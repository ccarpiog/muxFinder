import MuxFinderCore
import SwiftUI

/// The Persistent profiles tab (PLAN.md D26): the status of muxFinder's profile file in
/// iTerm2, the profiles the saved hosts make, "Install profiles", "Remove profiles" and "Check
/// again" with why they are off, the last result, and how to use the profiles (making one the
/// default, what is not adopted, a second tab, the parent warning). Everything shown comes from
/// `SettingsModel.persistentProfilesContent`. With a plain terminal chosen (PLAN.md D38, Phase
/// I-12d1) it shows `SettingsModel.persistentWorkContent` instead: each host's persistent work
/// command with Copy and where to paste it, and iTerm2's part in one line ("Remove profiles"
/// while muxFinder's file is installed).
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

  /// The copy on windows started otherwise, with a plain terminal chosen.
  static let plainNotAdoptedText =
    "Only windows that run the command work inside tmux. Other windows and apps are not moved "
    + "into tmux."
  /// The copy on running the command again, with a plain terminal chosen.
  static let plainSecondWindowText =
    "Running the command again while its session is open attaches that same session once more, "
    + "so both windows show the same work."

  /// The sections.
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if let work = model.persistentWorkContent {
          workSection(work)
          iTerm2Line(work)
          plainUsageSection
        } else {
          fileSection(model.persistentProfilesContent)
          usageSection
        }
      }
      .padding(14)
    }
  } // End of var body

  /// With a plain terminal chosen: each host's command with Copy, and where to paste it.
  private func workSection(_ work: PersistentWorkContent) -> some View {
    SettingsSection(title: work.title) {
      NoteText(text: work.introduction)
      MessageLine(text: work.whereToPaste, systemImage: "info.circle", tint: .secondary)
      if let problem = work.problem { IssueText(text: problem) }
      if let note = work.emptyNote {
        NoteText(text: note)
      }
      ForEach(work.lines) { line in
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.hostName)
              .font(.callout.weight(.medium))
            Spacer(minLength: 8)
            Button("Copy") { model.copyPersistentWorkCommand(for: line.id) }
              .controlSize(.small)
              .help("Copy \(line.hostName)'s command to the clipboard")
          }
          Text(line.command)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(line.hostName)'s command")
      } // End of loop over the hosts' commands
      if let notice = model.persistentWorkNotice {
        MessageLine(text: notice, systemImage: "checkmark.circle.fill", tint: .green)
      }
    } // End of SettingsSection holding the commands
  } // End of func workSection(_:)

  /// With a plain terminal chosen: iTerm2's profiles in one line, "Remove profiles" while
  /// muxFinder's file is installed, and the last result.
  private func iTerm2Line(_ work: PersistentWorkContent) -> some View {
    SettingsSection(title: "Profiles in iTerm2") {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        NoteText(text: work.iTerm2Line)
        Spacer(minLength: 8)
        if work.canRemoveITerm2Profiles || work.isRunning {
          Button("Remove profiles") { Task { await model.removeProfiles() } }
            .controlSize(.small)
            .disabled(!work.canRemoveITerm2Profiles)
        }
      }
      if let result = work.resultText {
        if work.resultIsProblem {
          IssueText(text: result)
        } else {
          MessageLine(text: result, systemImage: "checkmark.circle.fill", tint: .green)
        }
      }
    } // End of SettingsSection "Profiles in iTerm2"
  } // End of func iTerm2Line(_:)

  /// With a plain terminal chosen: how the command behaves.
  private var plainUsageSection: some View {
    SettingsSection(title: "Using persistent work") {
      NoteText(text: Self.plainNotAdoptedText)
      NoteText(text: Self.plainSecondWindowText)
    }
  }

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
