import Darwin
import Foundation

@testable import MuxFinderCore

/// Helpers for the folder-search tests (PLAN.md D36): a private folder with stub `mdfind` and
/// `mdutil` first on `PATH` that print synthetic paths (no Spotlight, no real folder name), a
/// synthetic home folder, and runs of the real static script through local shells.
struct FolderSearchSandbox {
  /// The private folder (the caller removes it with `remove()`).
  let root: URL
  /// The stub tools' folder, first on `PATH`.
  let bin: URL
  /// The synthetic home folder.
  let home: URL

  /// The stub `mdfind`, one long-lived process as the real one is: appends its pid to
  /// `mdfind.pids` and logs each argument on a line of its own (`[<argument>]`, after the
  /// count) to `mdfind.log`, then by `MFX_MODE` prints `paths` (default), prints `paths` and
  /// exits 4 (`fail`), prints `/syn/endless` records forever (`endless`), prints `paths` and
  /// then hidden, so left-out, folders forever (`noise`), blocks for 30 s (`hang`), or blocks
  /// on its first call only and prints `paths` on later ones (`hang-once`).
  static let mdfindStub = #"""
    #!/bin/sh
    printf '%s\n' "$$" >> "$MFX_DIR/mdfind.pids"
    { printf '%s\n' "$#"; for a do printf '[%s]\n' "$a"; done; } >> "$MFX_DIR/mdfind.log"
    case ${MFX_MODE-} in
      fail) cat "$MFX_DIR/paths"; exit 4 ;;
      endless) while :; do printf '/syn/endless\000'; done ;;
      noise) cat "$MFX_DIR/paths"; while :; do printf '/syn/.noise/x\000'; done ;;
      hang) exec sleep 30 ;;
      hang-once)
        if [ ! -e "$MFX_DIR/hung" ]; then : > "$MFX_DIR/hung"; exec sleep 30; fi
        ;;
    esac
    cat "$MFX_DIR/paths"

    """#

  /// The stub `mdutil`: logs its arguments to `mdutil.log` and prints `$MFX_DISK_INDEX` for
  /// `/` and `$MFX_HOME_INDEX` for any other volume, in `mdutil -s`'s layout.
  static let mdutilStub = #"""
    #!/bin/sh
    printf '%s\n' "$*" >> "$MFX_DIR/mdutil.log"
    if [ "$2" = / ]; then s=${MFX_DISK_INDEX-Indexing enabled.}; else s=${MFX_HOME_INDEX-Indexing enabled.}; fi
    printf '%s:\n\t%s\n' "$2" "$s"

    """#

  /// The tools the script needs besides `mdfind` and `mdutil`, for a `PATH` without them.
  static let tools = [
    "/bin/ls", "/bin/df", "/usr/bin/tail", "/usr/bin/wc", "/usr/bin/tr", "/usr/bin/head",
    "/usr/bin/xargs", "/usr/bin/yes",
  ]

  /// A sandbox with the stubs (unless `stubs` is false) and a home folder holding a readable
  /// `Desktop` and `Documents` and no `Downloads`.
  init(stubs: Bool = true) throws {
    root = try TestSupport.makeTemporaryDirectory()
    bin = root.appending(path: "bin", directoryHint: .isDirectory)
    home = root.appending(path: "home", directoryHint: .isDirectory)
    let manager = FileManager.default
    try manager.createDirectory(at: bin, withIntermediateDirectories: false)
    try manager.createDirectory(at: home, withIntermediateDirectories: false)
    for name in ["Desktop", "Documents"] {
      try manager.createDirectory(
        at: home.appending(path: name), withIntermediateDirectories: false)
    }
    if stubs {
      try Self.install(Self.mdfindStub, as: "mdfind", in: bin)
      try Self.install(Self.mdutilStub, as: "mdutil", in: bin)
    } else {
      for tool in Self.tools {
        let name = URL(fileURLWithPath: tool).lastPathComponent
        try manager.createSymbolicLink(
          at: bin.appending(path: name), withDestinationURL: URL(fileURLWithPath: tool))
      } // End of loop over linked tools
    }
    try writePaths([])
  } // End of init(stubs:)

  /// Writes `script` as an executable file `name` in `directory`.
  static func install(_ script: String, as name: String, in directory: URL) throws {
    let url = directory.appending(path: name)
    try Data(script.utf8).write(to: url)
    guard chmod(url.path(percentEncoded: false), 0o755) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  /// The home folder's path.
  var homePath: String { home.path(percentEncoded: false).trimmingSuffix("/") }

  /// Sets the paths the stub prints, NUL-separated.
  func writePaths(_ paths: [String]) throws {
    try Data(paths.flatMap { Array($0.utf8) + [0] }).write(to: root.appending(path: "paths"))
  }

  /// The stub `mdfind`'s calls: each the list of its arguments.
  func mdfindCalls() -> [[String]] {
    let text = (try? String(contentsOf: root.appending(path: "mdfind.log"), encoding: .utf8)) ?? ""
    var calls: [[String]] = []
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
    while let count = lines.popFirst().flatMap({ Int($0) }) {
      var arguments: [String] = []
      for _ in 0..<count {
        guard let line = lines.popFirst(), line.hasPrefix("["), line.hasSuffix("]") else { break }
        arguments.append(String(line.dropFirst().dropLast()))
      } // End of loop over one call's arguments
      calls.append(arguments)
    } // End of loop over calls
    return calls
  } // End of func mdfindCalls()

  /// The pids of every stub `mdfind` started so far, in order.
  func mdfindProcessIDs() -> [pid_t] {
    let data = (try? Data(contentsOf: root.appending(path: "mdfind.pids"))) ?? Data()
    return TestSupport.processIDs(in: data)
  }

  /// Waits up to `limit` until no stub `mdfind` started so far is running (each pid checked
  /// with `kill(pid, 0)`); returns whether none is.
  func noStubLeft(within limit: Duration = .seconds(3)) async -> Bool {
    let processIDs = mdfindProcessIDs()
    return await TestSupport.eventually(within: limit) {
      processIDs.allSatisfy(TestSupport.processIsGone)
    }
  }

  /// The stub `mdutil`'s calls, one argument string each.
  func mdutilCalls() -> [String] {
    let text = (try? String(contentsOf: root.appending(path: "mdutil.log"), encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
  }

  /// The environment of a run: the stubs first on `PATH` (or only the linked tools and `/bin`
  /// when there are no stubs), the home folder and the stub settings.
  func environment(
    mode: String? = nil, home: String? = nil, extra: [String: String] = [:], stubs: Bool = true
  ) -> [String: String] {
    var environment = extra
    environment["PATH"] =
      stubs
      ? bin.path(percentEncoded: false) + ":" + ProcessEnvironment.systemSearchPath
      : bin.path(percentEncoded: false) + ":/bin"
    environment["HOME"] = home ?? homePath
    environment["MFX_DIR"] = root.path(percentEncoded: false)
    if let mode { environment["MFX_MODE"] = mode }
    return environment
  } // End of func environment(mode:home:extra:stubs:)

  /// Runs the real script through `shell` with `lines` on standard input (then end of input)
  /// and returns what it wrote, parsed: the header and every reply.
  func run(
    _ lines: [String],
    shell: String = "/bin/sh",
    environment: [String: String],
    timeout: Duration = .seconds(20)
  ) async throws -> ScriptRun {
    let request = ProcessRequest(
      executableURL: URL(fileURLWithPath: shell),
      arguments: ["-c", FolderSearchScript.script.source, ShellQuoting.scriptName],
      environment: environment,
      standardInput: .data(Data(lines.map { $0 + "\n" }.joined().utf8)),
      timeout: timeout)
    let result = try await TestSupport.fastRunner.run(request)
    var parser = FolderSearchOutputParser()
    let events = try parser.consume(result.standardOutput)
    try parser.finish()
    var run = ScriptRun(result: result)
    for event in events {
      switch event {
      case .header(let header): run.header = header
      case .reply(let reply): run.replies.append(reply)
      }
    } // End of loop over events
    return run
  } // End of func run(_:shell:environment:timeout:)

  /// Removes the private folder (after making every folder in it writable again).
  func remove() {
    _ = chmod(home.appending(path: "Documents").path(percentEncoded: false), 0o755)
    try? FileManager.default.removeItem(at: root)
  }

  /// The shells the script is tested under: `/bin/sh` (bash on macOS) and `dash` when present.
  static var shells: [String] {
    ["/bin/sh", "/bin/dash"].filter { FileManager.default.isExecutableFile(atPath: $0) }
  }
}

/// One run of the script.
struct ScriptRun {
  /// The process's result.
  var result: ProcessResult
  /// The header.
  var header: FolderSearchHeader?
  /// The replies, in order.
  var replies: [FolderSearchReply] = []

  /// The reply with `id`.
  func reply(_ id: UInt64) -> FolderSearchReply? {
    replies.first { $0.id == id }
  }
}

extension String {
  /// The string without one trailing `suffix`.
  func trimmingSuffix(_ suffix: String) -> String {
    hasSuffix(suffix) && count > suffix.count ? String(dropLast(suffix.count)) : self
  }
}

/// Waits for asynchronous effects of the folder-search channel in tests.
enum FolderSearchWait {
  /// Polls `condition` every 2 ms until it holds or `limit` passes; returns the final value.
  /// Only for waiting on something the code under test does asynchronously.
  static func until(
    within limit: Duration = .seconds(5),
    _ condition: () async -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while clock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
  } // End of static func until(within:_:)
}
