import AppKit
import MuxFinderCore
import SwiftUI

/// The muxFinder menu bar app. Placeholder: a menu bar item with an empty popover; hosts and
/// sessions arrive in later phases.
@main
struct MuxFinderMenuBarApp: App {
  /// The menu bar extra and its popover window.
  var body: some Scene {
    MenuBarExtra("muxFinder", systemImage: "terminal") {
      PlaceholderPopover()
    }
    .menuBarExtraStyle(.window)
  }
}

/// Popover content until the real session list exists.
struct PlaceholderPopover: View {
  /// A short note and a quit button.
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("muxFinder")
        .font(.headline)
      Text("No hosts configured yet.")
        .foregroundStyle(.secondary)
      Button("Quit muxFinder") {
        NSApplication.shared.terminate(nil)
      }
    }
    .padding()
    .frame(width: 260, alignment: .leading)
  } // End of var body
}
