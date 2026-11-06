import Foundation

/// A folder dropped from Finder onto New session's Directory field (PLAN.md D34, Phase I-9b),
/// as a pure function: from the dropped items, given as plain facts (nothing is read here), and
/// This Mac's home folder, the field's new text or why the drop is refused.
///
/// - **What counts as a folder:** exactly one item, a `file:` URL with an absolute path whose
///   resource values say directory and not package. A file, a package (an `.app` or another
///   bundle, which Finder shows as a file), several items, none, an item with no URL (text, a
///   file promise without a URL) or with a URL of another kind is refused: the drag shows no
///   "+".
/// - **The path as dropped:** standardized by its text alone (empty and `.` components dropped,
///   `..` taking the component before it away, no trailing slash); no symbolic link is resolved
///   and nothing is read from the disk.
/// - **The `~` rule:** under This Mac's home folder (the one the directory list's `~` rule uses,
///   `DirectoryPickerContent.homeFolder(_:)`, PLAN.md Phase I-7), compared byte for byte by
///   whole path components, the path becomes `~/…` and the home folder itself `~`; a sibling
///   such as `<home>2`, or any other folder, stays absolute. With no home folder known, every
///   path stays absolute. The rule holds for every host: a remote host with the same layout
///   takes the same `~/…`.
///
/// The text then fills the field as a pick does (`AppModel.dropOnDirectoryField(_:)`), and the
/// draft checks it like typed text (PLAN.md D31). The path is never logged.
public enum FolderDrop {
  /// One dropped item as the drag's pasteboard gives it: its URL, if any, and the URL's own
  /// resource values (the view layer reads only those, never the folder's contents).
  public struct Item: Sendable, Hashable {
    /// The item's URL (`nil`: text, a file promise without a URL, other data).
    public var url: URL?
    /// Whether the URL's resource values say directory.
    public var isDirectory: Bool
    /// Whether the URL's resource values say package (an `.app`, another bundle).
    public var isPackage: Bool

    /// An item with `url` and its resource values.
    public init(url: URL?, isDirectory: Bool = false, isPackage: Bool = false) {
      self.url = url
      self.isDirectory = isDirectory
      self.isPackage = isPackage
    }

    /// Whether the item is a `file:` URL.
    public var isFileURL: Bool { url?.isFileURL == true }
  }

  /// Why a drop is refused (the drag shows no "+").
  public enum Refusal: Sendable, Hashable {
    /// Nothing was dropped.
    case noItems
    /// More than one item was dropped.
    case severalItems
    /// The item has no `file:` URL with an absolute path (text, a web link, a promise).
    case notAFileURL
    /// The item is a file.
    case notAFolder
    /// The item is a package, such as an `.app`.
    case package
    /// New session takes no drop now: its window is closed or its draft busy (the model's
    /// answer, `AppModel.directoryDropOutcome(_:)`).
    case unavailable
  }

  /// What a drop does.
  public enum Outcome: Sendable, Hashable {
    /// The Directory field gets this text.
    case fill(String)
    /// Nothing changes.
    case refused(Refusal)

    /// The Directory field's new text, or `nil` when refused.
    public var text: String? {
      if case .fill(let text) = self { return text }
      return nil
    }
  }

  /// What dropping `items` does with `home` as This Mac's home folder (`nil`: unknown, so no
  /// `~` rule): the Directory field's new text for exactly one folder, else the refusal.
  public static func outcome(for items: [Item], home: String?) -> Outcome {
    guard let item = items.first else { return .refused(.noItems) }
    guard items.count == 1 else { return .refused(.severalItems) }
    guard let url = item.url, url.isFileURL else { return .refused(.notAFileURL) }
    let dropped = url.path(percentEncoded: false)
    guard dropped.hasPrefix("/") else { return .refused(.notAFileURL) }
    guard item.isDirectory else { return .refused(.notAFolder) }
    guard !item.isPackage else { return .refused(.package) }
    return .fill(fieldText(forPath: standardizedPath(dropped), home: home))
  } // End of static func outcome(for:home:)

  /// `path` (absolute) standardized by its text alone: empty and `.` components dropped, `..`
  /// taking the component before it away (never above the root), no trailing slash; the
  /// components themselves are kept byte for byte. No symbolic link is resolved.
  static func standardizedPath(_ path: String) -> String {
    let slash = UInt8(ascii: "/")
    let dot = UInt8(ascii: ".")
    var components: [ArraySlice<UInt8>] = []
    for component in Array(path.utf8).split(separator: slash) {
      if component.elementsEqual([dot]) { continue }
      if component.elementsEqual([dot, dot]) {
        if !components.isEmpty { components.removeLast() }
        continue
      }
      components.append(component)
    } // End of loop over the path's components
    var bytes: [UInt8] = []
    for component in components { bytes += [slash] + component }
    return bytes.isEmpty ? "/" : String(decoding: bytes, as: UTF8.self)
  } // End of static func standardizedPath(_:)

  /// The field's text for the standardized `path`: `~` for the home folder itself, `~/…` for a
  /// path under it (by whole components, byte for byte), else `path` as it is. The home folder
  /// is the directory list's (`DirectoryPickerContent.homeFolder(_:)`), standardized the same
  /// way; none, or the root folder, turns the rule off.
  static func fieldText(forPath path: String, home: String?) -> String {
    guard let folder = DirectoryPickerContent.homeFolder(home) else { return path }
    let home = Array(standardizedPath(folder).utf8)
    let bytes = Array(path.utf8)
    let slash = UInt8(ascii: "/")
    guard home != [slash] else { return path }
    if bytes == home { return "~" }
    guard bytes.starts(with: home + [slash]) else { return path }
    return "~" + String(decoding: bytes[home.count...], as: UTF8.self)
  } // End of static func fieldText(forPath:home:)
}
