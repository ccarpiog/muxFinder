import SwiftUI

/// The terminal picker (PLAN.md D38, Phase I-12d1; requirement 8), in Settings › General and
/// onboarding's Terminal step: one row per terminal with its version, permission state and
/// note, "Allow in System Settings…" under a row macOS has not allowed or not asked yet, the
/// unavailable choice's reason, a waiting change's note, a refused save's error, "Check again",
/// and the definition files the loader could not use. Everything shown comes from
/// `TerminalPickerModel.content`.
struct TerminalPickerView: View {
  /// The picker shown.
  let picker: TerminalPickerModel

  /// The rows and what follows them.
  var body: some View {
    let content = picker.content
    VStack(alignment: .leading, spacing: 10) {
      NoteText(text: "muxFinder opens sessions in this terminal.")
      if content.isReading {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.mini)
          NoteText(text: TerminalPickerContent.readingText)
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        ForEach(content.rows) { row in
          rowView(row, isSelected: row.id == content.selectedID, isSaving: content.isSaving)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Terminal")
      if let note = content.pendingNote {
        MessageLine(text: note, systemImage: "clock", tint: .secondary)
      }
      if let error = content.saveError {
        IssueText(text: error)
      }
      HStack(spacing: 8) {
        Button("Check again") { picker.refresh() }
          .controlSize(.small)
          .help("Read the terminals and their Automation permission again")
        if content.isSaving {
          ProgressView()
            .controlSize(.small)
        }
      }
      if !content.problems.isEmpty {
        problemsView(content.problems)
      }
    } // End of VStack holding the picker
  } // End of var body

  /// One terminal: a radio button with its name, version, permission and note, its reason when
  /// it cannot be used, and "Allow in System Settings…" when macOS has not allowed it.
  private func rowView(
    _ row: TerminalPickerRow, isSelected: Bool, isSaving: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        Task { await picker.choose(row.id) }
      } label: {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(row.name)
              if let version = row.version {
                Text(version)
                  .foregroundStyle(.secondary)
              }
            }
            if let permission = row.permission {
              Text("Permission: " + permission.text)
                .font(.caption)
                .foregroundStyle(permission == .notAllowed ? Color.red : Color.secondary)
            }
            if let note = row.note {
              NoteText(text: note)
            }
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isSaving)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      if let reason = row.unavailableReason {
        IssueText(text: reason)
          .padding(.leading, 24)
      }
      if row.offersSystemSettings {
        Button("Allow in System Settings…") { picker.allowInSystemSettings() }
          .controlSize(.small)
          .padding(.leading, 24)
          .help("Open System Settings › Privacy & Security › Automation")
      }
    } // End of VStack holding the row
  } // End of func rowView(_:isSelected:isSaving:)

  /// The definition files the loader could not use: file name and reason only.
  private func problemsView(_ problems: [TerminalPickerProblem]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Terminal definitions not used")
        .font(.callout.weight(.semibold))
      ForEach(problems) { problem in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .imageScale(.small)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 1) {
            Text(problem.fileName)
              .font(.caption.monospaced())
            Text(problem.reason)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .accessibilityElement(children: .combine)
      } // End of loop over the problems
    }
  } // End of func problemsView(_:)
}
