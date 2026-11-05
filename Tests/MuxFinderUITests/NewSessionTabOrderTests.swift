import AppKit
import SwiftUI
import Testing

@testable import MuxFinderUI

/// New session's Tab order in the New session window (PLAN.md D34, D30, D31, Phase I-6): the
/// window recalculates its key view loop, so after views come (the directory list opening),
/// Tab from Name reaches Directory and ⇧Tab comes back, as the key binding's own action
/// messages (`insertTab(_:)`, `insertBacktab(_:)`) move them; no event is made. The window is
/// real (`NewSessionWindowHost`) but never shown: no window appears and nothing takes the key
/// focus. The cases run one after another: two windows editing text at once disturb each
/// other's focus.
@Suite("New session tab order", .serialized)
@MainActor
struct NewSessionTabOrderTests {
  /// The New session window over `kind`'s entry point fixture, laid out, its key view loop
  /// computed as AppKit does when a window is first shown (the window asked for a key view);
  /// then the directory list opens, so views come and the loop must be recalculated. Returns
  /// the window, the model and the window's host.
  static func windowWithForm(
    _ kind: AppLaunchOptions.KeyViewLoopPanel
  ) async -> (window: NSWindow, model: AppModel, host: NewSessionWindowHost) {
    _ = NSApplication.shared
    let model: AppModel
    switch kind {
    case .popover: model = AppModel(fixture: AttachFixtures.newSession)
    case .switcher: model = AppModel(fixture: SwitcherFixtures.form)
    }
    let host = NewSessionWindowHost(model: model)
    await settle(host)
    host.panel.selectNextKeyView(nil)
    model.openDirectoryList(highlightingFirst: false)
    await settle(host)
    return (host.panel, model, host)
  } // End of static func windowWithForm(_:)

  /// Gives SwiftUI a moment of the main loop to apply the model's change, then lays the window
  /// out at its content's size (never shown).
  static func settle(_ host: NewSessionWindowHost) async {
    try? await Task.sleep(for: .milliseconds(50))
    host.panel.setFrame(CGRect(origin: .zero, size: host.fittingFrameSize), display: false)
    host.panel.contentView?.layoutSubtreeIfNeeded()
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

  /// Tab and ⇧Tab (with or without other modifiers) are no panel key, so the key monitor (the
  /// panels' and the New session window's) never takes them: they reach the focused view, and
  /// an input method composing text (marked text) gets them first through AppKit's own text
  /// input.
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

  /// The key view loop setting of the panels' window class and the New session window's.
  @Test("The panels and the New session window recalculate their key view loop")
  func panelsRecalculateTheirKeyViewLoop() {
    #expect(PopoverPanelWindow(contentView: NSView()).autorecalculatesKeyViewLoop)
    #expect(
      PopoverPanelWindow(contentView: NSView(), level: .floating).autorecalculatesKeyViewLoop)
    #expect(NewSessionPanel(contentView: NSView()).autorecalculatesKeyViewLoop)
  }

  /// In the New session window over both entry points' fixtures, after the directory list
  /// opened: Tab from Name edits Directory, and ⇧Tab from Directory edits Name again.
  @Test(
    "Tab moves from Name to Directory and back",
    arguments: AppLaunchOptions.KeyViewLoopPanel.allCases)
  func tabMovesFromNameToDirectoryAndBack(
    _ kind: AppLaunchOptions.KeyViewLoopPanel
  ) async throws {
    let (window, model, host) = await Self.windowWithForm(kind)
    defer { host.hide() }
    #expect(model.directoryPicker.isOpen)
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
