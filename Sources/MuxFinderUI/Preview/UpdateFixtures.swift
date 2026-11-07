import Foundation
import MuxFinderCore

/// The update check's gallery states (PLAN.md D39 *The notice (I-13c1)*): the popover's notice
/// and Settings › General's status lines, toggle and button, from synthetic data with no
/// scheduler. The running app is 0.2.0 (2); the release offered is 0.3.0, its page a synthetic
/// one under the repository's releases.
public enum UpdateFixtures {
  /// The fixtures' clock (the popover fixtures').
  public static let now = PreviewFixtures.now

  /// A synthetic release `version` (`major.minor.patch`) through the real parser, so it passes
  /// the same rules as an answer; no asset (the page only).
  public static func release(_ version: String) -> UpdateRelease? {
    let body: [String: Any] = [
      "tag_name": "v" + version,
      "html_url": "https://github.com/ccarpiog/muxFinder/releases/tag/v" + version,
      "draft": false, "prerelease": false, "assets": [],
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: body),
      case .release(let release) = UpdateReleaseParser.parse(data)
    else { return nil }
    return release
  } // End of static func release(_:)

  /// The newer release the fixtures offer.
  static let newer = release("0.3.0")

  /// A status with the newer release kept, checked an hour ago.
  static func newerStatus(seen: UpdateVersion? = nil, manual: Bool = false) -> UpdateCheckStatus {
    let offer = newer.map { UpdateOffer.newer($0) }
    return UpdateCheckStatus(
      lastCheck: offer.map {
        UpdateCheckRecord(
          outcome: .checked($0), date: now.addingTimeInterval(-3600), manual: manual)
      },
      offer: offer, lastSuccessfulCheck: now.addingTimeInterval(-3600), noticeSeenVersion: seen)
  }

  /// A status after a check whose outcome is `outcome`, the last success `secondsAgo` ago.
  static func status(
    _ outcome: UpdateCheckOutcome?, lastSuccess secondsAgo: TimeInterval?,
    activity: UpdateCheckStatus.Activity = .idle
  ) -> UpdateCheckStatus {
    UpdateCheckStatus(
      activity: activity,
      lastCheck: outcome.map { UpdateCheckRecord(outcome: $0, date: now, manual: true) },
      offer: UpdateVersion("0.2.0").map { .upToDate(latest: $0) },
      lastSuccessfulCheck: secondsAgo.map { now.addingTimeInterval(-$0) })
  }

  // MARK: - Popover

  /// The popover with the notice.
  public static let popoverNotice: PreviewFixture = {
    var fixture = PreviewFixtures.overview
    fixture.id = "update-notice"
    fixture.title = "Update available: the notice"
    fixture.update = UpdateFixture(status: newerStatus(), now: now)
    return fixture
  }()

  /// The popover's update states, in the gallery's order.
  public static let popover = [popoverNotice]

  // MARK: - Settings

  /// A General tab fixture showing the update section as `update`.
  static func settingsFixture(_ id: String, _ title: String, _ update: UpdateFixture)
    -> SettingsFixture
  {
    SettingsFixture(id: id, title: title, hosts: SettingsFixtures.hostList) {
      $0.tab = .general
      $0.loginItemStatus = .enabled
      $0.update = update
    }
  }

  /// Never checked.
  public static let settingsNotChecked = settingsFixture(
    "update-not-checked", "Updates: not checked yet", UpdateFixture(status: nil, now: now))
  /// A check in flight (the button disabled).
  public static let settingsChecking = settingsFixture(
    "update-checking", "Updates: checking",
    UpdateFixture(
      status: status(nil, lastSuccess: 26 * 3600, activity: .checking(manual: true)),
      isCheckRequested: true, now: now))
  /// Up to date.
  public static let settingsUpToDate = settingsFixture(
    "update-up-to-date", "Updates: up to date",
    UpdateFixture(
      status: status(
        UpdateVersion("0.2.0").map { .checked(.upToDate(latest: $0)) }, lastSuccess: 120),
      now: now))
  /// A newer release.
  public static let settingsNewer = settingsFixture(
    "update-newer", "Updates: a newer release",
    UpdateFixture(status: newerStatus(manual: true), now: now))
  /// Offline.
  public static let settingsOffline = settingsFixture(
    "update-offline", "Updates: no connection",
    UpdateFixture(status: status(.failed(.offline), lastSuccess: 3 * 86400), now: now))
  /// No answer.
  public static let settingsTimedOut = settingsFixture(
    "update-timed-out", "Updates: no answer",
    UpdateFixture(status: status(.failed(.timedOut), lastSuccess: 3 * 86400), now: now))
  /// Rate limited.
  public static let settingsRateLimited = settingsFixture(
    "update-rate-limited", "Updates: GitHub limiting requests",
    UpdateFixture(
      status: status(.rateLimited(until: now.addingTimeInterval(1800)), lastSuccess: 86400),
      now: now))
  /// Automatic checks off.
  public static let settingsOff = settingsFixture(
    "update-off", "Updates: automatic checks off",
    UpdateFixture(
      status: status(nil, lastSuccess: 5 * 86400), automaticChecks: false, now: now))

  /// The Settings update states, in the gallery's order.
  public static let settings = [
    settingsNotChecked, settingsChecking, settingsUpToDate, settingsNewer, settingsOffline,
    settingsTimedOut, settingsRateLimited, settingsOff,
  ]
}
