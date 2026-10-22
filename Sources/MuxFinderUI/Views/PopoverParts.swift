import MuxFinderCore
import SwiftUI

/// The footer: "New session", "Refresh", "Settings", and "Quit" (which leaves every session
/// and iTerm2 tab running).
struct FooterView: View {
  /// The model the buttons talk to.
  let model: AppModel

  /// The buttons.
  var body: some View {
    HStack(spacing: 2) {
      Button {
        model.newSession()
      } label: {
        Label("New session", systemImage: "plus")
      }
      .help("New session (⌘N)")
      Button {
        model.refresh()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .help("Refresh every host now (⌘R)")
      Button {
        model.openSettings()
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
      .help("Settings (⌘,)")
      Spacer(minLength: 4)
      Button("Quit") {
        model.quit()
      }
      .help("Quit muxFinder. Your tmux sessions and iTerm2 tabs keep running.")
    } // End of HStack holding the buttons
    .buttonStyle(.borderless)
    .labelStyle(.titleAndIcon)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  } // End of var body
}

/// What replaces the host list: loading, no host turned on, or no search match.
struct PlaceholderView: View {
  /// Which placeholder.
  let placeholder: PopoverContent.Placeholder
  /// Opens the Settings window.
  let openSettings: () -> Void

  /// An icon or spinner, the title, the explanation and, with no host turned on, a button.
  var body: some View {
    VStack(spacing: 6) {
      if placeholder == .loading {
        ProgressView()
          .progressViewStyle(.circular)
          .controlSize(.small)
      } else {
        Image(systemName: symbol)
          .font(.title2)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      Text(placeholder.title)
        .font(.headline)
      if let message = placeholder.message {
        Text(message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      if placeholder == .noHostsEnabled {
        Button("Open Settings", action: openSettings)
          .padding(.top, 4)
      }
    } // End of VStack holding the placeholder
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
    .padding(.horizontal, 24)
    .accessibilityElement(children: .combine)
  } // End of var body

  /// The placeholder's SF Symbol.
  private var symbol: String {
    switch placeholder {
    case .loading: return "hourglass"
    case .noHostsEnabled: return "desktopcomputer"
    case .noMatches: return "magnifyingglass"
    }
  }
}

/// Problems shown above the host list: an unusable host list, a failed iTerm2 check (with its
/// fix-it when it has one).
struct NoticesView: View {
  /// The notices.
  let notices: [PopoverContent.Notice]
  /// The model that performs a fix-it.
  let model: AppModel

  /// One line per notice on a faint orange band, each fix-it under its line.
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(notices) { notice in
        MessageLine(
          text: notice.text, systemImage: "exclamationmark.triangle.fill", tint: .orange)
        if let fixIt = notice.fixIt {
          FixItView(fixIt: fixIt, shownExplanation: model.shownExplanation, perform: model.perform)
            .padding(.leading, 18)
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.08))
  } // End of var body
}
