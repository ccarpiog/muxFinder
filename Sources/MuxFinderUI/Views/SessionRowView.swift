import MuxFinderCore
import SwiftUI

/// One session: its name, "4 windows · 1 client" (or "Last seen … · not live"), the
/// "Open in iTerm2 here" badge, and any progress, result or failure. A click opens it; the
/// context menu offers "Move here…" and, for an attachment in this Mac's iTerm2, "Detach from
/// this Mac" (PLAN.md D25).
struct SessionRowView: View {
  /// The row's content.
  let row: SessionRow
  /// The model the row talks to.
  let model: AppModel
  /// Whether the pointer is over the row.
  @State private var isHovered = false

  /// The row's layout and its single accessibility element.
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(row.name)
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(row.isStale ? .secondary : .primary)
        Spacer(minLength: 8)
        if row.isStale {
          Image(systemName: "clock")
            .imageScale(.small)
            .foregroundStyle(.secondary)
        }
        Text(row.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      } // End of HStack holding the name and the detail
      if row.isOpenInITerm2Here {
        OpenHereBadge()
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
    } // End of VStack holding the row
    .padding(.vertical, 5)
    .padding(.horizontal, 6)
    .background(RoundedRectangle(cornerRadius: 6).fill(background))
    .contentShape(Rectangle())
    .onTapGesture { model.open(row.key) }
    .onHover { isHovered = $0 }
    .contextMenu { SessionMenu(row: row, model: model) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityValue(row.accessibilityValue)
    .accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : [.isButton])
    .accessibilityHint("Opens the session in iTerm2.")
    .accessibilityAction { model.open(row.key) }
    .accessibilityActions { accessibilityActions }
  } // End of var body

  /// The row's other actions for VoiceOver: the menu's, and the activity's buttons.
  @ViewBuilder private var accessibilityActions: some View {
    if row.offersMoveHere {
      Button(SessionMenu.moveHereTitle) { model.requestMoveHere(row.key) }
    }
    if row.offersDetach {
      Button(SessionMenu.detachTitle) { model.detach(row.key) }
    }
    if case .stillConnecting = row.activity {
      Button("Show tab") { model.showTab(for: row.key) }
    }
    if let problem = row.activity?.problem {
      ForEach(problem.recoveries, id: \.self) { recovery in
        Button(recovery.title) { model.perform(recovery, for: row.key) }
      }
    }
  } // End of var accessibilityActions

  /// The selection's tint, a faint hover tint, or nothing.
  private var background: Color {
    if row.isSelected { return Color.accentColor.opacity(0.22) }
    return isHovered ? Color.primary.opacity(0.06) : .clear
  }
}

/// A session row's context menu: "Open in iTerm2", "Move here…" (not while this Mac's iTerm2
/// shows the session already) and, only for an attachment in this Mac's iTerm2, "Detach from
/// this Mac", which detaches with tmux and leaves the session running.
struct SessionMenu: View {
  /// "Move here…".
  static let moveHereTitle = "Move here…"
  /// "Detach from this Mac".
  static let detachTitle = "Detach from this Mac"

  /// The row the menu is for.
  let row: SessionRow
  /// The model the items talk to.
  let model: AppModel

  /// The items.
  var body: some View {
    Button("Open in iTerm2") { model.open(row.key) }
    Button(Self.moveHereTitle) { model.requestMoveHere(row.key) }
      .disabled(!row.offersMoveHere)
    if row.offersDetach {
      Divider()
      Button(Self.detachTitle) { model.detach(row.key) }
        .help("Detaches this Mac's iTerm2 from the session. The session keeps running.")
    }
  }
}

/// "Open in iTerm2 here": an iTerm2 tmux connection on this Mac shows the session (from
/// `AttachmentIndex` only).
struct OpenHereBadge: View {
  /// The capsule.
  var body: some View {
    Label(SessionRow.openHereBadge, systemImage: "macwindow")
      .font(.caption2.weight(.medium))
      .foregroundStyle(Color.accentColor)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(Color.accentColor.opacity(0.14)))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(SessionRow.openHereBadge)
  }
}

/// Progress ("Opening…", "Waiting for iTerm2…"), "Still connecting — check the iTerm2 tab"
/// with "Show tab", a result ("Confirmed…", "Detached…"), or a failure with its recoveries and,
/// when it has one, its fix-it.
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
    case .confirmed, .focused, .detached:
      MessageLine(text: activity.text, systemImage: "checkmark.circle.fill", tint: .green)
    case .opening, .movingHere, .waitingForITerm2, .detaching:
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
