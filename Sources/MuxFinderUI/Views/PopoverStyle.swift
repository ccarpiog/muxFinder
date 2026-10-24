import AppKit
import SwiftUI

/// The popover's colors (PLAN.md D22): its own opaque window background, a bounded box per
/// host with a header band, neutral row fills, and the "Open in iTerm2 here" badge's solid
/// fill. Every fill is opaque and fixed per color scheme, so the real popover (whatever the
/// menu bar extra's window draws under it) looks like the preview galleries, and what is
/// drawn is what the contrast tests resolve (`PopoverStyleTests`). The keyboard selection is
/// a neutral fill with an accent outline, so the accent color never sits under the badge.
struct PopoverPalette {
  /// Behind everything: the gray `windowBackgroundColor` draws in a window (0.925 light,
  /// 0.196 dark), opaque, with no vibrancy or blur from the menu bar extra's material.
  let background: Color
  /// A host section's box, behind its rows.
  let sectionFill: Color
  /// A host section's header band (name, "Last checked …", status).
  let headerBand: Color
  /// The hairline around a section and the search field.
  let border: Color
  /// A selected row's fill: neutral, never the accent color.
  let selectedRowFill: Color
  /// A row's fill under the pointer.
  let hoveredRowFill: Color
  /// The outline around the selected row.
  let selectionOutline: Color
  /// The "Open in iTerm2 here" badge's solid fill.
  let badgeFill: Color
  /// The badge's text and icon.
  let badgeText: Color

  /// The palette for `scheme`.
  init(_ scheme: ColorScheme) {
    border = Color(nsColor: .separatorColor)
    selectionOutline = Color.accentColor
    badgeText = .white
    switch scheme {
    case .dark:
      background = Color(white: 0.196)
      sectionFill = Color(white: 0.235)
      headerBand = Color(white: 0.27)
      selectedRowFill = Color(white: 0.335)
      hoveredRowFill = Color(white: 0.27)
      badgeFill = Color(red: 0.122, green: 0.435, blue: 0.820)
    default:
      background = Color(white: 0.925)
      sectionFill = Color(white: 1)
      headerBand = Color(white: 0.955)
      selectedRowFill = Color(white: 0.87)
      hoveredRowFill = Color(white: 0.95)
      badgeFill = Color(red: 0.0, green: 0.384, blue: 0.769)
    }
  } // End of init(_:)

  /// A row's fill: the selection's, the hover's, or the section's own.
  func rowFill(isSelected: Bool, isHovered: Bool) -> Color {
    if isSelected { return selectedRowFill }
    return isHovered ? hoveredRowFill : sectionFill
  }
}

/// A host status's dot: filled in the tone's color, or for the muted tone (an unreachable
/// host) a hollow gray ring, so an offline Mac never reads as an alert.
struct StatusDot: View {
  /// The status's tone.
  let tone: HostStatusLabel.Tone

  /// The dot's diameter, in points.
  static let size: CGFloat = 7

  /// The filled or hollow circle.
  var body: some View {
    Group {
      if Self.isHollow(tone) {
        Circle().strokeBorder(Color.secondary, lineWidth: 1.2)
      } else {
        Circle().fill(Self.color(for: tone))
      }
    }
    .frame(width: Self.size, height: Self.size)
    .accessibilityHidden(true)
  }

  /// Whether `tone`'s dot is a hollow ring rather than a filled circle.
  static func isHollow(_ tone: HostStatusLabel.Tone) -> Bool { tone == .muted }

  /// The dot's color for `tone`; none is red (red is for failed session actions).
  static func color(for tone: HostStatusLabel.Tone) -> Color {
    switch tone {
    case .good: return .green
    case .neutral: return .gray
    case .attention: return .orange
    case .muted: return .secondary
    }
  }
}

/// A session row's leading indicator (PLAN.md D22): a distinct shape and color per attach
/// state, in a fixed-width column so the names line up. The row's text states the same, so
/// color is never the only signal; VoiceOver reads the row's label and value instead.
struct AttachStateIndicator: View {
  /// The row's state.
  let state: SessionRow.AttachState

  /// The column's width, in points.
  static let width: CGFloat = 14

  /// The symbol in its column.
  var body: some View {
    Image(systemName: Self.symbol(for: state))
      .font(.caption)
      .imageScale(state == .here ? .medium : .small)
      .foregroundStyle(Self.color(for: state))
      .frame(width: Self.width)
      .accessibilityHidden(true)
  }

  /// The SF Symbol of `state`: a window (open here, like the badge), a filled dot (attached
  /// elsewhere), a filled dot in a dashed ring (attached, where unknown), a hollow ring
  /// (detached), a clock (stale).
  static func symbol(for state: SessionRow.AttachState) -> String {
    switch state {
    case .here: return "macwindow"
    case .attachedElsewhere: return "circle.fill"
    case .attachedUnknownLocation: return "circle.dashed.inset.filled"
    case .detached: return "circle"
    case .stale: return "clock"
    }
  }

  /// The symbol's color: blue, green, a neutral gray (attached, where unknown, so never the
  /// green of "elsewhere"), the secondary gray, and a dimmer gray for a stale row.
  static func color(for state: SessionRow.AttachState) -> Color {
    switch state {
    case .here: return Color(nsColor: .systemBlue)
    case .attachedElsewhere: return Color(nsColor: .systemGreen)
    case .attachedUnknownLocation: return Color(nsColor: .systemGray)
    case .detached: return .secondary
    case .stale: return Color(nsColor: .tertiaryLabelColor)
    }
  }
}
