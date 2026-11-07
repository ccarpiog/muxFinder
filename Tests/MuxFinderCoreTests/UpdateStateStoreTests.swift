import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// `UpdateStateStore` (PLAN.md D39) on private folders only: missing and invalid files read as
/// never checked, a round trip, an invalid file replaced at the next save, a symbolic link or
/// other non-regular file never read, written through or replaced, and the probe's
/// `existingPrivate` policy never changing a folder.
@Suite("Update state store")
struct UpdateStateStoreTests {
  /// One store on a private folder.
  struct Fixture {
    /// The store.
    let store: UpdateStateStore
    /// The private base folder (the caller removes it).
    let base: URL
    /// The store's folder (not created).
    let directory: URL
    /// The store's file.
    let file: URL
  }

  /// A store whose folder is `muxFinder` in a new private base folder.
  static func makeFixture() throws -> Fixture {
    let base = try TestSupport.makeTemporaryDirectory()
    let directory = base.appending(path: "muxFinder", directoryHint: .isDirectory)
    let file = directory.appending(path: UpdateStateStore.fileName)
    return Fixture(
      store: UpdateStateStore(fileURL: file), base: base, directory: directory, file: file)
  }

  /// Writes `text` as the fixture's file with `mode`, creating the folder (0700).
  static func writeFile(_ text: String, in fixture: Fixture, mode: mode_t = 0o600) throws {
    if !LaunchTestSupport.exists(fixture.directory) {
      try FileManager.default.createDirectory(
        at: fixture.directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
    try HostStoreTests.writeFile(Data(text.utf8), to: fixture.file, mode: mode)
  }

  /// A full state with whole-second dates.
  static func fullState() -> UpdateState {
    let base = ManualUpdateClock.baseDate
    return UpdateState(
      lastSuccessfulCheck: base, lastAttempt: base.addingTimeInterval(30),
      etag: "W/\"abc\"", keptRelease: UpdateTestSupport.release(),
      noticeSeenVersion: UpdateVersion("0.3.0"),
      rateLimitedUntil: base.addingTimeInterval(3600.5))
  }

  /// No folder or no file: never checked, nothing created.
  @Test func missingReadsAsNeverChecked() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    #expect(
      await fixture.store.load() == UpdateStateLoadResult(state: UpdateState(), found: .missing))
    #expect(!LaunchTestSupport.exists(fixture.directory))
    try FileManager.default.createDirectory(
      at: fixture.directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o755])
    #expect(await fixture.store.load().found == .missing)
    #expect(try LaunchTestSupport.names(in: fixture.directory).isEmpty)
    #expect(try LaunchTestSupport.permissions(of: fixture.directory) == 0o755)
  } // End of func missingReadsAsNeverChecked()

  /// A save writes a private file (0600, folder 0700) that loads back equal.
  @Test func roundTrip() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try await fixture.store.save(Self.fullState())
    #expect(try LaunchTestSupport.permissions(of: fixture.file) == 0o600)
    #expect(try LaunchTestSupport.permissions(of: fixture.directory) == 0o700)
    #expect(try LaunchTestSupport.names(in: fixture.directory) == [UpdateStateStore.fileName])
    let loaded = await UpdateStateStore(fileURL: fixture.file).load()
    #expect(loaded.found == .saved)
    #expect(loaded.state == Self.fullState())
    let object = try PreferencesStoreTests.object(at: fixture.file)
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["lastSuccessfulCheck"] as? String == "2027-01-15T08:00:00.000Z")
    #expect(object["noticeSeenVersion"] as? String == "0.3.0")
    let release = try #require(object["release"] as? [String: Any])
    #expect(release["tag"] as? String == "v0.3.0")
    #expect(
      (release["asset"] as? [String: Any])?["sha256"] as? String
        == UpdateTestSupport.normalizedDigest)
    try await fixture.store.save(UpdateState())
    #expect(
      await fixture.store.load() == UpdateStateLoadResult(state: UpdateState(), found: .saved))
    let pageOnly = UpdateState(keptRelease: UpdateTestSupport.release(withAsset: false))
    try await fixture.store.save(pageOnly)
    #expect(await fixture.store.load().state == pageOnly)
  } // End of func roundTrip()

  /// Every invalid file reads as never checked and is replaced by the next save, with no
  /// backup.
  @Test func invalidFilesAreReplaced() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let good = String(decoding: UpdateStateCoding.encode(Self.fullState())!, as: UTF8.self)
    let tag = "\"tag\" : \"v0.3.0\""
    let invalid: [(String, String)] = [
      ("not json", "malformed"), ("[]", "malformed"), ("{}", "malformed"),
      ("{\"schemaVersion\": 2}", "otherSchemaVersion"),
      ("{\"schemaVersion\": 0}", "otherSchemaVersion"),
      ("{\"schemaVersion\": \"1\"}", "malformed"),
      ("{\"schemaVersion\": 1, \"etag\": 5}", "malformed"),
      ("{\"schemaVersion\": 1, \"etag\": \"a\\nb\"}", "invalidValue"),
      ("{\"schemaVersion\": 1, \"lastAttempt\": \"yesterday\"}", "invalidValue"),
      ("{\"schemaVersion\": 1, \"noticeSeenVersion\": \"0.03.0\"}", "invalidValue"),
      (good.replacingOccurrences(of: tag, with: "\"tag\" : \"V0.3.0\""), "invalidValue"),
      (
        good.replacingOccurrences(
          of: "https://github.com/ccarpiog/muxFinder/releases/tag/v0.3.0",
          with: "https://evil.example/x"), "invalidValue"
      ),
      (good.replacingOccurrences(of: "download/v0.3.0", with: "download/v0.2.0"), "invalidValue"),
      (
        good.replacingOccurrences(
          of: UpdateTestSupport.normalizedDigest,
          with: UpdateTestSupport.normalizedDigest.uppercased()), "invalidValue"
      ),
      (good.replacingOccurrences(of: "6123456", with: "0"), "invalidValue"),
      (good.replacingOccurrences(of: "6123456", with: "99999999999"), "invalidValue"),
      (
        "{\"schemaVersion\": 1, \"release\": {\"tag\": \"v0.3.0\", \"page\": "
          + "\"https://github.com/ccarpiog/muxFinder/releases/tag/v0.3.0\"}}", "invalidValue"
      ),
      (
        "{\"schemaVersion\": 1, \"release\": {\"tag\": \"v0.3.0\", \"page\": "
          + "\"https://github.com/ccarpiog/muxFinder/releases/tag/v0.3.0\", "
          + "\"assetProblem\": \"stolen\"}}", "invalidValue"
      ),
    ]
    #expect(good.contains(tag))
    for (text, reason) in invalid {
      try Self.writeFile(text, in: fixture)
      let loaded = await fixture.store.load()
      #expect(
        loaded == UpdateStateLoadResult(state: UpdateState(), found: .invalid(reason)), "\(text)")
    } // End of loop over invalid files
    try await fixture.store.save(Self.fullState())
    #expect(await fixture.store.load().state == Self.fullState())
    #expect(try LaunchTestSupport.names(in: fixture.directory) == [UpdateStateStore.fileName])
  } // End of func invalidFilesAreReplaced()

  /// A file others can read, or one that is too large, is not trusted, and the next save
  /// replaces it with a private one.
  @Test func untrustedFilesAreReplaced() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let good = String(decoding: UpdateStateCoding.encode(Self.fullState())!, as: UTF8.self)
    try Self.writeFile(good, in: fixture, mode: 0o644)
    #expect(await fixture.store.load().found == .invalid("unsafe.permissionsTooOpen"))
    try Self.writeFile(String(repeating: " ", count: 70 * 1024), in: fixture)
    #expect(await fixture.store.load().found == .invalid("unsafe.tooLarge"))
    try Self.writeFile(good, in: fixture, mode: 0o644)
    try await fixture.store.save(UpdateState(etag: "\"x\""))
    #expect(try LaunchTestSupport.permissions(of: fixture.file) == 0o600)
    #expect(await fixture.store.load().state == UpdateState(etag: "\"x\""))
  } // End of func untrustedFilesAreReplaced()

  /// A symbolic link at the file's name is never followed: it reads as never checked, a save
  /// is refused, and the link and its target stay as they were.
  @Test func symbolicLinkIsNeverUsed() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try FileManager.default.createDirectory(
      at: fixture.directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let target = fixture.base.appending(path: "target.json")
    let good = UpdateStateCoding.encode(Self.fullState())!
    try HostStoreTests.writeFile(good, to: target)
    try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: target)
    #expect(
      await fixture.store.load()
        == UpdateStateLoadResult(state: UpdateState(), found: .invalid("unsafe.symbolicLink")))
    await #expect(throws: UpdateStateStoreError.existingFileNotRegular) {
      try await fixture.store.save(UpdateState(etag: "\"x\""))
    }
    #expect(try Data(contentsOf: target) == good)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: fixture.file.path(percentEncoded: false)) == target.path(percentEncoded: false))
    #expect(try LaunchTestSupport.names(in: fixture.directory) == [UpdateStateStore.fileName])
  } // End of func symbolicLinkIsNeverUsed()

  /// A folder or a FIFO at the file's name is never read (the FIFO never blocks) or replaced.
  @Test func nonRegularFilesAreNeverUsed() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try FileManager.default.createDirectory(
      at: fixture.file, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    #expect(await fixture.store.load().found == .invalid("unsafe.notARegularFile"))
    await #expect(throws: UpdateStateStoreError.existingFileNotRegular) {
      try await fixture.store.save(UpdateState())
    }
    try FileManager.default.removeItem(at: fixture.file)
    #expect(mkfifo(fixture.file.path(percentEncoded: false), 0o600) == 0)
    #expect(await fixture.store.load().found == .invalid("unsafe.notARegularFile"))
    await #expect(throws: UpdateStateStoreError.existingFileNotRegular) {
      try await fixture.store.save(UpdateState())
    }
    #expect(try LaunchTestSupport.names(in: fixture.directory) == [UpdateStateStore.fileName])
  } // End of func nonRegularFilesAreNeverUsed()

  /// A folder that is a symbolic link is never used.
  @Test func linkedFolderIsNeverUsed() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let real = fixture.base.appending(path: "real", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: real, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(at: fixture.directory, withDestinationURL: real)
    #expect(await fixture.store.load().found == .invalid("directory"))
    await #expect(throws: UpdateStateStoreError.directoryIsSymbolicLink) {
      try await fixture.store.save(UpdateState())
    }
    #expect(try LaunchTestSupport.names(in: real).isEmpty)
  } // End of func linkedFolderIsNeverUsed()

  /// With `existingPrivate` (the probe's `--state`) a save never creates, tightens or strips
  /// the folder: a missing one, one open to others or one with an ACL entry is refused with
  /// nothing written and the folder as it was, and a private one is written with its mode
  /// left alone (0500 stays 0500, the save failing). The default policy (the app's) still
  /// creates, tightens and strips, as the other stores do.
  @Test func existingPrivatePolicyChangesNoFolder() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let path = fixture.directory.path(percentEncoded: false)
    let strict = UpdateStateStore(fileURL: fixture.file, directoryPolicy: .existingPrivate)
    #expect(strict.directoryPolicy == .existingPrivate)
    #expect(fixture.store.directoryPolicy == .createAndSecure)
    await #expect(throws: UpdateStateStoreError.directoryMissing) {
      try await strict.save(UpdateState())
    }
    #expect(!LaunchTestSupport.exists(fixture.directory))
    try FileManager.default.createDirectory(
      at: fixture.directory, withIntermediateDirectories: false)
    #expect(chmod(path, 0o755) == 0)
    await #expect(throws: UpdateStateStoreError.directoryNotPrivate) {
      try await strict.save(UpdateState())
    }
    #expect(try LaunchTestSupport.permissions(of: fixture.directory) == 0o755)
    #expect(chmod(path, 0o700) == 0)
    try LaunchTestSupport.setACL(LaunchTestSupport.everyoneReadACL, on: fixture.directory)
    await #expect(throws: UpdateStateStoreError.directoryNotPrivate) {
      try await strict.save(UpdateState())
    }
    #expect(try LaunchTestSupport.aclEntryCount(of: fixture.directory) == 1)
    #expect(try LaunchTestSupport.names(in: fixture.directory).isEmpty)
    try await fixture.store.save(Self.fullState())
    #expect(try LaunchTestSupport.aclEntryCount(of: fixture.directory) == 0)
    try await strict.save(UpdateState(etag: "\"x\""))
    #expect(await strict.load().state == UpdateState(etag: "\"x\""))
    #expect(try LaunchTestSupport.permissions(of: fixture.directory) == 0o700)
    #expect(chmod(path, 0o500) == 0)
    await #expect(throws: UpdateStateStoreError.self) {
      try await strict.save(UpdateState())
    }
    #expect(try LaunchTestSupport.permissions(of: fixture.directory) == 0o500)
    #expect(chmod(path, 0o755) == 0)
    try await fixture.store.save(Self.fullState())
    #expect(try LaunchTestSupport.permissions(of: fixture.directory) == 0o700)
    #expect(try LaunchTestSupport.names(in: fixture.directory) == [UpdateStateStore.fileName])
  } // End of func existingPrivatePolicyChangesNoFolder()

  /// The default store is `update-state.json` in muxFinder's folder; the in-memory store keeps
  /// saves and can fail them.
  @Test func defaultsAndMemory() async throws {
    let paths = AppPaths(applicationSupportDirectory: URL(fileURLWithPath: "/private/tmp/none"))
    #expect(UpdateStateStore(paths: paths).fileURL.path == "/private/tmp/none/update-state.json")
    let memory = InMemoryUpdateStateStore()
    #expect(await memory.load().found == .missing)
    try await memory.save(Self.fullState())
    #expect(await memory.load() == UpdateStateLoadResult(state: Self.fullState(), found: .saved))
    await memory.setFailure(.encodingFailed)
    await #expect(throws: UpdateStateStoreError.encodingFailed) {
      try await memory.save(UpdateState())
    }
    #expect(await memory.saveCount == 1)
  } // End of func defaultsAndMemory()
}
