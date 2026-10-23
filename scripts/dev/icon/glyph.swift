// glyph: draws muxFinder's split-window mark (BRIEF.md) in one flat colour on a transparent
// square canvas and writes it as a PNG with straight alpha.
//
// Usage: glyph --size <int> --out <path.png> [--fill <RRGGBB>]
//
// Every measure is a fraction of --size, snapped to whole pixels (stroke weights at least
// 1 px), so --size 16 and --size 1024 are the same drawing and small sizes stay crisp. Output is
// deterministic. The same mark is the app icon's glyph (white) and the menu bar template
// (black). Written with Codex from BRIEF.md; see README.md.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A failure reported on stderr with exit status 1.
struct RendererError: Error, CustomStringConvertible {
  /// The message.
  let description: String
  /// Creates an error with the given message.
  init(_ description: String) { self.description = description }
}

/// The parsed command line.
struct Options {
  /// Canvas side in pixels.
  let size: Int
  /// Output PNG path.
  let output: String
  /// Fill colour, red component.
  let red: UInt8
  /// Fill colour, green component.
  let green: UInt8
  /// Fill colour, blue component.
  let blue: UInt8

  /// Parses `--size`, `--out` and the optional `--fill` (default `FFFFFF`); throws on unknown,
  /// repeated or missing arguments and on a fill that is not six hexadecimal digits.
  init(arguments: [String]) throws {
    var size: Int?
    var output: String?
    var fill = "FFFFFF"
    var seen = Set<String>()
    var index = 0

    while index < arguments.count {
      let option = arguments[index]
      guard ["--size", "--out", "--fill"].contains(option) else {
        throw RendererError("Unknown argument: \(option)")
      }
      guard seen.insert(option).inserted else {
        throw RendererError("Duplicate argument: \(option)")
      }
      guard index + 1 < arguments.count else {
        throw RendererError("Missing value for \(option)")
      }

      let value = arguments[index + 1]
      switch option {
      case "--size":
        guard let parsed = Int(value), parsed > 0 else {
          throw RendererError("--size must be a positive integer.")
        }
        size = parsed
      case "--out":
        guard !value.isEmpty else {
          throw RendererError("--out must be a nonempty path.")
        }
        output = value
      case "--fill":
        fill = value
      default:
        break
      }
      index += 2
    } // End of loop over command-line arguments

    guard let size, let output else {
      throw RendererError(
        "Usage: glyph --size <int> --out <path.png> [--fill <RRGGBB>]"
      )
    }
    guard fill.utf8.count == 6,
      fill.utf8.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      }),
      let rgb = UInt32(fill, radix: 16)
    else {
      throw RendererError("--fill must contain exactly six hexadecimal digits.")
    }

    self.size = size
    self.output = output
    self.red = UInt8((rgb >> 16) & 0xFF)
    self.green = UInt8((rgb >> 8) & 0xFF)
    self.blue = UInt8(rgb & 0xFF)
  } // End of init(arguments:)
}

/// Adds one pane cutout to `path`: square bottom corners and optional circular top corners
/// (following the frame's inner radius), filled with the even-odd rule so it becomes a hole.
func addPane(
  to path: CGMutablePath,
  rect: CGRect,
  topLeftRadius: CGFloat = 0,
  topRightRadius: CGFloat = 0
) {
  let left = rect.minX
  let right = rect.maxX
  let bottom = rect.minY
  let top = rect.maxY

  path.move(to: CGPoint(x: left, y: bottom))
  path.addLine(to: CGPoint(x: right, y: bottom))
  path.addLine(to: CGPoint(x: right, y: top - topRightRadius))

  if topRightRadius > 0 {
    path.addArc(
      center: CGPoint(
        x: right - topRightRadius,
        y: top - topRightRadius
      ),
      radius: topRightRadius,
      startAngle: 0,
      endAngle: .pi / 2,
      clockwise: false
    )
  }

  path.addLine(to: CGPoint(x: left + topLeftRadius, y: top))

  if topLeftRadius > 0 {
    path.addArc(
      center: CGPoint(
        x: left + topLeftRadius,
        y: top - topLeftRadius
      ),
      radius: topLeftRadius,
      startAngle: .pi / 2,
      endAngle: .pi,
      clockwise: false
    )
  }

  path.addLine(to: CGPoint(x: left, y: bottom))
  path.closeSubpath()
} // End of func addPane(to:rect:topLeftRadius:topRightRadius:)

/// The mark for a canvas of `side` pixels: the rounded frame as a solid shape with three pane
/// cutouts (left pane, and the right column split in two), leaving the frame strokes, the
/// dividers and the bottom status bar solid. Every edge is snapped to whole pixels.
func makeGlyphPath(side: CGFloat) -> CGPath {
  let weight = max(1, (side * 0.065).rounded())
  let frameWidth = (side * 0.64).rounded()
  let frameHeight = (side * 0.52).rounded()
  let frame = CGRect(
    x: ((side - frameWidth) * 0.5).rounded(),
    y: ((side - frameHeight) * 0.5).rounded(),
    width: frameWidth,
    height: frameHeight
  )
  let outerRadius = min(
    (side * 0.07).rounded(),
    (min(frameWidth, frameHeight) * 0.5).rounded(.down)
  )

  let path = CGMutablePath()
  path.addRoundedRect(
    in: frame,
    cornerWidth: outerRadius,
    cornerHeight: outerRadius
  )

  let inner = frame.insetBy(dx: weight, dy: weight)
  let minimumClearance: CGFloat = 1

  // Below the dimensions needed for three clear panes, retain the outer
  // silhouette rather than introducing inverted or overlapping cutouts.
  guard inner.width >= weight + minimumClearance * 2,
    inner.height >= weight + minimumClearance * 2
  else {
    return path
  }

  // Round the independent pane height once. Derive both equal right panes
  // and the status boundary from it, keeping the divider exactly one weight.
  let statusExtension = (side * 0.11).rounded()
  let desiredPaneHeight =
    ((inner.height - statusExtension - weight) * 0.5).rounded()
  let maximumPaneHeight =
    ((inner.height - weight) * 0.5).rounded(.down)
  let rightPaneHeight = min(
    max(minimumClearance, desiredPaneHeight),
    maximumPaneHeight
  )

  let paneTop = inner.maxY
  let paneBottom = paneTop - rightPaneHeight * 2 - weight
  let upperPaneBottom = paneTop - rightPaneHeight

  // Snap the divider's leading edge, then derive its trailing edge.
  // This avoids half-pixel edges when the rounded weight is odd.
  let leftPaneWidth = min(
    max(
      minimumClearance,
      (inner.width * 0.55 - weight * 0.5).rounded()
    ),
    inner.width - weight - minimumClearance
  )
  let dividerLeft = inner.minX + leftPaneWidth
  let rightPaneX = dividerLeft + weight
  let rightPaneWidth = inner.maxX - rightPaneX
  let innerRadius = max(0, outerRadius - weight)

  addPane(
    to: path,
    rect: CGRect(
      x: inner.minX,
      y: paneBottom,
      width: leftPaneWidth,
      height: paneTop - paneBottom
    ),
    topLeftRadius: min(
      innerRadius,
      min(leftPaneWidth, paneTop - paneBottom)
    )
  )

  addPane(
    to: path,
    rect: CGRect(
      x: rightPaneX,
      y: upperPaneBottom,
      width: rightPaneWidth,
      height: rightPaneHeight
    ),
    topRightRadius: min(
      innerRadius,
      min(rightPaneWidth, rightPaneHeight)
    )
  )

  addPane(
    to: path,
    rect: CGRect(
      x: rightPaneX,
      y: paneBottom,
      width: rightPaneWidth,
      height: rightPaneHeight
    )
  )

  return path
} // End of func makeGlyphPath(side:)

/// Renders the mark's coverage in grey, turns it into straight (unpremultiplied) RGBA in the
/// fill colour, and writes the PNG.
func render(_ options: Options) throws {
  let size = options.size
  let (pixelCount, pixelOverflow) = size.multipliedReportingOverflow(by: size)
  let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
  let (rowBytes, rowOverflow) = size.multipliedReportingOverflow(by: 4)

  guard !pixelOverflow, !byteOverflow, !rowOverflow else {
    throw RendererError("Requested image dimensions are too large.")
  }

  // Render coverage independently, then construct explicitly straight RGBA.
  var coverage = Data(count: pixelCount)
  try coverage.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
    guard let baseAddress = buffer.baseAddress,
      let context = CGContext(
        data: baseAddress,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      )
    else {
      throw RendererError("Could not allocate the coverage renderer.")
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.setFillColor(gray: 1, alpha: 1)
    context.addPath(makeGlyphPath(side: CGFloat(size)))
    context.drawPath(using: .eoFill)
    context.flush()
  } // End of the coverage drawing closure

  var rgba = Data(count: byteCount)
  coverage.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
    rgba.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
      let alpha = source.bindMemory(to: UInt8.self)
      let pixels = destination.bindMemory(to: UInt8.self)

      for index in 0..<pixelCount {
        let offset = index * 4
        pixels[offset] = options.red
        pixels[offset + 1] = options.green
        pixels[offset + 2] = options.blue
        pixels[offset + 3] = alpha[index]
      }
    }
  } // End of the coverage-to-RGBA conversion

  guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let provider = CGDataProvider(data: rgba as CFData),
    let image = CGImage(
      width: size,
      height: size,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: rowBytes,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(
        rawValue: CGImageAlphaInfo.last.rawValue
      ).union(.byteOrder32Big),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  else {
    throw RendererError("Could not create the straight-alpha image.")
  }

  let url = URL(fileURLWithPath: options.output)
  guard
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL,
      UTType.png.identifier as CFString,
      1,
      nil
    )
  else {
    throw RendererError("Could not open output: \(options.output)")
  }

  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else {
    throw RendererError("Could not write PNG: \(options.output)")
  }
} // End of func render(_:)

do {
  let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
  try render(options)
  exit(0)
} catch {
  FileHandle.standardError.write(Data("glyph: \(error)\n".utf8))
  exit(1)
}
