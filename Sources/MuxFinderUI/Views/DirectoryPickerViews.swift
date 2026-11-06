import MuxFinderCore
import SwiftUI

/// New session's Directory field (PLAN.md D31): a text field (typing, pasting, `~/…`) with a
/// pull-down button at its trailing edge that opens the directory list under it, the field's
/// inline issue, and the list while it is open. The field is the list's search (Phase I-7):
/// typing filters the list and opens it while something matches (`AppModel`'s
/// `directoryFieldChanged(from:)`). ⌥↓ opens the list from the keyboard, as does Space on the
/// button once Tab reaches it (with macOS's keyboard navigation on). Tab with the list open
/// moves on and leaves it open: its rows take no focus (SwiftUI draws them, so they are not in
/// the window's key view loop) and its keys are the model's wherever the focus is in the form
/// (PLAN.md D31). One folder dragged from Finder onto the field or its button fills the field
/// with its path (`~/…` under This Mac's home folder) through `DirectoryDropZone`, an AppKit
/// drop target laid over the row, whether or not the field is being edited; the field shows a
/// highlight while such a drag hovers, and every other drag is refused (PLAN.md D34, Phase
/// I-9b).
struct DirectoryFieldView: View {
  /// The field's caption, also its accessibility label.
  static let title = "Directory (optional)"
  /// The field's placeholder.
  static let prompt = "Home folder on the host"
  /// The field's accessibility hint: typing filters the list and searches the host's folders;
  /// a folder can be dropped on it.
  static let hint =
    "Typing filters the list of recent, saved and session directories and searches the host's "
    + "folders by name. Option-Down Arrow shows the list. Dropping a folder from Finder here "
    + "fills in its path."
  /// How far the drop highlight reaches outside the field, in points.
  static let highlightOutset: CGFloat = 3

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
          prompt: Text(Self.prompt)
        )
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .disabled(draft.isBusy)
        .accessibilityLabel(Self.title)
        .accessibilityHint(Self.hint)
        .overlay {
          if model.isDirectoryDropTargeted { dropHighlight }
        }
        pullDownButton(content)
      }
      .overlay {
        DirectoryDropZone(model: model)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
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

  /// The drop highlight: an accent ring just outside the field, while a folder that would fill
  /// it is dragged over the row.
  private var dropHighlight: some View {
    RoundedRectangle(cornerRadius: 5 + Self.highlightOutset)
      .strokeBorder(Color.accentColor, lineWidth: 2.5)
      .padding(-Self.highlightOutset)
      .allowsHitTesting(false)
  }

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

/// New session's directory list, drawn inside the New session window under the Directory field
/// (PLAN.md D31, D34): the store's notice, the sections the Directory field's filter leaves (or
/// "Nothing to pick yet", or "No matching directories"), the "Folders on <host>" section while
/// folder search applies (Phase I-10b: its status line, the folders found, its notes and
/// "Missing a folder?" with its explanation), "Save this directory", "Clear recent directories
/// on <host>" and the last change's problem. Rows shorten long paths in the middle and give the
/// full path as help and accessibility label; the highlighted row (keys or pointer) has the
/// popover's selection look. Rows are identified by `DirectoryPickerContent.Item` (section and
/// UTF-8 bytes). Its accessibility value is the match count (and the folders' summary), which
/// VoiceOver also hears as an announcement when it changes (`AppModel.announce`).
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
      if content.folders == nil, content.isEmpty {
        placeholderNote(
          DirectoryPickerContent.nothingToPick,
          explanation: DirectoryPickerContent.nothingToPickExplanation)
      } else if content.folders == nil, content.noMatches {
        placeholderNote(
          DirectoryPickerContent.noMatchesTitle,
          explanation: DirectoryPickerContent.noMatchesExplanation)
      } else {
        sections(highlighted: highlighted, palette: palette)
      }
      if let folders = content.folders, model.isFolderSearchHelpShown {
        Divider()
        FolderSearchHelpView(section: folders, model: model)
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
    .accessibilityValue(content.listSummary)
  } // End of var body

  /// "Save this directory"'s help: what it does, or why it is off.
  private var saveHelp: String {
    content.saveIssue?.help
      ?? "Add the Directory field's value to the saved directories, offered for every host"
  }

  /// What the list says in place of the sections: with nothing to pick, or with the filter
  /// hiding every entry.
  private func placeholderNote(_ title: String, explanation: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.callout)
      Text(explanation)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  } // End of func placeholderNote(_:explanation:)

  /// The sections with their rows (the folders section last), scrolling once taller than
  /// `maximumHeight` and keeping the highlighted row in view.
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
          if let folders = content.folders {
            FolderSearchSectionView(
              section: folders, model: model, highlighted: highlighted, palette: palette)
          }
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
        guard let item else { return }
        switch item {
        case .entry, .action(.folderSearchHelp): proxy.scrollTo(item)
        case .action: break
        }
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
    DirectoryEntryRow(
      entry: entry, item: item, isHighlighted: isHighlighted, palette: palette, model: model)
  }

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
  private func rowBackground(_ isHighlighted: Bool, palette: PopoverPalette) -> some View {
    DirectoryRowBackground(isHighlighted: isHighlighted, palette: palette)
  }
}

/// A highlighted row's fill and outline in the directory list (the popover's selection look),
/// else nothing.
struct DirectoryRowBackground: View {
  /// Whether the row is highlighted.
  let isHighlighted: Bool
  /// The palette.
  let palette: PopoverPalette

  /// The fill and outline, or nothing.
  var body: some View {
    if isHighlighted {
      RoundedRectangle(cornerRadius: 4)
        .fill(palette.selectedRowFill)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.selectionOutline))
    }
  }
}

/// One directory of the list (a folder found included): shortened in the middle, the full path
/// as help and accessibility label, the highlight under the pointer.
struct DirectoryEntryRow: View {
  /// The directory as the field would take it.
  let entry: String
  /// Its row.
  let item: DirectoryPickerContent.Item
  /// Whether it is highlighted.
  let isHighlighted: Bool
  /// The palette.
  let palette: PopoverPalette
  /// The model the row talks to.
  let model: AppModel

  /// The row's button.
  var body: some View {
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
        .background(DirectoryRowBackground(isHighlighted: isHighlighted, palette: palette))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(entry)
    .accessibilityLabel(entry)
    .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    .onHover { inside in
      if inside { model.highlightDirectoryItem(item) }
    }
  } // End of var body
}

/// The "Folders on <host>" section of the directory list (PLAN.md D31, D36, Phase I-10b): its
/// title, its status line ("Searching…", "No folders found", the unavailable reason, the
/// problem), the folders found (rows like the other sections'), its notes (the limit, folders
/// that can't be offered, an SSH host's protected folders) and "Missing a folder?", a row the
/// keys reach like the actions, which shows or hides the explanation
/// (`FolderSearchHelpView`, below the scrolling sections so its links always show).
struct FolderSearchSectionView: View {
  /// What the section shows.
  let section: FolderSearchSection
  /// The model the rows talk to.
  let model: AppModel
  /// The list's highlighted row.
  let highlighted: DirectoryPickerContent.Item?
  /// The palette.
  let palette: PopoverPalette

  /// The title, status, rows, notes and help.
  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(section.title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 5)
        .padding(.bottom, 1)
        .accessibilityAddTraits(.isHeader)
      statusLine
      ForEach(rows, id: \.self) { item in
        DirectoryEntryRow(
          entry: item.directory ?? "", item: item, isHighlighted: item == highlighted,
          palette: palette, model: model
        )
        .id(item)
      }
      ForEach(notes, id: \.self) { note in
        Text(note)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
      }
      helpRow
    } // End of VStack holding the section
    .accessibilityElement(children: .contain)
    .accessibilityLabel(section.title)
    .accessibilityValue(section.summary)
  } // End of var body

  /// The folders found as the list's rows.
  private var rows: [DirectoryPickerContent.Item] {
    section.entries.map { DirectoryPickerContent.Item.entry(.folders, $0) }
  }

  /// The notes under the rows: the limit, folders that can't be offered, protected folders.
  private var notes: [String] {
    [section.limitedNote, section.droppedNote, section.protectedFoldersNote].compactMap { $0 }
  }

  /// "Searching…" with a small spinner, a "nothing found" line, the unavailable title and
  /// reason, or the problem; nothing while folders are listed and the search is over.
  @ViewBuilder
  private var statusLine: some View {
    switch section.status {
    case .found:
      EmptyView()
    case .searching:
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.mini)
          .accessibilityHidden(true)
        Text(FolderSearchSection.searchingTitle)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
    case .noneFound, .noneElse:
      Text(section.statusLine ?? "")
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    case .unavailable:
      VStack(alignment: .leading, spacing: 2) {
        Text(section.unavailableTitle)
          .font(.callout)
        if let reason = section.unavailableReason {
          Text(reason)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .accessibilityElement(children: .combine)
    case .failed, .refused:
      MessageLine(
        text: section.statusLine ?? "", systemImage: "exclamationmark.triangle.fill",
        tint: .orange
      )
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
    }
  } // End of var statusLine

  /// "Missing a folder?": a row the keys and the pointer highlight; picking it shows or hides
  /// the explanation.
  private var helpRow: some View {
    let item = DirectoryPickerContent.Item.action(.folderSearchHelp)
    let isHighlighted = item == highlighted
    return Button {
      model.pickDirectoryItem(item)
    } label: {
      Label(FolderSearchSection.helpTitle, systemImage: "questionmark.circle")
        .font(.callout)
        .foregroundStyle(Color.accentColor)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(DirectoryRowBackground(isHighlighted: isHighlighted, palette: palette))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(
      model.isFolderSearchHelpShown
        ? "Hide why a folder may not be listed" : "Why a folder may not be listed"
    )
    .accessibilityValue(model.isFolderSearchHelpShown ? "Shown" : "Hidden")
    .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    .onHover { inside in
      if inside { model.highlightDirectoryItem(item) }
    }
    .id(item)
  } // End of var helpRow

}

/// "Missing a folder?"'s explanation in the directory list (PLAN.md Phase I-10b): why a folder
/// may not be listed (`FolderSearchSection.missingFolderExplanation`), with "Open muxFinder
/// Settings" (its Directories tab, where the scope is) and, for This Mac, "Open Spotlight
/// settings" (System Settings). Shown below the scrolling sections while the user asked for it.
struct FolderSearchHelpView: View {
  /// The folders section it explains.
  let section: FolderSearchSection
  /// The model the links talk to.
  let model: AppModel

  /// The paragraphs and the links.
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(FolderSearchSection.missingFolderExplanation, id: \.self) { paragraph in
        Text(paragraph)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 8) {
        Button(FolderSearchSection.openSettingsTitle) { model.openFolderSearchSettings() }
        if section.isThisMac {
          Button(FolderSearchSection.openSpotlightSettingsTitle) {
            model.openSpotlightSettings()
          }
        }
      }
      .controlSize(.small)
      .padding(.top, 2)
    } // End of VStack holding the explanation
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(FolderSearchSection.helpTitle)
  } // End of var body
}
