import MuxFinderCore
import SwiftUI

/// One host's group: its header (name, last check, status), its problem with "Retry", its
/// empty state, and its session rows.
struct HostSectionView: View {
  /// The host's content.
  let section: HostSection
  /// The model the buttons talk to.
  let model: AppModel

  /// The group's layout.
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      header
      if let problem = section.problem {
        MessageLine(
          text: problem, systemImage: "exclamationmark.triangle.fill", tint: .orange,
          actionTitle: "Retry"
        ) {
          model.retry(hostID: section.id)
        }
        .padding(.horizontal, 6)
      }
      if section.offersSSHSetup {
        sshSetupLine
          .padding(.leading, 24)
          .padding(.trailing, 6)
      }
      if let emptyState = section.emptyState {
        Text(emptyState)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
      }
      ForEach(section.rows) { row in
        SessionRowView(row: row, model: model)
          .id(row.key)
      }
    } // End of VStack holding the group
    .padding(.horizontal, 8)
  } // End of var body

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
  /// right. One accessibility element, marked as a header.
  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      VStack(alignment: .leading, spacing: 1) {
        Text(section.name)
          .font(.headline)
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
    .padding(.horizontal, 6)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(section.accessibilityLabel)
    .accessibilityValue(section.accessibilityValue)
    .accessibilityAddTraits(.isHeader)
  } // End of var header
}

/// A host's status: a colored dot and the status text (the text always says it, so color is
/// never the only signal).
struct StatusLabelView: View {
  /// The status shown.
  let status: HostStatusLabel

  /// The dot and the text.
  var body: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(Self.color(for: status))
        .frame(width: 7, height: 7)
      Text(status.text)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Status")
    .accessibilityValue(status.text)
  } // End of var body

  /// The dot's color for a status's tone.
  static func color(for status: HostStatusLabel) -> Color {
    switch status.tone {
    case .good: return .green
    case .neutral: return .gray
    case .attention: return .orange
    case .problem: return .red
    }
  }
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
