import MuxFinderCore
import SwiftUI

/// The `--preview-fixtures --preview-gallery settings` window's content (PLAN.md D23): every
/// Settings state from `SettingsFixtures.all`, each in a frame like the Settings window.
/// Nothing here reads `hosts.json`, runs a probe, contacts iTerm2 or reads a login item.
public struct SettingsGallery: View {
  /// One state and the model that renders it.
  struct Entry: Identifiable {
    /// The fixture.
    let fixture: SettingsFixture
    /// Its model.
    let model: SettingsModel

    /// `Identifiable` conformance: the fixture's id.
    var id: String { fixture.id }
  }

  /// How many states each row holds.
  public static let columns = 3
  /// The height of a General tab's frame, which needs less room than the others.
  static let generalHeight: CGFloat = 330

  /// The states, each with its own model (made once).
  @State private var entries: [Entry]

  /// A gallery of every Settings fixture.
  public init() {
    _entries = State(
      initialValue: SettingsFixtures.all.map {
        Entry(fixture: $0, model: SettingsModel(fixture: $0))
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

  /// One state: its title above a window-like frame.
  private func card(_ entry: Entry) -> some View {
    let size = SettingsView.defaultSize
    let height = entry.fixture.tab == .general ? Self.generalHeight : size.height
    return VStack(alignment: .leading, spacing: 8) {
      Text(entry.fixture.title)
        .font(.headline)
      SettingsView(model: entry.model)
        .frame(width: size.width, height: height)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
  } // End of func card(_:)
}

#Preview("Settings: hosts") {
  SettingsView(model: SettingsModel(fixture: SettingsFixtures.hosts))
    .frame(width: SettingsView.defaultSize.width, height: SettingsView.defaultSize.height)
}

#Preview("Settings: validation errors") {
  SettingsView(model: SettingsModel(fixture: SettingsFixtures.validation))
    .frame(width: SettingsView.defaultSize.width, height: SettingsView.defaultSize.height)
}

#Preview("Settings: launch at login needs approval") {
  SettingsView(model: SettingsModel(fixture: SettingsFixtures.loginRequiresApproval))
    .frame(width: SettingsView.defaultSize.width, height: 330)
}

#Preview("Settings: diagnostics") {
  SettingsView(model: SettingsModel(fixture: SettingsFixtures.diagnostics))
    .frame(width: SettingsView.defaultSize.width, height: SettingsView.defaultSize.height)
}
