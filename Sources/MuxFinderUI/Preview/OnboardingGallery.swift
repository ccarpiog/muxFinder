import MuxFinderCore
import SwiftUI

/// The `--preview-fixtures --preview-gallery onboarding` window's content (PLAN.md D24): every
/// onboarding state from `OnboardingFixtures.all`, each in a frame like the onboarding window,
/// at its full height. Nothing here reads `hosts.json`, opens a tab or contacts iTerm2.
public struct OnboardingGallery: View {
  /// One state and the model that renders it.
  struct Entry: Identifiable {
    /// The fixture.
    let fixture: OnboardingFixture
    /// Its model.
    let model: OnboardingModel

    /// `Identifiable` conformance: the fixture's id.
    var id: String { fixture.id }
  }

  /// How many states each row holds.
  public static let columns = 4

  /// The states, each with its own model (made once).
  @State private var entries: [Entry]

  /// A gallery of every onboarding fixture.
  public init() {
    _entries = State(
      initialValue: OnboardingFixtures.all.map {
        Entry(fixture: $0, model: OnboardingModel(fixture: $0))
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

  /// One state: its title above a window-like frame showing the whole content.
  private func card(_ entry: Entry) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(entry.fixture.title)
        .font(.headline)
      OnboardingView(model: entry.model, scrolls: false)
        .frame(width: OnboardingView.defaultSize.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
  } // End of func card(_:)
}

#Preview("Onboarding: examples") {
  OnboardingView(model: OnboardingModel(fixture: OnboardingFixtures.examplesShown))
    .frame(width: OnboardingView.defaultSize.width, height: OnboardingView.defaultSize.height)
}

#Preview("Onboarding: filled in") {
  OnboardingView(model: OnboardingModel(fixture: OnboardingFixtures.filledIn))
    .frame(width: OnboardingView.defaultSize.width, height: OnboardingView.defaultSize.height)
}

#Preview("Onboarding: every state") {
  OnboardingGallery()
}
