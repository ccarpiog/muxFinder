import AppKit
import CoreGraphics
import SwiftUI
import Testing

@testable import MuxFinderUI

/// The popover's look (PLAN.md D22): the "Open in iTerm2 here" badge readable on a selected
/// and an unselected row in light and dark (WCAG contrast from colors resolved with
/// `Color.resolve(in:)`), a neutral selection, no red host status, a hollow dot for the muted
/// tone, distinct attach-state indicators, and the footer's spacing.
@MainActor
@Suite("Popover style")
struct PopoverStyleTests {
  /// An sRGB color with its opacity, gamma-encoded, as WCAG composites and measures it.
  struct RGBA: Equatable {
    /// Red, 0…1.
    var red: Double
    /// Green, 0…1.
    var green: Double
    /// Blue, 0…1.
    var blue: Double
    /// Opacity, 0…1.
    var alpha: Double
  }

  /// A row the badge can be on.
  enum RowKind: String, CaseIterable, Sendable {
    /// Neither selected nor under the pointer.
    case unselected
    /// The keyboard selection.
    case selected
    /// Under the pointer.
    case hovered
  }

  /// An environment in `scheme`.
  static func environment(_ scheme: ColorScheme) -> EnvironmentValues {
    var environment = EnvironmentValues()
    environment.colorScheme = scheme
    return environment
  }

  /// `color` resolved in `environment`, converted to sRGB.
  static func resolve(_ color: Color, in environment: EnvironmentValues) throws -> RGBA {
    let resolved = color.resolve(in: environment)
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let converted = try #require(
      resolved.cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil))
    let parts = try #require(converted.components).map(Double.init)
    try #require(parts.count == 4)
    return RGBA(red: parts[0], green: parts[1], blue: parts[2], alpha: parts[3])
  }

  /// `layers` (top first) composited over each other, the last one opaque.
  static func composite(_ layers: [RGBA]) -> RGBA {
    var result = layers.last ?? RGBA(red: 0, green: 0, blue: 0, alpha: 1)
    for top in layers.dropLast().reversed() {
      let a = top.alpha
      result = RGBA(
        red: top.red * a + result.red * (1 - a),
        green: top.green * a + result.green * (1 - a),
        blue: top.blue * a + result.blue * (1 - a),
        alpha: 1)
    }
    return result
  } // End of static func composite(_:)

  /// WCAG 2 relative luminance of an opaque sRGB color.
  static func luminance(_ color: RGBA) -> Double {
    /// One gamma-encoded component, linearized.
    func linear(_ value: Double) -> Double {
      value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(color.red) + 0.7152 * linear(color.green)
      + 0.0722 * linear(color.blue)
  }

  /// WCAG 2 contrast ratio of two opaque colors, 1…21.
  static func contrast(_ first: RGBA, _ second: RGBA) -> Double {
    let (a, b) = (luminance(first), luminance(second))
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  /// The layers behind the badge's text on `row`, top first: the badge's fill, the row's
  /// fill, the section's fill, the popover's background.
  static func layersBehindBadge(_ palette: PopoverPalette, row: RowKind) -> [Color] {
    [
      palette.badgeFill,
      palette.rowFill(isSelected: row == .selected, isHovered: row == .hovered),
      palette.sectionFill,
      palette.background,
    ]
  }

  // MARK: - The badge

  /// The measuring itself: black on white is 21:1, a color on itself 1:1, and resolving
  /// gives gamma-encoded sRGB (a 50 % gray stays 0.5).
  @Test func contrastMath() throws {
    let environment = Self.environment(.light)
    let black = try Self.resolve(.black, in: environment)
    let white = try Self.resolve(.white, in: environment)
    #expect(abs(Self.contrast(black, white) - 21) < 0.01)
    #expect(abs(Self.contrast(white, white) - 1) < 0.0001)
    let gray = try Self.resolve(Color(white: 0.5), in: environment)
    #expect(abs(gray.red - 0.5) < 0.005)
    let half = Self.composite([RGBA(red: 1, green: 1, blue: 1, alpha: 0.5), black])
    #expect(abs(half.red - 0.5) < 0.0001 && half.alpha == 1)
  } // End of func contrastMath()

  /// "Open in iTerm2 here": its text against what is actually behind it is at least 4.5:1, in
  /// light and dark, on an unselected, a selected and a hovered row.
  @Test(arguments: [ColorScheme.light, .dark], RowKind.allCases)
  func badgeContrast(scheme: ColorScheme, row: RowKind) throws {
    let environment = Self.environment(scheme)
    let palette = PopoverPalette(scheme)
    let layers = Self.layersBehindBadge(palette, row: row)
    let behind = Self.composite(try layers.map { try Self.resolve($0, in: environment) })
    let text = Self.composite(
      [try Self.resolve(palette.badgeText, in: environment), behind])
    let ratio = Self.contrast(text, behind)
    #expect(ratio >= 4.5, "\(scheme) \(row.rawValue): \(ratio)")
  }

  /// The test bites: the old badge, accent text on an accent capsule at 0.14 over the
  /// accent selection at 0.22 (the default blue), was below 4.5:1 in both appearances.
  @Test(arguments: [ColorScheme.light, .dark])
  func oldBadgeFails(scheme: ColorScheme) throws {
    let environment = Self.environment(scheme)
    let accent = Color(red: 0, green: 0.478, blue: 1)
    let behind = Self.composite(
      try [accent.opacity(0.14), accent.opacity(0.22), PopoverPalette(scheme).background].map {
        try Self.resolve($0, in: environment)
      })
    let text = try Self.resolve(accent, in: environment)
    #expect(Self.contrast(text, behind) < 4.5)
  }

  /// No accent on accent: the selection's fill is a neutral gray, and neither the badge's
  /// fill nor its text is the accent color.
  @Test(arguments: [ColorScheme.light, .dark])
  func selectionIsNeutral(scheme: ColorScheme) throws {
    let environment = Self.environment(scheme)
    let palette = PopoverPalette(scheme)
    let selected = try Self.resolve(palette.selectedRowFill, in: environment)
    #expect(abs(selected.red - selected.green) < 0.005)
    #expect(abs(selected.green - selected.blue) < 0.005)
    #expect(selected.alpha == 1)
    let accent = try Self.resolve(.accentColor, in: environment)
    #expect(try Self.resolve(palette.badgeFill, in: environment) != accent)
    #expect(try Self.resolve(palette.badgeText, in: environment) != accent)
    #expect(palette.selectionOutline == .accentColor)
  } // End of func selectionIsNeutral(scheme:)

  /// Every fill under a row's text is opaque, so the real popover shows what the galleries
  /// show, whatever the menu bar extra's window draws beneath.
  @Test(arguments: [ColorScheme.light, .dark])
  func fillsAreOpaque(scheme: ColorScheme) throws {
    let environment = Self.environment(scheme)
    let palette = PopoverPalette(scheme)
    let fills = [
      palette.background, palette.sectionFill, palette.headerBand, palette.selectedRowFill,
      palette.hoveredRowFill, palette.badgeFill,
    ]
    for fill in fills {
      #expect(try Self.resolve(fill, in: environment).alpha == 1)
    }
  }

  // MARK: - Status and attach state

  /// No host status is red; only the muted tone (an unreachable host) has a hollow dot, in
  /// the secondary color.
  @Test func statusDots() {
    for tone in HostStatusLabel.Tone.allCases {
      #expect(StatusDot.color(for: tone) != .red, "\(tone)")
      #expect(StatusDot.isHollow(tone) == (tone == .muted), "\(tone)")
    }
    #expect(StatusDot.color(for: .muted) == .secondary)
    #expect(StatusDot.color(for: .attention) == .orange)
  }

  /// Each attach state has its own shape and its own color, every shape an SF Symbol this
  /// system has; "attached, where unknown" is never drawn green like "attached elsewhere".
  @Test func attachIndicatorsAreDistinct() {
    let states = SessionRow.AttachState.allCases
    #expect(Set(states.map(AttachStateIndicator.symbol(for:))).count == states.count)
    #expect(Set(states.map(AttachStateIndicator.color(for:))).count == states.count)
    for state in states {
      let symbol = AttachStateIndicator.symbol(for: state)
      #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(state)")
    }
    #expect(
      AttachStateIndicator.color(for: .attachedUnknownLocation) != Color(nsColor: .systemGreen))
  }

  // MARK: - Footer

  /// The footer's buttons are at least three times as far apart as each icon is from its own
  /// title.
  @Test func footerSpacing() {
    #expect(FooterView.iconTitleSpacing > 0)
    #expect(FooterView.buttonSpacing >= 3 * FooterView.iconTitleSpacing)
  }
}
