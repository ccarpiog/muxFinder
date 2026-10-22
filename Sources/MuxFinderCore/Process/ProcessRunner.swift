import Foundation

/// Runs one external program to completion and captures its output.
///
/// Implementations never involve a shell: the executable receives exactly the argv in the
/// request. The production implementation is `PosixSpawnProcessRunner`; tests substitute fakes.
public protocol ProcessRunner: Sendable {
  /// Runs `request` and returns once the process has ended and its output has been collected.
  ///
  /// - Throws: `CancellationError` when the calling task is cancelled (the process group is
  ///   stopped first, like on a timeout), or `ProcessRunnerError` when the request is invalid or
  ///   the process could not be started. A timeout is not an error: it is reported through
  ///   `ProcessResult.timedOut`.
  func run(_ request: ProcessRequest) async throws -> ProcessResult
}

/// Everything needed to start one process: what to run, with which argv and environment.
public struct ProcessRequest: Sendable, Equatable {
  /// What the child reads on its standard input.
  public enum StandardInput: Sendable, Equatable {
    /// `/dev/null`, so the child sees end-of-file immediately. This is the default.
    case nullDevice
    /// The given bytes, followed by end-of-file.
    case data(Data)
  }

  /// The default per-stream output cap: 1 MiB.
  public static let defaultOutputLimit = 1 << 20

  /// Absolute file URL of the executable. Never resolved through `PATH`.
  public var executableURL: URL
  /// Arguments after argv[0]. argv[0] is always the executable path.
  public var arguments: [String]
  /// The complete environment of the child. Nothing is inherited implicitly; see
  /// `ProcessEnvironment` for helpers that build one.
  public var environment: [String: String]
  /// Standard input of the child.
  public var standardInput: StandardInput
  /// Hard limit on the run time. When it passes, the process group gets SIGTERM and, after the
  /// runner's grace period, SIGKILL. `nil` means no limit.
  public var timeout: Duration?
  /// Maximum number of bytes kept from each of stdout and stderr. Output beyond the cap is still
  /// read (so the child never blocks on a full pipe) but discarded.
  public var outputLimit: Int

  /// Creates a request. `environment` is required on purpose: the child's environment is always
  /// explicit.
  public init(
    executableURL: URL,
    arguments: [String] = [],
    environment: [String: String],
    standardInput: StandardInput = .nullDevice,
    timeout: Duration? = nil,
    outputLimit: Int = ProcessRequest.defaultOutputLimit
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.standardInput = standardInput
    self.timeout = timeout
    self.outputLimit = outputLimit
  } // End of init(executableURL:arguments:environment:standardInput:timeout:outputLimit:)
}

/// The outcome of a process that ran to completion (or was stopped by its timeout).
public struct ProcessResult: Sendable, Equatable {
  /// How the process ended.
  public enum Termination: Sendable, Hashable {
    /// The process called `exit` with this status.
    case exited(Int32)
    /// The process was terminated by this signal number.
    case signaled(Int32)
  }

  /// Process id of the child, which is also the id of the process group it led.
  public var processID: Int32
  /// How the child ended.
  public var termination: Termination
  /// Captured standard output, at most `ProcessRequest.outputLimit` bytes.
  public var standardOutput: Data
  /// Captured standard error, at most `ProcessRequest.outputLimit` bytes.
  public var standardError: Data
  /// Whether standard output exceeded the cap and was cut.
  public var standardOutputTruncated: Bool
  /// Whether standard error exceeded the cap and was cut.
  public var standardErrorTruncated: Bool
  /// Wall-clock time from spawn until the child was reaped.
  public var duration: Duration
  /// Whether the request's timeout fired and the runner killed the process group.
  public var timedOut: Bool

  /// Creates a result. Used by runner implementations and test fakes.
  public init(
    processID: Int32,
    termination: Termination,
    standardOutput: Data = Data(),
    standardError: Data = Data(),
    standardOutputTruncated: Bool = false,
    standardErrorTruncated: Bool = false,
    duration: Duration = .zero,
    timedOut: Bool = false
  ) {
    self.processID = processID
    self.termination = termination
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.standardOutputTruncated = standardOutputTruncated
    self.standardErrorTruncated = standardErrorTruncated
    self.duration = duration
    self.timedOut = timedOut
  } // End of init(processID:termination:…)

  /// The exit status, or `nil` when the process was killed by a signal.
  public var exitCode: Int32? {
    if case .exited(let code) = termination { return code }
    return nil
  }

  /// The terminating signal, or `nil` when the process exited normally.
  public var signal: Int32? {
    if case .signaled(let signal) = termination { return signal }
    return nil
  }

  /// `true` when the process exited with status 0 and did not time out.
  public var succeeded: Bool {
    termination == .exited(0) && !timedOut
  }
}

/// Why a process could not be run. Messages never include argument values, which may hold
/// user data.
public enum ProcessRunnerError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The executable URL is not an absolute file path.
  case executableNotAbsolute
  /// The argument at this index (0-based, excluding argv[0]) contains a NUL byte.
  case argumentContainsNUL(index: Int)
  /// An environment variable name is empty or contains `=` or NUL, or its value contains NUL.
  case invalidEnvironmentVariable(name: String)
  /// `posix_spawn` failed with this errno (for example `ENOENT` or `EACCES`).
  case spawnFailed(errno: Int32)
  /// A supporting system call failed.
  case systemCallFailed(name: String, errno: Int32)

  /// A short developer-facing description.
  public var description: String {
    switch self {
    case .executableNotAbsolute:
      return "The executable path is not absolute."
    case .argumentContainsNUL(let index):
      return "Argument \(index) contains a NUL byte."
    case .invalidEnvironmentVariable(let name):
      return "Environment variable \(name) has an invalid name or value."
    case .spawnFailed(let code):
      return "Could not start the process: \(String(cString: strerror(code)))."
    case .systemCallFailed(let name, let code):
      return "\(name) failed: \(String(cString: strerror(code)))."
    }
  } // End of var description
}
