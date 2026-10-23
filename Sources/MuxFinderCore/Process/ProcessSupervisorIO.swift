import Darwin
import Foundation

/// A pipe created with close-on-exec set on both ends.
struct PipePair {
  /// The end the reader uses.
  let readEnd: Int32
  /// The end the writer uses.
  let writeEnd: Int32

  /// Creates a pipe. Close-on-exec keeps it out of processes spawned concurrently elsewhere.
  static func make() throws(ProcessRunnerError) -> PipePair {
    var descriptors: [Int32] = [-1, -1]
    guard pipe(&descriptors) == 0 else { throw .systemCallFailed(name: "pipe", errno: errno) }
    for descriptor in descriptors {
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }
    return PipePair(readEnd: descriptors[0], writeEnd: descriptors[1])
  }
}

/// Wraps `posix_spawn_file_actions_t`. The owner calls `destroy()` exactly once.
struct SpawnFileActions {
  /// The underlying handle, passed to `posix_spawn`.
  var raw: posix_spawn_file_actions_t?

  /// Initializes an empty action list.
  init() throws(ProcessRunnerError) {
    raw = nil
    try checkSpawnCall(posix_spawn_file_actions_init(&raw), "posix_spawn_file_actions_init")
  }

  /// Adds `dup2(descriptor, target)` in the child.
  mutating func duplicate(_ descriptor: Int32, to target: Int32) throws(ProcessRunnerError) {
    try checkSpawnCall(
      posix_spawn_file_actions_adddup2(&raw, descriptor, target),
      "posix_spawn_file_actions_adddup2"
    )
  }

  /// Opens `/dev/null` read-only as `target` in the child.
  mutating func openNullDevice(as target: Int32) throws(ProcessRunnerError) {
    try checkSpawnCall(
      posix_spawn_file_actions_addopen(&raw, target, "/dev/null", O_RDONLY, 0),
      "posix_spawn_file_actions_addopen"
    )
  }

  /// Closes `descriptor` in the child.
  mutating func close(_ descriptor: Int32) throws(ProcessRunnerError) {
    try checkSpawnCall(
      posix_spawn_file_actions_addclose(&raw, descriptor),
      "posix_spawn_file_actions_addclose"
    )
  }

  /// Keeps this process's `descriptor` open in the child under the same number, even with
  /// `POSIX_SPAWN_CLOEXEC_DEFAULT`.
  mutating func inherit(_ descriptor: Int32) throws(ProcessRunnerError) {
    try checkSpawnCall(
      posix_spawn_file_actions_addinherit_np(&raw, descriptor),
      "posix_spawn_file_actions_addinherit_np"
    )
  }

  /// Releases the action list.
  mutating func destroy() {
    posix_spawn_file_actions_destroy(&raw)
  }
}

/// Wraps `posix_spawnattr_t`, configured for muxFinder's children. The owner calls `destroy()`
/// exactly once.
///
/// - `POSIX_SPAWN_SETPGROUP` with pgroup 0 (unless `newProcessGroup` is `false`): the child
///   leads a new process group.
/// - `POSIX_SPAWN_SETSIGMASK` (empty) and `POSIX_SPAWN_SETSIGDEF` (all catchable signals): the
///   child starts with no blocked signals and default dispositions, whatever this process uses.
/// - `POSIX_SPAWN_CLOEXEC_DEFAULT`: only the descriptors set up by the file actions survive.
/// - `POSIX_SPAWN_SETEXEC` (only with `replacingProcess`): `posix_spawn` replaces this process
///   like `execve` and returns only on failure (the helper's login shell, PLAN.md D26).
struct SpawnAttributes {
  /// The underlying handle, passed to `posix_spawn`.
  var raw: posix_spawnattr_t?

  /// Initializes and configures the attributes. `newProcessGroup: false` keeps the child in
  /// this process's group, which a child that reads the controlling terminal needs (a
  /// background group would get `SIGTTIN`). `replacingProcess: true` makes the spawn an exec.
  init(newProcessGroup: Bool = true, replacingProcess: Bool = false) throws(ProcessRunnerError) {
    raw = nil
    try checkSpawnCall(posix_spawnattr_init(&raw), "posix_spawnattr_init")
    var flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
    if newProcessGroup { flags |= POSIX_SPAWN_SETPGROUP }
    if replacingProcess { flags |= POSIX_SPAWN_SETEXEC }
    var blocked = sigset_t()
    sigemptyset(&blocked)
    var defaults = sigset_t()
    sigfillset(&defaults)
    sigdelset(&defaults, SIGKILL)
    sigdelset(&defaults, SIGSTOP)
    do throws(ProcessRunnerError) {
      try checkSpawnCall(posix_spawnattr_setflags(&raw, Int16(flags)), "posix_spawnattr_setflags")
      if newProcessGroup {
        try checkSpawnCall(posix_spawnattr_setpgroup(&raw, 0), "posix_spawnattr_setpgroup")
      }
      try checkSpawnCall(posix_spawnattr_setsigmask(&raw, &blocked), "posix_spawnattr_setsigmask")
      try checkSpawnCall(
        posix_spawnattr_setsigdefault(&raw, &defaults),
        "posix_spawnattr_setsigdefault"
      )
    } catch {
      posix_spawnattr_destroy(&raw)
      throw error
    }
  } // End of init()

  /// Releases the attributes.
  mutating func destroy() {
    posix_spawnattr_destroy(&raw)
  }
}

/// Turns a `posix_spawn*` return code (an errno value, 0 on success) into a thrown error.
func checkSpawnCall(_ code: Int32, _ name: String) throws(ProcessRunnerError) {
  guard code == 0 else { throw .systemCallFailed(name: name, errno: code) }
}

/// A NULL-terminated array of heap-allocated C strings, the shape `posix_spawn` expects for
/// argv and envp. Lives on one thread only.
final class CStringArray {
  /// The copied strings followed by a terminating `nil`.
  private var pointers: [UnsafeMutablePointer<CChar>?] = []

  /// Copies `strings`. Callers have already rejected strings that contain NUL.
  init(_ strings: [String]) throws(ProcessRunnerError) {
    pointers.reserveCapacity(strings.count + 1)
    for string in strings {
      guard let copy = strdup(string) else {
        throw .systemCallFailed(name: "strdup", errno: ENOMEM)
      }
      pointers.append(copy)
    }
    pointers.append(nil)
  }

  /// Frees the copies.
  deinit {
    for pointer in pointers {
      free(pointer)
    }
  }

  /// Calls `body` with a pointer to the first element of the NULL-terminated array.
  func withUnsafePointer<Result>(
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
  ) -> Result {
    pointers.withUnsafeBufferPointer { buffer in
      // The array always holds at least the terminating nil, so the base address exists.
      guard let base = buffer.baseAddress else { preconditionFailure("empty C string array") }
      return body(base)
    }
  }
}

/// Reads one output pipe and keeps at most `limit` bytes, discarding (but still reading) the
/// rest so the child never blocks on a full pipe.
struct OutputCollector {
  /// Upper bound on reads per wakeup, so a flood on one stream cannot starve deadline checks.
  static let maximumReadsPerWakeup = 16

  /// The non-blocking read end, or -1 once closed.
  private(set) var descriptor: Int32
  /// Maximum number of bytes kept.
  let limit: Int
  /// The bytes kept so far.
  private(set) var data = Data()
  /// Whether bytes beyond `limit` were discarded.
  private(set) var truncated = false

  /// Starts collecting from `descriptor`.
  init(descriptor: Int32, limit: Int) {
    self.descriptor = descriptor
    self.limit = max(0, limit)
  }

  /// Whether the pipe is still open (end-of-file not seen yet).
  var isOpen: Bool { descriptor >= 0 }

  /// Reads what is available now, up to `maximumReadsPerWakeup` chunks. Closes the pipe on
  /// end-of-file or on an unexpected error.
  mutating func drain(using buffer: inout [UInt8]) {
    for _ in 0..<Self.maximumReadsPerWakeup {
      guard isOpen else { return }
      let descriptor = self.descriptor
      let count = buffer.withUnsafeMutableBytes { bytes in
        read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count > 0 {
        keep(buffer[0..<count])
        continue
      }
      if count < 0 && errno == EINTR { continue }
      if count < 0 && errno == EAGAIN { return }
      close()
      return
    } // End of loop over reads for this wakeup
  } // End of func drain(using:)

  /// Appends as much of `bytes` as the limit allows and records any excess.
  private mutating func keep(_ bytes: ArraySlice<UInt8>) {
    let room = limit - data.count
    if room > 0 { data.append(contentsOf: bytes.prefix(room)) }
    if bytes.count > room { truncated = true }
  }

  /// Closes the read end if it is still open.
  mutating func close() {
    guard descriptor >= 0 else { return }
    Darwin.close(descriptor)
    descriptor = -1
  }
}

/// Writes request data to the child's stdin pipe without blocking, then closes it so the child
/// sees end-of-file.
struct InputFeeder {
  /// The non-blocking write end, or -1 when closed or unused.
  private(set) var descriptor: Int32
  /// The bytes to deliver.
  private let data: Data
  /// How many bytes have been written.
  private var offset = 0

  /// Prepares to write `data` to `descriptor` (-1 means there is no stdin pipe).
  init(descriptor: Int32, data: Data) {
    self.descriptor = descriptor
    self.data = data
  }

  /// Whether the pipe is still open.
  var isOpen: Bool { descriptor >= 0 }

  /// Writes as much as the pipe accepts now. Closes the pipe when everything is written, or
  /// when the child has closed its end (`EPIPE`).
  mutating func feed() {
    while isOpen && offset < data.count {
      let descriptor = self.descriptor
      let start = offset
      let length = min(data.count - start, ProcessSupervisor.chunkSize)
      let written = data.withUnsafeBytes { bytes -> Int in
        guard let base = bytes.baseAddress else { return 0 }
        return Darwin.write(descriptor, base + start, length)
      }
      if written > 0 {
        offset += written
        continue
      }
      if written < 0 && errno == EINTR { continue }
      if written == 0 || errno == EAGAIN { return }
      close()
      return
    } // End of loop over stdin writes
    close()
  } // End of func feed()

  /// Closes the write end if it is still open.
  mutating func close() {
    guard descriptor >= 0 else { return }
    Darwin.close(descriptor)
    descriptor = -1
  }
}

/// The `struct kevent` type. In expression position Swift resolves the bare name `kevent` to the
/// function of the same name, so code that builds event arrays uses this alias.
typealias KernelEvent = kevent

/// Thin helpers over `kevent`.
enum KernelQueue {
  /// Adds a filter to `queue`. Returns 0 on success or the errno value.
  static func register(
    queue: Int32,
    ident: UInt,
    filter: Int32,
    flags: Int32 = 0,
    fflags: UInt32 = 0
  ) -> Int32 {
    var change = kevent(
      ident: ident,
      filter: Int16(filter),
      flags: UInt16(EV_ADD | flags),
      fflags: fflags,
      data: 0,
      udata: nil
    )
    return kevent(queue, &change, 1, nil, 0, nil) == 0 ? 0 : errno
  } // End of func register(queue:ident:filter:flags:fflags:)

  /// Watches `descriptor` for readable data or end-of-file. Returns whether it worked.
  static func watchReadable(_ descriptor: Int32, queue: Int32) -> Bool {
    register(queue: queue, ident: UInt(descriptor), filter: EVFILT_READ) == 0
  }

  /// Waits for events, at most `timeout` (`nil` waits indefinitely). Returns the number of
  /// events stored in `events`, or -1 with `errno` set.
  static func wait(queue: Int32, into events: inout [KernelEvent], timeout: Duration?) -> Int32 {
    let capacity = Int32(events.count)
    guard let timeout else {
      return kevent(queue, nil, 0, &events, capacity, nil)
    }
    let parts = timeout.components
    let nanoseconds = Int(parts.attoseconds / 1_000_000_000)
    var limit = timespec(tv_sec: Int(parts.seconds), tv_nsec: nanoseconds)
    return kevent(queue, nil, 0, &events, capacity, &limit)
  }
}
