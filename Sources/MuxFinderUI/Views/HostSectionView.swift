import MuxFinderCore
import SwiftUI

/// One host's group (PLAN.md D22): a bounded box with a hairline border, its header band
/// (name, last check, status), its problem with "Retry", its empty state, and its session
/// rows separated by hairlines. An unreachable host's section reads muted.
struct HostSectionView: View {
  /// The section's corner radius, in points.
  static let cornerRadius: CGFloat = 8
  /// Where a row separator starts: past the row's inset and its indicator column.
  static let separatorInset: CGFloat = 4 + 8 + AttachStateIndicator.width + 8

  /// The host's content.
  let section: HostSection
  /// The model the buttons talk to.
  let model: AppModel
  /// Light or dark, for the palette.
  @Environment(\.colorScheme) private var colorScheme
  /// The display's scale, for hairlines one pixel wide.
  @Environment(\.displayScale) private var displayScale

  /// The group's layout.
  var body: some View {
    let palette = PopoverPalette(colorScheme)
    let hairline = 1 / max(displayScale, 1)
    let hasMessages =
      section.problem != nil || section.offersSSHSetup || section.emptyState != nil
    VStack(alignment: .leading, spacing: 0) {
      header
        .background(palette.headerBand)
      if hasMessages || !section.rows.isEmpty {
        Rectangle()
          .fill(palette.border)
          .frame(height: hairline)
      }
      if hasMessages {
        messages
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
      }
      if !section.rows.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(section.rows) { row in
            if row.key != section.rows.first?.key {
              Rectangle()
                .fill(palette.border)
                .frame(height: hairline)
                .padding(.leading, Self.separatorInset)
                .padding(.trailing, 8)
            }
            SessionRowView(row: row, model: model)
              .id(row.key)
          }
        }
        .padding(.vertical, 3)
      }
    } // End of VStack holding the group
    .background(palette.sectionFill)
    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
    .overlay(
      RoundedRectangle(cornerRadius: Self.cornerRadius)
        .strokeBorder(palette.border, lineWidth: hairline)
    )
  } // End of var body

  /// The problem with "Retry" (an orange triangle for what the user can fix, a neutral icon
  /// for an unreachable host), "Set up SSH in iTerm2 first" and the empty state.
  private var messages: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let problem = section.problem {
        MessageLine(
          text: problem,
          systemImage: section.isMuted ? "info.circle" : "exclamationmark.triangle.fill",
          tint: section.isMuted ? .secondary : .orange,
          actionTitle: "Retry"
        ) {
          model.retry(hostID: section.id)
        }
      }
      if section.offersSSHSetup {
        sshSetupLine
          .padding(.leading, 18)
      }
      if let emptyState = section.emptyState {
        Text(emptyState)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } // End of VStack holding the messages
  } // End of var messages

  /// "Set up SSH in iTerm2 first" under a sign-in or host key problem (PLAN.md D24), and what
  /// it did.
  private var sshSetupLine: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button("Set up SSH in iTerm2 first") { model.setUpSSH(hostID: section.id) }
        .controlSize(.small)
        .disabled(section.sshSetup == .opening)
        .help(
          "Open a new iTerm2 window running ssh to this host, so you can sign in or check its key")
      if let state = section.sshSetup {
        SSHSetupLine(state: state, perform: model.perform, shownExplanation: model.shownExplanation)
      }
    }
  } // End of var sshSetupLine

  /// Name and "Last checked …" on the left, a spinner while refreshing and the status on the
  /// right, on the header band; a muted section's name in secondary color. One accessibility
  /// element, marked as a header.
  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      VStack(alignment: .leading, spacing: 1) {
        Text(section.name)
          .font(.headline)
          .foregroundStyle(section.isMuted ? .secondary : .primary)
          .lineLimit(1)
        if let caption = section.caption {
          Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      if section.isRefreshing {
        ProgressView()
          .progressViewStyle(.circular)
          .controlSize(.mini)
      }
      StatusLabelView(status: section.status)
    } // End of HStack holding the header
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(section.accessibilityLabel)
    .accessibilityValue(section.accessibilityValue)
    .accessibilityAddTraits(.isHeader)
  } // End of var header
}

/// A host's status: its dot (`StatusDot`, hollow for an unreachable host) and the status text
/// (the text always says it, so color is never the only signal).
struct StatusLabelView: View {
  /// The status shown.
  let status: HostStatusLabel

  /// The dot and the text.
  var body: some View {
    HStack(spacing: 4) {
      StatusDot(tone: status.tone)
      Text(status.text)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Status")
    .accessibilityValue(status.text)
  } // End of var body
}

/// An icon, an explanation that wraps, and an optional button ("Retry").
struct MessageLine: View {
  /// The explanation.
  let text: String
  /// The SF Symbol before it.
  let systemImage: String
  /// The symbol's color.
  let tint: Color
  /// The button's title, if there is a button.
  var actionTitle: String?
  /// What the button does.
  var action: () -> Void = {}

  /// The line's layout.
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: systemImage)
        .imageScale(.small)
        .foregroundStyle(tint)
        .accessibilityHidden(true)
      Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 4)
      if let actionTitle {
        Button(actionTitle, action: action)
          .controlSize(.small)
      }
    } // End of HStack holding the line
    .accessibilityElement(children: .contain)
  } // End of var body
}
