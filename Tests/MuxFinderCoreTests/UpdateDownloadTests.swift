import Darwin
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// The update's download (PLAN.md D39, I-13b1): `URLSessionUpdateDownloadTransport` through
/// `UpdateStubProtocol`, the only protocol class on its sessions, so no request reaches the
/// network; `UpdateDownloader` into private staging folders (the exact URL, the exclusive
/// file, progress, the exact size, the digest, cancel deleting the partial file); and the zip
/// mode's local copy.
@Suite("Update download")
struct UpdateDownloadTests {
  /// Shorthand.
  typealias Support = UpdateVerifyTestSupport

  /// A transport that goes only through the stub.
  static let transport = URLSessionUpdateDownloadTransport(
    shortVersion: "0.2.0", protocolClasses: [UpdateStubProtocol.self])

  /// Collects progress reports.
  final class ProgressLog: Sendable {
    /// The reports so far.
    private let reports = OSAllocatedUnfairLock<[UpdateDownloadProgress]>(initialState: [])
    /// Records one.
    func record(_ progress: UpdateDownloadProgress) { reports.withLock { $0.append(progress) } }
    /// The reports so far.
    var all: [UpdateDownloadProgress] { reports.withLock { $0 } }
  }

  /// Downloads `release` (registered under its tag with `answers`) into a new staging folder;
  /// returns the result, the folder's names afterwards, the requests the stub saw and the
  /// progress reports.
  static func download(
    _ release: UpdateRelease, answers: [UpdateStubProtocol.Answer]
  ) async throws -> (UpdateDownloadResult, [String], [URLRequest], [UpdateDownloadProgress]) {
    UpdateStubProtocol.register(answers, key: release.tag)
    defer { UpdateStubProtocol.remove(release.tag) }
    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = ProgressLog()
    let result = await UpdateDownloader(transport: transport).download(
      release, into: staging, progress: { log.record($0) })
    return (
      result, try Support.names(folder), UpdateStubProtocol.requests(release.tag), log.all
    )
  } // End of static func download(_:answers:)

  /// A 200 answer with `body` (and its `Content-Length` when `length`).
  static func ok(_ body: Data, length: Bool = true) -> UpdateStubProtocol.Answer {
    .http(
      status: 200, headers: length ? ["Content-Length": "\(body.count)"] : [:], body: body)
  }

  /// The file lands in the staging folder (0600, the same bytes), with progress up to the
  /// declared size, after exactly one request with only the expected headers.
  @Test func downloadsIntoTheStagingFolder() async throws {
    let body = Support.randomData(300_000)
    let release = Support.release(tag: Support.uniqueTag(), body: body)
    UpdateStubProtocol.register([Self.ok(body)], key: release.tag)
    defer { UpdateStubProtocol.remove(release.tag) }
    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = ProgressLog()
    let result = await UpdateDownloader(transport: Self.transport).download(
      release, into: staging, progress: { log.record($0) })
    #expect(
      result
        == .downloaded(
          UpdateDownloadedFile(
            name: "muxFinder.zip", size: body.count, sha256: Support.sha256(body))))
    let file = folder.appending(path: "muxFinder.zip")
    #expect(try Data(contentsOf: file) == body)
    #expect(try LaunchTestSupport.permissions(of: file) == 0o600)
    let reports = log.all
    #expect(!reports.isEmpty)
    #expect(reports.map(\.received) == reports.map(\.received).sorted())
    #expect(reports.last == UpdateDownloadProgress(received: body.count, expected: body.count))
    #expect(reports.allSatisfy { $0.expected == body.count })
    #expect(reports.last?.fraction == 1)
    let requests = UpdateStubProtocol.requests(release.tag)
    try #require(requests.count == 1)
    let request = requests[0]
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == UpdateSource.assetDownloadURL(forTag: release.tag))
    #expect(request.timeoutInterval == 30)
    #expect(
      request.allHTTPHeaderFields == [
        "Accept": "application/octet-stream", "Accept-Encoding": "identity",
        "Accept-Language": "en", "User-Agent": "muxFinder/0.2.0",
      ])
    #expect(request.httpShouldHandleCookies == false)
  } // End of func downloadsIntoTheStagingFolder()

  /// The configuration: ephemeral, nothing stored, 30 s and 20 min, TLS 1.2, the stub only;
  /// the real transport keeps the system's protocols.
  @Test func configurationStoresNothing() {
    let configuration = Self.transport.makeConfiguration()
    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.httpCookieAcceptPolicy == .never)
    #expect(configuration.httpShouldSetCookies == false)
    #expect(configuration.urlCache == nil)
    #expect(configuration.urlCredentialStorage == nil)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(configuration.timeoutIntervalForRequest == 30)
    #expect(configuration.timeoutIntervalForResource == 1200)
    #expect(configuration.httpAdditionalHeaders == nil)
    #expect(configuration.waitsForConnectivity == false)
    #expect(configuration.tlsMinimumSupportedProtocolVersion == .TLSv12)
    #expect(configuration.protocolClasses?.count == 1)
    let real = URLSessionUpdateDownloadTransport(shortVersion: "0.2.0")
    #expect(real.protocolClasses.isEmpty)
    #expect(real.userAgent == "muxFinder/0.2.0")
    #expect(URLSessionUpdateDownloadTransport(shortVersion: "v1").userAgent == "muxFinder/unknown")
  } // End of func configurationStoresNothing()

  /// More bytes than declared (no `Content-Length`) stop the transfer: `tooLarge`, nothing
  /// left; fewer: `incomplete`, nothing left.
  @Test func sizeIsExact() async throws {
    let body = Support.randomData(200_000)
    let longer = body + Data([1])
    let release = Support.release(tag: Support.uniqueTag(), body: body)
    let (over, overNames, _, overProgress) = try await Self.download(
      release, answers: [Self.ok(longer, length: false)])
    #expect(over == .failed(.tooLarge))
    #expect(overNames.isEmpty)
    #expect(overProgress.allSatisfy { $0.received <= body.count })

    let shorter = Support.release(tag: Support.uniqueTag(), body: body + Data([2]))
    let (short, shortNames, _, _) = try await Self.download(
      shorter, answers: [Self.ok(body, length: false)])
    #expect(short == .failed(.incomplete))
    #expect(shortNames.isEmpty)
  } // End of func sizeIsExact()

  /// A `Content-Length` other than the declared size stops it before reading.
  @Test func contentLengthMismatchStopsBeforeReading() async throws {
    let body = Support.randomData(100_000)
    let release = Support.release(tag: Support.uniqueTag(), body: body)
    let answer = UpdateStubProtocol.Answer.http(
      status: 200, headers: ["Content-Length": "\(body.count + 5)"], body: body)
    let (result, names, _, progress) = try await Self.download(release, answers: [answer])
    #expect(result == .failed(.contentLengthMismatch))
    #expect(names.isEmpty)
    #expect(progress.isEmpty)
  }

  /// A digest other than the release's deletes the file.
  @Test func digestMismatchDeletesTheFile() async throws {
    let body = Support.randomData(150_000)
    var wrong = Array(Support.sha256(body))
    wrong[0] = wrong[0] == "0" ? "1" : "0"
    let release = Support.release(tag: Support.uniqueTag(), body: body, digest: String(wrong))
    let (result, names, _, progress) = try await Self.download(release, answers: [Self.ok(body)])
    #expect(result == .failed(.digestMismatch))
    #expect(names.isEmpty)
    #expect(progress.last?.received == body.count)
  }

  /// Redirects to `https` on GitHub's download hosts are followed (up to five); others are
  /// refused with a typed reason and never requested.
  @Test func redirectsFollowTheAllowlistOnly() async throws {
    let body = Support.randomData(10_000)
    for host in ["objects.githubusercontent.com", "release-assets.githubusercontent.com"] {
      let release = Support.release(tag: Support.uniqueTag(), body: body)
      let hop = URL(string: "https://\(host)/stub/\(release.tag)/asset")!
      let (result, names, requests, _) = try await Self.download(
        release, answers: [.redirect(to: hop, status: 302), Self.ok(body)])
      #expect(
        result
          == .downloaded(
            UpdateDownloadedFile(
              name: "muxFinder.zip", size: body.count, sha256: Support.sha256(body))), "\(host)")
      #expect(names == ["muxFinder.zip"])
      #expect(requests.map { $0.url?.host } == ["github.com", host])
    } // End of loop over allowed hosts
    let refused: [(String, UpdateRedirectRefusal)] = [
      ("http://objects.githubusercontent.com/stub/K/asset", .notHTTPS),
      ("https://example.com/stub/K/asset", .hostNotAllowed),
      ("https://objects.githubusercontent.com.example.com/stub/K/asset", .hostNotAllowed),
      ("https://api.github.com/stub/K/asset", .hostNotAllowed),
      ("https://user@objects.githubusercontent.com/stub/K/asset", .credentialsOrPort),
      ("https://objects.githubusercontent.com:8443/stub/K/asset", .credentialsOrPort),
      ("ftp://github.com/stub/K/asset", .notHTTPS),
    ]
    for (target, refusal) in refused {
      let release = Support.release(tag: Support.uniqueTag(), body: body)
      let url = URL(string: target.replacingOccurrences(of: "/K/", with: "/\(release.tag)/"))!
      let (result, names, requests, _) = try await Self.download(
        release, answers: [.redirect(to: url, status: 302), Self.ok(body)])
      #expect(result == .failed(.redirectRefused(refusal)), "\(target)")
      #expect(names.isEmpty)
      #expect(requests.count == 1, "\(target)")
    } // End of loop over refused targets
  } // End of func redirectsFollowTheAllowlistOnly()

  /// A sixth redirect is refused.
  @Test func tooManyRedirects() async throws {
    let body = Support.randomData(1_000)
    let release = Support.release(tag: Support.uniqueTag(), body: body)
    let hop = URL(string: "https://objects.githubusercontent.com/stub/\(release.tag)/asset")!
    let answers =
      Array(repeating: UpdateStubProtocol.Answer.redirect(to: hop, status: 302), count: 6)
      + [Self.ok(body)]
    let (result, names, requests, _) = try await Self.download(release, answers: answers)
    #expect(result == .failed(.redirectRefused(.tooManyRedirects)))
    #expect(names.isEmpty)
    #expect(requests.count == 6)
  } // End of func tooManyRedirects()

  /// The redirect rule on its own.
  @Test func redirectRule() {
    #expect(
      URLSessionUpdateDownloadTransport.redirectRefusal(
        for: URL(string: "https://github.com/ccarpiog/muxFinder/x")) == nil)
    #expect(
      URLSessionUpdateDownloadTransport.redirectRefusal(
        for: URL(string: "https://objects.githubusercontent.com:443/x")) == nil)
    #expect(URLSessionUpdateDownloadTransport.redirectRefusal(for: nil) == .notHTTPS)
    #expect(
      URLSessionUpdateDownloadTransport.redirectRefusal(
        for: URL(string: "https://GITHUB.com/x")) == .hostNotAllowed)
    #expect(
      URLSessionUpdateDownloadTransport.redirectRefusal(
        for: URL(string: "https://u:p@github.com/x")) == .credentialsOrPort)
  } // End of func redirectRule()

  /// An `http` asset is never sent (`notHTTPS`), and the downloader refuses any asset URL
  /// other than the release's exact one before creating anything.
  @Test func onlyTheExactHTTPSAssetURL() async throws {
    let body = Support.randomData(1_000)
    let tag = Support.uniqueTag()
    let http = UpdateAsset(
      downloadURL: URL(
        string: "http://github.com/ccarpiog/muxFinder/releases/download/\(tag)/muxFinder.zip")!,
      sha256: Support.sha256(body), size: body.count)
    UpdateStubProtocol.register([Self.ok(body)], key: tag)
    defer { UpdateStubProtocol.remove(tag) }
    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }
    let descriptor = try staging.createFile(named: "probe.bin")
    let sink = UpdateDownloadSink(
      descriptor: descriptor, declaredSize: body.count, progress: { _ in })
    let fetched = await Self.transport.fetch(http, into: sink)
    guard case .failure(.notHTTPS) = fetched else {
      Issue.record("an http asset was fetched: \(fetched)")
      return
    }
    #expect(UpdateStubProtocol.requests(tag).isEmpty)
    _ = sink.finish()
    staging.remove(named: "probe.bin")

    let version = UpdateVersion(tag: tag)!
    let page = URL(string: "https://github.com/ccarpiog/muxFinder/releases/tag/\(tag)")!
    for url in [
      "http://github.com/ccarpiog/muxFinder/releases/download/\(tag)/muxFinder.zip",
      "https://github.com/ccarpiog/muxFinder/releases/download/v9.9.9/muxFinder.zip",
      "https://objects.githubusercontent.com/ccarpiog/muxFinder/releases/download/\(tag)/muxFinder.zip",
    ] {
      let asset = UpdateAsset(
        downloadURL: URL(string: url)!, sha256: Support.sha256(body), size: body.count)
      let release = UpdateRelease(version: version, pageURL: page, asset: asset, assetProblem: nil)
      let result = await UpdateDownloader(transport: Self.transport).download(
        release, into: staging)
      #expect(result == .failed(.foreignURL), "\(url)")
    } // End of loop over foreign URLs
    let bare = UpdateRelease(version: version, pageURL: page, asset: nil, assetProblem: .missing)
    #expect(
      await UpdateDownloader(transport: Self.transport).download(bare, into: staging)
        == .failed(.noInstallableAsset))
    #expect(UpdateStubProtocol.requests(tag).isEmpty)
    #expect(try Support.names(folder).isEmpty)
  } // End of func onlyTheExactHTTPSAssetURL()

  /// HTTP errors are `httpStatus`; failures map to offline, timed out and other; nothing is
  /// left in the staging folder.
  @Test func errorsMap() async throws {
    let body = Support.randomData(1_000)
    let cases: [(UpdateStubProtocol.Answer, UpdateDownloadFailure)] = [
      (.http(status: 404, headers: [:], body: Data("no".utf8)), .httpStatus(404)),
      (.http(status: 500, headers: [:], body: Data()), .httpStatus(500)),
      (.http(status: 403, headers: [:], body: Data()), .httpStatus(403)),
      (.http(status: 206, headers: [:], body: body), .httpStatus(206)),
      (.failure(.timedOut), .timedOut),
      (.failure(.notConnectedToInternet), .offline),
      (.failure(.cannotFindHost), .offline),
      (.failure(.networkConnectionLost), .offline),
      (
        .failure(.secureConnectionFailed),
        .other("urlError.\(URLError.Code.secureConnectionFailed.rawValue)")
      ),
    ]
    for (answer, expected) in cases {
      let release = Support.release(tag: Support.uniqueTag(), body: body)
      let (result, names, _, _) = try await Self.download(release, answers: [answer])
      #expect(result == .failed(expected), "\(expected)")
      #expect(names.isEmpty)
    } // End of loop over the cases
  } // End of func errorsMap()

  /// Cancelling the task mid-transfer cancels the request and deletes the partial file.
  @Test func cancelDeletesThePartialFile() async throws {
    let body = Support.randomData(300_000)
    let release = Support.release(tag: Support.uniqueTag(), body: body)
    UpdateStubProtocol.register(
      [
        .hold(status: 200, headers: ["Content-Length": "\(body.count)"], body: body.prefix(100_000))
      ],
      key: release.tag)
    defer { UpdateStubProtocol.remove(release.tag) }
    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = ProgressLog()
    let task = Task {
      await UpdateDownloader(transport: Self.transport).download(
        release, into: staging, progress: { log.record($0) })
    }
    let started = await UpdateTestSupport.waitUntil { !log.all.isEmpty }
    #expect(started)
    #expect(try Support.names(folder) == ["muxFinder.zip"])
    task.cancel()
    let result = await task.value
    #expect(result == .failed(.cancelled))
    #expect(try Support.names(folder).isEmpty)
    #expect((log.all.last?.received ?? 0) < body.count)
  } // End of func cancelDeletesThePartialFile()

  /// The sink refuses a byte past the declared size and writes nothing of that chunk.
  @Test func sinkBound() throws {
    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }
    let sink = UpdateDownloadSink(
      descriptor: try staging.createFile(named: "f"), declaredSize: 4, progress: { _ in })
    try sink.append(Data([1, 2, 3]))
    #expect(throws: UpdateDownloadFailure.tooLarge) { try sink.append(Data([4, 5])) }
    try sink.append(Data([4]))
    let (size, digest) = sink.finish()
    #expect(size == 4)
    #expect(digest == Support.sha256(Data([1, 2, 3, 4])))
    #expect(try Data(contentsOf: folder.appending(path: "f")) == Data([1, 2, 3, 4]))
  } // End of func sinkBound()

  /// The zip mode's copy: the bytes and digest; a mismatch, a missing file, a link, a folder,
  /// an empty file and a file over 50 MiB (sparse, never read) refused with nothing left; an
  /// existing `muxFinder.zip` is never replaced or removed.
  @Test func localCopy() throws {
    let base = try UpdateTestSupport.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let body = Support.randomData(70_000)
    let source = base.appending(path: "release.zip")
    try body.write(to: source)
    let path = source.path(percentEncoded: false)
    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }

    let copied = UpdateDownloader.copyLocalFile(
      atPath: path, expectedSHA256: Support.sha256(body), into: staging)
    #expect(
      copied
        == .downloaded(
          UpdateDownloadedFile(
            name: "muxFinder.zip", size: body.count, sha256: Support.sha256(body))))
    #expect(try Data(contentsOf: folder.appending(path: "muxFinder.zip")) == body)
    // An existing name is never replaced, nor removed by the failure.
    #expect(
      UpdateDownloader.copyLocalFile(
        atPath: path, expectedSHA256: Support.sha256(body), into: staging)
        == .failed(.writeFailed(errno: EEXIST)))
    #expect(try Data(contentsOf: folder.appending(path: "muxFinder.zip")) == body)
    staging.remove(named: "muxFinder.zip")

    #expect(
      UpdateDownloader.copyLocalFile(
        atPath: path, expectedSHA256: Support.sha256(Data()), into: staging)
        == .failed(.digestMismatch))
    let link = base.appending(path: "link.zip")
    try FileManager.default.createSymbolicLink(
      atPath: link.path(percentEncoded: false), withDestinationPath: path)
    let empty = base.appending(path: "empty.zip")
    try Data().write(to: empty)
    let huge = base.appending(path: "huge.zip")
    let descriptor = open(huge.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL, 0o600)
    #expect(ftruncate(descriptor, off_t(UpdateReleaseParser.maximumAssetSize + 1)) == 0)
    close(descriptor)
    for (candidate, failure) in [
      (base.appending(path: "missing.zip"), UpdateDownloadFailure.sourceUnreadable),
      (link, .sourceUnreadable), (base, .sourceUnreadable), (empty, .sourceUnreadable),
      (huge, .tooLarge),
    ] {
      #expect(
        UpdateDownloader.copyLocalFile(
          atPath: candidate.path(percentEncoded: false), expectedSHA256: Support.sha256(body),
          into: staging) == .failed(failure), "\(candidate.lastPathComponent)")
    } // End of loop over unusable sources
    #expect(try Support.names(folder).isEmpty)
  } // End of func localCopy()

  /// Codes and reasons: reasons name no host or path.
  @Test func reasonsAreShort() {
    let failures: [UpdateDownloadFailure] = [
      .noInstallableAsset, .foreignURL, .notHTTPS, .redirectRefused(.hostNotAllowed),
      .redirectRefused(.notHTTPS), .redirectRefused(.credentialsOrPort),
      .redirectRefused(.tooManyRedirects), .httpStatus(404), .contentLengthMismatch, .tooLarge,
      .incomplete, .digestMismatch, .offline, .timedOut, .cancelled, .sourceUnreadable,
      .writeFailed(errno: EACCES), .other("x"),
    ]
    for failure in failures {
      #expect(!failure.reason.isEmpty)
      #expect(!failure.reason.contains("githubusercontent"))
      #expect(!failure.reason.contains("/"))
      #expect(failure.reason.first?.isLowercase == true)
    } // End of loop over the failures
    #expect(
      UpdateDownloadFailure.redirectRefused(.hostNotAllowed).code
        == "redirectRefused.hostNotAllowed")
    #expect(UpdateDownloadFailure.httpStatus(404).code == "httpStatus.404")
  } // End of func reasonsAreShort()
}
