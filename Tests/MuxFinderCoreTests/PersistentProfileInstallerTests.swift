import CryptoKit
import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The installer of `DynamicProfiles/muxFinder.json` (PLAN.md D26), always over a private
/// temporary folder standing in for iTerm2's (never the real one): atomic writes, no rewrite of
/// identical bytes, stale detection, removal of that one file only, refusal of links and other
/// kinds, and every other entry of the folder untouched (hashed before and after).
@Suite("Persistent profile installer")
struct PersistentProfileInstallerTests {
  /// A fixture folder: `<base>/iTerm2/DynamicProfiles`, with the user's own (synthetic) entries.
  struct Fixture {
    /// The private base folder (the caller removes it).
    let base: URL
    /// The stand-in for iTerm2's `DynamicProfiles` folder.
    let directory: URL
    /// The stand-in for muxFinder's own folder, which holds the lock (made by the first lock).
    let lockDirectory: URL
    /// An installer over it.
    let installer: PersistentProfileInstaller
  }

  /// A document for one opted-in host, running the helper at `helper`.
  static func document(
    helper: String = PersistentProfilesTests.helper,
    name: String = "This Mac"
  ) throws -> PersistentProfileDocument {
    try PersistentProfiles.document(
      for: try HostList([
        HostConfig(
          id: PersistentProfilesTests.localID, displayName: name, mode: .local,
          persistentProfileEnabled: true)
      ]),
      helperPath: helper)
  } // End of func document(helper:name:)

  /// Makes the fixture; with `siblings`, the folder holds other entries a user may have: a
  /// profile file, a hidden file, a plist, a symbolic link to a file outside, a dangling link
  /// and a subfolder with a file.
  static func makeFixture(siblings: Bool = true, createFolder: Bool = true) throws -> Fixture {
    let base = try TestSupport.makeTemporaryDirectory()
    let iTerm2 = base.appending(path: "iTerm2", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: iTerm2, withIntermediateDirectories: false)
    let directory = iTerm2.appending(path: "DynamicProfiles", directoryHint: .isDirectory)
    if createFolder {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    if siblings {
      try Data(#"{"Profiles": [{"Name": "Mine", "Guid": "mine-1"}]}"#.utf8)
        .write(to: directory.appending(path: "mine.json"))
      try Data("hidden".utf8).write(to: directory.appending(path: ".hidden"))
      try Data("<plist/>".utf8).write(to: directory.appending(path: "other.plist"))
      let outside = base.appending(path: "outside.json")
      try Data("outside".utf8).write(to: outside)
      try FileManager.default.createSymbolicLink(
        at: directory.appending(path: "linked.json"), withDestinationURL: outside)
      try FileManager.default.createSymbolicLink(
        atPath: directory.appending(path: "dangling.json").path(percentEncoded: false),
        withDestinationPath: "/nonexistent/muxfinder-test")
      let sub = directory.appending(path: "folder", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
      try Data("inner".utf8).write(to: sub.appending(path: "inner.json"))
    }
    let lockDirectory = base.appending(path: "muxFinder", directoryHint: .isDirectory)
    return Fixture(
      base: base, directory: directory, lockDirectory: lockDirectory,
      installer: PersistentProfileInstaller(directory: directory, lockDirectory: lockDirectory))
  } // End of func makeFixture(siblings:createFolder:)

  /// Every entry but `muxFinder.json` (and the folder's own mode), hashed independently of the
  /// code under test: kind, mode, inode, modification time, and a file's bytes or a link's
  /// text; a subfolder's entries the same way.
  static func siblingHashes(of directory: URL) throws -> [String: String] {
    var hashes: [String: String] = [:]
    var info = stat()
    try #require(lstat(directory.path(percentEncoded: false), &info) == 0)
    hashes["."] = "\(info.st_mode) \(info.st_uid)"
    for name in try LaunchTestSupport.names(in: directory) where name != "muxFinder.json" {
      let url = directory.appending(path: name)
      try #require(lstat(url.path(percentEncoded: false), &info) == 0)
      var line =
        "\(info.st_mode) \(info.st_ino) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
      switch info.st_mode & S_IFMT {
      case S_IFREG:
        line += " " + SHA256.hash(data: try Data(contentsOf: url)).description
      case S_IFLNK:
        line +=
          " "
          + (try FileManager.default.destinationOfSymbolicLink(
            atPath: url.path(percentEncoded: false)))
      case S_IFDIR:
        line += " " + (try siblingHashes(of: url)).sorted { $0.key < $1.key }.description
      default:
        break
      }
      hashes[name] = line
    } // End of loop over the folder's entries
    return hashes
  } // End of func siblingHashes(of:)

  /// The installed file's mode bits, or `nil`.
  static func mode(of url: URL) -> mode_t? {
    var info = stat()
    return lstat(url.path(percentEncoded: false), &info) == 0 ? info.st_mode & 0o7777 : nil
  }

  /// Install, reinstall identical, install changed, status, remove: the file holds exactly the
  /// document (0600), nothing else in the folder changes at any step, and no temporary file is
  /// left behind.
  @Test func installsAndRemovesOnlyItsFile() throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let before = try Self.siblingHashes(of: fixture.directory)
    let first = try Self.document()
    #expect(try fixture.installer.status(for: first) == .notInstalled)

    #expect(try fixture.installer.install(first) == .written)
    #expect(try Data(contentsOf: fixture.installer.fileURL) == first.data)
    #expect(Self.mode(of: fixture.installer.fileURL) == 0o600)
    #expect(try fixture.installer.status(for: first) == .current)
    #expect(try Self.siblingHashes(of: fixture.directory) == before)

    // Identical bytes: nothing is written (the same inode and modification time).
    var info = stat()
    try #require(lstat(fixture.installer.fileURL.path(percentEncoded: false), &info) == 0)
    let inode = info.st_ino
    let modified = info.st_mtimespec
    #expect(try fixture.installer.install(first) == .unchanged)
    try #require(lstat(fixture.installer.fileURL.path(percentEncoded: false), &info) == 0)
    #expect(info.st_ino == inode)
    #expect(info.st_mtimespec.tv_sec == modified.tv_sec)
    #expect(info.st_mtimespec.tv_nsec == modified.tv_nsec)

    // The helper moved: the installed file is stale, then replaced by a new file.
    let moved = try Self.document(
      helper: "/Users/tester/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch")
    #expect(try fixture.installer.status(for: moved) == .stale)
    #expect(try fixture.installer.install(moved) == .written)
    #expect(try Data(contentsOf: fixture.installer.fileURL) == moved.data)
    try #require(lstat(fixture.installer.fileURL.path(percentEncoded: false), &info) == 0)
    #expect(info.st_ino != inode)
    #expect(try fixture.installer.status(for: first) == .stale)
    #expect(try Self.siblingHashes(of: fixture.directory) == before)

    #expect(try fixture.installer.remove() == .removed)
    #expect(!LaunchTestSupport.exists(fixture.installer.fileURL))
    #expect(try fixture.installer.remove() == .notInstalled)
    #expect(try fixture.installer.status(for: moved) == .notInstalled)
    #expect(try Self.siblingHashes(of: fixture.directory) == before)
    #expect(
      try LaunchTestSupport.names(in: fixture.directory) == [
        ".hidden", "dangling.json", "folder", "linked.json", "mine.json", "other.plist",
      ])
  } // End of func installsAndRemovesOnlyItsFile()

  /// An empty document (no host opted in) removes the file; with none there it does nothing.
  @Test func emptyDocumentRemovesTheFile() throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let before = try Self.siblingHashes(of: fixture.directory)
    let empty = try PersistentProfiles.document(
      for: HostList(), helperPath: PersistentProfilesTests.helper)
    #expect(try fixture.installer.install(empty) == .nothingToRemove)
    try fixture.installer.install(try Self.document())
    #expect(try fixture.installer.status(for: empty) == .stale)
    #expect(try fixture.installer.install(empty) == .removed)
    #expect(!LaunchTestSupport.exists(fixture.installer.fileURL))
    #expect(try fixture.installer.status(for: empty) == .notInstalled)
    #expect(try Self.siblingHashes(of: fixture.directory) == before)
  } // End of func emptyDocumentRemovesTheFile()

  /// A symbolic link (to a file, or dangling) or a folder at `muxFinder.json` is refused by
  /// install, status and remove, and left exactly as it was, its target unchanged.
  @Test func refusesLinksAndOtherKinds() throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let target = fixture.base.appending(path: "target.json")
    try Data("the user's".utf8).write(to: target)
    let document = try Self.document()
    try FileManager.default.createSymbolicLink(
      at: fixture.installer.fileURL, withDestinationURL: target)
    #expect(throws: PersistentProfileInstallerError.fileIsSymbolicLink) {
      try fixture.installer.install(document)
    }
    #expect(throws: PersistentProfileInstallerError.fileIsSymbolicLink) {
      try fixture.installer.remove()
    }
    #expect(throws: PersistentProfileInstallerError.fileIsSymbolicLink) {
      try fixture.installer.status(for: document)
    }
    #expect(try Data(contentsOf: target) == Data("the user's".utf8))
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: fixture.installer.fileURL.path(percentEncoded: false))
        == target.path(percentEncoded: false))

    try FileManager.default.removeItem(at: fixture.installer.fileURL)
    try FileManager.default.createDirectory(
      at: fixture.installer.fileURL, withIntermediateDirectories: false)
    #expect(throws: PersistentProfileInstallerError.fileNotRegular) {
      try fixture.installer.install(document)
    }
    #expect(throws: PersistentProfileInstallerError.fileNotRegular) {
      try fixture.installer.remove()
    }
    var isDirectory: ObjCBool = false
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.installer.fileURL.path(percentEncoded: false), isDirectory: &isDirectory)
        && isDirectory.boolValue)
    #expect(
      try LaunchTestSupport.names(in: fixture.directory).allSatisfy { !$0.hasSuffix(".tmp") })
  } // End of func refusesLinksAndOtherKinds()

  /// The e2e harness's install never replaces a file, and its removal deletes only the file it
  /// wrote: different bytes are left alone.
  @Test func createOnlyAndExpectedRemoval() throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let users = Data(#"{"Profiles": []}"#.utf8)
    try users.write(to: fixture.installer.fileURL)
    let document = try Self.document()
    #expect(throws: PersistentProfileInstallerError.fileAlreadyExists) {
      try fixture.installer.install(document, replacing: .createOnly)
    }
    #expect(throws: PersistentProfileInstallerError.fileChanged) {
      try fixture.installer.remove(expecting: document.data)
    }
    #expect(try Data(contentsOf: fixture.installer.fileURL) == users)

    try FileManager.default.removeItem(at: fixture.installer.fileURL)
    #expect(try fixture.installer.install(document, replacing: .createOnly) == .written)
    #expect(try fixture.installer.remove(expecting: document.data) == .removed)
    #expect(!LaunchTestSupport.exists(fixture.installer.fileURL))
  } // End of func createOnlyAndExpectedRemoval()

  /// The folder: a missing one is created (0755) by an install when its parent exists, never
  /// by status or remove; a missing parent is `directoryMissing`; a linked folder or another
  /// user's is refused and nothing is written through it.
  @Test func folderRules() throws {
    let fixture = try Self.makeFixture(siblings: false, createFolder: false)
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let document = try Self.document()
    #expect(try fixture.installer.status(for: document) == .notInstalled)
    #expect(try fixture.installer.remove() == .notInstalled)
    #expect(!LaunchTestSupport.exists(fixture.directory))
    #expect(try fixture.installer.install(document) == .written)
    #expect(Self.mode(of: fixture.directory) == 0o755)

    let orphan = PersistentProfileInstaller(
      directory: fixture.base.appending(path: "missing/DynamicProfiles"),
      lockDirectory: fixture.lockDirectory)
    #expect(throws: PersistentProfileInstallerError.directoryMissing) {
      try orphan.install(document)
    }
    #expect(!LaunchTestSupport.exists(fixture.base.appending(path: "missing")))

    let real = fixture.base.appending(path: "real", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
    let linked = fixture.base.appending(path: "linked")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
    #expect(throws: PersistentProfileInstallerError.directoryIsSymbolicLink) {
      try PersistentProfileInstaller(directory: linked, lockDirectory: fixture.lockDirectory)
        .install(document)
    }
    #expect(try LaunchTestSupport.names(in: real).isEmpty)

    let foreign = PersistentProfileInstaller(
      directory: fixture.directory, lockDirectory: fixture.lockDirectory, owner: geteuid() + 1)
    #expect(throws: PersistentProfileInstallerError.directoryNotOwnedByUser) {
      try foreign.install(document)
    }
    #expect(throws: PersistentProfileInstallerError.directoryNotOwnedByUser) {
      try foreign.remove()
    }
    #expect(LaunchTestSupport.exists(fixture.installer.fileURL))
  } // End of func folderRules()

  /// A file too large to be muxFinder's is refused and left as it is.
  @Test func refusesOversizedFiles() throws {
    let fixture = try Self.makeFixture(siblings: false)
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let document = try Self.document()
    try Data(count: PersistentProfiles.maximumFileSize + 1).write(to: fixture.installer.fileURL)
    #expect(throws: PersistentProfileInstallerError.fileTooLarge) {
      try fixture.installer.install(document)
    }
    #expect(throws: PersistentProfileInstallerError.fileTooLarge) {
      try fixture.installer.remove()
    }
    #expect(
      (try? Data(contentsOf: fixture.installer.fileURL).count)
        == PersistentProfiles.maximumFileSize + 1)
  } // End of func refusesOversizedFiles()

  /// A swap that finds another entry at the name puts it back and refuses; a removal whose
  /// renamed entry is not the checked file puts it back too.
  @Test func publishPutsBackAnEntryThatTookTheName() throws {
    let fixture = try Self.makeFixture(siblings: false)
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let document = try Self.document()
    try fixture.installer.install(document)
    let directory = open(fixture.directory.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
    try #require(directory >= 0)
    defer { close(directory) }
    // The checked identity is not the file now at the name (as if another one replaced it).
    let stale = PersistentProfileInstaller.EntryIdentity(device: -1, inode: 0)
    let temporary = ".muxFinder.json.test.tmp"
    let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    try #require(descriptor >= 0)
    close(descriptor)
    #expect(throws: PersistentProfileInstallerError.fileChanged) {
      try fixture.installer.publish(temporary, replacing: stale, in: directory)
    }
    #expect(try Data(contentsOf: fixture.installer.fileURL) == document.data)
    #expect(try LaunchTestSupport.names(in: fixture.directory) == ["muxFinder.json"])
  } // End of func publishPutsBackAnEntryThatTookTheName()

  /// The swap back's own race (review of Phase 11a): a writer outside the lock publishes a
  /// newer file after the first swap. The swap back puts the entry the first swap displaced
  /// back at the name and displaces that newer file, which is kept under the hidden name
  /// (`displacedEntryKept`), never deleted; nothing else is left.
  @Test func swapBackKeepsAFileAnotherWriterPublished() throws {
    let fixture = try Self.makeFixture(siblings: false)
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let document = try Self.document()
    try fixture.installer.install(document)
    let newer = Data(#"{"Profiles": [], "Newer": true}"#.utf8)
    let staged = fixture.base.appending(path: "newer.json")
    let target = fixture.installer.fileURL
    let installer = PersistentProfileInstaller(
      directory: fixture.directory, lockDirectory: fixture.lockDirectory, owner: geteuid(),
      beforeSwappingBack: {
        // Another writer replaces whatever is at the name with its own file.
        try? newer.write(to: staged)
        _ = rename(staged.path(percentEncoded: false), target.path(percentEncoded: false))
      })
    let directory = open(fixture.directory.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
    try #require(directory >= 0)
    defer { close(directory) }
    let temporary = ".muxFinder.json.test.tmp"
    let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    try #require(descriptor >= 0)
    close(descriptor)
    // The checked identity is not the file at the name, so the first swap is undone.
    let stale = PersistentProfileInstaller.EntryIdentity(device: -1, inode: 0)
    #expect(throws: PersistentProfileInstallerError.displacedEntryKept(temporaryName: temporary)) {
      try installer.publish(temporary, replacing: stale, in: directory)
    }
    #expect(try Data(contentsOf: target) == document.data)
    #expect(try Data(contentsOf: fixture.directory.appending(path: temporary)) == newer)
    #expect(try LaunchTestSupport.names(in: fixture.directory) == [temporary, "muxFinder.json"])
  } // End of func swapBackKeepsAFileAnotherWriterPublished()

  /// Installs and removals of every muxFinder process are serialized by `profiles.lock` in
  /// muxFinder's own folder (0700, the file 0600): while another holder keeps it, an install
  /// and a removal wait, then give up (`busy`) changing nothing; reads take no lock. Once it is
  /// released both work, and the lock file stays.
  @Test func cooperatingWritersAreSerialized() throws {
    let fixture = try Self.makeFixture(siblings: false)
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let document = try Self.document()
    try fixture.installer.install(document)
    let lockFile = fixture.lockDirectory.appending(path: "profiles.lock")
    #expect(Self.mode(of: fixture.lockDirectory) == 0o700)
    #expect(Self.mode(of: lockFile) == 0o600)
    let waiting = PersistentProfileInstaller(
      directory: fixture.directory, lockDirectory: fixture.lockDirectory, owner: geteuid(),
      lockWait: .milliseconds(50))
    let moved = try Self.document(
      helper: "/Users/tester/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch")

    let holder = try fixture.installer.acquireLock()
    #expect(throws: PersistentProfileInstallerError.busy) { try waiting.install(moved) }
    #expect(throws: PersistentProfileInstallerError.busy) { try waiting.remove() }
    #expect(try waiting.installedContents() == document.data)
    #expect(try waiting.status(for: moved) == .stale)
    #expect(try LaunchTestSupport.names(in: fixture.directory) == ["muxFinder.json"])
    close(holder)

    #expect(try waiting.install(moved) == .written)
    #expect(try Data(contentsOf: fixture.installer.fileURL) == moved.data)
    #expect(try waiting.remove() == .removed)
    #expect(LaunchTestSupport.exists(lockFile))
  } // End of func cooperatingWritersAreSerialized()

  /// A lock file that is a symbolic link is refused (`lockUnavailable`), its target untouched,
  /// and nothing is written.
  @Test func refusesALinkedLockFile() throws {
    let fixture = try Self.makeFixture(siblings: false)
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try FileManager.default.createDirectory(
      at: fixture.lockDirectory, withIntermediateDirectories: false)
    let target = fixture.base.appending(path: "target")
    try Data("the user's".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: fixture.lockDirectory.appending(path: "profiles.lock"), withDestinationURL: target)
    #expect(throws: PersistentProfileInstallerError.lockUnavailable) {
      try fixture.installer.install(try Self.document())
    }
    #expect(try Data(contentsOf: target) == Data("the user's".utf8))
    #expect(try LaunchTestSupport.names(in: fixture.directory).isEmpty)
  } // End of func refusesALinkedLockFile()

  /// The app's policy (PLAN.md D26): `replaceGenerated` and `onlyIfGenerated` replace and remove
  /// only a generated document; a file of the user's at the name is `notMuxFinders` for status
  /// and refused (`fileNotMuxFinders`) by install, an empty install and removal, its bytes and
  /// every other entry unchanged, no temporary file left. A generated file from another helper
  /// path is replaced and removed.
  @Test func appPolicyChangesOnlyGeneratedFiles() throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let before = try Self.siblingHashes(of: fixture.directory)
    let users = Data(
      #"{"Profiles": [{"Name": "Mine", "Guid": "mine-1", "Tags": ["muxFinder"]}]}"#.utf8)
    try users.write(to: fixture.installer.fileURL)
    let document = try Self.document()
    let empty = try PersistentProfiles.document(
      for: HostList(), helperPath: PersistentProfilesTests.helper)
    #expect(try fixture.installer.status(for: document) == .notMuxFinders)
    #expect(try fixture.installer.status(for: empty) == .notMuxFinders)
    #expect(throws: PersistentProfileInstallerError.fileNotMuxFinders) {
      try fixture.installer.install(document, replacing: .replaceGenerated)
    }
    #expect(throws: PersistentProfileInstallerError.fileNotMuxFinders) {
      try fixture.installer.install(empty, replacing: .replaceGenerated)
    }
    #expect(throws: PersistentProfileInstallerError.fileNotMuxFinders) {
      try fixture.installer.remove(onlyIfGenerated: true)
    }
    #expect(try Data(contentsOf: fixture.installer.fileURL) == users)
    #expect(try Self.siblingHashes(of: fixture.directory) == before)
    #expect(
      try LaunchTestSupport.names(in: fixture.directory).allSatisfy { !$0.hasSuffix(".tmp") })

    // A generated file (an earlier helper path) is muxFinder's: replaced, then removed.
    try FileManager.default.removeItem(at: fixture.installer.fileURL)
    let earlier = try Self.document(
      helper: "/Users/tester/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch")
    try fixture.installer.install(earlier)
    #expect(try fixture.installer.status(for: document) == .stale)
    #expect(try fixture.installer.install(document, replacing: .replaceGenerated) == .written)
    #expect(try fixture.installer.status(for: document) == .current)
    #expect(try fixture.installer.install(empty, replacing: .replaceGenerated) == .removed)
    #expect(!LaunchTestSupport.exists(fixture.installer.fileURL))
    try fixture.installer.install(document)
    #expect(try fixture.installer.remove(onlyIfGenerated: true) == .removed)
    #expect(try fixture.installer.remove(onlyIfGenerated: true) == .notInstalled)
    #expect(try Self.siblingHashes(of: fixture.directory) == before)
  } // End of func appPolicyChangesOnlyGeneratedFiles()

  /// The automatic updates' policy (review of Phase 11c, PLAN.md D26):
  /// `updateExistingGenerated` never creates anything. No folder, or no file (also one removed
  /// after a status read it as stale), is `notInstalled` with nothing created, not even the
  /// folder; an empty document then finds nothing to remove. A stale generated file is
  /// replaced (0600) and identical bytes write nothing; an empty document removes only a
  /// generated file; a file of the user's is refused and left as it is. The other entries never
  /// change and no temporary file is left.
  @Test func updateExistingGeneratedNeverCreatesTheFile() throws {
    let document = try Self.document()
    let empty = try PersistentProfiles.document(
      for: HostList(), helperPath: PersistentProfilesTests.helper)
    let earlier = try Self.document(
      helper: "/Users/tester/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch")
    let update = PersistentProfileInstaller.ReplacePolicy.updateExistingGenerated

    let bare = try Self.makeFixture(siblings: false, createFolder: false)
    defer { try? FileManager.default.removeItem(at: bare.base) }
    #expect(try bare.installer.install(document, replacing: update) == .notInstalled)
    #expect(try bare.installer.install(empty, replacing: update) == .nothingToRemove)
    #expect(!LaunchTestSupport.exists(bare.directory))

    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let before = try Self.siblingHashes(of: fixture.directory)
    #expect(try fixture.installer.install(document, replacing: update) == .notInstalled)
    #expect(!LaunchTestSupport.exists(fixture.installer.fileURL))
    #expect(try fixture.installer.install(empty, replacing: update) == .nothingToRemove)

    // A stale file removed after the status read it (another muxFinder, or the user): the
    // update finds no file under the lock and creates none.
    try fixture.installer.install(earlier)
    #expect(try fixture.installer.status(for: document) == .stale)
    try FileManager.default.removeItem(at: fixture.installer.fileURL)
    #expect(try fixture.installer.install(document, replacing: update) == .notInstalled)
    #expect(!LaunchTestSupport.exists(fixture.installer.fileURL))

    // A stale generated file is updated; the same bytes again write nothing.
    try fixture.installer.install(earlier)
    #expect(try fixture.installer.install(document, replacing: update) == .written)
    #expect(try Data(contentsOf: fixture.installer.fileURL) == document.data)
    #expect(Self.mode(of: fixture.installer.fileURL) == 0o600)
    #expect(try fixture.installer.status(for: document) == .current)
    #expect(try fixture.installer.install(document, replacing: update) == .unchanged)

    // An empty document removes the generated file, then finds none.
    #expect(try fixture.installer.install(empty, replacing: update) == .removed)
    #expect(!LaunchTestSupport.exists(fixture.installer.fileURL))
    #expect(try fixture.installer.install(empty, replacing: update) == .nothingToRemove)

    // A file of the user's is refused, with a document or an empty one, and left as it is.
    let users = Data(
      #"{"Profiles": [{"Name": "Mine", "Guid": "mine-1", "Tags": ["muxFinder"]}]}"#.utf8)
    try users.write(to: fixture.installer.fileURL)
    #expect(throws: PersistentProfileInstallerError.fileNotMuxFinders) {
      try fixture.installer.install(document, replacing: update)
    }
    #expect(throws: PersistentProfileInstallerError.fileNotMuxFinders) {
      try fixture.installer.install(empty, replacing: update)
    }
    #expect(try Data(contentsOf: fixture.installer.fileURL) == users)
    #expect(try Self.siblingHashes(of: fixture.directory) == before)
    #expect(
      try LaunchTestSupport.names(in: fixture.directory).allSatisfy { !$0.hasSuffix(".tmp") })
  } // End of func updateExistingGeneratedNeverCreatesTheFile()

  /// What an update relies on once it has checked a file: publishing over a checked file is a
  /// swap, which fails (`fileChanged`) when that file went meanwhile (a writer outside
  /// muxFinder), creating nothing at the name and removing its temporary file.
  @Test func swapNeverCreatesTheName() throws {
    let fixture = try Self.makeFixture(siblings: false)
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let directory = open(fixture.directory.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
    try #require(directory >= 0)
    defer { close(directory) }
    let temporary = ".muxFinder.json.test.tmp"
    let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    try #require(descriptor >= 0)
    close(descriptor)
    let checked = PersistentProfileInstaller.EntryIdentity(device: -1, inode: 0)
    #expect(throws: PersistentProfileInstallerError.fileChanged) {
      try fixture.installer.publish(temporary, replacing: checked, in: directory)
    }
    #expect(!LaunchTestSupport.exists(fixture.installer.fileURL))
    #expect(try LaunchTestSupport.names(in: fixture.directory).isEmpty)
  } // End of func swapNeverCreatesTheName()
}
