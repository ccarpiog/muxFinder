import MuxFinderCore
import SwiftUI

/// The Hosts tab: the host list's banner (examples, an unusable file, a file changed since it
/// was loaded, an unreadable folder), the hosts on the left with Add and Remove, and the editor
/// on the right. Removing a host, discarding unsaved changes and replacing an unusable or
/// changed file each ask first.
struct HostsSettingsView: View {
  /// The model shown.
  let model: SettingsModel
  /// Whether "Replace the host list file?" is shown.
  @State private var isConfirmingReplace = false

  /// The banner, the list and the editor.
  var body: some View {
    VStack(spacing: 0) {
      if let banner = model.banner {
        bannerView(banner)
        Divider()
      }
      HStack(spacing: 0) {
        HostListColumn(model: model)
          .frame(width: 190)
        Divider()
        if model.draft != nil {
          HostEditorView(model: model)
        } else {
          emptyEditor
        }
      }
    } // End of VStack holding the tab
    .confirmationDialog(
      "Discard unsaved changes?", isPresented: discardBinding, titleVisibility: .visible
    ) {
      Button("Discard changes", role: .destructive) { model.confirmDiscard() }
      Button("Keep editing", role: .cancel) { model.cancelDiscard() }
    } message: {
      Text("Your changes to this host aren't saved yet.")
    }
    .confirmationDialog(
      "Remove “\(model.pendingRemovalName ?? "host")”?", isPresented: removalBinding,
      titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) { Task { await model.confirmRemoval() } }
      Button("Cancel", role: .cancel) { model.cancelRemoval() }
    } message: {
      Text("muxFinder stops listing this host's sessions. Its tmux sessions keep running.")
    }
    .confirmationDialog(
      "Replace the host list file?", isPresented: $isConfirmingReplace, titleVisibility: .visible
    ) {
      Button("Replace") { model.confirmReplaceFile() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(replaceMessage)
    }
  } // End of var body

  /// What "Replace the host list file?" explains, for an unusable or a changed file.
  private var replaceMessage: String {
    let start =
      model.changedFile == nil
      ? "muxFinder starts a new host list from the examples."
      : "muxFinder saves the host list shown here over the file as it is now."
    return start + " The current file stays as it is until you save, and is then kept as a "
      + "backup in muxFinder's settings folder."
  }

  /// Presents the discard question while a selection waits.
  private var discardBinding: Binding<Bool> {
    Binding(
      get: { model.pendingSelection != nil },
      set: { if !$0 { model.cancelDiscard() } })
  }

  /// Presents the removal question while a host waits.
  private var removalBinding: Binding<Bool> {
    Binding(
      get: { model.pendingRemoval != nil },
      set: { if !$0 { model.cancelRemoval() } })
  }

  /// The banner's text and its buttons.
  private func bannerView(_ banner: SettingsModel.HostListBanner) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: bannerSymbol(banner))
        .foregroundStyle(bannerTint(banner))
        .accessibilityHidden(true)
      Text(banner.text)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      switch banner {
      case .invalidFile(_, consented: false):
        Button("Replace…") { isConfirmingReplace = true }
      case .fileChanged(consented: false):
        Button("Reload") { Task { await model.reloadHosts() } }
        Button("Replace…") { isConfirmingReplace = true }
      case .unreadable:
        Button("Try again") { Task { await model.reloadHosts() } }
      case .examples, .invalidFile, .fileChanged:
        EmptyView()
      }
    } // End of HStack holding the banner
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(bannerTint(banner).opacity(0.1))
  } // End of func bannerView(_:)

  /// The banner's symbol.
  private func bannerSymbol(_ banner: SettingsModel.HostListBanner) -> String {
    if case .examples = banner { return "info.circle.fill" }
    return "exclamationmark.triangle.fill"
  }

  /// The banner's color.
  private func bannerTint(_ banner: SettingsModel.HostListBanner) -> Color {
    if case .examples = banner { return .blue }
    return .orange
  }

  /// What the editor's side shows with no host selected.
  private var emptyEditor: some View {
    VStack(spacing: 6) {
      Image(systemName: "desktopcomputer")
        .font(.title2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("No host selected")
        .font(.headline)
      NoteText(text: "Add a host with the + button below the list.")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  } // End of var emptyEditor
}

/// The host list: each host's name, mode and status, with Add and Remove below.
struct HostListColumn: View {
  /// The model shown.
  let model: SettingsModel

  /// The rows and the buttons.
  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(spacing: 2) {
          ForEach(model.hostRows) { row in
            HostRowView(row: row) { model.select(row.id) }
          }
        }
        .padding(6)
      }
      Divider()
      HStack(spacing: 2) {
        Button {
          model.addHost()
        } label: {
          Image(systemName: "plus")
            .frame(width: 20, height: 18)
        }
        .help("Add host")
        .accessibilityLabel("Add host")
        .disabled(!model.isEditable)
        Button {
          model.requestRemoval()
        } label: {
          Image(systemName: "minus")
            .frame(width: 20, height: 18)
        }
        .help("Remove host…")
        .accessibilityLabel("Remove host")
        .disabled(!model.isEditable || model.draft == nil || model.draft?.isNew == true)
        Spacer()
      } // End of HStack holding the buttons
      .buttonStyle(.borderless)
      .padding(6)
    } // End of VStack holding the column
    .background(Color(nsColor: .controlBackgroundColor))
  } // End of var body
}

/// One host in the list.
struct HostRowView: View {
  /// The row's content.
  let row: SettingsModel.HostRow
  /// Selects the row.
  let select: () -> Void

  /// Name and detail on the left, the status on the right.
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      VStack(alignment: .leading, spacing: 1) {
        Text(row.name)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(row.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      if let status = row.status {
        StatusDot(tone: status.tone)
          .help(status.text)
      }
    } // End of HStack holding the row
    .padding(.vertical, 4)
    .padding(.horizontal, 6)
    .background(
      RoundedRectangle(cornerRadius: 5)
        .fill(row.isSelected ? Color.accentColor.opacity(0.22) : .clear)
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: select)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.name)
    .accessibilityValue([row.detail, row.status?.text].compactMap { $0 }.joined(separator: ", "))
    .accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : [.isButton])
    .accessibilityAction(.default, select)
  } // End of var body
}
