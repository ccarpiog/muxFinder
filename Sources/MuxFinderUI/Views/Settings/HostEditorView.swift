import MuxFinderCore
import SwiftUI

/// The host editor (PLAN.md Phase 9a): name, This Mac or SSH, destination with suggestions and
/// "Set up SSH in iTerm2…" (D24, under the connection test's result instead when that test
/// needed a sign-in or had a host key problem), turned on, the tmux path with "Detect", the
/// iTerm2 profile, the persistent profile's switch, default session name and parent profile
/// (D26), "Test connection", and Remove, Revert and Save. Inline errors come from the model's
/// `HostDraftIssues`; the whole editor is disabled while the list is not editable.
struct HostEditorView: View {
  /// The model shown.
  let model: SettingsModel

  /// The sections and the footer.
  var body: some View {
    if let draft = model.draft {
      let issues = model.issues
      VStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            hostSection(draft, issues: issues)
            tmuxSection(draft, issues: issues)
            iTermSection(draft, issues: issues)
            persistentProfileSection(draft, issues: issues)
            connectionSection(draft)
          }
          .padding(14)
        }
        Divider()
        footer(draft)
      }
      .disabled(!model.isEditable)
    }
  } // End of var body

  // MARK: - Sections

  /// Name, connection, destination and turned on.
  private func hostSection(_ draft: HostDraft, issues: HostDraftIssues?) -> some View {
    SettingsSection(title: "Host") {
      FieldRow(label: "Name") {
        TextField("Name", text: binding(draft.displayName, model.setDisplayName))
          .labelsHidden()
          .accessibilityLabel("Name")
        if let error = issues?.displayName { IssueText(text: error) }
      }
      FieldRow(label: "Connection") {
        Picker("Connection", selection: modeBinding(draft)) {
          Text("This Mac").tag(HostConfig.ConnectionMode.local)
          Text("SSH").tag(HostConfig.ConnectionMode.ssh)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        if let notice = model.thisMacNotice {
          NoteText(text: notice)
        } else if draft.mode == .local {
          NoteText(text: "This Mac's tmux is checked directly, without SSH.")
        }
      }
      if draft.mode == .ssh {
        FieldRow(label: "SSH destination") {
          HStack(spacing: 6) {
            TextField(
              "host name, user@host or alias",
              text: binding(draft.sshDestination, model.setDestination)
            )
            .labelsHidden()
            .accessibilityLabel("SSH destination")
            suggestionsMenu
          }
          if let error = issues?.destination { IssueText(text: error) }
          NoteText(
            text: "A host name, user@host, or a Host alias from your SSH configuration. "
              + "muxFinder uses your own SSH settings and keys.")
          if !model.connectionTestOffersSSHSetup {
            sshSetupControls(title: "Set up SSH in iTerm2…", draft: draft)
          }
        }
      }
      FieldRow(label: "") {
        Toggle("Turned on", isOn: Binding(get: { draft.isEnabled }, set: { model.setEnabled($0) }))
          .disabled(!draft.isEnabled && !draft.canTurnOn)
        if let refusal = issues?.enabled ?? model.enableRefusal {
          IssueText(text: refusal)
        } else if !draft.canTurnOn {
          NoteText(text: "Add a valid SSH destination to turn this host on.")
        } else {
          NoteText(text: "muxFinder lists sessions only from hosts that are turned on.")
        }
      }
    } // End of SettingsSection "Host"
  } // End of func hostSection(_:issues:)

  /// The tmux path and "Detect".
  private func tmuxSection(_ draft: HostDraft, issues: HostDraftIssues?) -> some View {
    SettingsSection(title: "tmux") {
      FieldRow(label: "tmux path") {
        HStack(spacing: 6) {
          TextField("Automatic", text: binding(draft.tmuxPath, model.setTmuxPath))
            .labelsHidden()
            .accessibilityLabel("tmux path")
          Button("Detect") { model.detectTmux() }
            .disabled(!draft.canDetect || model.detection == .running)
            .help("Look for tmux on this host and fill in its path")
        }
        if let error = issues?.tmuxPath { IssueText(text: error) }
        probeLine(
          message: model.detection.message, isRunning: model.detection == .running,
          isProblem: model.detection.isProblem)
        NoteText(
          text: "Leave empty to look in the usual places (Homebrew, MacPorts, /usr/bin) on "
            + "each check.")
      }
    }
  } // End of func tmuxSection(_:issues:)

  /// The iTerm2 profile: a picker of iTerm2's profiles, or free text when they can't be
  /// listed.
  private func iTermSection(_ draft: HostDraft, issues: HostDraftIssues?) -> some View {
    SettingsSection(title: "iTerm2") {
      FieldRow(label: "Profile") {
        if case .available(let names) = model.profileChoices {
          Picker("Profile", selection: binding(draft.profileName, model.setProfileName)) {
            Text("iTerm2 default").tag("")
            ForEach(names, id: \.self) { name in
              Text(name).tag(name)
            }
            if !draft.profileName.isEmpty, !names.contains(draft.profileName) {
              Text("\(draft.profileName) (not in iTerm2)").tag(draft.profileName)
            }
          }
          .labelsHidden()
          .fixedSize()
        } else {
          TextField("iTerm2 default", text: binding(draft.profileName, model.setProfileName))
            .labelsHidden()
            .accessibilityLabel("iTerm2 profile")
        }
        if let error = issues?.profileName { IssueText(text: error) }
        if let warning = model.profileWarning { IssueText(text: warning) }
        if let note = model.profileChoices.note { NoteText(text: note) }
        if let fixIt = model.profileChoices.fixIt {
          FixItView(fixIt: fixIt, shownExplanation: model.shownExplanation, perform: model.perform)
        }
      } // End of FieldRow "Profile"
    }
  } // End of func iTermSection(_:issues:)

  /// The persistent profile (PLAN.md D26): on or off, the default session name (empty: `main`)
  /// and the parent profile, a picker of iTerm2's profiles or free text.
  private func persistentProfileSection(
    _ draft: HostDraft, issues: HostDraftIssues?
  ) -> some View {
    let settings = draft.persistentProfile
    let profile =
      draft.trimmedName.isEmpty
      ? "a “Persistent work” profile" : "“\(PersistentProfiles.namePrefix)\(draft.trimmedName)”"
    return SettingsSection(title: "Persistent profile") {
      FieldRow(label: "") {
        Toggle(
          "Persistent profile",
          isOn: Binding(
            get: { settings.isEnabled }, set: { model.setPersistentProfileEnabled($0) }))
        NoteText(
          text: "Adds \(profile) to iTerm2's profiles: its tabs run inside this host's tmux "
            + "session, so work started there keeps running after the tab closes. Install it "
            + "in the Persistent profiles tab.")
      }
      FieldRow(label: "Session") {
        TextField(
          HostConfig.standardDefaultSessionName,
          text: binding(settings.defaultSessionName, model.setDefaultSessionName)
        )
        .labelsHidden()
        .accessibilityLabel("Default session name")
        if let error = issues?.defaultSessionName { IssueText(text: error) }
        NoteText(
          text: "The session the profile attaches, or creates when it doesn't exist. Leave "
            + "empty for “\(HostConfig.standardDefaultSessionName)”.")
      }
      FieldRow(label: "Parent profile") {
        parentProfileField(settings)
        if let error = issues?.parentProfileName { IssueText(text: error) }
        if let warning = model.parentProfileWarning { IssueText(text: warning) }
        NoteText(
          text: "Colors, fonts and other settings come from this profile. Without one, iTerm2 "
            + "uses its default profile.")
      }
    } // End of SettingsSection "Persistent profile"
  } // End of func persistentProfileSection(_:issues:)

  /// The parent profile: a picker of iTerm2's profiles, or free text when they can't be listed
  /// (as the iTerm2 profile field).
  @ViewBuilder
  private func parentProfileField(_ settings: HostDraft.PersistentProfileSettings) -> some View {
    let value = settings.parentProfileName
    if case .available(let names) = model.profileChoices {
      Picker("Parent profile", selection: binding(value, model.setParentProfileName)) {
        Text("None").tag("")
        ForEach(names, id: \.self) { name in
          Text(name).tag(name)
        }
        if !value.isEmpty, !names.contains(value) {
          Text("\(value) (not in iTerm2)").tag(value)
        }
      }
      .labelsHidden()
      .fixedSize()
    } else {
      TextField("None", text: binding(value, model.setParentProfileName))
        .labelsHidden()
        .accessibilityLabel("Parent profile")
    }
  } // End of func parentProfileField(_:)

  /// "Test connection" and its result.
  private func connectionSection(_ draft: HostDraft) -> some View {
    SettingsSection(title: "Connection") {
      FieldRow(label: "") {
        HStack(spacing: 8) {
          Button("Test connection") { model.testConnection() }
            .disabled(!draft.canTest || model.connectionTest == .running)
          if model.connectionTest == .running {
            ProgressView()
              .controlSize(.small)
            Text("Testing…")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
        if case .finished(let result) = model.connectionTest {
          ConnectionTestResultView(result: result)
          if model.connectionTestOffersSSHSetup {
            sshSetupControls(title: "Set up SSH in iTerm2 first", draft: draft)
          }
        }
        NoteText(
          text: "Runs the same read-only check as the menu, with the values above; nothing is "
            + "saved or opened.")
      }
    }
  } // End of func connectionSection(_:)

  // MARK: - Footer

  /// Remove…, the save status, Revert and Save.
  private func footer(_ draft: HostDraft) -> some View {
    HStack(spacing: 8) {
      if !draft.isNew {
        Button("Remove…", role: .destructive) { model.requestRemoval() }
      }
      if let error = model.saveError {
        IssueText(text: error)
          .lineLimit(3)
      } else if let notice = model.saveNotice {
        NoteText(text: notice)
          .lineLimit(2)
      }
      Spacer(minLength: 8)
      Button(draft.isNew ? "Cancel" : "Revert") { model.revert() }
        .disabled(!model.isDirty)
      Button("Save") { Task { await model.save() } }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canSave)
    } // End of HStack holding the footer
    .padding(12)
  } // End of func footer(_:)

  // MARK: - Helpers

  /// "Set up SSH in iTerm2…" (PLAN.md D24) titled `title`, and its line: under the destination,
  /// or, after a connection test that needed a sign-in or had a host key problem, under its
  /// result instead.
  private func sshSetupControls(title: String, draft: HostDraft) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Button(title) { model.setUpSSH() }
        .disabled(!model.canSetUpSSH)
        .help(
          "Open a new iTerm2 window running ssh to this destination, so you can sign in or "
            + "accept its host key")
      if let state = model.sshSetup.states[draft.id] {
        SSHSetupLine(state: state, perform: model.perform, shownExplanation: model.shownExplanation)
      }
    }
  } // End of func sshSetupControls(title:draft:)

  /// The SSH configuration's host names, as a menu that fills the destination.
  @ViewBuilder private var suggestionsMenu: some View {
    if !model.suggestions.isEmpty {
      Menu {
        ForEach(model.suggestions.prefix(100), id: \.self) { name in
          Button(name) { model.setDestination(name) }
        }
      } label: {
        Image(systemName: "list.bullet")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Hosts from your SSH configuration")
      .accessibilityLabel("Suggestions from your SSH configuration")
    }
  } // End of var suggestionsMenu

  /// A probe's line: a spinner while it runs, then its message.
  @ViewBuilder
  private func probeLine(message: String?, isRunning: Bool, isProblem: Bool) -> some View {
    if let message {
      HStack(spacing: 6) {
        if isRunning {
          ProgressView()
            .controlSize(.mini)
        }
        if isProblem {
          IssueText(text: message)
        } else {
          NoteText(text: message)
        }
      }
    }
  } // End of func probeLine(message:isRunning:isProblem:)

  /// A text binding that reads `value` and writes through `set`.
  private func binding(
    _ value: String, _ set: @escaping @MainActor @Sendable (String) -> Void
  ) -> Binding<String> {
    Binding(get: { value }, set: { newValue in set(newValue) })
  }

  /// The mode picker's binding.
  private func modeBinding(_ draft: HostDraft) -> Binding<HostConfig.ConnectionMode> {
    Binding(get: { draft.mode }, set: { model.setMode($0) })
  }
}

/// "Test connection"'s result: the popover's status label, its explanation or the detail.
struct ConnectionTestResultView: View {
  /// The result.
  let result: ConnectionTestResult

  /// The status, then the explanation or detail.
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        StatusLabelView(status: result.status)
        if let detail = result.detail {
          Text("· " + detail)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      if let explanation = result.explanation {
        MessageLine(
          text: explanation, systemImage: "exclamationmark.triangle.fill", tint: .orange)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Connection test result")
  } // End of var body
}
