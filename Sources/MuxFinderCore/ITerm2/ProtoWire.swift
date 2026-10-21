import Foundation

/// Shared definitions of the minimal protobuf (`proto2`) wire codec used for iTerm2's API.
///
/// The codec is hand-written (PLAN.md D1): no SwiftProtobuf and no code generated from iTerm2's
/// `api.proto`. `ProtoWriter` encodes, `ProtoReader` decodes, and the typed messages in
/// `ITerm2API` sit on top of them.
public enum ProtoWire {
  /// The largest valid field number, 2^29 - 1.
  public static let maximumFieldNumber = 536_870_911
  /// The most bytes a varint may take (a 64-bit value needs 10).
  public static let maximumVarintLength = 10
  /// How deep embedded messages may nest before decoding stops with
  /// `ProtoWireError.nestingTooDeep` (protobuf's usual recursion limit). Each split level of an
  /// iTerm2 tab costs two (link and node), and real trees are a few levels deep; the limit only
  /// keeps hostile input from exhausting the stack.
  public static let maximumNestingDepth = 100
}

/// The wire types the codec accepts. Groups (3 and 4) and the unassigned values 6 and 7 are
/// rejected with `ProtoWireError.unsupportedWireType`.
public enum ProtoWireType: UInt8, Sendable, Hashable {
  /// Varint: int32, int64, uint32, uint64, bool, enum.
  case varint = 0
  /// Eight little-endian bytes: fixed64, sfixed64, double.
  case fixed64 = 1
  /// A varint length followed by that many bytes: string, bytes, embedded message, packed
  /// repeated scalars.
  case lengthDelimited = 2
  /// Four little-endian bytes: fixed32, sfixed32, float.
  case fixed32 = 5
}

/// The key that starts every field on the wire: a field number and a wire type.
public struct ProtoFieldKey: Sendable, Hashable {
  /// The field number, `1...ProtoWire.maximumFieldNumber`.
  public var number: Int
  /// How the field's value is encoded.
  public var wireType: ProtoWireType

  /// Creates a field key.
  public init(number: Int, wireType: ProtoWireType) {
    self.number = number
    self.wireType = wireType
  }
}

/// Why protobuf bytes could not be decoded. Decoding never traps: every malformed input ends in
/// one of these.
public enum ProtoWireError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The input ends inside a field key, varint or fixed-width value.
  case truncated
  /// A varint runs past 10 bytes, or its tenth byte holds more than the 64th bit.
  case overlongVarint
  /// A length-delimited field claims more bytes than are left in its message.
  case lengthExceedsInput
  /// A field key holds field number 0, or one above `ProtoWire.maximumFieldNumber`.
  case invalidFieldNumber
  /// A field key holds a group wire type (3 or 4) or an unassigned one (6 or 7).
  case unsupportedWireType(UInt8)
  /// Embedded messages nest deeper than `ProtoWire.maximumNestingDepth`.
  case nestingTooDeep

  /// An English explanation for logs; it never quotes input bytes.
  public var description: String {
    switch self {
    case .truncated:
      return "Protobuf input ends in the middle of a value."
    case .overlongVarint:
      return "Protobuf varint is longer than 10 bytes or overflows 64 bits."
    case .lengthExceedsInput:
      return "Protobuf length-delimited field runs past the end of its message."
    case .invalidFieldNumber:
      return "Protobuf field number is 0 or too large."
    case .unsupportedWireType(let wireType):
      return "Protobuf wire type \(wireType) is not supported."
    case .nestingTooDeep:
      return "Protobuf messages nest too deeply."
    }
  } // End of var description
}

/// A message that can be written in protobuf wire format.
public protocol ProtoEncodable: Sendable {
  /// Appends the message's fields to `writer`, in field-number order (as protobuf's
  /// `SerializeToString` does).
  func encode(to writer: inout ProtoWriter)
}

extension ProtoEncodable {
  /// The message in protobuf wire format.
  public func encode() -> Data {
    var writer = ProtoWriter()
    encode(to: &writer)
    return Data(writer.bytes)
  }
}

/// A message that can be read from protobuf wire format.
///
/// Decoders follow protobuf's (`proto2`) rules: unknown fields, and known field numbers that
/// arrive with an unexpected wire type, are skipped without affecting anything else; a singular
/// scalar field that appears more than once keeps its last value; repeated fields append; a
/// singular embedded message that appears more than once merges its occurrences
/// (`ProtoMessageField`); in a oneof the last member wins, and occurrences of the same
/// embedded-message member merge until a different member appears (`ProtoOneof`).
public protocol ProtoDecodable: Sendable {
  /// Reads the message's fields from `reader` until it is at its end.
  init(from reader: inout ProtoReader) throws
}

extension ProtoDecodable {
  /// Decodes a message from protobuf bytes. Throws `ProtoWireError` for malformed input.
  public init(decoding data: Data) throws {
    var reader = ProtoReader(data)
    try self.init(from: &reader)
  }
}
