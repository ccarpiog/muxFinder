import Foundation

/// Finds a member name used twice in one JSON object, at any depth, for the strict terminal
/// definition parser (PLAN.md D38, Phase I-12b1). `JSONSerialization` keeps only one of such
/// members (and the bridge to `[String: Any]` also merges names that are canonically
/// equivalent), so without this a file could declare `schemaVersion` twice and pass with an
/// ambiguous meaning.
///
/// It reads the bytes `JSONSerialization` accepted, as UTF-8 (a leading byte order mark
/// skipped). Names are compared as Swift strings after every escape is decoded (`\"`, `\\`,
/// `\/`, `\b`, `\f`, `\n`, `\r`, `\t`, `\uXXXX` with surrogate pairs), so `id` with a
/// letter written as a `\u` escape is the name `id`. It follows the structure it walks
/// (strings; names, colons, values and commas in order; matching brackets; a trailing comma
/// allowed, as `JSONSerialization` allows it) but not the spelling of numbers and literals,
/// so it is only run on text `JSONSerialization` accepted. Anything it cannot follow is `malformed`: a NUL
/// byte (so a UTF-16 or UTF-32 file, which `JSONSerialization` would read), a byte past ASCII
/// outside a string, a control character inside one, an unknown escape, a lone surrogate, or
/// nesting deeper than `maximumDepth`. It never recurses: the open containers are an explicit
/// stack, at most `maximumDepth` deep.
struct JSONDuplicateNameScanner {
  /// What a scan found.
  enum Finding: Equatable {
    /// Every object's member names are distinct.
    case unique
    /// This member name is used twice in one object; its path as the parser names keys
    /// (`schemaVersion`, `open.kind`, `open.arguments item 1.x`).
    case duplicate(String)
    /// The bytes are not JSON text the scanner can follow.
    case malformed
  }

  /// What may come next inside an open container.
  enum Expectation: Equatable {
    /// An object's member name, or the object's end.
    case name
    /// The colon after a member name.
    case colon
    /// A value; in an array also the array's end.
    case value
    /// A comma, or the container's end.
    case commaOrEnd
  }

  /// One container open at the current place.
  struct Frame {
    /// Whether it is an object (else an array).
    let isObject: Bool
    /// Its path, as the parser names keys; empty for the root.
    let path: String
    /// What may come next in it.
    var expecting: Expectation
    /// An object's member names so far.
    var names: Set<String> = []
    /// An object's latest member name.
    var name = ""
    /// An array's items so far.
    var items = 0
  }

  /// The deepest nesting followed; deeper text is `malformed`. A definition nests three deep
  /// (the top, `open`, `open.arguments`), and `JSONSerialization` itself stops at 512.
  static let maximumDepth = 64

  /// The bytes of a number, `true`, `false` or `null` (their spelling is not checked).
  static let scalarBytes: Set<UInt8> = Set(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-.".utf8)
  /// What each one-character escape stands for.
  static let escapes: [UInt8: UInt8] = [
    UInt8(ascii: "\""): 0x22, UInt8(ascii: "\\"): 0x5C, UInt8(ascii: "/"): 0x2F,
    UInt8(ascii: "b"): 0x08, UInt8(ascii: "f"): 0x0C, UInt8(ascii: "n"): 0x0A,
    UInt8(ascii: "r"): 0x0D, UInt8(ascii: "t"): 0x09,
  ]
  /// A quotation mark.
  static let quote = UInt8(ascii: "\"")
  /// A backslash.
  static let backslash = UInt8(ascii: "\\")

  /// The text scanned.
  private let bytes: [UInt8]
  /// The next byte to read.
  private var index: Int
  /// The containers open at `index`, outermost first.
  private var stack: [Frame] = []
  /// Whether the root value has started.
  private var rootSeen = false

  /// A scanner at the start of `bytes`, past a UTF-8 byte order mark.
  private init(bytes: [UInt8]) {
    self.bytes = bytes
    index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
  }

  /// Scans `data`, JSON text `JSONSerialization` accepted, for a member name used twice in
  /// one object (the first one found, in text order).
  static func scan(_ data: Data) -> Finding {
    var scanner = JSONDuplicateNameScanner(bytes: [UInt8](data))
    return scanner.run()
  }

  /// Walks the text from start to end.
  private mutating func run() -> Finding {
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      switch byte {
      case 0x20, 0x09, 0x0A, 0x0D:
        continue
      case Self.quote:
        guard let text = readString() else { return .malformed }
        if let last = stack.indices.last, stack[last].isObject, stack[last].expecting == .name {
          guard stack[last].names.insert(text).inserted else {
            return .duplicate(Self.member(text, of: stack[last].path))
          }
          stack[last].name = text
          stack[last].expecting = .colon
        } else if startValue() == nil {
          return .malformed
        }
      case UInt8(ascii: "{"), UInt8(ascii: "["):
        guard stack.count < Self.maximumDepth, let path = startValue() else { return .malformed }
        let isObject = byte == UInt8(ascii: "{")
        stack.append(Frame(isObject: isObject, path: path, expecting: isObject ? .name : .value))
      case UInt8(ascii: "}"), UInt8(ascii: "]"):
        // Empty, after a value, or after a trailing comma.
        guard let frame = stack.popLast(), frame.isObject == (byte == UInt8(ascii: "}")),
          frame.expecting == .commaOrEnd || frame.expecting == (frame.isObject ? .name : .value)
        else { return .malformed }
      case UInt8(ascii: ","):
        guard let last = stack.indices.last, stack[last].expecting == .commaOrEnd else {
          return .malformed
        }
        stack[last].expecting = stack[last].isObject ? .name : .value
      case UInt8(ascii: ":"):
        guard let last = stack.indices.last, stack[last].expecting == .colon else {
          return .malformed
        }
        stack[last].expecting = .value
      case let scalar where Self.scalarBytes.contains(scalar):
        guard startValue() != nil else { return .malformed }
        while index < bytes.count, Self.scalarBytes.contains(bytes[index]) { index += 1 }
      default:
        return .malformed
      }
    } // End of loop over the bytes
    return stack.isEmpty && rootSeen ? .unique : .malformed
  } // End of func run()

  /// Marks a value starting here and returns the path a container starting here has (empty
  /// for the root), or `nil` when no value may start here (a second root, a member without
  /// its colon, a missing comma).
  private mutating func startValue() -> String? {
    guard let last = stack.indices.last else {
      guard !rootSeen else { return nil }
      rootSeen = true
      return ""
    }
    guard stack[last].expecting == .value else { return nil }
    stack[last].expecting = .commaOrEnd
    if stack[last].isObject { return Self.member(stack[last].name, of: stack[last].path) }
    stack[last].items += 1
    let item = "item \(stack[last].items)"
    return stack[last].path.isEmpty ? item : "\(stack[last].path) \(item)"
  } // End of func startValue()

  /// Reads a string whose opening quote was just read, up to and past its closing quote, and
  /// returns its text with every escape decoded; `nil` when it is not a well-formed JSON
  /// string (unterminated, a control character, an unknown escape, a lone surrogate).
  private mutating func readString() -> String? {
    var text: [UInt8] = []
    while index < bytes.count {
      let byte = bytes[index]
      index += 1
      switch byte {
      case Self.quote:
        return String(decoding: text, as: UTF8.self)
      case Self.backslash:
        guard index < bytes.count else { return nil }
        let escape = bytes[index]
        index += 1
        if escape == UInt8(ascii: "u") {
          guard let scalar = readUnicodeEscape() else { return nil }
          text.append(contentsOf: String(scalar).utf8)
        } else if let decoded = Self.escapes[escape] {
          text.append(decoded)
        } else {
          return nil
        }
      case 0..<0x20:
        return nil
      default:
        text.append(byte)
      }
    } // End of loop over the string's bytes
    return nil
  } // End of func readString()

  /// Reads the four hex digits after `\u` (for a high surrogate also the `\uXXXX` low
  /// surrogate that must follow it) and returns the character, or `nil`.
  private mutating func readUnicodeEscape() -> Unicode.Scalar? {
    guard let unit = readHexUnit() else { return nil }
    switch unit {
    case 0xD800...0xDBFF:
      guard index + 1 < bytes.count, bytes[index] == Self.backslash,
        bytes[index + 1] == UInt8(ascii: "u")
      else { return nil }
      index += 2
      guard let low = readHexUnit(), (0xDC00...0xDFFF).contains(low) else { return nil }
      return Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
    case 0xDC00...0xDFFF:
      return nil
    default:
      return Unicode.Scalar(unit)
    }
  } // End of func readUnicodeEscape()

  /// Reads four hex digits as a UTF-16 code unit, or `nil`.
  private mutating func readHexUnit() -> UInt32? {
    guard index + 4 <= bytes.count else { return nil }
    var unit: UInt32 = 0
    for byte in bytes[index..<index + 4] {
      guard let digit = Self.hexValue(byte) else { return nil }
      unit = unit << 4 | digit
    }
    index += 4
    return unit
  }

  /// The value of the hex digit `byte`, or `nil`.
  static func hexValue(_ byte: UInt8) -> UInt32? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(byte - UInt8(ascii: "0"))
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(byte - UInt8(ascii: "a") + 10)
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(byte - UInt8(ascii: "A") + 10)
    default: return nil
    }
  }

  /// The path of member `name` of the object at `path`.
  static func member(_ name: String, of path: String) -> String {
    path.isEmpty ? name : "\(path).\(name)"
  }
} // End of struct JSONDuplicateNameScanner
