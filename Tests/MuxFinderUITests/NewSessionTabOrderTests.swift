import AppKit
import SwiftUI
import Testing

@testable import MuxFinderUI

/// New session's Tab order in muxFinder's panels (PLAN.md D30, D31, Phase I-6): the panel
/// recalculates its key view loop, so after the form replaces the list, Tab from Name reaches
/// Directory and ⇧Tab comes back, as the key binding's own action messages
/// (`insertTab(_:)`, `insertBacktab(_:)`) move them; no event is made. The panels are real
/// (`PanelHost`) but never shown: no window appears and nothing takes the key focus. The
/// cases run one after another: two panels editing text at once disturb each other's focus.
@Suite("New session tab order", .serialized)
@MainActor
struct NewSessionTabOrderTests {
  /// A panel showing `kind`'s list (its fixture's form taken away), laid out, its key view
  /// loop computed as AppKit does when a panel is first shown (the window asked for a key
  /// view); then the form replaces the list as ⌘N makes it. Returns the panel's window, the
  /// model and the panel's host.
  static func panelWithForm(
    _ kind: AppLaunchOptions.KeyViewLoopPanel
  ) async -> (window: NSWindow, model: AppModel, host: any PopoverPanelSurface) {
    _ = NSApplication.shared
    let model: AppModel
    let window: NSWindow
    let host: any PopoverPanelSurface
    switch kind {
    case .popover:
      model = AppModel(fixture: AttachFixtures.newSession)
      model.panel = nil
      let panelHost = PopoverPanelHost(model: model)
      (window, host) = (panelHost.panel, panelHost)
    case .switcher:
      model = AppModel(fixture: SwitcherFixtures.form)
      model.panel = nil
      let panelHost = PanelHost<SwitcherPanelRoot>(level: .floating) { onSizeChange in
        SwitcherPanelRoot(model: model, onSizeChange: onSizeChange)
      }
      (window, host) = (panelHost.panel, panelHost)
    }
    await settle(window, host)
    window.selectNextKeyView(nil)
    model.panel = .newSession
    await settle(window, host)
    return (window, model, host)
  } // End of static func panelWithForm(_:)

  /// Gives SwiftUI a moment of the main loop to apply the model's change, then lays the panel
  /// out at its content's size (never shown).
  static func settle(_ window: NSWindow, _ host: any PopoverPanelSurface) async {
    try? await Task.sleep(for: .milliseconds(50))
    let size = host.contentSize
    window.setFrame(CGRect(origin: .zero, size: size), display: false)
    window.contentView?.layoutSubtreeIfNeeded()
  }

  /// The panel's text field with placeholder `prompt`.
  static func field(_ prompt: String, in window: NSWindow) throws -> NSTextField {
    try #require(
      KeyViewLoopReport.subviews(of: window.contentView).lazy.compactMap { $0 as? NSTextField }
        .first { $0.placeholderString == prompt })
  }

  /// The text field being edited, if any (the first responder's field editor's).
  static func editedField(in window: NSWindow) -> NSTextField? {
    guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
      return window.firstResponder as? NSTextField
    }
    return editor.delegate as? NSTextField
  }

  /// Sends the action message a Tab (`forward`) or ⇧Tab sends to the field editor, and lets
  /// the focus settle.
  static func tab(in window: NSWindow, forward: Bool) async {
    let editor = window.firstResponder as? NSTextView
    editor?.doCommand(
      by: forward ? #selector(NSResponder.insertTab(_:)) : #selector(NSResponder.insertBacktab(_:)))
    try? await Task.sleep(for: .milliseconds(50))
  }

  /// Tab and ⇧Tab (with or without other modifiers) are no panel key, so the panels' key
  /// monitor never takes them: they reach the focused view, and an input method composing
  /// text (marked text) gets them first through AppKit's own text input.
  @Test("Tab and ⇧Tab are left to the focused view")
  func tabIsNoPanelKey() {
    let tab: UInt16 = 48
    for flags: NSEvent.ModifierFlags in [[], .shift, .option, .control, [.option, .shift]] {
      let characters = flags.contains(.shift) ? "\u{19}" : "\t"
      #expect(
        PopoverKey(keyCode: tab, modifierFlags: flags, charactersIgnoringModifiers: characters)
          == nil)
    }
  } // End of func tabIsNoPanelKey()

  /// `--preview-key-view-loop popover|switcher` only with `--preview-fixtures`; another panel
  /// name or no name is a usage error, and the flag never leaves normal mode on.
  @Test("The key view loop diagnostic's flag")
  func keyViewLoopFlag() {
    let popover = AppLaunchOptions(arguments: [
      "--preview-fixtures", "--preview-key-view-loop", "popover",
    ])
    #expect(popover.previewKeyViewLoop == .popover)
    #expect(popover.usageError == nil)
    #expect(!popover.isNormalMode)
    let switcher = AppLaunchOptions(arguments: [
      "--preview-key-view-loop=Switcher", "--preview-fixtures",
    ])
    #expect(switcher.previewKeyViewLoop == .switcher)
    #expect(switcher.usageError == nil)
    #expect(AppLaunchOptions(arguments: ["--preview-fixtures"]).previewKeyViewLoop == nil)
    let unknown = AppLaunchOptions(arguments: [
      "--preview-fixtures", "--preview-key-view-loop", "settings",
    ])
    #expect(unknown.usageError == AppLaunchOptions.keyViewLoopPanelError)
    let missing = AppLaunchOptions(arguments: ["--preview-fixtures", "--preview-key-view-loop"])
    #expect(missing.usageError == AppLaunchOptions.keyViewLoopPanelError)
    let alone = AppLaunchOptions(arguments: ["--preview-key-view-loop", "popover"])
    #expect(alone.usageError == "--preview-key-view-loop needs --preview-fixtures.")
    #expect(!alone.isNormalMode)
    #expect(AppLaunchOptions.usage.contains(AppLaunchOptions.keyViewLoopUsage))
  } // End of func keyViewLoopFlag()

  /// The panel's key view loop setting, for both panels' window class.
  @Test("The panels recalculate their key view loop")
  func panelsRecalculateTheirKeyViewLoop() {
    #expect(PopoverPanelWindow(contentView: NSView()).autorecalculatesKeyViewLoop)
    #expect(
      PopoverPanelWindow(contentView: NSView(), level: .floating).autorecalculatesKeyViewLoop)
  }

  /// In both panels, after the form replaced the list: Tab from Name edits Directory, and
  /// ⇧Tab from Directory edits Name again.
  @Test(
    "Tab moves from Name to Directory and back",
    arguments: AppLaunchOptions.KeyViewLoopPanel.allCases)
  func tabMovesFromNameToDirectoryAndBack(
    _ kind: AppLaunchOptions.KeyViewLoopPanel
  ) async throws {
    let (window, _, host) = await Self.panelWithForm(kind)
    defer { host.hide() }
    let name = try Self.field(NewSessionPanelView.namePrompt, in: window)
    let directory = try Self.field(DirectoryFieldView.prompt, in: window)
    #expect(window.makeFirstResponder(name))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(Self.editedField(in: window) === name)
    await Self.tab(in: window, forward: true)
    #expect(Self.editedField(in: window) === directory)
    await Self.tab(in: window, forward: false)
    #expect(Self.editedField(in: window) === name)
  } // End of func tabMovesFromNameToDirectoryAndBack(_:)
}
