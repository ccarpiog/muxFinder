import CryptoKit
import Darwin
import Foundation
import os

@testable import MuxFinderCore

/// Shared fixtures of the update verification's tests (PLAN.md D39, Phase I-13b1). Nothing
/// here sends a request (the download transport is `FakeUpdateDownloadTransport` or
/// `URLSessionUpdateDownloadTransport` over `UpdateStubProtocol` only), every zip is built
/// in a private temporary folder with `/usr/bin/ditto -c -k`, and every signature is ad hoc
/// (`codesign -s - --force`, no `--timestamp`, no keychain identity).
enum UpdateVerifyTestSupport {
  /// A well-formed Team ID that signs nothing of ours.
  static let team = UpdateTeamID("ABCDE12345")!

  /// A release tag no other test uses, so the stub's routes never collide.
  static func uniqueTag() -> String {
    "v0.3.\(Int.random(in: 1...999_999_999))"
  }

  /// The SHA-256 of `data`, lowercase hex.
  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// A release for `tag` whose asset is `body` at its exact download URL (with `digest`
  /// instead of the body's own when given).
  static func release(tag: String, body: Data, digest: String? = nil) -> UpdateRelease {
    let version = UpdateVersion(tag: tag)!
    let asset = UpdateAsset(
      downloadURL: URL(string: UpdateSource.assetDownloadURL(forTag: tag))!,
      sha256: digest ?? sha256(body), size: body.count)
    return UpdateRelease(
      version: version,
      pageURL: URL(string: "https://github.com/ccarpiog/muxFinder/releases/tag/\(tag)")!,
      asset: asset, assetProblem: nil)
  } // End of static func release(tag:body:digest:)

  /// Random bytes.
  static func randomData(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: 0...255) })
  }

  /// A new private staging folder (under `/private/tmp`) and its URL; the caller removes it.
  static func makeStaging() throws -> (UpdateStagingFolder, URL) {
    let folder = try UpdateTestSupport.makePrivateFolder()
    do {
      return (try UpdateStagingFolder(path: folder.path(percentEncoded: false)), folder)
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
  }

  /// Runs `executable` with `arguments` (no shell) and requires exit 0.
  @discardableResult
  static func run(_ executable: String, _ arguments: [String]) async throws -> ProcessResult {
    let result = try await PosixSpawnProcessRunner().run(
      ProcessRequest(
        executableURL: URL(fileURLWithPath: executable), arguments: arguments,
        environment: ["PATH": ProcessEnvironment.systemSearchPath], timeout: .seconds(60)))
    guard result.succeeded else {
      throw POSIXError(
        .EIO, userInfo: ["stderr": String(decoding: result.standardError, as: UTF8.self)])
    }
    return result
  } // End of static func run(_:_:)

  /// Zips the contents of `folder` (with `keepParent`, the folder itself) into `zip`.
  static func zip(_ folder: URL, keepParent: Bool = false, into zip: URL) async throws {
    var arguments = ["-c", "-k"]
    if keepParent { arguments.append("--keepParent") }
    arguments += [folder.path(percentEncoded: false), zip.path(percentEncoded: false)]
    try await run("/usr/bin/ditto", arguments)
  }

  /// An `Info.plist` with these values; `nil` leaves a key out.
  static func infoPlist(
    identifier: Any? = UpdateSource.bundleIdentifier, short: Any? = "0.3.0", build: Any? = "3"
  ) -> Data {
    var info: [String: Any] = [
      "CFBundleExecutable": "muxFinder", "CFBundlePackageType": "APPL",
      "CFBundleName": "muxFinder",
    ]
    info["CFBundleIdentifier"] = identifier
    info["CFBundleShortVersionString"] = short
    info["CFBundleVersion"] = build
    return try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
  } // End of static func infoPlist(identifier:short:build:)

  /// Builds a minimal app bundle at `app`: `Contents/Info.plist`, `Contents/MacOS/muxFinder`
  /// (a copy of `/usr/bin/true`, so it can be signed) and one resource.
  static func makeApp(at app: URL, info: Data = infoPlist()) throws {
    let manager = FileManager.default
    let macOS = app.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
    let resources = app.appending(path: "Contents/Resources", directoryHint: .isDirectory)
    try manager.createDirectory(at: macOS, withIntermediateDirectories: true)
    try manager.createDirectory(at: resources, withIntermediateDirectories: true)
    try info.write(to: app.appending(path: "Contents/Info.plist"))
    try manager.copyItem(
      at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appending(path: "muxFinder"))
    try Data("synthetic resource\n".utf8).write(to: resources.appending(path: "note.txt"))
  } // End of static func makeApp(at:info:)

  /// Signs `app` ad hoc (`codesign -s - --force`, nothing else).
  static func adHocSign(_ app: URL) async throws {
    try await run("/usr/bin/codesign", ["-s", "-", "--force", app.path(percentEncoded: false)])
  }

  /// A source folder under a new private folder, laid out by `build`, zipped (contents only,
  /// unless `keepParent`) into `<private>/release.zip`; returns the zip's bytes and URL, and
  /// the private folder to remove (removed here when anything fails).
  static func makeZip(
    keepParent: Bool = false, _ build: (URL) async throws -> Void
  ) async throws -> (data: Data, url: URL, folder: URL) {
    let folder = try UpdateTestSupport.makePrivateFolder()
    do {
      let source = folder.appending(path: "source", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
      try await build(source)
      let zip = folder.appending(path: "release.zip")
      try await self.zip(source, keepParent: keepParent, into: zip)
      return (try Data(contentsOf: zip), zip, folder)
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
  } // End of static func makeZip(keepParent:_:)

  /// The names in `folder`, sorted.
  static func names(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
  }
}

/// A code checker that answers as told and records the bundles it was asked about.
final class FakeUpdateCodeChecker: UpdateCodeChecking, Sendable {
  /// The answer.
  let result: UpdateCodeCheckResult
  /// The paths and teams asked about.
  private let calls = OSAllocatedUnfairLock<[(String, UpdateTeamID)]>(initialState: [])

  /// A checker answering `result`.
  init(_ result: UpdateCodeCheckResult = .passed) {
    self.result = result
  }

  /// Records the call and answers.
  func check(bundleAt path: String, team: UpdateTeamID) async -> UpdateCodeCheckResult {
    calls.withLock { $0.append((path, team)) }
    return result
  }

  /// The paths asked about.
  var paths: [String] { calls.withLock { $0.map(\.0) } }
}

/// A download transport that feeds `body` into the sink in chunks (or fails), and records
/// what it was asked for.
final class FakeUpdateDownloadTransport: UpdateDownloadTransport, Sendable {
  /// What it does.
  let answer: Result<Data, UpdateDownloadFailure>
  /// The assets asked for.
  private let asked = OSAllocatedUnfairLock<[UpdateAsset]>(initialState: [])

  /// A transport answering `answer`.
  init(_ answer: Result<Data, UpdateDownloadFailure>) {
    self.answer = answer
  }

  /// Feeds the body (64 KiB at a time) or fails.
  func fetch(_ asset: UpdateAsset, into sink: UpdateDownloadSink) async -> Result<
    Void, UpdateDownloadFailure
  > {
    asked.withLock { $0.append(asset) }
    switch answer {
    case .failure(let failure):
      return .failure(failure)
    case .success(let body):
      var offset = 0
      while offset < body.count {
        let end = min(offset + 64 * 1024, body.count)
        do throws(UpdateDownloadFailure) {
          try sink.append(body.subdata(in: offset..<end))
        } catch {
          return .failure(error)
        }
        offset = end
      } // End of loop over the body's chunks
      return .success(())
    }
  } // End of func fetch(_:into:)

  /// The assets asked for.
  var assets: [UpdateAsset] { asked.withLock { $0 } }
}

/// A process runner that answers as told and records each request (no process runs).
final class RecordingProcessRunner: ProcessRunner, Sendable {
  /// What `run` does.
  enum Answer: Sendable {
    /// Returns this result.
    case result(ProcessResult)
    /// Throws a cancellation.
    case cancel
    /// Throws a start failure.
    case startFailure
  }

  /// The answer.
  let answer: Answer
  /// The requests seen.
  private let seen = OSAllocatedUnfairLock<[ProcessRequest]>(initialState: [])

  /// A runner answering `answer`.
  init(_ answer: Answer) {
    self.answer = answer
  }

  /// Records `request` and answers.
  func run(_ request: ProcessRequest) async throws -> ProcessResult {
    seen.withLock { $0.append(request) }
    switch answer {
    case .result(let result): return result
    case .cancel: throw CancellationError()
    case .startFailure: throw ProcessRunnerError.spawnFailed(errno: ENOENT)
    }
  }

  /// The requests seen.
  var requests: [ProcessRequest] { seen.withLock { $0 } }
}

extension UpdateVerifyTestSupport {
  /// Makes `url` a sparse file of `size` zero bytes (no data written, so nothing is used on
  /// disk until it is unpacked).
  static func makeSparseFile(at url: URL, size: Int) throws {
    guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil),
      truncate(url.path(percentEncoded: false), off_t(size)) == 0
    else { throw POSIXError(.EIO) }
  }

  /// Gives the file or folder at `url` the extended attribute `name` (a short value), so
  /// `ditto -c -k` writes a `._` AppleDouble entry for it.
  static func setAttribute(_ name: String, on url: URL) throws {
    let value = Array("synthetic".utf8)
    guard
      setxattr(url.path(percentEncoded: false), name, value, value.count, 0, XATTR_NOFOLLOW)
        == 0
    else { throw POSIXError(.EIO) }
  }

  /// Whether the file or folder at `url` has the extended attribute `name`.
  static func hasAttribute(_ name: String, on url: URL) -> Bool {
    getxattr(url.path(percentEncoded: false), name, nil, 0, 0, XATTR_NOFOLLOW) > 0
  }

  /// Replaces the bundle at `path` as another process could: the original renamed aside (in
  /// the same folder), a copy of it with one resource changed put at its path.
  static func swapBundle(atPath path: String) throws {
    let app = URL(fileURLWithPath: path, isDirectory: true)
    let aside = app.deletingLastPathComponent().appending(
      path: "aside.app", directoryHint: .isDirectory)
    try FileManager.default.moveItem(at: app, to: aside)
    try FileManager.default.copyItem(at: aside, to: app)
    try Data("changed\n".utf8).write(to: app.appending(path: "Contents/Resources/note.txt"))
  }

  /// The identity of the entry at `url`, read with `lstat`.
  static func identity(of url: URL) throws -> UpdateBundleIdentity {
    var info = stat()
    guard lstat(url.path(percentEncoded: false), &info) == 0 else { throw POSIXError(.ENOENT) }
    return UpdateBundleIdentity(info)
  }
}

/// A zip's entries as laid out in its bytes (no ZIP64, no comment), for tests that patch them
/// into what a hostile archive would be. A reading of the format independent of
/// `UpdateArchiveCheck`'s.
struct ZipLayout {
  /// One entry's offsets and fields.
  struct Entry {
    /// Its name.
    var name: String
    /// Where its directory record begins.
    var record: Int
    /// Where its local header begins.
    var local: Int
    /// Its general purpose flags.
    var flags: UInt16
    /// Its packed size.
    var compressed: Int
    /// Its declared unpacked size.
    var uncompressed: Int
  }

  /// The zip's bytes.
  var bytes: [UInt8]
  /// Where the end record begins.
  let end: Int
  /// The entries, in directory order.
  let entries: [Entry]

  /// Reads the layout of `data`.
  init(_ data: Data) throws {
    bytes = Array(data)
    end = bytes.count - 22
    guard end >= 0, Self.u32(bytes, end) == 0x0605_4B50 else { throw POSIXError(.EINVAL) }
    var position = Int(Self.u32(bytes, end + 16))
    var entries: [Entry] = []
    for _ in 0..<Int(Self.u16(bytes, end + 10)) {
      guard Self.u32(bytes, position) == 0x0201_4B50 else { throw POSIXError(.EINVAL) }
      let nameLength = Int(Self.u16(bytes, position + 28))
      let more = Int(Self.u16(bytes, position + 30)) + Int(Self.u16(bytes, position + 32))
      entries.append(
        Entry(
          name: String(
            decoding: bytes[(position + 46)..<(position + 46 + nameLength)], as: UTF8.self),
          record: position, local: Int(Self.u32(bytes, position + 42)),
          flags: Self.u16(bytes, position + 8), compressed: Int(Self.u32(bytes, position + 20)),
          uncompressed: Int(Self.u32(bytes, position + 24))))
      position += 46 + nameLength + more
    } // End of loop over the directory records
    self.entries = entries
  } // End of init(_:)

  /// The little-endian 16-bit value at `index` of `bytes`.
  static func u16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
    UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
  }

  /// The little-endian 32-bit value at `index` of `bytes`.
  static func u32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
    UInt32(u16(bytes, index)) | UInt32(u16(bytes, index + 2)) << 16
  }

  /// The patched zip.
  var data: Data { Data(bytes) }

  /// The names, in directory order.
  var names: [String] { entries.map(\.name) }

  /// The entry named `name`.
  func entry(_ name: String) throws -> Entry {
    guard let entry = entries.first(where: { $0.name == name }) else { throw POSIXError(.ENOENT) }
    return entry
  }

  /// Writes the 16-bit `value` at `index`.
  mutating func set16(_ value: UInt16, at index: Int) {
    bytes[index] = UInt8(value & 0xFF)
    bytes[index + 1] = UInt8(value >> 8)
  }

  /// Writes the 32-bit `value` at `index`.
  mutating func set32(_ value: UInt32, at index: Int) {
    set16(UInt16(value & 0xFFFF), at: index)
    set16(UInt16(value >> 16), at: index + 2)
  }

  /// Renames the entry `name` to `newName` (the same length) in its directory record and, unless
  /// `localOnly` or `recordOnly`, its local header.
  mutating func rename(
    _ name: String, to newName: String, localOnly: Bool = false, recordOnly: Bool = false
  ) throws {
    let entry = try entry(name)
    let replacement = Array(newName.utf8)
    guard replacement.count == name.utf8.count else { throw POSIXError(.EINVAL) }
    if !localOnly {
      bytes.replaceSubrange(
        (entry.record + 46)..<(entry.record + 46 + replacement.count), with: replacement)
    }
    if !recordOnly {
      bytes.replaceSubrange(
        (entry.local + 30)..<(entry.local + 30 + replacement.count), with: replacement)
    }
  } // End of func rename(_:to:localOnly:recordOnly:)

  /// Declares `size` as the entry `name`'s unpacked size everywhere it is recorded: its
  /// directory record, its local header (when it records one) and its data descriptor.
  mutating func declare(size: UInt32, for name: String) throws {
    let entry = try entry(name)
    set32(size, at: entry.record + 24)
    if Self.u32(bytes, entry.local + 22) != 0 { set32(size, at: entry.local + 22) }
    guard entry.flags & 0x0008 != 0 else { return }
    let nameLength = Int(Self.u16(bytes, entry.local + 26))
    let extraLength = Int(Self.u16(bytes, entry.local + 28))
    var descriptor = entry.local + 30 + nameLength + extraLength + entry.compressed
    if Self.u32(bytes, descriptor) == 0x0807_4B50 { descriptor += 4 }
    set32(size, at: descriptor + 8)
  } // End of func declare(size:for:)

  /// Sets the entry `name`'s flags and method in its directory record and local header.
  mutating func set(flags: UInt16? = nil, method: UInt16? = nil, for name: String) throws {
    let entry = try entry(name)
    if let flags {
      set16(flags, at: entry.record + 8)
      set16(flags, at: entry.local + 6)
    }
    if let method {
      set16(method, at: entry.record + 10)
      set16(method, at: entry.local + 8)
    }
  } // End of func set(flags:method:for:)
}

/// A process runner that forwards to another and counts the runs and the cancelled ones.
final class CountingProcessRunner: ProcessRunner, Sendable {
  /// The runner forwarded to.
  let base: any ProcessRunner
  /// Runs started, and runs that ended cancelled.
  private let counts = OSAllocatedUnfairLock<[Int]>(initialState: [0, 0])

  /// A runner forwarding to `base`.
  init(_ base: any ProcessRunner = PosixSpawnProcessRunner()) {
    self.base = base
  }

  /// Counts the run and forwards it.
  func run(_ request: ProcessRequest) async throws -> ProcessResult {
    counts.withLock { $0[0] += 1 }
    do {
      return try await base.run(request)
    } catch is CancellationError {
      counts.withLock { $0[1] += 1 }
      throw CancellationError()
    }
  }

  /// Runs started.
  var runs: Int { counts.withLock { $0[0] } }
  /// Runs that ended cancelled.
  var cancelled: Int { counts.withLock { $0[1] } }
}

/// A process runner standing in for a `ditto` whose output passes the bounds: it writes
/// `files` files of `bytes` zero bytes each into the destination (its request's last
/// argument), then waits until it is cancelled (at most 30 s) and records that. No process
/// runs.
final class WritingProcessRunner: ProcessRunner, Sendable {
  /// Files written.
  let files: Int
  /// Bytes per file.
  let bytes: Int
  /// Whether the run was cancelled.
  private let stopped = OSAllocatedUnfairLock(initialState: false)

  /// A runner writing `files` files of `bytes` bytes.
  init(files: Int, bytes: Int) {
    self.files = files
    self.bytes = bytes
  }

  /// Writes the files, then waits until cancelled.
  func run(_ request: ProcessRequest) async throws -> ProcessResult {
    let destination = URL(fileURLWithPath: request.arguments.last ?? "/nonexistent")
    for index in 0..<files {
      try Data(count: bytes).write(to: destination.appending(path: "written-\(index)"))
    } // End of loop over the files written
    do {
      try await Task.sleep(for: .seconds(30))
    } catch {
      stopped.withLock { $0 = true }
      throw CancellationError()
    }
    return ProcessResult(processID: 1, termination: .exited(0))
  } // End of func run(_:)

  /// Whether the run was cancelled.
  var wasCancelled: Bool { stopped.withLock { $0 } }
}

/// A code checker that passes, but first replaces the bundle it was asked about (as another
/// process of the same user could, `UpdateVerifyTestSupport.swapBundle`).
final class SwappingCodeChecker: UpdateCodeChecking, Sendable {
  /// Whether the swap succeeded.
  private let swapped = OSAllocatedUnfairLock(initialState: false)

  /// Swaps the bundle, then passes.
  func check(bundleAt path: String, team: UpdateTeamID) async -> UpdateCodeCheckResult {
    let done = (try? UpdateVerifyTestSupport.swapBundle(atPath: path)) != nil
    swapped.withLock { $0 = done }
    return .passed
  }

  /// Whether the swap succeeded.
  var didSwap: Bool { swapped.withLock { $0 } }
}
