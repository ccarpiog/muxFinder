import MuxFinderCore
import SwiftUI

/// The `--preview-fixtures --preview-gallery attach` window's content (PLAN.md D25): every
/// session-action state from `AttachFixtures.all`, then the states per terminal
/// (`TerminalAttachFixtures.all`, PLAN.md D38 *The UI (I-12d2)*), each in a frame like the menu
/// bar popover, a card with the session row's context menu for a session open here and one
/// attached elsewhere, and one card per plain terminal's context menus. Nothing here runs an
/// engine, reads `hosts.json` or `directories.json`, or contacts iTerm2 or any terminal app.
public struct AttachGallery: View {
  /// How many cards each row holds.
  public static let columns = 4

  /// The states, each with its own model (made once).
  @State private var entries: [PreviewGallery.Entry]
  /// A model for the context menu's card (a fixture: its buttons do nothing).
  @State private var menuModel = AppModel(fixture: AttachFixtures.banners)
  /// The plain terminals' menu cards, each with its model (fixtures: their buttons do nothing).
  @State private var terminalMenus: [PreviewGallery.Entry]

  /// A gallery of every session-action fixture.
  public init() {
    _entries = State(
      initialValue: (AttachFixtures.all + TerminalAttachFixtures.all).map {
        PreviewGallery.Entry(fixture: $0, model: AppModel(fixture: $0))
      })
    _terminalMenus = State(
      initialValue: TerminalAttachFixtures.menus.map {
        PreviewGallery.Entry(fixture: $0.fixture, model: AppModel(fixture: $0.fixture))
      })
  }

  /// The grid of states, the context menus' cards last.
  public var body: some View {
    let cards =
      entries.map(Card.state) + [.menu]
      + TerminalAttachFixtures.menus.indices.map(Card.terminalMenu)
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
            case .terminalMenu(let index): terminalMenuCard(index)
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
    /// A plain terminal's context menus (`TerminalAttachFixtures.menus[index]`).
    case terminalMenu(Int)

    /// `Identifiable` conformance.
    var id: String {
      switch self {
      case .state(let entry): return entry.id
      case .menu: return "context-menu"
      case .terminalMenu(let index): return "context-menu-\(index)"
      }
    }
  } // End of enum Card

  /// One state: its title above a popover-like frame (the popover paints its own opaque
  /// background, as in the menu bar).
  private func stateCard(_ entry: PreviewGallery.Entry) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(entry.fixture.title)
        .font(.headline)
      PopoverView(model: entry.model, isLive: false)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
  } // End of func stateCard(_:)

  /// The context menu of a session open here and of one attached elsewhere, drawn as menus.
  private var menuCard: some View {
    menus(
      title: "Session context menu", rows: AttachFixtures.menuRows, model: menuModel,
      caption: { row in
        row.isOpenInITerm2Here ? "“\(row.name)”, open here" : "“\(row.name)”, elsewhere"
      })
  }

  /// A plain terminal's context menus (`TerminalAttachFixtures.menus[index]`).
  private func terminalMenuCard(_ index: Int) -> some View {
    let card = TerminalAttachFixtures.menus[index]
    return menus(
      title: card.title, rows: card.rows, model: terminalMenus[index].model,
      caption: { row in "“\(row.name)”" })
  }

  /// A card titled `title` drawing the context menu of each of `rows` for `model`, each under
  /// its `caption`.
  private func menus(
    title: String, rows: [SessionRow], model: AppModel, caption: @escaping (SessionRow) -> String
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
      ForEach(rows) { row in
        VStack(alignment: .leading, spacing: 4) {
          Text(caption(row))
            .font(.caption)
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 6) {
            SessionMenu(row: row, model: model)
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
  } // End of func menus(title:rows:model:caption:)
}

#Preview("New session: directory list") {
  NewSessionWindowRoot(
    model: AppModel(fixture: AttachFixtures.newSessionDirectories), isLive: false,
    onSizeChange: {})
}

#Preview("Session actions") {
  AttachGallery()
}
