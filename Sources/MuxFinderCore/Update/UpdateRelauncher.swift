import Darwin
import Foundation

/// Why the relauncher could not be started (PLAN.md D39, I-13b2).
public enum UpdateRelaunchError: Error, Sendable, Hashable {
  /// An argument is unusable: the pid is not positive, the opener or the bundle path is not
  /// absolute (or holds a NUL or a line break), or the wait is out of range.
  case unusableArgument
  /// `posix_spawn` failed with this errno.
  case spawnFailed(errno: Int32)

  /// The errno behind the failure (`EINVAL` for an unusable argument).
  public var errnoValue: Int32 {
    switch self {
    case .unusableArgument: return EINVAL
    case .spawnFailed(let code): return code
    }
  }
}

/// The relauncher (PLAN.md D39, I-13b2): after a successful swap, a small detached process
/// that waits for the app to end, then opens the installed bundle once. It is `/bin/sh -c
/// <script> muxfinder-relaunch <pid> <opener> <bundle path> <wait seconds>`: the script is the
/// compiled-in constant `script` (PLAN.md D3), and every runtime value is an argument, never
/// part of the script. It is spawned detached (`POSIX_SPAWN_SETSID`, standard input, output
/// and error `/dev/null`, no other inherited descriptor through `POSIX_SPAWN_CLOEXEC_DEFAULT`,
/// default signal dispositions, an empty signal mask) with only `PATH=/usr/bin:/bin` in its
/// environment, and never waited for. The script polls `kill -0 <pid>` every 0.25 s; once the
/// pid has ended it runs `<opener> <bundle path>` (`exec`, once); when the wait runs out it
/// opens nothing and exits 75. Unusable arguments exit 64 before anything is opened. The app
/// passes `/usr/bin/open` (`systemOpener`) and the absolute installed path, whose leading `/`
/// keeps it from being read as an option. The relauncher never terminates the app: I-13c
/// quits after the pipeline returns.
public enum UpdateRelauncher {
  /// The shell that runs the script.
  public static let shell = "/bin/sh"
  /// The script's `$0`.
  public static let scriptName = "muxfinder-relaunch"
  /// The opener the app passes.
  public static let systemOpener = "/usr/bin/open"
  /// How long the script waits for the pid by default, in seconds (worker's number: the app's
  /// quit deadline is 15 s, PLAN.md D22, so 60 s covers a slow quit with room to spare).
  public static let defaultWaitSeconds = 60
  /// The waits accepted, in seconds.
  public static let waitRange = 1...600
  /// The environment the script runs with.
  public static let environment = ["PATH=/usr/bin:/bin"]
  /// The exit status of unusable arguments.
  public static let exitUsage: Int32 = 64
  /// The exit status when the wait ran out (nothing opened).
  public static let exitTimedOut: Int32 = 75

  /// The script (a constant; arguments `$1` pid, `$2` opener, `$3` bundle path, `$4` wait in
  /// seconds).
  public static let script = """
    pid=$1 opener=$2 bundle=$3 limit=$4
    case $pid in ''|0|*[!0-9]*) exit 64 ;; esac
    case $limit in ''|*[!0-9]*) exit 64 ;; esac
    case $opener in /*) ;; *) exit 64 ;; esac
    case $bundle in /*) ;; *) exit 64 ;; esac
    ticks=$((limit * 4))
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$ticks" -le 0 ]; then exit 75; fi
      ticks=$((ticks - 1))
      sleep 0.25
    done
    exec "$opener" "$bundle"
    """

  /// The full argv for waiting on `processID` and then running `opener` with `bundlePath`.
  public static func arguments(
    processID: Int32, opener: String, bundlePath: String, waitSeconds: Int = defaultWaitSeconds
  ) throws(UpdateRelaunchError) -> [String] {
    guard processID > 0, isAbsolute(opener), isAbsolute(bundlePath),
      waitRange.contains(waitSeconds)
    else { throw .unusableArgument }
    return [
      shell, "-c", script, scriptName, String(processID), opener, bundlePath, String(waitSeconds),
    ]
  } // End of static func arguments(processID:opener:bundlePath:waitSeconds:)

  /// Whether `path` is absolute with no NUL or line break.
  static func isAbsolute(_ path: String) -> Bool {
    path.hasPrefix("/") && !path.contains("\0") && !path.contains("\n") && !path.contains("\r")
  }

  /// Spawns `arguments` (from `arguments(processID:…)`, whose first element is the shell)
  /// detached (see the type) and returns its pid without waiting for it.
  public static func spawn(_ arguments: [String]) throws(UpdateRelaunchError) -> Int32 {
    guard arguments.first == shell, !arguments.contains(where: { $0.contains("\0") }) else {
      throw .unusableArgument
    }
    var actions: posix_spawn_file_actions_t?
    let initialized = posix_spawn_file_actions_init(&actions)
    guard initialized == 0 else { throw .spawnFailed(errno: initialized) }
    defer { posix_spawn_file_actions_destroy(&actions) }
    for descriptor: Int32 in 0...2 {
      let status = posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_RDWR, 0)
      guard status == 0 else { throw .spawnFailed(errno: status) }
    } // End of loop over the standard descriptors
    var attributes: posix_spawnattr_t?
    let attributesInitialized = posix_spawnattr_init(&attributes)
    guard attributesInitialized == 0 else { throw .spawnFailed(errno: attributesInitialized) }
    defer { posix_spawnattr_destroy(&attributes) }
    try configure(&attributes)
    let argv: CStringArray
    let envp: CStringArray
    do throws(ProcessRunnerError) {
      argv = try CStringArray(arguments)
      envp = try CStringArray(environment)
    } catch {
      throw .spawnFailed(errno: ENOMEM)
    }
    var processID: pid_t = 0
    let status = argv.withUnsafePointer { argvPointer in
      envp.withUnsafePointer { envPointer in
        posix_spawn(&processID, shell, &actions, &attributes, argvPointer, envPointer)
      }
    }
    guard status == 0 else { throw .spawnFailed(errno: status) }
    return processID
  } // End of static func spawn(_:)

  /// Sets the detached child's attributes: a new session, only the file actions' descriptors,
  /// an empty signal mask and default dispositions.
  static func configure(_ attributes: inout posix_spawnattr_t?) throws(UpdateRelaunchError) {
    let flags =
      POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK
      | POSIX_SPAWN_SETSIGDEF
    var blocked = sigset_t()
    sigemptyset(&blocked)
    var defaults = sigset_t()
    sigfillset(&defaults)
    sigdelset(&defaults, SIGKILL)
    sigdelset(&defaults, SIGSTOP)
    for status in [
      posix_spawnattr_setflags(&attributes, Int16(flags)),
      posix_spawnattr_setsigmask(&attributes, &blocked),
      posix_spawnattr_setsigdefault(&attributes, &defaults),
    ] where status != 0 {
      throw .spawnFailed(errno: status)
    } // End of loop over the attribute calls' statuses
  } // End of static func configure(_:)
}

/// Starts the relauncher (PLAN.md D39, I-13b2); a seam, so the pipeline's tests can record or
/// fail it.
public protocol UpdateRelaunching: Sendable {
  /// Starts a relauncher waiting for `processID` to end, then opening `bundlePath`; its pid.
  func relaunch(after processID: Int32, bundlePath: String) -> Result<Int32, UpdateRelaunchError>
}

/// The real relauncher: `UpdateRelauncher.spawn` with `opener`. The app passes
/// `UpdateRelauncher.systemOpener`; tests pass a harmless stand-in (never `/usr/bin/open`).
public struct DetachedUpdateRelauncher: UpdateRelaunching {
  /// What the script runs once the pid has ended.
  public let opener: String
  /// How long it waits, in seconds.
  public let waitSeconds: Int

  /// A relauncher running `opener` after at most `waitSeconds`.
  public init(opener: String, waitSeconds: Int = UpdateRelauncher.defaultWaitSeconds) {
    self.opener = opener
    self.waitSeconds = waitSeconds
  }

  /// See `UpdateRelaunching`.
  public func relaunch(after processID: Int32, bundlePath: String) -> Result<
    Int32, UpdateRelaunchError
  > {
    do throws(UpdateRelaunchError) {
      let arguments = try UpdateRelauncher.arguments(
        processID: processID, opener: opener, bundlePath: bundlePath, waitSeconds: waitSeconds)
      return .success(try UpdateRelauncher.spawn(arguments))
    } catch {
      return .failure(error)
    }
  } // End of func relaunch(after:bundlePath:)
}
