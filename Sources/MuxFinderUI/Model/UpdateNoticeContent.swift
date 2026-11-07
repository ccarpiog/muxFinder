import Foundation
import MuxFinderCore

/// What a button of the popover's update notice does (PLAN.md D39 *The update views
/// (I-13c2b)*): each is one method of `UpdateModel` or its `UpdateFlow`, called through
/// `UpdateModel.perform(_:)`.
public enum UpdateNoticeAction: String, Sendable, Hashable, CaseIterable {
  /// What's new: opens the release page (`UpdateModel.openWhatsNew()`).
  case whatsNew
  /// Update: downloads, checks and installs (`UpdateFlow.update()`).
  case update
  /// Download: opens the release page (`UpdateFlow.download()`).
  case download
  /// Cancel: stops the download or its check (`UpdateFlow.cancel()`).
  case cancel
  /// Quit and install, despite unsaved work (`UpdateFlow.quitAndInstall()`).
  case quitAndInstall
  /// Not now: keeps the prepared update for later (`UpdateFlow.notNow()`).
  case notNow
  /// Install and relaunch, after Not now (`UpdateFlow.installAndRelaunch()`).
  case installAndRelaunch
  /// Release page: opens the release page after a failure (`UpdateModel.openReleasePage()`).
  case releasePage
}

/// One button of the update notice: its title, what VoiceOver says, how it looks and whether
/// it can be pressed.
public struct UpdateNoticeButton: Sendable, Hashable, Identifiable {
  /// How a button looks.
  public enum Style: Sendable, Hashable {
    /// The state's main action (a prominent button).
    case primary
    /// Any other button.
    case secondary
    /// A link (Release page).
    case link
  }

  /// What it does.
  public let action: UpdateNoticeAction
  /// Its title.
  public let title: String
  /// What VoiceOver says: the action and, where one applies, the version.
  public let accessibilityLabel: String
  /// What VoiceOver adds after a pause, if anything.
  public let accessibilityHint: String?
  /// How it looks.
  public let style: Style
  /// Whether it can be pressed.
  public let isEnabled: Bool

  /// `Identifiable` conformance: the action (a notice never shows one twice).
  public var id: UpdateNoticeAction { action }
}

/// One line of the update notice below its title.
public struct UpdateNoticeLine: Sendable, Hashable {
  /// How a line looks.
  public enum Style: Sendable, Hashable {
    /// What the update is doing ("Downloading… 40%").
    case status
    /// A secondary remark (a reason, "Attached tmux sessions are not affected.").
    case note
    /// A failure ("Couldn't update: …").
    case problem
  }

  /// The text.
  public let text: String
  /// How it looks.
  public let style: Style
}

/// The download's bar, shown while its total is known.
public struct UpdateNoticeProgress: Sendable, Hashable {
  /// What VoiceOver calls the bar.
  public static let accessibilityLabel = "Download progress"

  /// How much is downloaded, 0…1.
  public let fraction: Double
  /// The bar's VoiceOver value ("40%").
  public let accessibilityValue: String
}

/// The popover's update notice as one value (PLAN.md D39 *The update views (I-13c2b)*): its
/// title, What's new, the lines, the download's bar, the activity indicator, the buttons
/// (which show, which can be pressed) and what VoiceOver announces when the state appears.
/// Built only by `make(release:offer:state:canUpdate:preparedRelease:)`, a pure function the
/// view and the galleries both render through.
public struct UpdateNoticeContent: Sendable, Hashable {
  /// The first line: "muxFinder <version> is available", or "Installing…" / "Relaunching…".
  public let title: String
  /// What's new beside the title (none while installing or relaunching).
  public let whatsNew: UpdateNoticeButton?
  /// The lines below the title.
  public let lines: [UpdateNoticeLine]
  /// The download's bar (only while its total is known).
  public let progress: UpdateNoticeProgress?
  /// Whether a small activity indicator shows (work under way with no bar).
  public let showsActivity: Bool
  /// The flow's buttons, in order (What's new apart).
  public let buttons: [UpdateNoticeButton]
  /// What VoiceOver announces when this state appears (a failure, the ask), else `nil`.
  public let announcement: String?

  /// "Installing…".
  public static let installing = "Installing…"
  /// "Relaunching…".
  public static let relaunching = "Relaunching…"
  /// The prepared state's line (transient: the ask or the install follows at once).
  public static let downloadChecked = "Download checked"
  /// The ask's second line.
  public static let sessionsNotAffected = "Attached tmux sessions are not affected."
  /// The hint of every button that opens the release page.
  public static let opensReleasePage = "Opens the release page in your browser"

  /// Every text the notice shows or VoiceOver reads (tests check none holds a path, URL or
  /// header).
  public var texts: [String] {
    var texts = [title] + lines.map(\.text)
    let all = (whatsNew.map { [$0] } ?? []) + buttons
    for button in all {
      texts +=
        [button.title, button.accessibilityLabel] + (button.accessibilityHint.map { [$0] } ?? [])
    }
    if let progress { texts.append(progress.accessibilityValue) }
    if let announcement { texts.append(announcement) }
    return texts
  } // End of var texts

  /// The button for `action`, if the notice shows it.
  public func button(_ action: UpdateNoticeAction) -> UpdateNoticeButton? {
    if whatsNew?.action == action { return whatsNew }
    return buttons.first { $0.action == action }
  }

  /// The notice for `release` (the shown release) with the flow's `offer` (`nil`: no notice
  /// was handed to the flow, as in every mode without update machinery) and `state`;
  /// `canUpdate` is `UpdateFlow.canUpdate`; `preparedRelease` is the release being prepared,
  /// asked about, deferred or installed, when there is one (its version is what Cancel, the
  /// ask and Install and relaunch name; the shown release's otherwise).
  public static func make(
    release: UpdateRelease, offer: UpdateFlowOffer?, state: UpdateFlowState, canUpdate: Bool,
    preparedRelease: UpdateRelease? = nil
  ) -> UpdateNoticeContent {
    let version = release.version.description
    let prepared = (preparedRelease ?? release).version.description
    let whatsNew = UpdateNoticeButton(
      action: .whatsNew, title: "What's new",
      accessibilityLabel: "What's new in muxFinder " + version,
      accessibilityHint: opensReleasePage, style: .secondary, isEnabled: true)
    var title = UpdateNotice.available(release.version)
    var showsWhatsNew = true
    var lines: [UpdateNoticeLine] = []
    var progress: UpdateNoticeProgress?
    var showsActivity = false
    var buttons: [UpdateNoticeButton] = []
    switch state {
    case .idle:
      lines += downloadReason(offer, unless: nil)
      buttons += offered(offer, version: version, canUpdate: canUpdate, hidesDisabledUpdate: false)
    case .downloading(let bytes, let total):
      lines.append(
        UpdateNoticeLine(
          text: UpdateFlowText.downloading(bytes: bytes, total: total), style: .status))
      if let percent = UpdateFlowText.percent(bytes: bytes, total: total) {
        progress = UpdateNoticeProgress(
          fraction: Double(percent) / 100, accessibilityValue: "\(percent)%")
      } else {
        showsActivity = true
      }
      buttons.append(cancel(prepared))
    case .checking:
      lines.append(UpdateNoticeLine(text: UpdateFlowText.checking, style: .status))
      showsActivity = true
      buttons.append(cancel(prepared))
    case .prepared:
      lines.append(UpdateNoticeLine(text: downloadChecked, style: .status))
      showsActivity = true
    case .asking(let work):
      lines.append(UpdateNoticeLine(text: askLine(work), style: .status))
      lines.append(UpdateNoticeLine(text: sessionsNotAffected, style: .note))
      buttons.append(
        UpdateNoticeButton(
          action: .quitAndInstall, title: "Quit and install",
          accessibilityLabel: "Quit and install muxFinder " + prepared,
          accessibilityHint: "Quits muxFinder, installs the update and opens the new version",
          style: .primary, isEnabled: true))
      buttons.append(
        UpdateNoticeButton(
          action: .notNow, title: "Not now",
          accessibilityLabel: "Not now: install muxFinder \(prepared) later",
          accessibilityHint: "Keeps the update ready while muxFinder runs", style: .secondary,
          isEnabled: true))
    case .deferred:
      lines.append(UpdateNoticeLine(text: readyToInstall(prepared), style: .status))
      buttons.append(
        UpdateNoticeButton(
          action: .installAndRelaunch, title: "Install and relaunch",
          accessibilityLabel: "Install muxFinder \(prepared) and relaunch",
          accessibilityHint: "Quits muxFinder, installs the update and opens the new version",
          style: .primary, isEnabled: true))
    case .installing:
      title = installing
      showsWhatsNew = false
      showsActivity = true
    case .relaunchScheduled:
      title = relaunching
      showsWhatsNew = false
      showsActivity = true
    case .failed(let failure):
      lines.append(UpdateNoticeLine(text: failure.phrase, style: .problem))
      lines += downloadReason(offer, unless: failure.reason)
      buttons += offered(offer, version: version, canUpdate: canUpdate, hidesDisabledUpdate: true)
      buttons.append(
        UpdateNoticeButton(
          action: .releasePage, title: "Release page",
          accessibilityLabel: "Release page of muxFinder " + version,
          accessibilityHint: opensReleasePage, style: .link, isEnabled: true))
    } // End of switch over the flow's state
    return UpdateNoticeContent(
      title: title, whatsNew: showsWhatsNew ? whatsNew : nil, lines: lines, progress: progress,
      showsActivity: showsActivity, buttons: buttons,
      announcement: announcement(state: state, version: (preparedRelease ?? release).version))
  } // End of static func make(release:offer:state:canUpdate:preparedRelease:)

  /// What VoiceOver announces when `state` appears: a failure's phrase; the ask's lines, after
  /// "muxFinder <version> is ready to install." when the version is known; else `nil`.
  public static func announcement(state: UpdateFlowState, version: UpdateVersion?) -> String? {
    switch state {
    case .failed(let failure):
      return failure.phrase
    case .asking(let work):
      let ready = version.map { readyToInstall($0.description) + "." }
      return ([ready, askLine(work), sessionsNotAffected].compactMap { $0 }).joined(separator: " ")
    default:
      return nil
    }
  } // End of static func announcement(state:version:)

  /// "muxFinder 0.3.0 is ready to install".
  public static func readyToInstall(_ version: String) -> String {
    "muxFinder \(version) is ready to install"
  }

  /// The ask's line naming what is unsaved: "Quitting to install loses the New session draft
  /// and unsaved changes in Settings."
  public static func askLine(_ work: UpdateUnsavedWork) -> String {
    let items = work.items
    guard let last = items.last else { return "Installing quits muxFinder." }
    let list =
      items.count == 1 ? last : items.dropLast().joined(separator: ", ") + " and " + last
    return "Quitting to install loses \(list)."
  }

  /// "Can't update in place: <reason>" for a Download offer, unless the reason is `shown`
  /// already (a failure's phrase says it).
  public static func downloadReason(_ offer: UpdateFlowOffer?, unless shown: String?)
    -> [UpdateNoticeLine]
  {
    guard case .download(let reason)? = offer, reason != shown else { return [] }
    return [UpdateNoticeLine(text: "Can't update in place: " + reason, style: .note)]
  }

  /// The offer's button: Update (enabled while `canUpdate`; left out when it cannot be
  /// pressed and `hidesDisabledUpdate`), Download, or none while eligibility is read or no
  /// offer is known.
  static func offered(
    _ offer: UpdateFlowOffer?, version: String, canUpdate: Bool, hidesDisabledUpdate: Bool
  ) -> [UpdateNoticeButton] {
    switch offer {
    case .update?:
      guard canUpdate || !hidesDisabledUpdate else { return [] }
      return [
        UpdateNoticeButton(
          action: .update, title: "Update", accessibilityLabel: "Update to muxFinder " + version,
          accessibilityHint:
            "Downloads and checks the update, then installs it and relaunches muxFinder",
          style: .primary, isEnabled: canUpdate)
      ]
    case .download?:
      return [
        UpdateNoticeButton(
          action: .download, title: "Download", accessibilityLabel: "Download muxFinder " + version,
          accessibilityHint: opensReleasePage, style: .primary, isEnabled: true)
      ]
    case .reading?, nil:
      return []
    }
  } // End of static func offered(_:version:canUpdate:hidesDisabledUpdate:)

  /// Cancel, naming the version being prepared.
  static func cancel(_ version: String) -> UpdateNoticeButton {
    UpdateNoticeButton(
      action: .cancel, title: "Cancel",
      accessibilityLabel: "Cancel the update to muxFinder " + version,
      accessibilityHint: "Stops the download; nothing is installed", style: .secondary,
      isEnabled: true)
  }
}
