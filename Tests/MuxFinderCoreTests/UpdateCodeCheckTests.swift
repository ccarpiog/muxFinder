import Darwin
import Foundation
import Security
import Testing

@testable import MuxFinderCore

/// The code check (PLAN.md D39, I-13b1): the Team ID's validation before it enters the
/// requirement, the requirement's clauses, and `SecurityUpdateCodeChecker` on stub apps built
/// in private folders and signed only ad hoc (`codesign -s - --force`, never a keychain
/// identity, never `--timestamp`): ad hoc is not Developer ID, another identifier is not
/// ours, an unsigned or tampered bundle is not valid, and the `notarized` clause alone fails
/// for an ad hoc bundle. The stapled 0.2.0 release passing is the real zip-mode run's
/// (`docs/TESTING.md` *Phase I-13b1*).
@Suite("Update code check")
struct UpdateCodeCheckTests {
  /// Shorthand.
  typealias Support = UpdateVerifyTestSupport

  /// Only 10 uppercase ASCII letters or digits make a Team ID.
  @Test func teamIDValidation() {
    #expect(UpdateTeamID("ABCDE12345")?.value == "ABCDE12345")
    #expect(UpdateTeamID("0123456789") != nil)
    #expect(UpdateTeamID("ZZZZZZZZZZ") != nil)
    for bad in [
      "", "ABCDE1234", "ABCDE123456", "abcde12345", "ABCDe12345", "ABCDE 1234", "ABCDE\"1234",
      "ABCDÉ1234", "ABCDE-1234", "ABCDE1234\n", "ABCDE1234\0", "ＡBCDE12345", "\"ABCDE1234",
      "ABCDE\") or (\"", "ABC\\DE1234",
    ] {
      #expect(UpdateTeamID(bad) == nil, "\(bad)")
    } // End of loop over bad Team IDs
  } // End of func teamIDValidation()

  /// The requirement's text, and every clause compiles.
  @Test func requirementText() {
    let team = Support.team
    #expect(
      UpdateCodeRequirement.full(team)
        == "identifier \"cc.carpio.muxfinder\" and anchor apple generic and certificate "
        + "1[field.1.2.840.113635.100.6.2.6] exists and certificate "
        + "leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "
        + "\"ABCDE12345\" and notarized")
    for text in [
      UpdateCodeRequirement.identifierClause, UpdateCodeRequirement.developerIDClause,
      UpdateCodeRequirement.teamClause(team), UpdateCodeRequirement.notarizedClause,
      UpdateCodeRequirement.full(team),
    ] {
      var requirement: SecRequirement?
      #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
    } // End of loop over the clauses
    let flags = SecurityUpdateCodeChecker.validityFlags.rawValue
    #expect(flags & UInt32(kSecCSStrictValidate) != 0)
    #expect(flags & UInt32(kSecCSCheckAllArchitectures) != 0)
    #expect(flags & UInt32(kSecCSCheckNestedCode) != 0)
    #expect(flags & UInt32(kSecCSRestrictSymlinks) != 0)
    #expect(flags & UInt32(kSecCSRestrictToAppLike) != 0)
    #expect(flags & SecCSFlags.enforceRevocationChecks.rawValue == 0)
    #expect(flags & UInt32(kSecCSAllowNetworkAccess) == 0)
  } // End of func requirementText()

  /// A stub app in a new private folder, signed ad hoc when `sign`; returns its path and the
  /// folder to remove.
  static func stub(
    info: Data = Support.infoPlist(), sign: Bool = true
  ) async throws -> (path: String, folder: URL) {
    let folder = try UpdateTestSupport.makePrivateFolder()
    do {
      let app = folder.appending(path: "muxFinder.app", directoryHint: .isDirectory)
      try Support.makeApp(at: app, info: info)
      if sign { try await Support.adHocSign(app) }
      return (folder.appending(path: "muxFinder.app").path(percentEncoded: false), folder)
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
  } // End of static func stub(info:sign:)

  /// An ad hoc signed stub with our identifier fails as not Developer ID; with another
  /// identifier as not ours.
  @Test func adHocStubIsNotDeveloperID() async throws {
    let ours = try await Self.stub()
    defer { try? FileManager.default.removeItem(at: ours.folder) }
    #expect(
      await SecurityUpdateCodeChecker().check(bundleAt: ours.path, team: Support.team)
        == .signatureFailed(.notDeveloperID))
    let other = try await Self.stub(info: Support.infoPlist(identifier: "cc.example.other"))
    defer { try? FileManager.default.removeItem(at: other.folder) }
    #expect(
      await SecurityUpdateCodeChecker().check(bundleAt: other.path, team: Support.team)
        == .signatureFailed(.notOurs))
  } // End of func adHocStubIsNotDeveloperID()

  /// The `notarized` clause alone fails for an ad hoc bundle (the other half of the proof:
  /// it passes for the stapled 0.2.0 release).
  @Test func notarizedClauseFailsAdHoc() async throws {
    let stub = try await Self.stub()
    defer { try? FileManager.default.removeItem(at: stub.folder) }
    guard
      case .success(false) = SecurityUpdateCodeChecker.bundle(
        atPath: stub.path, satisfies: UpdateCodeRequirement.notarizedClause)
    else {
      Issue.record("the notarized clause did not fail for an ad hoc bundle")
      return
    }
    guard
      case .success(true) = SecurityUpdateCodeChecker.bundle(
        atPath: stub.path, satisfies: UpdateCodeRequirement.identifierClause)
    else {
      Issue.record("the identifier clause failed for the stub")
      return
    }
  } // End of func notarizedClauseFailsAdHoc()

  /// An unsigned bundle and a tampered one (a sealed resource changed after signing) are not
  /// valid; a missing path cannot be read.
  @Test func unsignedAndTamperedAreInvalid() async throws {
    let unsigned = try await Self.stub(sign: false)
    defer { try? FileManager.default.removeItem(at: unsigned.folder) }
    let unsignedResult = await SecurityUpdateCodeChecker().check(
      bundleAt: unsigned.path, team: Support.team)
    switch unsignedResult {
    case .signatureFailed(.unsigned), .signatureFailed(.invalid): break
    default: Issue.record("an unsigned bundle: \(unsignedResult)")
    }
    let tampered = try await Self.stub()
    defer { try? FileManager.default.removeItem(at: tampered.folder) }
    try Data("changed\n".utf8).write(
      to: URL(fileURLWithPath: tampered.path).appending(path: "Contents/Resources/note.txt"))
    let tamperedResult = await SecurityUpdateCodeChecker().check(
      bundleAt: tampered.path, team: Support.team)
    guard case .signatureFailed(.invalid) = tamperedResult else {
      Issue.record("a tampered bundle: \(tamperedResult)")
      return
    }
    let missing = await SecurityUpdateCodeChecker().check(
      bundleAt: unsigned.folder.appending(path: "nothing.app").path(percentEncoded: false),
      team: Support.team)
    guard case .signatureFailed(.unreadable) = missing else {
      Issue.record("a missing bundle: \(missing)")
      return
    }
  } // End of func unsignedAndTamperedAreInvalid()

  /// Through the verifier with the real checker: an ad hoc signed stub in a zip fails the
  /// signature step as not Developer ID, the steps after it do not run, nothing is left.
  @Test func verifierRefusesAnAdHocStub() async throws {
    let zip = try await Support.makeZip { source in
      let app = source.appending(path: "muxFinder.app", directoryHint: .isDirectory)
      try Support.makeApp(at: app)
      try await Support.adHocSign(app)
    }
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }
    let report = await UpdateVerifier(staging: staging, team: Support.team, runningBuild: "2")
      .verifyLocalZip(
        atPath: zip.url.path(percentEncoded: false), sha256: Support.sha256(zip.data),
        expectedVersion: UpdateVersion("0.3.0")!)
    #expect(report.failure == .signature(.notDeveloperID))
    #expect(report.verdict(of: .shape) == .passed)
    #expect(report.verdict(of: .notarization) == .notRun)
    #expect(report.verdict(of: .versions) == .notRun)
    #expect(report.failure?.reason == "the app isn't signed with a Developer ID certificate")
    #expect(try Support.names(folder).isEmpty)
  } // End of func verifierRefusesAnAdHocStub()

  /// Reasons name no team, path or host.
  @Test func reasons() {
    let problems: [UpdateSignatureProblem] = [
      .unreadable(-1), .unsigned, .invalid(-67061), .notOurs, .notDeveloperID, .otherTeam,
      .requirementUnusable(-1),
    ]
    for problem in problems {
      #expect(!problem.reason.contains("/"))
      #expect(!problem.reason.contains(Support.team.value))
    }
    #expect(UpdateSignatureProblem.otherTeam.reason == "the app is signed by another developer")
    #expect(
      UpdateNotarizationProblem.notNotarized(-67050).reason == "the app isn't notarized by Apple")
    #expect(UpdateNotarizationProblem.notNotarized(-67050).code == "notNotarized")
  } // End of func reasons()
}
