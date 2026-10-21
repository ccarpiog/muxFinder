import Foundation

/// JSON values as iTerm2's API carries them in profile properties (`ProfileProperty.json_value`).
///
/// The encoders produce the same text as Python's `json.dumps` with default options, which is
/// what iTerm2's own Python module sends: ASCII only, with `"`, `\`, backspace, form feed, line
/// feed, carriage return and tab as two-character escapes, every other character outside
/// U+0020...U+007E as `\uXXXX` (lowercase hex, UTF-16 surrogate pairs above U+FFFF), and `/`
/// left alone. Matching it byte for byte lets golden tests compare whole requests.
public enum ITerm2JSON {
  /// `value` as a JSON string literal, quotes included.
  public static func encode(_ value: String) -> String {
    var output = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": output += "\\\""
      case "\\": output += "\\\\"
      case "\u{08}": output += "\\b"
      case "\u{0C}": output += "\\f"
      case "\n": output += "\\n"
      case "\r": output += "\\r"
      case "\t": output += "\\t"
      case " "..."~": output.unicodeScalars.append(scalar)
      default:
        for unit in String(scalar).utf16 {
          output += "\\u" + hexDigits(unit)
        }
      }
    } // End of loop over the value's scalars
    output += "\""
    return output
  } // End of func encode(_:) for strings

  /// `value` as a JSON literal: `true` or `false`.
  public static func encode(_ value: Bool) -> String {
    value ? "true" : "false"
  }

  /// The string a JSON string literal holds, or `nil` if `json` is not a JSON string.
  public static func decodeString(_ json: String) -> String? {
    try? JSONDecoder().decode(String.self, from: Data(json.utf8))
  }

  /// `unit` as four lowercase hex digits.
  private static func hexDigits(_ unit: UInt16) -> String {
    let digits = String(unit, radix: 16)
    return String(repeating: "0", count: 4 - digits.count) + digits
  }
}
