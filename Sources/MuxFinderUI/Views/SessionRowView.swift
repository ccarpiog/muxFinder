import MuxFinderCore
import SwiftUI

/// One session: its attach-state indicator, its name (stronger while attached), "4 windows ·
/// 1 client" (or "Last seen … · not live"), the "Open in iTerm2 here" badge (with "also
/// attached elsewhere" while "Detach other clients…" is offered, PLAN.md D37), one "Open in
/// Terminal on this Mac" badge with "Show in Terminal" per app a client of the session runs in
/// here (PLAN.md D38 *The UI (I-12d2)*, whichever terminal is chosen), and any progress, result
/// or failure. A click opens it in the chosen terminal; the context menu offers "Move here…"
/// and, for an attachment in this Mac's iTerm2 or a window of the chosen plain terminal,
/// "Detach from this Mac" and, when the listing shows more clients than this Mac's
/// attachments, "Detach other clients…" (PLAN.md D25, D37). The keyboard selection is a neutral
/// fill with an accent outline (PLAN.md D22).
struct SessionRowView: View {
  /// The row's content.
  let row: SessionRow
  /// The model the row talks to.
  let model: AppModel
  /// Whether the pointer is over the row.
  @State private var isHovered = false
  /// Light or dark, for the palette.
  @Environment(\.colorScheme) private var colorScheme

  /// The row's layout and its single accessibility element.
  var body: some View {
    let palette = PopoverPalette(colorScheme)
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      AttachStateIndicator(state: row.attachState)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(row.name)
            .fontWeight(row.isAttached ? .semibold : .regular)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(row.attachState == .stale ? .secondary : .primary)
          Spacer(minLength: 8)
          Text(row.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } // End of HStack holding the name and the detail
        if row.isOpenInITerm2Here {
          OpenHereBadge(text: row.openHereText)
        }
        ForEach(row.openInApps) { entry in
          OpenInAppLine(entry: entry, key: row.key, model: model)
        }
        if let activity = row.activity {
          ActivityLine(activity: activity, key: row.key, model: model)
        }
        if let note = row.note {
          Text(note)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 18)
        }
      } // End of VStack holding the name, badge and activity
    } // End of HStack holding the indicator and the row's text
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .background {
      RoundedRectangle(cornerRadius: 6)
        .fill(palette.rowFill(isSelected: row.isSelected, isHovered: isHovered))
        .overlay {
          if row.isSelected {
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(palette.selectionOutline, lineWidth: 1.5)
          }
        }
    }
    .padding(.horizontal, 4)
    .contentShape(Rectangle())
    .onTapGesture { model.open(row.key) }
    .onHover { isHovered = $0 }
    .contextMenu { SessionMenu(row: row, model: model) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityValue(row.accessibilityValue)
    .accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : [.isButton])
    .accessibilityHint(model.terminalWording.openHint)
    .accessibilityAction { model.open(row.key) }
    .accessibilityActions { accessibilityActions }
  } // End of var body

  /// The row's other actions for VoiceOver: the menu's, and the activity's buttons.
  @ViewBuilder private var accessibilityActions: some View {
    if row.hasWindowHere {
      Button(model.terminalWording.showTitle) { model.showWindow(for: row.key) }
    }
    ForEach(row.openInApps) { entry in
      Button(entry.showTitle) { model.showInApp(entry.app, for: row.key) }
    }
    if row.offersMoveHere {
      Button(SessionMenu.moveHereTitle) { model.requestMoveHere(row.key) }
    }
    if row.offersDetach {
      Button(SessionMenu.detachTitle) { model.detach(row.key) }
    }
    ForEach(row.otherTerminalDetaches) { other in
      Button(other.title) { model.detach(row.key, openedIn: other.terminalID) }
    }
    if row.offersDetachOtherClients, !row.isPending {
      Button(SessionMenu.detachOtherClientsTitle) { model.requestDetachOtherClients(row.key) }
    }
    ActivityAccessibilityActions(activity: row.activity, key: row.key, model: model)
  } // End of var accessibilityActions
}

/// The activity's buttons for VoiceOver, in the popover's rows and the switcher's: "Show tab"
/// or "Show window" while a launch still connects, and a failure's recoveries.
struct ActivityAccessibilityActions: View {
  /// The row's activity.
  let activity: SessionActivity?
  /// The session.
  let key: SessionKey
  /// The model the buttons talk to.
  let model: AppModel

  /// The buttons.
  var body: some View {
    if case .stillConnecting = activity {
      Button("Show tab") { model.showTab(for: key) }
    }
    if case .stillConnectingInWindow(_, let wording) = activity {
      Button(wording.showTitle) { model.showLaunchWindow(for: key) }
    }
    if let problem = activity?.problem {
      ForEach(problem.recoveries, id: \.self) { recovery in
        Button(recovery.title) { model.perform(recovery, for: key) }
      }
    }
  } // End of var body
}

/// A session row's context menu: "Open in iTerm2" (the chosen terminal's name, PLAN.md D38
/// *The UI (I-12d2)*), "Show window" for a window of the chosen plain terminal, "Show in
/// Terminal" for each app a client of the session runs in on this Mac, "Move here…" (dimmed
/// only while this Mac's iTerm2 shows the session already; beside a window of the chosen plain
/// terminal the backend decides, `SessionRow.offersMoveHere`) and, only for
/// an attachment in this Mac's iTerm2 or such a window, "Detach from this Mac", which detaches
/// with tmux and leaves the session running, "Detach (opened in <terminal>)" for each record
/// another terminal keeps (through that terminal's backend), and, only while the listing shows
/// more clients than this Mac's attachments of a live row, "Detach other clients…" (hidden
/// otherwise, disabled while another action of the row is pending; PLAN.md D37), which asks
/// first.
struct SessionMenu: View {
  /// "Move here…".
  static let moveHereTitle = "Move here…"
  /// "Detach from this Mac".
  static let detachTitle = "Detach from this Mac"
  /// "Detach other clients…".
  static let detachOtherClientsTitle = "Detach other clients…"

  /// The row the menu is for.
  let row: SessionRow
  /// The model the items talk to.
  let model: AppModel

  /// The items.
  var body: some View {
    let wording = model.terminalWording
    Button(wording.openTitle) { model.open(row.key) }
    if row.hasWindowHere {
      Button(wording.showTitle) { model.showWindow(for: row.key) }
    }
    ForEach(row.openInApps) { entry in
      Button(entry.showTitle) { model.showInApp(entry.app, for: row.key) }
    }
    Button(Self.moveHereTitle) { model.requestMoveHere(row.key) }
      .disabled(!row.offersMoveHere)
    if row.offersDetach || !row.otherTerminalDetaches.isEmpty {
      Divider()
    }
    if row.offersDetach {
      Button(Self.detachTitle) { model.detach(row.key) }
        .help(wording.detachHelp)
    }
    ForEach(row.otherTerminalDetaches) { other in
      Button(other.title) { model.detach(row.key, openedIn: other.terminalID) }
        .disabled(row.isPending)
        .help(other.wording.detachOpenedInHelp)
    }
    if row.offersDetachOtherClients {
      Button(Self.detachOtherClientsTitle) { model.requestDetachOtherClients(row.key) }
        .disabled(row.isPending)
        .help(wording.detachOtherClientsHelp)
    }
  } // End of var body
}

/// "Open in Terminal on this Mac" with "Show in Terminal" (PLAN.md D38 *The UI (I-12d2)*): a
/// client of the session runs in that app here, as process ancestry traced it. The badge looks
/// like "Open in iTerm2 here"; the button brings the running app forward through the chosen
/// terminal's backend (no Apple event, nothing launched).
struct OpenInAppLine: View {
  /// The app.
  let entry: OpenInApp
  /// The session.
  let key: SessionKey
  /// The model the button talks to.
  let model: AppModel

  /// The badge and the button.
  var body: some View {
    HStack(spacing: 6) {
      OpenHereBadge(text: entry.badgeText)
      Button(entry.showTitle) { model.showInApp(entry.app, for: key) }
        .controlSize(.mini)
        .help("Brings \(entry.wording.name) forward. Nothing is opened or launched.")
    }
  } // End of var body
}

/// "Open in iTerm2 here": an iTerm2 tmux connection on this Mac shows the session (from
/// `AttachmentIndex` only); `text` adds "also attached elsewhere" while "Detach other clients…"
/// is offered (`SessionRow.openHereText`). White text on a solid blue capsule
/// (`PopoverPalette`), readable on a selected row and an unselected one alike.
struct OpenHereBadge: View {
  /// The badge's text.
  var text = SessionRow.openHereBadge
  /// Light or dark, for the palette.
  @Environment(\.colorScheme) private var colorScheme

  /// The capsule.
  var body: some View {
    let palette = PopoverPalette(colorScheme)
    Label(text, systemImage: "macwindow")
      .font(.caption2.weight(.semibold))
      .foregroundStyle(palette.badgeText)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(Capsule().fill(palette.badgeFill))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(text)
  }
}

/// Progress ("Opening…", "Waiting for iTerm2…", "Detaching other clients…"), "Still
/// connecting — check the iTerm2 tab" with "Show tab" (a plain terminal's: "… the Terminal
/// window" with "Show window", PLAN.md D38 *The UI (I-12d2)*), a result ("Confirmed…",
/// "Detached…"), "No other clients to detach…" with an information mark, or a failure with its
/// recoveries and, when it has one, its fix-it.
struct ActivityLine: View {
  /// What to show.
  let activity: SessionActivity
  /// The session.
  let key: SessionKey
  /// The model the buttons talk to.
  let model: AppModel

  /// A spinner or icon and the text, with the buttons that go with it.
  var body: some View {
    switch activity {
    case .failed(let problem):
      VStack(alignment: .leading, spacing: 4) {
        MessageLine(text: problem.message, systemImage: "xmark.octagon.fill", tint: .red)
        if !problem.recoveries.isEmpty {
          HStack(spacing: 6) {
            ForEach(problem.recoveries, id: \.self) { recovery in
              Button(recovery.title) { model.perform(recovery, for: key) }
                .controlSize(.small)
            }
          }
          .padding(.leading, 18)
        }
        if let fixIt = problem.fixIt {
          FixItView(fixIt: fixIt, shownExplanation: model.shownExplanation, perform: model.perform)
        }
      } // End of VStack holding the failure
    case .stillConnecting:
      MessageLine(
        text: activity.text, systemImage: "hourglass", tint: .orange, actionTitle: "Show tab"
      ) {
        model.showTab(for: key)
      }
    case .stillConnectingInWindow(_, let wording):
      MessageLine(
        text: activity.text, systemImage: "hourglass", tint: .orange,
        actionTitle: wording.showTitle
      ) {
        model.showLaunchWindow(for: key)
      }
    case .confirmed, .focused, .detached, .detachedOtherClients, .confirmedInTerminal,
      .focusedWindow, .focusedApp:
      MessageLine(text: activity.text, systemImage: "checkmark.circle.fill", tint: .green)
    case .noOtherClientsLeft:
      MessageLine(text: activity.text, systemImage: "info.circle.fill", tint: .blue)
    case .opening, .movingHere, .waitingForITerm2, .detaching, .detachingOtherClients,
      .waitingForTerminal:
      HStack(spacing: 6) {
        ProgressView()
          .progressViewStyle(.circular)
          .controlSize(.mini)
        Text(activity.text)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  } // End of var body
}
