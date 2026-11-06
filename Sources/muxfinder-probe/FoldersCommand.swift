import Darwin
import Foundation
import MuxFinderCore

/// `muxfinder-probe folders`: opens one folder-search channel (PLAN.md D36) on This Mac or an
/// SSH host, asks it each `--name` in turn (`--repeat` times), and prints the header's facts,
/// each query's status, count and latency, and the channel's open time. Read-only: Spotlight
/// queries, `mdutil -s` and readability tests on the host, nothing written anywhere. The home
/// folder is printed only as present or absent, the typed names only by number and length, and
/// paths only with `--paths` (never in unattended runs: folder names are the user's).
enum FoldersCommand {
  /// Usage lines for this subcommand.
  static let usage = """
      folders --local | --ssh <destination> --name <text> [--name <text> …]
              [--scope home|disk] [--count-only | --paths] [--repeat <n>]
          Search folder names through one Spotlight channel (read-only) and print the header,
          each query's status, count and latency, and the channel's open time. Names are
          printed by number only. --count-only (the default) prints no path; --paths prints
          them (folder names are the user's: never in unattended runs). --repeat asks every
          name n times (1–100) on the same channel.
    """

  /// Parsed command-line options.
  struct Options {
    /// The host.
    var host: FolderSearchHost
    /// The texts, in order.
    var names: [String]
    /// The scope.
    var scope: FolderSearchScope = .standard
    /// Whether paths are printed.
    var printsPaths = false
    /// How many times every name is asked.
    var repeats = 1
  }

  /// Why the arguments were rejected.
  struct UsageError: Error {
    /// What is wrong, in English.
    let message: String
  }

  /// How long one query may take, debounce, open and answer included, before the probe gives
  /// up on it (the channel's own bounds are shorter).
  static let queryLimit: Duration = .seconds(40)

  /// Runs the subcommand with the arguments after `folders` and returns the exit status: 0
  /// when every query was answered (or the host reported folder search unavailable), 1 when one
  /// failed, `EX_USAGE` for bad arguments, 128 + n after signal n.
  static func run(_ arguments: [String]) async -> Int32 {
    if arguments.contains("--help") || arguments.contains("-h") {
      print(usage)
      return 0
    }
    let options: Options
    do {
      options = try parse(arguments)
    } catch let error as UsageError {
      printError("muxfinder-probe: \(error.message)\n\nusage:\n\(usage)")
      return EX_USAGE
    } catch {
      printError("muxfinder-probe: \(error)")
      return EX_USAGE
    }
    let watcher = SignalWatcher()
    let channel = FolderSearchChannel(transport: ProcessFolderSearchTransport())
    let queries = Task { await runQueries(options, channel: channel) }
    // The group returns only once both children have: a signal cancels the queries (awaiting
    // their value is not interrupted by cancellation), and the queries ending cancels the
    // watcher's child, whose stream then ends.
    let outcome = await withTaskGroup(of: Int32?.self) { group -> Int32 in
      group.addTask { await queries.value }
      group.addTask {
        for await number in watcher.stream {
          queries.cancel()
          return 128 + number
        }
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first ?? 1
    }
    if outcome > 128 { print("interrupted by signal \(outcome - 128); closing the channel") }
    let closeStart = ContinuousClock.now
    await channel.close()
    let closeTime = ContinuousClock.now - closeStart
    watcher.stop()
    print("closed in \(milliseconds(closeTime)) ms, child processes left: \(childProcessCount())")
    return outcome
  } // End of func run(_:)

  /// Parses the subcommand's arguments.
  static func parse(_ arguments: [String]) throws -> Options {
    var host: FolderSearchHost?
    var names: [String] = []
    var scope = FolderSearchScope.standard
    var paths = false
    var countOnly = false
    var repeats = 1
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
      switch argument {
      case "--local":
        guard host == nil else { throw UsageError(message: "use either --local or --ssh") }
        host = .local
      case "--ssh":
        guard host == nil else { throw UsageError(message: "use either --local or --ssh") }
        guard let value = remaining.popFirst() else {
          throw UsageError(message: "--ssh needs a destination")
        }
        host = .ssh(destination: value)
      case "--name":
        guard let value = remaining.popFirst() else {
          throw UsageError(message: "--name needs a text")
        }
        names.append(value)
      case "--scope":
        guard let value = remaining.popFirst(), let parsed = FolderSearchScope(rawValue: value)
        else { throw UsageError(message: "--scope needs home or disk") }
        scope = parsed
      case "--count-only":
        countOnly = true
      case "--paths":
        paths = true
      case "--repeat":
        guard let value = remaining.popFirst(), let count = Int(value), (1...100).contains(count)
        else { throw UsageError(message: "--repeat needs a number from 1 to 100") }
        repeats = count
      default:
        throw UsageError(message: "unknown option")
      }
    } // End of loop over arguments
    guard let host else { throw UsageError(message: "use --local or --ssh <destination>") }
    guard !names.isEmpty else { throw UsageError(message: "give at least one --name") }
    guard !(paths && countOnly) else {
      throw UsageError(message: "use either --count-only or --paths")
    }
    return Options(host: host, names: names, scope: scope, printsPaths: paths, repeats: repeats)
  } // End of func parse(_:)

  /// Asks every name in turn and prints each result. Returns 0 when all were answered (or
  /// unavailable), 1 otherwise.
  static func runQueries(_ options: Options, channel: FolderSearchChannel) async -> Int32 {
    let hostLabel: String
    switch options.host {
    case .local: hostLabel = "This Mac"
    case .ssh(let destination): hostLabel = destination
    }
    print(
      "folders: \(hostLabel), scope \(options.scope.rawValue), \(options.names.count) names, "
        + "\(options.repeats) repeats")
    var failures = 0
    var latencies: [Duration] = []
    var printedHeader = false
    var number = 0
    for round in 1...options.repeats {
      for (index, name) in options.names.enumerated() {
        guard !Task.isCancelled else { return 1 }
        number += 1
        let started = ContinuousClock.now
        await channel.search(name, scope: options.scope, on: options.host)
        guard let state = await waitForResult(channel) else {
          print("query \(number): name \(index + 1), round \(round): no result in time")
          failures += 1
          continue
        }
        let total = ContinuousClock.now - started
        if !printedHeader, let header = state.header {
          print(headerLine(header))
          if let open = state.openDuration { print("channel open: \(milliseconds(open)) ms") }
          printedHeader = true
        }
        let label = "query \(number): name \(index + 1) (\(name.count) characters), round \(round)"
        switch state.phase {
        case .answered(let answer):
          latencies.append(answer.latency)
          let status = answer.isLimited ? "limited" : "ok"
          print(
            "\(label): \(status), \(answer.paths.count) folders, dropped \(answer.droppedCount), "
              + "latency \(milliseconds(answer.latency)) ms, total \(milliseconds(total)) ms")
          if options.printsPaths {
            for path in answer.paths { print("  \(path)") }
          }
        case .unavailable(let reason):
          print("\(label): unavailable (\(reason.rawValue)), total \(milliseconds(total)) ms")
        case .failed(let failure):
          failures += 1
          print("\(label): failed (\(failure.code)), total \(milliseconds(total)) ms")
        case .refused(let issue):
          failures += 1
          print("\(label): refused (\(issue.code))")
        case .idle, .searching:
          failures += 1
          print("\(label): not searched")
        }
      } // End of loop over names
    } // End of loop over rounds
    if !latencies.isEmpty { print(summaryLine(latencies)) }
    return failures == 0 ? 0 : 1
  } // End of static func runQueries(_:channel:)

  /// Polls the channel every 5 ms until its phase is no longer `searching`, at most
  /// `queryLimit`; `nil` when it stays searching or the task is cancelled.
  static func waitForResult(_ channel: FolderSearchChannel) async -> FolderSearchState? {
    let deadline = ContinuousClock.now + queryLimit
    while ContinuousClock.now < deadline, !Task.isCancelled {
      let state = await channel.state
      if state.phase != .searching { return state }
      try? await Task.sleep(for: .milliseconds(5))
    } // End of loop polling the channel
    return nil
  }

  /// The header's facts, the home folder only as present or absent.
  static func headerLine(_ header: FolderSearchHeader) -> String {
    "header: home \(header.homeDirectory == nil ? "absent" : "present"), "
      + "mdfind \(header.hasSpotlight ? "yes" : "no"), "
      + "index home \(header.homeIndexing.rawValue), index disk \(header.diskIndexing.rawValue), "
      + "Desktop \(readability(header.desktop)), Documents \(readability(header.documents)), "
      + "Downloads \(readability(header.downloads))"
  }

  /// A readability as a word.
  static func readability(_ value: FolderSearchHeader.Readability) -> String {
    switch value {
    case .readable: return "readable"
    case .unreadable: return "unreadable"
    case .missing: return "missing"
    }
  }

  /// The latency summary: count, minimum, median and maximum.
  static func summaryLine(_ latencies: [Duration]) -> String {
    let sorted = latencies.sorted()
    let median = sorted[sorted.count / 2]
    return "summary: \(sorted.count) answers, latency min \(milliseconds(sorted[0])) ms, "
      + "median \(milliseconds(median)) ms, max \(milliseconds(sorted[sorted.count - 1])) ms"
  }

  /// `duration` in whole milliseconds.
  static func milliseconds(_ duration: Duration) -> Int {
    Int(duration / .milliseconds(1))
  }

  /// How many child processes this process has now (`proc_listpids` by parent id).
  static func childProcessCount() -> Int {
    var pids = [pid_t](repeating: 0, count: 256)
    let bytes = pids.withUnsafeMutableBytes { buffer in
      proc_listpids(
        UInt32(PROC_PPID_ONLY), UInt32(getpid()), buffer.baseAddress, Int32(buffer.count))
    }
    guard bytes > 0 else { return 0 }
    return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).filter { $0 > 0 }.count
  } // End of static func childProcessCount()
}
