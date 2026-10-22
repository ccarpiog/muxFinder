import MuxFinderCore
import SwiftUI

/// The `--preview-fixtures --preview-gallery attach` window's content (PLAN.md D25): every
/// session-action state from `AttachFixtures.all`, each in a frame like the menu bar popover,
/// and a card with the session row's context menu for a session open here and one attached
/// elsewhere. Nothing here runs an engine, reads `hosts.json` or contacts iTerm2.
public struct AttachGallery: View {
  /// How many cards each row holds.
  public static let columns = 4

  /// The states, each with its own model (made once).
  @State private var entries: [PreviewGallery.Entry]
  /// A model for the context menu's card (a fixture: its buttons do nothing).
  @State private var menuModel = AppModel(fixture: AttachFixtures.banners)

  /// A gallery of every session-action fixture.
  public init() {
    _entries = State(
      initialValue: AttachFixtures.all.map {
        PreviewGallery.Entry(fixture: $0, model: AppModel(fixture: $0))
      })
  }

  /// The grid of states, the context menu's card last.
  public var body: some View {
    let cards = entries.map(Card.state) + [.menu]
    let rows = stride(from: 0, to: cards.count, by: Self.columns).map {
      Array(cards[$0..<min($0 + Self.columns, cards.count)])
    }
    Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 28) {
      ForEach(rows.indices, id: \.self) { index in
        GridRow(alignment: .top) {
          ForEach(rows[index]) { card in
            switch card {
            case .state(let entry): stateCard(entry)
            case .menu: menuCard
            }
          }
        }
      }
    } // End of Grid holding the cards
    .padding(28)
    .background(Color(nsColor: .underPageBackgroundColor))
  } // End of var body

  /// One card of the grid.
  enum Card: Identifiable {
    /// A popover state.
    case state(PreviewGallery.Entry)
    /// The context menu.
    case menu

    /// `Identifiable` conformance.
    var id: String {
      switch self {
      case .state(let entry): return entry.id
      case .menu: return "context-menu"
      }
    }
  }

  /// One state: its title above a popover-like frame.
  private func stateCard(_ entry: PreviewGallery.Entry) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(entry.fixture.title)
        .font(.headline)
      PopoverView(model: entry.model, isLive: false)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
  } // End of func stateCard(_:)

  /// The context menu of a session open here and of one attached elsewhere, drawn as menus.
  private var menuCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Session context menu")
        .font(.headline)
      ForEach(AttachFixtures.menuRows) { row in
        VStack(alignment: .leading, spacing: 4) {
          Text(row.isOpenInITerm2Here ? "“\(row.name)”, open here" : "“\(row.name)”, elsewhere")
            .font(.caption)
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 6) {
            SessionMenu(row: row, model: menuModel)
          }
          .buttonStyle(.plain)
          .padding(10)
          .frame(width: 220, alignment: .leading)
          .background(Color(nsColor: .windowBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        } // End of VStack holding one menu
      }
    } // End of VStack holding the card
    .frame(width: PopoverView.width, alignment: .leading)
  } // End of var menuCard
}

#Preview("Session actions") {
  AttachGallery()
}
