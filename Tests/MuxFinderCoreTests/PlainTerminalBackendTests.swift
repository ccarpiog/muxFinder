import Foundation
import Testing

@testable import MuxFinderCore

/// The plain backend's attach (PLAN.md D38, Phase I-12c1) over test fakes: the fake window
/// layer (whose open plays the helper: it takes the plain request and writes the early report or
/// the result into a real `LaunchStore` on a private folder), a scripted process runner for
/// tmux and ssh, a fake discovery and a manual clock. Confirmation only from evidence, on This
/// Mac and over ssh; the helper's result first; every open failure; the remote still-waiting
/// state; coalescing and an unresolved earlier launch; the backend's own attachment focused,
/// or dropped when stale. No terminal app, iTerm2, tmux or ssh is ever run.
@Suite("Plain terminal backend: attach")
@MainActor
struct PlainTerminalBackendTests {
  /// Shorthand.
  typealias Support = PlainBackendSupport

  /// The window the n-th open of `harness` answers.
  static func window(_ number: Int, of harness: PlainBackendHarness) -> PlainTerminalWindow {
    PlainTerminalWindow(openedBy: harness.loaded, windowID: "fake-window-\(number)", tty: nil)
  }

  // MARK: - Confirmation on This Mac

  /// A match: the request is a plain one (the definition's id and minimum-lifetime choice, the
  /// session's four identity values, no move here); the window opens running the helper with
  /// the launch id; the session's one client on the report's terminal, with the report's attach
  /// child (still running with its start time), confirms; the attachment is recorded with every
  /// field of the session and the client; the window is focused once.
  @Test func confirmsTheLocalClientFromTheReport() async throws {
    let harness = try PlainBackendHarness()
    defer { harness.cleanUp() }
    let target = Support.target()
    let result = await harness.backend.attach(target)

    let request = try #require(harness.taken.first)
    #expect(harness.taken.count == 1)
    #expect(request.id == result.launchID)
    #expect(request.terminal == .plain(definitionID: "terminal"))
    #expect(request.keepsMinimumLifetime == harness.loaded.definition.keepsMinimumLifetime)
    #expect(request.host == .local && request.sessionID == TmuxSessionID("$3"))
    #expect(request.expectedServerPID == 4242 && request.expectedServerStartTime == 1_792_599_999)
    #expect(request.expectedSessionCreated == 1_792_600_001)
    #expect(request.detachOtherClients == nil && !request.detachesOtherClients)
    #expect(
      harness.windows.opens
        == [
          .init(
            definitionID: "terminal", helperPath: AttachTestSupport.helper.path,
            token: result.launchID)
        ])

    let window = Self.window(1, of: harness)
    let client = PlainClientRecord(
      session: Support.identity, client: Support.localClient, launchID: result.launchID,
      token: nil, terminalPath: Support.terminalPath)
    #expect(result.state == .plainConfirmed(client: client))
    #expect(result.isConfirmed && result.isAttached && !result.isFocused)
    #expect(result.plainWindow == window && result.plainClient == client)
    #expect(result.plainWindowHandle == .plainWindow(window))
    #expect(result.plainWindowFocus == .plainWindowFocused)
    #expect(result.gatewaySessionID == nil && result.connectionID == nil)
    #expect(result.activation == nil && result.burial == nil)
    #expect(harness.windows.focuses == [window])
    #expect(
      harness.log.states
        == [.requested, .plainLaunched(window: window), .plainConfirmed(client: client)])
    #expect(await harness.backend.state(of: target.key) == .plainConfirmed(client: client))
    #expect(
      await harness.backend.attachment(of: target.key)
        == PlainAttachment(
          loaded: harness.loaded, window: window, client: client,
          target: .init(host: .local, tmuxPathOverride: nil)))

    let listing = try #require(harness.runner.requests(.localListing).first)
    #expect(harness.runner.requests.count == 1)
    #expect(listing.executableURL.path(percentEncoded: false) == "/bin/sh")
    #expect(
      listing.arguments
        == [
          "-c", PlainTmuxCommands.script.source, "muxfinder", "", "list-clients", "-F",
          PlainClientIdentification.localFormat,
        ])
    #expect(listing.environment["TMUX"] == nil)
    #expect(harness.discovery.calls == 1)
    #expect(harness.backend.terminal == .plain(definitionID: "terminal"))
  } // End of func confirmsTheLocalClientFromTheReport()

  /// No client on the report's terminal (one on another terminal only): nothing confirms
  /// within the 15 s budget; the attach ends `timedOut`.
  @Test func noLocalCandidateNeverConfirms() async throws {
    let harness = try PlainBackendHarness(answer: { _, _ in
      Support.listing(Support.listingLine(pid: 6000, tty: "/dev/ttys009"))
    })
    defer { harness.cleanUp() }
    let result = await harness.backend.attach(Support.target())
    #expect(result.failure == .timedOut)
    #expect(result.plainClient == nil && result.plainWindow == Self.window(1, of: harness))
    #expect(harness.runner.requests(.localListing).count > 1)
    #expect(harness.windows.focuses.isEmpty)
    #expect(await harness.backend.attachment(of: Support.target().key) == nil)
  }

  /// Two clients of the session on the report's terminal: neither confirms (`timedOut`).
  @Test func twoLocalCandidatesNeverConfirm() async throws {
    let harness = try PlainBackendHarness(answer: { _, _ in
      Support.listing(Support.listingLine(), Support.listingLine(pid: 6000))
    })
    defer { harness.cleanUp() }
    let result = await harness.backend.attach(Support.target())
    #expect(result.failure == .timedOut)
    #expect(await harness.backend.attachment(of: Support.target().key) == nil)
  }

  /// A report without a terminal path never confirms: `cannotConfirmHere`, with no listing run.
  @Test func reportWithoutATerminalCannotConfirm() async throws {
    let harness = try PlainBackendHarness()
    defer { harness.cleanUp() }
    harness.report = { Support.report(for: $0, terminalPath: nil) }
    let result = await harness.backend.attach(Support.target())
    #expect(result.failure == .cannotConfirmHere)
    #expect(harness.runner.requests.isEmpty)
    #expect(harness.windows.focuses.isEmpty)
  }

  /// A stale report confirms nothing: the attach child running with another start time, the
  /// child gone, or the terminal's client another process than the report's child.
  @Test(arguments: ["start time", "gone", "other pid"])
  func staleReportNeverConfirms(_ staleness: String) async throws {
    let harness = try PlainBackendHarness(
      answer: { _, _ in
        Support.listing(Support.listingLine(pid: staleness == "other pid" ? 6000 : 5150))
      },
      startTime: { _ in
        switch staleness {
        case "start time": return ProcessStartTime(seconds: 1_792_600_100, microseconds: 251)
        case "gone": return nil
        default: return Support.childStart
        }
      })
    defer { harness.cleanUp() }
    let result = await harness.backend.attach(Support.target())
    #expect(result.failure == .timedOut, "\(staleness)")
    #expect(await harness.backend.attachment(of: Support.target().key) == nil)
  } // End of func staleReportNeverConfirms(_:)

  /// A report that does not decode, or is too large, is a typed failure, never a confirmation.
  @Test(arguments: [false, true])
  func malformedReportIsAFailure(_ oversized: Bool) async throws {
    let harness = try PlainBackendHarness()
    defer { harness.cleanUp() }
    harness.report = nil
    let directory = harness.store.directory
    harness.windows.onOpen = { token in
      let url = directory.appending(path: LaunchStore.reportFileName(for: token))
      let bytes = oversized ? Data(repeating: 0x20, count: 20_000) : Data("{}".utf8)
      FileManager.default.createFile(
        atPath: url.path(percentEncoded: false), contents: bytes,
        attributes: [.posixPermissions: 0o600])
    }
    let result = await harness.backend.attach(Support.target())
    #expect(
      result.failure
        == .launchStore(oversized ? .fileUnsafe(.tooLarge) : .fileMalformed))
    #expect(harness.runner.requests.isEmpty)
  } // End of func malformedReportIsAFailure(_:)

  /// A helper result before any confirmation ends the attach with the coordinator's mapping:
  /// a clean end `helperEnded`, a gone session `sessionGone`, any other failure `helperFailed`.
  @Test func helperResultFirstFailsTheAttach() async throws {
    let cases: [(LaunchFailure?, AttachFailure)] = [
      (nil, .helperEnded), (.sessionGone, .sessionGone), (.sessionChanged, .sessionChanged),
      (.childExited(1), .helperFailed(.childExited(1))),
    ]
    for (failure, expected) in cases {
      let harness = try PlainBackendHarness()
      defer { harness.cleanUp() }
      harness.result = { Support.result(for: $0, failure: failure) }
      let result = await harness.backend.attach(Support.target())
      #expect(result.failure == expected)
      #expect(harness.runner.requests.isEmpty, "the result comes first")
      #expect(await harness.backend.unsettledLaunchCount(for: Support.target().key) == 0)
    } // End of loop over the helper's ends
  } // End of func helperResultFirstFailsTheAttach()

  /// A listing that fails (tmux's own error) fails the attach `clientCheckFailed`; no server is
  /// a listing with no client (the helper's result then says the session is gone).
  @Test func failedListingFailsAndNoServerIsEmpty() async throws {
    let failing = try PlainBackendHarness(answer: { _, _ in
      Support.output("", status: 3, stderr: "some tmux error")
    })
    defer { failing.cleanUp() }
    let failed = await failing.backend.attach(Support.target())
    #expect(failed.failure == .clientCheckFailed(.exited(.exited(3))))

    let noServer = try PlainBackendHarness(answer: { _, _ in
      Support.output("", status: 1, stderr: "no server running on /private/tmp/tmux-501/default\n")
    })
    defer { noServer.cleanUp() }
    let gone = await noServer.backend.attach(Support.target())
    #expect(gone.failure == .timedOut)
  } // End of func failedListingFailsAndNoServerIsEmpty()

  // MARK: - Confirmation on an SSH host

  /// A remote match: the token reading over discovery's noninteractive ssh (the static script
  /// with the override, the session id and the launch id) finds exactly one client whose parent
  /// shell ends with the token; the record keeps the token.
  @Test func confirmsTheRemoteClientByItsToken() async throws {
    let host = Support.remoteHost
    let harness = try PlainBackendHarness(
      sessions: [Support.session(on: host)],
      answer: { _, _ in
        Support.remoteAnswer([(false, Support.localClient), (true, Support.remoteClient)])
      })
    defer { harness.cleanUp() }
    harness.report = { Support.report(for: $0, terminalPath: nil) }
    let result = await harness.backend.attach(Support.target(on: host))
    let request = try #require(harness.taken.first)
    #expect(request.host == .ssh(destination: "remote-fixture"))
    let client = PlainClientRecord(
      session: Support.identity, client: Support.remoteClient, launchID: result.launchID,
      token: result.launchID, terminalPath: nil)
    #expect(result.state == .plainConfirmed(client: client))
    let reading = try #require(harness.runner.requests(.remoteReading).first)
    #expect(harness.runner.requests.count == 1)
    #expect(reading.executableURL.path(percentEncoded: false) == "/usr/bin/ssh")
    #expect(
      reading.arguments
        == DiscoveryProbe.sshOptions
        + [
          "-n", "-T", "--", "remote-fixture",
          ShellQuoting.remoteCommand(
            script: PlainClientIdentification.remoteScript,
            args: ["", "$3", result.launchID.rawValue]),
        ])
    #expect(
      await harness.backend.attachment(of: Support.target(on: host).key)?.target
        == .init(host: .ssh(destination: "remote-fixture"), tmuxPathOverride: nil))
  } // End of func confirmsTheRemoteClientByItsToken()

  /// Remotely, no candidate and then two candidates confirm nothing: past the 20 s budget the
  /// attach publishes `plainStillWaiting` once (never a success) and keeps watching; a single
  /// match later confirms it.
  @Test func remoteStillWaitsThenConfirms() async throws {
    let host = Support.remoteHost
    let other = OtherClient(processID: "6200", created: "1792600150", name: "/dev/ttys008")!
    let clock = ManualAttachClock()
    let harness = try PlainBackendHarness(
      sessions: [Support.session(on: host)],
      answer: { _, number in
        if number < 50 { return Support.remoteAnswer([(false, Support.remoteClient)]) }
        if number < 130 {
          return Support.remoteAnswer([(true, Support.remoteClient), (true, other)])
        }
        return Support.remoteAnswer([(true, Support.remoteClient)])
      },
      clock: clock)
    defer { harness.cleanUp() }
    let result = await harness.backend.attach(Support.target(on: host))
    #expect(result.isConfirmed)
    #expect(result.plainClient?.client == Support.remoteClient)
    let window = Self.window(1, of: harness)
    let states = harness.log.states
    #expect(states.filter { $0 == .plainStillWaiting(window: window) }.count == 1)
    let waiting = try #require(states.firstIndex(of: .plainStillWaiting(window: window)))
    #expect(waiting < states.count - 1 && states.last?.kind == "plainConfirmed")
    #expect(result.timings.stillWaiting != nil)
    #expect(clock.elapsed > .seconds(20))
  } // End of func remoteStillWaitsThenConfirms()

  /// Remotely, a launch that never confirms stops at the wait limit (`waitLimitReached`).
  @Test func remoteWaitLimitEndsTheWatch() async throws {
    let host = Support.remoteHost
    let clock = ManualAttachClock()
    let harness = try PlainBackendHarness(
      sessions: [Support.session(on: host)],
      answer: { _, _ in Support.remoteAnswer([]) }, clock: clock)
    defer { harness.cleanUp() }
    let result = await harness.backend.attach(Support.target(on: host))
    #expect(result.failure == .waitLimitReached)
    #expect(harness.log.states.contains { $0.kind == "plainStillWaiting" })
    #expect(clock.elapsed >= .seconds(300))
  }

  /// Remote readings that fail: an unreadable answer and ssh's own failure.
  @Test func failedRemoteReadings() async throws {
    let host = Support.remoteHost
    for (answer, expected) in [
      (Support.output("match 1 2\n"), PlainTmuxCommandFailure.unreadable),
      (Support.output("", status: 255, stderr: "ssh: connect to host"), .sshFailed),
    ] {
      let harness = try PlainBackendHarness(
        sessions: [Support.session(on: host)], answer: { _, _ in answer })
      defer { harness.cleanUp() }
      let result = await harness.backend.attach(Support.target(on: host))
      #expect(result.failure == .clientCheckFailed(expected))
    } // End of loop over the failed readings
  } // End of func failedRemoteReadings()

  // MARK: - Review fixes: the helper's end and the kept report

  /// A reading that confirms while the helper ends (its result written while the reading is in
  /// flight; on This Mac and over ssh) confirms nothing: the attach ends as the result maps
  /// (`helperEnded`), with no attachment recorded, no `plainConfirmed` published and no focus.
  @Test(arguments: [false, true])
  func helperEndingDuringAConfirmingReadingFails(_ remote: Bool) async throws {
    let host = remote ? Support.remoteHost : AttachTestSupport.host
    let harness = try PlainBackendHarness(sessions: [Support.session(on: host)])
    defer { harness.cleanUp() }
    if remote { harness.report = { Support.report(for: $0, terminalPath: nil) } }
    let store = harness.store
    harness.runner.setAnswer { _, _ in
      if let token = Support.reportToken(in: store) {
        try? store.writeResult(Support.result(for: token))
      }
      return remote
        ? Support.remoteAnswer([(true, Support.remoteClient)])
        : Support.listing(Support.listingLine())
    }
    let target = Support.target(on: host)
    let result = await harness.backend.attach(target)
    #expect(result.failure == .helperEnded, "remote: \(remote)")
    #expect(result.plainClient == nil && !result.isConfirmed)
    #expect(harness.runner.requests.count == 1, "one reading, which matched")
    #expect(harness.windows.focuses.isEmpty)
    #expect(!harness.log.states.contains { $0.kind == "plainConfirmed" })
    #expect(await harness.backend.attachment(of: target.key) == nil)
    #expect(await harness.backend.unsettledLaunchCount(for: target.key) == 0)
  } // End of func helperEndingDuringAConfirmingReadingFails(_:)

  /// The first early report read is kept for the whole wait: removed right after it (as the
  /// sweep removes reports after 120 s while a remote wait goes on to 300 s), a later reading
  /// still confirms from it, on This Mac and over ssh; the record keeps its terminal.
  @Test(arguments: [false, true])
  func removedReportStillConfirms(_ remote: Bool) async throws {
    let host = remote ? Support.remoteHost : AttachTestSupport.host
    let harness = try PlainBackendHarness(sessions: [Support.session(on: host)])
    defer { harness.cleanUp() }
    if remote { harness.report = { Support.report(for: $0, terminalPath: nil) } }
    let store = harness.store
    harness.runner.setAnswer { _, number in
      if number == 1 {
        // The first reading finds no candidate yet, and the report's file goes meanwhile.
        if let token = Support.reportToken(in: store) { _ = try? store.removeReport(token) }
        return remote ? Support.remoteAnswer([]) : Support.listing()
      }
      return remote
        ? Support.remoteAnswer([(true, Support.remoteClient)])
        : Support.listing(Support.listingLine())
    }
    let target = Support.target(on: host)
    let result = await harness.backend.attach(target)
    #expect(result.isConfirmed, "remote: \(remote) \(result.failure?.kind ?? "")")
    #expect(harness.runner.requests.count == 2)
    #expect(try harness.store.peekReport(result.launchID) == nil, "the file stayed gone")
    #expect(result.plainClient?.terminalPath == (remote ? nil : Support.terminalPath))
    #expect(await harness.backend.attachment(of: target.key)?.launchID == result.launchID)
  } // End of func removedReportStillConfirms(_:)

  /// A report file that differs from the one kept (rewritten with another attach child, one
  /// the listing would match) is a typed failure, never a confirmation:
  /// `launchStore(fileMalformed)`, no reading after it, nothing recorded.
  @Test func changedReportIsAFailure() async throws {
    let harness = try PlainBackendHarness()
    defer { harness.cleanUp() }
    harness.report = { Support.report(for: $0, childPID: 6000) }
    let store = harness.store
    harness.runner.setAnswer { _, number in
      if number == 1, let token = Support.reportToken(in: store) {
        try? store.writeReport(Support.report(for: token))
      }
      return Support.listing(Support.listingLine())
    }
    let target = Support.target()
    let result = await harness.backend.attach(target)
    #expect(result.failure == .launchStore(.fileMalformed))
    #expect(harness.runner.requests.count == 1)
    #expect(harness.windows.focuses.isEmpty)
    #expect(await harness.backend.attachment(of: target.key) == nil)
  } // End of func changedReportIsAFailure()

  // MARK: - Open failures

  /// Every failure the window layer's open can give ends the attach `terminalWindow` with that
  /// error, the request withdrawn (nothing left in the launch folder), one open only (no
  /// retry), nothing run in tmux.
  @Test func everyOpenFailureEndsTheAttach() async throws {
    let harness = try PlainBackendHarness()
    defer { harness.cleanUp() }
    let failures: [PlainTerminalWindowError] = [
      .appNotInstalled(appName: "Terminal"),
      .appTooOld(appName: "Terminal", installed: "1.0", minimum: "2.0"),
      .appVersionUnknown(appName: "Terminal", minimum: "2.0"),
      .permissionDenied(appName: "Terminal"),
      .launchCommandRefused(.helperPathUnsafeForShellText),
      .scriptFailed(appName: "Terminal", .compileFailed(errorNumber: -2741)),
      .scriptFailed(appName: "Terminal", .callFailed(handler: .open, errorNumber: -1708)),
      .scriptMissing(appName: "Terminal"),
      .malformedReply(appName: "Terminal", handler: .open),
      .spawnFailed(appName: "Terminal", .spawnFailed(errno: ENOENT)),
    ]
    for (index, failure) in failures.enumerated() {
      harness.windows.openFailure = failure
      let result = await harness.backend.attach(Support.target())
      #expect(result.failure == .terminalWindow(failure))
      #expect(result.failure?.message == failure.message)
      #expect(result.plainWindow == nil)
      #expect(harness.windows.opens.count == index + 1)
      #expect(try harness.files().isEmpty, "the request was withdrawn")
    } // End of loop over the open failures
    #expect(harness.runner.requests.isEmpty && harness.windows.focuses.isEmpty)
    #expect(await harness.backend.unsettledLaunchCount(for: Support.target().key) == 0)
  } // End of func everyOpenFailureEndsTheAttach()

  /// A window focus that fails after a confirmation is recorded and never fails the attach.
  @Test func failedFocusKeepsTheAttachConfirmed() async throws {
    let harness = try PlainBackendHarness()
    defer { harness.cleanUp() }
    harness.windows.focusFailure = .appNotRunning(appName: "Terminal")
    let result = await harness.backend.attach(Support.target())
    #expect(result.isConfirmed)
    #expect(result.plainWindowFocus == .plainWindowFailed(.appNotRunning(appName: "Terminal")))
  }

  // MARK: - Coalescing and earlier launches

  /// Two concurrent attaches of one session share one launch: one discovery, one request, one
  /// window, one result.
  @Test func concurrentAttachesCoalesce() async throws {
    let discovery = FakeDiscovery(.ok([Support.session()]), gated: true)
    let harness = try PlainBackendHarness(discovery: discovery)
    defer { harness.cleanUp() }
    let backend = harness.backend
    let target = Support.target()
    let first = Task { await backend.attach(target) }
    while discovery.calls == 0 { await Task.yield() }
    let second = Task { await backend.attach(target) }
    while await backend.waiterCount(for: target.key) < 2 { await Task.yield() }
    discovery.release()
    let one = await first.value
    let two = await second.value
    #expect(one == two && one.isConfirmed)
    #expect(discovery.calls == 1 && harness.windows.opens.count == 1 && harness.taken.count == 1)
  } // End of func concurrentAttachesCoalesce()

  /// An earlier launch that may still attach (its helper took the request; no client, no
  /// result) refuses a new attach within the confirmation budget (`earlierLaunchPending`,
  /// nothing opened); once its result exists, the next attach goes ahead.
  @Test func unresolvedEarlierLaunchRefusesANewOne() async throws {
    let harness = try PlainBackendHarness()
    defer { harness.cleanUp() }
    harness.report = nil
    let target = Support.target()
    let first = await harness.backend.attach(target)
    #expect(first.failure == .timedOut)
    #expect(await harness.backend.unsettledLaunchCount(for: target.key) == 1)

    let refused = await harness.backend.attach(target)
    #expect(refused.failure == .earlierLaunchPending)
    #expect(harness.windows.opens.count == 1 && harness.taken.count == 1)

    try harness.store.writeResult(Support.result(for: first.launchID, failure: .sessionGone))
    harness.report = { Support.report(for: $0) }
    let next = await harness.backend.attach(target)
    #expect(next.isConfirmed)
    #expect(harness.windows.opens.count == 2)
    #expect(await harness.backend.unsettledLaunchCount(for: target.key) == 0)
  } // End of func unresolvedEarlierLaunchRefusesANewOne()

  /// A launch whose request was withdrawn before a helper took it can no longer attach, so the
  /// next attach does not wait for it.
  @Test func withdrawnLaunchDoesNotBlock() async throws {
    let harness = try PlainBackendHarness()
    defer { harness.cleanUp() }
    harness.takesRequests = false
    harness.report = nil
    let first = await harness.backend.attach(Support.target())
    #expect(first.failure == .timedOut)
    #expect(try harness.files().isEmpty, "the request was withdrawn")
    #expect(await harness.backend.unsettledLaunchCount(for: Support.target().key) == 0)
  }

  // MARK: - The backend's own attachment

  /// A live attachment (the bound presence check answers present) is focused instead of
  /// opening another window: `plainFocused` with the same client and window, no request.
  @Test func liveAttachmentIsFocused() async throws {
    let harness = try PlainBackendHarness(answer: { kind, _ in
      kind == .presence
        ? Support.output(PlainClientPresence.presentMarker + "\n")
        : Support.listing(Support.listingLine())
    })
    defer { harness.cleanUp() }
    let target = Support.target()
    let first = await harness.backend.attach(target)
    let client = try #require(first.plainClient)
    let focused = await harness.backend.attach(target)
    let window = Self.window(1, of: harness)
    #expect(focused.state == .plainFocused(client: client))
    #expect(focused.isFocused && focused.isAttached && !focused.isConfirmed)
    #expect(focused.plainWindow == window && focused.plainWindowFocus == .plainWindowFocused)
    #expect(harness.windows.opens.count == 1 && harness.taken.count == 1)
    #expect(harness.windows.focuses == [window, window])
    #expect(harness.log.states.last == .plainFocused(client: client))
    let presence = try #require(harness.runner.requests(.presence).first)
    #expect(
      presence.arguments
        == ["-c", PlainTmuxCommands.script.source, "muxfinder", ""]
        + PlainClientPresence.arguments(of: Support.localClient, in: Support.identity)!)
  } // End of func liveAttachmentIsFocused()

  /// A stale attachment (the presence check finds another client, or its helper's result
  /// exists) is dropped and a new window opened; a presence check that cannot run fails the
  /// attach and opens nothing.
  @Test func staleAttachmentIsDropped() async throws {
    let harness = try PlainBackendHarness(answer: { kind, _ in
      kind == .presence
        ? Support.output(PlainClientDetach.notThisClientMarker + "\n")
        : Support.listing(Support.listingLine())
    })
    defer { harness.cleanUp() }
    let target = Support.target()
    let first = await harness.backend.attach(target)
    let second = await harness.backend.attach(target)
    #expect(second.isConfirmed && second.launchID != first.launchID)
    #expect(harness.windows.opens.count == 2)
    #expect(await harness.backend.attachment(of: target.key)?.launchID == second.launchID)

    try harness.store.writeResult(Support.result(for: second.launchID))
    let presenceChecks = harness.runner.requests(.presence).count
    let third = await harness.backend.attach(target)
    #expect(third.isConfirmed && harness.windows.opens.count == 3)
    #expect(harness.runner.requests(.presence).count == presenceChecks, "dropped by its result")

    harness.runner.setAnswer { _, _ in Support.output("", status: 2) }
    let failed = await harness.backend.attach(target)
    #expect(failed.failure == .clientCheckFailed(.exited(.exited(2))))
    #expect(harness.windows.opens.count == 3)
  } // End of func staleAttachmentIsDropped()

  // MARK: - Focus

  /// A plain window goes through the window layer with the backend's loaded definition (another
  /// definition's window is refused there, nothing sent); an iTerm2 launch tab is refused with
  /// nothing run.
  @Test func focusesItsWindowsAndRefusesITerm2Tabs() async throws {
    let harness = try PlainBackendHarness()
    defer { harness.cleanUp() }
    let window = PlainTerminalWindow(openedBy: harness.loaded, windowID: "4711", tty: nil)
    #expect(await harness.backend.focus(.plainWindow(window)) == .plainWindowFocused)
    #expect(harness.windows.focuses == [window])
    let ghosttyWindow = PlainTerminalWindow(
      openedBy: try Support.ghostty(), windowID: "W-1", tty: nil)
    #expect(
      await harness.backend.focus(.plainWindow(ghosttyWindow))
        == .plainWindowFailed(.windowOfAnotherTerminal))
    #expect(
      await harness.backend.focus(.iTerm2LaunchTab(sessionID: AttachTestSupport.gateway))
        == .handleOfAnotherTerminal)
    #expect(harness.windows.focuses == [window, ghosttyWindow])
    #expect(harness.runner.requests.isEmpty && harness.discovery.calls == 0)
  } // End of func focusesItsWindowsAndRefusesITerm2Tabs()

  /// The plain states and failures have their own kinds; the iTerm2 ones are unchanged.
  @Test func plainKindsAreTheirOwn() throws {
    let window = PlainTerminalWindow(openedBy: try Support.terminal(), windowID: "1", tty: nil)
    let client = PlainClientRecord(
      session: Support.identity, client: Support.localClient, launchID: LaunchToken(),
      token: nil, terminalPath: nil)
    #expect(AttachState.plainLaunched(window: window).kind == "plainLaunched")
    #expect(AttachState.plainStillWaiting(window: window).kind == "plainStillWaiting")
    #expect(AttachState.plainConfirmed(client: client).kind == "plainConfirmed")
    #expect(AttachState.plainFocused(client: client).kind == "plainFocused")
    #expect(
      AttachFailure.terminalWindow(.permissionDenied(appName: "Terminal")).kind
        == "terminalWindow")
    #expect(
      AttachFailure.terminalWindow(.permissionDenied(appName: "Terminal")).detail
        == "permissionDenied")
    #expect(AttachFailure.cannotConfirmHere.kind == "cannotConfirmHere")
    #expect(AttachFailure.clientCheckFailed(.sshFailed).detail == "sshFailed")
    #expect(AttachFailure.alreadyOpenInTerminal(window: window).message.contains("Terminal"))
    #expect(!AttachFailure.cannotConfirmHere.triggersRefresh)
  } // End of func plainKindsAreTheirOwn()
} // End of struct PlainTerminalBackendTests
