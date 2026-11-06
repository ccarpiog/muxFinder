import AppKit
import SwiftUI

/// The Directory field row's drop target (PLAN.md D34, Phase I-9b): an invisible AppKit view
/// laid over the field and its list button (`DirectoryFieldView`), handing every drag over the
/// row to the model (`FolderDropView`).
struct DirectoryDropZone: NSViewRepresentable {
  /// The model whose Directory field a drop fills.
  let model: AppModel

  /// Creates the drop target.
  func makeNSView(context: Context) -> FolderDropView {
    FolderDropView(model: model)
  }

  /// Keeps the drop target on the current model.
  func updateNSView(_ nsView: FolderDropView, context: Context) {
    nsView.model = model
  }
}

/// The invisible view over New session's Directory field and its list button that takes drags
/// (PLAN.md D34, Phase I-9b). Only one folder dragged from Finder is taken: the field shows a
/// highlight while it hovers (`AppModel.directoryDragMoved(_:)`) and its drop fills the field
/// as a pick (`AppModel.dropOnDirectoryField(_:)`, `FolderDrop`). Every other drag over the row
/// (a file, a package, several items, text, a web link, a file promise) is refused: the drag
/// shows no "+".
///
/// - **Ahead of the field editor:** AppKit gives a drag to the frontmost view under the pointer
///   registered for one of its types, and this view lies in front of the field. It registers
///   for every type a text field's field editor accepts (and file URLs and promises), so while
///   the Directory field is being edited its field editor never becomes the drop target and
///   never inserts a path, a file name or other text of its own at the caret.
/// - **Clicks go through:** `hitTest(_:)` answers no view, so clicks, the text cursor and text
///   selection reach the field and the button as before; the view takes no focus and is not in
///   the key view loop.
/// - **Reads only the dropped URL's own resource values** (directory, package; a Finder file
///   reference URL resolved to its path), never the folder's contents, and logs nothing.
final class FolderDropView: NSView {
  /// The types the view registers for beyond a text view's own: file URLs and file promises,
  /// links and plain text (so it is the drop target for anything the field editor would take).
  static let baseDraggedTypes: [NSPasteboard.PasteboardType] =
    [
      .fileURL, .URL, .string, .rtf, .rtfd, .html, .tiff, .png, .pdf, .color, .font, .ruler,
      .fileContents, .tabularText, NSPasteboard.PasteboardType("NSFilenamesPboardType"),
    ] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
  /// The types a text view accepts as a drag's destination (measured once).
  static let textViewDraggedTypes = NSTextView().acceptableDragTypes

  /// The model told about drags.
  weak var model: AppModel?
  /// The current drag's items, read once when it entered.
  private var dragItems: [FolderDrop.Item]?

  /// A drop target for `model`'s Directory field.
  init(model: AppModel?) {
    self.model = model
    super.init(frame: .zero)
    registerForDraggedTypes(Self.draggedTypes(in: nil))
  }

  /// Not used: the view is only created in code.
  required init?(coder: NSCoder) {
    return nil
  }

  /// Every type the view registers for in `window`: `baseDraggedTypes`, those a text view
  /// accepts, and those the window's own field editor accepts, once in a window.
  static func draggedTypes(in window: NSWindow?) -> [NSPasteboard.PasteboardType] {
    var types = baseDraggedTypes + textViewDraggedTypes
    if let editor = window?.fieldEditor(true, for: nil) as? NSTextView {
      types += editor.acceptableDragTypes
    }
    var seen = Set<NSPasteboard.PasteboardType>()
    return types.filter { seen.insert($0).inserted }
  }

  /// Registers for the types of its new window's field editor too.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    unregisterDraggedTypes()
    registerForDraggedTypes(Self.draggedTypes(in: window))
  }

  /// No view: clicks go on to the field and the button under it (drags do not use this).
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  /// Not an accessibility element: VoiceOver hears the field's hint instead.
  override func isAccessibilityElement() -> Bool {
    false
  }

  // MARK: - Dragging destination

  /// A drag entered the row.
  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    dragEntered(sender.draggingPasteboard, allowed: sender.draggingSourceOperationMask)
  }

  /// The drag moved over the row.
  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    if dragItems == nil { dragItems = Self.items(on: sender.draggingPasteboard) }
    return dragMoved(allowed: sender.draggingSourceOperationMask)
  }

  /// The drag left the row.
  override func draggingExited(_ sender: (any NSDraggingInfo)?) {
    dragEnded()
  }

  /// Whether the drop is taken (refused ones slide back).
  override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let items = dragItems ?? Self.items(on: sender.draggingPasteboard)
    return model?.directoryDropOutcome(items).text != nil
  }

  /// The drop.
  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    drop(sender.draggingPasteboard)
  }

  /// The drop is over.
  override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
    dragEnded()
  }

  /// The drag ended, wherever it was dropped.
  override func draggingEnded(_ sender: any NSDraggingInfo) {
    dragEnded()
  }

  // MARK: - The decisions (also driven by the tests)

  /// A drag carrying `pasteboard` entered, the source allowing `allowed`: its items are read
  /// once (`items(on:)`) and the model decides (`dragMoved(allowed:)`).
  func dragEntered(_ pasteboard: NSPasteboard, allowed: NSDragOperation) -> NSDragOperation {
    dragItems = Self.items(on: pasteboard)
    return dragMoved(allowed: allowed)
  }

  /// The model's answer for the current drag (its highlight follows): the operation shown, or
  /// none (no "+") when the drop would not fill the field.
  func dragMoved(allowed: NSDragOperation) -> NSDragOperation {
    let fills = model?.directoryDragMoved(dragItems ?? []) ?? false
    return Self.operation(fills: fills, allowed: allowed)
  }

  /// The drop of `pasteboard`'s items (the ones read when the drag entered): the model fills
  /// the field for one folder and refuses anything else. Returns whether the field was filled.
  func drop(_ pasteboard: NSPasteboard) -> Bool {
    let items = dragItems ?? Self.items(on: pasteboard)
    dragItems = nil
    return model?.dropOnDirectoryField(items) ?? false
  }

  /// The drag left or ended: the highlight goes.
  func dragEnded() {
    dragItems = nil
    model?.directoryDragEnded()
  }

  /// The operation a drop that `fills` the field shows, from those the source allows: copy (the
  /// "+"), else generic, else link; never move or delete; none when it does not fill it.
  static func operation(fills: Bool, allowed: NSDragOperation) -> NSDragOperation {
    guard fills else { return [] }
    return [NSDragOperation.copy, .generic, .link].first { allowed.contains($0) } ?? []
  }

  // MARK: - Reading the drag

  /// The items on a drag's `pasteboard`, as `FolderDrop` takes them.
  static func items(on pasteboard: NSPasteboard) -> [FolderDrop.Item] {
    (pasteboard.pasteboardItems ?? []).map(item(from:))
  }

  /// One pasteboard item: a file URL (a Finder file reference URL resolved to its path) with
  /// its own directory and package resource values, else its link if it has one, else no URL.
  static func item(from item: NSPasteboardItem) -> FolderDrop.Item {
    guard let text = item.string(forType: .fileURL), let dropped = NSURL(string: text),
      dropped.isFileURL
    else {
      return FolderDrop.Item(url: item.string(forType: .URL).flatMap { URL(string: $0) })
    }
    let url = (dropped.filePathURL ?? dropped as URL)
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
    return FolderDrop.Item(
      url: url, isDirectory: values?.isDirectory == true, isPackage: values?.isPackage == true)
  } // End of static func item(from:)
}
