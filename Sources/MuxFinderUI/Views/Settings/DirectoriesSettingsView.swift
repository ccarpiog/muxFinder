import MuxFinderCore
import SwiftUI

/// The Directories tab (PLAN.md D31): New session's saved directories, shared by every host,
/// with their notice (an unusable file offers no edit), the list with move up, move down and
/// remove per entry, "Add" checked inline, and "Revert" and "Save" (D23's pattern).
struct DirectoriesSettingsView: View {
  /// The model shown.
  @Bindable var model: SettingsModel

  /// The section.
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        SettingsSection(title: "Saved directories") {
          NoteText(
            text: "New session offers these directories for every host, below that host's "
              + "recent directories and above the folders its sessions started in. A path that "
              + "starts with ~/ is in the home folder of the host the session is created on.")
          if let notice = model.directoryNotice {
            noticeView(notice)
          }
          entryList
          addRow
          footer
        } // End of SettingsSection "Saved directories"
        SettingsSection(title: "Recent directories") {
          NoteText(
            text: "New session remembers the last \(DirectoryLists.maximumRecentCount) "
              + "directories you created sessions in on each host. Clear a host's recent "
              + "directories from New session's directory list.")
        }
      } // End of VStack holding the sections
      .padding(14)
    }
  } // End of var body

  /// The notice with "Try again" when the file or the folder could not be used.
  private func noticeView(_ notice: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(notice)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      if model.offersDirectoryReload {
        Button("Try again") { Task { await model.loadDirectories() } }
      }
    } // End of HStack holding the notice
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
    .accessibilityElement(children: .contain)
  } // End of func noticeView(_:)

  /// The working copy's entries in a bordered box, or a placeholder.
  private var entryList: some View {
    let entries = model.directoryDraft
    return VStack(spacing: 0) {
      if entries.isEmpty {
        Text(
          model.areDirectoriesEditable
            ? "No saved directories yet." : "No saved directories to show."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
      } else {
        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
          entryRow(entry, at: index, count: entries.count)
          if index < entries.count - 1 { Divider() }
        }
      }
    } // End of VStack holding the entries
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
  } // End of var entryList

  /// One entry: the path, shortened in the middle (the full path as help and label), and its
  /// buttons.
  private func entryRow(_ entry: String, at index: Int, count: Int) -> some View {
    HStack(spacing: 6) {
      Text(entry)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(entry)
        .accessibilityLabel(entry)
        .frame(maxWidth: .infinity, alignment: .leading)
      Group {
        Button {
          model.moveDirectory(at: index, by: -1)
        } label: {
          Image(systemName: "arrow.up")
        }
        .help("Move up")
        .accessibilityLabel("Move \(entry) up")
        .disabled(!model.areDirectoriesEditable || index == 0)
        Button {
          model.moveDirectory(at: index, by: 1)
        } label: {
          Image(systemName: "arrow.down")
        }
        .help("Move down")
        .accessibilityLabel("Move \(entry) down")
        .disabled(!model.areDirectoriesEditable || index == count - 1)
        Button {
          model.removeDirectory(at: index)
        } label: {
          Image(systemName: "minus.circle")
        }
        .help("Remove")
        .accessibilityLabel("Remove \(entry)")
        .disabled(!model.areDirectoriesEditable)
      } // End of Group holding the row's buttons
      .buttonStyle(.borderless)
    } // End of HStack holding the row
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
  } // End of func entryRow(_:at:count:)

  /// The "Add" field and button, with the field's issue under them.
  private var addRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        TextField("Directory to add", text: $model.newDirectory, prompt: Text("~/projects/site"))
          .textFieldStyle(.roundedBorder)
          .disabled(!model.areDirectoriesEditable)
          .onSubmit { model.addDirectory() }
          .accessibilityLabel("Directory to add")
        Button("Add") { model.addDirectory() }
          .disabled(!model.canAddDirectory)
      }
      if let issue = model.newDirectoryIssue {
        IssueText(text: issue)
      }
    }
  } // End of var addRow

  /// The last save's error or notice, "Revert" and "Save".
  private var footer: some View {
    HStack(spacing: 8) {
      if let error = model.directorySaveError {
        IssueText(text: error)
      } else if let notice = model.directorySaveNotice {
        NoteText(text: notice)
      } else if model.isDirectoryListDirty {
        NoteText(text: "Not saved yet.")
      }
      Spacer(minLength: 8)
      Button("Revert") { model.revertDirectories() }
        .disabled(!model.isDirectoryListDirty || model.isSavingDirectories)
      Button("Save") { Task { await model.saveDirectories() } }
        .disabled(!model.canSaveDirectories)
    } // End of HStack holding the footer
  } // End of var footer
}
