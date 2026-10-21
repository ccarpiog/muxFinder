import Foundation

/// Reads protobuf wire-format bytes field by field.
///
/// Every read is bounds-checked against the end of the current message and throws
/// `ProtoWireError` instead of trapping. Each call that returns a value consumes at least one
/// byte, so decode loops always end. Embedded messages are read through nested readers that
/// share the same storage (no copying) and count their depth.
///
/// A reader can also span several occurrences of one embedded-message field, merged by
/// `ProtoMessageField`. Each occurrence is a segment of the shared storage; `nextField()` moves
/// from one to the next, and every value must end inside the segment its key starts in, as it
/// would if each occurrence were parsed on its own.
///
/// A typical decode loop:
///
/// ```swift
/// while let field = try reader.nextField() {
///   switch (field.number, field.wireType) {
///   case (1, .lengthDelimited): name = try reader.readString()
///   default: try reader.skip(field.wireType)
///   }
/// }
/// ```
public struct ProtoReader: Sendable {
  /// The whole input; nested readers share it.
  private let storage: [UInt8]
  /// The next byte to read.
  private var position: Int
  /// One past the last byte of the current segment: the whole message, or the occurrence being
  /// read when the reader spans several merged occurrences.
  private var end: Int
  /// The merged occurrences still to read after the current segment, in wire order.
  private var pendingSegments: ArraySlice<Range<Int>> = []
  /// How many embedded messages enclose the current one (0 for the outermost).
  public let depth: Int

  /// Creates a reader over `data`.
  public init(_ data: Data) {
    self.init(bytes: [UInt8](data))
  }

  /// Creates a reader over `bytes`.
  public init(bytes: [UInt8]) {
    self.init(storage: bytes, start: 0, end: bytes.count, depth: 0)
  }

  /// Creates a reader over `storage[start..<end]` at the given depth.
  private init(storage: [UInt8], start: Int, end: Int, depth: Int) {
    self.storage = storage
    self.position = start
    self.end = end
    self.depth = depth
  }

  /// Whether every byte of the current message (every merged occurrence) has been read.
  public var isAtEnd: Bool {
    position >= end && pendingSegments.allSatisfy(\.isEmpty)
  }

  /// Reads the next field key, or returns `nil` at the end of the message. At the end of one
  /// merged occurrence, continues with the next.
  public mutating func nextField() throws -> ProtoFieldKey? {
    while position >= end, let segment = pendingSegments.popFirst() {
      position = segment.lowerBound
      end = segment.upperBound
    }
    guard position < end else { return nil }
    let key = try readVarint()
    let fieldNumber = key >> 3
    guard fieldNumber >= 1, fieldNumber <= UInt64(ProtoWire.maximumFieldNumber) else {
      throw ProtoWireError.invalidFieldNumber
    }
    let rawWireType = UInt8(key & 0x07)
    guard let wireType = ProtoWireType(rawValue: rawWireType) else {
      throw ProtoWireError.unsupportedWireType(rawWireType)
    }
    return ProtoFieldKey(number: Int(fieldNumber), wireType: wireType)
  } // End of func nextField()

  /// Reads a base-128 varint of at most 10 bytes.
  public mutating func readVarint() throws -> UInt64 {
    var result: UInt64 = 0
    for index in 0..<ProtoWire.maximumVarintLength {
      guard position < end else { throw ProtoWireError.truncated }
      let byte = storage[position]
      position += 1
      if index == ProtoWire.maximumVarintLength - 1 && byte > 0x01 {
        // The tenth byte may only carry bit 63 and must end the varint.
        throw ProtoWireError.overlongVarint
      }
      result |= UInt64(byte & 0x7F) << UInt64(7 * index)
      if byte & 0x80 == 0 { return result }
    } // End of loop over varint bytes
    throw ProtoWireError.overlongVarint
  } // End of func readVarint()

  /// Reads a `uint64` value.
  public mutating func readUInt64() throws -> UInt64 {
    try readVarint()
  }

  /// Reads a `uint32` value; like protobuf, keeps the low 32 bits.
  public mutating func readUInt32() throws -> UInt32 {
    UInt32(truncatingIfNeeded: try readVarint())
  }

  /// Reads an `int64` value.
  public mutating func readInt64() throws -> Int64 {
    Int64(bitPattern: try readVarint())
  }

  /// Reads an `int32` value; like protobuf, keeps the low 32 bits, so both the 10-byte
  /// sign-extended form and a 5-byte form of a negative number decode correctly.
  public mutating func readInt32() throws -> Int32 {
    Int32(truncatingIfNeeded: try readVarint())
  }

  /// Reads a `bool` value: any nonzero varint is `true`.
  public mutating func readBool() throws -> Bool {
    try readVarint() != 0
  }

  /// Reads an enum value as its number (enums travel like `int32`).
  public mutating func readEnum() throws -> Int {
    Int(try readInt32())
  }

  /// Reads a `fixed64` value (eight little-endian bytes).
  public mutating func readFixed64() throws -> UInt64 {
    let range = try advance(by: 8, orThrow: .truncated)
    var value: UInt64 = 0
    for (offset, index) in range.enumerated() {
      value |= UInt64(storage[index]) << UInt64(8 * offset)
    }
    return value
  }

  /// Reads a `fixed32` value (four little-endian bytes).
  public mutating func readFixed32() throws -> UInt32 {
    let range = try advance(by: 4, orThrow: .truncated)
    var value: UInt32 = 0
    for (offset, index) in range.enumerated() {
      value |= UInt32(storage[index]) << UInt32(8 * offset)
    }
    return value
  }

  /// Reads a `bytes` value.
  public mutating func readBytes() throws -> Data {
    Data(storage[try readLengthDelimitedRange()])
  }

  /// Reads a `string` value. Invalid UTF-8 is replaced with U+FFFD rather than rejected
  /// (`proto2` does not require valid UTF-8, and a stray byte in a title must not fail a whole
  /// response).
  public mutating func readString() throws -> String {
    String(decoding: storage[try readLengthDelimitedRange()], as: UTF8.self)
  }

  /// Reads an embedded message's bytes and returns a reader over them, one level deeper.
  public mutating func readNestedReader() throws -> ProtoReader {
    let range = try readLengthDelimitedRange()
    guard depth < ProtoWire.maximumNestingDepth else { throw ProtoWireError.nestingTooDeep }
    return ProtoReader(
      storage: storage,
      start: range.lowerBound,
      end: range.upperBound,
      depth: depth + 1
    )
  } // End of func readNestedReader()

  /// Reads and decodes one embedded message on its own. Use it for elements of repeated fields;
  /// a singular embedded-message field merges its occurrences through `ProtoMessageField`.
  public mutating func readMessage<Message: ProtoDecodable>(
    _ type: Message.Type
  ) throws -> Message {
    var nested = try readNestedReader()
    return try Message(from: &nested)
  }

  /// Appends the unread bytes of `occurrence`, a later occurrence of the same field read from
  /// the same parent reader, as further segments of this reader.
  fileprivate mutating func appendSegments(of occurrence: ProtoReader) {
    precondition(
      occurrence.depth == depth && occurrence.sharesStorage(with: self),
      "merged protobuf occurrences must come from the same parent reader"
    )
    let segments = [occurrence.position..<occurrence.end] + occurrence.pendingSegments
    pendingSegments.append(contentsOf: segments.filter { !$0.isEmpty })
  }

  /// Whether `other` reads the same input buffer as this reader.
  private func sharesStorage(with other: ProtoReader) -> Bool {
    storage.withUnsafeBufferPointer { mine in
      other.storage.withUnsafeBufferPointer { theirs in mine.baseAddress == theirs.baseAddress }
    }
  }

  /// Skips the value of a field whose key was just read. Varints are validated; fixed-width and
  /// length-delimited values are bounds-checked.
  public mutating func skip(_ wireType: ProtoWireType) throws {
    switch wireType {
    case .varint: _ = try readVarint()
    case .fixed64: _ = try advance(by: 8, orThrow: .truncated)
    case .lengthDelimited: _ = try readLengthDelimitedRange()
    case .fixed32: _ = try advance(by: 4, orThrow: .truncated)
    }
  }

  /// Reads a length prefix and returns the range of the bytes it covers, moving past them.
  private mutating func readLengthDelimitedRange() throws -> Range<Int> {
    let length = try readVarint()
    guard length <= UInt64(end - position) else { throw ProtoWireError.lengthExceedsInput }
    return try advance(by: Int(length), orThrow: .lengthExceedsInput)
  }

  /// Moves past the next `count` bytes and returns their range, or throws `error` if fewer are
  /// left in the current segment.
  private mutating func advance(by count: Int, orThrow error: ProtoWireError) throws -> Range<Int> {
    guard count <= end - position else { throw error }
    let range = position..<(position + count)
    position += count
    return range
  }
} // End of struct ProtoReader

/// A singular embedded-message field whose occurrences merge the way protobuf merges them.
///
/// In `proto2`, a singular embedded message that appears more than once is one message: its
/// scalar fields keep their last value, its repeated fields append, and its own embedded
/// messages merge in turn. Parsing the concatenation of the occurrences' bytes gives exactly
/// that, so this keeps every occurrence as a segment of one reader and decodes them together
/// once the enclosing message has been read. The segments are ranges of the input (nothing is
/// copied), so the merged message is never larger than the input, and it sits one nesting level
/// below its parent like any embedded message, so `ProtoWire.maximumNestingDepth` still holds.
///
/// ```swift
/// var root = ProtoMessageField()
/// while let field = try reader.nextField() {
///   switch (field.number, field.wireType) {
///   case (3, .lengthDelimited): try root.merge(from: &reader)
///   default: try reader.skip(field.wireType)
///   }
/// }
/// let node = try root.decode(SplitTreeNode.self)
/// ```
public struct ProtoMessageField: Sendable {
  /// A reader over every occurrence so far; `nil` until the first one.
  private var merged: ProtoReader?

  /// Creates a field that has not appeared yet.
  public init() {}

  /// Whether the field has appeared at least once (an empty occurrence counts).
  public var isPresent: Bool { merged != nil }

  /// Reads an occurrence from `parent`, whose key was just read, and merges it with the earlier
  /// ones. Every occurrence must come from the same `parent`.
  public mutating func merge(from parent: inout ProtoReader) throws {
    let occurrence = try parent.readNestedReader()
    if merged == nil {
      merged = occurrence
    } else {
      merged?.appendSegments(of: occurrence)
    }
  }

  /// Decodes the merged occurrences with `decoder`, or returns `nil` if the field never appeared.
  public func decode<Value>(with decoder: (inout ProtoReader) throws -> Value) throws -> Value? {
    guard var reader = merged else { return nil }
    return try decoder(&reader)
  }

  /// Decodes the merged occurrences as `Message`, or returns `nil` if the field never appeared.
  public func decode<Message: ProtoDecodable>(_ type: Message.Type) throws -> Message? {
    try decode { try Message(from: &$0) }
  }
} // End of struct ProtoMessageField

/// The member of a oneof that appeared last, with the occurrences of an embedded-message member
/// merged.
///
/// In a oneof the last member on the wire wins, and setting a member clears the one before it.
/// So occurrences of the same member merge only until a different member appears: A, A merges
/// both; A, B, A keeps only the last A. Field numbers that are not members of the oneof must not
/// be passed in; like any unknown field, they are skipped and leave the oneof alone.
public struct ProtoOneof: Sendable {
  /// The field number of the member that appeared last; `nil` if none has.
  public private(set) var fieldNumber: Int?
  /// The merged occurrences of that member since it last became the member, when it is an
  /// embedded message; empty otherwise.
  public private(set) var message = ProtoMessageField()

  /// Creates a oneof with no member set.
  public init() {}

  /// Reads an occurrence of the embedded-message member `fieldNumber` from `parent`, whose key
  /// was just read. It merges with the earlier occurrences if `fieldNumber` is already the
  /// member, and replaces the previous member otherwise.
  public mutating func mergeMessage(_ fieldNumber: Int, from parent: inout ProtoReader) throws {
    if self.fieldNumber != fieldNumber {
      self.fieldNumber = fieldNumber
      message = ProtoMessageField()
    }
    try message.merge(from: &parent)
  }

  /// Records that the scalar member `fieldNumber` (a string, a number…) appeared; the caller
  /// keeps its value. It replaces the previous member and drops any merged message.
  public mutating func selectScalar(_ fieldNumber: Int) {
    self.fieldNumber = fieldNumber
    message = ProtoMessageField()
  }
} // End of struct ProtoOneof
