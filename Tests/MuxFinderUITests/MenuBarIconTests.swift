import AppKit
import Foundation
import ImageIO
import Testing

@testable import MuxFinderUI

/// The menu bar icon (PLAN.md D28): the template PNGs committed in `Resources/` are what a menu
/// bar template image needs (black with alpha, 18, 36 and 54 px, with a clear margin), and
/// `MenuBarIcon.image(in:)` reads them from a bundle as one 18 pt template image, or returns nil
/// so the label falls back to the SF Symbol. Reads only the repository's files and a private
/// temporary folder.
@Suite("Menu bar icon")
struct MenuBarIconTests {
  /// The repository's `Resources/` folder, found from this file's path.
  static let resources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources")

  /// The committed menu bar PNGs with their pixel sizes.
  static let files = [
    (name: "MenuBarIcon.png", pixels: 18), (name: "MenuBarIcon@2x.png", pixels: 36),
    (name: "MenuBarIcon@3x.png", pixels: 54),
  ]

  /// A private folder with copies of the named PNGs, opened as a flat bundle; the caller
  /// removes the folder.
  static func bundle(with names: [String]) throws -> (bundle: Bundle, folder: URL) {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("muxfinder-menubar-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in names {
      try FileManager.default.copyItem(
        at: resources.appendingPathComponent(name), to: folder.appendingPathComponent(name))
    }
    return (try #require(Bundle(url: folder)), folder)
  }

  /// Each PNG has its size, is black wherever it is not transparent (a template image's
  /// colour is ignored, so anything else would mean a wrong file), covers a plausible share of
  /// the canvas, and leaves the outermost ring of pixels empty.
  @Test("the committed PNGs are black-on-transparency templates at 18, 36 and 54 px")
  func committedFiles() throws {
    for file in Self.files {
      let url = Self.resources.appendingPathComponent(file.name)
      let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
      let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
      let side = file.pixels
      #expect(image.width == side && image.height == side, "\(file.name)")
      var pixels = [UInt8](repeating: 0, count: side * side * 4)
      let context = try #require(
        CGContext(
          data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
      var covered = 0
      var colored = 0
      var edge = 0
      for y in 0..<side {
        for x in 0..<side {
          let offset = (y * side + x) * 4
          if pixels[offset + 3] > 0 { covered += 1 }
          if pixels[offset] > 0 || pixels[offset + 1] > 0 || pixels[offset + 2] > 0 {
            colored += 1
          }
          if pixels[offset + 3] > 0 && (x == 0 || y == 0 || x == side - 1 || y == side - 1) {
            edge += 1
          }
        }
      } // End of loop over pixel rows
      let share = Double(covered) / Double(side * side)
      #expect(colored == 0, "\(file.name) has non-black pixels")
      #expect(share > 0.15 && share < 0.6, "\(file.name) covers \(share)")
      #expect(edge == 0, "\(file.name) touches an edge")
    } // End of loop over the committed PNGs
  } // End of func committedFiles()

  /// From a bundle with the three PNGs: one template image of 18 × 18 pt, titled for
  /// accessibility, with a representation per file.
  @Test("the bundle's PNGs load as one 18 pt template image")
  func loadsFromBundle() throws {
    let (bundle, folder) = try Self.bundle(with: Self.files.map(\.name))
    defer { try? FileManager.default.removeItem(at: folder) }
    let image = try #require(MenuBarIcon.image(in: bundle))
    #expect(image.isTemplate)
    #expect(image.size == NSSize(width: 18, height: 18))
    #expect(image.accessibilityDescription == "muxFinder")
    #expect(image.representations.map(\.pixelsWide).sorted() == [18, 36, 54])
  }

  /// From a bundle without the PNGs (an unbundled `swift run`): no image, and the fallback is
  /// an SF Symbol this macOS has.
  @Test("without the PNGs there is no image and the fallback symbol exists")
  func missingFallsBack() throws {
    let (bundle, folder) = try Self.bundle(with: [])
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(MenuBarIcon.image(in: bundle) == nil)
    #expect(
      NSImage(systemSymbolName: MenuBarIcon.fallbackSymbol, accessibilityDescription: nil) != nil)
  }

  /// The status item's image (PLAN.md D30): the bundle's template PNGs when present, else the
  /// SF Symbol fallback, a template image titled for accessibility either way.
  @Test("the status item image is the bundle's template or the symbol fallback")
  func statusItemImage() throws {
    let (bundle, folder) = try Self.bundle(with: Self.files.map(\.name))
    defer { try? FileManager.default.removeItem(at: folder) }
    let bundled = MenuBarIcon.statusItemImage(in: bundle)
    #expect(bundled.isTemplate)
    #expect(bundled.representations.map(\.pixelsWide).sorted() == [18, 36, 54])
    let (empty, emptyFolder) = try Self.bundle(with: [])
    defer { try? FileManager.default.removeItem(at: emptyFolder) }
    let fallback = MenuBarIcon.statusItemImage(in: empty)
    #expect(fallback.isTemplate)
    #expect(fallback.accessibilityDescription == MenuBarIcon.accessibilityName)
    #expect(fallback.size.width > 0 && fallback.size.height > 0)
  } // End of func statusItemImage()
}
