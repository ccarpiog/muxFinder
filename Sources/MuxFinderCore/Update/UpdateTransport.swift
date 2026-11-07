import Foundation

/// Why a request got no HTTP answer.
public enum UpdateTransportFailure: Sendable, Hashable {
  /// The Mac is offline, or the host could not be found or reached.
  case offline
  /// The request or the whole exchange ran out of time.
  case timedOut
  /// Anything else, with a short machine-readable detail (never a URL or a body).
  case other(String)

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .offline: return "offline"
    case .timedOut: return "timedOut"
    case .other(let detail): return "other.\(detail)"
    }
  }
}

/// What one `releases/latest` request came to (PLAN.md D39), as the scheduler needs it.
public enum UpdateCheckResponse: Sendable, Hashable {
  /// A 200 answer: its body (at most `UpdateReleaseParser.maximumBodySize` bytes) and its
  /// `ETag`, when it has a usable one.
  case body(Data, etag: String?)
  /// A 304 answer to `If-None-Match`: the release is the one of the last 200 answer.
  case notModified
  /// A 403 or 429 answer that says the rate limit is used up, with the time it resets.
  case rateLimited(until: Date)
  /// Another HTTP status (a redirect away from `api.github.com` included).
  case httpStatus(Int)
  /// The body is larger than `UpdateReleaseParser.maximumBodySize`; the rest was not read.
  case tooLarge
  /// No HTTP answer.
  case failed(UpdateTransportFailure)
}

/// Sends the update check's one request (PLAN.md D39): `URLSessionUpdateTransport` in the app
/// and the probe, fakes in tests (no test ever sends a real request).
public protocol UpdateCheckTransport: Sendable {
  /// `GET /repos/ccarpiog/muxFinder/releases/latest`, with `If-None-Match: etag` when `etag`
  /// is given. Never throws: every failure is a response.
  func latestRelease(etag: String?) async -> UpdateCheckResponse
}

/// Reads the rate-limit headers of a 403 or 429 answer (PLAN.md D39).
public enum UpdateRateLimit {
  /// The rate limit's date for an answer with `status` and `header`, or `nil` when it is not a
  /// rate limit: a 403 or 429 with `x-ratelimit-remaining: 0` and `x-ratelimit-reset` (seconds
  /// since 1970), or with `retry-after` (seconds from `now`). With both, the later date wins.
  /// The result is never earlier than `now` (the reset may already have passed by the local
  /// clock); how far ahead the scheduler honours it is `UpdateScheduler`'s rule.
  public static func until(
    status: Int, header: (String) -> String?, now: Date
  ) -> Date? {
    guard status == 403 || status == 429 else { return nil }
    var dates: [Date] = []
    if let remaining = header("x-ratelimit-remaining").flatMap(seconds), remaining == 0,
      let reset = header("x-ratelimit-reset").flatMap(seconds)
    {
      dates.append(Date(timeIntervalSince1970: TimeInterval(reset)))
    }
    if let delay = header("retry-after").flatMap(seconds) {
      dates.append(now.addingTimeInterval(TimeInterval(delay)))
    }
    guard let latest = dates.max() else { return nil }
    return max(latest, now)
  } // End of static func until(status:header:now:)

  /// A header value that is 1 to 12 ASCII digits (surrounding spaces allowed), or `nil`.
  static func seconds(_ text: String) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 12,
      trimmed.utf8.allSatisfy({ (0x30...0x39).contains($0) })
    else { return nil }
    return Int(trimmed)
  }
}

/// The update check's request over `URLSession` (PLAN.md D39). Each request gets its own
/// session from an ephemeral configuration with no cookie, cache or credential storage, a
/// 15 s request timeout and a 30 s resource timeout, invalidated once the request ends. The
/// request is a `GET` of `UpdateSource.latestReleaseURL` with only `Accept:
/// application/vnd.github+json`, `User-Agent: muxFinder/<short version>`, a constant
/// `Accept-Language: en` (else the system adds the user's languages) and, given an `ETag`,
/// `If-None-Match`: no token and nothing else identifying. Only `https` is sent, and a redirect
/// is followed only to `https://api.github.com`. The body is read up to
/// `UpdateReleaseParser.maximumBodySize` bytes and the request is cancelled past that.
public struct URLSessionUpdateTransport: UpdateCheckTransport {
  /// The request timeout, in seconds.
  public static let requestTimeout: TimeInterval = 15
  /// The resource timeout, in seconds.
  public static let resourceTimeout: TimeInterval = 30
  /// The `Accept` header's value.
  public static let acceptHeader = "application/vnd.github+json"
  /// The `Accept-Language` header's value: a constant, so the system's URL loading does not
  /// add one built from the user's language preferences.
  public static let acceptLanguageHeader = "en"
  /// The longest `ETag` kept and sent back.
  public static let maximumETagLength = 256

  /// The `User-Agent` header's value.
  public let userAgent: String
  /// The URL requested: `UpdateSource.latestReleaseURL` except in tests.
  let url: URL
  /// `URLProtocol` classes that replace the system's on each session's configuration (tests
  /// register only their stub here, so no request can reach the network); empty in the app and
  /// the probe, which keep the system's.
  let protocolClasses: [AnyClass]
  /// The wall clock, for a `retry-after` delay.
  let now: @Sendable () -> Date

  /// The transport for an app whose `CFBundleShortVersionString` is `shortVersion` (it goes into
  /// the `User-Agent` only when it is a version of ours, `unknown` otherwise).
  public init(shortVersion: String?) {
    self.init(shortVersion: shortVersion, url: UpdateSource.latestReleaseURL)
  }

  /// The designated initializer; tests pass a stub's protocol class and another clock.
  init(
    shortVersion: String?,
    url: URL,
    protocolClasses: [AnyClass] = [],
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    let version = shortVersion.flatMap({ UpdateVersion($0) })?.description ?? "unknown"
    userAgent = "muxFinder/\(version)"
    self.url = url
    self.protocolClasses = protocolClasses
    self.now = now
  }

  /// The configuration of each request's session.
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

  /// The request: a `GET` with only the headers above, no cookies, no cache.
  func makeRequest(etag: String?) -> URLRequest {
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: Self.requestTimeout)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue(Self.acceptHeader, forHTTPHeaderField: "Accept")
    request.setValue(Self.acceptLanguageHeader, forHTTPHeaderField: "Accept-Language")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    if let etag = etag.flatMap(Self.usableETag) {
      request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }
    return request
  } // End of func makeRequest(etag:)

  /// `text` when it can be sent back as `If-None-Match`: 1 to `maximumETagLength` printable
  /// ASCII characters; `nil` otherwise.
  public static func usableETag(_ text: String) -> String? {
    guard !text.isEmpty, text.utf8.count <= maximumETagLength,
      text.utf8.allSatisfy({ (0x20...0x7E).contains($0) })
    else { return nil }
    return text
  }

  /// Whether a redirect to `url` is followed: only to `https` on `api.github.com` (no user,
  /// password or other port).
  public static func followsRedirect(to url: URL?) -> Bool {
    guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
    else { return false }
    return components.scheme == "https" && components.host == UpdateSource.apiHost
      && components.user == nil && components.password == nil
      && (components.port == nil || components.port == 443)
  }

  /// Sends the request and reads the answer (see the type).
  public func latestRelease(etag: String?) async -> UpdateCheckResponse {
    guard url.scheme == "https" else { return .failed(.other("notHTTPS")) }
    let session = URLSession(
      configuration: makeConfiguration(), delegate: RedirectGuard(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let bytes: URLSession.AsyncBytes
    let response: URLResponse
    do {
      (bytes, response) = try await session.bytes(for: makeRequest(etag: etag))
    } catch {
      return .failed(Self.failure(error))
    }
    guard let http = response as? HTTPURLResponse else {
      bytes.task.cancel()
      return .failed(.other("notHTTP"))
    }
    let header: (String) -> String? = { http.value(forHTTPHeaderField: $0) }
    switch http.statusCode {
    case 200:
      return await readBody(bytes, response: http)
    case 304:
      bytes.task.cancel()
      return .notModified
    default:
      bytes.task.cancel()
      if let until = UpdateRateLimit.until(status: http.statusCode, header: header, now: now()) {
        return .rateLimited(until: until)
      }
      return .httpStatus(http.statusCode)
    }
  } // End of func latestRelease(etag:)

  /// Reads a 200 answer's body up to the bound, with its usable `ETag`.
  func readBody(_ bytes: URLSession.AsyncBytes, response: HTTPURLResponse) async
    -> UpdateCheckResponse
  {
    let limit = UpdateReleaseParser.maximumBodySize
    if response.expectedContentLength > Int64(limit) {
      bytes.task.cancel()
      return .tooLarge
    }
    var data = Data()
    do {
      for try await byte in bytes {
        data.append(byte)
        if data.count > limit {
          bytes.task.cancel()
          return .tooLarge
        }
      } // End of loop over the body's bytes
    } catch {
      return .failed(Self.failure(error))
    }
    let etag = response.value(forHTTPHeaderField: "ETag").flatMap(Self.usableETag)
    return .body(data, etag: etag)
  } // End of func readBody(_:response:)

  /// The failure an error of `URLSession` comes to.
  static func failure(_ error: any Error) -> UpdateTransportFailure {
    guard let error = error as? URLError else { return .other("error") }
    switch error.code {
    case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
      .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
      return .offline
    case .timedOut:
      return .timedOut
    default:
      return .other("urlError.\(error.code.rawValue)")
    }
  } // End of func failure(_:)
}

/// The session delegate that refuses every redirect except to `https://api.github.com`
/// (`URLSessionUpdateTransport.followsRedirect(to:)`); a refused redirect's own answer is then
/// the response (`httpStatus`).
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
  /// Follows `request` only when it stays on `https://api.github.com`.
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    URLSessionUpdateTransport.followsRedirect(to: request.url) ? request : nil
  }
}
