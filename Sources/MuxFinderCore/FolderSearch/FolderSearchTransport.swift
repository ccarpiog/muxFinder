import Foundation
import os

/// The host a folder search runs on (PLAN.md D36): This Mac, or an SSH destination.
public enum FolderSearchHost: Sendable, Hashable {
  /// This Mac: the script runs as `/bin/sh -c <script> muxfinder unchecked`.
  case local
  /// An SSH host: the script runs through discovery's noninteractive ssh.
  case ssh(destination: String)

  /// The folder-search host of a configured host.
  public init(_ host: HostConfig) {
    switch host.mode {
    case .local: self = .local
    case .ssh: self = .ssh(destination: host.sshDestination)
    }
  }
}

/// Why a folder search failed (PLAN.md D36). Codes and messages hold no folder name or path.
public enum FolderSearchFailure: Error, Sendable, Hashable {
  /// The process could not be started (a bad destination, or a system call failed).
  case couldNotStart(String)
  /// ssh failed on its own (exit 255), classified as discovery classifies it.
  case connection(HostStatus)
  /// No header arrived in time.
  case headerTimedOut
  /// No answer arrived in time.
  case answerTimedOut
  /// The script or ssh ended before it was asked to, with this exit status or signal.
  case ended(ProcessResult.Termination?)
  /// The output was not what the script writes.
  case protocolError(FolderSearchProtocolError)
  /// The host's script refused the query line, with its code (`malformed`, `scope`, `length`,
  /// `text`); never expected, since the app escapes and bounds the text first.
  case queryRefused(String)
  /// `mdfind` failed on the host.
  case searchFailed
  /// `mdfind` ran past the script's deadline (`FolderSearchScript.searchDeadline`) and was
  /// stopped on the host; the process stays usable.
  case searchTimedOut

  /// A stable, machine-readable name: what a log may record.
  public var code: String {
    switch self {
    case .couldNotStart: return "couldNotStart"
    case .connection(let status): return "connection.\(status.kind)"
    case .headerTimedOut: return "headerTimedOut"
    case .answerTimedOut: return "answerTimedOut"
    case .ended(.exited(let code)): return "ended.exit.\(code)"
    case .ended(.signaled(let signal)): return "ended.signal.\(signal)"
    case .ended(nil): return "ended"
    case .protocolError(let error): return "protocolError.\(error.code)"
    case .queryRefused(let code): return "queryRefused.\(code)"
    case .searchFailed: return "searchFailed"
    case .searchTimedOut: return "searchTimedOut"
    }
  } // End of var code

  /// The user-facing explanation, in English and sentence case.
  public var message: String {
    switch self {
    case .couldNotStart(let detail):
      return "muxFinder couldn't start the folder search. \(detail)"
    case .connection(.authFailed):
      return "muxFinder couldn't sign in over SSH to search folders."
    case .connection(.hostKeyProblem):
      return "The host's SSH key couldn't be verified, so folders weren't searched."
    case .connection(.unreachable):
      return "The host can't be reached, so folders weren't searched."
    case .connection:
      return "SSH failed, so folders weren't searched."
    case .headerTimedOut, .answerTimedOut, .searchTimedOut:
      return "The folder search took too long."
    case .ended:
      return "The folder search stopped unexpectedly."
    case .protocolError:
      return "The host's answer to the folder search wasn't understood."
    case .queryRefused:
      return "The host refused the folder search."
    case .searchFailed:
      return "Spotlight couldn't search the host's folders."
    }
  } // End of var message
}

/// How a folder-search process ended.
public struct FolderSearchConnectionEnd: Sendable, Hashable {
  /// How it ended; `nil` when it could not be reaped normally.
  public var termination: ProcessResult.Termination?
  /// The first bytes of its standard error (ssh's own errors); never logged.
  public var standardError: Data

  /// Creates an end.
  public init(termination: ProcessResult.Termination?, standardError: Data = Data()) {
    self.termination = termination
    self.standardError = standardError
  }
}

/// What a folder-search process reports, in order: at most one header, replies, at most one
/// protocol error (after which output is no longer read), and always one end, last.
public enum FolderSearchConnectionEvent: Sendable, Hashable {
  /// The script's header.
  case header(FolderSearchHeader)
  /// One answer.
  case reply(FolderSearchReply)
  /// The output stopped making sense; the process should be closed.
  case protocolError(FolderSearchProtocolError)
  /// The process ended and was reaped.
  case ended(FolderSearchConnectionEnd)
}

/// One running folder-search script (PLAN.md D36).
public protocol FolderSearchConnection: Sendable {
  /// The process's events. Finishes after `.ended`.
  var events: AsyncStream<FolderSearchConnectionEvent> { get }

  /// Writes one query line to the script's standard input; `false` when it could not.
  func send(_ line: Data) -> Bool

  /// Ends the script: closes its standard input (which ends it), terminates it after a grace
  /// period if it is still running, and returns once it is reaped.
  func close() async
}

/// Starts folder-search scripts (PLAN.md D36): `ProcessFolderSearchTransport` in the app and
/// the probe, `FakeFolderSearchTransport` in tests.
public protocol FolderSearchTransport: Sendable {
  /// Starts the script on `host`.
  func open(_ host: FolderSearchHost) async throws(FolderSearchFailure)
    -> any FolderSearchConnection
}

/// The real transport (PLAN.md D3, D36): This Mac runs `/bin/sh -c <script> muxfinder
/// unchecked` by argv (the fixed argument turns the readability checks off, Phase I-10b); an
/// SSH host gets `/usr/bin/ssh <discovery's options> -T -- <destination> <D3 command>`, the D3
/// string carrying the static script and no argument, with standard input kept open as the
/// query stream (so no `-n`). Nothing here weakens host-key checking; the user's SSH
/// configuration, keys and agent apply as they are.
public struct ProcessFolderSearchTransport: FolderSearchTransport {
  /// How long `close()` waits after closing standard input before SIGTERM.
  public static let closeGracePeriod: Duration = .seconds(2)
  /// How long after SIGTERM SIGKILL follows.
  public static let killDelay: Duration = .seconds(2)
  /// The most standard error bytes kept.
  public static let errorLimit = 4096
  /// The most parsed events (a header, answers) a connection holds for its reader. The script
  /// writes one answer per query line and the channel sends one line at a time, so a few are
  /// ever waiting; more is a flood or a stalled reader, and the connection fails
  /// (`eventOverflow`) and ends the process. With the parser's limits (50 paths of at most
  /// 16 KiB an answer) this bounds what is buffered.
  public static let eventLimit = 8

  /// The environment of This Mac's script.
  public var localEnvironment: [String: String]
  /// The environment of ssh.
  public var sshEnvironment: [String: String]

  /// A transport. The defaults: this process's environment with `PATH` set to the system's
  /// search path (so `mdfind` and `mdutil` resolve in `/usr/bin` as on an SSH host) and
  /// without `TMUX` and `TMUX_PANE` for This Mac; discovery's environment for ssh. Tests pass
  /// a `localEnvironment` whose `PATH` starts with stub tools.
  public init(
    localEnvironment: [String: String] = ProcessFolderSearchTransport.defaultLocalEnvironment(),
    sshEnvironment: [String: String] = DiscoveryProbe.localEnvironment(
      base: ProcessInfo.processInfo.environment)
  ) {
    self.localEnvironment = localEnvironment
    self.sshEnvironment = sshEnvironment
  }

  /// This process's environment with `PATH` set to `ProcessEnvironment.systemSearchPath` and
  /// without `TMUX` and `TMUX_PANE`.
  public static func defaultLocalEnvironment(
    base: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    var environment = base
    for name in DiscoveryProbe.strippedVariables { environment[name] = nil }
    environment["PATH"] = ProcessEnvironment.systemSearchPath
    return environment
  }

  /// The process `host` runs. Exposed so tests and the probe can inspect it.
  public func request(for host: FolderSearchHost) throws(FolderSearchFailure) -> ProcessRequest {
    switch host {
    case .local:
      return ProcessRequest(
        executableURL: DiscoveryProbe.shellURL,
        arguments: [
          "-c", FolderSearchScript.script.source, ShellQuoting.scriptName,
          FolderSearchScript.uncheckedArgument,
        ],
        environment: localEnvironment)
    case .ssh(let raw):
      let destination: String
      do throws(ValidationError) {
        destination = try Validation.sshDestination(raw)
      } catch {
        throw .couldNotStart(error.message)
      }
      let command = ShellQuoting.remoteCommand(script: FolderSearchScript.script, args: [])
      return ProcessRequest(
        executableURL: DiscoveryProbe.sshURL,
        arguments: DiscoveryProbe.sshOptions + ["-T", "--", destination, command],
        environment: sshEnvironment)
    }
  } // End of func request(for:)

  /// Starts the script on `host`.
  public func open(
    _ host: FolderSearchHost
  ) async throws(FolderSearchFailure) -> any FolderSearchConnection {
    let request = try request(for: host)
    do throws(ProcessRunnerError) {
      return try ProcessFolderSearchConnection.start(request)
    } catch {
      throw .couldNotStart(error.description)
    }
  }
}

/// A running script over `StreamingProcess`: its standard output goes through a
/// `FolderSearchOutputParser` on the process's queue, so only parsed events are buffered, at
/// most `eventLimit` of them (`ProcessFolderSearchTransport.eventLimit`); the first protocol
/// error stops the reading. When the reader falls that far behind, the connection reports
/// `eventOverflow`, stops reading and ends the process as `close()` does; the end is still
/// delivered, last.
final class ProcessFolderSearchConnection: FolderSearchConnection {
  /// Ends the process once, when the event buffer overflows, even before `start` returned.
  final class OverflowStop: Sendable {
    /// Where the stop stands.
    private enum Stage {
      /// The process is not known yet; `true` once an overflow asked for the stop.
      case starting(stopRequested: Bool)
      /// The process is known.
      case started(StreamingProcess)
    }

    /// The stage.
    private let stage = OSAllocatedUnfairLock(initialState: Stage.starting(stopRequested: false))

    /// Records `process`, ending it at once when an overflow came first.
    func started(_ process: StreamingProcess) {
      let stopNow = stage.withLock { stage -> Bool in
        defer { stage = .started(process) }
        if case .starting(let requested) = stage { return requested }
        return false
      }
      if stopNow { Self.end(process) }
    }

    /// Ends the process, or does so once it is known.
    func stop() {
      let process = stage.withLock { stage -> StreamingProcess? in
        switch stage {
        case .starting:
          stage = .starting(stopRequested: true)
          return nil
        case .started(let process):
          return process
        }
      }
      if let process { Self.end(process) }
    } // End of func stop()

    /// Ends `process` in the background as `close()` does.
    static func end(_ process: StreamingProcess) {
      Task {
        await process.terminate(
          gracePeriod: ProcessFolderSearchTransport.closeGracePeriod,
          killAfter: ProcessFolderSearchTransport.killDelay)
      }
    }
  } // End of class OverflowStop

  /// The events.
  let events: AsyncStream<FolderSearchConnectionEvent>
  /// The process.
  private let process: StreamingProcess

  /// Wraps a started process.
  private init(events: AsyncStream<FolderSearchConnectionEvent>, process: StreamingProcess) {
    self.events = events
    self.process = process
  }

  /// Starts `request` and its parser, holding at most `eventLimit` events for the reader.
  static func start(
    _ request: ProcessRequest, eventLimit: Int = ProcessFolderSearchTransport.eventLimit
  ) throws(ProcessRunnerError) -> ProcessFolderSearchConnection {
    // Room for `eventLimit` events, the one that overflows, the overflow error and the end.
    let limit = max(1, eventLimit)
    let capacity = limit + 3
    let (events, sink) = AsyncStream.makeStream(
      of: FolderSearchConnectionEvent.self, bufferingPolicy: .bufferingOldest(capacity))
    let parser = OSAllocatedUnfairLock(initialState: FolderSearchOutputParser())
    let overflow = OverflowStop()
    let process = try StreamingProcess.start(
      request, errorLimit: ProcessFolderSearchTransport.errorLimit,
      onOutput: { chunk in
        let parsed = parser.withLock {
          parser -> Result<[FolderSearchOutputEvent], FolderSearchProtocolError> in
          do throws(FolderSearchProtocolError) {
            return .success(try parser.consume(chunk))
          } catch {
            return .failure(error)
          }
        }
        switch parsed {
        case .success(let found):
          for event in found {
            let room = Self.enqueue(Self.connectionEvent(event), into: sink, capacity: capacity)
            guard room >= capacity - limit else {
              sink.yield(.protocolError(.eventOverflow))
              overflow.stop()
              return false
            }
          } // End of loop over the chunk's events
          return true
        case .failure(let error):
          sink.yield(.protocolError(error))
          return false
        }
      },
      onEnd: { termination, errors in
        sink.yield(
          .ended(FolderSearchConnectionEnd(termination: termination, standardError: errors)))
        sink.finish()
      })
    overflow.started(process)
    return ProcessFolderSearchConnection(events: events, process: process)
  } // End of static func start(_:eventLimit:)

  /// Yields `event` and returns the room left in the buffer: `capacity` when nobody reads the
  /// stream any more (the event is dropped; the owner closes the process), 0 when it did not
  /// fit.
  static func enqueue(
    _ event: FolderSearchConnectionEvent,
    into sink: AsyncStream<FolderSearchConnectionEvent>.Continuation,
    capacity: Int
  ) -> Int {
    switch sink.yield(event) {
    case .enqueued(let remaining): return remaining
    case .terminated: return capacity
    case .dropped: return 0
    @unknown default: return 0
    }
  }

  /// The connection event for a parser event.
  static func connectionEvent(_ event: FolderSearchOutputEvent) -> FolderSearchConnectionEvent {
    switch event {
    case .header(let header): return .header(header)
    case .reply(let reply): return .reply(reply)
    }
  }

  /// The process id, also its process group id (tests).
  var processID: pid_t { process.processID }

  /// Writes `line` to the script's standard input.
  func send(_ line: Data) -> Bool {
    process.write(line)
  }

  /// Closes standard input, then terminates the process if it is still running after
  /// `ProcessFolderSearchTransport.closeGracePeriod`; returns once it is reaped. Over SSH that
  /// process is the local ssh only: the host's script sees its input end and its output go,
  /// and ends by itself, a query still running at `FolderSearchScript.searchDeadline` at the
  /// latest (PLAN.md D36).
  func close() async {
    await process.terminate(
      gracePeriod: ProcessFolderSearchTransport.closeGracePeriod,
      killAfter: ProcessFolderSearchTransport.killDelay)
  }
}
