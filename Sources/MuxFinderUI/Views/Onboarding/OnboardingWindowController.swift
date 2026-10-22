import AppKit
import SwiftUI

/// The onboarding window (PLAN.md D24): one window, shown by the app at launch while the host
/// list is `notSavedYet`. `show(_:)` makes it (once), centers it and brings it to the front,
/// activating muxFinder (an accessory app would otherwise stay behind the active app). The
/// model closes it after a save or "Not now" (`OnboardingModel.closeWindow`); closing it any
/// way tells the model, which cancels ssh tab requests still running and writes nothing. The
/// window is not restored at launch and its frame is not saved. It uses the Settings window's
/// class, so its text fields get the same editing keys and ⌘W.
@MainActor
public final class OnboardingWindowController: NSObject, NSWindowDelegate {
  /// The app's controller.
  public static let shared = OnboardingWindowController()

  /// The window, once made.
  private var window: SettingsWindow?
  /// The model the window shows.
  private var model: OnboardingModel?

  /// Shows the window for `model`, making it if needed, and brings it to the front.
  public func show(_ model: OnboardingModel) {
    let window = self.window ?? makeWindow(for: model)
    if !window.isVisible {
      window.center()
      model.windowDidOpen()
    }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  /// Makes the window over `model`, and lets the model close it.
  private func makeWindow(for model: OnboardingModel) -> SettingsWindow {
    let hosting = NSHostingView(rootView: OnboardingView(model: model))
    let window = SettingsWindow(
      contentRect: NSRect(origin: .zero, size: OnboardingView.defaultSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = OnboardingText.title
    window.contentView = hosting
    window.contentMinSize = OnboardingView.minimumSize
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.tabbingMode = .disallowed
    window.delegate = self
    model.closeWindow = { [weak window] in window?.performClose(nil) }
    self.window = window
    self.model = model
    return window
  } // End of func makeWindow(for:)

  /// The window closed: the model cancels its ssh tab requests; nothing is written.
  public func windowWillClose(_ notification: Notification) {
    model?.windowDidClose()
  }
}
