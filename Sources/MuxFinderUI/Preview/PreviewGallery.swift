import MuxFinderCore
import SwiftUI

/// The `--preview-fixtures` window's content (PLAN.md D22): every popover state from
/// `PreviewFixtures.all`, side by side, each in a frame like the menu bar popover. Nothing
/// here runs an engine, reads `hosts.json` or contacts iTerm2.
public struct PreviewGallery: View {
  /// One state and the model that renders it.
  struct Entry: Identifiable {
    /// The fixture.
    let fixture: PreviewFixture
    /// Its model.
    let model: AppModel

    /// `Identifiable` conformance: the fixture's id.
    var id: String { fixture.id }
  }

  /// How many states each row holds.
  public static let columns = 5

  /// The states, each with its own model (made once).
  @State private var entries: [Entry]

  /// A gallery of every fixture.
  public init() {
    _entries = State(
      initialValue: PreviewFixtures.all.map { Entry(fixture: $0, model: AppModel(fixture: $0)) })
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

  /// One state: its title above a popover-like frame.
  private func card(_ entry: Entry) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(entry.fixture.title)
        .font(.headline)
      PopoverView(model: entry.model, isLive: false)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
  } // End of func card(_:)
}

#Preview("Hosts and sessions") {
  PopoverView(model: AppModel(fixture: PreviewFixtures.overview), isLive: false)
}

#Preview("Progress and errors") {
  PopoverView(model: AppModel(fixture: PreviewFixtures.progress), isLive: false)
}

#Preview("Host problems") {
  PopoverView(model: AppModel(fixture: PreviewFixtures.hostProblems), isLive: false)
}

#Preview("Checking and empty hosts") {
  PopoverView(model: AppModel(fixture: PreviewFixtures.checkingAndEmpty), isLive: false)
}

#Preview("Search") {
  PopoverView(model: AppModel(fixture: PreviewFixtures.search), isLive: false)
}

#Preview("No hosts turned on") {
  PopoverView(model: AppModel(fixture: PreviewFixtures.noHosts), isLive: false)
}

#Preview("Every state") {
  PreviewGallery()
}
