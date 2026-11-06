import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The real static folder-search script (PLAN.md D36), run through `/bin/sh` and `dash` with
/// stub `mdfind` and `mdutil` first on `PATH` that print synthetic paths: the header, the query
/// lines and their errors, the predicate as one argument, the noise rule, the 50 limit, the
/// early stop (also amid endless left-out folders), the deadline and the end records, with no
/// stub left running after an answer. No Spotlight, no real folder, nothing over SSH.
@Suite("Folder search script")
struct FolderSearchScriptTests {
  /// The predicate the script builds for `escaped` name text.
  static func predicate(_ escaped: String) -> String {
    #"kMDItemContentType == "public.folder" && kMDItemFSName == "*"# + escaped + #"*"cd"#
  }

  /// The header reports the home folder, `mdfind`, both indexing states from `mdutil -s` (the
  /// home's volume from `df -P`, and `/`) and the protected folders' readability; then the
  /// script ends at end of input with status 0.
  @Test(arguments: FolderSearchSandbox.shells)
  func writesTheHeader(shell: String) async throws {
    let sandbox = try FolderSearchSandbox()
    defer { sandbox.remove() }
    let documents = sandbox.home.appending(path: "Documents").path(percentEncoded: false)
    #expect(chmod(documents, 0) == 0)
    let run = try await sandbox.run(
      [], shell: shell,
      environment: sandbox.environment(extra: ["MFX_HOME_INDEX": "Indexing disabled."]))
    #expect(run.result.succeeded)
    let header = try #require(run.header)
    #expect(header.homeDirectory == sandbox.homePath)
    #expect(header.hasSpotlight)
    #expect(header.homeIndexing == .off)
    #expect(header.diskIndexing == .on)
    #expect(header.desktop == .readable)
    if geteuid() != 0 { #expect(header.documents == .unreadable) }
    #expect(header.downloads == .missing)
    let volumes = sandbox.mdutilCalls()
    #expect(volumes.count == 2)
    #expect(volumes.contains("-s /"))
    #expect(
      volumes.contains { $0.hasPrefix("-s /") && $0 != "-s /" && $0 != "-s \(sandbox.homePath)" })
    #expect(sandbox.mdfindCalls().isEmpty)
  } // End of func writesTheHeader(shell:)

  /// Unknown `mdutil` output is `unknown`; a home with a trailing slash loses it; a relative
  /// `HOME` is no home (the home scope then answers `error home`, the disk scope still works).
  @Test func headerEdgeCases() async throws {
    let sandbox = try FolderSearchSandbox()
    defer { sandbox.remove() }
    let odd = try await sandbox.run(
      [],
      environment: sandbox.environment(
        home: sandbox.homePath + "/", extra: ["MFX_DISK_INDEX": "Error: unknown indexing state."]))
    #expect(odd.header?.homeDirectory == sandbox.homePath)
    #expect(odd.header?.diskIndexing == .unknown)
    try sandbox.writePaths(["/syn/a"])
    let relative = try await sandbox.run(
      ["1 home ab", "2 disk ab"], environment: sandbox.environment(home: "relative/home"))
    #expect(relative.header?.homeDirectory == nil)
    #expect(relative.header?.desktop == .missing)
    #expect(relative.reply(1) == FolderSearchReply(id: 1, status: .error("home"), paths: []))
    #expect(relative.reply(2) == FolderSearchReply(id: 2, status: .ok, paths: ["/syn/a"]))
  } // End of func headerEdgeCases()

  /// Without `mdfind` (and `mdutil`) on `PATH`: the header says so, the states are unknown, and
  /// a query gets `error unavailable`.
  @Test func reportsNoSpotlight() async throws {
    let sandbox = try FolderSearchSandbox(stubs: false)
    defer { sandbox.remove() }
    let run = try await sandbox.run(["1 home ab"], environment: sandbox.environment(stubs: false))
    #expect(run.header?.hasSpotlight == false)
    #expect(run.header?.homeIndexing == .unknown)
    #expect(run.header?.diskIndexing == .unknown)
    #expect(run.replies == [FolderSearchReply(id: 1, status: .error("unavailable"), paths: [])])
  }

  /// The predicate goes to `mdfind -0` as one argument, after `-onlyin <home>` for `home`; the
  /// name text is data, shell metacharacters included, and no file appears.
  @Test(arguments: FolderSearchSandbox.shells)
  func passesThePredicateAsOneArgument(shell: String) async throws {
    let sandbox = try FolderSearchSandbox()
    defer { sandbox.remove() }
    try sandbox.writePaths(["/syn/one"])
    let hostile = try FolderSearchText.nameText(for: #"$(touch x) `y` ; | 'q' "d" *?\ ${HOME}"#)
    let lines = [
      "1 home do", "2 disk  pro ", "3 home \(hostile.escaped)",
    ]
    let run = try await sandbox.run(lines, shell: shell, environment: sandbox.environment())
    #expect(run.replies.map(\.status) == [.ok, .ok, .ok])
    let calls = sandbox.mdfindCalls()
    #expect(
      calls == [
        ["-0", "-onlyin", sandbox.homePath, Self.predicate("do")],
        ["-0", Self.predicate(" pro ")],
        ["-0", "-onlyin", sandbox.homePath, Self.predicate(hostile.escaped)],
      ])
    let names = try FileManager.default.contentsOfDirectory(
      atPath: sandbox.root.path(percentEncoded: false))
    #expect(Set(names) == ["bin", "home", "paths", "mdfind.log", "mdfind.pids", "mdutil.log"])
  } // End of func passesThePredicateAsOneArgument(shell:)

  /// Malformed lines get an error answer for their id (or are skipped without a usable id), and
  /// the script keeps reading; none reaches `mdfind`.
  @Test(arguments: FolderSearchSandbox.shells)
  func answersMalformedLines(shell: String) async throws {
    let sandbox = try FolderSearchSandbox()
    defer { sandbox.remove() }
    try sandbox.writePaths(["/syn/a"])
    let lines = [
      "x1 home ab", "", " 2 home ab", "1234567890123456789 home ab",
      "3", "4 home", "5 everywhere ab", "6 home ", "7 home a\"b", "8 home a\\", "9 home a\\b",
      "10 home a*b", "11 home a?b", "12 home a\tb", "13 home " + String(repeating: "a", count: 513),
      "14 home " + String(repeating: "\\*", count: 256), "15 home a\\\"b",
    ]
    let run = try await sandbox.run(lines, shell: shell, environment: sandbox.environment())
    let expected: [(UInt64, FolderSearchReply.Status)] = [
      (3, .error("malformed")), (4, .error("malformed")), (5, .error("scope")),
      (6, .error("length")), (7, .error("text")), (8, .error("text")), (9, .error("text")),
      (10, .error("text")), (11, .error("text")), (12, .error("text")), (13, .error("length")),
      (14, .ok), (15, .ok),
    ]
    #expect(run.replies.map(\.id) == expected.map(\.0))
    #expect(run.replies.map(\.status) == expected.map(\.1))
    #expect(
      sandbox.mdfindCalls().map(\.last) == [
        Self.predicate(String(repeating: "\\*", count: 256)), Self.predicate("a\\\"b"),
      ])
  } // End of func answersMalformedLines(shell:)

  /// The noise rule, for the home scope and the whole disk (a synthetic `HOME` under `/Users`,
  /// which need not exist).
  @Test(arguments: FolderSearchSandbox.shells)
  func appliesTheNoiseRule(shell: String) async throws {
    let sandbox = try FolderSearchSandbox()
    defer { sandbox.remove() }
    let home = "/Users/synthetic-home"
    let kept = [
      "\(home)/Libraryx", "\(home)/a/Library", "/syn/a.b/c", "/syn/my_node_modules",
      "/syn/Podsx", "/syn/Foo.app", "/syn/app/y", "/syn/x.appx/y", "/syn/build", "/syn/dist",
      "/syn/target", "/Applications/Syn", "/Volumes/Syn/x", "/Systemx", "/usrx/y",
      "/Users/synthetic/projects/Library",
    ]
    let alwaysOut = [
      "\(home)/Library", "\(home)/Library/x", "/syn/.git", "/syn/.hidden/x", "/syn/x/.y",
      "/syn/node_modules", "/syn/node_modules/pkg", "/syn/DerivedData/x", "/syn/Pods",
      "/syn/__pycache__", "/syn/Foo.app/Contents", "/syn/x.framework/y", "/syn/x.bundle/y",
      "/syn/x.plugin/y", "/syn/x.kext/y", "/syn/p.photoslibrary/y", "/syn/p.xcodeproj/y",
      "/syn/p.xcworkspace/y", "/syn/p.xcassets/y",
    ]
    let diskOnlyOut = [
      "/Users/synthetic/Library", "/Users/synthetic/Library/x", "/System", "/System/x",
      "/Library/x", "/private/var", "/usr/local", "/bin", "/sbin/x", "/opt/x", "/cores",
      "/dev/x",
    ]
    var all: [String] = []
    for (index, path) in (alwaysOut + diskOnlyOut).enumerated() {
      all.append(path)
      if index < kept.count { all.append(kept[index]) }
    } // End of loop interleaving kept and left-out paths
    try sandbox.writePaths(all)
    let run = try await sandbox.run(
      ["1 home ab", "2 disk ab"], shell: shell, environment: sandbox.environment(home: home))
    #expect(run.reply(1)?.paths == all.filter { kept.contains($0) || diskOnlyOut.contains($0) })
    #expect(run.reply(2)?.paths == all.filter { kept.contains($0) })
    #expect(run.reply(1)?.status == .ok)
  } // End of func appliesTheNoiseRule(shell:)

  /// At most 50 folders, the first 50 kept in `mdfind`'s order, with noise interleaved and a
  /// name holding a line feed among them; exactly 50 kept is `ok`, not `limited`.
  @Test(arguments: FolderSearchSandbox.shells)
  func stopsAtFiftyWithNoiseInterleaved(shell: String) async throws {
    let sandbox = try FolderSearchSandbox()
    defer { sandbox.remove() }
    var kept: [String] = []
    var all: [String] = []
    for index in 1...120 {
      let path = index == 3 ? "/syn/line\nbreak \(index)" : "/syn/kept \(index)"
      kept.append(path)
      all += [path, "/syn/.noise/\(index)", "/syn/node_modules/\(index)"]
    } // End of loop building the paths
    try sandbox.writePaths(all)
    let limited = try await sandbox.run(
      ["7 disk ab"], shell: shell, environment: sandbox.environment())
    #expect(
      limited.replies == [FolderSearchReply(id: 7, status: .limited, paths: Array(kept.prefix(50)))]
    )
    try sandbox.writePaths(Array(all.prefix(150)))
    let exact = try await sandbox.run(
      ["8 disk ab"], shell: shell, environment: sandbox.environment())
    #expect(exact.replies == [FolderSearchReply(id: 8, status: .ok, paths: Array(kept.prefix(50)))])
    try sandbox.writePaths(Array(all.prefix(153)))
    let over = try await sandbox.run(
      ["9 disk ab"], shell: shell, environment: sandbox.environment())
    #expect(over.reply(9)?.status == .limited)
  } // End of func stopsAtFiftyWithNoiseInterleaved(shell:)

  /// An endless `mdfind` is stopped once 50 folders are kept: the answer is `limited` and the
  /// run ends well within its timeout; the next query is answered on the same script.
  @Test(arguments: FolderSearchSandbox.shells)
  func stopsAnEndlessSearch(shell: String) async throws {
    let sandbox = try FolderSearchSandbox()
    defer { sandbox.remove() }
    let started = ContinuousClock.now
    let run = try await sandbox.run(
      ["1 disk ab", "2 disk ab"], shell: shell, environment: sandbox.environment(mode: "endless"),
      timeout: .seconds(20))
    #expect(!run.result.timedOut)
    #expect(ContinuousClock.now - started < .seconds(10))
    #expect(run.replies.count == 2)
    #expect(run.replies.allSatisfy { $0.status == .limited && $0.paths.count == 50 })
    #expect(run.replies.map(\.id) == [1, 2])
    #expect(sandbox.mdfindProcessIDs().count == 2)
    #expect(await sandbox.noStubLeft())
  } // End of func stopsAnEndlessSearch(shell:)

  /// Once 50 folders are kept and a 51st is, `mdfind` is stopped even when everything it prints
  /// after them is left out (so the filter writes nothing more): the answer is `limited` at
  /// once, well before the deadline, the next query is answered too, and no stub is left.
  @Test(arguments: FolderSearchSandbox.shells)
  func stopsAtTheLimitAmidEndlessNoise(shell: String) async throws {
    let sandbox = try FolderSearchSandbox()
    defer { sandbox.remove() }
    let kept = (1...51).map { "/syn/kept \($0)" }
    try sandbox.writePaths(kept)
    let started = ContinuousClock.now
    let run = try await sandbox.run(
      ["1 disk ab", "2 home ab"], shell: shell, environment: sandbox.environment(mode: "noise"),
      timeout: .seconds(15))
    #expect(!run.result.timedOut)
    // Two queries ending at the deadline would take at least 8 s.
    #expect(ContinuousClock.now - started < FolderSearchScript.searchDeadline * 1.5)
    let limited = [UInt64(1), 2].map { id in
      FolderSearchReply(id: id, status: .limited, paths: Array(kept.prefix(50)))
    }
    #expect(run.replies == limited)
    #expect(sandbox.mdfindProcessIDs().count == 2)
    #expect(await sandbox.noStubLeft())
  } // End of func stopsAtTheLimitAmidEndlessNoise(shell:)

  /// A search that blocks is stopped on the host at the deadline: `mdfind` is killed and
  /// reaped, the query gets `error timeout`, and the same script answers the next query.
  @Test(arguments: FolderSearchSandbox.shells)
  func answersATimeoutForABlockedSearch(shell: String) async throws {
    let sandbox = try FolderSearchSandbox()
    defer { sandbox.remove() }
    try sandbox.writePaths(["/syn/a"])
    let started = ContinuousClock.now
    let run = try await sandbox.run(
      ["1 disk ab", "2 disk ab"], shell: shell,
      environment: sandbox.environment(mode: "hang-once"), timeout: .seconds(15))
    let elapsed = ContinuousClock.now - started
    #expect(!run.result.timedOut)
    #expect(elapsed >= FolderSearchScript.searchDeadline)
    #expect(elapsed < FolderSearchScript.searchDeadline * 2)
    #expect(
      run.replies == [
        FolderSearchReply(id: 1, status: .error("timeout"), paths: []),
        FolderSearchReply(id: 2, status: .ok, paths: ["/syn/a"]),
      ])
    #expect(sandbox.mdfindProcessIDs().count == 2)
    #expect(await sandbox.noStubLeft())
  } // End of func answersATimeoutForABlockedSearch(shell:)

  /// The deadlines in Swift are the script's (`u 4`, `u 1`), and the host's deadline ends a
  /// search before the channel's own answer wait does.
  @Test func deadlinesMatchTheScript() {
    let source = FolderSearchScript.script.source
    #expect(FolderSearchScript.searchDeadline == .seconds(4))
    #expect(FolderSearchScript.answerSignalWait == .seconds(1))
    #expect(source.contains("\nu 4\n"))
    #expect(source.contains("\nu 1\n"))
    #expect(
      FolderSearchScript.searchDeadline < FolderSearchChannel.Configuration().answerTimeout)
  } // End of func deadlinesMatchTheScript()

  /// A failing `mdfind` is `error search`, whatever it printed; no paths are passed on.
  @Test func reportsAFailedSearch() async throws {
    let sandbox = try FolderSearchSandbox()
    defer { sandbox.remove() }
    try sandbox.writePaths(["/syn/a", "/syn/b"])
    let run = try await sandbox.run(["1 home ab"], environment: sandbox.environment(mode: "fail"))
    #expect(run.replies == [FolderSearchReply(id: 1, status: .error("search"), paths: [])])
  }

  /// No match is `ok 0`; answers come in order, one per line.
  @Test func answersEveryLineInOrder() async throws {
    let sandbox = try FolderSearchSandbox()
    defer { sandbox.remove() }
    let run = try await sandbox.run(
      (1...5).map { "\($0) home ab" }, environment: sandbox.environment())
    #expect(
      run.replies == (1...5).map { FolderSearchReply(id: UInt64($0), status: .ok, paths: []) })
  }
}
