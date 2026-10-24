import AppKit
import MuxFinderCore
import SwiftUI

/// The General tab's "Session switcher" section (PLAN.md D32): "Show session switcher" with the
/// recorder and "Clear", the warning before ⌘ with one key, what went wrong beside it (a
/// refusal, a taken shortcut, a failed save; never an alert), an unusable preferences file's
/// notice with "Try again", and how to use it.
struct SessionSwitcherSettingsSection: View {
  /// The shortcut's model.
  let model: GlobalShortcutModel

  /// The section.
  var body: some View {
    SettingsSection(title: "Session switcher") {
      HStack(alignment: .center, spacing: 10) {
        Text("Show session switcher")
        ShortcutRecorderView(model: model)
        Button("Clear") { model.clear() }
          .disabled(!model.isEditable || (model.shortcut == nil && !model.isRecording))
      }
      if let warning = model.warning {
        VStack(alignment: .leading, spacing: 6) {
          MessageLine(text: warning, systemImage: "exclamationmark.triangle.fill", tint: .orange)
          HStack(spacing: 8) {
            Button("Use it anyway") { model.confirmWarning() }
            Button("Choose another") { model.chooseAnother() }
          }
          .controlSize(.small)
        }
      }
      if let issue = model.issue {
        IssueText(text: issue)
      }
      if let notice = model.fileNotice {
        MessageLine(
          text: notice, systemImage: "exclamationmark.triangle.fill", tint: .orange,
          actionTitle: model.canRetryLoading ? "Try again" : nil,
          action: { Task { await model.retryLoading() } })
      }
      NoteText(
        text: "Click the shortcut field, then press the keys, such as ⌃⌥Space. Esc cancels and "
          + "Delete clears. The shortcut works in every app; for now it opens muxFinder's menu "
          + "bar popover.")
    } // End of SettingsSection "Session switcher"
  } // End of var body
}

/// The hand-written shortcut recorder (PLAN.md D32; no package): a field-like button that shows
/// the shortcut, or "Record shortcut" without one. Clicking it listens for the next key
/// combination ("Type the shortcut"), which goes to the model through a local key monitor
/// installed only while it listens; clicking it again cancels, and so does the recorder going
/// away (another Settings tab, which `SettingsModel.selectedTab` cancels too, or the window
/// closing), so the monitor never outlives it and the saved hotkey is never left suspended.
struct ShortcutRecorderView: View {
  /// The shortcut's model.
  let model: GlobalShortcutModel

  /// The field and its key monitor.
  var body: some View {
    Button {
      if model.isRecording { model.cancelRecording() } else { model.startRecording() }
    } label: {
      Text(title)
        .foregroundStyle(model.isRecording || model.shortcut == nil ? .secondary : .primary)
        .frame(minWidth: 150)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
    .buttonStyle(RecorderButtonStyle(isRecording: model.isRecording))
    .disabled(!model.isEditable)
    .background(
      ShortcutKeyMonitor(isActive: model.isRecording) { keyCode, modifiers in
        model.handleRecorderKey(keyCode: keyCode, modifiers: modifiers)
      }
    )
    .onDisappear { model.cancelRecording() }
    .accessibilityLabel("Session switcher shortcut")
    .accessibilityValue(accessibilityValue)
    .accessibilityHint(
      model.isRecording
        ? "Press the keys of the shortcut. Escape cancels, Delete clears."
        : "Press to record a shortcut.")
  } // End of var body

  /// The field's text.
  private var title: String {
    if model.isRecording { return "Type the shortcut" }
    return model.label?.text ?? "Record shortcut"
  }

  /// What VoiceOver reads as the value.
  private var accessibilityValue: String {
    if model.isRecording { return "Recording" }
    return model.label?.spokenText ?? "None"
  }
}

/// The recorder's look: a rounded field with the separator's border, the accent color's while
/// it listens.
struct RecorderButtonStyle: ButtonStyle {
  /// Whether the recorder listens.
  let isRecording: Bool

  /// The field.
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.monospacedDigit())
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(Color(nsColor: .textBackgroundColor).opacity(configuration.isPressed ? 0.7 : 1))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(
            isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
            lineWidth: isRecording ? 2 : 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: 6))
  } // End of func makeBody(configuration:)
}

/// Catches key presses for the recorder while it listens: a local key-down monitor on the
/// window holding it (keys of other windows pass), installed only while `isActive` and removed
/// with the view. A key the handler takes goes nowhere else; repeats are swallowed.
struct ShortcutKeyMonitor: NSViewRepresentable {
  /// Whether to listen.
  let isActive: Bool
  /// Takes a key: its key code and modifiers; returns whether it was taken.
  let onKey: @MainActor (UInt16, GlobalShortcut.Modifiers) -> Bool

  /// The monitor's view.
  func makeNSView(context: Context) -> ShortcutKeyMonitorView {
    ShortcutKeyMonitorView()
  }

  /// Installs or removes the monitor.
  func updateNSView(_ view: ShortcutKeyMonitorView, context: Context) {
    view.onKey = onKey
    view.setActive(isActive)
  }

  /// Removes the monitor with the view.
  static func dismantleNSView(_ view: ShortcutKeyMonitorView, coordinator: ()) {
    view.setActive(false)
  }
}

/// The view `ShortcutKeyMonitor` installs its monitor for.
final class ShortcutKeyMonitorView: NSView {
  /// Takes a key.
  var onKey: (@MainActor (UInt16, GlobalShortcut.Modifiers) -> Bool)?
  /// The installed monitor, while listening.
  private var monitor: Any?

  /// Installs the monitor (`true`) or removes it (`false`).
  func setActive(_ isActive: Bool) {
    if isActive, monitor == nil {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, event.window === self.window else { return event }
        if event.isARepeat { return nil }
        let taken = self.onKey?(
          event.keyCode, GlobalShortcut.Modifiers(eventFlags: event.modifierFlags))
        return taken == true ? nil : event
      }
    } else if !isActive, let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
  } // End of func setActive(_:)
}
