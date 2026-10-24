import MuxFinderCore
import SwiftUI

/// New session's Directory field (PLAN.md D31): a text field (typing, pasting, `~/…`) with a
/// pull-down button at its trailing edge that opens the directory list under it, the field's
/// inline issue, and the list while it is open. ⌥↓ opens the list from the keyboard, as does
/// Space on the button once Tab reaches it (with macOS's keyboard navigation on).
struct DirectoryFieldView: View {
  /// The field's caption, also its accessibility label.
  static let title = "Directory (optional)"

  /// The model whose draft the field edits.
  @Bindable var model: AppModel

  /// The caption, the field and its button, the issue, and the open list.
  var body: some View {
    let draft = model.newSessionDraft
    let content = model.directoryPickerContent
    VStack(alignment: .leading, spacing: 3) {
      Text(Self.title)
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack(spacing: 4) {
        TextField(
          Self.title, text: $model.newSessionDraft.directory,
          prompt: Text("Home folder on the host")
        )
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .disabled(draft.isBusy)
        .accessibilityLabel(Self.title)
        pullDownButton(content)
      }
      if let issue = draft.directoryIssue {
        Text(issue)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      if model.directoryPicker.isOpen, let content {
        DirectoryListView(content: content, model: model)
          .padding(.top, 3)
      }
    } // End of VStack holding the field
  } // End of var body

  /// The button that opens and closes the list; with nothing to pick it says so.
  private func pullDownButton(_ content: DirectoryPickerContent?) -> some View {
    let isOpen = model.directoryPicker.isOpen
    let nothing = content?.isEmpty ?? true
    return Button {
      model.toggleDirectoryList()
    } label: {
      Image(systemName: isOpen ? "chevron.up" : "chevron.down")
        .frame(width: 14, height: 14)
    }
    .buttonStyle(.bordered)
    .disabled(model.newSessionDraft.isBusy || content == nil)
    .help(
      nothing
        ? "\(DirectoryPickerContent.nothingToPick) (⌥↓)"
        : "Pick a recent, saved or session directory (⌥↓)"
    )
    .accessibilityLabel("Pick a directory")
    .accessibilityValue(
      nothing ? DirectoryPickerContent.nothingToPick : (isOpen ? "Shown" : "Hidden"))
  } // End of func pullDownButton(_:)
}

/// New session's directory list, drawn inside the popover under the Directory field (PLAN.md
/// D31): the store's notice, the sections (or "Nothing to pick yet"), "Save this directory",
/// "Clear recent directories on <host>" and the last change's problem. Rows shorten long paths
/// in the middle and give the full path as help and accessibility label; the highlighted row
/// (keys or pointer) has the popover's selection look. Rows are identified by
/// `DirectoryPickerContent.Item` (section and UTF-8 bytes).
struct DirectoryListView: View {
  /// The tallest the sections grow before they scroll, in points.
  static let maximumHeight: CGFloat = 260

  /// What the list shows.
  let content: DirectoryPickerContent
  /// The model the rows talk to.
  let model: AppModel
  /// The sections' natural height, measured.
  @State private var sectionsHeight: CGFloat = 0
  /// Light or dark, for the palette.
  @Environment(\.colorScheme) private var colorScheme

  /// The notice, the sections, the actions and the problem in one bordered box.
  var body: some View {
    let palette = PopoverPalette(colorScheme)
    let highlighted = model.highlightedDirectoryItem
    VStack(alignment: .leading, spacing: 0) {
      if let notice = content.notice {
        MessageLine(text: notice, systemImage: "exclamationmark.triangle.fill", tint: .orange)
          .padding(8)
        Divider()
      }
      if content.isEmpty {
        emptyNote
      } else {
        sections(highlighted: highlighted, palette: palette)
      }
      Divider()
      VStack(alignment: .leading, spacing: 1) {
        actionRow(
          .saveDirectory, title: DirectoryPickerContent.saveTitle,
          systemImage: "bookmark", help: saveHelp, highlighted: highlighted, palette: palette)
        actionRow(
          .clearRecents, title: content.clearTitle, systemImage: "clock.arrow.circlepath",
          help: content.canClearRecents
            ? "Forget the directories you created sessions in on \(content.hostName)"
            : "No recent directories on \(content.hostName)",
          highlighted: highlighted, palette: palette)
      }
      .padding(4)
      if let problem = model.directoryPicker.problem {
        Divider()
        MessageLine(text: problem, systemImage: "xmark.octagon.fill", tint: .red)
          .padding(8)
      }
    } // End of VStack holding the list
    .background(RoundedRectangle(cornerRadius: 7).fill(palette.sectionFill))
    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.border))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Directories")
  } // End of var body

  /// "Save this directory"'s help: what it does, or why it is off.
  private var saveHelp: String {
    content.saveIssue?.help
      ?? "Add the Directory field's value to the saved directories, offered for every host"
  }

  /// What the list says with nothing to pick.
  private var emptyNote: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(DirectoryPickerContent.nothingToPick)
        .font(.callout)
      Text(DirectoryPickerContent.nothingToPickExplanation)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  } // End of var emptyNote

  /// The sections with their rows, scrolling once taller than `maximumHeight` and keeping the
  /// highlighted row in view.
  private func sections(
    highlighted: DirectoryPickerContent.Item?,
    palette: PopoverPalette
  ) -> some View {
    let height = min(max(sectionsHeight, 1), Self.maximumHeight)
    return ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 1) {
          ForEach(content.sections) { section in
            Text(section.title)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 8)
              .padding(.top, 5)
              .padding(.bottom, 1)
              .accessibilityAddTraits(.isHeader)
            // Rows are identified by `Item` (section and UTF-8 bytes), never by the `String`,
            // whose equality would merge two spellings of one accented name.
            ForEach(section.items, id: \.self) { item in
              entryRow(
                item.directory ?? "", item: item, isHighlighted: item == highlighted,
                palette: palette
              )
              .id(item)
            }
          } // End of loop over the sections
        }
        .padding(4)
        .onGeometryChange(for: CGFloat.self) { geometry in
          geometry.size.height
        } action: { height in
          sectionsHeight = height
        }
      } // End of ScrollView
      .frame(height: height)
      .onChange(of: highlighted) { _, item in
        guard let item, case .entry = item else { return }
        proxy.scrollTo(item)
      }
    } // End of ScrollViewReader
  } // End of func sections(highlighted:palette:)

  /// One directory: shortened in the middle, the full path as help and label.
  private func entryRow(
    _ entry: String,
    item: DirectoryPickerContent.Item,
    isHighlighted: Bool,
    palette: PopoverPalette
  ) -> some View {
    Button {
      model.pickDirectoryItem(item)
    } label: {
      Text(entry)
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(rowBackground(isHighlighted, palette: palette))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(entry)
    .accessibilityLabel(entry)
    .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    .onHover { inside in
      if inside { model.highlightDirectoryItem(item) }
    }
  } // End of func entryRow(_:item:isHighlighted:palette:)

  /// One action below the sections; off ones are dimmed and never highlighted.
  private func actionRow(
    _ action: DirectoryPickerContent.Action,
    title: String,
    systemImage: String,
    help: String,
    highlighted: DirectoryPickerContent.Item?,
    palette: PopoverPalette
  ) -> some View {
    let item = DirectoryPickerContent.Item.action(action)
    let isHighlighted = item == highlighted
    return Button {
      model.pickDirectoryItem(item)
    } label: {
      Label(title, systemImage: systemImage)
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(rowBackground(isHighlighted, palette: palette))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!content.isEnabled(action))
    .help(help)
    .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    .onHover { inside in
      if inside { model.highlightDirectoryItem(item) }
    }
  } // End of func actionRow(_:title:systemImage:help:highlighted:palette:)

  /// A highlighted row's fill and outline (the popover's selection look), else nothing.
  @ViewBuilder
  private func rowBackground(_ isHighlighted: Bool, palette: PopoverPalette) -> some View {
    if isHighlighted {
      RoundedRectangle(cornerRadius: 4)
        .fill(palette.selectedRowFill)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.selectionOutline))
    }
  }
}
