import Foundation

/// Short English relative times for the popover ("just now", "2 min ago", "3 hr ago",
/// "1 day ago"), the same in every locale (PLAN.md D10).
///
/// Written by hand rather than with `RelativeDateTimeFormatter`, whose wording and
/// abbreviations change with the locale and the system version, so the strings the tests and
/// the screenshots show are exactly the strings the app shows.
public enum RelativeTime {
  /// The phrase for `date` seen at `now`: under a minute (or in the future, for a clock that
  /// moved back) is "just now"; then whole minutes, hours and days, rounded down.
  public static func phrase(for date: Date, now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date).rounded(.down))
    guard seconds >= 60 else { return "just now" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes) min ago" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours) hr ago" }
    let days = hours / 24
    return days == 1 ? "1 day ago" : "\(days) days ago"
  } // End of func phrase(for:now:)

  /// "Last checked 2 min ago": when the host last answered.
  public static func lastChecked(_ date: Date, now: Date) -> String {
    "Last checked \(phrase(for: date, now: now))"
  }

  /// "Last seen 3 min ago · not live": a stale session, as the host last reported it.
  public static func lastSeen(_ date: Date, now: Date) -> String {
    "Last seen \(phrase(for: date, now: now)) · not live"
  }
}
