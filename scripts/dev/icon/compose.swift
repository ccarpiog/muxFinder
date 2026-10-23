// compose: stacks plate → glyph for one icon variant at one size and writes the macOS and iOS
// composites.
//
// Usage: compose --variant <dir> --size <int>
//
// Reads the palette from <dir>/BRIEF.md, the optional 1024 px opaque plate from
// <dir>/out/plate.png, and runs <dir>/bin/glyph to render the glyph natively at the exact size
// needed (never scaled). Writes <dir>/out/ios-<size>.png (full-bleed, opaque, square corners)
// and <dir>/out/macos-<size>.png (rounded tile of 824/1024 with a soft shadow, over
// transparency). At 32 px and below the plate is replaced by a two-stop gradient of the brief's
// bg-start and bg-end colours; without a plate the gradient is used at every size.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The palette a brief pins down.
struct Palette {
  /// Top colour of the background gradient.
  let bgStart: CGColor
  /// Bottom colour of the background gradient.
  let bgEnd: CGColor
  /// Glyph colour, as the RRGGBB string the glyph renderer takes.
  let glyphFill: String
}

/// Prints a message to stderr and exits with status 1.
func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("compose: \(message)\n".utf8))
  exit(1)
}

/// Parses an RRGGBB hex string, with or without a leading #, into an sRGB colour.
func color(hex: String) -> CGColor {
  let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
  guard digits.count == 6, let value = UInt32(digits, radix: 16) else { fail("bad colour \(hex)") }
  return CGColor(
    srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
    blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}

/// Reads the `bg-start`, `bg-end` and `glyph-fill` list items from a variant's BRIEF.md.
func readPalette(variant: URL) -> Palette {
  let url = variant.appendingPathComponent("BRIEF.md")
  guard let text = try? String(contentsOf: url, encoding: .utf8) else {
    fail("cannot read \(url.path)")
  }
  var values: [String: String] = [:]
  for line in text.split(separator: "\n") {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("- ") else { continue }
    let parts = trimmed.dropFirst(2).split(separator: ":", maxSplits: 1)
    guard parts.count == 2 else { continue }
    values[parts[0].trimmingCharacters(in: .whitespaces)] =
      parts[1].trimmingCharacters(in: .whitespaces)
  }
  guard let start = values["bg-start"], let end = values["bg-end"],
    let fill = values["glyph-fill"]
  else { fail("palette missing in \(url.path)") }
  return Palette(
    bgStart: color(hex: start), bgEnd: color(hex: end),
    glyphFill: String(fill.drop(while: { $0 == "#" })))
} // End of func readPalette(variant:)

/// Creates a square sRGB bitmap context; `opaque` drops the alpha channel.
func makeContext(_ size: Int, opaque: Bool = false) -> CGContext {
  let info =
    opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
  guard
    let ctx = CGContext(
      data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
  else { fail("cannot create a \(size) px context") }
  ctx.interpolationQuality = .high
  return ctx
}

/// Loads a PNG file as a CGImage, or returns nil when it is missing or unreadable.
func loadImage(_ url: URL) -> CGImage? {
  guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
  return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// Writes an image to a PNG file, exiting on failure.
func writePNG(_ image: CGImage, to url: URL) {
  guard
    let dest = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { fail("cannot write \(url.path)") }
  CGImageDestinationAddImage(dest, image, nil)
  guard CGImageDestinationFinalize(dest) else { fail("cannot write \(url.path)") }
}

/// Downscales an image to `size` px square in halving steps, each drawn with high-quality
/// interpolation, so a 1024 px plate does not alias on its way to 64 px.
func downscale(_ image: CGImage, to size: Int) -> CGImage {
  var current = image
  while current.width / 2 >= size {
    let half = current.width / 2
    let ctx = makeContext(half)
    ctx.draw(current, in: CGRect(x: 0, y: 0, width: half, height: half))
    current = ctx.makeImage()!
  }
  guard current.width != size else { return current }
  let ctx = makeContext(size)
  ctx.draw(current, in: CGRect(x: 0, y: 0, width: size, height: size))
  return ctx.makeImage()!
} // End of func downscale(_:to:)

/// Runs the variant's glyph renderer natively at `size` and returns the glyph image.
func renderGlyph(variant: URL, size: Int, fill: String, scratch: URL) -> CGImage {
  let out = scratch.appendingPathComponent("glyph-\(size)-\(fill).png")
  let process = Process()
  process.executableURL = variant.appendingPathComponent("bin/glyph")
  process.arguments = ["--size", String(size), "--out", out.path, "--fill", fill]
  do { try process.run() } catch { fail("cannot run the glyph renderer: \(error)") }
  process.waitUntilExit()
  guard process.terminationStatus == 0, let image = loadImage(out) else {
    fail("the glyph renderer failed at \(size) px")
  }
  return image
} // End of func renderGlyph(variant:size:fill:scratch:)

/// Renders the square, full-bleed artwork at `size`: the plate (downscaled) or the brief's
/// two-stop vertical gradient, then the glyph rendered natively at the same size on top.
func artwork(variant: URL, size: Int, plate: CGImage?, palette: Palette, scratch: URL)
  -> CGImage
{
  let ctx = makeContext(size)
  let rect = CGRect(x: 0, y: 0, width: size, height: size)
  if let plate {
    ctx.draw(downscale(plate, to: size), in: rect)
  } else {
    let gradient = CGGradient(
      colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
      colors: [palette.bgStart, palette.bgEnd] as CFArray, locations: [0, 1])!
    // Core Graphics' y axis points up, so bg-start goes at the top edge.
    ctx.drawLinearGradient(
      gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: .zero,
      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  }
  let glyph = renderGlyph(variant: variant, size: size, fill: palette.glyphFill, scratch: scratch)
  ctx.draw(glyph, in: rect)
  return ctx.makeImage()!
} // End of func artwork(variant:size:plate:palette:scratch:)

// MARK: - Main

var variantPath = ""
var size = 0
var index = 1
let arguments = CommandLine.arguments
while index < arguments.count {
  switch arguments[index] {
  case "--variant" where index + 1 < arguments.count: variantPath = arguments[index + 1]
  case "--size" where index + 1 < arguments.count: size = Int(arguments[index + 1]) ?? 0
  default: fail("usage: compose --variant <dir> --size <int>")
  }
  index += 2
} // End of loop over command-line arguments
guard !variantPath.isEmpty, size >= 16 else { fail("usage: compose --variant <dir> --size <int>") }

let variant = URL(fileURLWithPath: variantPath)
let outDir = variant.appendingPathComponent("out")
let scratch = outDir.appendingPathComponent(".compose")
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
let palette = readPalette(variant: variant)
let loadedPlate = loadImage(outDir.appendingPathComponent("plate.png"))
if loadedPlate == nil && size > 32 {
  FileHandle.standardError.write(Data("compose: no plate yet, gradient used at \(size) px\n".utf8))
}
// At 32 px and below the painting would only be noise: use the gradient.
let plate = size > 32 ? loadedPlate : nil

// iOS: full-bleed, flattened onto bg-start, no alpha; the system applies its own mask.
let iosRect = CGRect(x: 0, y: 0, width: size, height: size)
let ios = makeContext(size, opaque: true)
ios.setFillColor(palette.bgStart)
ios.fill(iosRect)
ios.draw(
  artwork(variant: variant, size: size, plate: plate, palette: palette, scratch: scratch),
  in: iosRect)
writePNG(ios.makeImage()!, to: outDir.appendingPathComponent("ios-\(size).png"))

// macOS: a rounded tile of 824/1024 (corner radius 185.4/1024), centred on whole pixels, with a
// soft drop shadow, over transparency. The artwork is rendered at the tile's own pixel size.
let margin = Int((Double(size) * 100 / 1024).rounded())
let tile = size - 2 * margin
let tileRect = CGRect(x: margin, y: margin, width: tile, height: tile)
let radius = CGFloat(size) * 185.4 / 1024
let shape = CGPath(
  roundedRect: tileRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
let mac = makeContext(size)
mac.saveGState()
mac.setShadow(
  offset: CGSize(width: 0, height: -CGFloat(size) * 10 / 1024), blur: CGFloat(size) * 24 / 1024,
  color: CGColor(gray: 0, alpha: 0.35))
mac.addPath(shape)
mac.setFillColor(palette.bgEnd)
mac.fillPath()
mac.restoreGState()
mac.saveGState()
mac.addPath(shape)
mac.clip()
mac.draw(
  artwork(variant: variant, size: tile, plate: plate, palette: palette, scratch: scratch),
  in: tileRect)
mac.restoreGState()
writePNG(mac.makeImage()!, to: outDir.appendingPathComponent("macos-\(size).png"))
