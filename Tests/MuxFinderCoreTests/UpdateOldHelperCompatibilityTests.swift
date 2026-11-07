import Foundation
import Testing

@testable import MuxFinderCore

/// What an update must keep working across versions (PLAN.md D39, I-13b2, D14): a launch
/// request written by a 0.2.0 or 0.3.0 app (whose `LaunchRequest`, identical in both releases,
/// has no `terminal` or `keepsMinimumLifetime`) is still an iTerm2 attach for the current
/// helper, and the current result file has exactly the fields those releases' helpers write, so
/// either side reads the other's.
@Suite("Update old helper compatibility")
struct UpdateOldHelperCompatibilityTests {
  /// Every field a 0.2.0 or 0.3.0 app's `LaunchRequest` encodes (the optional ones only when
  /// set).
  static let oldRequestKeys: Set<String> = [
    "formatVersion", "id", "createdAt", "host", "hostID", "tmuxPathOverride", "sessionID",
    "expectedServerPID", "expectedServerStartTime", "expectedSessionCreated",
    "testLaunchDelaySeconds", "testSuppressDisinter", "detachOtherClients",
  ]
  /// Every field a 0.2.0 or 0.3.0 helper's `LaunchResult` encodes.
  static let oldResultKeys: Set<String> = [
    "formatVersion", "id", "helperPID", "startedAt", "childStartedAt", "endedAt",
    "childTermination", "failure", "exitStatus",
  ]

  /// A request in the older shape (no `terminal`, a Move here) decodes as a well-formed iTerm2
  /// attach with no plain-mode field.
  @Test func oldRequestsAreITerm2Attaches() throws {
    let request = LaunchTestSupport.request(tmuxPathOverride: "/opt/homebrew/bin/tmux")
    let data = try LaunchCoding.encoder().encode(request)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "terminal")
    object.removeValue(forKey: "keepsMinimumLifetime")
    object["detachOtherClients"] = true
    #expect(Set(object.keys).isSubset(of: Self.oldRequestKeys))
    let old = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let decoded = try LaunchCoding.decoder().decode(LaunchRequest.self, from: old)
    #expect(decoded.terminal == .iterm2)
    #expect(decoded.keepsMinimumLifetime == nil)
    #expect(decoded.detachOtherClients == true)
    #expect(decoded.isWellFormed)
    #expect(decoded.id == request.id && decoded.sessionID == request.sessionID)
  } // End of func oldRequestsAreITerm2Attaches()

  /// The current result, with every field set, has exactly the older releases' fields, and one
  /// written with only those fields decodes.
  @Test func resultsKeepTheOldFields() throws {
    let start = LaunchTestSupport.requestTime
    let result = LaunchResult(
      id: LaunchToken(), helperPID: 321, startedAt: start,
      childStartedAt: start.addingTimeInterval(1), endedAt: start.addingTimeInterval(2),
      childTermination: .exited(0), failure: .sessionGone)
    let data = try LaunchCoding.encoder().encode(result)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == Self.oldResultKeys)
    #expect(try LaunchCoding.decoder().decode(LaunchResult.self, from: data) == result)
  }
}
