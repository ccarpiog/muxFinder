import Foundation
import Testing
import os

@testable import MuxFinderCore

/// Shared fixtures of the update check's tests (PLAN.md D39, Phase I-13a). Nothing here sends a
/// real request: bodies are synthetic JSON written by hand, the scheduler's transport is
/// `FakeUpdateTransport`, and the `URLSession` transport only ever talks to `UpdateStubProtocol`.
enum UpdateTestSupport {
  /// A digest in the form GitHub sends (`sha256:` plus 64 hex characters, mixed case here to
  /// prove the normalization).
  static let digest = "sha256:" + String(repeating: "Ab01", count: 16)
  /// The same digest normalized.
  static let normalizedDigest = String(repeating: "ab01", count: 16)

  /// A hand-written `releases/latest` body for `v0.3.0` with its installable asset.
  static let canonicalBody = """
    {
      "url": "https://api.github.com/repos/ccarpiog/muxFinder/releases/1",
      "html_url": "https://github.com/ccarpiog/muxFinder/releases/tag/v0.3.0",
      "id": 1,
      "tag_name": "v0.3.0",
      "name": "muxFinder 0.3.0",
      "draft": false,
      "prerelease": false,
      "assets": [
        {
          "name": "muxFinder.zip",
          "content_type": "application/zip",
          "state": "uploaded",
          "size": 6123456,
          "digest": "sha256:\(String(repeating: "Ab01", count: 16))",
          "browser_download_url": "https://github.com/ccarpiog/muxFinder/releases/download/v0.3.0/muxFinder.zip"
        }
      ],
      "body": "Synthetic release notes."
    }
    """

  /// A synthetic release body built from its parts; `nil` values are left out. `assets`
  /// replaces the default single asset when given.
  static func body(
    tag: Any? = "v0.3.0",
    page: Any? = "https://github.com/ccarpiog/muxFinder/releases/tag/v0.3.0",
    draft: Any? = false,
    prerelease: Any? = false,
    assets: [[String: Any]]? = nil
  ) -> Data {
    var fields: [String: Any] = ["id": 1, "name": "Synthetic"]
    fields["tag_name"] = tag
    fields["html_url"] = page
    fields["draft"] = draft
    fields["prerelease"] = prerelease
    let tagText = tag as? String ?? "v0.3.0"
    fields["assets"] = assets ?? [asset(tag: tagText)]
    return try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
  } // End of func body(tag:page:draft:prerelease:assets:)

  /// A synthetic asset entry; `nil` values are left out.
  static func asset(
    tag: String = "v0.3.0",
    name: Any? = "muxFinder.zip",
    url: Any? = nil,
    digest: Any? = UpdateTestSupport.digest,
    size: Any? = 6_123_456,
    state: Any? = "uploaded"
  ) -> [String: Any] {
    var entry: [String: Any] = ["content_type": "application/zip"]
    entry["name"] = name
    entry["browser_download_url"] =
      url ?? "https://github.com/ccarpiog/muxFinder/releases/download/\(tag)/muxFinder.zip"
    entry["digest"] = digest
    entry["size"] = size
    entry["state"] = state
    return entry
  } // End of func asset(tag:name:url:digest:size:state:)

  /// The release `canonicalBody` parses to.
  static func release(
    _ tag: String = "v0.3.0", withAsset: Bool = true
  ) -> UpdateRelease {
    guard
      case .release(let release) = UpdateReleaseParser.parse(
        body(
          tag: tag, page: "https://github.com/ccarpiog/muxFinder/releases/tag/\(tag)",
          assets: withAsset ? nil : []))
    else { fatalError("the synthetic release does not parse") }
    return release
  } // End of func release(_:withAsset:)

  /// Waits (real time, bounded) until `condition` holds.
  static func waitUntil(
    within limit: Duration = .seconds(10),
    _ condition: () async -> Bool
  ) async -> Bool {
    await RefreshTestSupport.waitUntil(within: limit, condition)
  }

  /// A private folder physically under `/private/tmp` (no symbolic link on its path), from
  /// `mkdtemp`. The caller removes it.
  static func makePrivateFolder() throws -> URL {
    var template = Array("/private/tmp/mfx-update.XXXXXX".utf8CString)
    guard let path = mkdtemp(&template) else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
  }
}

/// A transport that answers from a script and records what it was asked; it can hold every
/// request until the test releases it.
final class FakeUpdateTransport: UpdateCheckTransport, Sendable {
  /// Mutable state.
  private struct State {
    /// Answers given in order; once used up, `fallback`.
    var script: [UpdateCheckResponse]
    /// The answer after the script.
    var fallback: UpdateCheckResponse
    /// The `ETag` of every request, in order.
    var etags: [String?] = []
    /// Whether requests wait for `releaseHeld()`.
    var holding = false
    /// Requests waiting.
    var held: [CheckedContinuation<Void, Never>] = []
  }

  /// The state.
  private let state: OSAllocatedUnfairLock<State>

  /// A transport answering `script`, then `fallback` every time.
  init(_ script: [UpdateCheckResponse] = [], fallback: UpdateCheckResponse = .httpStatus(500)) {
    state = OSAllocatedUnfairLock(initialState: State(script: script, fallback: fallback))
  }

  /// Records the request, waits while holding, then answers.
  func latestRelease(etag: String?) async -> UpdateCheckResponse {
    let hold = state.withLock { state -> Bool in
      state.etags.append(etag)
      return state.holding
    }
    if hold {
      await withCheckedContinuation { continuation in
        let resumeNow = state.withLock { state -> Bool in
          guard state.holding else { return true }
          state.held.append(continuation)
          return false
        }
        if resumeNow { continuation.resume() }
      }
    }
    return state.withLock { state in
      state.script.isEmpty ? state.fallback : state.script.removeFirst()
    }
  } // End of func latestRelease(etag:)

  /// How many requests were made.
  var calls: Int { state.withLock { $0.etags.count } }
  /// The `ETag` of every request.
  var etags: [String?] { state.withLock { $0.etags } }
  /// How many requests wait.
  var heldCount: Int { state.withLock { $0.held.count } }

  /// Makes later requests wait for `releaseHeld()`.
  func hold() { state.withLock { $0.holding = true } }

  /// Lets every waiting and later request go.
  func releaseHeld() {
    let held = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.holding = false
      defer { state.held = [] }
      return state.held
    }
    for continuation in held { continuation.resume() }
  }

  /// Replaces the answers.
  func setScript(_ script: [UpdateCheckResponse], fallback: UpdateCheckResponse) {
    state.withLock {
      $0.script = script
      $0.fallback = fallback
    }
  }
}

/// A state store whose `load()` does not return until the test calls `releaseLoad()`, to model
/// a load still pending past the launch delay; saves are kept in memory.
final class SuspendedUpdateStateStore: UpdateStateStoring, Sendable {
  /// Mutable state.
  private struct State {
    /// The state a load gives and saves replace.
    var state: UpdateState
    /// Whether loads may return.
    var released = false
    /// Loads waiting for `releaseLoad()`.
    var waiting: [CheckedContinuation<Void, Never>] = []
    /// How many loads were asked for.
    var loadCalls = 0
    /// How many saves were kept.
    var saveCount = 0
  }

  /// The state.
  private let lock: OSAllocatedUnfairLock<State>

  /// A store holding `state`, its loads suspended.
  init(_ state: UpdateState) {
    lock = OSAllocatedUnfairLock(initialState: State(state: state))
  }

  /// Counts the load, waits for `releaseLoad()`, then gives the state (as `saved`, or
  /// `missing` while it is empty).
  func load() async -> UpdateStateLoadResult {
    let released = lock.withLock { state -> Bool in
      state.loadCalls += 1
      return state.released
    }
    if !released {
      await withCheckedContinuation { continuation in
        let resumeNow = lock.withLock { state -> Bool in
          guard !state.released else { return true }
          state.waiting.append(continuation)
          return false
        }
        if resumeNow { continuation.resume() }
      }
    }
    let state = lock.withLock { $0.state }
    return UpdateStateLoadResult(state: state, found: state == UpdateState() ? .missing : .saved)
  } // End of func load()

  /// Keeps `state`.
  func save(_ state: UpdateState) async throws(UpdateStateStoreError) {
    lock.withLock {
      $0.state = state
      $0.saveCount += 1
    }
  }

  /// Lets every waiting and later load return.
  func releaseLoad() {
    let waiting = lock.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.released = true
      defer { state.waiting = [] }
      return state.waiting
    }
    for continuation in waiting { continuation.resume() }
  }

  /// How many loads were asked for.
  var loadCalls: Int { lock.withLock { $0.loadCalls } }
  /// How many saves were kept.
  var saveCount: Int { lock.withLock { $0.saveCount } }
}

/// A clock whose time moves only when a test says: `advance(by:)` moves the wall clock and
/// ends the sleeps it reaches; `shiftWallClock(by:)` moves only the wall clock (the user set
/// the clock back or forward), which no sleep notices.
final class ManualUpdateClock: UpdateClock, Sendable {
  /// The wall-clock time virtual time starts from (whole seconds).
  static let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

  /// One waiting sleep.
  private struct Waiter {
    /// When it ends, in virtual time.
    let deadline: Duration
    /// Resumes the sleep.
    let continuation: CheckedContinuation<Void, any Error>
  }

  /// Mutable state.
  private struct State {
    /// Virtual time elapsed.
    var offset: Duration = .zero
    /// How far the wall clock was moved by hand, in seconds.
    var shift: TimeInterval = 0
    /// Waiting sleeps, by id.
    var waiters: [Int: Waiter] = [:]
    /// Ids of sleeps cancelled before they registered.
    var cancelledEarly: Set<Int> = []
    /// The next sleep's id.
    var nextID = 0
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// `baseDate` plus virtual time plus the hand shift.
  func date() -> Date {
    let (offset, shift) = state.withLock { ($0.offset, $0.shift) }
    return Self.baseDate.addingTimeInterval(Self.seconds(offset) + shift)
  }

  /// `duration` in seconds.
  static func seconds(_ duration: Duration) -> TimeInterval {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }

  /// Waits until virtual time reaches now + `duration`, or throws when cancelled.
  func sleep(for duration: Duration) async throws {
    let id = state.withLock { state -> Int in
      state.nextID += 1
      return state.nextID
    }
    if Task.isCancelled { throw CancellationError() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let immediate = state.withLock { state -> Result<Void, any Error>? in
          if state.cancelledEarly.remove(id) != nil { return .failure(CancellationError()) }
          guard duration > .zero else { return .success(()) }
          state.waiters[id] = Waiter(deadline: state.offset + duration, continuation: continuation)
          return nil
        }
        if let immediate { continuation.resume(with: immediate) }
      }
    } onCancel: {
      let waiter = state.withLock { state -> Waiter? in
        guard let waiter = state.waiters.removeValue(forKey: id) else {
          state.cancelledEarly.insert(id)
          return nil
        }
        return waiter
      }
      waiter?.continuation.resume(throwing: CancellationError())
    }
  } // End of func sleep(for:)

  /// Moves virtual time (and the wall clock) forward and ends every sleep it reaches.
  func advance(by duration: Duration) {
    let due = state.withLock { state -> [Waiter] in
      state.offset += duration
      let due = state.waiters.filter { $0.value.deadline <= state.offset }
      for id in due.keys { state.waiters[id] = nil }
      return Array(due.values)
    }
    for waiter in due { waiter.continuation.resume() }
  }

  /// Moves only the wall clock by `seconds` (negative: back).
  func shiftWallClock(by seconds: TimeInterval) {
    state.withLock { $0.shift += seconds }
  }

  /// How many sleeps wait now.
  var waiting: Int { state.withLock { $0.waiters.count } }

  /// How long until the nearest waiting sleep ends, or `nil`.
  var nextWake: Duration? {
    state.withLock { state in
      state.waiters.values.map(\.deadline).min().map { $0 - state.offset }
    }
  }
}

/// The `URLProtocol` stub the `URLSession` transport's tests register on its configuration (and
/// only it, so no request can reach the network). It claims every request, records it, and
/// answers as the test's route says; routes are keyed by the second path component of the
/// URL (`/stub/<key>/…`), so tests running in parallel never share one.
final class UpdateStubProtocol: URLProtocol, @unchecked Sendable {
  /// How the stub answers one request.
  enum Answer: Sendable {
    /// An HTTP answer with headers and a body (sent in chunks of at most 64 KiB).
    case http(status: Int, headers: [String: String], body: Data)
    /// A redirect to this URL with this status.
    case redirect(to: URL, status: Int)
    /// No answer: this error.
    case failure(URLError.Code)
  }

  /// One route: the answers in order (the last one repeats) and the requests seen.
  struct Route {
    /// The answers.
    var answers: [Answer]
    /// The requests seen, in order.
    var requests: [URLRequest] = []
  }

  /// Every route, by key.
  static let routes = OSAllocatedUnfairLock<[String: Route]>(initialState: [:])

  /// Registers `answers` under a new key and returns the URL to request
  /// (`https://api.github.com/stub/<key>/releases/latest`) and the key.
  static func register(_ answers: [Answer]) -> (url: URL, key: String) {
    let key = UUID().uuidString
    routes.withLock { $0[key] = Route(answers: answers) }
    return (URL(string: "https://api.github.com/stub/\(key)/releases/latest")!, key)
  }

  /// The requests seen under `key`.
  static func requests(_ key: String) -> [URLRequest] {
    routes.withLock { $0[key]?.requests ?? [] }
  }

  /// Removes `key`'s route.
  static func remove(_ key: String) {
    routes.withLock { $0[key] = nil }
  }

  /// The route key in `url`, or `nil`.
  static func key(of url: URL?) -> String? {
    let parts = url?.path(percentEncoded: false).split(separator: "/") ?? []
    return parts.count >= 2 ? String(parts[1]) : nil
  }

  /// Claims every request, so none is left to the system.
  override class func canInit(with request: URLRequest) -> Bool { true }

  /// The request as given.
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  /// Records the request and answers it.
  override func startLoading() {
    let request = self.request
    let answer = Self.routes.withLock { routes -> Answer? in
      guard let key = Self.key(of: request.url), var route = routes[key] else { return nil }
      route.requests.append(request)
      let answer = route.answers.count > 1 ? route.answers.removeFirst() : route.answers.first
      routes[key] = route
      return answer
    }
    guard let client, let url = request.url else { return }
    switch answer {
    case .none:
      client.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    case .failure(let code):
      client.urlProtocol(self, didFailWithError: URLError(code))
    case .redirect(let target, let status):
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Location": target.absoluteString])!
      var next = URLRequest(url: target)
      next.allHTTPHeaderFields = request.allHTTPHeaderFields
      client.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
      client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client.urlProtocolDidFinishLoading(self)
    case .http(let status, let headers, let body):
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      var offset = 0
      while offset < body.count {
        let end = min(offset + 64 * 1024, body.count)
        client.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
        offset = end
      } // End of loop over the body's chunks
      client.urlProtocolDidFinishLoading(self)
    }
  } // End of func startLoading()

  /// Nothing to stop: every answer is sent at once.
  override func stopLoading() {}
}
