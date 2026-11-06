import Foundation
import Testing

@testable import MuxFinderCore

/// `FolderSearchChannel` (PLAN.md D36) over `FakeFolderSearchTransport` and a gated clock:
/// the debounce, latest text only, one query in flight, older answers dropped, opening once on
/// a failure and reporting the second, timeouts, the quiet close, a host change, closing, the
/// header's unavailability and refused text. Synthetic paths only.
@Suite("Folder search channel")
struct FolderSearchChannelTests {
  /// A channel with its fake transport and clock.
  struct Rig {
    /// The transport.
    let transport = FakeFolderSearchTransport()
    /// The clock; sleeps end only when the test advances it.
    let clock = GatedAttachClock()
    /// The channel.
    let channel: FolderSearchChannel

    /// A rig with the default timings.
    init() {
      channel = FolderSearchChannel(transport: transport, clock: clock)
    }

    /// A header with Spotlight on everywhere.
    static let header = FolderSearchHeader(
      homeDirectory: "/Users/example", hasSpotlight: true, homeIndexing: .on, diskIndexing: .on,
      desktop: .readable, documents: .readable, downloads: .readable)

    /// Waits until `count` connections were opened; returns the last one.
    func opened(_ count: Int) async throws -> FakeFolderSearchConnection {
      #expect(await FolderSearchWait.until { transport.connections.count >= count })
      #expect(transport.connections.count == count)
      return try #require(transport.connections.last)
    }

    /// Waits until `connection` was sent `count` lines.
    func lines(_ connection: FakeFolderSearchConnection, _ count: Int) async -> [String] {
      #expect(await FolderSearchWait.until { connection.sentLines.count >= count })
      return connection.sentLines
    }

    /// Waits until exactly `count` sleeps wait on the clock.
    func sleeps(_ count: Int) async {
      #expect(await FolderSearchWait.until { clock.waiting == count }, "sleeps \(clock.waiting)")
    }

    /// Waits until the channel's phase matches `predicate`; returns the state.
    @discardableResult
    func phase(_ predicate: @escaping (FolderSearchState.Phase) -> Bool) async -> FolderSearchState
    {
      #expect(await FolderSearchWait.until { predicate(await channel.state.phase) })
      return await channel.state
    }

    /// Searches `text` on `host` and waits for its timers to be armed (`sleeps` waiting).
    func search(
      _ text: String, scope: FolderSearchScope = .home, on host: FolderSearchHost = .local,
      sleeps: Int? = nil
    ) async {
      await channel.search(text, scope: scope, on: host)
      if let sleeps { await self.sleeps(sleeps) }
    }

    /// Opens a channel for `text`, gives it the header, passes the debounce and returns the
    /// connection with the line sent.
    func searchedAndSent(
      _ text: String, scope: FolderSearchScope = .home, connections: Int = 1
    ) async throws -> FakeFolderSearchConnection {
      await search(text, scope: scope, sleeps: 3)
      let connection = try await opened(connections)
      connection.emit(.header(Self.header))
      await sleeps(2)
      clock.advance(by: .milliseconds(150))
      _ = await lines(connection, connection.sentLines.count + 1)
      return connection
    } // End of func searchedAndSent(_:scope:connections:)
  }

  /// Whether `phase` is `searching`.
  static func isSearching(_ phase: FolderSearchState.Phase) -> Bool { phase == .searching }

  /// Whether `phase` is an answer.
  static func isAnswered(_ phase: FolderSearchState.Phase) -> Bool {
    if case .answered = phase { return true }
    return false
  }

  /// Whether `phase` is a failure.
  static func isFailed(_ phase: FolderSearchState.Phase) -> Bool {
    if case .failed = phase { return true }
    return false
  }

  /// Typing opens the script at once, but the query waits for 150 ms without typing and then
  /// carries only the latest text; the answer is shown with its paths.
  @Test func debouncesAndSendsOnlyTheLatestText() async throws {
    let rig = Rig()
    await rig.search("ab", sleeps: 3)
    let connection = try await rig.opened(1)
    #expect(await rig.channel.state.phase == .searching)
    connection.emit(.header(Rig.header))
    await rig.sleeps(2)
    rig.clock.advance(by: .milliseconds(100))
    await rig.search("abc", sleeps: 2)
    await rig.search("abcd", sleeps: 2)
    rig.clock.advance(by: .milliseconds(149))
    try await Task.sleep(for: .milliseconds(20))
    #expect(connection.sentLines.isEmpty)
    rig.clock.advance(by: .milliseconds(1))
    #expect(await rig.lines(connection, 1) == ["1 home abcd\n"])
    connection.emit(.reply(FolderSearchReply(id: 1, status: .ok, paths: ["/syn/a", "/syn/b"])))
    let state = await rig.phase(Self.isAnswered)
    #expect(
      state.phase == .answered(FolderSearchAnswer(paths: ["/syn/a", "/syn/b"], isLimited: false)))
    #expect(state.text == "abcd")
    #expect(state.header == Rig.header)
    #expect(rig.transport.connections.count == 1)
  } // End of func debouncesAndSendsOnlyTheLatestText()

  /// No query leaves before the header, even once the debounce passed; the header sends it.
  @Test func waitsForTheHeader() async throws {
    let rig = Rig()
    await rig.search("ab", sleeps: 3)
    let connection = try await rig.opened(1)
    rig.clock.advance(by: .milliseconds(150))
    await rig.sleeps(2)
    try await Task.sleep(for: .milliseconds(20))
    #expect(connection.sentLines.isEmpty)
    rig.clock.advance(by: .seconds(1))
    connection.emit(.header(Rig.header))
    #expect(await rig.lines(connection, 1) == ["1 home ab\n"])
    #expect(await rig.channel.state.openDuration == .milliseconds(1150))
  } // End of func waitsForTheHeader()

  /// One query in flight: a newer text waits for it; its answer, for an older text, is dropped
  /// and the newer text goes at once; an unknown id is dropped too.
  @Test func keepsOneQueryInFlightAndDropsOlderAnswers() async throws {
    let rig = Rig()
    let connection = try await rig.searchedAndSent("ab")
    await rig.search("abc", sleeps: 3)
    rig.clock.advance(by: .milliseconds(150))
    try await Task.sleep(for: .milliseconds(20))
    #expect(connection.sentLines == ["1 home ab\n"])
    connection.emit(.reply(FolderSearchReply(id: 1, status: .ok, paths: ["/syn/old"])))
    #expect(await rig.lines(connection, 2) == ["1 home ab\n", "2 home abc\n"])
    #expect(await rig.channel.state.phase == .searching)
    connection.emit(.reply(FolderSearchReply(id: 77, status: .ok, paths: ["/syn/unknown"])))
    connection.emit(.reply(FolderSearchReply(id: 2, status: .limited, paths: ["/syn/new"])))
    let state = await rig.phase(Self.isAnswered)
    #expect(state.phase == .answered(FolderSearchAnswer(paths: ["/syn/new"], isLimited: true)))
    #expect(state.droppedReplies == 2)
  } // End of func keepsOneQueryInFlightAndDropsOlderAnswers()

  /// The same text while its query is in flight changes nothing; asked again once answered, it
  /// is searched again.
  @Test func repeatsAnAnsweredText() async throws {
    let rig = Rig()
    let connection = try await rig.searchedAndSent("ab")
    await rig.channel.search("ab", scope: .home, on: .local)
    connection.emit(.reply(FolderSearchReply(id: 1, status: .ok, paths: [])))
    await rig.phase(Self.isAnswered)
    #expect(await rig.channel.state.droppedReplies == 0)
    await rig.search("ab", sleeps: 2)
    rig.clock.advance(by: .milliseconds(150))
    #expect(await rig.lines(connection, 2) == ["1 home ab\n", "2 home ab\n"])
  } // End of func repeatsAnAnsweredText()

  /// A dead script is closed and opened again at once for the latest text; a second failure in
  /// a row is reported and stands for that text; a new text tries once more, and an answer
  /// clears the count.
  @Test func reopensOnceAndReportsTheSecondFailure() async throws {
    let rig = Rig()
    let first = try await rig.searchedAndSent("ab")
    first.end(exitCode: 1)
    let second = try await rig.opened(2)
    #expect(await FolderSearchWait.until { first.isClosed })
    #expect(await rig.channel.state.phase == .searching)
    second.emit(.header(Rig.header))
    #expect(await rig.lines(second, 1) == ["2 home ab\n"])
    second.end(exitCode: 1)
    let state = await rig.phase(Self.isFailed)
    #expect(state.phase == .failed(.ended(.exited(1))))
    await rig.channel.search("ab", scope: .home, on: .local)
    try await Task.sleep(for: .milliseconds(20))
    #expect(rig.transport.connections.count == 2)
    #expect(await rig.channel.state.phase == .failed(.ended(.exited(1))))
    let third = try await rig.searchedAndSent("abc", connections: 3)
    third.emit(.reply(FolderSearchReply(id: 3, status: .ok, paths: ["/syn/x"])))
    await rig.phase(Self.isAnswered)
    #expect(await rig.channel.consecutiveFailures == 0)
  } // End of func reopensOnceAndReportsTheSecondFailure()

  /// A script that dies while idle counts one failure; the next text opens a new one.
  @Test func reopensAfterAnIdleDeath() async throws {
    let rig = Rig()
    let first = try await rig.searchedAndSent("ab")
    first.emit(.reply(FolderSearchReply(id: 1, status: .ok, paths: [])))
    await rig.phase(Self.isAnswered)
    first.end(exitCode: 0)
    #expect(await FolderSearchWait.until { await rig.channel.consecutiveFailures == 1 })
    #expect(
      await rig.channel.state.phase == .answered(FolderSearchAnswer(paths: [], isLimited: false)))
    let second = try await rig.searchedAndSent("abc", connections: 2)
    #expect(second.sentLines == ["2 home abc\n"])
  } // End of func reopensAfterAnIdleDeath()

  /// No header within 10 s and no answer within 5 s are failures; after a reported failure a
  /// new text makes exactly one attempt.
  @Test func timesOutTheHeaderAndTheAnswer() async throws {
    let rig = Rig()
    await rig.search("ab", sleeps: 3)
    _ = try await rig.opened(1)
    rig.clock.advance(by: .milliseconds(150))
    await rig.sleeps(2)
    rig.clock.advance(by: .milliseconds(9850))
    _ = try await rig.opened(2)
    await rig.sleeps(2)
    rig.clock.advance(by: .seconds(10))
    #expect(await rig.phase(Self.isFailed).phase == .failed(.headerTimedOut))
    #expect(await FolderSearchWait.until { rig.transport.connections.allSatisfy(\.isClosed) })
    let third = try await rig.searchedAndSent("abc", connections: 3)
    await rig.sleeps(2)
    rig.clock.advance(by: .seconds(5))
    #expect(await rig.phase(Self.isFailed).phase == .failed(.answerTimedOut))
    try await Task.sleep(for: .milliseconds(20))
    #expect(rig.transport.connections.count == 3)
    #expect(await FolderSearchWait.until { third.isClosed })
  } // End of func timesOutTheHeaderAndTheAnswer()

  /// A quiet minute closes the script without counting a failure; the next text opens another.
  @Test func closesAfterAQuietMinute() async throws {
    let rig = Rig()
    let first = try await rig.searchedAndSent("ab")
    first.emit(.reply(FolderSearchReply(id: 1, status: .ok, paths: ["/syn/a"])))
    await rig.phase(Self.isAnswered)
    await rig.sleeps(1)
    rig.clock.advance(by: .seconds(59))
    try await Task.sleep(for: .milliseconds(20))
    #expect(!first.isClosed)
    rig.clock.advance(by: .seconds(1))
    #expect(await FolderSearchWait.until { first.isClosed })
    #expect(await rig.channel.consecutiveFailures == 0)
    #expect(
      await rig.channel.state.phase
        == .answered(FolderSearchAnswer(paths: ["/syn/a"], isLimited: false)))
    _ = try await rig.searchedAndSent("abc", connections: 2)
  } // End of func closesAfterAQuietMinute()

  /// A host change closes the script, forgets its header and failures, and opens one on the new
  /// host; the old script's answer is ignored.
  @Test func startsAfreshOnAHostChange() async throws {
    let rig = Rig()
    let local = try await rig.searchedAndSent("ab")
    await rig.channel.search("ab", scope: .home, on: .ssh(destination: "saturno-m4"))
    let remote = try await rig.opened(2)
    #expect(remote.host == .ssh(destination: "saturno-m4"))
    #expect(await FolderSearchWait.until { local.isClosed })
    let state = await rig.channel.state
    #expect(state.host == .ssh(destination: "saturno-m4"))
    #expect(state.header == nil)
    #expect(state.phase == .searching)
    local.emit(.reply(FolderSearchReply(id: 1, status: .ok, paths: ["/syn/old"])))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await rig.channel.state.phase == .searching)
    #expect(rig.transport.openedHosts == [.local, .ssh(destination: "saturno-m4")])
  } // End of func startsAfreshOnAHostChange()

  /// `close()` ends the script and every timer, goes back to idle and returns once nothing is
  /// pending; a later search opens a new script.
  @Test func closesExplicitly() async throws {
    let rig = Rig()
    let connection = try await rig.searchedAndSent("ab")
    await rig.channel.close()
    #expect(connection.isClosed)
    #expect(await rig.channel.state == .initial)
    #expect(await rig.channel.pendingTaskCount == 0)
    await rig.sleeps(0)
    connection.emit(.reply(FolderSearchReply(id: 1, status: .ok, paths: ["/syn/late"])))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await rig.channel.state == .initial)
    _ = try await rig.searchedAndSent("ab", connections: 2)
  } // End of func closesExplicitly()

  /// A header without Spotlight, or with indexing off for the scope, is reported and no query
  /// is sent; the other scope is searched; later texts are answered from the header at once.
  @Test func reportsAHostWithoutSpotlight() async throws {
    let rig = Rig()
    await rig.search("ab", sleeps: 3)
    let connection = try await rig.opened(1)
    var header = Rig.header
    header.homeIndexing = .off
    connection.emit(.header(header))
    #expect(
      await rig.phase { $0 == .unavailable(.indexingOff) }.phase == .unavailable(.indexingOff))
    rig.clock.advance(by: .milliseconds(150))
    await rig.search("abc")
    #expect(await rig.channel.state.phase == .unavailable(.indexingOff))
    try await Task.sleep(for: .milliseconds(20))
    #expect(connection.sentLines.isEmpty)
    await rig.search("abc", scope: .disk, sleeps: 2)
    rig.clock.advance(by: .milliseconds(150))
    #expect(await rig.lines(connection, 1) == ["1 disk abc\n"])

    let other = Rig()
    await other.search("ab", sleeps: 3)
    let bare = try await other.opened(1)
    header.hasSpotlight = false
    bare.emit(.header(header))
    #expect(
      await other.phase { $0 == .unavailable(.noSpotlight) }.phase == .unavailable(.noSpotlight))
    await other.search("ab", scope: .disk)
    #expect(await other.channel.state.phase == .unavailable(.noSpotlight))
    #expect(bare.sentLines.isEmpty)
  } // End of func reportsAHostWithoutSpotlight()

  /// Too short text is idle and opens nothing; text with a control character or over 255 bytes
  /// is refused.
  @Test func refusesUnsearchableText() async throws {
    let rig = Rig()
    await rig.search("a")
    #expect(await rig.channel.state.phase == .idle)
    await rig.search("a\u{7}b")
    #expect(await rig.channel.state.phase == .refused(.controlCharacter))
    await rig.search(String(repeating: "x", count: 256))
    #expect(await rig.channel.state.phase == .refused(.tooLong))
    try await Task.sleep(for: .milliseconds(20))
    #expect(rig.transport.connections.isEmpty)
  } // End of func refusesUnsearchableText()

  /// ssh's own failure (exit 255) is classified from its standard error, as discovery does; an
  /// open that fails twice is reported with its reason.
  @Test func classifiesConnectionFailures() async throws {
    let rig = Rig()
    let host = FolderSearchHost.ssh(destination: "saturno-m4")
    await rig.search("ab", on: host, sleeps: 3)
    let refused = Data("user@example: Permission denied (publickey).\n".utf8)
    try await rig.opened(1).end(exitCode: 255, standardError: refused)
    try await rig.opened(2).end(exitCode: 255, standardError: refused)
    #expect(await rig.phase(Self.isFailed).phase == .failed(.connection(.authFailed)))

    let other = Rig()
    other.transport.failNextOpens(2, with: .couldNotStart("synthetic"))
    await other.search("ab")
    #expect(await other.phase(Self.isFailed).phase == .failed(.couldNotStart("synthetic")))
    #expect(other.transport.openedHosts.count == 2)
  } // End of func classifiesConnectionFailures()

  /// The script's error answers: no Spotlight, no home folder, a failed search, a search
  /// stopped at the host's deadline and a refused line; none reopens the script.
  @Test func reportsTheScriptsErrors() async throws {
    let cases: [(String, FolderSearchState.Phase)] = [
      ("unavailable", .unavailable(.noSpotlight)), ("home", .unavailable(.noHomeFolder)),
      ("search", .failed(.searchFailed)), ("timeout", .failed(.searchTimedOut)),
      ("text", .failed(.queryRefused("text"))),
    ]
    for (code, expected) in cases {
      let rig = Rig()
      let connection = try await rig.searchedAndSent("ab")
      connection.emit(.reply(FolderSearchReply(id: 1, status: .error(code), paths: [])))
      #expect(await rig.phase { $0 == expected }.phase == expected, "\(code)")
      #expect(!connection.isClosed)
      #expect(rig.transport.connections.count == 1)
    } // End of loop over error codes
  } // End of func reportsTheScriptsErrors()

  /// A line that cannot be written, or output that is not the script's, is a failure.
  @Test func failsOnSendAndProtocolErrors() async throws {
    let rig = Rig()
    await rig.search("ab", sleeps: 3)
    let first = try await rig.opened(1)
    first.setSendFails(true)
    first.emit(.header(Rig.header))
    await rig.sleeps(2)
    rig.clock.advance(by: .milliseconds(150))
    let second = try await rig.opened(2)
    #expect(await FolderSearchWait.until { first.isClosed })
    second.emit(.protocolError(.unexpectedRecord))
    #expect(await rig.phase(Self.isFailed).phase == .failed(.protocolError(.unexpectedRecord)))
  } // End of func failsOnSendAndProtocolErrors()

  /// The update stream gives the current state first, then each change.
  @Test func streamsUpdates() async throws {
    let rig = Rig()
    let updates = await rig.channel.updates(bufferingNewest: 8)
    var iterator = updates.makeAsyncIterator()
    #expect(await iterator.next() == .initial)
    await rig.search("ab")
    let next = await iterator.next()
    #expect(next?.text == "ab")
    #expect(next?.phase == .searching)
  }
}
