import MuxFinderCore
import SwiftUI

/// One session: its name, "4 windows · 1 client" (or "Last seen … · not live"), the
/// "Open in iTerm2 here" badge, and any progress or failure. A click opens it (Phase 10; a
/// recorded placeholder until then).
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
        ActivityLine(activity: activity) {
          model.retry(session: row.key)
        }
      }
    } // End of VStack holding the row
    .padding(.vertical, 5)
    .padding(.horizontal, 6)
    .background(RoundedRectangle(cornerRadius: 6).fill(background))
    .contentShape(Rectangle())
    .onTapGesture { model.open(row.key) }
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityValue(row.accessibilityValue)
    .accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : [.isButton])
    .accessibilityHint("Opens the session in iTerm2.")
    .accessibilityAction { model.open(row.key) }
    .accessibilityActions {
      if case .failed = row.activity {
        Button("Retry") { model.retry(session: row.key) }
      }
    }
  } // End of var body

  /// The selection's tint, a faint hover tint, or nothing.
  private var background: Color {
    if row.isSelected { return Color.accentColor.opacity(0.22) }
    return isHovered ? Color.primary.opacity(0.06) : .clear
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

/// Progress ("Opening…", "Waiting for iTerm2…", "Waiting for you in iTerm2") or a failure
/// with "Retry".
struct ActivityLine: View {
  /// What to show.
  let activity: SessionActivity
  /// What "Retry" does.
  let retry: () -> Void

  /// A spinner or icon and the text; "Retry" for a failure.
  var body: some View {
    switch activity {
    case .failed(let message):
      MessageLine(
        text: message, systemImage: "xmark.octagon.fill", tint: .red, actionTitle: "Retry",
        action: retry)
    case .waitingForYou:
      MessageLine(text: activity.text, systemImage: "hourglass", tint: .orange)
    case .opening, .waitingForITerm2:
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
