import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// Tests for `LaunchStore`: permissions (checked with `lstat`), refused directories, atomic
/// writes, delete on read, the 2-minute TTL with an injected clock, the sweep and unsafe files.
/// Every test uses its own temporary directory, never the real Application Support folder.
@Suite("Launch store")
struct LaunchStoreTests {
  /// The directory is created 0700, the request file 0600, and no temporary file is left.
  @Test func writesPrivately() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let request = LaunchTestSupport.request()
    try store.writeRequest(request)
    let file = store.directory.appending(path: LaunchStore.requestFileName(for: request.id))
    #expect(try LaunchTestSupport.permissions(of: store.directory) == 0o700)
    #expect(try LaunchTestSupport.status(of: store.directory).st_mode & S_IFMT == S_IFDIR)
    #expect(try LaunchTestSupport.permissions(of: file) == 0o600)
    #expect(try LaunchTestSupport.status(of: file).st_mode & S_IFMT == S_IFREG)
    #expect(try LaunchTestSupport.names(in: store.directory) == ["\(request.id).request.json"])
  } // End of func writesPrivately()

  /// A store made from `AppPaths` creates `<root>/launch`, both 0700, even under a umask that
  /// would allow more.
  @Test func createsTheStandardLayout() throws {
    let base = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let paths = AppPaths(applicationSupportDirectory: base.appending(path: "muxFinder"))
    let store = LaunchStore(paths: paths, now: { LaunchTestSupport.requestTime })
    #expect(store.directory.lastPathComponent == "launch")
    #expect(store.directory.deletingLastPathComponent().lastPathComponent == "muxFinder")
    try store.writeRequest(LaunchTestSupport.request())
    #expect(try LaunchTestSupport.permissions(of: paths.applicationSupportDirectory) == 0o700)
    #expect(try LaunchTestSupport.permissions(of: store.directory) == 0o700)
    #expect(LaunchStore().directory.path(percentEncoded: false).hasSuffix("/muxFinder/launch/"))
  } // End of func createsTheStandardLayout()

  /// An existing directory with looser permissions is tightened to 0700.
  @Test func tightensALooseDirectory() throws {
    let root = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "launch")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o755]
    )
    #expect(try LaunchTestSupport.permissions(of: directory) == 0o755)
    let store = LaunchStore(directory: directory)
    #expect(throws: LaunchStoreError.fileMissing) { try store.takeRequest(LaunchToken()) }
    #expect(try LaunchTestSupport.permissions(of: directory) == 0o700)
  } // End of func tightensALooseDirectory()

  /// A symbolic link as the launch directory is refused for every operation, and its target
  /// is left untouched.
  @Test func refusesASymlinkedDirectory() throws {
    let root = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "elsewhere")
    try FileManager.default.createDirectory(
      at: target,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o755]
    )
    let link = root.appending(path: "launch")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let store = LaunchStore(directory: link)
    let refused = LaunchStoreError.directoryIsSymbolicLink
    #expect(throws: refused) { try store.prepareDirectory() }
    #expect(throws: refused) { try store.writeRequest(LaunchTestSupport.request()) }
    #expect(throws: refused) { try store.takeRequest(LaunchToken()) }
    #expect(throws: refused) { try store.sweep() }
    #expect(refused.launchFailure == .launchDirectoryUnusable)
    #expect(try LaunchTestSupport.permissions(of: target) == 0o755)
    #expect(try LaunchTestSupport.names(in: target).isEmpty)
  } // End of func refusesASymlinkedDirectory()

  /// A directory owned by another user is refused: a real root-owned one (`/usr`, read only)
  /// and a temporary one checked against a different owner id. Neither is changed.
  @Test func refusesAForeignDirectory() throws {
    let system = LaunchStore(directory: URL(fileURLWithPath: "/usr", isDirectory: true))
    #expect(throws: LaunchStoreError.directoryNotOwnedByUser) {
      try system.takeRequest(LaunchToken())
    }
    #expect(throws: LaunchStoreError.directoryNotOwnedByUser) { try system.prepareDirectory() }
    #expect(LaunchStoreError.directoryNotOwnedByUser.launchFailure == .launchDirectoryUnusable)

    let root = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "launch")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o755]
    )
    let foreign = LaunchStore(
      directory: directory,
      root: nil,
      timeToLive: LaunchStore.defaultTimeToLive,
      owner: geteuid() + 1,
      now: { Date() }
    )
    #expect(throws: LaunchStoreError.directoryNotOwnedByUser) { try foreign.prepareDirectory() }
    #expect(try LaunchTestSupport.permissions(of: directory) == 0o755)
  } // End of func refusesAForeignDirectory()

  /// A regular file at the directory's path is refused; a missing directory is reported, never
  /// created by the helper's operations.
  @Test func refusesAFileAndReportsAMissingDirectory() throws {
    let root = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "launch")
    try Data("x".utf8).write(to: file)
    #expect(throws: LaunchStoreError.directoryNotADirectory) {
      try LaunchStore(directory: file).prepareDirectory()
    }
    let missing = LaunchStore(directory: root.appending(path: "missing"))
    #expect(throws: LaunchStoreError.directoryMissing) { try missing.takeRequest(LaunchToken()) }
    #expect(LaunchStoreError.directoryMissing.launchFailure == .requestMissing)
    let result = LaunchResult(
      id: LaunchToken(),
      helperPID: 1,
      startedAt: Date(),
      childStartedAt: nil,
      endedAt: Date(),
      childTermination: nil,
      failure: .requestMissing
    )
    #expect(throws: LaunchStoreError.directoryMissing) { try missing.writeResult(result) }
    #expect(try missing.sweep() == 0)
    #expect(try missing.takeResult(LaunchToken()) == nil)
    #expect(try missing.discardRequest(LaunchToken()) == false)
    #expect(!missing.testModeMarkerExists())
    #expect(!LaunchTestSupport.exists(missing.directory))
  } // End of func refusesAFileAndReportsAMissingDirectory()

  /// Taking a request returns it and deletes the file; a second take finds nothing.
  @Test func deletesOnRead() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let request = LaunchTestSupport.request(tmuxPathOverride: "/opt/homebrew/bin/tmux")
    try store.writeRequest(request)
    #expect(try store.takeRequest(request.id) == request)
    #expect(try LaunchTestSupport.names(in: store.directory).isEmpty)
    #expect(throws: LaunchStoreError.fileMissing) { try store.takeRequest(request.id) }
    #expect(LaunchStoreError.fileMissing.launchFailure == .requestMissing)
  }

  /// An id is never reused: a second request with the same id is refused, the first kept.
  @Test func refusesADuplicateRequest() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let request = LaunchTestSupport.request()
    try store.writeRequest(request)
    var other = request
    other.expectedServerPID = 1
    #expect(throws: LaunchStoreError.fileAlreadyExists) { try store.writeRequest(other) }
    #expect(try LaunchTestSupport.names(in: store.directory) == ["\(request.id).request.json"])
    #expect(try store.takeRequest(request.id) == request)
  } // End of func refusesADuplicateRequest()

  /// A request is valid for exactly 2 minutes (fake clock); an expired one is refused and
  /// removed, and so is one dated in the future.
  @Test func expiresAfterTwoMinutes() throws {
    let root = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "launch")
    let created = LaunchTestSupport.requestTime
    #expect(LaunchStore.defaultTimeToLive == 120)
    /// A store over `directory` whose clock is `offset` seconds after the request time.
    func store(at offset: TimeInterval) -> LaunchStore {
      LaunchStore(directory: directory, now: { created.addingTimeInterval(offset) })
    }
    let fresh = LaunchTestSupport.request(createdAt: created)
    try store(at: 0).writeRequest(fresh)
    #expect(try store(at: 120).takeRequest(fresh.id) == fresh)

    let stale = LaunchTestSupport.request(createdAt: created)
    try store(at: 0).writeRequest(stale)
    #expect(throws: LaunchStoreError.fileExpired) { try store(at: 121).takeRequest(stale.id) }
    #expect(try LaunchTestSupport.names(in: directory).isEmpty)
    #expect(LaunchStoreError.fileExpired.launchFailure == .requestExpired)

    let future = LaunchTestSupport.request(createdAt: created.addingTimeInterval(60))
    try store(at: 0).writeRequest(future)
    #expect(throws: LaunchStoreError.fileExpired) { try store(at: 0).takeRequest(future.id) }
    #expect(try LaunchTestSupport.names(in: directory).isEmpty)
  } // End of func expiresAfterTwoMinutes()

  /// The sweep removes request, result, digest and temporary files older than the TTL, and
  /// leaves fresh ones, other files and the test-mode marker alone.
  @Test func sweepsStaleFiles() throws {
    let root = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "launch")
    let now = Date()
    let store = LaunchStore(directory: directory, now: { now })
    try store.writeRequest(LaunchTestSupport.request(createdAt: now))
    let id = LaunchToken()
    try store.writeResult(
      LaunchResult(
        id: id,
        helperPID: 1,
        startedAt: now,
        childStartedAt: nil,
        endedAt: now,
        childTermination: .exited(0),
        failure: nil
      )
    )
    try store.writeArgvDigest(LaunchArgvDigest(argv: [[0x61]], helperPID: 42, recordedAt: now))
    for name in [".x.request.json.0123.tmp", "notes.txt", LaunchStore.testModeMarkerName] {
      try Data("x".utf8).write(to: directory.appending(path: name))
    }
    try FileManager.default.createDirectory(
      at: directory.appending(path: "nested.request.json"),
      withIntermediateDirectories: false
    )
    let before = try LaunchTestSupport.names(in: directory)
    #expect(before.count == 7)

    #expect(try store.sweep() == 0)
    let later = LaunchStore(directory: directory, now: { now.addingTimeInterval(121) })
    #expect(try later.sweep() == 4)
    #expect(
      try LaunchTestSupport.names(in: directory) == [
        "nested.request.json", "notes.txt", LaunchStore.testModeMarkerName,
      ]
    )
  } // End of func sweepsStaleFiles()

  /// Results are written 0600, replace an earlier one, and are deleted when taken.
  @Test func takesResults() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = LaunchToken()
    #expect(try store.takeResult(id) == nil)
    var result = LaunchResult(
      id: id,
      helperPID: 5,
      startedAt: LaunchTestSupport.requestTime,
      childStartedAt: LaunchTestSupport.requestTime,
      endedAt: LaunchTestSupport.requestTime,
      childTermination: .exited(1),
      failure: .childExited(1)
    )
    try store.writeResult(result)
    result.helperPID = 6
    try store.writeResult(result)
    let file = store.directory.appending(path: LaunchStore.resultFileName(for: id))
    #expect(try LaunchTestSupport.permissions(of: file) == 0o600)
    #expect(try store.takeResult(id) == result)
    #expect(try store.takeResult(id) == nil)
  } // End of func takesResults()

  /// A peek reads a result without taking it (PLAN.md D29): it stays for the take, and a peek
  /// after the take finds nothing. A result refused as unsafe or malformed is reported and
  /// left in place (the take or the sweep removes it); the sweep still removes an old one.
  @Test func peeksResultsWithoutTakingThem() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    /// A result for `id`.
    func result(_ id: LaunchToken) -> LaunchResult {
      LaunchResult(
        id: id, helperPID: 5, startedAt: LaunchTestSupport.requestTime, childStartedAt: nil,
        endedAt: LaunchTestSupport.requestTime, childTermination: .exited(0), failure: nil)
    }
    let id = LaunchToken()
    #expect(try store.peekResult(id) == nil)
    try store.writeResult(result(id))
    #expect(try store.peekResult(id) == result(id))
    #expect(try store.peekResult(id) == result(id))
    #expect(try store.takeResult(id) == result(id))
    #expect(try store.peekResult(id) == nil)

    let open = LaunchToken()
    try store.writeResult(result(open))
    let openFile = store.directory.appending(path: LaunchStore.resultFileName(for: open))
    #expect(chmod(openFile.path(percentEncoded: false), 0o644) == 0)
    #expect(throws: LaunchStoreError.fileUnsafe(.permissionsTooOpen)) {
      try store.peekResult(open)
    }
    #expect(LaunchTestSupport.exists(openFile))

    let other = LaunchToken()
    try store.writeResult(result(LaunchToken()))
    let written = try #require(
      try LaunchTestSupport.names(in: store.directory).first {
        $0 != LaunchStore.resultFileName(for: open)
      })
    let otherFile = store.directory.appending(path: LaunchStore.resultFileName(for: other))
    let writtenPath = store.directory.appending(path: written).path(percentEncoded: false)
    #expect(rename(writtenPath, otherFile.path(percentEncoded: false)) == 0)
    #expect(throws: LaunchStoreError.fileMalformed) { try store.peekResult(other) }
    #expect(LaunchTestSupport.exists(otherFile))

    let later = LaunchStore(
      directory: store.directory, now: { LaunchTestSupport.requestTime.addingTimeInterval(1e9) })
    try store.writeResult(result(id))
    #expect(try later.sweep() == 3)
    #expect(try store.peekResult(id) == nil)
  } // End of func peeksResultsWithoutTakingThem()

  /// `discardRequest` removes a pending request once.
  @Test func discardsRequests() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let request = LaunchTestSupport.request()
    try store.writeRequest(request)
    #expect(try store.discardRequest(request.id))
    #expect(try store.discardRequest(request.id) == false)
    #expect(throws: LaunchStoreError.fileMissing) { try store.takeRequest(request.id) }
  }

  /// Unsafe or malformed request files are refused, and removed so they cannot be retried: a
  /// symbolic link (its target untouched), a FIFO (without blocking), group/other permissions,
  /// an oversized file, invalid JSON and a request for another id.
  @Test func refusesUnsafeAndMalformedFiles() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = store.directory
    /// The request file for `id`.
    func path(_ id: LaunchToken) -> URL {
      directory.appending(path: LaunchStore.requestFileName(for: id))
    }
    let valid = try LaunchCoding.encoder().encode(LaunchTestSupport.request())

    let target = root.appending(path: "target.json")
    try valid.write(to: target)
    let linked = LaunchToken()
    try FileManager.default.createSymbolicLink(at: path(linked), withDestinationURL: target)
    #expect(throws: LaunchStoreError.fileUnsafe(.symbolicLink)) { try store.takeRequest(linked) }
    #expect(LaunchTestSupport.exists(target))

    let fifo = LaunchToken()
    #expect(mkfifo(path(fifo).path(percentEncoded: false), 0o600) == 0)
    #expect(throws: LaunchStoreError.fileUnsafe(.notARegularFile)) { try store.takeRequest(fifo) }

    let open = LaunchToken()
    try valid.write(to: path(open))
    #expect(chmod(path(open).path(percentEncoded: false), 0o644) == 0)
    #expect(throws: LaunchStoreError.fileUnsafe(.permissionsTooOpen)) {
      try store.takeRequest(open)
    }

    let large = LaunchToken()
    try Data(repeating: 0x20, count: LaunchStore.maximumFileSize + 1).write(to: path(large))
    #expect(chmod(path(large).path(percentEncoded: false), 0o600) == 0)
    #expect(throws: LaunchStoreError.fileUnsafe(.tooLarge)) { try store.takeRequest(large) }

    let garbage = LaunchToken()
    try Data("{not json".utf8).write(to: path(garbage))
    #expect(chmod(path(garbage).path(percentEncoded: false), 0o600) == 0)
    #expect(throws: LaunchStoreError.fileMalformed) { try store.takeRequest(garbage) }

    let other = LaunchToken()
    try valid.write(to: path(other))
    #expect(chmod(path(other).path(percentEncoded: false), 0o600) == 0)
    #expect(throws: LaunchStoreError.fileMalformed) { try store.takeRequest(other) }

    #expect(try LaunchTestSupport.names(in: directory).isEmpty)
    #expect(LaunchStoreError.fileMalformed.launchFailure == .requestUnreadable)
    #expect(LaunchStoreError.fileUnsafe(.tooLarge).launchFailure == .requestUnreadable)
  } // End of func refusesUnsafeAndMalformedFiles()

  /// The test-mode marker counts only as a regular file, not as a link to one.
  @Test func detectsTheTestModeMarker() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = store.directory.appending(path: LaunchStore.testModeMarkerName)
    #expect(!store.testModeMarkerExists())
    let target = root.appending(path: "target")
    try Data().write(to: target)
    try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: target)
    #expect(!store.testModeMarkerExists())
    try FileManager.default.removeItem(at: marker)
    try Data().write(to: marker)
    #expect(store.testModeMarkerExists())
  } // End of func detectsTheTestModeMarker()

  /// Argv digests are written 0600 and taken (deleted) together, oldest first.
  @Test func takesArgvDigests() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = LaunchArgvDigest(
      argv: [[0x61]], helperPID: 10, recordedAt: Date(timeIntervalSince1970: 1))
    let second = LaunchArgvDigest(
      argv: [[0x62], [0x63]], helperPID: 11, recordedAt: Date(timeIntervalSince1970: 2))
    try store.writeArgvDigest(second)
    try store.writeArgvDigest(first)
    let file = store.directory.appending(path: LaunchArgvDigest.fileName(helperPID: 10))
    #expect(try LaunchTestSupport.permissions(of: file) == 0o600)
    #expect(try store.takeArgvDigests() == [first, second])
    #expect(try store.takeArgvDigests().isEmpty)
  } // End of func takesArgvDigests()

  /// An extended ACL on the launch directory (here one that grants `everyone` access and is
  /// inherited) is removed whenever the store opens it, also by the helper's operations, which
  /// never create the directory.
  @Test func removesACLsFromTheDirectory() throws {
    let root = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "launch")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let store = LaunchStore(directory: directory)
    try LaunchTestSupport.setACL(LaunchTestSupport.everyoneInheritedACL, on: directory)
    #expect(try LaunchTestSupport.aclEntryCount(of: directory) == 1)
    #expect(throws: LaunchStoreError.fileMissing) { try store.takeRequest(LaunchToken()) }
    #expect(try LaunchTestSupport.aclEntryCount(of: directory) == 0)

    try LaunchTestSupport.setACL(LaunchTestSupport.everyoneDenyDeleteACL, on: directory)
    try store.prepareDirectory()
    #expect(try LaunchTestSupport.aclEntryCount(of: directory) == 0)
    #expect(try LaunchTestSupport.permissions(of: directory) == 0o700)
  } // End of func removesACLsFromTheDirectory()

  /// A parent with an inheritable ACL hands it to the directories created under it; the
  /// launch directory loses it, and every file the store writes there (request, result, argv
  /// digest, test-mode marker) has none and is 0600.
  @Test func leavesNoInheritedACLOnTheDirectoryOrItsFiles() throws {
    let base = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    try LaunchTestSupport.setACL(LaunchTestSupport.everyoneInheritedACL, on: base)
    let paths = AppPaths(applicationSupportDirectory: base.appending(path: "muxFinder"))
    let store = LaunchStore(paths: paths, now: { LaunchTestSupport.requestTime })
    let request = LaunchTestSupport.request()
    try store.writeRequest(request)
    #expect(try LaunchTestSupport.aclEntryCount(of: paths.applicationSupportDirectory) > 0)
    #expect(try LaunchTestSupport.aclEntryCount(of: store.directory) == 0)
    try store.writeResult(
      LaunchResult(
        id: request.id,
        helperPID: 1,
        startedAt: LaunchTestSupport.requestTime,
        childStartedAt: nil,
        endedAt: LaunchTestSupport.requestTime,
        childTermination: nil,
        failure: .requestMissing
      )
    )
    try store.writeArgvDigest(LaunchArgvDigest(argv: [[0x61]], helperPID: 9, recordedAt: Date()))
    try store.createTestModeMarker()
    let names = try LaunchTestSupport.names(in: store.directory)
    #expect(names.count == 4)
    for name in names {
      let file = store.directory.appending(path: name)
      #expect(try LaunchTestSupport.aclEntryCount(of: file) == 0, "\(name)")
      #expect(try LaunchTestSupport.permissions(of: file) == 0o600, "\(name)")
    }
  } // End of func leavesNoInheritedACLOnTheDirectoryOrItsFiles()

  /// A file created in a directory with an inheritable ACL inherits it (the premise), but the
  /// store's writer removes it before writing: the file it renames into place has no ACL.
  @Test func clearsInheritedACLsBeforeWriting() throws {
    let root = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try LaunchTestSupport.setACL(LaunchTestSupport.everyoneInheritedACL, on: root)
    let premise = root.appending(path: "premise")
    try Data("x".utf8).write(to: premise)
    #expect(try LaunchTestSupport.aclEntryCount(of: premise) == 1)

    let directory = open(root.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    try #require(directory >= 0)
    defer { close(directory) }
    try LaunchStore.writeFile(
      Data("{}".utf8), named: "a.result.json", exclusive: true, in: directory)
    let written = root.appending(path: "a.result.json")
    #expect(try LaunchTestSupport.aclEntryCount(of: written) == 0)
    #expect(try LaunchTestSupport.permissions(of: written) == 0o600)
    #expect(try Data(contentsOf: written) == Data("{}".utf8))
  } // End of func clearsInheritedACLsBeforeWriting()

  /// A request or result file with any extended ACL, whether it grants access or only denies
  /// it, is refused and removed.
  @Test func refusesFilesWithACLs() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    for text in [LaunchTestSupport.everyoneReadACL, LaunchTestSupport.everyoneDenyDeleteACL] {
      let request = LaunchTestSupport.request()
      try store.writeRequest(request)
      let file = store.directory.appending(path: LaunchStore.requestFileName(for: request.id))
      try LaunchTestSupport.setACL(text, on: file)
      #expect(throws: LaunchStoreError.fileUnsafe(.extendedACL)) {
        try store.takeRequest(request.id)
      }
      #expect(!LaunchTestSupport.exists(file))
    }
    let id = LaunchToken()
    try store.writeResult(
      LaunchResult(
        id: id,
        helperPID: 1,
        startedAt: LaunchTestSupport.requestTime,
        childStartedAt: nil,
        endedAt: LaunchTestSupport.requestTime,
        childTermination: nil,
        failure: nil
      )
    )
    let result = store.directory.appending(path: LaunchStore.resultFileName(for: id))
    try LaunchTestSupport.setACL(LaunchTestSupport.everyoneReadACL, on: result)
    #expect(throws: LaunchStoreError.fileUnsafe(.extendedACL)) { try store.takeResult(id) }
    #expect(try LaunchTestSupport.names(in: store.directory).isEmpty)
    #expect(LaunchStoreError.fileUnsafe(.extendedACL).launchFailure == .requestUnreadable)
  } // End of func refusesFilesWithACLs()

  /// A directory whose ACL cannot be removed (it is immutable) is refused as unusable.
  @Test func refusesADirectoryWhoseACLStays() throws {
    let root = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "launch")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let path = directory.path(percentEncoded: false)
    try LaunchTestSupport.setACL(LaunchTestSupport.everyoneReadACL, on: directory)
    try #require(chflags(path, UInt32(UF_IMMUTABLE)) == 0)
    defer { chflags(path, 0) }
    let store = LaunchStore(directory: directory)
    #expect(throws: LaunchStoreError.directoryHasExtendedACL) {
      try store.takeRequest(LaunchToken())
    }
    #expect(throws: LaunchStoreError.directoryHasExtendedACL) { try store.prepareDirectory() }
    #expect(LaunchStoreError.directoryHasExtendedACL.launchFailure == .launchDirectoryUnusable)
    #expect(try LaunchTestSupport.aclEntryCount(of: directory) == 1)
  } // End of func refusesADirectoryWhoseACLStays()

  /// The test-mode marker is created as an empty 0600 file (with the directory if needed) and
  /// removed once.
  @Test func createsAndRemovesTheTestModeMarker() throws {
    let root = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LaunchStore(directory: root.appending(path: "launch"))
    #expect(try store.removeTestModeMarker() == false)
    try store.createTestModeMarker()
    try store.createTestModeMarker()
    #expect(store.testModeMarkerExists())
    let marker = store.directory.appending(path: LaunchStore.testModeMarkerName)
    #expect(try LaunchTestSupport.permissions(of: marker) == 0o600)
    #expect(try Data(contentsOf: marker).isEmpty)
    #expect(try store.removeTestModeMarker())
    #expect(try store.removeTestModeMarker() == false)
    #expect(!store.testModeMarkerExists())
  } // End of func createsAndRemovesTheTestModeMarker()
}
