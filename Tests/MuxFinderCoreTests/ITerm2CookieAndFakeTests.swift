import Foundation
import Testing

@testable import MuxFinderCore

/// Cookie parsing and AppleScript error mapping (no AppleScript runs), and the scripted fake
/// integration later phases test against.
@Suite("iTerm2 cookie and fake integration")
struct ITerm2CookieAndFakeTests {
  /// A well-formed reply splits into cookie and key.
  @Test func parsesTheCookieReply() throws {
    let credentials = try ITerm2Credentials(
      appleScriptReply: "0123456789abcdef 01234567-89AB-CDEF-0123-456789ABCDEF")
    #expect(credentials.cookie == "0123456789abcdef")
    #expect(credentials.key == "01234567-89AB-CDEF-0123-456789ABCDEF")
  }

  /// Any other shape is refused: missing or extra tokens, extra spaces, line breaks, control
  /// characters, non-ASCII, overlong tokens.
  @Test(arguments: [
    "", "cookie", "cookie key extra", "cookie  key", " cookie key", "cookie key ",
    "cookie key\n", "cookie\tkey", "cookie key\r\nInjected: yes", "cookie k\u{0}ey",
    "cookië key", "cookie \(String(repeating: "k", count: 513))",
  ])
  func refusesMalformedReplies(reply: String) {
    #expect(throws: ITerm2Error.protocolError("iTerm2 returned a malformed cookie and key")) {
      _ = try ITerm2Credentials(appleScriptReply: reply)
    }
  }

  /// AppleScript error numbers map to typed errors; -1743 is the missing Automation permission.
  @Test func appleScriptErrorMapping() {
    #expect(AppleScriptCookieProvider.error(forAppleScriptError: -1743) == .automationDenied)
    #expect(AppleScriptCookieProvider.error(forAppleScriptError: -1744) == .automationDenied)
    #expect(AppleScriptCookieProvider.error(forAppleScriptError: -600) == .notRunning)
    #expect(AppleScriptCookieProvider.error(forAppleScriptError: -1712) == .timedOut)
    #expect(
      AppleScriptCookieProvider.error(forAppleScriptError: -2741)
        == .cookieUnavailable(appleScriptError: -2741))
  }

  /// The script source is the fixed constant from PLAN.md D1.
  @Test func scriptSourceIsStatic() {
    #expect(
      AppleScriptCookieProvider.scriptSource
        == #"tell application "iTerm2" to request cookie and key for app named "muxFinder""#)
  }

  /// The real provider refuses to run its script while iTerm2 is not running.
  @Test func providerChecksRunningFirst() async {
    let provider = AppleScriptCookieProvider(appControl: FakeAppControl(running: false))
    await #expect(throws: ITerm2Error.notRunning) { _ = try await provider.requestCredentials() }
  }

  /// Every error kind is distinct, and descriptions are single sentences without the server's
  /// own error text.
  @Test func errorDescriptions() {
    let errors: [ITerm2Error] = [
      .notRunning, .apiDisabled, .automationDenied, .cookieUnavailable(appleScriptError: -1),
      .authRejected, .protocolError("detail"), .timedOut, .disconnected,
      .connectionFailed(errno: EACCES), .requestFailed("server-text"),
      .createTabFailed(.invalidProfileName), .activateFailed(.badIdentifier),
      .tmuxRequestFailed(.invalidConnectionID), .launchFailed("detail"), .notSent(.timedOut),
      .tmuxConnectionNotOwned,
    ]
    #expect(Set(errors.map(\.kind)).count == errors.count)
    for error in errors {
      let description = error.errorDescription ?? ""
      #expect(!description.isEmpty)
      #expect(!description.contains("\n"))
      #expect(!description.contains("server-text"))
    }
    #expect(
      ITerm2Error.notSent(.disconnected).errorDescription
        == "The connection to iTerm2's API was closed; the request was not sent.")
  } // End of func errorDescriptions()

  /// The fake returns queued results, then its fallback, and logs every call with arguments.
  @Test func fakeReturnsScriptedResultsAndLogsCalls() async throws {
    var script = FakeITerm2Integration.Script()
    script.listTmuxConnections = .init(
      .success([]),
      queued: [.success([.init(connectionID: "c1", owningSessionID: "s1")]), .failure(.timedOut)])
    script.sendTmuxCommand = .init(.success("output"))
    let fake = FakeITerm2Integration(script: script)
    #expect(try await fake.listTmuxConnections().map(\.connectionID) == ["c1"])
    await #expect(throws: ITerm2Error.timedOut) { _ = try await fake.listTmuxConnections() }
    #expect(try await fake.listTmuxConnections() == [])
    #expect(try await fake.sendTmuxCommand("list-windows", connectionID: "c1") == "output")
    let request = ITerm2API.ActivateRequest(
      target: .tab("t1"), orderWindowFront: true, selectTab: true, selectSession: false)
    try await fake.activate(request)
    let close = ITerm2API.CloseRequest(target: .sessions(["s1"]), force: true)
    #expect(try await fake.close(close) == .init())
    await fake.disconnect()
    #expect(
      await fake.calls == [
        .listTmuxConnections, .listTmuxConnections, .listTmuxConnections,
        .sendTmuxCommand(command: "list-windows", connectionID: "c1"), .activate(request),
        .close(close), .disconnect,
      ])
    await fake.clearCalls()
    #expect(await fake.calls.isEmpty)
  } // End of func fakeReturnsScriptedResultsAndLogsCalls()

  /// The fake's ownership-bound tmux command checks the next listing like the real client: it
  /// answers only for a connection with that id and owner, refuses others with
  /// `tmuxConnectionNotOwned`, and reports a failed listing as `notSent`.
  @Test func fakeOwnedTmuxCommand() async throws {
    var script = FakeITerm2Integration.Script()
    script.listTmuxConnections = .init(
      .success([.init(connectionID: "c1", owningSessionID: "s1")]),
      queued: [
        .success([.init(connectionID: "c1", owningSessionID: "s2")]), .failure(.timedOut),
        .failure(.notSent(.disconnected)),
      ])
    script.sendTmuxCommand = .init(.success("output"))
    let fake = FakeITerm2Integration(script: script)
    await #expect(throws: ITerm2Error.tmuxConnectionNotOwned) {
      _ = try await fake.sendTmuxCommand("detach-client", connectionID: "c1", ownedBy: "s1")
    }
    await #expect(throws: ITerm2Error.notSent(.timedOut)) {
      _ = try await fake.sendTmuxCommand("detach-client", connectionID: "c1", ownedBy: "s1")
    }
    await #expect(throws: ITerm2Error.notSent(.disconnected)) {
      _ = try await fake.sendTmuxCommand("detach-client", connectionID: "c1", ownedBy: "s1")
    }
    await #expect(throws: ITerm2Error.tmuxConnectionNotOwned) {
      _ = try await fake.sendTmuxCommand("detach-client", connectionID: "c2", ownedBy: "s1")
    }
    let output = try await fake.sendTmuxCommand(
      "detach-client", connectionID: "c1", ownedBy: "s1")
    #expect(output == "output")
    #expect(
      await fake.calls.last
        == .sendOwnedTmuxCommand(
          command: "detach-client", connectionID: "c1", owningSessionID: "s1"))
  } // End of func fakeOwnedTmuxCommand()

  /// Like the real client, the fake refuses requests while iTerm2 is not running or its socket
  /// is missing, and `ensureRunning()` brings it up.
  @Test func fakeMirrorsTheLifecycle() async throws {
    var script = FakeITerm2Integration.Script()
    script.isRunning = false
    script.protocolVersion = "1.21"
    let fake = FakeITerm2Integration(script: script)
    await #expect(throws: ITerm2Error.notRunning) { _ = try await fake.listSessions() }
    #expect(await fake.status().error == .notRunning)
    #expect(await !fake.isRunning())
    try await fake.ensureRunning()
    #expect(await fake.isRunning())
    #expect(
      await fake.status()
        == ITerm2Status(
          isRunning: true, socketPresent: true, isConnected: true, protocolVersion: "1.21"))
    await fake.updateScript { $0.socketPresent = false }
    await #expect(throws: ITerm2Error.apiDisabled) {
      _ = try await fake.createTab(.init(profileName: "p"))
    }
    await fake.updateScript {
      $0.socketPresent = true
      $0.connectionError = .authRejected
      $0.ensureRunning = .init(.failure(.launchFailed("detail")))
    }
    #expect(await fake.status().error == .authRejected)
    await #expect(throws: ITerm2Error.launchFailed("detail")) { try await fake.ensureRunning() }
    #expect(await fake.calls.contains(.createTab(.init(profileName: "p"))))
  } // End of func fakeMirrorsTheLifecycle()

  /// The fake works through the protocol, as the app will use it.
  @Test func fakeBehindTheProtocol() async throws {
    let integration: any ITerm2Integration = FakeITerm2Integration()
    #expect(try await integration.listProfiles(properties: [], guids: []) == [])
    #expect(try await integration.listSessions() == .init())
  }

  /// The listing helpers the attach path uses: a connection's tabs in order, where a session
  /// is, and every session id including buried ones.
  @Test func listingHelpers() {
    let sessions = AttachTestSupport.sessions
    #expect(
      sessions.tabs(ofTmuxConnection: AttachTestSupport.connection).map(\.tabID) == ["t3", "t4"])
    #expect(sessions.tabs(ofTmuxConnection: "missing").isEmpty)
    let withBuried = ITerm2API.ListSessionsResponse(
      windows: [
        .init(windowID: "w1", tabs: [.init(tabID: "t1", root: AttachTestSupport.leaves(2))])
      ],
      buriedSessions: [.init(uniqueIdentifier: "buried-1")])
    #expect(withBuried.placement(ofSession: "leaf-1")?.window.windowID == "w1")
    #expect(withBuried.placement(ofSession: "buried-1") == nil)
    #expect(withBuried.allSessionIDs == ["leaf-0", "leaf-1", "buried-1"])
  } // End of func listingHelpers()

  /// Which errors guarantee a request was never sent.
  @Test func notSentErrors() {
    let notSent: [ITerm2Error] = [
      .notSent(.timedOut), .notRunning, .apiDisabled, .automationDenied,
      .cookieUnavailable(appleScriptError: 1), .authRejected, .tmuxConnectionNotOwned,
    ]
    let unknownOrAnswered: [ITerm2Error] = [
      .timedOut, .disconnected, .protocolError("x"), .connectionFailed(errno: 1),
      .requestFailed("x"), .tmuxRequestFailed(.invalidConnectionID), .launchFailed("x"),
    ]
    #expect(notSent.allSatisfy { $0.isNotSent })
    #expect(!unknownOrAnswered.contains { $0.isNotSent })
  } // End of func notSentErrors()

  /// `Tab.isTmuxTab` treats iTerm2's `"-1"` window id on ordinary tabs as "no tmux".
  @Test func tmuxTabDetection() {
    #expect(!ITerm2API.Tab(tmuxWindowID: "-1").isTmuxTab)
    #expect(!ITerm2API.Tab().isTmuxTab)
    #expect(ITerm2API.Tab(tmuxWindowID: "3").isTmuxTab)
    #expect(ITerm2API.Tab(tmuxWindowID: "-1", tmuxConnectionID: "c1").isTmuxTab)
  }
}
