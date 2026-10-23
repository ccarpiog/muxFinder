import Darwin
import Foundation

/// The user's login shell, which the persistent profile's helper starts in place of tmux when
/// it must not or cannot start the persistent session (PLAN.md D26): the tab then behaves like
/// an ordinary iTerm2 tab.
public struct LoginShell: Sendable, Hashable {
  /// The shells tried after the passwd entry's, in order: macOS's default shell since 10.15,
  /// then the POSIX shell every Mac has.
  public static let fallbackPaths = ["/bin/zsh", "/bin/sh"]

  /// The shell's absolute path.
  public let path: String

  /// Creates a shell at `path` (callers pass a usable path, `isUsable(_:)`).
  public init(path: String) {
    self.path = path
  }

  /// `argv[0]`: the shell's file name after a `-`, the convention that makes a shell a login
  /// shell (as `login(1)` and iTerm2 start them), for example `-zsh`.
  public var argv0: String {
    "-" + (path.split(separator: "/").last.map(String.init) ?? path)
  }

  /// The shells to try, in order: the passwd entry's shell (`passwdShell`) when it is usable,
  /// then each usable `fallbackPaths` entry not already listed. Empty only when none is usable.
  public static func candidates(
    passwdShell: String?,
    isUsable: (String) -> Bool = LoginShell.isUsable
  ) -> [LoginShell] {
    var paths: [String] = []
    for path in [passwdShell].compactMap({ $0 }) + fallbackPaths
    where !paths.contains(path) && isUsable(path) {
      paths.append(path)
    }
    return paths.map(LoginShell.init(path:))
  } // End of func candidates(passwdShell:isUsable:)

  /// Whether `path` can be a login shell: absolute, without control characters, and naming an
  /// executable regular file (links followed).
  public static func isUsable(_ path: String) -> Bool {
    guard path.hasPrefix("/"), !Validation.containsControlCharacter(path) else { return false }
    var info = stat()
    return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
  }

  /// The shell in this user's passwd entry (`getpwuid_r` for the real uid), or `nil`.
  public static func passwdShell() -> String? {
    var entry = passwd()
    var result: UnsafeMutablePointer<passwd>?
    var buffer = [CChar](repeating: 0, count: 16 * 1024)
    guard getpwuid_r(getuid(), &entry, &buffer, buffer.count, &result) == 0, result != nil,
      let shell = entry.pw_shell
    else { return nil }
    let text = String(cString: shell)
    return text.isEmpty ? nil : text
  } // End of func passwdShell()
}

/// What `LoginShellStarting.exec(_:environment:)` did.
public enum LoginShellExecResult: Sendable, Hashable {
  /// The process became the shell. A real exec never returns, so only fakes report this.
  case replaced
  /// The exec failed with this errno; the helper still runs.
  case failed(errno: Int32)
}

/// Starts the login shell in place of the helper. `ExecLoginShellStarter` is the production
/// implementation; tests pass a fake, so no test ever starts a real shell.
public protocol LoginShellStarting: Sendable {
  /// The shells to try, in order (`LoginShell.candidates(passwdShell:isUsable:)`).
  func candidates() -> [LoginShell]
  /// Replaces the process with `shell` (`argv` is just `shell.argv0`) and exactly
  /// `environment`; returns only when that failed.
  func exec(_ shell: LoginShell, environment: [String: String]) -> LoginShellExecResult
}

/// The real login shell: the passwd entry's shell, else `LoginShell.fallbackPaths`, started
/// with `posix_spawn` and `POSIX_SPAWN_SETEXEC`, so it replaces the helper (the same pid, the
/// session and the tab's foreground process group kept) with default signal dispositions, an
/// empty signal mask and only descriptors 0–2 open (`POSIX_SPAWN_CLOEXEC_DEFAULT`; one that is
/// closed becomes `/dev/null`). Never a shell command line: argv is `[-<name>]` and nothing
/// else, and no runtime value becomes shell source.
public struct ExecLoginShellStarter: LoginShellStarting {
  /// Creates the starter.
  public init() {}

  /// The passwd entry's shell when usable, then the usable fallbacks.
  public func candidates() -> [LoginShell] {
    LoginShell.candidates(passwdShell: LoginShell.passwdShell())
  }

  /// Execs `shell`; returns only when that failed.
  public func exec(_ shell: LoginShell, environment: [String: String]) -> LoginShellExecResult {
    let request = ProcessRequest(
      executableURL: URL(fileURLWithPath: shell.path), environment: environment)
    do throws(ProcessRunnerError) {
      let parameters = try ProcessSupervisor.launchParameters(for: request)
      let argv = try CStringArray([shell.argv0])
      let envp = try CStringArray(parameters.environment)
      var actions = try SpawnFileActions()
      defer { actions.destroy() }
      for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
        if fcntl(descriptor, F_GETFD) != -1 {
          try actions.inherit(descriptor)
        } else {
          try actions.openNullDevice(as: descriptor)
        }
      } // End of loop over the terminal descriptors
      var attributes = try SpawnAttributes(newProcessGroup: false, replacingProcess: true)
      defer { attributes.destroy() }
      var processID: pid_t = 0
      let code = argv.withUnsafePointer { argvPointer in
        envp.withUnsafePointer { envPointer in
          posix_spawn(
            &processID, parameters.path, &actions.raw, &attributes.raw, argvPointer, envPointer)
        }
      }
      return .failed(errno: code == 0 ? EINVAL : code)
    } catch {
      return .failed(errno: LaunchHelper.errorNumber(of: error))
    }
  } // End of func exec(_:environment:)
}
