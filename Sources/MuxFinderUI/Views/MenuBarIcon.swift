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

  /// The dot's diameter as a share of the icon's width (PLAN.md D39 *The notice (I-13c1)*).
  static let dotShare: CGFloat = 0.42
  /// The clear ring around the dot, as a share of the icon's width, so the dot stays apart
  /// from the mark at 16 px.
  static let ringShare: CGFloat = 0.1

  /// The rectangle of the dot in an icon of `size` (its top-right corner, in a non-flipped
  /// drawing).
  static func dotRect(in size: NSSize) -> NSRect {
    let diameter = (size.width * dotShare).rounded()
    return NSRect(
      x: size.width - diameter, y: size.height - diameter, width: diameter, height: diameter)
  }

  /// `base` with the update dot (PLAN.md D39 *The notice (I-13c1)*): drawn at run time, at
  /// every resolution the menu bar asks for, as `base` with a clear ring cut out of its top-right
  /// corner and a filled circle in it; the result is a template image again (one flat colour,
  /// tinted by the menu bar) of `base`'s size. Without the dot, `base` itself.
  public static func image(_ base: NSImage, withDot: Bool) -> NSImage {
    guard withDot else { return base }
    let size = base.size
    let image = NSImage(size: size, flipped: false) { rect in
      base.draw(in: rect)
      let dot = dotRect(in: size)
      let ring = dot.insetBy(dx: -size.width * ringShare, dy: -size.width * ringShare)
      if let context = NSGraphicsContext.current {
        context.saveGraphicsState()
        context.compositingOperation = .clear
        NSBezierPath(ovalIn: ring).fill()
        context.restoreGraphicsState()
      }
      NSColor.black.setFill()
      NSBezierPath(ovalIn: dot).fill()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = UpdateNotice.labelWithDot
    return image
  } // End of static func image(_:withDot:)

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
