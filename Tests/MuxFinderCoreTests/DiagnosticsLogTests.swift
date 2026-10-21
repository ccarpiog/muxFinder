import Foundation
import Testing

@testable import MuxFinderCore

/// Tests for the diagnostics ring buffer.
@Suite("Diagnostics log")
struct DiagnosticsLogTests {
  /// A fixed timestamp for deterministic events.
  static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

  /// Creates a log that does not write to the unified log and always reports `fixedDate`.
  static func makeLog(capacity: Int = 10) -> DiagnosticsLog {
    DiagnosticsLog(capacity: capacity, writesToSystemLog: false, now: { fixedDate })
  }

  /// Recorded events keep every field.
  @Test func recordsEventFields() async {
    let log = Self.makeLog()
    let event = await log.record(
      .process,
      outcome: .timedOut,
      hostID: "host-1",
      durationMs: 1234,
      detail: "Timed out after 12 s."
    )
    #expect(
      event
        == DiagnosticEvent(
          time: Self.fixedDate,
          category: .process,
          hostID: "host-1",
          outcome: .timedOut,
          durationMs: 1234,
          detail: "Timed out after 12 s."
        )
    )
    #expect(await log.events() == [event])
  } // End of func recordsEventFields()

  /// Once full, the oldest events are dropped and order stays oldest first.
  @Test func dropsTheOldestEventsWhenFull() async {
    let log = Self.makeLog(capacity: 3)
    for index in 1...5 {
      await log.record(.general, outcome: .info, detail: "event \(index)")
    }
    let details = await log.events().map(\.detail)
    #expect(details == ["event 3", "event 4", "event 5"])
  }

  /// `removeAll()` empties the log, which then fills again from scratch.
  @Test func removesAllEvents() async {
    let log = Self.makeLog(capacity: 2)
    for index in 1...3 {
      await log.record(.general, outcome: .success, detail: "\(index)")
    }
    await log.removeAll()
    #expect(await log.events().isEmpty)
    await log.record(.general, outcome: .success, detail: "again")
    #expect(await log.events().map(\.detail) == ["again"])
  }

  /// Control characters become spaces, so multi-line text cannot slip in as is.
  @Test func flattensControlCharacters() async {
    let log = Self.makeLog()
    let event = await log.record(.process, outcome: .failure, detail: "one\ntwo\tthree\u{1B}[0m")
    #expect(event.detail == "one two three [0m")
  }

  /// Long details are capped with an ellipsis.
  @Test func capsLongDetails() {
    let detail = DiagnosticsLog.sanitizedDetail(String(repeating: "x", count: 1000))
    #expect(detail.count == DiagnosticsLog.maximumDetailLength)
    #expect(detail.hasSuffix("…"))
    #expect(DiagnosticsLog.sanitizedDetail("short") == "short")
  }

  /// Negative durations are clamped to zero and the host is optional.
  @Test func clampsNegativeDurations() async {
    let log = Self.makeLog()
    let event = await log.record(.general, outcome: .cancelled, durationMs: -5, detail: "x")
    #expect(event.durationMs == 0)
    #expect(event.hostID == nil)
  }

  /// The subsystem matches the bundle identifier.
  @Test func usesTheAppSubsystem() {
    #expect(DiagnosticsLog.subsystem == "cc.carpio.muxfinder")
  }

  /// Writing to the unified log does not disturb the in-memory buffer.
  @Test func writesToTheSystemLogToo() async {
    let log = DiagnosticsLog(capacity: 2)
    await log.record(.general, outcome: .info, detail: "muxFinder unit test event")
    #expect(await log.events().count == 1)
  }
}
