import CryptoKit
import Darwin
import Foundation
import os

/// How far a download has come: bytes written so far of the asset's declared size.
public struct UpdateDownloadProgress: Sendable, Hashable {
  /// Bytes written to the staging file so far.
  public let received: Int
  /// The asset's declared size in bytes.
  public let expected: Int

  /// Creates a progress value.
  public init(received: Int, expected: Int) {
    self.received = received
    self.expected = expected
  }

  /// `received` over `expected`, from 0 to 1.
  public var fraction: Double {
    expected > 0 ? min(1, Double(received) / Double(expected)) : 0
  }
}

/// Why a redirect of the download was not followed (PLAN.md D39, I-13b1).
public enum UpdateRedirectRefusal: String, Sendable, Hashable, CaseIterable {
  /// The new address is not `https`.
  case notHTTPS
  /// The new address's host is not on the list of GitHub's download hosts
  /// (`UpdateSource.downloadHosts`). Its name is never recorded.
  case hostNotAllowed
  /// The new address carries a user, a password or a port other than 443.
  case credentialsOrPort
  /// More redirects than `URLSessionUpdateDownloadTransport.maximumRedirects`.
  case tooManyRedirects
}

/// Why the download (or, in the probe's zip mode, the copy of a local zip) failed (PLAN.md
/// D39, I-13b1). Codes are machine-readable; reasons are short English phrases for "Couldn't
/// update: …", with no path, host or Team ID.
public enum UpdateDownloadFailure: Error, Sendable, Hashable {
  /// The release has no installable asset.
  case noInstallableAsset
  /// The asset's address is not exactly
  /// `https://github.com/ccarpiog/muxFinder/releases/download/<tag>/muxFinder.zip`.
  case foreignURL
  /// The address is not `https`.
  case notHTTPS
  /// A redirect was refused.
  case redirectRefused(UpdateRedirectRefusal)
  /// The final answer's status is not 200.
  case httpStatus(Int)
  /// The answer's `Content-Length` is not the asset's declared size (nothing was read).
  case contentLengthMismatch
  /// More bytes than the declared size arrived (the transfer was stopped).
  case tooLarge
  /// Fewer bytes than the declared size arrived.
  case incomplete
  /// The file's SHA-256 is not the release's digest (the file was deleted).
  case digestMismatch
  /// No connection, or the host could not be found or reached.
  case offline
  /// The transfer stalled past the request timeout or ran past the resource timeout.
  case timedOut
  /// The download was cancelled (the partial file was deleted).
  case cancelled
  /// The local zip (zip mode) cannot be read as a regular file of at most 50 MiB.
  case sourceUnreadable
  /// The staging file could not be created or written (this errno).
  case writeFailed(errno: Int32)
  /// Anything else, with a short machine-readable detail (never a URL or a body).
  case other(String)

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .noInstallableAsset: return "noInstallableAsset"
    case .foreignURL: return "foreignURL"
    case .notHTTPS: return "notHTTPS"
    case .redirectRefused(let refusal): return "redirectRefused.\(refusal.rawValue)"
    case .httpStatus(let status): return "httpStatus.\(status)"
    case .contentLengthMismatch: return "contentLengthMismatch"
    case .tooLarge: return "tooLarge"
    case .incomplete: return "incomplete"
    case .digestMismatch: return "digestMismatch"
    case .offline: return "offline"
    case .timedOut: return "timedOut"
    case .cancelled: return "cancelled"
    case .sourceUnreadable: return "sourceUnreadable"
    case .writeFailed(let code): return "writeFailed.\(code)"
    case .other(let detail): return "other.\(detail)"
    }
  } // End of var code

  /// The reason, as a phrase after "Couldn't update: ".
  public var reason: String {
    switch self {
    case .noInstallableAsset: return "the release has no installable download"
    case .foreignURL: return "the download isn't muxFinder's release on GitHub"
    case .notHTTPS: return "the download address isn't secure (https)"
    case .redirectRefused(.notHTTPS):
      return "the download was redirected to an address that isn't secure (https)"
    case .redirectRefused(.hostNotAllowed):
      return "the download was redirected to a server that isn't one of GitHub's"
    case .redirectRefused(.credentialsOrPort):
      return "the download was redirected to an unexpected address"
    case .redirectRefused(.tooManyRedirects): return "the download was redirected too many times"
    case .httpStatus(let status): return "the server answered the download with status \(status)"
    case .contentLengthMismatch: return "the download's size isn't the size the release lists"
    case .tooLarge: return "the download is larger than the release lists"
    case .incomplete: return "the download ended before it was complete"
    case .digestMismatch: return "the download doesn't match the release's checksum"
    case .offline: return "no connection"
    case .timedOut: return "the download took too long"
    case .cancelled: return "the update was cancelled"
    case .sourceUnreadable: return "the update file can't be read"
    case .writeFailed: return "the download couldn't be saved"
    case .other: return "the download failed"
    }
  } // End of var reason
}

/// A downloaded (or copied) zip in the staging folder whose size and SHA-256 matched.
public struct UpdateDownloadedFile: Sendable, Hashable {
  /// Its name in the staging folder.
  public let name: String
  /// Its size in bytes.
  public let size: Int
  /// Its SHA-256, lowercase hex.
  public let sha256: String
}

/// What a download (or a copy) came to.
public enum UpdateDownloadResult: Sendable, Hashable {
  /// The file is in the staging folder with the expected size and digest.
  case downloaded(UpdateDownloadedFile)
  /// It failed; nothing it wrote is left.
  case failed(UpdateDownloadFailure)
}

/// Fetches the release's asset and hands every byte of a 200 answer to a sink (PLAN.md D39,
/// I-13b1): `URLSessionUpdateDownloadTransport` in the app and the probe, fakes in tests (no
/// test sends a real request).
public protocol UpdateDownloadTransport: Sendable {
  /// `GET` of `asset.downloadURL`, feeding the body to `sink`. Never throws: every failure is
  /// a value. The sink checks the declared size as bytes arrive; the caller checks the size and
  /// the digest at the end.
  func fetch(_ asset: UpdateAsset, into sink: UpdateDownloadSink) async -> Result<
    Void, UpdateDownloadFailure
  >
}

/// The file a download streams into: it writes each chunk to the exclusive staging file,
/// computes SHA-256 as it goes, refuses any byte past the declared size and reports progress
/// after each write. One task uses it at a time; a lock keeps it safe to share.
public final class UpdateDownloadSink: @unchecked Sendable {
  /// The size the bytes may not exceed.
  public let declaredSize: Int
  /// The open staging file.
  private let descriptor: Int32
  /// Told after every write.
  private let progress: @Sendable (UpdateDownloadProgress) -> Void
  /// Guards the mutable state below.
  private let lock = NSLock()
  /// The running digest.
  private var hasher = SHA256()
  /// Bytes written so far.
  private var received = 0
  /// Whether the file is closed.
  private var closed = false

  /// A sink writing to `descriptor` (which it closes) for an asset of `declaredSize` bytes.
  init(
    descriptor: Int32, declaredSize: Int,
    progress: @escaping @Sendable (UpdateDownloadProgress) -> Void
  ) {
    self.descriptor = descriptor
    self.declaredSize = declaredSize
    self.progress = progress
  }

  /// Closes the file if `finish()` did not.
  deinit {
    if !closed { Darwin.close(descriptor) }
  }

  /// Bytes written so far.
  public var receivedBytes: Int {
    lock.withLock { received }
  }

  /// Writes `data`: `tooLarge` (nothing written) when it would pass the declared size,
  /// `writeFailed` when the file cannot take it.
  public func append(_ data: Data) throws(UpdateDownloadFailure) {
    switch lock.withLock({ appendLocked(data) }) {
    case .success(let total):
      progress(UpdateDownloadProgress(received: total, expected: declaredSize))
    case .failure(let failure):
      throw failure
    }
  }

  /// `append(_:)`'s work, with the lock held: the new total, or why nothing was written.
  private func appendLocked(_ data: Data) -> Result<Int, UpdateDownloadFailure> {
    guard !closed else { return .failure(.other("sinkClosed")) }
    guard received + data.count <= declaredSize else { return .failure(.tooLarge) }
    do throws(PrivateStorageError) {
      try PrivateStorage.writeAll(data, to: descriptor)
    } catch {
      if case .systemCallFailed(_, let code) = error { return .failure(.writeFailed(errno: code)) }
      return .failure(.writeFailed(errno: EIO))
    }
    hasher.update(data: data)
    received += data.count
    return .success(received)
  } // End of func appendLocked(_:)

  /// Closes the file and returns its size and SHA-256 (lowercase hex).
  func finish() -> (size: Int, sha256: String) {
    lock.withLock {
      if !closed {
        closed = true
        Darwin.close(descriptor)
      }
      let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
      return (received, digest)
    }
  } // End of func finish()
}

/// Downloads a release's asset into the staging folder (PLAN.md D39, I-13b1): only the offer's
/// exact asset URL, into a new `muxFinder.zip` created exclusively there, then the exact
/// declared size and the release's SHA-256. Any failure, a cancellation included, deletes the
/// file. `copyLocalFile` does the same for a zip on disk (the probe's zip mode).
public struct UpdateDownloader: Sendable {
  /// The staging file's name.
  public static let fileName = "muxFinder.zip"
  /// The size of each read when copying a local file.
  static let copyChunkSize = 64 * 1024

  /// The transport.
  public let transport: any UpdateDownloadTransport

  /// A downloader over `transport`.
  public init(transport: any UpdateDownloadTransport) {
    self.transport = transport
  }

  /// Downloads `release`'s asset into `staging` (see the type); `progress` is told after each
  /// write. Cancellation of the calling task cancels the request.
  public func download(
    _ release: UpdateRelease,
    into staging: UpdateStagingFolder,
    progress: @escaping @Sendable (UpdateDownloadProgress) -> Void = { _ in }
  ) async -> UpdateDownloadResult {
    guard let asset = release.asset else { return .failed(.noInstallableAsset) }
    guard asset.downloadURL.absoluteString == UpdateSource.assetDownloadURL(forTag: release.tag)
    else { return .failed(.foreignURL) }
    guard (1...UpdateReleaseParser.maximumAssetSize).contains(asset.size) else {
      return .failed(.tooLarge)
    }
    if Task.isCancelled { return .failed(.cancelled) }
    let descriptor: Int32
    do throws(UpdateStagingFileError) {
      descriptor = try staging.createFile(named: Self.fileName)
    } catch {
      return .failed(.writeFailed(errno: error.errnoValue))
    }
    let sink = UpdateDownloadSink(
      descriptor: descriptor, declaredSize: asset.size, progress: progress)
    let fetched = await transport.fetch(asset, into: sink)
    let cancelled = Task.isCancelled
    return Self.conclude(
      fetched, cancelled: cancelled, sink: sink, expectedSHA256: asset.sha256, staging: staging)
  } // End of func download(_:into:progress:)

  /// Copies the regular file at `source` (at most `UpdateReleaseParser.maximumAssetSize`
  /// bytes, a link at its last component refused, never read past its checked size) into
  /// `staging` as `muxFinder.zip`, created exclusively, and checks its SHA-256 against
  /// `expectedSHA256` (lowercase hex). Any failure deletes the copy.
  public static func copyLocalFile(
    atPath source: String, expectedSHA256: String, into staging: UpdateStagingFolder
  ) -> UpdateDownloadResult {
    let input = open(source, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard input >= 0 else { return .failed(.sourceUnreadable) }
    defer { Darwin.close(input) }
    var info = stat()
    guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else {
      return .failed(.sourceUnreadable)
    }
    guard info.st_size <= off_t(UpdateReleaseParser.maximumAssetSize) else {
      return .failed(.tooLarge)
    }
    let descriptor: Int32
    do throws(UpdateStagingFileError) {
      descriptor = try staging.createFile(named: fileName)
    } catch {
      return .failed(.writeFailed(errno: error.errnoValue))
    }
    let sink = UpdateDownloadSink(
      descriptor: descriptor, declaredSize: Int(info.st_size), progress: { _ in })
    let copied = copy(from: input, into: sink)
    return conclude(
      copied, cancelled: false, sink: sink, expectedSHA256: expectedSHA256, staging: staging)
  } // End of static func copyLocalFile(atPath:expectedSHA256:into:)

  /// Reads `input` in chunks into `sink`, never more than the sink's declared size (the
  /// file's size when it was checked, at most `UpdateReleaseParser.maximumAssetSize`): bytes
  /// the file may have gained since are never read, and a file that shrank comes out short.
  static func copy(from input: Int32, into sink: UpdateDownloadSink) -> Result<
    Void, UpdateDownloadFailure
  > {
    var buffer = [UInt8](repeating: 0, count: copyChunkSize)
    let limit = min(sink.declaredSize, UpdateReleaseParser.maximumAssetSize)
    var total = 0
    while total < limit {
      let room = min(copyChunkSize, limit - total)
      let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, room) }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        return .failure(.sourceUnreadable)
      }
      total += count
      do throws(UpdateDownloadFailure) {
        try sink.append(Data(buffer[0..<count]))
      } catch {
        return .failure(error)
      }
    } // End of loop over the file's chunks
    return .success(())
  } // End of static func copy(from:into:)

  /// Closes the sink and returns the result: the transfer's failure, a cancellation, a size
  /// other than the declared one or a digest other than the expected one deletes the file.
  static func conclude(
    _ transfer: Result<Void, UpdateDownloadFailure>,
    cancelled: Bool,
    sink: UpdateDownloadSink,
    expectedSHA256: String,
    staging: UpdateStagingFolder
  ) -> UpdateDownloadResult {
    let (size, digest) = sink.finish()
    let failure: UpdateDownloadFailure?
    if case .failure(let error) = transfer {
      failure = cancelled ? .cancelled : error
    } else if cancelled {
      failure = .cancelled
    } else if size != sink.declaredSize {
      failure = size < sink.declaredSize ? .incomplete : .tooLarge
    } else if digest != expectedSHA256.lowercased() {
      failure = .digestMismatch
    } else {
      failure = nil
    }
    if let failure {
      staging.remove(named: fileName)
      return .failed(failure)
    }
    return .downloaded(UpdateDownloadedFile(name: fileName, size: size, sha256: digest))
  } // End of static func conclude(_:cancelled:sink:expectedSHA256:staging:)
}

/// The download's request over `URLSession` (PLAN.md D39, I-13b1). Each download gets its own
/// session from an ephemeral configuration with no cookie, cache or credential storage, TLS
/// 1.2 at least, a 30 s request timeout (a stall) and a 20 min resource timeout (50 MiB at
/// about 350 kbit/s), invalidated once it ends. The request is a `GET` of the asset's URL
/// with only `Accept: application/octet-stream`, `Accept-Encoding: identity` (so
/// `Content-Length` is the file's size), a constant `Accept-Language: en` and `User-Agent:
/// muxFinder/<short version>`: no token, nothing else identifying. Only `https` is sent; a
/// redirect is followed only to `https` on `UpdateSource.downloadHosts` (port 443, no user
/// or password), at most `maximumRedirects` times. A `Content-Length` other than the declared
/// size stops it before reading, and a byte past the declared size cancels it.
public struct URLSessionUpdateDownloadTransport: UpdateDownloadTransport {
  /// The request timeout (the longest stall), in seconds.
  public static let requestTimeout: TimeInterval = 30
  /// The resource timeout (the whole transfer), in seconds.
  public static let resourceTimeout: TimeInterval = 20 * 60
  /// The most redirects followed.
  public static let maximumRedirects = 5
  /// The `Accept` header's value.
  public static let acceptHeader = "application/octet-stream"
  /// The size of each write to the staging file.
  static let chunkSize = 64 * 1024

  /// The `User-Agent` header's value.
  public let userAgent: String
  /// `URLProtocol` classes that replace the system's on each session (tests register only
  /// their stub, so no request can reach the network); empty in the app and the probe.
  let protocolClasses: [AnyClass]

  /// The transport for an app whose `CFBundleShortVersionString` is `shortVersion` (in the
  /// `User-Agent` only when it is a version of ours, `unknown` otherwise).
  public init(shortVersion: String?) {
    self.init(shortVersion: shortVersion, protocolClasses: [])
  }

  /// The designated initializer; tests pass a stub's protocol class.
  init(shortVersion: String?, protocolClasses: [AnyClass]) {
    let version = shortVersion.flatMap({ UpdateVersion($0) })?.description ?? "unknown"
    userAgent = "muxFinder/\(version)"
    self.protocolClasses = protocolClasses
  }

  /// The configuration of each download's session.
  func makeConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = Self.requestTimeout
    configuration.timeoutIntervalForResource = Self.resourceTimeout
    configuration.waitsForConnectivity = false
    configuration.httpAdditionalHeaders = nil
    configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
    if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
    return configuration
  } // End of func makeConfiguration()

  /// The request: a `GET` of `url` with only the headers above.
  func makeRequest(_ url: URL) -> URLRequest {
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue(Self.acceptHeader, forHTTPHeaderField: "Accept")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.setValue(
      URLSessionUpdateTransport.acceptLanguageHeader, forHTTPHeaderField: "Accept-Language")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    return request
  } // End of func makeRequest(_:)

  /// Why a redirect to `url` is not followed, or `nil` when it is: only `https` on one of
  /// `UpdateSource.downloadHosts` (exactly, as written), with no user or password and no port
  /// other than 443.
  public static func redirectRefusal(for url: URL?) -> UpdateRedirectRefusal? {
    guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
      components.scheme == "https"
    else { return .notHTTPS }
    guard let host = components.host, UpdateSource.downloadHosts.contains(host) else {
      return .hostNotAllowed
    }
    guard components.user == nil, components.password == nil,
      components.port == nil || components.port == 443
    else { return .credentialsOrPort }
    return nil
  } // End of static func redirectRefusal(for:)

  /// Fetches `asset` into `sink` (see the type).
  public func fetch(_ asset: UpdateAsset, into sink: UpdateDownloadSink) async -> Result<
    Void, UpdateDownloadFailure
  > {
    guard asset.downloadURL.scheme == "https" else { return .failure(.notHTTPS) }
    let redirects = DownloadRedirectGuard()
    let session = URLSession(
      configuration: makeConfiguration(), delegate: redirects, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do {
      (bytes, response) = try await session.bytes(for: makeRequest(asset.downloadURL))
    } catch {
      return .failure(Task.isCancelled ? .cancelled : Self.failure(error))
    }
    guard let http = response as? HTTPURLResponse else {
      bytes.task.cancel()
      return .failure(.other("notHTTP"))
    }
    guard http.statusCode == 200 else {
      bytes.task.cancel()
      if let refusal = redirects.refusal { return .failure(.redirectRefused(refusal)) }
      return .failure(.httpStatus(http.statusCode))
    }
    if http.expectedContentLength >= 0, http.expectedContentLength != Int64(asset.size) {
      bytes.task.cancel()
      return .failure(.contentLengthMismatch)
    }
    return await stream(bytes, into: sink)
  } // End of func fetch(_:into:)

  /// Why streaming stopped early.
  private enum StreamStop: Error {
    /// The sink or the size bound refused the bytes.
    case failure(UpdateDownloadFailure)
  }

  /// Streams a 200 answer's body into `sink` in chunks, cancelling the request at the first
  /// byte past the declared size or when the calling task is cancelled.
  func stream(_ bytes: URLSession.AsyncBytes, into sink: UpdateDownloadSink) async -> Result<
    Void, UpdateDownloadFailure
  > {
    let task = bytes.task
    let declared = sink.declaredSize
    do {
      try await withTaskCancellationHandler {
        var buffer = Data()
        buffer.reserveCapacity(Self.chunkSize)
        var total = 0
        for try await byte in bytes {
          total += 1
          if total > declared { throw StreamStop.failure(.tooLarge) }
          buffer.append(byte)
          if buffer.count >= Self.chunkSize {
            try Self.write(buffer, to: sink)
            buffer.removeAll(keepingCapacity: true)
          }
        } // End of loop over the body's bytes
        if !buffer.isEmpty { try Self.write(buffer, to: sink) }
      } onCancel: {
        task.cancel()
      }
    } catch StreamStop.failure(let failure) {
      task.cancel()
      return .failure(Task.isCancelled ? .cancelled : failure)
    } catch {
      task.cancel()
      return .failure(Task.isCancelled ? .cancelled : Self.failure(error))
    }
    return Task.isCancelled ? .failure(.cancelled) : .success(())
  } // End of func stream(_:into:)

  /// Hands `buffer` to `sink`, turning its refusal into a stop.
  private static func write(_ buffer: Data, to sink: UpdateDownloadSink) throws {
    do throws(UpdateDownloadFailure) {
      try sink.append(buffer)
    } catch {
      throw StreamStop.failure(error)
    }
  }

  /// The failure an error of `URLSession` comes to.
  static func failure(_ error: any Error) -> UpdateDownloadFailure {
    if error is CancellationError { return .cancelled }
    guard let error = error as? URLError else { return .other("error") }
    switch error.code {
    case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
      .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
      return .offline
    case .timedOut:
      return .timedOut
    case .cancelled:
      return .cancelled
    default:
      return .other("urlError.\(error.code.rawValue)")
    }
  } // End of static func failure(_:)
}

/// The download session's delegate: it follows a redirect only when
/// `URLSessionUpdateDownloadTransport.redirectRefusal(for:)` allows it and at most
/// `maximumRedirects` times, and records why it refused one (never the address).
final class DownloadRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
  /// What has happened so far.
  private struct State {
    /// Redirects followed.
    var followed = 0
    /// The first refusal.
    var refusal: UpdateRedirectRefusal?
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Why a redirect was refused, if one was.
  var refusal: UpdateRedirectRefusal? { state.withLock { $0.refusal } }

  /// Follows `request` only when it is allowed (see the type).
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    let refusal = URLSessionUpdateDownloadTransport.redirectRefusal(for: request.url)
    let follow = state.withLock { state -> Bool in
      if let refusal {
        state.refusal = state.refusal ?? refusal
        return false
      }
      guard state.followed < URLSessionUpdateDownloadTransport.maximumRedirects else {
        state.refusal = state.refusal ?? .tooManyRedirects
        return false
      }
      state.followed += 1
      return true
    }
    return follow ? request : nil
  } // End of func urlSession(_:task:willPerformHTTPRedirection:newRequest:)
}
