import Darwin
import Foundation

@testable import MuxFinderCore

/// Helpers shared by the process and quoting tests. Everything runs local system binaries only
/// (`/bin/sh`, `/usr/bin/printf`, …); nothing touches ssh, tmux or iTerm2.
enum TestSupport {
  /// `/bin/sh`.
  static let shell = URL(fileURLWithPath: "/bin/sh")
  /// A minimal explicit environment for test children.
  static let environment = ["PATH": ProcessEnvironment.systemSearchPath]
  /// A runner with short grace periods so timeout tests finish quickly.
  static let fastRunner = PosixSpawnProcessRunner(
    terminationGracePeriod: .milliseconds(300),
    outputDrainGracePeriod: .milliseconds(200)
  )
  /// A runner whose grace period is far longer than any test cleanup, so a slow machine cannot
  /// turn the SIGKILL escalation into a flake. Runs still end as soon as the group is gone.
  static let patientRunner = PosixSpawnProcessRunner(
    terminationGracePeriod: .seconds(30),
    outputDrainGracePeriod: .milliseconds(200)
  )

  /// A group whose leader dies on SIGTERM while a background descendant traps TERM, spends
  /// 300 ms on cleanup, prints `cleaned` and only then leaves the `cleaned` marker.
  ///
  /// `$1` is a per-test directory. The leader writes `<leader pid> <descendant pid>` to `pids`.
  /// The descendant creates `ready` once its trap is installed; the leader waits for it and then
  /// creates `armed` (see `runArmedTimeoutScenario(_:runner:firstTimeout:attempts:)`).
  static let cleanupScript = """
    dir=$1
    (
      trap 'sleep 0.3; echo cleaned; : > "$dir/cleaned"; exit 0' TERM
      : > "$dir/ready"
      while :; do sleep 1; done
    ) &
    printf '%s %s\\n' "$$" "$!" > "$dir/pids"
    until [ -e "$dir/ready" ]; do sleep 0.01; done
    : > "$dir/armed"
    sleep 30
    """

  /// A timeout run whose scenario was fully set up before the timeout fired.
  struct ArmedRun {
    /// The run's result.
    let result: ProcessResult
    /// The timeout of the attempt that got armed.
    let timeout: Duration
    /// The attempt's directory with the script's marker files. The caller removes it.
    let directory: URL
  }

  /// Arguments that would break naive shell quoting: whitespace, quotes, substitutions,
  /// operators, globs, option-like words, escapes, emoji and CJK.
  static let adversarialArguments: [String] = [
    "plain",
    "",
    "with space",
    "  leading and trailing  ",
    "it's",
    "''",
    #"'\''"#,
    #""double""#,
    "$(echo injected)",
    "`echo injected`",
    "${HOME}",
    "$HOME",
    "a;b",
    "a|b",
    "a&b",
    "a && b || c",
    "*",
    "?",
    "[a-z]",
    "{a,b}",
    "a>b<c",
    "(subshell)",
    "~",
    "~/dir",
    "-n",
    "-e",
    "--",
    "-",
    #"back\slash"#,
    #"trailing backslash\"#,
    "tab\tseparated",
    "new\nline",
    "carriage\rreturn",
    "!history",
    "#not a comment",
    "%s%n%%",
    "emoji 🧪🚀 👨‍👩‍👧",
    "日本語のセッション",
    "中文 한국어",
    #"mixed 'single' "double" $var `cmd` \ end"#,
  ]

  /// Builds a `/bin/sh -c <script> muxfinder-test <args…>` request. Test scripts are literals;
  /// data travels as positional parameters.
  static func shellRequest(
    _ script: String,
    arguments: [String] = [],
    timeout: Duration = .seconds(10)
  ) -> ProcessRequest {
    ProcessRequest(
      executableURL: shell,
      arguments: ["-c", script, "muxfinder-test"] + arguments,
      environment: environment,
      timeout: timeout
    )
  } // End of func shellRequest(_:arguments:timeout:)

  /// The bytes `printf '%s\0' <values…>` prints: every value followed by a NUL byte.
  static func nulTerminated(_ values: [String]) -> Data {
    var data = Data()
    for value in values {
      data.append(contentsOf: Array(value.utf8))
      data.append(0)
    }
    return data
  }

  /// Decimal numbers found in `data`, in order (used to read pids printed by test scripts).
  static func processIDs(in data: Data) -> [pid_t] {
    String(decoding: data, as: UTF8.self)
      .split(whereSeparator: { $0.isWhitespace })
      .compactMap { pid_t($0) }
  }

  /// Whether no process with this pid exists any more.
  static func processIsGone(_ processID: pid_t) -> Bool {
    kill(processID, 0) == -1 && errno == ESRCH
  }

  /// Whether no process is left in this process group.
  static func processGroupIsGone(_ groupID: pid_t) -> Bool {
    kill(-groupID, 0) == -1 && errno == ESRCH
  }

  /// Polls `condition` every 20 ms until it holds or `limit` passes. Returns the final value.
  static func eventually(
    within limit: Duration = .seconds(3),
    _ condition: () -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while clock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  } // End of func eventually(within:_:)

  /// A fresh, not yet existing path under the temporary directory.
  static func temporaryURL(_ suffix: String = "") -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "muxfinder-test-\(UUID().uuidString)\(suffix)"
    )
  }

  /// Runs `script` with a timeout until an attempt is set up before its timeout fires.
  ///
  /// Each attempt passes a fresh directory as `$1`. The script's leader creates `armed` there as
  /// its last setup step, after confirming every member is in place; a SIGTERM that arrived any
  /// earlier would have killed a member before it was ready (and the leader waiting for it), so
  /// `armed` proves the scenario was in place when the timeout fired. A heavily loaded machine
  /// can hold a fresh shell back for over a second, so an attempt without `armed` is
  /// inconclusive: it is discarded and retried with twice the timeout. Returns `nil` if no
  /// attempt got armed.
  static func runArmedTimeoutScenario(
    _ script: String,
    runner: PosixSpawnProcessRunner,
    firstTimeout: Duration,
    attempts: Int = 4
  ) async throws -> ArmedRun? {
    var timeout = firstTimeout
    for _ in 0..<attempts {
      let directory = try makeTemporaryDirectory()
      let request = shellRequest(
        script,
        arguments: [directory.path(percentEncoded: false)],
        timeout: timeout
      )
      let result: ProcessResult
      do {
        result = try await runner.run(request)
      } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
      }
      if fileExists("armed", in: directory) {
        return ArmedRun(result: result, timeout: timeout, directory: directory)
      }
      try? FileManager.default.removeItem(at: directory)
      timeout = timeout * 2
    } // End of loop over attempts
    return nil
  } // End of func runArmedTimeoutScenario(_:runner:firstTimeout:attempts:)

  /// Creates a fresh, empty directory under the temporary directory. The caller removes it.
  static func makeTemporaryDirectory() throws -> URL {
    let url = temporaryURL()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  /// Whether a file named `name` exists in `directory`.
  static func fileExists(_ name: String, in directory: URL) -> Bool {
    let path = directory.appending(path: name).path(percentEncoded: false)
    return FileManager.default.fileExists(atPath: path)
  }

  /// The pids in the file `name` of `directory`, or none if it is missing or not fully written
  /// (test scripts end the line with a newline once every pid is in).
  static func processIDs(inFile name: String, in directory: URL) -> [pid_t] {
    let text = (try? String(contentsOf: directory.appending(path: name), encoding: .utf8)) ?? ""
    return text.hasSuffix("\n") ? processIDs(in: Data(text.utf8)) : []
  }
}
