import MuxFinderCore
import SwiftUI

/// The menu bar popover (PLAN.md Phase 8, D22, D30): a search field, notices, the hosts with
/// their sessions (or a placeholder), and the footer, on its own opaque window background, so
/// the real popover (in muxFinder's panel, `MenuBarPopover`) and the preview galleries look the
/// same.
///
/// With `isLive` the view also tracks its window for the popover's keys
/// (`PopoverWindowBridge`); the panel's controller tells the model when the popover opens and
/// closes. The preview window and SwiftUI previews pass `false`: a fixture never tells an
/// engine anything.
public struct PopoverView: View {
  /// The popover's width, in points.
  public static let width: CGFloat = 360
  /// The tallest the host list grows before it scrolls, in points.
  static let maximumListHeight: CGFloat = 440

  /// The model shown.
  @Bindable var model: AppModel
  /// Whether this is the real popover (window tracking and keys).
  let isLive: Bool
  /// Whether the search field has the keyboard focus.
  @FocusState private var isSearchFocused: Bool
  /// The host list's natural height, measured.
  @State private var listHeight: CGFloat = 0
  /// Light or dark, for the palette.
  @Environment(\.colorScheme) private var colorScheme

  /// A popover for `model`; `isLive` only in muxFinder's popover panel.
  public init(model: AppModel, isLive: Bool) {
    self.model = model
    self.isLive = isLive
  }

  /// The popover's layout: the panel (Move here, New session) while one shows, otherwise the
  /// search field, banners, notices, hosts and footer.
  public var body: some View {
    let content = model.content
    VStack(spacing: 0) {
      if let panel = model.panel {
        PanelView(panel: panel, model: model)
      } else {
        searchField
          .padding(10)
        Divider()
        if !content.banners.isEmpty {
          BannersView(banners: content.banners, model: model)
          Divider()
        }
        if !content.notices.isEmpty {
          NoticesView(notices: content.notices, model: model)
          Divider()
        }
        if let placeholder = content.placeholder {
          PlaceholderView(placeholder: placeholder, openSettings: model.openSettings)
        } else {
          hostList(content.sections)
        }
        Divider()
        FooterView(model: model)
      }
    } // End of VStack holding the popover
    .frame(width: Self.width)
    .background(PopoverPalette(colorScheme).background)
    .background {
      if isLive { PopoverWindowBridge(model: model) }
    }
    .onChange(of: model.searchFocusRequests) {
      isSearchFocused = true
    }
  } // End of var body

  /// The search field, with a clear button while it holds text, boxed like the host sections.
  private var searchField: some View {
    let palette = PopoverPalette(colorScheme)
    return HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField("Search hosts and sessions", text: $model.searchText)
        .textFieldStyle(.plain)
        .focused($isSearchFocused)
        .accessibilityLabel("Search hosts and sessions")
      if !model.searchText.isEmpty {
        Button {
          model.searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Clear search")
      }
    } // End of HStack holding the search field
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(RoundedRectangle(cornerRadius: 7).fill(palette.sectionFill))
    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.border))
  } // End of var searchField

  /// The host groups, one bounded box each, scrolling once taller than `maximumListHeight`,
  /// keeping the keyboard selection in view. At its natural height when offered no height or
  /// enough; offered less (the panel's height limit, PLAN.md D30), it is the part that shrinks,
  /// down to nothing, and scrolls, so the search field, notices and footer keep their heights.
  private func hostList(_ sections: [HostSection]) -> some View {
    let height = min(max(listHeight, 1), Self.maximumListHeight)
    return ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(sections) { section in
            HostSectionView(section: section, model: model)
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .onGeometryChange(for: CGFloat.self) { geometry in
          geometry.size.height
        } action: { height in
          listHeight = height
        }
      } // End of ScrollView
      .frame(minHeight: 0, idealHeight: height, maxHeight: height)
      .onChange(of: model.selection) { _, key in
        guard let key else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(key) }
      }
    } // End of ScrollViewReader
    .layoutPriority(-1)
  } // End of func hostList(_:)
}
