import Foundation

/// A value made ready for tmux to store or find exactly when it arrives as one argv element
/// (PLAN.md D18, *Verified facts*, Phase 6a): every `#` doubled, since tmux expands formats in
/// a new session's `-s` and `##` is its escape for `#`; then a trailing `;` written `\;`, since
/// tmux reads an argument ending in `;` as a command separator even as its own argv element.
///
/// The same transformation as the static shell functions `TmuxCommands.wordFunctions`
/// (`muxfinder_double_hash`, then `muxfinder_tmux_word`), for argv built in Swift, such as the
/// persistent profile's local `new-session -A -s <name>` (PLAN.md D26).
public enum TmuxWord {
  /// `value` with every `#` doubled and a trailing `;` written `\;` (only the last character
  /// counts, so `x\;` becomes `x\\;`, which tmux reads as `x\;`). Works on Unicode scalars, as
  /// the shell functions work on bytes, so a `#` followed by a combining mark is doubled too.
  public static func escaped(_ value: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in value.unicodeScalars {
      if scalar == "#" { scalars.append("#") }
      scalars.append(scalar)
    }
    if scalars.last == ";" {
      scalars.removeLast()
      scalars.append(contentsOf: "\\;".unicodeScalars)
    }
    return String(scalars)
  } // End of func escaped(_:)
}
