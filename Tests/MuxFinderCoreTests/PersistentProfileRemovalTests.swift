import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The uninstall script's profile removal (`--remove-persistent-profiles`, PLAN.md D26, D27),
/// always over private temporary folders standing in for iTerm2's `DynamicProfiles` and
/// muxFinder's own folder (never the real ones): only muxFinder's generated file is deleted,
/// anything else at `muxFinder.json` is left byte for byte, every other entry of the folder is
/// untouched, a dry run creates and changes nothing, and each outcome has its line and exit
/// status.
@Suite("Persistent profile removal")
struct PersistentProfileRemovalTests {
  /// The fixture of the installer tests: a private `DynamicProfiles` stand-in with the user's
  /// (synthetic) entries, and a lock folder that does not exist yet.
  typealias Fixture = PersistentProfileInstallerTests.Fixture

  /// A removal over the fixture's folders, as the command line builds it.
  static func removal(_ fixture: Fixture, dryRun: Bool) -> PersistentProfileRemoval {
    PersistentProfileRemoval(
      profilesDirectory: fixture.directory.path(percentEncoded: false),
      lockDirectory: fixture.lockDirectory.path(percentEncoded: false),
      dryRun: dryRun)
  }

  /// The fixture's file path, as the report prints it.
  static func path(_ fixture: Fixture) -> String {
    fixture.installer.fileURL.path(percentEncoded: false)
  }

  /// muxFinder's generated file (from an earlier build's helper path too) is removed, exit 0;
  /// every other entry of the folder is unchanged, and the lock file stays in the lock folder.
  @Test func removesTheGeneratedFileOnly() throws {
    let fixture = try PersistentProfileInstallerTests.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let earlier = try PersistentProfileInstallerTests.document(
      helper: "/Users/tester/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch")
    try fixture.installer.install(earlier)
    let siblings = try PersistentProfileInstallerTests.siblingHashes(of: fixture.directory)

    let removal = Self.removal(fixture, dryRun: false)
    let outcome = removal.run()
    #expect(outcome == .removed)
    #expect(PersistentProfileRemoval.exitStatus(for: outcome) == 0)
    #expect(
      removal.report(outcome) == "muxFinder persistent profiles: removed \(Self.path(fixture))")
    #expect(!LaunchTestSupport.exists(fixture.installer.fileURL))
    #expect(try PersistentProfileInstallerTests.siblingHashes(of: fixture.directory) == siblings)
    #expect(LaunchTestSupport.exists(fixture.lockDirectory.appending(path: "profiles.lock")))

    let again = removal.run()
    #expect(again == .notInstalled)
    #expect(PersistentProfileRemoval.exitStatus(for: again) == 0)
    #expect(
      removal.report(again)
        == "muxFinder persistent profiles: none installed at \(Self.path(fixture))")
  } // End of func removesTheGeneratedFileOnly()

  /// A `muxFinder.json` that is not a generated document (the user's own profiles, an empty
  /// object, a GUID that only looks like muxFinder's) is left byte for byte, exit 1, in a dry
  /// run and for real.
  @Test func leavesAFileThatIsNotMuxFinders() throws {
    let documents = [
      #"{"Profiles": [{"Name": "Mine", "Guid": "mine-2", "Tags": ["muxFinder"]}]}"#,
      #"{}"#,
      #"{"Profiles": [{"Guid": "muxfinder-persistent-custom", "Tags": ["muxFinder"]}]}"#,
      "not json",
    ]
    for text in documents {
      let fixture = try PersistentProfileInstallerTests.makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      try Data(text.utf8).write(to: fixture.installer.fileURL)
      let siblings = try PersistentProfileInstallerTests.siblingHashes(of: fixture.directory)
      for dryRun in [true, false] {
        let removal = Self.removal(fixture, dryRun: dryRun)
        let outcome = removal.run()
        #expect(outcome == .leftAsItIs(reason: .fileNotMuxFinders), "\(text)")
        #expect(PersistentProfileRemoval.exitStatus(for: outcome) == 1)
        #expect(
          removal.report(outcome)
            == "muxFinder persistent profiles: left \(Self.path(fixture)) as it is (not "
            + "muxFinder's generated file)")
        #expect(try Data(contentsOf: fixture.installer.fileURL) == Data(text.utf8))
        #expect(
          try PersistentProfileInstallerTests.siblingHashes(of: fixture.directory) == siblings)
      } // End of loop over dry run and real removal
    } // End of loop over the documents
  } // End of func leavesAFileThatIsNotMuxFinders()

  /// A dry run over muxFinder's generated file reports it, exit 0, and changes nothing: the
  /// file stays byte for byte and no lock folder is created.
  @Test func dryRunChangesNothing() throws {
    let fixture = try PersistentProfileInstallerTests.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let document = try PersistentProfileInstallerTests.document()
    try fixture.installer.install(document)
    try FileManager.default.removeItem(at: fixture.lockDirectory)
    let siblings = try PersistentProfileInstallerTests.siblingHashes(of: fixture.directory)

    let removal = Self.removal(fixture, dryRun: true)
    let outcome = removal.run()
    #expect(outcome == .wouldRemove)
    #expect(PersistentProfileRemoval.exitStatus(for: outcome) == 0)
    #expect(
      removal.report(outcome)
        == "muxFinder persistent profiles: would remove \(Self.path(fixture)) (muxFinder's "
        + "generated file)")
    #expect(try Data(contentsOf: fixture.installer.fileURL) == document.data)
    #expect(try PersistentProfileInstallerTests.siblingHashes(of: fixture.directory) == siblings)
    #expect(!LaunchTestSupport.exists(fixture.lockDirectory))
  } // End of func dryRunChangesNothing()

  /// No `DynamicProfiles` folder: nothing installed, exit 0, and nothing is created (neither
  /// folder), in a dry run and for real.
  @Test func noFolderCreatesNothing() throws {
    let fixture = try PersistentProfileInstallerTests.makeFixture(
      siblings: false, createFolder: false)
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    for dryRun in [true, false] {
      let outcome = Self.removal(fixture, dryRun: dryRun).run()
      #expect(outcome == .notInstalled)
      #expect(PersistentProfileRemoval.exitStatus(for: outcome) == 0)
    }
    #expect(!LaunchTestSupport.exists(fixture.directory))
    #expect(!LaunchTestSupport.exists(fixture.lockDirectory))
  } // End of func noFolderCreatesNothing()

  /// A `muxFinder.json` that is a symbolic link is left as it is (exit 1), its target unread
  /// and unchanged, even when the target holds a generated document.
  @Test func leavesALinkedFile() throws {
    let fixture = try PersistentProfileInstallerTests.makeFixture(siblings: false)
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let target = fixture.base.appending(path: "elsewhere.json")
    let document = try PersistentProfileInstallerTests.document()
    try document.data.write(to: target)
    try FileManager.default.createSymbolicLink(
      at: fixture.installer.fileURL, withDestinationURL: target)
    for dryRun in [true, false] {
      let removal = Self.removal(fixture, dryRun: dryRun)
      let outcome = removal.run()
      #expect(outcome == .leftAsItIs(reason: .fileIsSymbolicLink))
      #expect(PersistentProfileRemoval.exitStatus(for: outcome) == 1)
      #expect(removal.report(outcome).hasSuffix("as it is (a symbolic link)"))
    }
    let destination = try FileManager.default.destinationOfSymbolicLink(
      atPath: fixture.installer.fileURL.path(percentEncoded: false))
    #expect(destination == target.path(percentEncoded: false))
    #expect(try Data(contentsOf: target) == document.data)
  } // End of func leavesALinkedFile()

  /// While another muxFinder process holds the lock, the removal fails (exit 3) and deletes
  /// nothing; the line says why.
  @Test func aHeldLockFailsAndDeletesNothing() throws {
    let fixture = try PersistentProfileInstallerTests.makeFixture(siblings: false)
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let document = try PersistentProfileInstallerTests.document()
    try fixture.installer.install(document)
    let waiting = PersistentProfileInstaller(
      directory: fixture.directory, lockDirectory: fixture.lockDirectory, owner: geteuid(),
      lockWait: .milliseconds(50))
    let holder = try fixture.installer.acquireLock()
    defer { close(holder) }

    let removal = PersistentProfileRemoval(installer: waiting, dryRun: false)
    let outcome = removal.run()
    #expect(outcome == .failed(reason: .busy))
    #expect(PersistentProfileRemoval.exitStatus(for: outcome) == 3)
    #expect(
      removal.report(outcome)
        == "muxFinder persistent profiles: could not remove \(Self.path(fixture)): "
        + PersistentProfileInstallerError.busy.message)
    #expect(try Data(contentsOf: fixture.installer.fileURL) == document.data)
  } // End of func aHeldLockFailsAndDeletesNothing()

  /// Every installer error is sorted: what muxFinder never writes is left as it is, the rest
  /// fails; each left reason is a short phrase.
  @Test func sortsEveryError() {
    let left: [PersistentProfileInstallerError] = [
      .fileNotMuxFinders, .fileIsSymbolicLink, .fileNotRegular, .fileNotOwnedByUser,
      .fileTooLarge, .directoryIsSymbolicLink, .directoryNotADirectory, .directoryNotOwnedByUser,
    ]
    let failed: [PersistentProfileInstallerError] = [
      .directoryMissing, .fileAlreadyExists, .fileChanged,
      .displacedEntryKept(temporaryName: ".muxFinder.json.0.tmp"), .busy, .lockUnavailable,
      .systemCallFailed(name: "unlinkat", errno: EACCES),
    ]
    for error in left {
      #expect(PersistentProfileRemoval.outcome(for: error) == .leftAsItIs(reason: error))
      #expect(!PersistentProfileRemoval.leftReason(error).hasSuffix("."), "\(error)")
    }
    for error in failed {
      #expect(PersistentProfileRemoval.outcome(for: error) == .failed(reason: error))
    }
    #expect(PersistentProfileRemoval.exitUsage == 2)
  } // End of func sortsEveryError()

  /// Without folders the removal works on the real locations' installer (iTerm2's
  /// `DynamicProfiles` and muxFinder's own folder); nothing is run.
  @Test func defaultsToTheRealFolders() {
    let removal = PersistentProfileRemoval(profilesDirectory: nil, lockDirectory: nil, dryRun: true)
    #expect(removal.installer.directory == PersistentProfileInstaller.standardDirectory)
    #expect(removal.installer.lockDirectory == PersistentProfileInstaller.standardLockDirectory)
    #expect(removal.dryRun)
  }
}
