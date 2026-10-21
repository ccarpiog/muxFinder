import Foundation

/// Builds protobuf wire-format bytes field by field.
///
/// Field numbers come from this package's message definitions, never from input, so an invalid
/// one is a programming error and traps.
public struct ProtoWriter: Sendable {
  /// The bytes written so far.
  public private(set) var bytes: [UInt8] = []

  /// Creates an empty writer.
  public init() {}

  /// Appends `value` as a base-128 varint (1 to 10 bytes).
  public mutating func writeVarint(_ value: UInt64) {
    var remaining = value
    while remaining >= 0x80 {
      bytes.append(UInt8(truncatingIfNeeded: remaining) | 0x80)
      remaining >>= 7
    }
    bytes.append(UInt8(remaining))
  }

  /// Appends a field key.
  public mutating func writeKey(_ fieldNumber: Int, _ wireType: ProtoWireType) {
    precondition(
      (1...ProtoWire.maximumFieldNumber).contains(fieldNumber),
      "protobuf field number out of range"
    )
    writeVarint(UInt64(fieldNumber) << 3 | UInt64(wireType.rawValue))
  }

  /// Appends a `uint64` field.
  public mutating func writeUInt64(_ fieldNumber: Int, _ value: UInt64) {
    writeKey(fieldNumber, .varint)
    writeVarint(value)
  }

  /// Appends a `uint32` field.
  public mutating func writeUInt32(_ fieldNumber: Int, _ value: UInt32) {
    writeUInt64(fieldNumber, UInt64(value))
  }

  /// Appends an `int64` field (negative values take 10 bytes).
  public mutating func writeInt64(_ fieldNumber: Int, _ value: Int64) {
    writeUInt64(fieldNumber, UInt64(bitPattern: value))
  }

  /// Appends an `int32` field. Negative values are sign-extended to 64 bits and take 10 bytes,
  /// as protobuf requires.
  public mutating func writeInt32(_ fieldNumber: Int, _ value: Int32) {
    writeInt64(fieldNumber, Int64(value))
  }

  /// Appends a `bool` field (`1` or `0`).
  public mutating func writeBool(_ fieldNumber: Int, _ value: Bool) {
    writeUInt64(fieldNumber, value ? 1 : 0)
  }

  /// Appends an enum field; enums travel like `int32`.
  public mutating func writeEnum(_ fieldNumber: Int, _ value: Int32) {
    writeInt32(fieldNumber, value)
  }

  /// Appends a `fixed64` field (eight little-endian bytes).
  public mutating func writeFixed64(_ fieldNumber: Int, _ value: UInt64) {
    writeKey(fieldNumber, .fixed64)
    for shift in stride(from: 0, to: 64, by: 8) {
      bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
    }
  }

  /// Appends a `fixed32` field (four little-endian bytes).
  public mutating func writeFixed32(_ fieldNumber: Int, _ value: UInt32) {
    writeKey(fieldNumber, .fixed32)
    for shift in stride(from: 0, to: 32, by: 8) {
      bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
    }
  }

  /// Appends a `bytes` field.
  public mutating func writeBytes(_ fieldNumber: Int, _ value: some Collection<UInt8>) {
    writeKey(fieldNumber, .lengthDelimited)
    writeVarint(UInt64(value.count))
    bytes.append(contentsOf: value)
  }

  /// Appends a `string` field as UTF-8.
  public mutating func writeString(_ fieldNumber: Int, _ value: String) {
    writeBytes(fieldNumber, Array(value.utf8))
  }

  /// Appends an embedded message field.
  public mutating func writeMessage(_ fieldNumber: Int, _ message: some ProtoEncodable) {
    var nested = ProtoWriter()
    message.encode(to: &nested)
    writeBytes(fieldNumber, nested.bytes)
  }

  /// Appends an embedded message field whose fields `build` writes. An empty `build` writes an
  /// empty message, which still marks the field as present.
  public mutating func writeMessage(_ fieldNumber: Int, _ build: (inout ProtoWriter) -> Void) {
    var nested = ProtoWriter()
    build(&nested)
    writeBytes(fieldNumber, nested.bytes)
  }
}
