import AppKit
import Foundation
import MuxFinderUI
import SwiftUI

/// `--preview-fixtures` mode (PLAN.md D22, D23, D24, D25, D32): a plain `NSApplication` with
/// one normal window showing every popover state, or with `--preview-gallery settings` every
/// Settings window state, with `--preview-gallery onboarding` every onboarding window state,
/// with `--preview-gallery attach` every session-action state, or with `--preview-gallery
/// switcher` every session switcher state, from synthetic fixtures. No SwiftUI scene, menu bar
/// item, switcher panel, refresh engine, host list, login item, hotkey or iTerm2 is involved,
/// and nothing is written except the PNG a `--preview-snapshot` asks for. With
/// `--preview-key-view-loop popover|switcher` there is no gallery window: muxFinder's real New
/// session window (PLAN.md D34) shows the form over that entry point's fixture while
/// `KeyViewLoopReport` prints its key view loop, then the app quits (PLAN.md Phase I-6).
///
/// The window is shown without activating the app (the keyboard focus stays where it was),
/// its window number is printed on standard output for `screencapture -l`, and closing it,
/// SIGTERM or SIGINT quits with status 0.
@MainActor
final class PreviewAppDelegate: NSObject, NSApplicationDelegate {
  /// How long the window settles (layout, measured list heights) before a snapshot.
  static let snapshotDelay: Duration = .milliseconds(1_500)
  /// How long the window settles again after `fitWindow(to:)` resized it.
  static let refitDelay: Duration = .milliseconds(500)

  /// The command-line options.
  private let options: AppLaunchOptions
  /// The SIGTERM and SIGINT sources.
  private var signalSources: [any DispatchSourceSignal] = []
  /// The preview window, kept alive.
  private var window: NSWindow?
  /// The key view loop diagnostic's watchdog, kept alive while it runs.
  private var watchdog: (any DispatchSourceTimer)?

  /// A delegate for `options`.
  private init(options: AppLaunchOptions) {
    self.options = options
    super.init()
  }

  /// Runs the preview app; never returns (the process exits when it quits).
  static func run(options: AppLaunchOptions) {
    let app = NSApplication.shared
    let delegate = PreviewAppDelegate(options: options)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
  }

  /// Shows the window, and takes the snapshot if asked; with `--preview-key-view-loop` runs
  /// that diagnostic instead (no gallery window).
  func applicationDidFinishLaunching(_ notification: Notification) {
    signalSources = QuitSignals.install()
    QuitSignals.applyAppearance(options.appearance)
    if let panel = options.previewKeyViewLoop {
      reportKeyViewLoop(of: panel)
      return
    }
    let hosting: NSView
    switch options.previewGallery {
    case .popover: hosting = NSHostingView(rootView: PreviewGallery())
    case .settings: hosting = NSHostingView(rootView: SettingsGallery())
    case .onboarding: hosting = NSHostingView(rootView: OnboardingGallery())
    case .attach: hosting = NSHostingView(rootView: AttachGallery())
    case .switcher: hosting = NSHostingView(rootView: SwitcherGallery())
    }
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false)
    window.title = "muxFinder preview fixtures (\(options.previewGallery.rawValue))"
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.contentView = hosting
    window.center()
    window.orderFrontRegardless()
    self.window = window
    let appearance = options.appearance?.rawValue ?? "system"
    print("muxFinder preview window \(window.windowNumber) appearance \(appearance)")
    if let path = options.previewSnapshotPath {
      Task {
        try? await Task.sleep(for: Self.snapshotDelay)
        if fitWindow(to: hosting) { try? await Task.sleep(for: Self.refitDelay) }
        writeSnapshot(of: hosting, to: path)
      }
    }
  } // End of func applicationDidFinishLaunching(_:)

  /// Closing the gallery window quits. The key view loop diagnostic quits by itself: the text
  /// cursor's indicator window (`TUINSWindow`) closes while its window's fields are edited.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    options.previewKeyViewLoop == nil
  }

  /// `--preview-key-view-loop`: prints the New session form's key view loop in the real New
  /// session window over `panel`'s entry point fixture (`KeyViewLoopReport`), then quits:
  /// status 0 with the form's fields found, 1 without, 3 when the watchdog ends it first. Lines
  /// go through `keyViewLoopOutput`, so a reader that stops reading never holds the main actor
  /// while the window is key (lines that do not fit are dropped), and a watchdog off the main
  /// thread ends the process `keyViewLoopDeadline` seconds after the start whatever the main
  /// thread is doing, the window going with it.
  private func reportKeyViewLoop(of panel: AppLaunchOptions.KeyViewLoopPanel) {
    watchdog = PopoverPlacementReport.makeWatchdog(
      after: Self.keyViewLoopDeadline, exitCode: Self.keyViewLoopWatchdogStatus)
    let output = Self.keyViewLoopOutput
    Task {
      let found = await KeyViewLoopReport.run(panel) { line in _ = output.write(line) }
      _ = output.flush(timeout: Self.keyViewLoopFlushWait)
      if found { AppTermination.request() } else { exit(1) }
    }
  }

  /// The key view loop diagnostic's standard output, never blocking (`NonblockingLineWriter`).
  private static let keyViewLoopOutput = NonblockingLineWriter(fileDescriptor: STDOUT_FILENO)
  /// How long the key view loop diagnostic may run before its watchdog ends it, in seconds
  /// (its steps take about ten).
  static let keyViewLoopDeadline: TimeInterval = 30
  /// The key view loop diagnostic's exit status when its watchdog ends it.
  static let keyViewLoopWatchdogStatus: Int32 = 3
  /// How long the key view loop diagnostic waits for its last lines to be read before it
  /// quits, in seconds.
  static let keyViewLoopFlushWait: TimeInterval = 0.25

  /// Before a snapshot: gives the window exactly the content's natural size, so the PNG shows
  /// every state at full height whatever the display. Showing a titled window taller than the
  /// screen shrinks it to fit, and a gallery whose host lists can shrink (each popover's list
  /// scrolls when offered less) then renders squeezed and cut off; `setFrame(_:display:)` is
  /// not held to the screen. Returns whether the size changed.
  private func fitWindow(to view: NSView) -> Bool {
    let size = view.fittingSize
    guard let window = view.window, size != view.bounds.size else { return false }
    let content = NSRect(origin: window.frame.origin, size: size)
    window.setFrame(window.frameRect(forContentRect: content), display: true)
    return true
  }

  /// Draws `view` (the window's contents) into a PNG at `path` from inside the app, at the
  /// window's backing scale, then quits: status 0 once written, 1 if it could not be. Unlike
  /// `screencapture -l` it works while the screen is locked or the display sleeps.
  private func writeSnapshot(of view: NSView, to path: String) {
    view.layoutSubtreeIfNeeded()
    let url = URL(fileURLWithPath: path)
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      fail("could not create a bitmap for the preview window")
      return
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
      fail("could not encode the preview window as PNG")
      return
    }
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      fail("could not write \(url.path): \(error.localizedDescription)")
      return
    }
    print("muxFinder preview snapshot \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) \(url.path)")
    AppTermination.request()
  } // End of func writeSnapshot(of:to:)

  /// Prints why the snapshot failed and exits with status 1 (nothing to shut down here).
  private func fail(_ reason: String) {
    FileHandle.standardError.write(Data("muxFinder preview snapshot failed: \(reason)\n".utf8))
    exit(1)
  }

  /// Writes one line to standard output at once (it may be a pipe or a file).
  private func print(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
  }
}
