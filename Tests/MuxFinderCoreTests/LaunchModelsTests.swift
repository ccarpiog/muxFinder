import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// Tests for the launch models: the token, request and result encodings, and the pure mapping
/// from exit statuses to typed failures.
@Suite("Launch models")
struct LaunchModelsTests {
  /// Canonical lowercase UUIDs are accepted and round-trip.
  @Test func acceptsCanonicalTokens() throws {
    let raw = "0f8fad5b-d9cb-469f-a165-70867728950e"
    let token = try #require(LaunchToken(raw))
    #expect(token.rawValue == raw)
    #expect(token.description == raw)
    #expect(LaunchToken(LaunchToken().rawValue) != nil)
  }

  /// Anything but the canonical lowercase form is refused before it can reach a file name.
  @Test(arguments: [
    "",
    "0F8FAD5B-D9CB-469F-A165-70867728950E",
    "0f8fad5b-d9cb-469f-a165-70867728950",
    "0f8fad5b-d9cb-469f-a165-70867728950e0",
    "{0f8fad5b-d9cb-469f-a165-70867728950e}",
    "0f8fad5bd9cb469fa16570867728950e",
    "0f8fad5b-d9cb-469f-a165-70867728950g",
    "0f8fad5b_d9cb_469f_a165_70867728950e",
    "../../../../../etc/passwd-0000000000",
    "0f8fad5b-d9cb-469f-a165-7086772895/e",
    " 0f8fad5b-d9cb-469f-a165-70867728950e",
    "0f8fad5b-d9cb-469f-a165-70867728950é",
  ])
  func refusesMalformedTokens(raw: String) {
    #expect(LaunchToken(raw) == nil)
  }

  /// A request survives JSON encoding unchanged, and the file holds the expected fields only.
  @Test func requestRoundTrip() throws {
    let request = LaunchTestSupport.request(tmuxPathOverride: "/opt/homebrew/bin/tmux")
    let data = try LaunchCoding.encoder().encode(request)
    #expect(try LaunchCoding.decoder().decode(LaunchRequest.self, from: data) == request)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(
      Set(object.keys) == [
        "createdAt", "expectedServerPID", "expectedServerStartTime", "expectedSessionCreated",
        "formatVersion", "host", "hostID", "id", "sessionID", "tmuxPathOverride",
      ]
    )
    #expect(object["host"] as? [String: String] == ["kind": "local"])
    #expect(object["id"] as? String == request.id.rawValue)
    #expect(object["sessionID"] as? String == "$3")
    #expect(object["createdAt"] as? String == "2026-10-21T16:26:40.000Z")
  } // End of func requestRoundTrip()

  /// A request built from a discovered session carries its D4 identity.
  @Test func requestFromDiscoveredSession() {
    let server = ServerIdentity(socketPath: "/private/tmp/tmux-501/default", pid: 99, startTime: 7)
    let key = SessionKey(hostID: UUID(), server: server, sessionID: sessionID("$12"))
    let session = DiscoveredSession(
      key: key,
      name: "muxfinder-test-x",
      createdAt: 8,
      windowCount: 1,
      attachedClientCount: 0,
      lastActivityAt: 9,
      clients: []
    )
    let request = LaunchRequest(
      createdAt: LaunchTestSupport.requestTime,
      host: .local,
      tmuxPathOverride: nil,
      session: session
    )
    #expect(request.hostID == key.hostID)
    #expect(request.sessionID == key.sessionID)
    #expect(request.expectedServerPID == 99)
    #expect(request.expectedServerStartTime == 7)
    #expect(request.expectedSessionCreated == 8)
    #expect(request.formatVersion == LaunchRequest.currentFormatVersion)
  } // End of func requestFromDiscoveredSession()

  /// An unknown host kind, session id or format is a decoding error or not well formed.
  @Test func refusesUnusableRequests() throws {
    let request = LaunchTestSupport.request()
    let data = try LaunchCoding.encoder().encode(request)
    let text = String(decoding: data, as: UTF8.self)
    for (from, to) in [
      (#""kind":"local""#, #""kind":"ssh""#),
      (#""sessionID":"$3""#, #""sessionID":"muxfinder-test""#),
      (#""id":"\#(request.id.rawValue)""#, #""id":"\#(request.id.rawValue.uppercased())""#),
    ] {
      let changed = Data(text.replacingOccurrences(of: from, with: to).utf8)
      #expect(throws: DecodingError.self) {
        try LaunchCoding.decoder().decode(LaunchRequest.self, from: changed)
      }
    } // End of loop over corruptions
    var badVersion = request
    badVersion.formatVersion = 2
    var badPID = request
    badPID.expectedServerPID = 0
    var badOverride = request
    badOverride.tmuxPathOverride = "tmux"
    var badTime = request
    badTime.expectedSessionCreated = -1
    #expect(request.isWellFormed)
    for unusable in [badVersion, badPID, badOverride, badTime] {
      #expect(!unusable.isWellFormed)
    }
  } // End of func refusesUnusableRequests()

  /// Results round-trip, with and without a failure, and record the helper's exit status.
  @Test func resultRoundTrip() throws {
    let start = LaunchTestSupport.requestTime
    for (termination, failure, status) in [
      (ProcessResult.Termination.exited(0), nil as LaunchFailure?, Int32(0)),
      (.exited(64), .sessionGone, 64),
      (.signaled(9), .childSignaled(9), 137),
    ] {
      let result = LaunchResult(
        id: LaunchToken(),
        helperPID: 321,
        startedAt: start,
        childStartedAt: start.addingTimeInterval(1),
        endedAt: start.addingTimeInterval(2),
        childTermination: termination,
        failure: failure
      )
      #expect(result.exitStatus == status)
      #expect(result.succeeded == (failure == nil))
      let data = try LaunchCoding.encoder().encode(result)
      #expect(try LaunchCoding.decoder().decode(LaunchResult.self, from: data) == result)
    } // End of loop over results
  } // End of func resultRoundTrip()

  /// Every failure encodes as `{"kind": …}` plus its number and decodes back.
  @Test(arguments: [
    LaunchFailure.sessionGone, .sessionChanged, .tmuxMissing, .tmuxCheckFailed, .guardUsage,
    .sshFailed(.authFailed), .usage, .requestMissing, .requestExpired, .requestUnreadable,
    .launchDirectoryUnusable, .spawnFailed(errno: ENOENT), .checkTimedOut,
    .interrupted(SIGHUP), .childSignaled(SIGHUP), .childExited(1),
  ])
  func failureCoding(failure: LaunchFailure) throws {
    let data = try LaunchCoding.encoder().encode(failure)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["kind"] as? String == failure.kind)
    #expect(try LaunchCoding.decoder().decode(LaunchFailure.self, from: data) == failure)
    #expect(!failure.explanation.isEmpty)
    #expect(!failure.explanation.contains("\n"))
  }

  /// Terminations encode with an explicit kind.
  @Test func terminationCoding() throws {
    let exited = try LaunchCoding.encoder().encode(ProcessResult.Termination.exited(3))
    #expect(String(decoding: exited, as: UTF8.self) == #"{"kind":"exited","status":3}"#)
    let signaled = try LaunchCoding.encoder().encode(ProcessResult.Termination.signaled(15))
    #expect(String(decoding: signaled, as: UTF8.self) == #"{"kind":"signaled","signal":15}"#)
    #expect(throws: DecodingError.self) {
      try LaunchCoding.decoder().decode(
        ProcessResult.Termination.self,
        from: Data(#"{"kind":"stopped","signal":17}"#.utf8)
      )
    }
  } // End of func terminationCoding()

  /// The exit status → failure mapping (PLAN.md D14).
  @Test func mapsExitStatusesToFailures() {
    let table: [(ProcessResult.Termination, LaunchFailure?)] = [
      (.exited(0), nil),
      (.exited(64), .sessionGone),
      (.exited(65), .sessionChanged),
      (.exited(66), .tmuxMissing),
      (.exited(67), .tmuxCheckFailed),
      (.exited(68), .guardUsage),
      (.exited(1), .childExited(1)),
      (.exited(2), .childExited(2)),
      (.exited(63), .childExited(63)),
      (.exited(69), .childExited(69)),
      (.exited(126), .childExited(126)),
      (.exited(127), .childExited(127)),
      (.exited(255), .childExited(255)),
      (.signaled(SIGHUP), .childSignaled(SIGHUP)),
      (.signaled(SIGKILL), .childSignaled(SIGKILL)),
    ]
    for (termination, expected) in table {
      #expect(LaunchFailure.from(termination, host: .local) == expected, "\(termination)")
    }
  } // End of func mapsExitStatusesToFailures()

  /// How the check child ended → failure (PLAN.md D14): a timeout wins, 64–68 are the guard's
  /// codes, anything else (other statuses, signals) is check failed.
  @Test func mapsCheckEndingsToFailures() {
    let table: [(ProcessResult.Termination, Bool, LaunchFailure?)] = [
      (.exited(0), false, nil),
      (.exited(64), false, .sessionGone),
      (.exited(65), false, .sessionChanged),
      (.exited(66), false, .tmuxMissing),
      (.exited(67), false, .tmuxCheckFailed),
      (.exited(68), false, .guardUsage),
      (.exited(1), false, .tmuxCheckFailed),
      (.exited(125), false, .tmuxCheckFailed),
      (.exited(127), false, .tmuxCheckFailed),
      (.signaled(SIGKILL), false, .tmuxCheckFailed),
      (.signaled(SIGTERM), true, .checkTimedOut),
      (.exited(0), true, .checkTimedOut),
      (.exited(64), true, .checkTimedOut),
    ]
    for (termination, timedOut, expected) in table {
      #expect(
        LaunchFailure.fromCheck(termination, timedOut: timedOut) == expected,
        "\(termination) \(timedOut)"
      )
    }
  } // End of func mapsCheckEndingsToFailures()

  /// Each failure's exit status: guard codes pass through, 128 + n for signals, the helper's
  /// own codes for its failures.
  @Test func failureExitStatuses() {
    let table: [(LaunchFailure, Int32)] = [
      (.sessionGone, 64), (.sessionChanged, 65), (.tmuxMissing, 66), (.tmuxCheckFailed, 67),
      (.guardUsage, 68), (.sshFailed(.other), 255), (.usage, 2), (.requestMissing, 70),
      (.requestExpired, 71), (.requestUnreadable, 72), (.launchDirectoryUnusable, 73),
      (.spawnFailed(errno: ENOENT), 74), (.checkTimedOut, 75), (.interrupted(SIGHUP), 129),
      (.interrupted(SIGTERM), 143), (.childSignaled(SIGTERM), 143), (.childExited(1), 1),
    ]
    for (failure, status) in table {
      #expect(failure.exitStatus == status, "\(failure)")
    }
    // A guard code maps back to the same failure.
    for status: Int32 in 64...68 {
      #expect(LaunchFailure.from(.exited(status), host: .local)?.exitStatus == status)
    }
  } // End of func failureExitStatuses()
}
