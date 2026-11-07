import AppKit
import MuxFinderCore
import SwiftUI

/// The popover's update notice (PLAN.md D39 *The notice (I-13c1)*): "muxFinder <version> is
/// available" with **What's new**, which opens the release page; shown while the offer is newer
/// than the running version. No Update or Download button yet (I-13c2).
struct UpdateNoticeView: View {
  /// The release offered.
  let release: UpdateRelease
  /// The model that opens the release page.
  let update: UpdateModel

  /// One line on a faint blue band.
  var body: some View {
    let text = UpdateNotice.available(release.version)
    HStack(spacing: 8) {
      Image(systemName: "arrow.down.circle.fill")
        .foregroundStyle(Color.accentColor)
        .accessibilityHidden(true)
      Text(text)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(text)
      Spacer(minLength: 6)
      Button("What's new") { update.openWhatsNew() }
        .controlSize(.small)
        .accessibilityLabel("What's new in muxFinder " + release.version.description)
        .accessibilityHint("Opens the release page in your browser")
    } // End of HStack holding the notice
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.accentColor.opacity(0.08))
    .accessibilityElement(children: .contain)
  } // End of var body
}

/// Settings › General's "Updates" section (PLAN.md D39 *The notice (I-13c1)*): the toggle
/// "Check for updates automatically", the button "Check for updates…" (disabled while a check
/// is in flight) and the status line. Shown only with update machinery or a fixture.
struct UpdateSettingsSection: View {
  /// The model shown.
  let update: UpdateModel

  /// The toggle, the button and the status line.
  var body: some View {
    SettingsSection(title: "Updates") {
      Toggle(
        "Check for updates automatically",
        isOn: Binding(get: { update.automaticChecks }, set: { update.setAutomaticChecks($0) })
      )
      .accessibilityLabel("Check for updates automatically")
      if let problem = update.toggleProblem {
        IssueText(text: problem)
      }
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Button("Check for updates…") { update.checkNow() }
          .disabled(update.isChecking)
          .accessibilityLabel("Check for updates")
        if update.isChecking {
          ProgressView()
            .controlSize(.small)
            .accessibilityHidden(true)
        }
        Spacer(minLength: 0)
      }
      let lines = update.statusLines
      VStack(alignment: .leading, spacing: 2) {
        ForEach(lines.indices, id: \.self) { index in
          if index == 0, lines.count > 1 {
            Text(lines[index])
              .font(.callout)
              .fixedSize(horizontal: false, vertical: true)
          } else {
            NoteText(text: lines[index])
          }
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Update status: " + lines.joined(separator: ". "))
    } // End of SettingsSection "Updates"
    .onAppear { update.refreshNow() }
  } // End of var body
}

/// The popover gallery's row of status item images (PLAN.md D39 *The notice (I-13c1)*): the
/// menu bar icon without and with the update dot, rendered as the menu bar does a template
/// image, on a light and a dark menu bar.
struct MenuBarIconStrip: View {
  /// The icon from the bundle (or its fallback).
  let base: NSImage

  /// A light and a dark band, each with both images.
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Menu bar icon: without and with the update dot")
        .font(.headline)
      HStack(spacing: 16) {
        band(dark: false)
        band(dark: true)
      }
    }
  } // End of var body

  /// One menu bar band.
  private func band(dark: Bool) -> some View {
    HStack(spacing: 18) {
      icon(withDot: false)
      icon(withDot: true)
    }
    .foregroundStyle(dark ? Color.white : Color.black)
    .padding(.horizontal, 14)
    .padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: 6).fill(
        dark ? Color(white: 0.16) : Color(white: 0.93)))
  }

  /// The image at the menu bar's size, tinted as a template.
  private func icon(withDot: Bool) -> some View {
    let image = MenuBarIcon.image(base, withDot: withDot)
    return Image(nsImage: image)
      .renderingMode(.template)
      .resizable()
      .frame(width: base.size.width, height: base.size.height)
      .accessibilityLabel(UpdateNotice.statusItemLabel(showsDot: withDot))
  }
}
