import MuxFinderCore
import SwiftUI

/// The panel the popover shows in place of its host list (PLAN.md D25): the Move here
/// confirmation or the New session sheet. Drawn inside the popover, so it stays in the menu bar
/// window and renders in the preview fixtures.
struct PanelView: View {
  /// Which panel.
  let panel: PopoverPanel
  /// The model the buttons talk to.
  @Bindable var model: AppModel

  /// The panel's content.
  var body: some View {
    switch panel {
    case .moveHere(let request):
      MoveHerePanelView(request: request, model: model)
    case .newSession:
      NewSessionPanelView(model: model)
    }
  }
}

/// "Move “name” here?": what moving does (every other client is disconnected, including other
/// Macs; the session keeps running), "Cancel" and "Move here". Only "Move here" reaches the
/// core's move.
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
      Text(request.explanation)
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
  } // End of var body
}

/// "New session": the host (enabled hosts), the name with its inline issue, the optional
/// directory with its directory list (`DirectoryFieldView`, PLAN.md D31), the creation's state
/// (a collision offers "Open existing"), "Cancel" and "Create". Shown in the popover and in
/// the session switcher (PLAN.md D32), which asks for the name field to take the focus.
struct NewSessionPanelView: View {
  /// The model whose draft the fields edit.
  @Bindable var model: AppModel
  /// Whether the name field takes the keyboard focus when the form appears (the live session
  /// switcher, which is keyboard-first).
  var focusesName = false
  /// Whether the name field has the keyboard focus.
  @FocusState private var isNameFocused: Bool

  /// The sheet.
  var body: some View {
    let draft = model.newSessionDraft
    VStack(alignment: .leading, spacing: 10) {
      Text("New session")
        .font(.headline)
      Picker("Host", selection: $model.newSessionDraft.hostID) {
        ForEach(model.newSessionHosts) { host in
          Text(host.displayName).tag(Optional(host.id))
        }
      }
      .disabled(draft.isBusy)
      field(
        "Name", text: $model.newSessionDraft.name, prompt: "work", issue: draft.nameIssue)
      DirectoryFieldView(model: model)
      if let message = draft.stateMessage {
        stateLine(message, state: draft.state)
      }
      HStack {
        Spacer()
        Button("Cancel") { model.cancelPanel() }
          .keyboardShortcut(.cancelAction)
        Button("Create") { model.createSession() }
          .keyboardShortcut(.defaultAction)
          .disabled(draft.isBusy || model.newSessionHosts.isEmpty)
      }
      .padding(.top, 2)
    } // End of VStack holding the sheet
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .task {
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
