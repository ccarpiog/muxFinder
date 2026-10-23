import CryptoKit
import Foundation

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
