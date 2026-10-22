import Foundation
import Testing
import os

@testable import MuxFinderCore

/// Closing the popover ends the automatic attachment check (PLAN.md D20, D22): no cookie
/// request, connection or identity question starts once it has closed, and a check started when
/// it reopens runs at once while the cancelled one's result is discarded. The engine drives the
/// real `AttachmentIndex` over the real `ITerm2APIClient`, whose cookie provider, connector and
/// byte stream are gated fakes; nothing touches iTerm2, its socket, AppleScript or tmux.
@Suite("Refresh: popover close")
struct RefreshPopoverCloseTests {
  /// Shorthand.
  typealias Support = RefreshTestSupport

  /// The engine, the real client under it, and the fakes.
  struct Harness {
    /// The engine, idle (no cadence: only the popover's requests run).
    let coordinator: RefreshCoordinator
    /// The real API client.
    let client: ITerm2APIClient
    /// The real index over `client`, counted.
    let index: CountingIndex
    /// The fake connector handing out the streams.
    let connector: FakeConnector
    /// Where the client records its connection outcomes.
    let log: DiagnosticsLog
  }

  /// An engine over This Mac (discovered at once, with one session) whose attachment checks run
  /// the real index over the real client with `cookies` and a connector handing out `streams`.
  static func harness(
    cookies: any ITerm2CookieProvider,
    streams: [FakeByteStream]
  ) -> Harness {
    let host = Support.thisMac()
    let prober = ScriptedProber()
    prober.setAnswer(.ok([Support.session(on: host)]), for: host.id)
    let connector = FakeConnector(streams: streams)
    let log = DiagnosticsLog(writesToSystemLog: false)
    var configuration = ITerm2APIClient.Configuration(socketPath: "/nonexistent/fake-socket")
    configuration.connectTimeout = .milliseconds(500)
    configuration.requestTimeout = .seconds(5)
    let client = ITerm2APIClient(
      configuration: configuration, appControl: FakeAppControl(running: true),
      cookieProvider: cookies, connector: connector, connectionSettings: fastConnectionSettings,
      diagnostics: log)
    let index = CountingIndex(AttachmentIndex(iTerm2: client))
    let coordinator = RefreshCoordinator(
      hosts: Support.list([host]), discovery: prober, attachmentIndex: index,
      clock: GatedAttachClock())
    return Harness(
      coordinator: coordinator, client: client, index: index, connector: connector, log: log)
  } // End of static func harness(cookies:streams:)

  /// Whether `request` carries the index's identity question.
  static func asksIdentity(_ request: ClientRequest) -> Bool {
    request.bytes.firstRange(of: Array(ConnectionIdentity.command.utf8)) != nil
  }

  /// The review's finding: the popover closes while the check waits for iTerm2's cookie. The
  /// check is cancelled, and when the cookie arrives the connection attempt, left without
  /// callers, stops before connecting: no connection, no request, nothing published.
  @Test func closingDuringTheCookieRequestContactsNothing() async throws {
    let cookies = GatedCookieProvider()
    let stream = FakeByteStream()
    let harness = Self.harness(cookies: cookies, streams: [stream])
    await harness.coordinator.popoverDidOpen()
    try await waitUntil("the check asked for the cookie") { cookies.calls == 1 }
    await harness.coordinator.popoverDidClose()
    try await waitUntil("the cancelled check left the connection attempt") {
      await harness.client.attemptWaiterCount == 0 && harness.index.ended == 1
    }
    cookies.release()
    try await waitUntil("the connection attempt ended") { await !harness.log.events().isEmpty }
    #expect(
      await harness.log.events().map(\.detail) == ["iTerm2 API connection failed: cancelled"])
    #expect(harness.connector.connects == 0)
    #expect(stream.written.isEmpty)
    #expect(cookies.calls == 1)
    #expect(harness.index.started == 1)
    #expect(await harness.coordinator.indexPassesStarted == 1)
    #expect(await harness.coordinator.state.attachmentCheck == .notChecked)
    await harness.coordinator.stop()
    #expect(await harness.coordinator.liveTaskCount == 0)
  } // End of func closingDuringTheCookieRequestContactsNothing()

  /// The review's finding: the popover closes midway through a check, after one connection
  /// answered its identity question while the other's ownership listing is still pending.
  /// Even when that listing's answer comes, the other connection is never asked: the next
  /// frame on the wire is the test's own request, and the check publishes nothing.
  @Test func closingMidCheckAsksNoFurtherConnection() async throws {
    let stream = FakeByteStream()
    let harness = Self.harness(cookies: FakeCookieProvider.numbered(), streams: [stream])
    var peer = FakeITerm2Peer(stream: stream)
    await harness.coordinator.popoverDidOpen()
    try await peer.answerHandshake()
    var request = try await peer.nextRequest()
    #expect(request.fieldNumber == 124)
    try peer.respond(to: request.id, withFixture: "tmux-list-connections-response")
    // Before its question, each of the fixture's two connections is listed again, bound to
    // its owner (D15).
    let first = try await peer.nextRequest()
    let second = try await peer.nextRequest()
    #expect(!Self.asksIdentity(first))
    #expect(!Self.asksIdentity(second))
    try peer.respond(to: first.id, withFixture: "tmux-list-connections-response")
    request = try await peer.nextRequest()
    #expect(Self.asksIdentity(request))
    try peer.respond(to: request.id, withFixture: "tmux-send-command-response")

    await harness.coordinator.popoverDidClose()
    try peer.respond(to: second.id, withFixture: "tmux-list-connections-response")
    try await waitUntil("the cancelled check ended") { harness.index.ended == 1 }
    let sessions = Task { try await harness.client.listSessions() }
    request = try await peer.nextRequest()
    #expect(!Self.asksIdentity(request))
    #expect(request.fieldNumber == 106)
    try peer.respond(to: request.id, withFixture: "list-sessions-response")
    _ = try await sessions.value
    #expect(harness.connector.connects == 1)
    #expect(await harness.coordinator.state.attachmentCheck == .notChecked)
    await harness.coordinator.stop()
    #expect(await harness.coordinator.liveTaskCount == 0)
  } // End of func closingMidCheckAsksNoFurtherConnection()

  /// The review's finding: reopening the popover while the cancelled check has not ended yet
  /// (its answer already on its way, so it ignores the cancellation) starts a fresh check at
  /// once, and the stale check's late answer is discarded: it neither publishes over the fresh
  /// one nor starts another check.
  @Test func reopeningRunsAFreshCheckAndDiscardsTheStaleOne() async {
    let host = Support.thisMac()
    let session = Support.session(on: host)
    let prober = ScriptedProber()
    prober.setAnswer(.ok([session]), for: host.id)
    let stale = AttachmentSnapshot(attachments: [
      .init(key: session.key, connectionID: "fixture-connection", owningSessionID: "fixture-owner")
    ])
    let index = HeldIndex(first: stale, later: AttachmentSnapshot())
    let coordinator = RefreshCoordinator(
      hosts: Support.list([host]), discovery: prober, attachmentIndex: index,
      clock: GatedAttachClock())
    await coordinator.popoverDidOpen()
    #expect(await Support.waitUntil { index.calls == 1 })
    await coordinator.popoverDidClose()
    await coordinator.popoverDidOpen()
    #expect(
      await Support.waitUntil(within: .seconds(3)) {
        await coordinator.state.attachmentCheck.kind == "checked"
      })
    #expect(index.calls == 2)
    #expect(index.ended == 1)

    index.release()
    #expect(await Support.waitUntil { await coordinator.liveTaskCount == 0 })
    #expect(index.ended == 2)
    let state = await coordinator.state
    #expect(state.snapshot(of: host.id)?.sessions.first?.attachments.isEmpty == true)
    if case .checked(_, let counts) = state.attachmentCheck {
      #expect(counts == AttachmentSnapshot.Counts())
    } else {
      Issue.record("expected a checked state, got \(state.attachmentCheck.kind)")
    }
    #expect(await coordinator.indexPassesStarted == 2)
    #expect(index.calls == 2)
    await coordinator.stop()
  } // End of func reopeningRunsAFreshCheckAndDiscardsTheStaleOne()
}

/// Wraps an attachment index and counts the checks started and ended.
final class CountingIndex: AttachmentIndexing {
  /// The wrapped index.
  private let inner: any AttachmentIndexing
  /// Checks started and ended.
  private let counts = OSAllocatedUnfairLock(initialState: (started: 0, ended: 0))

  /// Wraps `inner`.
  init(_ inner: any AttachmentIndexing) {
    self.inner = inner
  }

  /// Checks started so far.
  var started: Int { counts.withLock { $0.started } }
  /// Checks ended so far, however they ended.
  var ended: Int { counts.withLock { $0.ended } }

  /// Counts the check and runs the wrapped index.
  func snapshot(of hosts: [AttachmentIndex.Host]) async throws -> AttachmentSnapshot {
    counts.withLock { $0.started += 1 }
    defer { counts.withLock { $0.ended += 1 } }
    return try await inner.snapshot(of: hosts)
  }
}

/// An attachment index whose first call is held until `release()` whatever happens to its
/// task, like a check whose answer is already on its way, and then answers `first`; every
/// later call answers `later` at once. Counts calls started and ended. Never contacts iTerm2.
final class HeldIndex: AttachmentIndexing {
  /// Lock-protected state.
  private struct State {
    /// Calls started.
    var calls = 0
    /// Calls ended.
    var ended = 0
    /// Whether `release()` ran.
    var released = false
    /// The held first call, while it waits.
    var waiter: CheckedContinuation<Void, Never>?
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())
  /// The first call's answer.
  private let first: AttachmentSnapshot
  /// Every later call's answer.
  private let later: AttachmentSnapshot

  /// Creates an index answering `first` once released, then `later`.
  init(first: AttachmentSnapshot, later: AttachmentSnapshot) {
    self.first = first
    self.later = later
  }

  /// Calls started so far.
  var calls: Int { state.withLock { $0.calls } }
  /// Calls ended so far.
  var ended: Int { state.withLock { $0.ended } }

  /// Lets the held first call answer.
  func release() {
    let waiter = state.withLock { state in
      state.released = true
      defer { state.waiter = nil }
      return state.waiter
    }
    waiter?.resume()
  }

  /// Answers `later` at once, or, for the first call, `first` once released.
  func snapshot(of hosts: [AttachmentIndex.Host]) async throws -> AttachmentSnapshot {
    let call = state.withLock { state in
      state.calls += 1
      return state.calls
    }
    defer { state.withLock { $0.ended += 1 } }
    guard call == 1 else { return later }
    await withCheckedContinuation { continuation in
      let resumeNow = state.withLock { state in
        if state.released { return true }
        state.waiter = continuation
        return false
      }
      if resumeNow { continuation.resume() }
    }
    return first
  } // End of func snapshot(of:)
}
