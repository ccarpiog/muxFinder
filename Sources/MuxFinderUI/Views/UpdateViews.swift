import AppKit
import MuxFinderCore
import SwiftUI

/// The popover's update notice (PLAN.md D39 *The notice (I-13c1)*, *The update views
/// (I-13c2b)*), rendered only from an `UpdateNoticeContent`: the title ("muxFinder <version> is
/// available", or "Installing…" / "Relaunching…") with **What's new**, then the flow's lines
/// (wrapping, never cutting a button), the download's bar and the flow's buttons. Each button
/// hands its action to `perform` (`UpdateModel.perform(_:)`). VoiceOver reads every line as
/// text, each button by its label and hint, and the bar's percent as its value.
struct UpdateNoticeView: View {
  /// What the notice shows.
  let content: UpdateNoticeContent
  /// Called with a pressed button's action.
  let perform: @MainActor (UpdateNoticeAction) -> Void

  /// The title row and, below it, the lines, the bar and the buttons, on a faint blue band.
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "arrow.down.circle.fill")
        .foregroundStyle(Color.accentColor)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(content.title)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
          if content.showsActivity, content.lines.isEmpty { activity }
          Spacer(minLength: 6)
          if let whatsNew = content.whatsNew { button(whatsNew) }
        }
        ForEach(content.lines.indices, id: \.self) { index in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            line(content.lines[index])
            if index == 0, content.showsActivity { activity }
          }
        }
        if let progress = content.progress {
          ProgressView(value: progress.fraction)
            .progressViewStyle(.linear)
            .controlSize(.small)
            .accessibilityLabel(UpdateNoticeProgress.accessibilityLabel)
            .accessibilityValue(progress.accessibilityValue)
        }
        if !content.buttons.isEmpty {
          HStack(spacing: 10) {
            ForEach(content.buttons) { button($0) }
            Spacer(minLength: 0)
          }
        }
      } // End of VStack holding the title row, the lines, the bar and the buttons
    } // End of HStack holding the notice
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.accentColor.opacity(0.08))
    .accessibilityElement(children: .contain)
  } // End of var body

  /// The small activity indicator (VoiceOver hears the line beside it instead).
  private var activity: some View {
    ProgressView()
      .controlSize(.mini)
      .accessibilityHidden(true)
  }

  /// One line: a status in the title's size, a note in secondary caption, a failure in red
  /// with its symbol; each wraps.
  @ViewBuilder
  private func line(_ line: UpdateNoticeLine) -> some View {
    switch line.style {
    case .status:
      Text(line.text)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    case .note:
      Text(line.text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    case .problem:
      Label {
        Text(line.text)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "exclamationmark.circle.fill")
          .accessibilityHidden(true)
      }
      .font(.callout)
      .foregroundStyle(.red)
      .accessibilityElement(children: .combine)
    }
  } // End of func line(_:)

  /// One button at its full width (never truncated): prominent for the state's main action,
  /// a link for Release page, small either way, disabled when it cannot be pressed.
  @ViewBuilder
  private func button(_ button: UpdateNoticeButton) -> some View {
    let base = Button(button.title) { perform(button.action) }
      .controlSize(.small)
      .fixedSize()
      .disabled(!button.isEnabled)
      .accessibilityLabel(button.accessibilityLabel)
      .accessibilityHint(button.accessibilityHint ?? "")
    switch button.style {
    case .primary: base.buttonStyle(.borderedProminent)
    case .secondary: base
    case .link: base.buttonStyle(.link)
    }
  } // End of func button(_:)
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
