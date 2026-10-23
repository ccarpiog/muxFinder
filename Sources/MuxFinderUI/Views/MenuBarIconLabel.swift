import AppKit
import SwiftUI

/// The menu bar icon (PLAN.md D28): muxFinder's split-window mark as a template image, read
/// from the app bundle's `Contents/Resources/MenuBarIcon.png` and its `@2x` and `@3x` files
/// (`scripts/build-app.sh` copies them from the repository's `Resources/`). An unbundled run
/// (`swift run`) has no such file, so the label falls back to the SF Symbol `fallbackSymbol`.
public enum MenuBarIcon {
  /// The resource name of the template PNGs.
  public static let resourceName = "MenuBarIcon"

  /// The SF Symbol shown when the bundle has no menu bar icon.
  public static let fallbackSymbol = "terminal"

  /// The icon from `bundle` as a template image (18 × 18 pt, one representation per PNG), or
  /// nil when the bundle has no `MenuBarIcon.png`.
  public static func image(in bundle: Bundle = .main) -> NSImage? {
    guard let image = bundle.image(forResource: resourceName) else { return nil }
    image.isTemplate = true
    image.accessibilityDescription = "muxFinder"
    return image
  }
}

/// The menu bar extra's label: a `Label` titled "muxFinder" (the menu bar shows only its icon;
/// the title is what accessibility reads) whose icon is `MenuBarIcon`, or the SF Symbol
/// fallback when the bundle has none.
public struct MenuBarIconLabel: View {
  /// The template image, or nil for the SF Symbol fallback.
  private let image: NSImage?

  /// Reads the icon from `bundle` once.
  public init(bundle: Bundle = .main) {
    image = MenuBarIcon.image(in: bundle)
  }

  /// The label.
  public var body: some View {
    Label {
      Text("muxFinder")
    } icon: {
      if let image {
        Image(nsImage: image)
      } else {
        Image(systemName: MenuBarIcon.fallbackSymbol)
      }
    }
  }
}
