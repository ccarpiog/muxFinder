import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The running app's update eligibility (PLAN.md D39, I-13b2): the pure decision for every
/// reason, the report's lines (never the Team ID's value), the signature reader on this
/// process (`SecCodeCopySelf`) and on bundles from a path, the bundle folder's facts on stub
/// bundles in private folders, and, when `MUXFINDER_TEST_RELEASE_BUNDLE` names an unpacked
/// copy of a release, its Developer ID signature with the Team ID `codesign -dv` reports.
@Suite("Update eligibility")
struct UpdateEligibilityTests {
  /// Shorthand.
  typealias Support = UpdateInstallTestSupport

  /// A Team ID for the facts.
  static let team = UpdateVerifyTestSupport.team
  /// An identity on device 7.
  static let identity = UpdateBundleIdentity(device: 7, inode: 42)

  /// Facts of an eligible copy; `change` alters them.
  static func facts(_ change: (inout UpdateEligibilityFacts) -> Void = { _ in })
    -> UpdateEligibilityFacts
  {
    var facts = UpdateEligibilityFacts(
      signing: .read(isDeveloperID: true, team: team),
      bundle: UpdateInstalledBundleFacts(
        path: "/Applications/muxFinder.app", identity: identity, isOwnedByUser: true,
        isBundleWritable: true, isParentWritable: true, shortVersion: "0.4.0", build: "5"),
      stagingRoot: .usable(device: 7))
    change(&facts)
    return facts
  } // End of static func facts(_:)

  /// Eligible facts give the install with the team, path, identity and build.
  @Test func eligibleRecordsTheInstall() {
    let decision = UpdateEligibility.decide(Self.facts())
    #expect(
      decision
        == .eligible(
          UpdateEligibleInstall(
            team: Self.team, bundlePath: "/Applications/muxFinder.app", identity: Self.identity,
            runningBuild: "5", runningVersion: UpdateVersion("0.4.0"))))
    let missingRoot = UpdateEligibility.decide(Self.facts { $0.stagingRoot = .missing(device: 7) })
    #expect(missingRoot == UpdateEligibility.decide(Self.facts()))
  }

  /// Each fact that refuses gives its reason, in the decision's order, as a phrase starting
  /// in lowercase with no path or Team ID.
  @Test func eachReason() {
    let team = Self.team
    let cases: [(String, UpdateEligibilityFacts)] = [
      ("signatureUnreadable", Self.facts { $0.signing = .unreadable(status: -1) }),
      ("notDeveloperID", Self.facts { $0.signing = .read(isDeveloperID: false, team: team) }),
      ("notDeveloperID", Self.facts { $0.signing = .read(isDeveloperID: false, team: nil) }),
      ("signatureUnreadable", Self.facts { $0.signing = .read(isDeveloperID: true, team: nil) }),
      ("translocated", Self.facts { $0.bundle.isTranslocated = true }),
      ("bundleUnusable.symbolicLinkOnPath", Self.facts { $0.bundle.problem = .symbolicLinkOnPath }),
      ("bundleUnusable.executableOutside", Self.facts { $0.bundle.problem = .executableOutside }),
      ("bundleUnusable.unreadable.5", Self.facts { $0.bundle.identity = nil }),
      ("readOnlyVolume", Self.facts { $0.bundle.isReadOnlyVolume = true }),
      ("notOwnedByUser", Self.facts { $0.bundle.isOwnedByUser = false }),
      ("notWritable", Self.facts { $0.bundle.isBundleWritable = false }),
      ("notWritable", Self.facts { $0.bundle.isParentWritable = false }),
      ("runningBuildUnknown", Self.facts { $0.bundle.build = nil }),
      ("runningBuildUnknown", Self.facts { $0.bundle.build = "02" }),
      ("runningBuildUnknown", Self.facts { $0.bundle.build = "1.2" }),
      ("stagingRootUnusable.notPrivate", Self.facts { $0.stagingRoot = .unusable(.notPrivate) }),
      ("differentVolume", Self.facts { $0.stagingRoot = .usable(device: 8) }),
      ("differentVolume", Self.facts { $0.stagingRoot = .missing(device: 9) }),
    ]
    for (code, facts) in cases {
      guard case .notEligible(let reason) = UpdateEligibility.decide(facts) else {
        Issue.record("eligible for \(code)")
        continue
      }
      #expect(reason.code == code)
      #expect(reason.reason.first?.isLowercase == true, "\(code)")
      #expect(!reason.reason.contains("/") && !reason.reason.contains(team.value))
    } // End of loop over the refusing facts
  } // End of func eachReason()

  /// The signature is decided first: a development build on a read-only, translocated volume is
  /// "not Developer ID".
  @Test func signatureComesFirst() {
    let facts = Self.facts {
      $0.signing = .read(isDeveloperID: false, team: Self.team)
      $0.bundle.isTranslocated = true
      $0.bundle.isReadOnlyVolume = true
      $0.stagingRoot = .unusable(.symbolicLinkOnPath)
    }
    #expect(UpdateEligibility.decide(facts) == .notEligible(.notDeveloperID))
  }

  /// The report: the verdict, then the facts, every line prefixed, never the Team ID's value or
  /// a path.
  @Test func reportLines() {
    let eligible = UpdateEligibilityReport.lines(Self.facts())
    #expect(eligible.allSatisfy { $0.hasPrefix(UpdateEligibilityReport.prefix) })
    #expect(eligible.first == UpdateEligibilityReport.prefix + "eligible")
    #expect(eligible.contains(UpdateEligibilityReport.prefix + "Team ID: present"))
    #expect(eligible.contains(UpdateEligibilityReport.prefix + "same volume: yes"))
    #expect(eligible.contains(UpdateEligibilityReport.prefix + "running version 0.4.0 build 5"))
    #expect(!eligible.joined().contains(Self.team.value))
    #expect(!eligible.joined().contains("/Applications"))
    let development = UpdateEligibilityReport.lines(
      Self.facts {
        $0.signing = .read(isDeveloperID: false, team: Self.team)
        $0.stagingRoot = .missing(device: 7)
      })
    #expect(
      development.first
        == UpdateEligibilityReport.prefix
        + "not eligible (notDeveloperID: this copy isn't signed with a Developer ID)")
    #expect(development.contains(UpdateEligibilityReport.prefix + "Developer ID: no"))
    #expect(
      development.contains(
        UpdateEligibilityReport.prefix + "update folder: not created yet (an update creates it)"))
    #expect(!development.joined().contains(Self.team.value))
    let unreadable = UpdateEligibilityReport.lines(
      Self.facts { $0.signing = .unreadable(status: -67062) })
    #expect(unreadable.contains(UpdateEligibilityReport.prefix + "Team ID: unknown"))
  } // End of func reportLines()

  /// The reader on this process's own signature (`SecCodeCopySelf`): it reads, and the test
  /// runner (signed by Apple, not with a Developer ID) is not Developer ID.
  @Test func readsOwnSignature() {
    guard case .read(let isDeveloperID, _) = UpdateSigningReader.readSelf() else {
      Issue.record("the test runner's signature was not read")
      return
    }
    #expect(!isDeveloperID)
  }

  /// The reader on bundles from a path: an unsigned stub and an ad hoc signed one are read and
  /// are not Developer ID, with no Team ID; a folder that is no code is unreadable.
  @Test func readsBundlesFromAPath() async throws {
    let folder = try UpdateTestSupport.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let unsigned = folder.appending(path: "unsigned/muxFinder.app", directoryHint: .isDirectory)
    try UpdateVerifyTestSupport.makeApp(at: unsigned)
    #expect(
      UpdateSigningReader.read(bundleAt: Support.path(unsigned))
        == .read(isDeveloperID: false, team: nil))
    let adHoc = folder.appending(path: "adhoc/muxFinder.app", directoryHint: .isDirectory)
    try UpdateVerifyTestSupport.makeApp(at: adHoc)
    try await UpdateVerifyTestSupport.adHocSign(adHoc)
    #expect(
      UpdateSigningReader.read(bundleAt: Support.path(adHoc))
        == .read(isDeveloperID: false, team: nil))
    guard case .unreadable = UpdateSigningReader.read(bundleAt: Support.path(folder) + "/missing")
    else {
      Issue.record("a missing bundle was read")
      return
    }
  } // End of func readsBundlesFromAPath()

  /// The real check on an unpacked release copy, only when `MUXFINDER_TEST_RELEASE_BUNDLE`
  /// names one (an absolute path to its `muxFinder.app`): Developer ID, and the Team ID equal to
  /// the one `codesign -dv` reports for it, compared here and never printed.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["MUXFINDER_TEST_RELEASE_BUNDLE"] != nil))
  func readsAReleaseCopy() async throws {
    let bundle = try #require(ProcessInfo.processInfo.environment["MUXFINDER_TEST_RELEASE_BUNDLE"])
    let reading = UpdateSigningReader.read(bundleAt: bundle)
    guard case .read(let isDeveloperID, let team) = reading else {
      Issue.record("the release copy's signature was not read")
      return
    }
    #expect(isDeveloperID)
    let result = try await PosixSpawnProcessRunner().run(
      ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["-dv", bundle],
        environment: ["PATH": ProcessEnvironment.systemSearchPath], timeout: .seconds(60)))
    let output = String(decoding: result.standardError + result.standardOutput, as: UTF8.self)
    let reported = output.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
      .map { String($0.dropFirst("TeamIdentifier=".count)) }
    let same = team != nil && reported != nil && team?.value == reported
    #expect(same, "the reader's Team ID differs from codesign's (values not shown)")
  } // End of func readsAReleaseCopy()

  /// The bundle folder's facts on a stub in a private folder: identity, owner, write access,
  /// versions, the running executable inside; the problems of a link on the path, a missing
  /// bundle, a foreign identifier, an executable elsewhere; translocation by path component.
  @Test func readsBundleFolders() throws {
    let folder = try UpdateTestSupport.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let app = try Support.makeInstalledApp(in: folder)
    let facts = UpdateInstalledBundleReader.read(
      bundlePath: Support.path(app), executablePath: Support.executablePath(of: app))
    #expect(facts.problem == nil)
    #expect(facts.identity == (try UpdateVerifyTestSupport.identity(of: app)))
    #expect(facts.isOwnedByUser && facts.isBundleWritable && facts.isParentWritable)
    #expect(!facts.isTranslocated && !facts.isReadOnlyVolume)
    #expect(facts.shortVersion == "0.2.0" && facts.build == "2")
    let other = UpdateInstalledBundleReader.read(
      bundlePath: Support.path(app), executablePath: "/usr/bin/true")
    #expect(other.problem == .executableOutside)
    let none = UpdateInstalledBundleReader.read(bundlePath: Support.path(app), executablePath: nil)
    #expect(none.problem == .executableOutside)
    let foreign = UpdateInstalledBundleReader.read(
      bundlePath: Support.path(app), executablePath: Support.executablePath(of: app),
      owner: geteuid() + 1)
    #expect(!foreign.isOwnedByUser)
    let link = folder.appending(path: "Linked")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: app.deletingLastPathComponent())
    let linked = UpdateInstalledBundleReader.read(
      bundlePath: Support.path(link) + "/muxFinder.app",
      executablePath: Support.executablePath(of: app))
    #expect(linked.problem == .symbolicLinkOnPath)
    let missing = UpdateInstalledBundleReader.read(
      bundlePath: Support.path(folder) + "/Applications/Other.app", executablePath: nil)
    #expect(missing.problem == .missing)
    #expect(
      UpdateInstalledBundleReader.read(
        bundlePath: "Applications/muxFinder.app", executablePath: nil
      )
      .problem == .notAPlainAbsolutePath)
    try UpdateVerifyTestSupport.infoPlist(identifier: "com.example.other").write(
      to: app.appending(path: "Contents/Info.plist"))
    let renamed = UpdateInstalledBundleReader.read(
      bundlePath: Support.path(app), executablePath: Support.executablePath(of: app))
    #expect(renamed.problem == .identifierMismatch)
    #expect(
      UpdateInstalledBundleReader.isTranslocated(
        "/private/var/folders/x/AppTranslocation/y/d/muxFinder.app"))
    #expect(
      !UpdateInstalledBundleReader.isTranslocated("/Applications/AppTranslocationX/muxFinder.app"))
  } // End of func readsBundleFolders()

  /// A parent folder the user cannot write makes the copy not writable (and so not
  /// eligible), and the facts reader with a Developer ID reading and an update folder on the
  /// same volume is otherwise eligible; nothing is created by reading.
  @Test func eligibilityOverStubFolders() throws {
    let folder = try UpdateTestSupport.makePrivateFolder()
    defer {
      _ = chmod(Support.path(folder) + "/Applications", 0o700)
      try? FileManager.default.removeItem(at: folder)
    }
    let app = try Support.makeInstalledApp(in: folder)
    let root = UpdateStagingRoot(path: Support.path(folder) + "/support/muxFinder/update")
    let eligibility = StubUpdateEligibility(
      bundlePath: Support.path(app), executablePath: Support.executablePath(of: app),
      signing: .read(isDeveloperID: true, team: Self.team), root: root)
    guard case .eligible(let install) = eligibility.check() else {
      Issue.record("the stub copy is not eligible")
      return
    }
    #expect(install.runningBuild == "2" && install.team == Self.team)
    #expect(!FileManager.default.fileExists(atPath: Support.path(folder) + "/support"))
    #expect(chmod(Support.path(folder) + "/Applications", 0o500) == 0)
    #expect(eligibility.check() == .notEligible(.notWritable))
    #expect(!FileManager.default.fileExists(atPath: Support.path(folder) + "/support"))
  } // End of func eligibilityOverStubFolders()
}

extension UpdateBundleIdentity {
  /// An identity of these values (tests only).
  init(device: Int64, inode: UInt64) {
    var info = stat()
    info.st_dev = dev_t(device)
    info.st_ino = ino_t(inode)
    self.init(info)
  }
}
