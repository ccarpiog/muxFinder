import MuxFinderCore
import SwiftUI

/// The onboarding window's content (PLAN.md Phase 9b, D24): the welcome, the example hosts with
/// their names, SSH destinations, "Set up SSH in iTerm2…", the This Mac choice and the
/// turned-on switches, then what to expect, the scope line and the iTerm2 requirements, and
/// "Not now" and "Save hosts" at the bottom.
public struct OnboardingView: View {
  /// The window's size when it first opens, in points.
  public static let defaultSize = CGSize(width: 780, height: 760)
  /// The smallest the window gets, in points.
  public static let minimumSize = CGSize(width: 700, height: 480)
  /// The width of the name fields.
  static let nameWidth: CGFloat = 130

  /// The model shown.
  let model: OnboardingModel
  /// Whether the content scrolls (the window) or takes its full height (the preview gallery).
  let scrolls: Bool

  /// An onboarding view for `model`.
  public init(model: OnboardingModel, scrolls: Bool = true) {
    self.model = model
    self.scrolls = scrolls
  }

  /// The sections above the footer.
  public var body: some View {
    VStack(spacing: 0) {
      if scrolls {
        ScrollView { sections }
      } else {
        sections
      }
      Divider()
      footer
    }
  } // End of var body

  /// The welcome, the hosts, what to expect and the iTerm2 requirements.
  private var sections: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      hostsSection
      expectationsSection
      iTermSection
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The title and the introduction.
  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "terminal")
        .font(.system(size: 30))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(OnboardingText.title)
          .font(.title2.bold())
        Text(OnboardingText.introduction)
          .foregroundStyle(.secondary)
      }
    }
  } // End of var header

  // MARK: - Hosts

  /// The note, then one block per example host.
  private var hostsSection: some View {
    SettingsSection(title: "Your Macs") {
      NoteText(text: OnboardingText.hostsNote)
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
        GridRow {
          columnTitle("Name")
          columnTitle("SSH destination")
          columnTitle("")
          columnTitle("")
        }
        ForEach(model.drafts, id: \.id) { draft in
          hostRow(draft)
          messagesRow(draft)
        }
      } // End of Grid holding the hosts
      .disabled(!model.isEditable)
    }
  } // End of var hostsSection

  /// A column's title.
  private func columnTitle(_ text: String) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  /// One host: its name, its destination (or This Mac's note) with "Set up SSH in iTerm2…",
  /// This Mac and turned on.
  private func hostRow(_ draft: HostDraft) -> some View {
    GridRow {
      TextField(
        "Name", text: textBinding(draft.displayName) { model.setDisplayName($0, for: draft.id) }
      )
      .labelsHidden()
      .frame(width: Self.nameWidth)
      .accessibilityLabel("Name")
      if draft.mode == .ssh {
        HStack(spacing: 6) {
          TextField(
            "host name, user@host or alias",
            text: textBinding(draft.sshDestination) { model.setDestination($0, for: draft.id) }
          )
          .labelsHidden()
          .accessibilityLabel("SSH destination of \(draft.trimmedName)")
          Button("Set up SSH in iTerm2…") { model.setUpSSH(for: draft.id) }
            .fixedSize()
            .disabled(!model.canSetUpSSH(draft.id))
            .help(
              "Open a new iTerm2 window running ssh to this destination, so you can sign in or "
                + "accept its host key")
        }
      } else {
        Text("This Mac: checked directly, without SSH")
          .foregroundStyle(.secondary)
      }
      Toggle(
        "This Mac",
        isOn: Binding(
          get: { draft.mode == .local },
          set: { model.chooseThisMac($0 ? draft.id : nil) })
      )
      .toggleStyle(.checkbox)
      .help("muxFinder checks This Mac directly; only one host can be This Mac")
      Toggle(
        "Turned on",
        isOn: Binding(get: { draft.isEnabled }, set: { model.setEnabled($0, for: draft.id) })
      )
      .toggleStyle(.checkbox)
      .disabled(!draft.isEnabled && !draft.canTurnOn)
    } // End of GridRow holding the host
  } // End of func hostRow(_:)

  /// The host's inline errors and its "Set up SSH in iTerm2…" line, under its fields.
  @ViewBuilder
  private func messagesRow(_ draft: HostDraft) -> some View {
    let issues = model.issues(for: draft.id)
    let lines = [
      issues?.displayName, issues?.destination,
      issues?.enabled ?? model.enableRefusals[draft.id],
    ].compactMap { $0 }
    let setup = model.sshSetup.states[draft.id]
    if !lines.isEmpty || setup != nil {
      GridRow {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(lines, id: \.self) { IssueText(text: $0) }
          if let setup {
            SSHSetupLine(state: setup)
          }
        }
        .gridCellColumns(4)
      }
    }
  } // End of func messagesRow(_:)

  // MARK: - What to expect and iTerm2

  /// The four expectations and the scope line.
  private var expectationsSection: some View {
    SettingsSection(title: "Good to know") {
      ForEach(OnboardingText.expectations, id: \.self) { line in
        BulletLine(text: line)
      }
      BulletLine(text: OnboardingText.scope)
    }
  }

  /// What iTerm2 needs.
  private var iTermSection: some View {
    SettingsSection(title: "iTerm2") {
      ForEach(OnboardingText.iTermRequirements, id: \.self) { line in
        BulletLine(text: line)
      }
    }
  }

  // MARK: - Footer

  /// The save status, "Not now" and "Save hosts".
  private var footer: some View {
    HStack(spacing: 8) {
      if let error = model.saveError {
        IssueText(text: error)
          .lineLimit(3)
        if model.fileChanged {
          Button("Open Settings") { model.openSettings() }
        }
      } else if model.isSaving {
        ProgressView()
          .controlSize(.small)
        Text("Saving…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Button("Not now") { model.notNow() }
        .help("Close without saving; this window shows again the next time muxFinder starts")
      Button("Save hosts") { Task { await model.save() } }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canSave)
    } // End of HStack holding the footer
    .padding(12)
  } // End of var footer

  // MARK: - Helpers

  /// A text binding that reads `value` and writes through `set`.
  private func textBinding(
    _ value: String, _ set: @escaping @MainActor (String) -> Void
  ) -> Binding<String> {
    Binding(get: { value }, set: { newValue in set(newValue) })
  }
}

/// One line of a list, after a bullet.
struct BulletLine: View {
  /// The line.
  let text: String

  /// The bullet and the text, wrapping.
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text("•")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// A "Set up SSH in iTerm2…" line: a spinner while the tab opens, what happened, and a fix-it
/// for an iTerm2 error.
struct SSHSetupLine: View {
  /// The state shown.
  let state: SSHSetupState
  /// Performs the fix-it, if any (`nil`: no button).
  var perform: ((FixIt) -> Void)?
  /// The explaining fix-it whose text is shown, if any.
  var shownExplanation: FixIt?

  /// The line and the fix-it.
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        if state == .opening {
          ProgressView()
            .controlSize(.mini)
        }
        if state.isProblem {
          IssueText(text: state.message)
        } else {
          NoteText(text: state.message)
        }
      }
      if let fixIt = state.fixIt {
        if let perform {
          FixItView(fixIt: fixIt, shownExplanation: shownExplanation, perform: perform)
        } else if let explanation = fixIt.explanation {
          NoteText(text: explanation)
        }
      }
    } // End of VStack holding the line
  } // End of var body
}
