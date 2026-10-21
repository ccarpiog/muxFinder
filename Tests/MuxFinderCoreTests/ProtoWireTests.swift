import Foundation
import Testing

@testable import MuxFinderCore

/// One malformed protobuf input and the error decoding it must produce.
struct MalformedProto: Sendable, CustomTestStringConvertible {
  /// What is wrong, for the test log.
  let label: String
  /// The input bytes.
  let bytes: [UInt8]
  /// The expected error.
  let error: ProtoWireError

  /// The label.
  var testDescription: String { label }
}

/// Reads every field of `bytes` with `skip`, the way a decoder treats unknown fields, and
/// returns the field numbers seen.
private func skipAll(_ bytes: [UInt8]) throws -> [Int] {
  var reader = ProtoReader(bytes: bytes)
  var numbers: [Int] = []
  while let field = try reader.nextField() {
    numbers.append(field.number)
    try reader.skip(field.wireType)
  }
  return numbers
}

/// The bytes `build` writes.
private func written(_ build: (inout ProtoWriter) -> Void) -> [UInt8] {
  var writer = ProtoWriter()
  build(&writer)
  return writer.bytes
}

/// Tests for the hand-written protobuf codec: varint edge cases, every scalar encoding, unknown
/// field skipping for every wire type and typed errors for malformed input.
@Suite("Protobuf wire codec")
struct ProtoWireTests {
  /// Varints at the size boundaries and their protobuf reference encodings.
  static let varints: [(UInt64, [UInt8])] = [
    (0, [0x00]),
    (1, [0x01]),
    (127, [0x7F]),
    (128, [0x80, 0x01]),
    (300, [0xAC, 0x02]),
    (16_383, [0xFF, 0x7F]),
    (16_384, [0x80, 0x80, 0x01]),
    (UInt64(UInt32.max), [0xFF, 0xFF, 0xFF, 0xFF, 0x0F]),
    (UInt64(1) << 63, [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01]),
    (UInt64.max, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]),
  ]

  /// Varints at the size boundaries encode to the protobuf reference bytes and read back.
  @Test(arguments: varints)
  func varintRoundTrip(value: UInt64, bytes: [UInt8]) throws {
    let encoded = written { $0.writeVarint(value) }
    #expect(encoded == bytes)
    var reader = ProtoReader(bytes: bytes)
    #expect(try reader.readVarint() == value)
    #expect(reader.isAtEnd)
  }

  /// Negative `int32` values are sign-extended to 10-byte varints, as protobuf requires, and
  /// both that form and a 5-byte form read back.
  @Test func negativeInt32() throws {
    let minusOne = written { $0.writeInt32(1, -1) }
    #expect(minusOne == [0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
    let minimum = written { $0.writeInt32(1, .min) }
    #expect(minimum == [0x08, 0x80, 0x80, 0x80, 0x80, 0xF8, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
    var reader = ProtoReader(bytes: Array(minusOne.dropFirst()) + Array(minimum.dropFirst()))
    #expect(try reader.readInt32() == -1)
    #expect(try reader.readInt32() == .min)
    var short = ProtoReader(bytes: [0xFF, 0xFF, 0xFF, 0xFF, 0x0F])
    #expect(try short.readInt32() == -1)
    #expect(written { $0.writeInt32(1, .max) } == [0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0x07])
  } // End of func negativeInt32()

  /// `int64`, `uint32`, `bool` and enum values encode and decode like protobuf.
  @Test func otherVarintScalars() throws {
    let minimum = written { $0.writeInt64(1, .min) }
    #expect(minimum == [0x08, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01])
    var reader = ProtoReader(bytes: Array(minimum.dropFirst()))
    #expect(try reader.readInt64() == .min)
    #expect(written { $0.writeUInt32(3, .max) } == [0x18, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F])
    var wide = ProtoReader(bytes: [0x80, 0x80, 0x80, 0x80, 0x10]) // 2^32: low 32 bits are 0
    #expect(try wide.readUInt32() == 0)
    #expect(written { $0.writeBool(4, true) } == [0x20, 0x01])
    #expect(written { $0.writeBool(4, false) } == [0x20, 0x00])
    var bools = ProtoReader(bytes: [0x00, 0x01, 0x02])
    #expect(try bools.readBool() == false)
    #expect(try bools.readBool() == true)
    #expect(try bools.readBool() == true)
    #expect(written { $0.writeEnum(1, 2) } == [0x08, 0x02])
    var enums = ProtoReader(bytes: [
      0x02, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01,
    ])
    #expect(try enums.readEnum() == 2)
    #expect(try enums.readEnum() == -3)
  } // End of func otherVarintScalars()

  /// Fixed-width values are little-endian.
  @Test func fixedWidthValues() throws {
    let fixed64 = written { $0.writeFixed64(1, 0x0807_0605_0403_0201) }
    #expect(fixed64 == [0x09, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
    let fixed32 = written { $0.writeFixed32(2, 0xDDCC_BBAA) }
    #expect(fixed32 == [0x15, 0xAA, 0xBB, 0xCC, 0xDD])
    var reader = ProtoReader(bytes: fixed64 + fixed32)
    #expect(try reader.nextField() == ProtoFieldKey(number: 1, wireType: .fixed64))
    #expect(try reader.readFixed64() == 0x0807_0605_0403_0201)
    #expect(try reader.nextField() == ProtoFieldKey(number: 2, wireType: .fixed32))
    #expect(try reader.readFixed32() == 0xDDCC_BBAA)
    #expect(try reader.nextField() == nil)
  } // End of func fixedWidthValues()

  /// Strings, bytes and embedded messages are length-delimited; an empty embedded message is
  /// still written (it marks the field as present).
  @Test func lengthDelimitedValues() throws {
    let bytes = written { writer in
      writer.writeString(1, "hé🧪")
      writer.writeBytes(2, [0x00, 0xFF])
      writer.writeMessage(3) { $0.writeString(1, "inner") }
      writer.writeMessage(4) { _ in }
    }
    #expect(
      bytes == [0x0A, 0x07, 0x68, 0xC3, 0xA9, 0xF0, 0x9F, 0xA7, 0xAA, 0x12, 0x02, 0x00, 0xFF]
        + [0x1A, 0x07, 0x0A, 0x05] + Array("inner".utf8) + [0x22, 0x00])
    var reader = ProtoReader(bytes: bytes)
    _ = try reader.nextField()
    #expect(try reader.readString() == "hé🧪")
    _ = try reader.nextField()
    #expect(try reader.readBytes() == Data([0x00, 0xFF]))
    _ = try reader.nextField()
    var nested = try reader.readNestedReader()
    #expect(nested.depth == 1)
    #expect(try nested.nextField() == ProtoFieldKey(number: 1, wireType: .lengthDelimited))
    #expect(try nested.readString() == "inner")
    #expect(try nested.nextField() == nil)
    _ = try reader.nextField()
    var empty = try reader.readNestedReader()
    #expect(empty.isAtEnd)
    #expect(try empty.nextField() == nil)
    #expect(reader.isAtEnd)
  } // End of func lengthDelimitedValues()

  /// Invalid UTF-8 in a string becomes U+FFFD instead of failing the message.
  @Test func invalidUTF8IsReplaced() throws {
    var reader = ProtoReader(bytes: [0x03, 0x61, 0xFF, 0x62])
    #expect(try reader.readString() == "a\u{FFFD}b")
  }

  /// Unknown fields of every wire type are skipped and decoding continues with the next field.
  @Test func skipsUnknownFieldsOfEveryWireType() throws {
    let bytes = written { writer in
      writer.writeUInt64(99, .max)
      writer.writeString(1, "fixture-session")
      writer.writeFixed64(98, 0x0102_0304_0506_0708)
      writer.writeBytes(97, Array(repeating: 0xEE, count: 300))
      writer.writeMessage(96) { $0.writeString(1, "nested unknown") }
      writer.writeFixed32(95, 0xFFFF_FFFF)
      writer.writeString(4, "fixture-title")
      writer.writeUInt64(ProtoWire.maximumFieldNumber, 1)
    }
    #expect(try skipAll(bytes) == [99, 1, 98, 97, 96, 95, 4, ProtoWire.maximumFieldNumber])
    let summary = try ITerm2API.SessionSummary(decoding: Data(bytes))
    #expect(summary == .init(uniqueIdentifier: "fixture-session", title: "fixture-title"))
  } // End of func skipsUnknownFieldsOfEveryWireType()

  /// A known field number with an unexpected wire type is skipped like an unknown field.
  @Test func skipsKnownFieldsWithTheWrongWireType() throws {
    let bytes = written { writer in
      writer.writeUInt64(1, 5)
      writer.writeFixed32(4, 1)
      writer.writeString(4, "fixture-title")
    }
    let summary = try ITerm2API.SessionSummary(decoding: Data(bytes))
    #expect(summary == .init(uniqueIdentifier: nil, title: "fixture-title"))
  }

  /// Malformed inputs, each with the typed error it must produce. Each is decoded both as raw
  /// fields and as a full response envelope.
  static let malformed: [MalformedProto] = [
    MalformedProto(label: "truncated key", bytes: [0x80], error: .truncated),
    MalformedProto(label: "key without value", bytes: [0x08], error: .truncated),
    MalformedProto(label: "truncated varint", bytes: [0x08, 0xFF, 0x80], error: .truncated),
    MalformedProto(label: "truncated length prefix", bytes: [0x12, 0x80], error: .truncated),
    MalformedProto(
      label: "truncated length-delimited", bytes: [0x12, 0x05, 0x61, 0x62],
      error: .lengthExceedsInput),
    MalformedProto(
      label: "length past end (2^63 - 1)",
      bytes: [0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F],
      error: .lengthExceedsInput),
    MalformedProto(
      label: "length past end (UInt64.max)",
      bytes: [0x12, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01],
      error: .lengthExceedsInput),
    MalformedProto(
      label: "truncated fixed64", bytes: [0x09, 1, 2, 3, 4, 5, 6, 7], error: .truncated),
    MalformedProto(label: "truncated fixed32", bytes: [0x0D, 1, 2, 3], error: .truncated),
    MalformedProto(
      label: "overlong varint (11 bytes)",
      bytes: [0x08] + Array(repeating: 0x80, count: 10) + [0x00],
      error: .overlongVarint),
    MalformedProto(
      label: "varint overflowing 64 bits",
      bytes: [0x08] + Array(repeating: 0xFF, count: 9) + [0x02],
      error: .overlongVarint),
    MalformedProto(
      label: "overlong key", bytes: Array(repeating: 0x80, count: 11), error: .overlongVarint),
    MalformedProto(
      label: "wire type 3 (start group)", bytes: [0x0B], error: .unsupportedWireType(3)),
    MalformedProto(label: "wire type 4 (end group)", bytes: [0x0C], error: .unsupportedWireType(4)),
    MalformedProto(label: "wire type 6", bytes: [0x0E, 0x00], error: .unsupportedWireType(6)),
    MalformedProto(label: "wire type 7", bytes: [0x0F, 0x00], error: .unsupportedWireType(7)),
    MalformedProto(
      label: "field number 0, varint", bytes: [0x00, 0x00], error: .invalidFieldNumber),
    MalformedProto(
      label: "field number 0, length-delimited", bytes: [0x02, 0x00], error: .invalidFieldNumber),
    MalformedProto(
      label: "field number 2^29", bytes: [0x80, 0x80, 0x80, 0x80, 0x10, 0x00],
      error: .invalidFieldNumber),
  ]

  /// Every malformed input produces its typed error when its fields are skipped.
  @Test(arguments: malformed)
  func malformedFieldsThrowTypedErrors(_ input: MalformedProto) {
    #expect(throws: input.error) { try skipAll(input.bytes) }
  }

  /// Every malformed input produces its typed error inside a response envelope, both at the top
  /// level (after a valid id) and nested inside a response message.
  @Test(arguments: malformed)
  func malformedEnvelopesThrowTypedErrors(_ input: MalformedProto) {
    let topLevel = [0x08, 0x01] + input.bytes
    #expect(throws: input.error) {
      try ITerm2API.ServerOriginatedMessage(decoding: Data(topLevel))
    }
    // Inside create_tab_response (108): the nested reader's bounds apply.
    let nested = written { $0.writeBytes(108, input.bytes) }
    #expect(throws: input.error) {
      try ITerm2API.ServerOriginatedMessage(decoding: Data(nested))
    }
  } // End of func malformedEnvelopesThrowTypedErrors(_:)

  /// A nested length that fits the input but not its parent message is rejected.
  @Test func nestedLengthPastParentEnd() {
    // windows (1) holds 2 bytes: a tabs (1) field claiming 5 more bytes, which exist only
    // after the window ends.
    let bytes: [UInt8] = [0x0A, 0x02, 0x0A, 0x05, 0x61, 0x62, 0x63, 0x64, 0x65]
    #expect(throws: ProtoWireError.lengthExceedsInput) {
      try ITerm2API.ListSessionsResponse(decoding: Data(bytes))
    }
  }

  /// Nesting is allowed up to `ProtoWire.maximumNestingDepth` and rejected one level deeper.
  @Test func nestingDepthLimit() throws {
    /// `levels` embedded messages, each the only field (1) of its parent.
    func nested(_ levels: Int) -> [UInt8] {
      var bytes: [UInt8] = []
      for _ in 0..<levels { bytes = written { $0.writeBytes(1, bytes) } }
      return bytes
    }
    /// Descends through every level and returns the deepest reader's depth.
    func descend(_ bytes: [UInt8]) throws -> Int {
      var reader = ProtoReader(bytes: bytes)
      while try reader.nextField() != nil { reader = try reader.readNestedReader() }
      return reader.depth
    }
    let limit = ProtoWire.maximumNestingDepth
    #expect(try descend(nested(limit)) == limit)
    #expect(throws: ProtoWireError.nestingTooDeep) { try descend(nested(limit + 1)) }
  } // End of func nestingDepthLimit()

  /// A split tree nested far beyond the limit fails with a typed error instead of exhausting
  /// the stack, and a realistic depth decodes.
  @Test func deepSplitTreesAreBounded() throws {
    /// A node whose only link holds the previous node, `levels` times.
    func tree(_ levels: Int) -> [UInt8] {
      var node = written { $0.writeMessage(2) { $0.writeMessage(1) { $0.writeString(1, "s") } } }
      for _ in 0..<levels {
        let link = written { $0.writeBytes(2, node) }
        node = written { $0.writeBytes(2, link) }
      }
      return node
    }
    let shallow = try ITerm2API.SplitTreeNode(decoding: Data(tree(10)))
    #expect(shallow.sessions.map(\.uniqueIdentifier) == ["s"])
    #expect(throws: ProtoWireError.nestingTooDeep) {
      try ITerm2API.SplitTreeNode(decoding: Data(tree(1_000)))
    }
  } // End of func deepSplitTreesAreBounded()

  /// Occurrences of a singular embedded message read as one message: fields from every
  /// occurrence, scalars last-wins, unknown fields in between ignored, empty occurrences kept as
  /// presence only.
  @Test func singularMessageOccurrencesMerge() throws {
    let bytes = written { writer in
      writer.writeMessage(3) { $0.writeString(1, "first-id") }
      writer.writeString(9, "unknown between occurrences")
      writer.writeMessage(3) { _ in }
      writer.writeMessage(3) {
        $0.writeString(4, "fixture-title")
        $0.writeString(1, "fixture-session")
      }
    }
    var reader = ProtoReader(bytes: bytes)
    var field = ProtoMessageField()
    #expect(!field.isPresent)
    while let key = try reader.nextField() {
      if key.number == 3 { try field.merge(from: &reader) } else { try reader.skip(key.wireType) }
    }
    #expect(field.isPresent)
    #expect(
      try field.decode(ITerm2API.SessionSummary.self)
        == .init(uniqueIdentifier: "fixture-session", title: "fixture-title"))
    let fieldNumbers = try field.decode { merged -> [Int] in
      var numbers: [Int] = []
      while let key = try merged.nextField() {
        numbers.append(key.number)
        try merged.skip(key.wireType)
        if merged.isAtEnd { numbers.append(0) }
      }
      return numbers
    }
    #expect(fieldNumbers == [1, 4, 1, 0])
    #expect(try ProtoMessageField().decode(ITerm2API.SessionSummary.self) == nil)
  } // End of func singularMessageOccurrencesMerge()

  /// A value never runs from one occurrence into the next: each occurrence must parse on its
  /// own, as protobuf (`api_pb2` raises `DecodeError` here) requires. Concatenated, these two
  /// `root` occurrences would read as `vertical = true`.
  @Test func valuesCannotSpanOccurrences() {
    let bytes = written { writer in
      writer.writeBytes(3, [0x08])
      writer.writeBytes(3, [0x01])
    }
    #expect(throws: ProtoWireError.truncated) { try ITerm2API.Tab(decoding: Data(bytes)) }
  }

  /// In a split-tree link's `child` oneof, occurrences of the same member merge until the other
  /// member appears, which replaces it.
  @Test func linkOneofMergesUntilTheMemberChanges() throws {
    let merged = written { node in
      node.writeMessage(2) { link in
        link.writeMessage(1) { $0.writeString(1, "fixture-session") }
        link.writeMessage(1) { $0.writeString(4, "fixture-title") }
      }
      node.writeMessage(2) { link in
        link.writeMessage(1) { $0.writeString(1, "dropped-session") }
        link.writeMessage(2) { $0.writeBool(1, true) }
        link.writeMessage(1) { $0.writeString(4, "fixture-title") }
      }
      node.writeMessage(2) { link in
        link.writeMessage(1) { $0.writeString(1, "dropped-session") }
        link.writeMessage(2) { $0.writeBool(1, true) }
        link.writeMessage(2) { $0.writeMessage(2) { $0.writeMessage(1) { _ in } } }
      }
    }
    let node = try ITerm2API.SplitTreeNode(decoding: Data(merged))
    #expect(
      node.links == [
        .session(.init(uniqueIdentifier: "fixture-session", title: "fixture-title")),
        .session(.init(uniqueIdentifier: nil, title: "fixture-title")),
        .node(.init(vertical: true, links: [.session(.init())])),
      ])
  } // End of func linkOneofMergesUntilTheMemberChanges()

  /// Merged occurrences sit one level below their parent like any embedded message, so a tree
  /// whose every link carries its node twice is still stopped by the nesting limit.
  @Test func mergedOccurrencesKeepTheNestingLimit() throws {
    /// A node whose only link holds the previous node, then an empty second `node` occurrence,
    /// `levels` times.
    func tree(_ levels: Int) -> [UInt8] {
      var node = written { $0.writeMessage(2) { $0.writeMessage(1) { $0.writeString(1, "s") } } }
      for _ in 0..<levels {
        let link = written { link in
          link.writeBytes(2, node)
          link.writeMessage(2) { _ in }
        }
        node = written { $0.writeBytes(2, link) }
      }
      return node
    } // End of func tree(_:)
    let shallow = try ITerm2API.SplitTreeNode(decoding: Data(tree(10)))
    #expect(shallow.sessions.map(\.uniqueIdentifier) == ["s"])
    #expect(throws: ProtoWireError.nestingTooDeep) {
      try ITerm2API.SplitTreeNode(decoding: Data(tree(1_000)))
    }
  } // End of func mergedOccurrencesKeepTheNestingLimit()

  /// An empty input is a valid, empty message.
  @Test func emptyInputIsAnEmptyMessage() throws {
    let message = try ITerm2API.ServerOriginatedMessage(decoding: Data())
    #expect(message == .init(id: nil, response: nil))
    #expect(try skipAll([]) == [])
  }
}
