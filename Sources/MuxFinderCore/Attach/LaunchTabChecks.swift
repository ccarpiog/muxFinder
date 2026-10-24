import Darwin
import Foundation

// The `e2e-bury` harness's judgements of the launch tab hidden once attached (PLAN.md D29),
// pure so that `LaunchTabChecksTests` covers their negative cases: the probe has no test
// target, and like `RecordingITerm2Integration` and `CreatedSession` they live here for that.

/// Where iTerm2 lists a launch tab's session at one moment.
public enum GatewayPlace: String, Sendable, Hashable {
  /// In a tab of a window.
  case inTab = "in a tab"
  /// In `buried_sessions`.
  case buried
  /// Not listed at all.
  case absent = "gone"

  /// Where `sessions` lists `gateway`.
  public init(of gateway: String, in sessions: ITerm2API.ListSessionsResponse) {
    if sessions.placement(ofSession: gateway) != nil {
      self = .inTab
    } else if sessions.buriedSessions.contains(where: { $0.uniqueIdentifier == gateway }) {
      self = .buried
    } else {
      self = .absent
    }
  } // End of init(of:in:)
} // End of enum GatewayPlace

/// `e2e-bury` step 7's judgement of one attempt at the race PLAN.md D29 closes by order: the
/// coordinator's bury of a launch tab released together with a detach of its connection. Only
/// a bury that was sent, answered `OK` (`RecordingITerm2Integration.buryAnswers(of:)`), and
/// whose coordinator check ended `buried` (the helper's restore undoes it) or
/// `restoredAfterEnd` (the check saw tmux had ended and restored the tab) ran the race. A bury
/// its ownership check refused (`failed` `tmuxConnectionNotOwned`: the connection was gone
/// first) buried nothing, so it never counts as the race: the step retries, and fails once its
/// attempts are used up.
public enum BuryRaceOutcome: Sendable, Hashable {
  /// The bury was sent and answered `OK`, and the burial is this (`buried` or
  /// `restoredAfterEnd`): the race ran.
  case raced(LaunchTabBurial)
  /// The bury's ownership check refused it: nothing was buried, the race did not run.
  case refused
  /// Anything else; the step fails with this reason.
  case unexpected(String)

  /// What the step does after one attempt.
  public enum Next: Sendable, Hashable {
    /// The race ran: the step goes on with its other checks.
    case pass
    /// The bury was refused, and an attempt is left: attach again and race again.
    case retry
    /// The step fails with this reason.
    case fail(String)
  }

  /// Judges one attempt from the coordinator's `burial` of the launch tab and the recorder's
  /// `answers` to its buries of that tab: exactly one bury must have been forwarded, and its
  /// answer must agree with the burial.
  public init(burial: LaunchTabBurial?, answers: [RecordingITerm2Integration.BuryAnswer]) {
    guard answers.count == 1, let answer = answers.first else {
      self = .unexpected(
        "the coordinator forwarded \(answers.count) buries of the launch tab, not 1 (burial "
          + "\(burial?.kind ?? "none"))")
      return
    }
    let refusedBurial = burial == .failed(.tmuxConnectionNotOwned)
    switch answer.outcome {
    case .failed(.tmuxConnectionNotOwned):
      self =
        refusedBurial
        ? .refused
        : .unexpected(
          "the bury was refused by its ownership check, but the burial is "
            + "\(burial?.kind ?? "none")")
    case .failed(let error):
      self = .unexpected("the bury was not answered OK (\(error.kind))")
    case .failedOtherwise:
      self = .unexpected("the bury was not answered OK (not an iTerm2 error)")
    case .ok:
      switch burial {
      case .buried?, .restoredAfterEnd?:
        self = .raced(burial ?? .buried)
      default:
        self = .unexpected(
          "the bury was answered OK, but the burial is \(burial?.kind ?? "none") "
            + "(\(burial?.detail ?? "-")), not buried or restoredAfterEnd")
      }
    }
  } // End of init(burial:answers:)

  /// What the step does after attempt `attempt` (counted from 1) of `attempts`.
  public func next(afterAttempt attempt: Int, of attempts: Int) -> Next {
    switch self {
    case .raced: return .pass
    case .refused:
      return attempt < attempts
        ? .retry
        : .fail(
          "the bury was refused by its ownership check on all \(attempts) attempts "
            + "(tmuxConnectionNotOwned): the race never ran")
    case .unexpected(let reason): return .fail(reason)
    }
  } // End of func next(afterAttempt:of:)
} // End of enum BuryRaceOutcome

/// `e2e-bury` step 11's watch over a launch tab whose attach child it killed with SIGKILL while
/// the tab was buried (PLAN.md D29 spike (e), D14): every look at where iTerm2 listed the tab,
/// and the judgement. After that abnormal end the helper writes the failure result
/// `childSignaled(9)` (exit 137), its restores (or iTerm2, or the coordinator's recovery of a
/// failed tab) bring the tab back, and it prints its explanation and waits for Return. So the
/// tab must come back in a tab and stay there, never buried again and never gone, with its
/// helper alive, past the helper's minimum lifetime, until the harness closes it itself.
public struct KilledLaunchTabWatch: Sendable, Hashable {
  /// One look.
  public struct Look: Sendable, Hashable {
    /// Where the tab was listed.
    public var place: GatewayPlace
    /// When the listing answered, wall clock.
    public var at: Date

    /// Creates a look.
    public init(place: GatewayPlace, at: Date) {
      self.place = place
      self.at = at
    }
  } // End of struct Look

  /// What the judgement needs besides the looks.
  public struct Facts: Sendable, Equatable {
    /// The helper's result, if it came.
    public var result: LaunchResult?
    /// Whether a status report of the helper's restores before its exit was answered (iTerm2
    /// parses the tab as a terminal again, so the explanation written next is drawn).
    public var answeredStatusReport: Bool
    /// Whether the helper still ran at the last look.
    public var helperAlive: Bool
    /// The coordinator's recorded `Close`s that may have touched the tab.
    public var coordinatorCloses: Int
    /// The coordinator's recorded buries of the tab, the attach's own one included.
    public var coordinatorBuries: Int
    /// The helper's minimum lifetime (D14), counted from its start (`LaunchResult.startedAt`).
    public var minimumLifetime: Duration

    /// Creates the facts.
    public init(
      result: LaunchResult?,
      answeredStatusReport: Bool,
      helperAlive: Bool,
      coordinatorCloses: Int,
      coordinatorBuries: Int,
      minimumLifetime: Duration = LaunchHelper.defaultMinimumLifetime
    ) {
      self.result = result
      self.answeredStatusReport = answeredStatusReport
      self.helperAlive = helperAlive
      self.coordinatorCloses = coordinatorCloses
      self.coordinatorBuries = coordinatorBuries
      self.minimumLifetime = minimumLifetime
    } // End of init(result:answeredStatusReport:helperAlive:coordinatorCloses:…)
  } // End of struct Facts

  /// The judgement.
  public enum Verdict: Sendable, Hashable {
    /// Every requirement held; the tab was first seen back in a tab then.
    case passed(cameBackAt: Date)
    /// The step fails with this reason.
    case failed(String)
  }

  /// The result a SIGKILLed attach child leaves (D14: 128 + 9, exit 137).
  public static let expectedFailure = LaunchFailure.childSignaled(SIGKILL)

  /// When the first look saw the tab in a tab.
  public private(set) var firstInTab: Date?
  /// The first look after `firstInTab` that did not see it in a tab.
  public private(set) var leftAfterComingBack: Look?
  /// The latest look.
  public private(set) var last: Look?
  /// How many looks were recorded.
  public private(set) var lookCount = 0

  /// An empty watch.
  public init() {}

  /// Records one look, in order.
  public mutating func record(_ place: GatewayPlace, at date: Date) {
    lookCount += 1
    last = Look(place: place, at: date)
    if firstInTab == nil {
      if place == .inTab { firstInTab = date }
    } else if place != .inTab, leftAfterComingBack == nil {
      leftAfterComingBack = Look(place: place, at: date)
    }
  } // End of func record(_:at:)

  /// Until when the tab must be seen in a tab: the helper's start plus its minimum lifetime.
  public static func visibleUntil(_ result: LaunchResult, minimumLifetime: Duration) -> Date {
    let parts = minimumLifetime.components
    let seconds = Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    return result.startedAt.addingTimeInterval(seconds)
  }

  /// Judges the looks with `facts`: the expected failure result, no `Close` and no further bury
  /// of the coordinator's, the tab back in a tab and never anywhere else after that, an
  /// answered status report, the last look at or after the end of the helper's minimum
  /// lifetime, and the helper alive.
  public func verdict(_ facts: Facts) -> Verdict {
    guard let result = facts.result else { return .failed("no helper result came") }
    let expected = Self.expectedFailure
    guard result.failure == expected, result.exitStatus == expected.exitStatus else {
      return .failed(
        "the helper's result is exit \(result.exitStatus) (\(result.failure?.kind ?? "clean")), "
          + "not exit \(expected.exitStatus) childSignaled(\(SIGKILL))")
    }
    guard facts.coordinatorCloses == 0 else {
      return .failed(
        "the coordinator sent \(facts.coordinatorCloses) Close(s) that may have touched the "
          + "failed launch tab; it must stay visible")
    }
    guard facts.coordinatorBuries <= 1 else {
      return .failed(
        "the coordinator sent \(facts.coordinatorBuries - 1) more bury(s) of the failed launch tab")
    }
    guard let firstInTab else {
      return .failed(
        "the launch tab never came back in a tab: it is listed \(last?.place.rawValue ?? "nowhere")"
      )
    }
    if let left = leftAfterComingBack {
      let after = Int((left.at.timeIntervalSince(firstInTab) * 1000).rounded())
      return .failed(
        "the launch tab came back in a tab, then was listed \(left.place.rawValue) \(after) ms "
          + "later; a failed tab must stay visible until it is closed")
    }
    guard facts.answeredStatusReport else {
      return .failed(
        "no status report of the helper's was answered: iTerm2 probably still parses the tab in "
          + "tmux mode, so its explanation is not drawn")
    }
    let until = Self.visibleUntil(result, minimumLifetime: facts.minimumLifetime)
    guard let last, last.at >= until else {
      return .failed("the watch ended before the helper's minimum lifetime did")
    }
    guard facts.helperAlive else {
      return .failed("the helper exited; after a failure it waits for Return, never typed here")
    }
    return .passed(cameBackAt: firstInTab)
  } // End of func verdict(_:)
} // End of struct KilledLaunchTabWatch
