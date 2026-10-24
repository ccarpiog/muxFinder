import Darwin
import Foundation

/// Terminal I/O that never blocks, for the helper's work on its tab's terminal (PLAN.md D14,
/// D17, D29): a descriptor of its own for the terminal, opened again with `O_NONBLOCK` (a
/// separate open file description, so the descriptors the helper shares with its attach child
/// stay blocking), and `poll` waits bounded by an absolute deadline.
enum NonBlockingTerminal {
  /// How a wait for a descriptor ended.
  enum Readiness: Equatable {
    /// The descriptor reported the events waited for.
    case ready
    /// The deadline passed first.
    case timedOut
    /// The descriptor reported a hang-up or an error without those events, or `poll` failed.
    case failed
  }

  /// A new descriptor for the terminal `descriptor` refers to, opened with `access`
  /// (`O_RDONLY` or `O_WRONLY`) plus `O_NONBLOCK`, `O_NOCTTY` and `O_CLOEXEC`; `nil` when
  /// `descriptor` is not a terminal, its device cannot be opened again, or the path names
  /// another device. Its `O_NONBLOCK` stays on its own open file description. The caller
  /// closes it.
  static func reopen(_ descriptor: Int32, access: Int32) -> Int32? {
    guard isatty(descriptor) == 1 else { return nil }
    var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard ttyname_r(descriptor, &name, name.count) == 0 else { return nil }
    let opened = open(name, access | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
    guard opened >= 0 else { return nil }
    var original = stat()
    var reopened = stat()
    guard fstat(descriptor, &original) == 0, fstat(opened, &reopened) == 0,
      original.st_rdev == reopened.st_rdev
    else {
      Darwin.close(opened)
      return nil
    }
    return opened
  } // End of static func reopen(_:access:)

  /// Waits until `descriptor` reports `events` (`POLLIN` or `POLLOUT`) or `deadline` passes,
  /// retrying on `EINTR`. Each round is rounded up to whole milliseconds (at least 1, at most
  /// a minute), so the wait never ends before the deadline.
  static func wait(
    for events: Int16,
    on descriptor: Int32,
    until deadline: ContinuousClock.Instant
  ) -> Readiness {
    while true {
      let remaining = deadline - ContinuousClock.now
      guard remaining > .zero else { return .timedOut }
      let milliseconds = Int32(min(60_000, max(1, (remaining / .milliseconds(1)).rounded(.up))))
      var poller = pollfd(fd: descriptor, events: events, revents: 0)
      let ready = poll(&poller, 1, milliseconds)
      if ready < 0 {
        if errno == EINTR { continue }
        return .failed
      }
      if ready == 0 { continue }
      return poller.revents & events != 0 ? .ready : .failed
    } // End of loop polling until the events or the deadline
  } // End of static func wait(for:on:until:)
} // End of enum NonBlockingTerminal
