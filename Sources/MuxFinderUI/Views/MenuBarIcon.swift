import AppKit

/// The menu bar icon (PLAN.md D28): muxFinder's split-window mark as a template image, read
/// from the app bundle's `Contents/Resources/MenuBarIcon.png` and its `@2x` and `@3x` files
/// (`scripts/build-app.sh` copies them from the repository's `Resources/`). An unbundled run
/// (`swift run`) has no such file, so the status item falls back to the SF Symbol
/// `fallbackSymbol`.
public enum MenuBarIcon {
  /// The resource name of the template PNGs.
  public static let resourceName = "MenuBarIcon"

  /// The SF Symbol shown when the bundle has no menu bar icon.
  public static let fallbackSymbol = "terminal"

  /// What accessibility reads for the icon (the menu bar shows only the image).
  public static let accessibilityName = "muxFinder"

  /// The icon from `bundle` as a template image (18 × 18 pt, one representation per PNG), or
  /// nil when the bundle has no `MenuBarIcon.png`.
  public static func image(in bundle: Bundle = .main) -> NSImage? {
    guard let image = bundle.image(forResource: resourceName) else { return nil }
    image.isTemplate = true
    image.accessibilityDescription = accessibilityName
    return image
  }

  /// The status item's image: `image(in:)`, else the SF Symbol fallback, a template image
  /// either way (so the menu bar tints it for light, dark, tinted and transparent menu bars),
  /// else an empty template image.
  public static func statusItemImage(in bundle: Bundle = .main) -> NSImage {
    if let image = image(in: bundle) { return image }
    let symbol =
      NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: accessibilityName)
      ?? NSImage(size: NSSize(width: 18, height: 18))
    symbol.isTemplate = true
    return symbol
  }
}
