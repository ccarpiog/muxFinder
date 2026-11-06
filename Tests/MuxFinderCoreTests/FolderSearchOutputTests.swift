import Foundation
import Testing

@testable import MuxFinderCore

/// `FolderSearchOutputParser` (PLAN.md D36): the header, NUL-separated paths, end records,
/// stale ids, truncation, oversized records and garbage, on synthetic output only.
@Suite("Folder search output")
struct FolderSearchOutputTests {
  /// `text` as one record: its UTF-8 bytes and a NUL.
  static func record(_ text: String) -> [UInt8] {
    Array(text.utf8) + [0]
  }

  /// A header's records, with these values.
  static func header(
    home: String = "/Users/example", mdfind: String = "yes", homeIndex: String = "on",
    diskIndex: String = "on", desktop: String = "yes", documents: String = "no",
    downloads: String = "missing"
  ) -> [UInt8] {
    [
      "muxfinder-folders 1", "home \(home)", "mdfind \(mdfind)", "index home \(homeIndex)",
      "index disk \(diskIndex)", "readable Desktop \(desktop)", "readable Documents \(documents)",
      "readable Downloads \(downloads)", "ready",
    ].flatMap(record)
  } // End of static func header(home:mdfind:homeIndex:diskIndex:desktop:documents:downloads:)

  /// The header `header()` describes.
  static let expectedHeader = FolderSearchHeader(
    homeDirectory: "/Users/example", hasSpotlight: true, homeIndexing: .on, diskIndexing: .on,
    desktop: .readable, documents: .unreadable, downloads: .missing)

  /// Parses `bytes` in one chunk.
  static func parse(_ bytes: [UInt8]) throws(FolderSearchProtocolError) -> [FolderSearchOutputEvent]
  {
    var parser = FolderSearchOutputParser()
    return try parser.consume(bytes)
  }

  /// The protocol error parsing `bytes` (then finishing) ends with, or `nil`.
  static func error(_ bytes: [UInt8], finish: Bool = false) -> FolderSearchProtocolError? {
    var parser = FolderSearchOutputParser()
    do throws(FolderSearchProtocolError) {
      _ = try parser.consume(bytes)
      if finish { try parser.finish() }
      return nil
    } catch {
      return error
    }
  }

  /// The header is read in order, then answers with their paths and end records.
  @Test func readsTheHeaderAndAnswers() throws {
    let bytes =
      Self.header() + Self.record("/syn/a") + Self.record("/syn/b c") + Self.record("end 1 ok 2")
      + Self.record("end 2 ok 0")
    let events = try Self.parse(bytes)
    #expect(
      events == [
        .header(Self.expectedHeader),
        .reply(FolderSearchReply(id: 1, status: .ok, paths: ["/syn/a", "/syn/b c"])),
        .reply(FolderSearchReply(id: 2, status: .ok, paths: [])),
      ])
    // `limited` needs exactly 50 paths before it.
    #expect(
      Self.error(bytes + Self.record("/syn/x") + Self.record("end 3 limited 50")) == .countMismatch)
    #expect(
      Self.error(bytes + Self.record("/syn/x") + Self.record("end 3 limited 1")) == .countMismatch)
  } // End of func readsTheHeaderAndAnswers()

  /// A limited answer holds exactly 50 paths; a 51st path record is refused.
  @Test func limitedAnswersHoldFiftyPaths() throws {
    let paths = (1...50).map { "/syn/f\($0)" }
    let bytes = Self.header() + paths.flatMap(Self.record) + Self.record("end 7 limited 50")
    let events = try Self.parse(bytes)
    #expect(events.last == .reply(FolderSearchReply(id: 7, status: .limited, paths: paths)))
    let tooMany = Self.header() + (paths + ["/syn/f51"]).flatMap(Self.record)
    #expect(Self.error(tooMany) == .tooManyPaths)
  }

  /// A NUL-separated path keeps a line feed, a tab and other bytes of its name.
  @Test func keepsANameWithANewline() throws {
    let path = "/syn/line\nbreak/\ttab \"q\" 'q' $x"
    let events = try Self.parse(Self.header() + Self.record(path) + Self.record("end 4 ok 1"))
    #expect(events.last == .reply(FolderSearchReply(id: 4, status: .ok, paths: [path])))
  }

  /// Chunks split anywhere, even inside a record or between a record and its NUL, give the
  /// same events.
  @Test func acceptsAnyChunking() throws {
    let bytes =
      Self.header() + Self.record("/syn/é/ü") + Self.record("/syn/b") + Self.record("end 9 ok 2")
    let whole = try Self.parse(bytes)
    for size in [1, 2, 3, 7, 64] {
      var parser = FolderSearchOutputParser()
      var events: [FolderSearchOutputEvent] = []
      var start = 0
      while start < bytes.count {
        events += try parser.consume(bytes[start..<min(start + size, bytes.count)])
        start += size
      } // End of loop over chunks
      try parser.finish()
      #expect(events == whole, "chunk size \(size)")
    } // End of loop over chunk sizes
  } // End of func acceptsAnyChunking()

  /// An error answer drops the paths before it; its code is kept.
  @Test func errorAnswersHoldNoPaths() throws {
    let bytes =
      Self.header() + Self.record("/syn/a") + Self.record("end 5 error search")
      + Self.record("end 6 error unavailable")
    let events = try Self.parse(bytes)
    #expect(
      Array(events.dropFirst()) == [
        .reply(FolderSearchReply(id: 5, status: .error("search"), paths: [])),
        .reply(FolderSearchReply(id: 6, status: .error("unavailable"), paths: [])),
      ])
  } // End of func errorAnswersHoldNoPaths()

  /// The parser reports every id as written; a stale or unknown id is the channel's to drop.
  @Test func reportsStaleIDsAsWritten() throws {
    let events = try Self.parse(
      Self.header() + Self.record("end 3 ok 0") + Self.record("end 1 ok 0")
        + Self.record("end 999999999999999999 ok 0"))
    #expect(
      events.dropFirst().map { event -> UInt64? in
        if case .reply(let reply) = event { return reply.id }
        return nil
      } == [3, 1, 999_999_999_999_999_999])
  }

  /// A path record longer than the record limit is read to its end, left out and counted; the
  /// count in the end record includes it.
  @Test func dropsOversizedPaths() throws {
    let long = "/" + String(repeating: "x", count: FolderSearchOutputParser.maximumRecordLength)
    let events = try Self.parse(
      Self.header() + Self.record(long) + Self.record("/syn/ok") + Self.record("end 2 ok 2"))
    #expect(
      events.last
        == .reply(FolderSearchReply(id: 2, status: .ok, paths: ["/syn/ok"], droppedCount: 1)))
    let invalid = Self.header() + [0x2F, 0xFF, 0xFE, 0] + Self.record("end 3 ok 1")
    #expect(
      try Self.parse(invalid).last
        == .reply(FolderSearchReply(id: 3, status: .ok, paths: [], droppedCount: 1)))
  } // End of func dropsOversizedPaths()

  /// Garbage before the header (a login shell's greeting) is skipped up to the limit; the
  /// header's first record may follow it in the same record.
  @Test func skipsAPreamble() throws {
    let greeting = Array("Welcome\nlast login\n".utf8) + [0] + Array("more text".utf8)
    let events = try Self.parse(greeting + Self.header())
    #expect(events == [.header(Self.expectedHeader)])
    let flood = [UInt8](repeating: 0x41, count: FolderSearchOutputParser.maximumPreambleLength + 1)
    #expect(Self.error(flood + Self.header()) == .noHeader)
    #expect(Self.error(Array("no header at all".utf8), finish: true) == .noHeader)
  }

  /// Header records out of order, malformed or too long are refused.
  @Test func refusesABadHeader() {
    #expect(Self.error(Self.header(mdfind: "maybe")) == .badHeader)
    #expect(Self.error(Self.header(homeIndex: "enabled")) == .badHeader)
    #expect(Self.error(Self.header(home: "relative/home")) == .badHeader)
    #expect(Self.error(Self.header(desktop: "perhaps")) == .badHeader)
    let swapped =
      Self.record("muxfinder-folders 1") + Self.record("mdfind yes") + Self.record("home /h")
    #expect(Self.error(swapped) == .badHeader)
    let longHome = Self.header(
      home: "/" + String(repeating: "h", count: FolderSearchOutputParser.maximumRecordLength))
    #expect(Self.error(longHome) == .badHeader)
    #expect(Self.error(Self.record("muxfinder-folders 2") + Self.header()) == nil)
  } // End of func refusesABadHeader()

  /// An empty home reads as unknown.
  @Test func readsAnEmptyHome() throws {
    let events = try Self.parse(Self.header(home: ""))
    guard case .header(let header) = events.first else {
      Issue.record("no header")
      return
    }
    #expect(header.homeDirectory == nil)
    #expect(header.unavailability(for: .home) == .noHomeFolder)
    #expect(header.unavailability(for: .disk) == nil)
  }

  /// Garbage between records, bad end records and counts that do not match are refused.
  @Test func refusesGarbageAndBadEnds() {
    let start = Self.header()
    #expect(Self.error(start + Self.record("garbage")) == .unexpectedRecord)
    #expect(Self.error(start + Self.record("/syn/a") + Self.record("noise")) == .unexpectedRecord)
    #expect(Self.error(start + Self.record("end x ok 0")) == .unexpectedRecord)
    #expect(Self.error(start + Self.record("end 1 maybe 0")) == .unexpectedRecord)
    #expect(Self.error(start + Self.record("end 1 ok")) == .unexpectedRecord)
    #expect(Self.error(start + Self.record("end 1 ok 0 extra")) == .unexpectedRecord)
    #expect(Self.error(start + Self.record("end 1 error Bad")) == .unexpectedRecord)
    #expect(Self.error(start + Self.record("end 1234567890123456789 ok 0")) == .unexpectedRecord)
    #expect(Self.error(start + Self.record("/syn/a") + Self.record("end 1 ok 2")) == .countMismatch)
    #expect(Self.error(start + Self.record("end 1 ok 1")) == .countMismatch)
    #expect(Self.error(start + Self.record("")) == .unexpectedRecord)
  } // End of func refusesGarbageAndBadEnds()

  /// Output that ends inside the header, a record or an answer is truncated; after a whole
  /// answer it is a clean end. Once failed, the parser keeps failing.
  @Test func reportsTruncation() throws {
    let start = Self.header()
    #expect(Self.error(Array(start.prefix(30)), finish: true) == .truncated)
    #expect(Self.error(start + Array("/syn/cut".utf8), finish: true) == .truncated)
    #expect(Self.error(start + Self.record("/syn/a"), finish: true) == .truncated)
    #expect(
      Self.error(start + Self.record("/syn/a") + Self.record("end 1 ok 1"), finish: true) == nil)
    var parser = FolderSearchOutputParser()
    #expect(throws: FolderSearchProtocolError.unexpectedRecord) {
      try parser.consume(start + Self.record("garbage"))
    }
    #expect(throws: FolderSearchProtocolError.unexpectedRecord) {
      try parser.consume(Self.record("end 1 ok 0"))
    }
  } // End of func reportsTruncation()

  /// The header's derived facts.
  @Test func headerFacts() {
    var header = Self.expectedHeader
    #expect(header.hasUnreadableProtectedFolder)
    #expect(header.unavailability(for: .home) == nil)
    header.homeIndexing = .off
    #expect(header.unavailability(for: .home) == .indexingOff)
    #expect(header.unavailability(for: .disk) == nil)
    header.diskIndexing = .unknown
    #expect(header.unavailability(for: .disk) == nil)
    header.hasSpotlight = false
    #expect(header.unavailability(for: .disk) == .noSpotlight)
    #expect(header.unreadableProtectedFolders == ["Documents"])
    header.documents = .readable
    #expect(!header.hasUnreadableProtectedFolder)
    #expect(header.unreadableProtectedFolders.isEmpty)
    header.desktop = .unreadable
    header.downloads = .unreadable
    #expect(header.unreadableProtectedFolders == ["Desktop", "Downloads"])
  } // End of func headerFacts()

  /// `unchecked` (This Mac's script, PLAN.md Phase I-10b) reads as `notChecked`, which is not
  /// unreadable; any other value is still a bad header.
  @Test func readsUncheckedFolders() throws {
    let bytes = Self.header(desktop: "unchecked", documents: "unchecked", downloads: "unchecked")
    let events = try Self.parse(bytes)
    var expected = Self.expectedHeader
    expected.desktop = .notChecked
    expected.documents = .notChecked
    expected.downloads = .notChecked
    #expect(events == [.header(expected)])
    #expect(!expected.hasUnreadableProtectedFolder)
    #expect(FolderSearchHeader.Readability.notChecked.rawValue == "unchecked")
    #expect(Self.error(Self.header(documents: "not-checked")) == .badHeader)
  } // End of func readsUncheckedFolders()
}
