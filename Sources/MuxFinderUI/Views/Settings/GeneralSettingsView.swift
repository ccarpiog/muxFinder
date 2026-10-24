import SwiftUI

/// The General tab: launch at login (`SMAppService.mainApp` through the model's seam), with
/// the status's explanation, its fix-it and any error; the session switcher shortcut's
/// recorder (PLAN.md D32); and a note on what quitting does.
struct GeneralSettingsView: View {
  /// The model shown.
  let model: SettingsModel

  /// The sections.
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        SettingsSection(title: "Startup") {
          if let content = model.launchAtLogin {
            Toggle(
              "Open muxFinder when you log in",
              isOn: Binding(get: { content.isOn }, set: { model.setLaunchAtLogin($0) }))
            NoteText(text: content.message)
            if let fixIt = content.fixIt {
              FixItView(
                fixIt: fixIt, shownExplanation: model.shownExplanation, perform: model.perform)
            }
          } else {
            NoteText(text: "Checking whether muxFinder opens when you log in…")
          }
          if let error = model.loginItemError {
            IssueText(text: error)
          }
        } // End of SettingsSection "Startup"
        SessionSwitcherSettingsSection(model: model.globalShortcut)
        SettingsSection(title: "About muxFinder") {
          NoteText(
            text: "muxFinder lists the tmux sessions on your Macs (each Mac's default tmux "
              + "server) and opens them in iTerm2.")
          NoteText(
            text: "Quitting muxFinder leaves your tmux sessions and iTerm2 tabs running.")
        }
      } // End of VStack holding the sections
      .padding(14)
    }
  } // End of var body
}

/// The Diagnostics tab: the last iTerm2 check's problem with its fix-it, the operation log
/// (newest first), "Refresh" and "Copy diagnostics".
struct DiagnosticsSettingsView: View {
  /// The model shown.
  let model: SettingsModel

  /// The note, the problem, the log and the buttons.
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      NoteText(
        text: "Recent operations, newest first. muxFinder records outcomes and timings only: "
          + "no terminal contents, window titles or commands. Copied diagnostics name hosts by "
          + "their display names, never by SSH destination.")
      if let problem = model.iTermProblem {
        VStack(alignment: .leading, spacing: 6) {
          MessageLine(
            text: problem.text, systemImage: "exclamationmark.triangle.fill", tint: .orange)
          if let fixIt = problem.fixIt {
            FixItView(
              fixIt: fixIt, shownExplanation: model.shownExplanation, perform: model.perform)
          }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
      }
      logList
      HStack(spacing: 8) {
        if let notice = model.copyNotice {
          NoteText(text: notice)
        }
        Spacer(minLength: 8)
        Button("Refresh") { Task { await model.refreshDiagnostics() } }
        Button("Copy diagnostics") { Task { await model.copyDiagnostics() } }
      }
    } // End of VStack holding the tab
    .padding(14)
    .task { await model.refreshDiagnostics() }
  } // End of var body

  /// The log's rows in a bordered, scrolling box, or a placeholder.
  @ViewBuilder private var logList: some View {
    let rows = model.diagnosticRows
    ScrollView {
      if rows.isEmpty {
        Text("Nothing recorded yet.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 24)
      } else {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(rows) { row in
            DiagnosticRowView(row: row)
            Divider()
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .textBackgroundColor))
    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
  } // End of var logList
}

/// One log entry: time, outcome, category, host and duration, then the detail.
struct DiagnosticRowView: View {
  /// The row's content.
  let row: SettingsModel.DiagnosticRow

  /// Two lines.
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Image(systemName: symbol)
          .foregroundStyle(tint)
          .imageScale(.small)
          .accessibilityHidden(true)
        Text(row.time, format: .dateTime.hour().minute().second())
          .monospacedDigit()
        Text(row.category)
          .foregroundStyle(.secondary)
        if let host = row.host {
          Text("· " + host)
        }
        if let duration = row.duration {
          Text("· " + duration)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        Spacer(minLength: 0)
      } // End of HStack holding the header line
      .font(.caption)
      Text(row.detail)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    } // End of VStack holding the row
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .accessibilityElement(children: .combine)
    .accessibilityValue(row.outcome.rawValue)
  } // End of var body

  /// The outcome's symbol.
  private var symbol: String {
    switch row.outcome {
    case .success: return "checkmark.circle.fill"
    case .failure: return "xmark.octagon.fill"
    case .timedOut: return "clock.badge.exclamationmark"
    case .cancelled: return "minus.circle"
    case .info: return "info.circle"
    }
  }

  /// The outcome's color.
  private var tint: Color {
    switch row.outcome {
    case .success: return .green
    case .failure: return .red
    case .timedOut: return .orange
    case .cancelled, .info: return .secondary
    }
  }
}
