import SwiftUI

/// A titled group of settings in a rounded box.
struct SettingsSection<Content: View>: View {
  /// The section's title.
  let title: String
  /// The rows.
  @ViewBuilder let content: Content

  /// The box with its title.
  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(6)
    } label: {
      Text(title)
        .font(.headline)
    }
  } // End of var body
}

/// One setting: a right-aligned label and its controls, with notes and errors under them.
struct FieldRow<Content: View>: View {
  /// The label's width, so the controls of every row line up.
  static var labelWidth: CGFloat { 104 }

  /// The label ("" for none).
  let label: String
  /// The controls and their notes.
  @ViewBuilder let content: Content

  /// The label and the controls.
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(label)
        .frame(width: Self.labelWidth, alignment: .trailing)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 4) {
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  } // End of var body
}

/// An inline validation error: a red symbol and the sentence.
struct IssueText: View {
  /// The error.
  let text: String

  /// The symbol and the text.
  var body: some View {
    Label {
      Text(text)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.red)
    }
    .font(.caption)
    .foregroundStyle(.red)
    .accessibilityElement(children: .combine)
  } // End of var body
}

/// A secondary note under a control.
struct NoteText: View {
  /// The note.
  let text: String

  /// The text, wrapping.
  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// A fix-it's button and, while shown, its explanation.
struct FixItView: View {
  /// The fix-it.
  let fixIt: FixIt
  /// The explaining fix-it whose text is shown, if any.
  let shownExplanation: FixIt?
  /// Performs it.
  let perform: (FixIt) -> Void

  /// The button and the explanation.
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button(fixIt.buttonTitle) {
        perform(fixIt)
      }
      .controlSize(.small)
      if shownExplanation == fixIt, let explanation = fixIt.explanation {
        Text(explanation)
          .font(.caption)
          .fixedSize(horizontal: false, vertical: true)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
      }
    }
  } // End of var body
}
