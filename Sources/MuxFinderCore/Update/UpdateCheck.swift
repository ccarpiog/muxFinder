import Foundation

/// Why a check failed (PLAN.md D39). In the background a failure is silent and the check is
/// tried again no sooner than an hour later; a manual check shows it.
public enum UpdateCheckFailure: Sendable, Hashable {
  /// The Mac is offline, or GitHub could not be reached.
  case offline
  /// The request ran out of time.
  case timedOut
  /// GitHub answered with this HTTP status (a redirect away from `api.github.com` included).
  case httpStatus(Int)
  /// The answer could not be read: too large, not JSON, or not a release object.
  case unreadableAnswer(UpdateNoOfferReason)
  /// A 304 answer with no release kept from an earlier 200; the `ETag` is dropped so the next
  /// check fetches the body.
  case notModifiedWithoutRelease
  /// The check was stopped before it ended.
  case cancelled
  /// Anything else, with a short machine-readable detail.
  case other(String)

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .offline: return "offline"
    case .timedOut: return "timedOut"
    case .httpStatus(let status): return "httpStatus.\(status)"
    case .unreadableAnswer(let reason): return "unreadableAnswer.\(reason.rawValue)"
    case .notModifiedWithoutRelease: return "notModifiedWithoutRelease"
    case .cancelled: return "cancelled"
    case .other(let detail): return "other.\(detail)"
    }
  } // End of var code
}

/// What one check came to (PLAN.md D39).
public enum UpdateCheckOutcome: Sendable, Hashable {
  /// GitHub answered (a 200 that could be read, or a 304 with a kept release): what the latest
  /// release offers the running app.
  case checked(UpdateOffer)
  /// No request may be sent before this date: GitHub said so, or (for a manual check during a
  /// rate limit) nothing was sent.
  case rateLimited(until: Date)
  /// The check failed.
  case failed(UpdateCheckFailure)

  /// A stable, machine-readable name: `upToDate`, `newer`, `nothingOffered.<reason>`,
  /// `rateLimited` or `failed.<failure>`.
  public var code: String {
    switch self {
    case .checked(.upToDate): return "upToDate"
    case .checked(.newer): return "newer"
    case .checked(.nothingOffered(let reason)): return "nothingOffered.\(reason.rawValue)"
    case .rateLimited: return "rateLimited"
    case .failed(let failure): return "failed.\(failure.code)"
    }
  }

  /// Whether the check succeeded (GitHub answered something that could be read).
  public var isSuccess: Bool {
    if case .checked = self { return true }
    return false
  }
}

/// The rules of one check, shared by `UpdateScheduler` and the probe (PLAN.md D39).
public enum UpdateCheck {
  /// The longest rate-limit wait honoured: 24 hours. A later reset date is cut to this when it
  /// is recorded, and a recorded one further ahead than this (the clock went back) is ignored.
  public static let maximumRateLimitWait: TimeInterval = 24 * 60 * 60

  /// The rate limit's date when it is still in force at `now`: later than `now`, and no more
  /// than `maximumRateLimitWait` ahead of it.
  public static func activeRateLimit(_ state: UpdateState, now: Date) -> Date? {
    guard let until = state.rateLimitedUntil, until > now,
      until.timeIntervalSince(now) <= maximumRateLimitWait
    else { return nil }
    return until
  }

  /// What the kept release offers the running app, recomputed at every use; `nil` when no
  /// release is kept.
  public static func offer(_ state: UpdateState, runningVersion: String?) -> UpdateOffer? {
    state.keptRelease.map { UpdateOffer.evaluate($0, runningVersion: runningVersion) }
  }

  /// Applies `response`, the answer to a request sent with `state`'s `ETag`, to `state` at
  /// `now`, and returns the outcome:
  /// - a 200 with a release keeps it and its `ETag`, and is a success;
  /// - a 200 that offers nothing (a draft, a prerelease, a tag or page not ours) keeps no
  ///   release and no `ETag`, and is a success;
  /// - a 200 that cannot be read drops the `ETag` (so the next check fetches the body), keeps
  ///   the release kept before, and is a failure;
  /// - a 304 with a kept release is a success with that release; without one it drops the
  ///   `ETag` and is a failure;
  /// - a rate limit records its date (at most `maximumRateLimitWait` ahead);
  /// - any other answer is a failure that changes nothing else.
  /// A success clears the rate limit and records `now` as the last successful check. The
  /// caller records the attempt before sending.
  public static func apply(
    _ response: UpdateCheckResponse, to state: inout UpdateState, runningVersion: String?,
    now: Date
  ) -> UpdateCheckOutcome {
    let outcome: UpdateCheckOutcome
    switch response {
    case .body(let data, let etag):
      switch UpdateReleaseParser.parse(data) {
      case .release(let release):
        state.keptRelease = release
        state.etag = etag
        outcome = .checked(UpdateOffer.evaluate(release, runningVersion: runningVersion))
      case .nothingOffered(let reason) where reason.isUnreadableAnswer:
        state.etag = nil
        outcome = .failed(.unreadableAnswer(reason))
      case .nothingOffered(let reason):
        state.keptRelease = nil
        state.etag = nil
        outcome = .checked(.nothingOffered(reason))
      }
    case .notModified:
      if let release = state.keptRelease {
        outcome = .checked(UpdateOffer.evaluate(release, runningVersion: runningVersion))
      } else {
        state.etag = nil
        outcome = .failed(.notModifiedWithoutRelease)
      }
    case .rateLimited(let until):
      let bounded = min(max(until, now), now.addingTimeInterval(maximumRateLimitWait))
      state.rateLimitedUntil = bounded
      outcome = .rateLimited(until: bounded)
    case .httpStatus(let status):
      outcome = .failed(.httpStatus(status))
    case .tooLarge:
      state.etag = nil
      outcome = .failed(.unreadableAnswer(.tooLarge))
    case .failed(.offline):
      outcome = .failed(.offline)
    case .failed(.timedOut):
      outcome = .failed(.timedOut)
    case .failed(.other(let detail)):
      outcome = .failed(.other(detail))
    }
    if outcome.isSuccess {
      state.lastSuccessfulCheck = now
      state.rateLimitedUntil = nil
    }
    return outcome
  } // End of static func apply(_:to:runningVersion:now:)
}
