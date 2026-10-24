import MuxFinderCore
import SwiftUI

/// The `--preview-fixtures --preview-gallery switcher` window's content (PLAN.md D32): every
/// session switcher state from `SwitcherFixtures.all`, each framed like the real switcher
/// panel (rounded, with a shadow; the switcher paints its own opaque background). Nothing here
/// runs an engine, reads `hosts.json`, `directories.json` or `preferences.json`, registers a
/// hotkey or contacts iTerm2.
public struct SwitcherGallery: View {
  /// How many cards each row holds.
  public static let columns = 3

  /// The states, each with its own model (made once).
  @State private var entries: [PreviewGallery.Entry]

  /// A gallery of every switcher fixture.
  public init() {
    _entries = State(
      initialValue: SwitcherFixtures.all.map {
        PreviewGallery.Entry(fixture: $0, model: AppModel(fixture: $0))
      })
  }

  /// The grid of states.
  public var body: some View {
    let rows = stride(from: 0, to: entries.count, by: Self.columns).map {
      Array(entries[$0..<min($0 + Self.columns, entries.count)])
    }
    Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 28) {
      ForEach(rows.indices, id: \.self) { index in
        GridRow(alignment: .top) {
          ForEach(rows[index]) { entry in
            card(entry)
          }
        }
      }
    } // End of Grid holding the states
    .padding(28)
    .background(Color(nsColor: .underPageBackgroundColor))
  } // End of var body

  /// One state: its title above a switcher-like frame.
  private func card(_ entry: PreviewGallery.Entry) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(entry.fixture.title)
        .font(.headline)
      SwitcherView(model: entry.model, isLive: false)
        .clipShape(RoundedRectangle(cornerRadius: PopoverPanelContentView.cornerRadius))
        .overlay(
          RoundedRectangle(cornerRadius: PopoverPanelContentView.cornerRadius)
            .strokeBorder(.separator)
        )
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
  } // End of func card(_:)
}

#Preview("Session switcher") {
  SwitcherView(model: AppModel(fixture: SwitcherFixtures.list), isLive: false)
}

#Preview("Every switcher state") {
  SwitcherGallery()
}
