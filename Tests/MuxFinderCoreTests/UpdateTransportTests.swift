import Foundation
import Testing

@testable import MuxFinderCore

/// `URLSessionUpdateTransport` (PLAN.md D39) through `UpdateStubProtocol`, the only protocol
/// class on its sessions' configuration, so no request reaches the network: the headers it
/// sends, `If-None-Match`, no cookies, the timeouts, the body bound, the redirect rule, and how
/// answers and errors map to `UpdateCheckResponse`.
@Suite("Update transport")
struct UpdateTransportTests {
  /// A transport for `url` that goes only through the stub, on a fixed clock.
  static func transport(_ url: URL, version: String? = "0.2.0") -> URLSessionUpdateTransport {
    URLSessionUpdateTransport(
      shortVersion: version, url: url, protocolClasses: [UpdateStubProtocol.self],
      now: { ManualUpdateClock.baseDate })
  }

  /// A 200 answer with the canonical body and an `ETag`.
  static let ok = UpdateStubProtocol.Answer.http(
    status: 200, headers: ["ETag": "W/\"abc123\"", "Content-Type": "application/json"],
    body: Data(UpdateTestSupport.canonicalBody.utf8))

  /// The request carries exactly `Accept`, a constant `Accept-Language`, `User-Agent` and (given
  /// an `ETag`) `If-None-Match`, with the 15 s timeout, no cookie and no credential; the answer
  /// is the body and its `ETag`.
  @Test func sendsOnlyTheExpectedHeaders() async throws {
    let (url, key) = UpdateStubProtocol.register([Self.ok])
    defer { UpdateStubProtocol.remove(key) }
    let transport = Self.transport(url)
    let first = await transport.latestRelease(etag: nil)
    #expect(first == .body(Data(UpdateTestSupport.canonicalBody.utf8), etag: "W/\"abc123\""))
    let second = await transport.latestRelease(etag: "W/\"abc123\"")
    #expect(second == first)
    let requests = UpdateStubProtocol.requests(key)
    try #require(requests.count == 2)
    for (index, request) in requests.enumerated() {
      #expect(request.httpMethod == "GET")
      #expect(request.url == url)
      #expect(request.timeoutInterval == 15)
      let headers = request.allHTTPHeaderFields ?? [:]
      var expected = [
        "Accept": "application/vnd.github+json", "Accept-Language": "en",
        "User-Agent": "muxFinder/0.2.0",
      ]
      if index == 1 { expected["If-None-Match"] = "W/\"abc123\"" }
      #expect(headers == expected)
      #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      #expect(request.httpShouldHandleCookies == false)
    } // End of loop over the requests
  } // End of func sendsOnlyTheExpectedHeaders()

  /// A `Set-Cookie` in an answer is kept nowhere: the next request carries no cookie.
  @Test func keepsNoCookies() async throws {
    let answer = UpdateStubProtocol.Answer.http(
      status: 200, headers: ["Set-Cookie": "tracker=1; Domain=api.github.com; Path=/"],
      body: Data(UpdateTestSupport.canonicalBody.utf8))
    let (url, key) = UpdateStubProtocol.register([answer])
    defer { UpdateStubProtocol.remove(key) }
    let transport = Self.transport(url)
    _ = await transport.latestRelease(etag: nil)
    _ = await transport.latestRelease(etag: nil)
    let requests = UpdateStubProtocol.requests(key)
    try #require(requests.count == 2)
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
  } // End of func keepsNoCookies()

  /// The configuration: ephemeral, no cookie, cache or credential storage, 15 s and 30 s
  /// timeouts, no extra headers, no waiting for connectivity.
  @Test func configurationStoresNothing() {
    let configuration = Self.transport(UpdateSource.latestReleaseURL).makeConfiguration()
    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.httpCookieAcceptPolicy == .never)
    #expect(configuration.httpShouldSetCookies == false)
    #expect(configuration.urlCache == nil)
    #expect(configuration.urlCredentialStorage == nil)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(configuration.timeoutIntervalForRequest == 15)
    #expect(configuration.timeoutIntervalForResource == 30)
    #expect(configuration.httpAdditionalHeaders == nil)
    #expect(configuration.waitsForConnectivity == false)
    #expect(configuration.protocolClasses?.count == 1)
    let real = URLSessionUpdateTransport(shortVersion: "0.2.0")
    #expect(
      real.url == URL(string: "https://api.github.com/repos/ccarpiog/muxFinder/releases/latest"))
    #expect(real.protocolClasses.isEmpty)
    #expect(real.userAgent == "muxFinder/0.2.0")
  } // End of func configurationStoresNothing()

  /// The `User-Agent` names the version only when it is one of ours.
  @Test func userAgentVersion() {
    #expect(URLSessionUpdateTransport(shortVersion: "1.20.3").userAgent == "muxFinder/1.20.3")
    for odd in [nil, "", "0.2", "0.2.0 (2)", "v0.2.0", "0.2.0\r\nX: y"] as [String?] {
      #expect(URLSessionUpdateTransport(shortVersion: odd).userAgent == "muxFinder/unknown")
    }
  }

  /// An `ETag` that cannot be sent back is neither kept nor sent.
  @Test func unusableETagsAreDropped() async throws {
    #expect(URLSessionUpdateTransport.usableETag("W/\"x\"") == "W/\"x\"")
    for odd in ["", "a\r\nInjected: 1", "é", String(repeating: "a", count: 257)] {
      #expect(URLSessionUpdateTransport.usableETag(odd) == nil)
    }
    let answer = UpdateStubProtocol.Answer.http(
      status: 200, headers: ["ETag": String(repeating: "a", count: 300)],
      body: Data(UpdateTestSupport.canonicalBody.utf8))
    let (url, key) = UpdateStubProtocol.register([answer])
    defer { UpdateStubProtocol.remove(key) }
    let transport = Self.transport(url)
    #expect(
      await transport.latestRelease(etag: "bad\nvalue")
        == .body(Data(UpdateTestSupport.canonicalBody.utf8), etag: nil))
    let request = try #require(UpdateStubProtocol.requests(key).first)
    #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
  } // End of func unusableETagsAreDropped()

  /// 304 is `notModified`; 5xx and other statuses are `httpStatus`.
  @Test func statusesMap() async {
    for (status, expected) in [
      (304, UpdateCheckResponse.notModified), (500, .httpStatus(500)), (502, .httpStatus(502)),
      (404, .httpStatus(404)), (403, .httpStatus(403)), (429, .httpStatus(429)),
    ] {
      let (url, key) = UpdateStubProtocol.register([
        .http(status: status, headers: [:], body: Data("{}".utf8))
      ])
      #expect(await Self.transport(url).latestRelease(etag: "e") == expected, "\(status)")
      UpdateStubProtocol.remove(key)
    } // End of loop over the statuses
  } // End of func statusesMap()

  /// A rate limit in either form: `x-ratelimit-remaining: 0` with `x-ratelimit-reset`, or
  /// `retry-after`, on a 403 or a 429.
  @Test func rateLimitsMap() async {
    let base = ManualUpdateClock.baseDate
    let reset = Int(base.timeIntervalSince1970) + 1800
    let cases: [(Int, [String: String], UpdateCheckResponse)] = [
      (
        403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "\(reset)"],
        .rateLimited(until: base.addingTimeInterval(1800))
      ),
      (429, ["Retry-After": "120"], .rateLimited(until: base.addingTimeInterval(120))),
      (403, ["retry-after": " 60 "], .rateLimited(until: base.addingTimeInterval(60))),
      // Remaining calls left: not a rate limit.
      (403, ["x-ratelimit-remaining": "5", "x-ratelimit-reset": "\(reset)"], .httpStatus(403)),
      (403, ["x-ratelimit-remaining": "0"], .httpStatus(403)),
      (429, ["retry-after": "soon"], .httpStatus(429)),
      // A reset already past by the local clock is now.
      (
        403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "\(reset - 7200)"],
        .rateLimited(until: base)
      ),
      // Not a 403 or 429.
      (503, ["retry-after": "30"], .httpStatus(503)),
    ]
    for (status, headers, expected) in cases {
      let (url, key) = UpdateStubProtocol.register([
        .http(status: status, headers: headers, body: Data())
      ])
      #expect(await Self.transport(url).latestRelease(etag: nil) == expected, "\(headers)")
      UpdateStubProtocol.remove(key)
    } // End of loop over the cases
  } // End of func rateLimitsMap()

  /// Both rate-limit forms at once: the later date wins.
  @Test func laterRateLimitWins() {
    let base = ManualUpdateClock.baseDate
    let headers = [
      "x-ratelimit-remaining": "0",
      "x-ratelimit-reset": "\(Int(base.timeIntervalSince1970) + 10)", "retry-after": "300",
    ]
    #expect(
      UpdateRateLimit.until(status: 429, header: { headers[$0] }, now: base)
        == base.addingTimeInterval(300))
  }

  /// A body over 1 MiB is `tooLarge`, announced or not; exactly 1 MiB is read.
  @Test func boundsTheBody() async {
    let limit = UpdateReleaseParser.maximumBodySize
    let big = Data(repeating: 0x20, count: limit + 1)
    let (url, key) = UpdateStubProtocol.register([
      .http(status: 200, headers: [:], body: big),
      .http(status: 200, headers: ["Content-Length": "\(2 * limit)"], body: big),
      .http(status: 200, headers: [:], body: Data(repeating: 0x20, count: limit)),
    ])
    defer { UpdateStubProtocol.remove(key) }
    let transport = Self.transport(url)
    #expect(await transport.latestRelease(etag: nil) == .tooLarge)
    #expect(await transport.latestRelease(etag: nil) == .tooLarge)
    #expect(
      await transport.latestRelease(etag: nil)
        == .body(Data(repeating: 0x20, count: limit), etag: nil))
  } // End of func boundsTheBody()

  /// Errors: offline, timed out, anything else.
  @Test func failuresMap() async {
    for (code, expected) in [
      (URLError.Code.notConnectedToInternet, UpdateTransportFailure.offline),
      (.cannotFindHost, .offline), (.networkConnectionLost, .offline),
      (.timedOut, .timedOut),
      (
        .secureConnectionFailed, .other("urlError.\(URLError.Code.secureConnectionFailed.rawValue)")
      ),
    ] {
      let (url, key) = UpdateStubProtocol.register([.failure(code)])
      #expect(await Self.transport(url).latestRelease(etag: nil) == .failed(expected))
      UpdateStubProtocol.remove(key)
    } // End of loop over the errors
    #expect(UpdateTransportTests.failure(CancellationError()) == .other("error"))
  } // End of func failuresMap()

  /// The failure for a non-URL error.
  static func failure(_ error: any Error) -> UpdateTransportFailure {
    URLSessionUpdateTransport.failure(error)
  }

  /// A redirect away from `api.github.com` (or off `https`) is not followed: the redirect's
  /// own status is the answer and the other host never sees a request. A redirect within
  /// `https://api.github.com` is followed.
  @Test func refusesForeignRedirects() async throws {
    for target in [
      "https://evil.example/stub/KEY/x", "http://api.github.com/stub/KEY/x",
      "https://api.github.com.evil.example/stub/KEY/x", "https://github.com/stub/KEY/x",
      "https://user@api.github.com/stub/KEY/x", "https://api.github.com:8443/stub/KEY/x",
    ] {
      let key = UUID().uuidString
      let url = URL(string: "https://api.github.com/stub/\(key)/releases/latest")!
      let foreign = URL(string: target.replacingOccurrences(of: "KEY", with: key))!
      UpdateStubProtocol.routes.withLock {
        $0[key] = UpdateStubProtocol.Route(answers: [.redirect(to: foreign, status: 302), Self.ok])
      }
      defer { UpdateStubProtocol.remove(key) }
      #expect(await Self.transport(url).latestRelease(etag: nil) == .httpStatus(302), "\(target)")
      let seen = UpdateStubProtocol.requests(key).compactMap(\.url)
      #expect(seen == [url], "\(target)")
    } // End of loop over the foreign targets
    let key = UUID().uuidString
    let url = URL(string: "https://api.github.com/stub/\(key)/releases/latest")!
    let moved = URL(string: "https://api.github.com/stub/\(key)/moved")!
    UpdateStubProtocol.routes.withLock {
      $0[key] = UpdateStubProtocol.Route(answers: [.redirect(to: moved, status: 301), Self.ok])
    }
    defer { UpdateStubProtocol.remove(key) }
    #expect(
      await Self.transport(url).latestRelease(etag: nil)
        == .body(Data(UpdateTestSupport.canonicalBody.utf8), etag: "W/\"abc123\""))
    #expect(UpdateStubProtocol.requests(key).compactMap(\.url) == [url, moved])
  } // End of func refusesForeignRedirects()

  /// The redirect rule itself.
  @Test func redirectRule() {
    #expect(URLSessionUpdateTransport.followsRedirect(to: URL(string: "https://api.github.com/x")))
    #expect(
      URLSessionUpdateTransport.followsRedirect(to: URL(string: "https://api.github.com:443/x")))
    for target in [
      "http://api.github.com/x", "https://github.com/x", "https://objects.githubusercontent.com/x",
      "https://a:b@api.github.com/x", "https://api.github.com:80/x", "ftp://api.github.com/x",
    ] {
      #expect(!URLSessionUpdateTransport.followsRedirect(to: URL(string: target)), "\(target)")
    }
    #expect(!URLSessionUpdateTransport.followsRedirect(to: nil))
  } // End of func redirectRule()

  /// Only `https` is ever sent.
  @Test func refusesPlainHTTP() async {
    let transport = URLSessionUpdateTransport(
      shortVersion: "0.2.0", url: URL(string: "http://api.github.com/stub/none/x")!,
      protocolClasses: [UpdateStubProtocol.self])
    #expect(await transport.latestRelease(etag: nil) == .failed(.other("notHTTPS")))
  }
}
