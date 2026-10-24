import CryptoKit
import Foundation
import os

/// A digest of the argv `muxfinder-launch` received, written in test mode so Phase 4b can check
/// exactly how iTerm2 split the tab's `Command` property (PLAN.md D14).
///
/// Test mode is on when the helper's environment has `MUXFINDER_LAUNCH_TEST_MODE=1` (direct
/// runs, hermetic tests) or when the launch directory holds a regular file named
/// `LaunchStore.testModeMarkerName` (`test-mode`) owned by the user; that marker is how an e2e
/// run enables it for helpers iTerm2 starts, whose environment muxFinder does not control. The
/// e2e run creates the marker before opening the tab and removes it during cleanup; the sweep
/// leaves it alone.
///
/// The digest is written before argv is parsed, so a wrongly split command line still leaves
/// one, as `argv-<helper pid>.json` (0600) in the launch directory. It holds the argument
/// count and, per argument (argv[0] included), its byte length and SHA-256. No raw argument is
/// stored except a launch id, which is safe: `launchID` is the first argument after argv[0]
/// that is a canonical launch id. Right before it starts its attach child (tmux locally, ssh for
/// a remote host, or the plain ssh of `ssh-setup`, PLAN.md D24), the helper writes the digest
/// again with `attachChild`: that child's argv digested the same way, and whether it detaches
/// the session's other clients (`-d`, a move here, PLAN.md D21; never for ssh setup).
///
/// In `attach` mode it is written again as the launch goes on (PLAN.md Phase 13a): with
/// `attachChildProcessID` right after the attach child was spawned, so a harness can signal
/// exactly that process, and with one `tabRestores` record after each launch tab restore
/// (after the attach child ended, and just before the helper exits).
public struct LaunchArgvDigest: Sendable, Hashable, Codable {
  /// One argument's digest.
  public struct Argument: Sendable, Hashable, Codable {
    /// The argument's length in bytes (UTF-8, without the terminating NUL).
    public var byteLength: Int
    /// The lowercase hexadecimal SHA-256 of the argument's bytes.
    public var sha256: String

    /// Digests `bytes`.
    public init(bytes: [UInt8]) {
      byteLength = bytes.count
      sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
  }

  /// The attach child the helper started (PLAN.md D21): the argv it spawned, digested the same
  /// way, and whether that argv asks tmux to detach the session's other clients. Recorded just
  /// before the child starts, so a check, a test launch delay or a refused request that ends
  /// the launch first leaves none.
  public struct AttachChild: Sendable, Hashable, Codable {
    /// Whether the child attaches with `attach-session -d` (a move here): the local tmux argv
    /// holds `-d`, or the ssh command runs `RemoteLaunch.moveHereScript`.
    public var detachesOtherClients: Bool
    /// The child's `argc`.
    public var argumentCount: Int
    /// One entry per argument, argv[0] (the executable's path: tmux, or `/usr/bin/ssh`; for the
    /// login shell, `-<name>`) first.
    public var arguments: [Argument]
    /// `true` when the child is the login shell the `profile` mode starts instead of tmux
    /// (PLAN.md D26; in test mode it is recorded but never started); absent otherwise.
    public var startsLoginShell: Bool?

    /// Digests the child `executable` (its argv[0]) with `arguments` (argv after argv[0]).
    public init(
      executable: String,
      arguments: [String],
      detachesOtherClients: Bool,
      startsLoginShell: Bool = false
    ) {
      self.detachesOtherClients = detachesOtherClients
      let argv = [executable] + arguments
      argumentCount = argv.count
      self.arguments = argv.map { Argument(bytes: Array($0.utf8)) }
      self.startsLoginShell = startsLoginShell ? true : nil
    } // End of init(executable:arguments:detachesOtherClients:startsLoginShell:)
  } // End of struct AttachChild

  /// One launch tab restore of a finished attach (PLAN.md Phase 13 item 4): the `Disinter`
  /// sequence (unless the request's test switch suppressed it) and a status report request,
  /// and how the terminal answered. It holds times and kinds only, never terminal content.
  public struct TabRestoreRecord: Sendable, Hashable, Codable {
    /// When in the helper's end the restore ran.
    public enum Stage: String, Sendable, Hashable, Codable {
      /// Right after the attach child ended and the result was written (a line feed comes
      /// first, `LaunchHelper.tmuxModeEndSequence`).
      case afterChild
      /// Right after `afterChild`, only when that went unanswered: iTerm2 was still parsing the
      /// tab as a tmux gateway, and the line feed ended that (PLAN.md D29).
      case afterTmuxModeEnd
      /// Just before the helper exits, after the explanation, the wait and the hold.
      case beforeExit
    }

    /// When in the helper's end the restore ran.
    public var stage: Stage
    /// Whether the `Disinter` sequence was written before the status report request (`false`
    /// only for a request with `testSuppressDisinter` in test mode).
    public var wroteDisinter: Bool
    /// When the helper asked the terminal (just before it discarded typed input and wrote).
    public var requestedAt: Date
    /// When the wait ended (the answer read, the time up, or nothing to wait for).
    public var endedAt: Date
    /// `TerminalStatusReport.kind`: `answered`, `unanswered` or `unavailable`.
    public var outcome: String
    /// For an answer, how long after the request it came, in whole milliseconds.
    public var answeredAfterMilliseconds: Int?

    /// Creates a record of a restore whose status report ended with `report`.
    public init(
      stage: Stage,
      wroteDisinter: Bool,
      requestedAt: Date,
      endedAt: Date,
      report: TerminalStatusReport
    ) {
      self.stage = stage
      self.wroteDisinter = wroteDisinter
      self.requestedAt = requestedAt
      self.endedAt = endedAt
      outcome = report.kind
      if case .answered(let after) = report {
        answeredAfterMilliseconds = Int(after / .milliseconds(1))
      }
    } // End of init(stage:wroteDisinter:requestedAt:endedAt:report:)
  } // End of struct TabRestoreRecord

  /// The format version this build writes.
  public static let currentFormatVersion = 1
  /// The prefix of digest file names.
  static let fileNamePrefix = "argv-"
  /// The suffix of digest file names.
  static let fileNameSuffix = ".json"

  /// The file format version.
  public var formatVersion: Int
  /// The helper's process id.
  public var helperPID: Int32
  /// When the digest was made.
  public var recordedAt: Date
  /// `argc`.
  public var argumentCount: Int
  /// One entry per argument, argv[0] first.
  public var arguments: [Argument]
  /// The first canonical launch id among the arguments after argv[0], if any.
  public var launchID: LaunchToken?
  /// The attach child, once the helper is about to start it (the digest file is then written
  /// again with it); absent before, and for a launch that ended without one.
  public var attachChild: AttachChild?
  /// The attach child's process id, once it was spawned (`attach` mode only); absent before,
  /// and for a launch that started none. The child is the helper's own, unreaped until it ends.
  public var attachChildProcessID: Int32?
  /// The launch tab restores so far (`attach` mode only, after the attach child ran), in order;
  /// absent before the first.
  public var tabRestores: [TabRestoreRecord]?

  /// Digests `argv` (raw bytes, argv[0] first).
  public init(argv: [[UInt8]], helperPID: Int32, recordedAt: Date) {
    formatVersion = Self.currentFormatVersion
    self.helperPID = helperPID
    self.recordedAt = recordedAt
    argumentCount = argv.count
    arguments = argv.map(Argument.init(bytes:))
    launchID =
      argv.dropFirst().lazy.compactMap { LaunchToken(String(decoding: $0, as: UTF8.self)) }
      .first
  }

  /// The file name for a helper with this pid.
  public static func fileName(helperPID: Int32) -> String {
    "\(fileNamePrefix)\(helperPID)\(fileNameSuffix)"
  }

  /// Whether `name` is a digest file name.
  static func isFileName(_ name: String) -> Bool {
    name.hasPrefix(fileNamePrefix) && name.hasSuffix(fileNameSuffix)
  }
}

/// The helper's argv digest while an `attach` launch goes on in test mode (PLAN.md Phase 13a):
/// keeps the latest digest and writes it again, whole, after every change, so the file always
/// holds everything recorded so far. Changes may come from the thread that supervises the
/// attach child (its process id) and from the helper's own task; the lock keeps them, and the
/// writes, in order.
final class LaunchDigestRecorder: Sendable {
  /// Where the digest is written.
  private let store: LaunchStore
  /// The latest digest.
  private let digest: OSAllocatedUnfairLock<LaunchArgvDigest>

  /// Starts from `digest`, already written.
  init(store: LaunchStore, digest: LaunchArgvDigest) {
    self.store = store
    self.digest = OSAllocatedUnfairLock(initialState: digest)
  }

  /// The latest digest.
  var current: LaunchArgvDigest { digest.withLock { $0 } }

  /// Applies `change` and writes the digest again; returns the write's error, if any (the
  /// change is kept either way).
  @discardableResult
  func update(_ change: @Sendable (inout LaunchArgvDigest) -> Void) -> LaunchStoreError? {
    let store = store
    return digest.withLock { latest -> LaunchStoreError? in
      change(&latest)
      do throws(LaunchStoreError) {
        try store.writeArgvDigest(latest)
        return nil
      } catch {
        return error
      }
    }
  } // End of func update(_:)
} // End of class LaunchDigestRecorder
