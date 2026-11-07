import MuxFinderCore
import SwiftUI

/// "Move “name” here?", the panel the popover shows in place of its host list (PLAN.md D25):
/// what moving does (every other client is disconnected, including other Macs; the session
/// keeps running), "Cancel" and "Move here". Only "Move here" reaches the core's move. Drawn
/// inside the popover, so it stays in the menu bar window and renders in the preview fixtures.
struct MoveHerePanelView: View {
  /// The session.
  let request: MoveHereRequest
  /// The model the buttons talk to.
  let model: AppModel

  /// The dialog.
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label {
        Text(request.title)
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
          .foregroundStyle(.orange)
      }
      Text(request.explanation(in: model.terminalWording))
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      Text(request.clientsText)
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel") { model.cancelPanel() }
          .keyboardShortcut(.cancelAction)
        Button(MoveHereRequest.confirmTitle) { model.confirmMoveHere() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(.top, 4)
    } // End of VStack holding the dialog
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(request.title)
  } // End of var body
}

/// "Detach other clients of “name”?", the panel the popover shows in place of its host list
/// (PLAN.md D25, D37): that tmux detaches every other client of the session and keeps this
/// Mac's attachment, that they may be iTerm2 on other Macs, that nothing is closed and the
/// session keeps running, how many there were when it opened (and how many of them are in this
/// Mac's iTerm2), and why someone may want it (the window size). "Cancel" and "Detach other
/// clients"; only the latter reaches the core's call. Drawn inside the popover, as Move here's.
struct DetachOtherClientsPanelView: View {
  /// The session and the counts.
  let request: DetachOtherClientsRequest
  /// The model the buttons talk to.
  let model: AppModel

  /// The dialog.
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label {
        Text(request.title)
          .font(.headline)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "person.2.slash")
          .foregroundStyle(.orange)
      }
      Text(request.explanation(in: model.terminalWording))
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      Text(DetachOtherClientsRequest.windowSizeText)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      Text(request.clientsText(in: model.terminalWording))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel") { model.cancelPanel() }
          .keyboardShortcut(.cancelAction)
          .accessibilityHint("Closes this question. Nothing is detached.")
        Button(DetachOtherClientsRequest.confirmTitle) { model.confirmDetachOtherClients() }
          .keyboardShortcut(.defaultAction)
          .accessibilityHint("Detaches the session's other clients and keeps this Mac's.")
      }
      .padding(.top, 4)
    } // End of VStack holding the dialog
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(request.title)
  } // End of var body
}

/// The New session form, the content of the New session window (PLAN.md D34, whose title says
/// "New session"): the host (enabled hosts), the name with its inline issue, the optional
/// directory with its directory list (`DirectoryFieldView`, PLAN.md D31), the creation's state
/// (a collision offers "Open existing"), "Cancel" (`AppModel.closeNewSession()`) and "Create".
/// The live window asks for the name field to take the focus at each fresh opening
/// (`AppModel.newSessionFocusRequests`). Tab and ⇧Tab move between Name and Directory (with
/// macOS's keyboard navigation on, through the host picker, the directory list button, Cancel
/// and Create too) by AppKit's own key view loop, which the window recalculates
/// (`NewSessionPanel`, PLAN.md Phase I-6). The host picker is AppKit's pop-up button: focused,
/// it gets Space, ↑, ↓ and ⌥↓ as AppKit handles them, and its open menu every key (the
/// window's key monitor leaves them, `PanelKeyRoute`, PLAN.md Phase I-8); a host picked by
/// keyboard, click or VoiceOver comes through the same binding.
struct NewSessionPanelView: View {
  /// The Name field's placeholder.
  static let namePrompt = "work"

  /// The model whose draft the fields edit.
  @Bindable var model: AppModel
  /// Whether the name field takes the keyboard focus when the form appears and at each fresh
  /// opening (the live window).
  var focusesName = false
  /// Whether the name field has the keyboard focus.
  @FocusState private var isNameFocused: Bool

  /// The form.
  var body: some View {
    let draft = model.newSessionDraft
    VStack(alignment: .leading, spacing: 10) {
      Picker("Host", selection: $model.newSessionDraft.hostID) {
        ForEach(model.newSessionHosts) { host in
          Text(host.displayName).tag(Optional(host.id))
        }
      }
      .disabled(draft.isBusy)
      field(
        "Name", text: $model.newSessionDraft.name, prompt: Self.namePrompt,
        issue: draft.nameIssue)
      DirectoryFieldView(model: model)
      if let message = draft.stateMessage(in: model.terminalWording) {
        stateLine(message, state: draft.state)
      }
      HStack {
        Spacer()
        Button("Cancel") { model.closeNewSession() }
          .keyboardShortcut(.cancelAction)
        Button("Create") { model.createSession() }
          .keyboardShortcut(.defaultAction)
          .disabled(draft.isBusy || model.newSessionHosts.isEmpty)
      }
      .padding(.top, 2)
    } // End of VStack holding the form
    // No edits while an update installs (PLAN.md D39); the model refuses them too.
    .disabled(model.isInstallingUpdate)
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .task {
      if focusesName { isNameFocused = true }
    }
    .onChange(of: model.newSessionFocusRequests) {
      if focusesName { isNameFocused = true }
    }
  } // End of var body

  /// A labelled text field with its issue under it, in red.
  private func field(
    _ title: String,
    text: Binding<String>,
    prompt: String,
    issue: String?
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      TextField(title, text: text, prompt: Text(prompt))
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .disabled(model.newSessionDraft.isBusy)
        .focused($isNameFocused)
        .accessibilityLabel(title)
      if let issue {
        Text(issue)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    } // End of VStack holding the field
  } // End of func field(_:text:prompt:issue:)

  /// The creation's progress, failure or collision (with "Open existing").
  @ViewBuilder
  private func stateLine(_ message: String, state: NewSessionDraft.State) -> some View {
    switch state {
    case .creating, .findingExisting:
      HStack(spacing: 6) {
        ProgressView()
          .progressViewStyle(.circular)
          .controlSize(.mini)
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    case .collision:
      MessageLine(
        text: message, systemImage: "exclamationmark.triangle.fill", tint: .orange,
        actionTitle: "Open existing"
      ) {
        model.openExisting()
      }
    case .failed, .editing:
      MessageLine(text: message, systemImage: "xmark.octagon.fill", tint: .red)
    }
  } // End of func stateLine(_:state:)
}

/// Banners above the host list for sessions that vanished or changed between the listing and
/// an action, each with a close button.
struct BannersView: View {
  /// The banners, newest first.
  let banners: [SessionBanner]
  /// The model that dismisses them.
  let model: AppModel

  /// One line per banner on a faint band.
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(banners) { banner in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(
            systemName: banner.kind == .vanished
              ? "questionmark.circle.fill" : "arrow.triangle.2.circlepath"
          )
          .imageScale(.small)
          .foregroundStyle(.blue)
          .accessibilityHidden(true)
          Text(banner.text)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 4)
          Button {
            model.dismissBanner(banner.id)
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .accessibilityLabel("Dismiss")
        } // End of HStack holding one banner
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.blue.opacity(0.08))
  } // End of var body
}
