import AppKit
import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// A folder dropped from Finder onto New session's Directory field (PLAN.md D34, Phase I-9b),
/// as a pure function: exactly one folder fills the field, `~/…` under This Mac's home folder
/// by whole path components, the path standardized by its text alone; anything else is
/// refused. Every item is a plain fact: nothing is read from the disk.
@Suite("New session: the folder drop")
struct FolderDropFunctionTests {
  /// This Mac's home folder in these tests (synthetic; never the real one).
  static let home = "/Users/me"

  /// A folder item at `path` (a `file:` URL; nothing is read).
  static func folder(_ path: String) -> FolderDrop.Item {
    FolderDrop.Item(url: URL(fileURLWithPath: path), isDirectory: true)
  }

  /// The field's text a drop of `items` gives with `home`, or `nil` when refused.
  static func text(_ items: [FolderDrop.Item], home: String? = home) -> String? {
    FolderDrop.outcome(for: items, home: home).text
  }

  /// A folder under the home folder becomes `~/…`, also deep down.
  @Test func aFolderUnderHome() {
    #expect(Self.text([Self.folder("/Users/me/projects/site")]) == "~/projects/site")
    #expect(Self.text([Self.folder("/Users/me/a/b/c d/é")]) == "~/a/b/c d/é")
  }

  /// A folder elsewhere stays absolute, as dropped.
  @Test func aFolderOutsideHome() {
    #expect(Self.text([Self.folder("/opt/work")]) == "/opt/work")
    #expect(Self.text([Self.folder("/Users/bob/x")]) == "/Users/bob/x")
    #expect(Self.text([Self.folder("/Volumes/Data/me")]) == "/Volumes/Data/me")
  }

  /// The home folder itself becomes `~`.
  @Test func theHomeFolderItself() {
    #expect(Self.text([Self.folder("/Users/me")]) == "~")
    #expect(Self.text([Self.folder("/Users/me/")]) == "~")
  }

  /// A sibling that only starts like the home folder is not under it: compared by whole path
  /// components.
  @Test func aSiblingWithTheSamePrefix() {
    #expect(Self.text([Self.folder("/Users/me2")]) == "/Users/me2")
    #expect(Self.text([Self.folder("/Users/me2/projects")]) == "/Users/me2/projects")
    #expect(Self.text([Self.folder("/Users/meadow")]) == "/Users/meadow")
  }

  /// A file is refused.
  @Test func aFileIsRefused() {
    let file = FolderDrop.Item(url: URL(fileURLWithPath: "/Users/me/notes.txt"))
    #expect(FolderDrop.outcome(for: [file], home: Self.home) == .refused(.notAFolder))
  }

  /// A package (an `.app`, another bundle) is refused like a file, as Finder shows it.
  @Test func aPackageIsRefused() {
    let app = FolderDrop.Item(
      url: URL(fileURLWithPath: "/Applications/Tool.app"), isDirectory: true, isPackage: true)
    #expect(FolderDrop.outcome(for: [app], home: Self.home) == .refused(.package))
  }

  /// Two folders, or two items of any kind, are refused.
  @Test func twoFoldersAreRefused() {
    let two = [Self.folder("/Users/me/a"), Self.folder("/Users/me/b")]
    #expect(FolderDrop.outcome(for: two, home: Self.home) == .refused(.severalItems))
    let mixed = [Self.folder("/Users/me/a"), FolderDrop.Item(url: nil)]
    #expect(FolderDrop.outcome(for: mixed, home: Self.home) == .refused(.severalItems))
  }

  /// Nothing dropped is refused.
  @Test func zeroItemsAreRefused() {
    #expect(FolderDrop.outcome(for: [], home: Self.home) == .refused(.noItems))
  }

  /// A URL of another kind (a web link), an item with no URL (text, a promise without a URL)
  /// and a `file:` URL without an absolute path are refused, whatever their resource values.
  @Test func aNonFileURLIsRefused() {
    let link = FolderDrop.Item(url: URL(string: "https://example.com/folder/"), isDirectory: true)
    #expect(!link.isFileURL)
    #expect(FolderDrop.outcome(for: [link], home: Self.home) == .refused(.notAFileURL))
    let none = FolderDrop.Item(url: nil, isDirectory: true)
    #expect(FolderDrop.outcome(for: [none], home: Self.home) == .refused(.notAFileURL))
    let relative = FolderDrop.Item(url: URL(string: "file:projects"), isDirectory: true)
    #expect(FolderDrop.outcome(for: [relative], home: Self.home) == .refused(.notAFileURL))
  } // End of func aNonFileURLIsRefused()

  /// A trailing slash, in the dropped URL or in the home folder, is dropped.
  @Test func aTrailingSlashIsDropped() throws {
    #expect(Self.text([Self.folder("/Users/me/projects/")]) == "~/projects")
    #expect(Self.text([Self.folder("/opt/work/")]) == "/opt/work")
    #expect(Self.text([Self.folder("/Users/me/projects")], home: "/Users/me/") == "~/projects")
    #expect(Self.text([Self.folder("/Users/me/projects")], home: "/Users/me//") == "~/projects")
    let url = try #require(URL(string: "file:///opt/work/"))
    #expect(Self.text([FolderDrop.Item(url: url, isDirectory: true)]) == "/opt/work")
  }

  /// A path needing no change is used as it is, with or without a home folder; with none, or
  /// the root folder as the home folder, no path is shortened.
  @Test func aPathNeedingNoChange() {
    #expect(Self.text([Self.folder("/srv/data")]) == "/srv/data")
    #expect(Self.text([Self.folder("/srv/data")], home: nil) == "/srv/data")
    #expect(Self.text([Self.folder("/Users/me/projects")], home: nil) == "/Users/me/projects")
    #expect(Self.text([Self.folder("/Users/me/projects")], home: "/") == "/Users/me/projects")
    #expect(Self.text([Self.folder("/Users/me/projects")], home: "") == "/Users/me/projects")
    #expect(Self.text([Self.folder("/")]) == "/")
  }

  /// The path is standardized by its text alone (repeated slashes, `.` and `..`), percent
  /// escapes are decoded, and nothing is resolved: a path under `/tmp` stays there (the disk
  /// would say `/private/tmp`), and a folder that does not exist is taken as dropped.
  @Test func thePathIsStandardizedByItsTextAlone() throws {
    #expect(Self.text([Self.folder("/Users/me//projects/./site/../api")]) == "~/projects/api")
    #expect(Self.text([Self.folder("/Users/me/../me/x")]) == "~/x")
    #expect(Self.text([Self.folder("/../../opt")]) == "/opt")
    let missing = "/tmp/muxfinder-test-missing-folder"
    #expect(Self.text([Self.folder(missing)]) == missing)
    let spaced = try #require(URL(string: "file:///Users/me/My%20Projects/"))
    #expect(Self.text([FolderDrop.Item(url: spaced, isDirectory: true)]) == "~/My Projects")
    #expect(FolderDrop.standardizedPath("/a//b/./c/") == "/a/b/c")
    #expect(FolderDrop.standardizedPath("/") == "/")
  } // End of func thePathIsStandardizedByItsTextAlone()
}

/// The folder drop in the model (PLAN.md D34, Phase I-9b): the fill is a pick (the directory
/// list closes and does not reopen, nothing is announced), it replaces the field's text and is
/// then checked like typed text, for every host; a refused drop changes nothing; the highlight
/// follows the drag; a closed window or a busy draft takes no drop.
@Suite("New session: the folder drop in the model")
@MainActor
struct FolderDropModelTests {
  /// Shorthand.
  typealias Fixtures = PreviewFixtures

  /// A fixture model showing New session for `host` with `directory` typed, over the gallery's
  /// lists and sessions, its list closed; This Mac's home folder is `/Users/example`.
  static func model(host: HostConfig = Fixtures.neptuno, directory: String = "") -> AppModel {
    DirectoryFilterModelTests.model(host: host, directory: directory)
  }

  /// A folder item at `path`.
  static func folder(_ path: String) -> [FolderDrop.Item] {
    [FolderDropFunctionTests.folder(path)]
  }

  /// The drop fills the field with `~/…` and does not open the list, though the same text typed
  /// would (it matches saved entries): the fill is no edit, so nothing is announced either.
  @Test func theFillDoesNotOpenTheList() {
    let typed = Self.model()
    typed.newSessionDraft.directory = "~/projects"
    #expect(typed.directoryPicker.opening == .typing, "typed, the same text opens the list")
    let model = Self.model()
    let recorder = AnnouncementRecorder()
    model.announce = { recorder.said.append($0) }
    #expect(model.dropOnDirectoryField(Self.folder("/Users/example/projects")))
    #expect(model.newSessionDraft.directory == "~/projects")
    #expect(!model.directoryPicker.isOpen)
    #expect(recorder.said.isEmpty)
    #expect(model.newSessionDraft.directoryIssue == nil)
    #expect(model.isNewSessionShown)
  } // End of func theFillDoesNotOpenTheList()

  /// A list open by the button, or by the typing, closes at the drop and does not reopen.
  @Test func theFillClosesAnOpenList() {
    let model = Self.model()
    model.toggleDirectoryList()
    #expect(model.directoryPicker.opening == .request)
    #expect(model.dropOnDirectoryField(Self.folder("/opt/work")))
    #expect(model.newSessionDraft.directory == "/opt/work")
    #expect(!model.directoryPicker.isOpen)

    model.newSessionDraft.directory = "proj"
    #expect(model.directoryPicker.opening == .typing)
    #expect(model.dropOnDirectoryField(Self.folder("/Users/example/projects")))
    #expect(!model.directoryPicker.isOpen)
    #expect(model.directoryPicker == DirectoryPickerState())
  } // End of func theFillClosesAnOpenList()

  /// The drop replaces whatever the field held, whole.
  @Test func theFillReplacesTheFieldsText() {
    let model = Self.model(directory: "~/half typed/path")
    #expect(model.dropOnDirectoryField(Self.folder("/Users/example")))
    #expect(model.newSessionDraft.directory == "~")
    #expect(model.dropOnDirectoryField(Self.folder("/Volumes/Data/archive/")))
    #expect(model.newSessionDraft.directory == "/Volumes/Data/archive")
  }

  /// A refused drop (a file, a package, two folders, text) leaves the field, the list and the
  /// highlight as they were.
  @Test func aRefusedDropChangesNothing() {
    let model = Self.model(directory: "~/notes")
    model.toggleDirectoryList()
    let refused: [[FolderDrop.Item]] = [
      [FolderDrop.Item(url: URL(fileURLWithPath: "/Users/example/a.txt"))],
      [
        FolderDrop.Item(
          url: URL(fileURLWithPath: "/Applications/Tool.app"), isDirectory: true, isPackage: true)
      ],
      Self.folder("/a") + Self.folder("/b"),
      [FolderDrop.Item(url: nil)],
      [],
    ]
    for items in refused {
      #expect(!model.directoryDragMoved(items))
      #expect(!model.isDirectoryDropTargeted)
      #expect(!model.dropOnDirectoryField(items))
      #expect(model.newSessionDraft.directory == "~/notes")
      #expect(model.directoryPicker.opening == .request)
    } // End of loop over the refused drops
  } // End of func aRefusedDropChangesNothing()

  /// The highlight shows while a folder hovers, goes for a drag that would be refused, when the
  /// drag leaves or ends, at the drop, and when the window closes.
  @Test func theHighlightFollowsTheDrag() {
    let model = Self.model()
    #expect(!model.isDirectoryDropTargeted)
    #expect(model.directoryDragMoved(Self.folder("/opt/work")))
    #expect(model.isDirectoryDropTargeted)
    #expect(!model.directoryDragMoved([]))
    #expect(!model.isDirectoryDropTargeted)
    model.directoryDragMoved(Self.folder("/opt/work"))
    model.directoryDragEnded()
    #expect(!model.isDirectoryDropTargeted)
    model.directoryDragMoved(Self.folder("/opt/work"))
    model.dropOnDirectoryField(Self.folder("/opt/work"))
    #expect(!model.isDirectoryDropTargeted)
    model.directoryDragMoved(Self.folder("/opt/work"))
    model.closeNewSession()
    #expect(!model.isDirectoryDropTargeted)
  } // End of func theHighlightFollowsTheDrag()

  /// A closed window or a busy draft (its fields off) takes no drop and shows no highlight.
  @Test func aClosedWindowOrABusyDraftTakesNoDrop() {
    let busy = Self.model()
    for state in [NewSessionDraft.State.creating, .findingExisting] {
      busy.newSessionDraft.state = state
      #expect(busy.directoryDropOutcome(Self.folder("/opt/work")) == .refused(.unavailable))
      #expect(!busy.directoryDragMoved(Self.folder("/opt/work")))
      #expect(!busy.dropOnDirectoryField(Self.folder("/opt/work")))
      #expect(busy.newSessionDraft.directory.isEmpty)
    }
    let closed = Self.model()
    closed.closeNewSession()
    #expect(closed.directoryDropOutcome(Self.folder("/opt/work")) == .refused(.unavailable))
    #expect(!closed.dropOnDirectoryField(Self.folder("/opt/work")))
    #expect(!closed.isDirectoryDropTargeted)
  } // End of func aClosedWindowOrABusyDraftTakesNoDrop()

  /// The drop works for an SSH host too (the same `~/…`, from This Mac's home folder), and the
  /// text then goes through D31's checks like typed text: a folder name with a line break
  /// fills the field, which then shows its issue and creates nothing.
  @Test func everyHostAndTheDraftsChecks() {
    let model = Self.model(host: Fixtures.saturno)
    #expect(model.dropOnDirectoryField(Self.folder("/Users/example/projects/site")))
    #expect(model.newSessionDraft.directory == "~/projects/site")
    #expect(model.newSessionDraft.directoryIssue == nil)
    #expect(model.dropOnDirectoryField(Self.folder("/Users/example/bad\nname")))
    #expect(model.newSessionDraft.directory == "~/bad\nname")
    #expect(model.newSessionDraft.directoryIssue != nil)
  }

  /// The model's `~` rule uses This Mac's home folder as I-7's does (`thisMacHome`); with none
  /// known every path stays absolute.
  @Test func theHomeFolderIsTheDirectoryLists() {
    var fixture = AttachFixtures.newSession
    fixture.homeDirectory = nil
    let model = AppModel(fixture: fixture)
    #expect(model.thisMacHome == nil)
    #expect(model.dropOnDirectoryField(Self.folder("/Users/example/projects")))
    #expect(model.newSessionDraft.directory == "/Users/example/projects")
  }

  /// The gallery's drop highlight state, and the Directory field's accessibility hint, which
  /// mentions dropping a folder from Finder.
  @Test func theGalleryStateAndTheHint() {
    let model = AppModel(fixture: AttachFixtures.newSessionFolderDrag)
    #expect(model.isDirectoryDropTargeted && model.isNewSessionShown)
    #expect(!AppModel(fixture: AttachFixtures.newSession).isDirectoryDropTargeted)
    #expect(DirectoryFieldView.hint.contains("Dropping a folder from Finder here"))
    #expect(DirectoryFieldView.hint.hasPrefix("Typing filters the list"))
  }
}

/// The Directory field's drop target in the real New session window (PLAN.md D34, Phase
/// I-9b), never shown: an AppKit view in front of the field and its button, so AppKit gives it
/// every drag over the row before the field editor (which would insert text of its own at the
/// caret), whether or not the field is edited, while clicks go through to the field; and its
/// decisions over a private pasteboard holding real folders and files in a private temporary
/// folder. No window appears, nothing takes the key focus, the general pasteboard is untouched.
@Suite("New session: the Directory field's drop target", .serialized)
@MainActor
struct FolderDropTargetTests {
  /// Shorthand.
  typealias TabOrder = NewSessionTabOrderTests

  /// `view` and its superviews, nearest first.
  static func chain(_ view: NSView) -> [NSView] {
    var views = [view]
    while let parent = views.last?.superview { views.append(parent) }
    return views
  }

  /// Whether `front` is in front of `back` in their window: under their closest common
  /// ancestor, its branch comes later among the subviews, so AppKit, which looks for a drag's
  /// destination frontmost first, reaches it first.
  static func isInFront(_ front: NSView, of back: NSView) -> Bool {
    let fronts = chain(front)
    let backs = chain(back)
    guard let frontIndex = fronts.firstIndex(where: { view in backs.contains { $0 === view } }),
      frontIndex > 0, let backIndex = backs.firstIndex(where: { $0 === fronts[frontIndex] }),
      backIndex > 0
    else { return false }
    let common = fronts[frontIndex]
    guard let frontBranch = common.subviews.firstIndex(where: { $0 === fronts[frontIndex - 1] }),
      let backBranch = common.subviews.firstIndex(where: { $0 === backs[backIndex - 1] })
    else { return false }
    return frontBranch > backBranch
  } // End of static func isInFront(_:of:)

  /// The window's view under `view`'s centre for a click (`hitTest(_:)` from the content view).
  static func clickTarget(atCentreOf view: NSView, in window: NSWindow) -> NSView? {
    guard let content = window.contentView, let frame = content.superview else { return nil }
    let centre = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    return content.hitTest(frame.convert(centre, from: nil))
  }

  /// In front of the Directory field and covering it and its button, edited or not; clicks go
  /// through to the field (or its field editor); registered for file URLs and every type the
  /// field's own field editor takes; never focused, in the key view loop, or seen by VoiceOver.
  @Test func theDropTargetCoversTheFieldAheadOfItsFieldEditor() async throws {
    _ = NSApplication.shared
    let model = AppModel(fixture: AttachFixtures.newSession)
    let host = NewSessionWindowHost(model: model)
    defer { host.hide() }
    await TabOrder.settle(host)
    let window = host.panel
    let directory = try TabOrder.field(DirectoryFieldView.prompt, in: window)
    let targets = KeyViewLoopReport.subviews(of: window.contentView).compactMap {
      $0 as? FolderDropView
    }
    #expect(targets.count == 1)
    let target = try #require(targets.first)
    let targetFrame = target.convert(target.bounds, to: nil)
    #expect(targetFrame.contains(directory.convert(directory.bounds, to: nil)))
    #expect(Self.isInFront(target, of: directory))
    #expect(
      Self.clickTarget(atCentreOf: directory, in: window)?.isDescendant(of: directory) == true)
    #expect(target.hitTest(CGPoint(x: 1, y: 1)) == nil)
    #expect(!target.acceptsFirstResponder && !target.canBecomeKeyView)
    #expect(!target.isAccessibilityElement())
    #expect(target.registeredDraggedTypes.contains(.fileURL))

    #expect(window.makeFirstResponder(directory))
    let editor = try #require(window.firstResponder as? NSTextView)
    #expect(editor.isFieldEditor && editor.isDescendant(of: directory))
    #expect(Self.isInFront(target, of: editor))
    #expect(!editor.registeredDraggedTypes.isEmpty)
    let missing = Set(editor.registeredDraggedTypes).subtracting(target.registeredDraggedTypes)
    #expect(missing.isEmpty, "the field editor would take \(missing)")
    #expect(
      Self.clickTarget(atCentreOf: directory, in: window)?.isDescendant(of: directory) == true)
    _ = window.makeFirstResponder(nil)
  } // End of func theDropTargetCoversTheFieldAheadOfItsFieldEditor()

  /// A private temporary folder, named by its real path (`/private/var/…`, as a drag's
  /// pasteboard gives it), with a folder, a second folder, a file and an `.app` folder in it;
  /// removed by the caller.
  static func makeFolders() throws -> URL {
    let temporary = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(temporary) }
    let root = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
      .appendingPathComponent("muxfinder-drop-\(UUID().uuidString)", isDirectory: true)
    let files = FileManager.default
    for name in ["folder", "other", "Tool.app"] {
      try files.createDirectory(
        at: root.appendingPathComponent(name, isDirectory: true),
        withIntermediateDirectories: true)
    }
    try Data("x".utf8).write(to: root.appendingPathComponent("file.txt"))
    return root
  } // End of static func makeFolders()

  /// A private pasteboard holding `objects` (never the general one).
  static func pasteboard(_ objects: [any NSPasteboardWriting]) -> NSPasteboard {
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.clearContents()
    pasteboard.writeObjects(objects)
    return pasteboard
  }

  /// Through the drop target's own decisions over private pasteboards: one folder (also as a
  /// Finder file reference URL) shows the "+" and the highlight and fills the field with `~/…`
  /// (This Mac's home folder being the temporary folder here); a file, an `.app`, two folders,
  /// text and a web link show none, leave no highlight and fill nothing; a source allowing only
  /// a move is refused too.
  @Test func theDropTargetsDecisions() throws {
    let root = try Self.makeFolders()
    defer { try? FileManager.default.removeItem(at: root) }
    var fixture = AttachFixtures.newSession
    fixture.homeDirectory = root.path(percentEncoded: false)
    let model = AppModel(fixture: fixture)
    let target = FolderDropView(model: model)
    let folder = root.appendingPathComponent("folder", isDirectory: true)
    // `NSURL`'s own file reference URL: bridged to `URL`, it would become a path URL again.
    let referenceObject = NSURL(fileURLWithPath: folder.path(percentEncoded: false))
      .perform(#selector(NSURL.fileReferenceURL))?.takeUnretainedValue()
    let reference = try #require((referenceObject as? NSURL)?.absoluteString)
    #expect(reference.contains("/.file/id="), "Finder's spelling")
    let referenceItem = NSPasteboardItem()
    referenceItem.setString(reference, forType: .fileURL)
    let drags: [[any NSPasteboardWriting]] = [[folder as NSURL], [referenceItem]]
    for objects in drags {
      let pasteboard = Self.pasteboard(objects)
      defer { pasteboard.releaseGlobally() }
      #expect(target.dragEntered(pasteboard, allowed: .every) == .copy)
      #expect(model.isDirectoryDropTargeted)
      #expect(target.dragMoved(allowed: .every) == .copy)
      #expect(target.drop(pasteboard))
      #expect(model.newSessionDraft.directory == "~/folder")
      #expect(!model.isDirectoryDropTargeted)
      model.newSessionDraft.directory = ""
    } // End of loop over the folder's two spellings

    let refused: [[any NSPasteboardWriting]] = [
      [root.appendingPathComponent("file.txt") as NSURL],
      [root.appendingPathComponent("Tool.app", isDirectory: true) as NSURL],
      [folder as NSURL, root.appendingPathComponent("other", isDirectory: true) as NSURL],
      ["~/folder" as NSString],
      [NSURL(string: "https://example.com/folder/")!],
    ]
    for objects in refused {
      let pasteboard = Self.pasteboard(objects)
      defer { pasteboard.releaseGlobally() }
      #expect(target.dragEntered(pasteboard, allowed: .every) == [])
      #expect(!model.isDirectoryDropTargeted)
      #expect(!target.drop(pasteboard))
      #expect(model.newSessionDraft.directory.isEmpty)
    } // End of loop over the refused drags

    let moveOnly = Self.pasteboard([folder as NSURL])
    defer { moveOnly.releaseGlobally() }
    #expect(target.dragEntered(moveOnly, allowed: .move) == [])
    target.dragEnded()
    #expect(!model.isDirectoryDropTargeted)
  } // End of func theDropTargetsDecisions()

  /// What the drag's pasteboard is read as: a folder with its resource values (a package
  /// marked), a file, a link with no file URL, text with no URL, one item each.
  @Test func readingTheDrag() throws {
    let root = try Self.makeFolders()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Tool.app", isDirectory: true)
    let pasteboard = Self.pasteboard([
      root.appendingPathComponent("folder", isDirectory: true) as NSURL, app as NSURL,
      root.appendingPathComponent("file.txt") as NSURL,
    ])
    defer { pasteboard.releaseGlobally() }
    let items = FolderDropView.items(on: pasteboard)
    #expect(items.map(\.isDirectory) == [true, true, false])
    #expect(items.map(\.isPackage) == [false, true, false])
    #expect(items.allSatisfy { $0.isFileURL })
    let rootPath = FolderDrop.standardizedPath(root.path(percentEncoded: false))
    #expect(items.first?.url?.path(percentEncoded: false).hasPrefix(rootPath + "/") == true)
    let link = Self.pasteboard([NSURL(string: "https://example.com/x")!])
    defer { link.releaseGlobally() }
    #expect(FolderDropView.items(on: link).map(\.url) == [URL(string: "https://example.com/x")])
    #expect(FolderDropView.items(on: link).map(\.isFileURL) == [false])
    let text = Self.pasteboard(["/Users/example" as NSString])
    defer { text.releaseGlobally() }
    #expect(FolderDropView.items(on: text) == [FolderDrop.Item(url: nil)])
  } // End of func readingTheDrag()

  /// The operation shown: copy (the "+"), else generic, else link, from those the source
  /// allows; never move or delete; none when the drop would not fill the field.
  @Test func theOperationShown() {
    typealias View = FolderDropView
    #expect(View.operation(fills: true, allowed: .every) == .copy)
    #expect(View.operation(fills: true, allowed: [.generic, .link]) == .generic)
    #expect(View.operation(fills: true, allowed: .link) == .link)
    #expect(View.operation(fills: true, allowed: [.move, .delete]) == [])
    #expect(View.operation(fills: false, allowed: .every) == [])
  }
}
