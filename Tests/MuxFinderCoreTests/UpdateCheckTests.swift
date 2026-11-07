import Foundation
import Testing

@testable import MuxFinderCore

/// `UpdateCheck.apply` (PLAN.md D39): how each answer changes the kept state, the 304 rule,
/// "newer" recomputed against the running version, and the rate limit's bounds.
@Suite("Update check rules")
struct UpdateCheckTests {
  /// Shorthand.
  typealias Support = UpdateTestSupport
  /// The time the answers arrive.
  static let now = ManualUpdateClock.baseDate

  /// A 200 with a release keeps it and its `ETag`, and is a success that clears a rate limit.
  @Test func bodyKeepsTheRelease() {
    var state = UpdateState(rateLimitedUntil: Self.now.addingTimeInterval(-10))
    let outcome = UpdateCheck.apply(
      .body(Data(Support.canonicalBody.utf8), etag: "\"e1\""), to: &state,
      runningVersion: "0.2.0", now: Self.now)
    #expect(outcome == .checked(.newer(Support.release())))
    #expect(outcome.code == "newer")
    #expect(state.keptRelease == Support.release())
    #expect(state.etag == "\"e1\"")
    #expect(state.lastSuccessfulCheck == Self.now)
    #expect(state.rateLimitedUntil == nil)
  } // End of func bodyKeepsTheRelease()

  /// A 200 that offers nothing (a draft, a page not ours) keeps no release and no `ETag` and is
  /// a success; one that cannot be read is a failure that drops the `ETag` and keeps the
  /// release kept before.
  @Test func bodiesThatOfferNothing() {
    let kept = Support.release("v0.2.5")
    var state = UpdateState(etag: "\"old\"", keptRelease: kept)
    let draft = UpdateCheck.apply(
      .body(Support.body(draft: true), etag: "\"e2\""), to: &state, runningVersion: "0.2.0",
      now: Self.now)
    #expect(draft == .checked(.nothingOffered(.draft)))
    #expect(draft.code == "nothingOffered.draft")
    #expect(state.keptRelease == nil && state.etag == nil)
    #expect(state.lastSuccessfulCheck == Self.now)

    state = UpdateState(etag: "\"old\"", keptRelease: kept)
    for body in [Data("not json".utf8), Data("[]".utf8)] {
      let outcome = UpdateCheck.apply(
        .body(body, etag: "\"e3\""), to: &state, runningVersion: "0.2.0", now: Self.now)
      #expect(!outcome.isSuccess)
      #expect(state.keptRelease == kept)
      #expect(state.etag == nil)
      #expect(state.lastSuccessfulCheck == nil)
    }
    #expect(
      UpdateCheck.apply(
        .body(Data("x".utf8), etag: nil), to: &state, runningVersion: "0.2.0",
        now: Self.now) == .failed(.unreadableAnswer(.notJSON)))
    state.etag = "\"again\""
    #expect(
      UpdateCheck.apply(.tooLarge, to: &state, runningVersion: "0.2.0", now: Self.now)
        == .failed(.unreadableAnswer(.tooLarge)))
    #expect(state.etag == nil)
  } // End of func bodiesThatOfferNothing()

  /// A 304 with a kept release is a success with that release, "newer" worked out against the
  /// running version now: an app updated to it is up to date.
  @Test func notModifiedUsesTheKeptRelease() {
    let kept = Support.release("v0.3.0")
    var state = UpdateState(etag: "\"e1\"", keptRelease: kept)
    #expect(
      UpdateCheck.apply(.notModified, to: &state, runningVersion: "0.2.0", now: Self.now)
        == .checked(.newer(kept)))
    #expect(state.etag == "\"e1\"" && state.lastSuccessfulCheck == Self.now)
    #expect(
      UpdateCheck.apply(.notModified, to: &state, runningVersion: "0.3.0", now: Self.now)
        == .checked(.upToDate(latest: kept.version)))
    #expect(UpdateCheck.offer(state, runningVersion: "0.3.0") == .upToDate(latest: kept.version))
    #expect(UpdateCheck.offer(state, runningVersion: "0.2.0") == .newer(kept))
    #expect(UpdateCheck.offer(UpdateState(), runningVersion: "0.2.0") == nil)
  } // End of func notModifiedUsesTheKeptRelease()

  /// A 304 with nothing kept drops the `ETag` and is a failure, so the next check fetches the
  /// body.
  @Test func notModifiedWithoutAReleaseFails() {
    var state = UpdateState(etag: "\"e1\"")
    let outcome = UpdateCheck.apply(
      .notModified, to: &state, runningVersion: "0.2.0", now: Self.now)
    #expect(outcome == .failed(.notModifiedWithoutRelease))
    #expect(state.etag == nil)
    #expect(state.lastSuccessfulCheck == nil)
  }

  /// A rate limit is recorded, never earlier than now nor more than 24 h ahead.
  @Test func rateLimitIsRecordedWithinBounds() {
    var state = UpdateState()
    let soon = Self.now.addingTimeInterval(600)
    #expect(
      UpdateCheck.apply(
        .rateLimited(until: soon), to: &state, runningVersion: "0.2.0",
        now: Self.now) == .rateLimited(until: soon))
    #expect(state.rateLimitedUntil == soon)
    let far = Self.now.addingTimeInterval(10 * 24 * 3600)
    _ = UpdateCheck.apply(.rateLimited(until: far), to: &state, runningVersion: nil, now: Self.now)
    #expect(state.rateLimitedUntil == Self.now.addingTimeInterval(24 * 3600))
    _ = UpdateCheck.apply(
      .rateLimited(until: Self.now.addingTimeInterval(-60)), to: &state, runningVersion: nil,
      now: Self.now)
    #expect(state.rateLimitedUntil == Self.now)
    #expect(state.lastSuccessfulCheck == nil)
  } // End of func rateLimitIsRecordedWithinBounds()

  /// Other statuses and failures change nothing but the outcome.
  @Test func failuresChangeNothing() {
    let kept = Support.release()
    let before = UpdateState(etag: "\"e\"", keptRelease: kept)
    for (response, outcome) in [
      (UpdateCheckResponse.httpStatus(503), UpdateCheckOutcome.failed(.httpStatus(503))),
      (.httpStatus(404), .failed(.httpStatus(404))),
      (.failed(.offline), .failed(.offline)), (.failed(.timedOut), .failed(.timedOut)),
      (.failed(.other("x")), .failed(.other("x"))),
    ] {
      var state = before
      #expect(
        UpdateCheck.apply(response, to: &state, runningVersion: "0.2.0", now: Self.now)
          == outcome)
      #expect(state == before)
    } // End of loop over the failures
    #expect(UpdateCheckOutcome.failed(.httpStatus(503)).code == "failed.httpStatus.503")
    #expect(UpdateCheckOutcome.failed(.offline).code == "failed.offline")
  } // End of func failuresChangeNothing()

  /// A recorded rate limit is in force only while it is ahead and no more than 24 h ahead
  /// (further means the clock went back).
  @Test func activeRateLimit() {
    let now = Self.now
    func state(_ offset: TimeInterval?) -> UpdateState {
      UpdateState(rateLimitedUntil: offset.map { now.addingTimeInterval($0) })
    }
    #expect(UpdateCheck.activeRateLimit(state(nil), now: now) == nil)
    #expect(UpdateCheck.activeRateLimit(state(-1), now: now) == nil)
    #expect(UpdateCheck.activeRateLimit(state(0), now: now) == nil)
    #expect(UpdateCheck.activeRateLimit(state(60), now: now) == now.addingTimeInterval(60))
    #expect(
      UpdateCheck.activeRateLimit(state(24 * 3600), now: now)
        == now.addingTimeInterval(24 * 3600))
    #expect(UpdateCheck.activeRateLimit(state(24 * 3600 + 1), now: now) == nil)
  } // End of func activeRateLimit()
}
