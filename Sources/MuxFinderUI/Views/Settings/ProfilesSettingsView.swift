import MuxFinderCore
import SwiftUI

/// The Persistent profiles tab (PLAN.md D26): the status of muxFinder's profile file in
/// iTerm2, the profiles the saved hosts make, "Install profiles", "Remove profiles" and "Check
/// again" with why they are off, the last result, and how to use the profiles (making one the
/// default, what is not adopted, a second tab, the parent warning). Everything shown comes from
/// `SettingsModel.persistentProfilesContent`.
struct ProfilesSettingsView: View {
  /// The model shown.
  let model: SettingsModel

  /// The copy on making a profile iTerm2's default.
  static let setAsDefaultText =
    "To open every new iTerm2 window or tab in a persistent profile, make it iTerm2's default: "
    + "in iTerm2, choose Settings › Profiles, select the profile, then choose Other Actions › "
    + "Set as Default."
  /// The copy on shells started elsewhere.
  static let notAdoptedText =
    "Only tabs opened with a persistent profile run inside tmux. Shells started from other "
    + "profiles or other apps are not moved into tmux."
  /// The copy on opening the profile again (not tried with iTerm2, PLAN.md D26).
  static let secondTabText =
    "Opening the profile again while its session is open attaches that same session once more, "
    + "so iTerm2 may show its windows a second time; both show the same work. For a separate "
    + "shell, use another profile."
  /// The parent-inheritance warning (PLAN.md D26).
  static let parentWarningText =
    "Before making a persistent profile the default, check your other dynamic profiles: iTerm2 "
    + "bases a dynamic profile without a parent on the default profile, so one that sets no "
    + "parent and no command of its own would start this host's tmux session too. muxFinder "
    + "can't change those profiles; give them a parent, or keep another profile as the default."

  /// The sections.
  var body: some View {
    let content = model.persistentProfilesContent
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        fileSection(content)
        usageSection
      }
      .padding(14)
    }
  } // End of var body

  /// The file's status, the profiles, the buttons and the result.
  private func fileSection(_ content: PersistentProfilesContent) -> some View {
    SettingsSection(title: "Profiles in iTerm2") {
      FieldRow(label: "Status") {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          if content.tone == .checking {
            ProgressView()
              .controlSize(.mini)
          } else {
            Image(systemName: Self.symbol(content.tone))
              .foregroundStyle(Self.tint(content.tone))
              .accessibilityHidden(true)
          }
          Text(content.statusText)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      FieldRow(label: "Profiles") {
        if content.profileNames.isEmpty {
          NoteText(text: "None: no saved host has its persistent profile turned on.")
        } else {
          ForEach(content.profileNames, id: \.self) { name in
            Text(name)
          }
        }
      }
      FieldRow(label: "") {
        HStack(spacing: 8) {
          Button("Install profiles") { Task { await model.installProfiles() } }
            .disabled(!content.canInstall)
          Button("Remove profiles") { Task { await model.removeProfiles() } }
            .disabled(!content.canRemove)
          Button("Check again") { Task { await model.checkProfiles() } }
            .disabled(!content.canCheck)
          if content.isRunning {
            ProgressView()
              .controlSize(.small)
          }
        }
        if let result = content.resultText {
          if content.resultIsProblem {
            IssueText(text: result)
          } else {
            MessageLine(text: result, systemImage: "checkmark.circle.fill", tint: .green)
          }
        }
        if let note = content.installNote { NoteText(text: note) }
        if let note = content.draftNote { NoteText(text: note) }
        NoteText(
          text: "muxFinder writes only its own file, muxFinder.json in iTerm2's DynamicProfiles "
            + "folder. While it is installed, saving hosts and starting muxFinder keep it up to "
            + "date.")
      } // End of FieldRow holding the buttons
    } // End of SettingsSection "Profiles in iTerm2"
  } // End of func fileSection(_:)

  /// How to use the profiles.
  private var usageSection: some View {
    SettingsSection(title: "Using persistent profiles") {
      NoteText(text: Self.setAsDefaultText)
      NoteText(text: Self.notAdoptedText)
      NoteText(text: Self.secondTabText)
      MessageLine(
        text: Self.parentWarningText, systemImage: "exclamationmark.triangle.fill", tint: .orange)
    }
  } // End of var usageSection

  /// The status line's symbol.
  static func symbol(_ tone: PersistentProfilesContent.Tone) -> String {
    switch tone {
    case .checking, .neutral: return "circle.dashed"
    case .good: return "checkmark.circle.fill"
    case .warning: return "exclamationmark.circle.fill"
    case .problem: return "exclamationmark.triangle.fill"
    }
  }

  /// The status line's color.
  static func tint(_ tone: PersistentProfilesContent.Tone) -> Color {
    switch tone {
    case .checking, .neutral: return .secondary
    case .good: return .green
    case .warning: return .orange
    case .problem: return .red
    }
  }
}
