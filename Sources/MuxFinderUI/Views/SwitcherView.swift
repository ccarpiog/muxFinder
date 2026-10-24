import MuxFinderCore
import SwiftUI

/// The session switcher (PLAN.md D32, Phase I-3b): a search field, the popover's banners, the
/// live sessions (pinned rows first) with New session last, muted lines for hosts still
/// checking or unreachable, and a line of key hints; or the popover's placeholder; or the New
/// session form (`NewSessionPanelView`, shared with the popover) while it shows. It paints
/// Phase 14's opaque background, so the real switcher and the preview gallery look the same.
///
/// With `isLive` the view also tracks its window for the switcher's keys
/// (`SwitcherWindowBridge`) and focuses New session's name field; the switcher's controller
/// tells the model when it opens and closes. The preview gallery passes `false`.
public struct SwitcherView: View {
  /// The switcher's width, in points (`SwitcherPlacement.width`).
  public static let width = SwitcherPlacement.width
  /// The tallest the list grows before it scrolls, in points.
  static let maximumListHeight: CGFloat = 380
  /// The panel's accessibility title.
  public static let accessibilityTitle = "Session switcher"
  /// The search field's placeholder and accessibility label.
  static let searchPrompt = "Search sessions and hosts"

  /// The model shown.
  @Bindable var model: AppModel
  /// Whether this is the real switcher (window tracking and keys).
  let isLive: Bool
  /// Whether the search field has the keyboard focus.
  @FocusState private var isSearchFocused: Bool
  /// The list's natural height, measured.
  @State private var listHeight: CGFloat = 0
  /// Light or dark, for the palette.
  @Environment(\.colorScheme) private var colorScheme

  /// A switcher for `model`; `isLive` only in muxFinder's switcher panel.
  public init(model: AppModel, isLive: Bool) {
    self.model = model
    self.isLive = isLive
  }

  /// The New session form while it shows, otherwise the search field, banners, list (or
  /// placeholder), host lines and key hints.
  public var body: some View {
    let content = model.switcherContent
    VStack(spacing: 0) {
      if model.switcherShowsNewSession {
        NewSessionPanelView(model: model, focusesName: isLive)
      } else {
        searchField
          .padding(12)
        Divider()
        if !content.banners.isEmpty {
          BannersView(banners: content.banners, model: model)
          Divider()
        }
        if let placeholder = content.placeholder {
          PlaceholderView(placeholder: placeholder, openSettings: model.openSettings)
        } else {
          list(content)
          if !content.hostLines.isEmpty {
            hostLines(content.hostLines)
          }
        }
        Divider()
        SwitcherHintsView()
      }
    } // End of VStack holding the switcher
    .frame(width: Self.width)
    .background(PopoverPalette(colorScheme).background)
    .background {
      if isLive { SwitcherWindowBridge(model: model) }
    }
    .onChange(of: model.switcherFocusRequests) {
      isSearchFocused = true
    }
    .onChange(of: model.switcherShowsNewSession) { _, showsForm in
      if !showsForm { isSearchFocused = true }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Self.accessibilityTitle)
  } // End of var body

  /// The search field, larger than the popover's, boxed like the list.
  private var searchField: some View {
    let palette = PopoverPalette(colorScheme)
    return HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.title3)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField(Self.searchPrompt, text: $model.switcherSearchText)
        .textFieldStyle(.plain)
        .font(.title3)
        .focused($isSearchFocused)
        .accessibilityLabel(Self.searchPrompt)
      if !model.switcherSearchText.isEmpty {
        Button {
          model.switcherSearchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Clear search")
      }
    } // End of HStack holding the search field
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(RoundedRectangle(cornerRadius: 8).fill(palette.sectionFill))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.border))
  } // End of var searchField

  /// The rows in one bounded box (pinned rows, then the listed ones, the empty text, New
  /// session), scrolling once taller than `maximumListHeight` and keeping the selection in
  /// view. Offered less height (the panel's limit), it is the part that shrinks.
  private func list(_ content: SwitcherContent) -> some View {
    let height = min(max(listHeight, 1), Self.maximumListHeight)
    return ScrollViewReader { proxy in
      ScrollView {
        SwitcherListBox(content: content, model: model)
          .padding(10)
          .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
          } action: { height in
            listHeight = height
          }
      }
      .frame(minHeight: 0, idealHeight: height, maxHeight: height)
      .onChange(of: content.selection) { _, item in
        guard let item else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(item) }
      }
    } // End of ScrollViewReader
    .layoutPriority(-1)
  } // End of func list(_:)

  /// The muted lines for hosts still checking or whose last check failed (never red).
  private func hostLines(_ lines: [SwitcherContent.HostLine]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(lines) { line in
        HStack(spacing: 6) {
          StatusDot(tone: line.tone)
          Text(line.text)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
  } // End of func hostLines(_:)
}

/// The switcher's list in one bounded box, flat like the popover's host sections: the pinned
/// rows, a stronger separator, the listed rows, the empty text, then New session, separated by
/// hairlines.
struct SwitcherListBox: View {
  /// What the list shows.
  let content: SwitcherContent
  /// The model the rows talk to.
  let model: AppModel
  /// Light or dark, for the palette.
  @Environment(\.colorScheme) private var colorScheme
  /// The display's scale, for hairlines one pixel wide.
  @Environment(\.displayScale) private var displayScale

  /// The box.
  var body: some View {
    let palette = PopoverPalette(colorScheme)
    let hairline = 1 / max(displayScale, 1)
    VStack(alignment: .leading, spacing: 0) {
      ForEach(content.pinned) { row in
        if row.key != content.pinned.first?.key { separator(palette, hairline) }
        SwitcherRowView(row: row, model: model)
          .id(SwitcherContent.Item.session(row.key))
      }
      if !content.pinned.isEmpty {
        Rectangle()
          .fill(palette.border)
          .frame(height: 2 * hairline)
          .padding(.vertical, 3)
      }
      ForEach(content.rows) { row in
        if row.key != content.rows.first?.key { separator(palette, hairline) }
        SwitcherRowView(row: row, model: model)
          .id(SwitcherContent.Item.session(row.key))
      }
      if let emptyText = content.emptyText {
        Text(emptyText)
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
      }
      if let newSession = content.newSession {
        Rectangle()
          .fill(palette.border)
          .frame(height: hairline)
          .padding(.horizontal, 8)
        SwitcherNewSessionRowView(row: newSession, model: model)
          .id(SwitcherContent.Item.newSession)
      }
    } // End of VStack holding the rows
    .padding(.vertical, 3)
    .background(palette.sectionFill)
    .clipShape(RoundedRectangle(cornerRadius: HostSectionView.cornerRadius))
    .overlay(
      RoundedRectangle(cornerRadius: HostSectionView.cornerRadius)
        .strokeBorder(palette.border, lineWidth: hairline)
    )
  } // End of var body

  /// A hairline between two rows, past the indicator column.
  private func separator(_ palette: PopoverPalette, _ hairline: CGFloat) -> some View {
    Rectangle()
      .fill(palette.border)
      .frame(height: hairline)
      .padding(.leading, HostSectionView.separatorInset)
      .padding(.trailing, 8)
  }
}

/// One session in the switcher: Phase 14's attach-state indicator, its name (stronger while
/// attached) and its host's name, the detail text, the "Open in iTerm2 here" badge, and any
/// progress, result or failure with the popover row's recoveries. A click selects it; a
/// double-click (or Return) opens it as the popover's Open does. No Move here or Detach here:
/// those stay in the popover (PLAN.md D32).
struct SwitcherRowView: View {
  /// The row's content.
  let row: SessionRow
  /// The model the row talks to.
  let model: AppModel
  /// Whether the pointer is over the row.
  @State private var isHovered = false
  /// Light or dark, for the palette.
  @Environment(\.colorScheme) private var colorScheme

  /// The row's layout and its single accessibility element.
  var body: some View {
    let palette = PopoverPalette(colorScheme)
    let item = SwitcherContent.Item.session(row.key)
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      AttachStateIndicator(state: row.attachState)
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(row.name)
            .fontWeight(row.isAttached ? .semibold : .regular)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(row.attachState == .stale ? .secondary : .primary)
            .layoutPriority(1)
          Text(row.hostName)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer(minLength: 8)
          Text(row.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } // End of HStack holding the name, host and detail
        if row.isOpenInITerm2Here {
          OpenHereBadge()
        }
        if let activity = row.activity {
          ActivityLine(activity: activity, key: row.key, model: model)
        }
        if let note = row.note {
          Text(note)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 18)
        }
      } // End of VStack holding the row's text
    } // End of HStack holding the indicator and the row's text
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .background {
      RoundedRectangle(cornerRadius: 6)
        .fill(palette.rowFill(isSelected: row.isSelected, isHovered: isHovered))
        .overlay {
          if row.isSelected {
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(palette.selectionOutline, lineWidth: 1.5)
          }
        }
    }
    .padding(.horizontal, 4)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { model.activateSwitcherItem(item) }
    .onTapGesture { model.selectSwitcherItem(item) }
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityValue(row.accessibilityValue)
    .accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : [.isButton])
    .accessibilityHint("Opens the session in iTerm2.")
    .accessibilityAction { model.activateSwitcherItem(item) }
    .accessibilityActions { accessibilityActions }
  } // End of var body

  /// The activity's buttons for VoiceOver ("Show tab", a failure's recoveries).
  @ViewBuilder private var accessibilityActions: some View {
    if case .stillConnecting = row.activity {
      Button("Show tab") { model.showTab(for: row.key) }
    }
    if let problem = row.activity?.problem {
      ForEach(problem.recoveries, id: \.self) { recovery in
        Button(recovery.title) { model.perform(recovery, for: row.key) }
      }
    }
  }
}

/// The switcher's last row: "New session…", or "New session “<name>”…" when the filter text
/// gives the name. A click selects it; a double-click (or Return, or ⌘N) shows the form.
struct SwitcherNewSessionRowView: View {
  /// The row's content.
  let row: SwitcherContent.NewSessionRow
  /// The model the row talks to.
  let model: AppModel
  /// Whether the pointer is over the row.
  @State private var isHovered = false
  /// Light or dark, for the palette.
  @Environment(\.colorScheme) private var colorScheme

  /// The row.
  var body: some View {
    let palette = PopoverPalette(colorScheme)
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "plus")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: AttachStateIndicator.width)
        .accessibilityHidden(true)
      Text(row.title)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      Text("⌘N")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    } // End of HStack holding the row
    .padding(.vertical, 7)
    .padding(.horizontal, 8)
    .background {
      RoundedRectangle(cornerRadius: 6)
        .fill(palette.rowFill(isSelected: row.isSelected, isHovered: isHovered))
        .overlay {
          if row.isSelected {
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(palette.selectionOutline, lineWidth: 1.5)
          }
        }
    }
    .padding(.horizontal, 4)
    .padding(.top, 3)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { model.activateSwitcherItem(.newSession) }
    .onTapGesture { model.selectSwitcherItem(.newSession) }
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : [.isButton])
    .accessibilityHint("Shows the New session form.")
    .accessibilityAction { model.activateSwitcherItem(.newSession) }
  } // End of var body
}

/// The switcher's key hints, muted, at its bottom.
struct SwitcherHintsView: View {
  /// The hints, as key and meaning.
  static let hints: [(key: String, meaning: String)] = [
    ("↩", "Open"), ("⌘N", "New session"), ("⌘R", "Refresh"), ("⌘,", "Settings"),
  ]

  /// One line of hints, "Esc Close" trailing.
  var body: some View {
    HStack(spacing: 14) {
      ForEach(Self.hints, id: \.key) { hint in
        hintView(hint.key, hint.meaning)
      }
      Spacer(minLength: 0)
      hintView("Esc", "Close")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .accessibilityElement(children: .combine)
  } // End of var body

  /// A key, then what it does.
  private func hintView(_ key: String, _ meaning: String) -> some View {
    HStack(spacing: 4) {
      Text(key).fontWeight(.semibold)
      Text(meaning)
    }
  }
}
