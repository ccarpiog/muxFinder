import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The `e2e-bury` harness's pure judgements (PLAN.md D29): where a listing puts a launch tab
/// (`GatewayPlace`), step 7's race (`BuryRaceOutcome`: an ownership refusal is never the race)
/// and step 11's watch of a killed attach's tab (`KilledLaunchTabWatch`: a tab that vanishes or
/// is buried again after coming back fails). Synthetic data only; nothing touches iTerm2.
@Suite("Launch tab checks")
struct LaunchTabChecksTests {
  /// Shorthand.
  typealias Support = AttachTestSupport
  /// One recorded bury answer.
  typealias Answer = RecordingITerm2Integration.BuryAnswer

  /// The launch tab's session id in these tests.
  static let gateway = Support.gateway
  /// A fixed moment the times below count from.
  static let start = Date(timeIntervalSince1970: 1_792_600_000)

  /// A bury answer of `gateway` with `outcome`.
  static func answer(_ outcome: Answer.Outcome) -> Answer {
    Answer(
      sessionID: gateway, forwardedAt: start, answeredAt: start.addingTimeInterval(0.01),
      outcome: outcome)
  }

  /// A helper result that started at `start` and ended `endedAfter` seconds later with
  /// `failure`.
  static func result(_ failure: LaunchFailure?, endedAfter: TimeInterval = 2) -> LaunchResult {
    LaunchResult(
      id: LaunchToken(uuid: UUID(uuidString: "00000000-0000-4000-8000-0000000000d1")!),
      helperPID: 4321, startedAt: start, childStartedAt: start.addingTimeInterval(0.5),
      endedAt: start.addingTimeInterval(endedAfter),
      childTermination: failure == nil ? .exited(0) : .signaled(SIGKILL), failure: failure)
  } // End of static func result(_:endedAfter:)

  /// A listing with `gateway` in a tab of its own window, or buried, or not at all.
  static func listing(_ place: GatewayPlace) -> ITerm2API.ListSessionsResponse {
    switch place {
    case .inTab:
      return LaunchTabBurialTests.sessionsWithLaunchTab
    case .buried:
      return ITerm2API.ListSessionsResponse(
        windows: Support.sessions.windows, buriedSessions: [.init(uniqueIdentifier: gateway)])
    case .absent:
      return Support.sessions
    }
  } // End of static func listing(_:)

  /// A tab in a window, in `buried_sessions` or in neither is told apart.
  @Test(arguments: [GatewayPlace.inTab, .buried, .absent])
  func tellsWhereTheLaunchTabIs(place: GatewayPlace) {
    #expect(GatewayPlace(of: Self.gateway, in: Self.listing(place)) == place)
  }

  /// Only a bury that was sent and answered `OK`, with the burial `buried` or
  /// `restoredAfterEnd`, is the race, and it passes on any attempt.
  @Test(arguments: [LaunchTabBurial.buried, .restoredAfterEnd])
  func acceptsASentBuryAsTheRace(burial: LaunchTabBurial) {
    let outcome = BuryRaceOutcome(burial: burial, answers: [Self.answer(.ok)])
    #expect(outcome == .raced(burial))
    #expect(outcome.next(afterAttempt: 1, of: 3) == .pass)
    #expect(outcome.next(afterAttempt: 3, of: 3) == .pass)
  }

  /// An ownership refusal (`failed` `tmuxConnectionNotOwned`, the bury not sent) is never the
  /// race: it retries while attempts are left and fails on the last one.
  @Test func neverCountsAnOwnershipRefusalAsTheRace() {
    let outcome = BuryRaceOutcome(
      burial: .failed(.tmuxConnectionNotOwned),
      answers: [Self.answer(.failed(.tmuxConnectionNotOwned))])
    #expect(outcome == .refused)
    #expect(outcome.next(afterAttempt: 1, of: 3) == .retry)
    #expect(outcome.next(afterAttempt: 2, of: 3) == .retry)
    guard case .fail(let reason) = outcome.next(afterAttempt: 3, of: 3) else {
      Issue.record("a refusal on the last attempt did not fail")
      return
    }
    #expect(reason.contains("all 3 attempts"))
  }

  /// Everything else fails at once, never retried: no bury forwarded or more than one, a bury
  /// that was not answered `OK` (also when the coordinator then restored the tab), an answer
  /// that disagrees with the burial, and any other burial.
  @Test func failsEveryOtherOutcome() {
    let cases: [(LaunchTabBurial?, [Answer])] = [
      (.buried, []),
      (.buried, [Self.answer(.ok), Self.answer(.ok)]),
      (.restoredAfterEnd, [Self.answer(.failed(.timedOut))]),
      (.uncertain, [Self.answer(.failed(.timedOut))]),
      (.uncertain, [Self.answer(.failedOtherwise)]),
      (.failed(.tmuxConnectionNotOwned), [Self.answer(.ok)]),
      (.buried, [Self.answer(.failed(.tmuxConnectionNotOwned))]),
      (
        .failed(.setPropertyFailed(.invalidValue)),
        [Self.answer(.failed(.setPropertyFailed(.invalidValue)))]
      ),
      (.skipped(.noTab), [Self.answer(.ok)]),
      (nil, [Self.answer(.ok)]),
    ]
    for (burial, answers) in cases {
      let outcome = BuryRaceOutcome(burial: burial, answers: answers)
      guard case .unexpected = outcome else {
        Issue.record("\(String(describing: burial)) with \(answers.count) answer(s): \(outcome)")
        continue
      }
      guard case .fail = outcome.next(afterAttempt: 1, of: 3) else {
        Issue.record("\(String(describing: burial)) did not fail on the first attempt")
        continue
      }
    } // End of loop over the outcomes that must fail
  } // End of func failsEveryOtherOutcome()

  /// A watch whose looks see the tab buried for 0.9 s, then in a tab every 0.25 s until
  /// `until` seconds after `start`, plus any `extra` looks after those.
  static func watch(
    until: TimeInterval = 12.5,
    extra: [(GatewayPlace, TimeInterval)] = []
  ) -> KilledLaunchTabWatch {
    var watch = KilledLaunchTabWatch()
    var time: TimeInterval = 2
    while time <= until {
      watch.record(time < 2.9 ? .buried : .inTab, at: start.addingTimeInterval(time))
      time += 0.25
    } // End of loop over the synthetic looks
    for (place, at) in extra { watch.record(place, at: start.addingTimeInterval(at)) }
    return watch
  } // End of static func watch(until:extra:)

  /// The facts of a passing watch, with `change` applied.
  static func facts(
    _ change: (inout KilledLaunchTabWatch.Facts) -> Void = { _ in }
  ) -> KilledLaunchTabWatch.Facts {
    var facts = KilledLaunchTabWatch.Facts(
      result: result(.childSignaled(SIGKILL)), answeredStatusReport: true, helperAlive: true,
      coordinatorCloses: 0, coordinatorBuries: 1)
    change(&facts)
    return facts
  }

  /// The tab back in a tab and there at every later look past the helper's minimum lifetime,
  /// the kill's result, an answered status report, nothing of the coordinator's but its one
  /// bury, the helper alive: passed, with when the tab came back.
  @Test func passesATabThatStaysVisible() {
    let watch = Self.watch()
    #expect(watch.lookCount > 40)
    #expect(watch.verdict(Self.facts()) == .passed(cameBackAt: Self.start.addingTimeInterval(3)))
    #expect(KilledLaunchTabWatch.expectedFailure.exitStatus == 137)
  }

  /// A tab that came back and then vanished, or was buried again, fails, even when its last
  /// look sees it in a tab again; so does one that never came back.
  @Test(arguments: [GatewayPlace.absent, .buried])
  func failsATabThatLeavesAfterComingBack(place: GatewayPlace) {
    let watch = Self.watch(extra: [(place, 12.6), (.inTab, 12.8)])
    guard case .failed(let reason) = watch.verdict(Self.facts()) else {
      Issue.record("a tab listed \(place.rawValue) after coming back passed")
      return
    }
    #expect(reason.contains("then was listed \(place.rawValue)"))
    var never = KilledLaunchTabWatch()
    never.record(.buried, at: Self.start.addingTimeInterval(13))
    guard case .failed(let neverReason) = never.verdict(Self.facts()) else {
      Issue.record("a tab that never came back passed")
      return
    }
    #expect(neverReason.contains("never came back"))
  } // End of func failsATabThatLeavesAfterComingBack(place:)

  /// Each other requirement fails on its own: no result, a result that is not the kill's (a
  /// clean exit, another signal, a plain exit status), a `Close` or a further bury of the
  /// coordinator's, no answered status report, a watch that ended before the helper's minimum
  /// lifetime, and a helper that exited.
  @Test func failsEachMissingRequirement() {
    let watch = Self.watch()
    let broken: [(String, KilledLaunchTabWatch.Facts)] = [
      ("no result", Self.facts { $0.result = nil }),
      ("clean", Self.facts { $0.result = Self.result(nil) }),
      ("SIGTERM", Self.facts { $0.result = Self.result(.childSignaled(SIGTERM)) }),
      ("exit 1", Self.facts { $0.result = Self.result(.childExited(1)) }),
      ("a Close", Self.facts { $0.coordinatorCloses = 1 }),
      ("a second bury", Self.facts { $0.coordinatorBuries = 2 }),
      ("no answer", Self.facts { $0.answeredStatusReport = false }),
      ("helper exited", Self.facts { $0.helperAlive = false }),
    ]
    for (name, facts) in broken {
      guard case .failed = watch.verdict(facts) else {
        Issue.record("\(name) passed")
        continue
      }
    } // End of loop over the broken facts
    let short = Self.watch(until: 9.5)
    guard case .failed(let reason) = short.verdict(Self.facts()) else {
      Issue.record("a watch that ended at 9.5 s passed")
      return
    }
    #expect(reason.contains("minimum lifetime"))
    #expect(
      KilledLaunchTabWatch.visibleUntil(Self.result(nil), minimumLifetime: .seconds(10))
        == Self.start.addingTimeInterval(10))
  } // End of func failsEachMissingRequirement()
}
