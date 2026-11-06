import MuxFinderCore
import SwiftUI

/// The `--preview-fixtures --preview-gallery new-session` window's content (PLAN.md D34, Phase
/// I-9b): every state of the New session window, each drawn like the window (its title bar and
/// the live form's root view, `NewSessionWindowRoot`, not live): editing (as the popover and as
/// the switcher open it), an invalid name, the directory list's states (open, nothing to pick,
/// saved already, an unusable file, filtered by typing, no match), busy, a collision, a failure
/// and a folder dragged over Directory. Nothing here runs an engine, reads `hosts.json` or
/// `directories.json`, or contacts iTerm2.
public struct NewSessionGallery: View {
  /// How many cards each row holds.
  public static let columns = 3
  /// The title bar's height, in points.
  static let titleBarHeight: CGFloat = 28

  /// The states in the gallery's order: the popover's (`AttachFixtures.newSessionStates`) with
  /// the switcher's opening (`SwitcherFixtures.form`, its name from the filter) after the first.
  public static let fixtures: [PreviewFixture] = {
    var states = AttachFixtures.newSessionStates
    states.insert(SwitcherFixtures.form, at: 1)
    return states
  }()

  /// The states, each with its own model (made once).
  @State private var entries: [PreviewGallery.Entry]

  /// A gallery of every New session window state.
  public init() {
    _entries = State(
      initialValue: Self.fixtures.map {
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

  /// One state: its caption above a window-like frame (a title bar saying "New session" over
  /// the form on its opaque background).
  private func card(_ entry: PreviewGallery.Entry) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(entry.fixture.title)
        .font(.headline)
      VStack(spacing: 0) {
        titleBar
        Divider()
        NewSessionWindowRoot(model: entry.model, isLive: false, onSizeChange: {})
      }
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
      .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    } // End of VStack holding one card
  } // End of func card(_:)

  /// A title bar like the window's: its close button (the other two off, as for a panel that
  /// is only closable) and its title.
  private var titleBar: some View {
    ZStack {
      Text(NewSessionWindow.title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        windowButton(Color(red: 1, green: 0.37, blue: 0.34))
        windowButton(Color.secondary.opacity(0.35))
        windowButton(Color.secondary.opacity(0.35))
        Spacer()
      }
      .padding(.leading, 12)
    } // End of ZStack holding the title bar
    .frame(width: NewSessionWindowPlacement.width, height: Self.titleBarHeight)
    .background(Color(nsColor: .windowBackgroundColor))
  } // End of var titleBar

  /// One of the title bar's three buttons, drawn as a dot of `color`.
  private func windowButton(_ color: Color) -> some View {
    Circle()
      .fill(color)
      .frame(width: 12, height: 12)
  }
}

#Preview("New session: a folder dragged over Directory") {
  NewSessionWindowRoot(
    model: AppModel(fixture: AttachFixtures.newSessionFolderDrag), isLive: false,
    onSizeChange: {})
}

#Preview("Every New session window state") {
  NewSessionGallery()
}
