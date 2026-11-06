import Foundation
import MuxFinderCore

/// What the Persistent profiles tab shows with a plain terminal chosen (PLAN.md D38, Phase
/// I-12d1; requirement 11). muxFinder never writes another terminal's settings: per saved host
/// whose persistent profile is on, it shows the command for that terminal's own "run command"
/// setting, with a Copy button, and where to paste it. The iTerm2 part collapses to one line:
/// "Remove profiles" stays offered while muxFinder's own `DynamicProfiles/muxFinder.json` is
/// installed (the user's explicit action, as before); "Install profiles" is not offered. A pure
/// value, so every rule is tested without SwiftUI.
///
/// The command is D3's extension (`TerminalCommandText`): `exec '<helper path>' 'profile-plain'
/// '<host id>'`, each word POSIX single-quoted, the helper path the bundle's
/// (`LaunchHelperPath`), the host id in the canonical lowercase form. A terminal runs it through
/// the user's shell (Terminal's "Run inside shell", Ghostty's `/bin/sh -c`); `exec` leaves no
/// shell behind it, and the helper's `profile-plain` mode falls back to the login shell on any
/// failure (PLAN.md D26, D38).
public struct PersistentWorkContent: Sendable, Hashable {
  /// One host's command.
  public struct Line: Sendable, Hashable, Identifiable {
    /// The host's id.
    public var id: UUID
    /// The host's display name.
    public var hostName: String
    /// The command to paste.
    public var command: String

    /// A line of these values.
    public init(id: UUID, hostName: String, command: String) {
      self.id = id
      self.hostName = hostName
      self.command = command
    }
  }

  /// The section's title: "Persistent work in Terminal".
  public var title: String
  /// What the commands are for.
  public var introduction: String
  /// Where to paste a command in the chosen terminal.
  public var whereToPaste: String
  /// One line per saved host whose persistent profile is on, in host-list order.
  public var lines: [Line]
  /// Why there is no line, when there is none for a reason other than `problem`.
  public var emptyNote: String?
  /// Why no command can be built (the helper's path), if anything.
  public var problem: String?
  /// The iTerm2 part's one line.
  public var iTerm2Line: String
  /// Whether "Remove profiles" works: muxFinder's own file is installed in iTerm2.
  public var canRemoveITerm2Profiles: Bool
  /// Whether a removal or a check runs.
  public var isRunning: Bool
  /// The last removal's (or automatic update's) line, if any.
  public var resultText: String?
  /// Whether that line reports a failure.
  public var resultIsProblem: Bool

  /// Why there is no command while the host list is not saved or not usable.
  public static let listNotSavedNote =
    "Commands come from the saved host list. Save the host list in the Hosts tab first."
  /// Why there is no command while no saved host has its persistent profile on.
  public static let noHostNote =
    "None: no saved host has its persistent profile turned on. Turn it on for a host in the "
    + "Hosts tab and save it."

  /// The content for the terminal of `wording`, the saved `hosts` (`isListSaved`: they are the
  /// saved, usable list), the bundle's `helper` path as last found (`nil`: not looked for), the
  /// iTerm2 file's `profileStatus` (`nil`: not checked yet), whether an operation `isRunning`,
  /// and the last `result`.
  public init(
    wording: TerminalWording,
    hosts: HostList,
    isListSaved: Bool,
    helper: Result<LaunchHelperPath, LaunchHelperPathError>?,
    profileStatus: PersistentProfileStatus?,
    isRunning: Bool,
    result: PersistentProfileResult?
  ) {
    let name = wording.name
    title = "Persistent work in \(name)"
    introduction =
      "muxFinder never changes \(name)'s settings. Put a host's command in \(name)'s own "
      + "setting for the command a new window runs: windows that run it work inside that "
      + "host's tmux session, so work started there keeps running after the window closes."
    whereToPaste = Self.whereToPaste(for: wording)
    let opted = isListSaved ? hosts.hosts.filter(\.persistentProfileEnabled) : []
    var lines: [Line] = []
    var problem: String?
    switch helper ?? .failure(.notFound) {
    case .failure(let error):
      problem = error.message
    case .success(let path):
      do throws(TerminalCommandTextError) {
        for host in opted {
          lines.append(
            Line(
              id: host.id, hostName: host.displayName,
              command: try Self.command(helperPath: path.path, hostID: host.id)))
        }
      } catch {
        lines = []
        problem = error.message
      }
    } // End of switch over the helper's path
    self.lines = lines
    self.problem = problem
    if !isListSaved {
      emptyNote = Self.listNotSavedNote
    } else if opted.isEmpty {
      emptyNote = Self.noHostNote
    } else {
      emptyNote = nil
    }
    let isInstalled = profileStatus?.isInstalled == true
    switch profileStatus {
    case nil:
      iTerm2Line = "Checking muxFinder's profiles in iTerm2…"
    case .some where isInstalled:
      iTerm2Line = "Used only with iTerm2. muxFinder's profiles are still installed there."
    case .some:
      iTerm2Line = "Used only with iTerm2."
    }
    canRemoveITerm2Profiles = !isRunning && isInstalled
    self.isRunning = isRunning
    resultText = result?.text
    resultIsProblem = result?.isProblem ?? false
  } // End of init(wording:hosts:isListSaved:helper:profileStatus:isRunning:result:)

  /// The persistent work command for the host `hostID` with the helper at `helperPath`: `exec
  /// '<helper path>' 'profile-plain' '<host id>'` (`TerminalCommandText`, D3's extension).
  public static func command(
    helperPath: String,
    hostID: UUID
  ) throws(TerminalCommandTextError) -> String {
    try TerminalCommandText.shellCommand(
      helperPath: helperPath,
      arguments: [ProfileLaunch.plainHelperMode, LaunchToken(uuid: hostID).rawValue])
  }

  /// Where to paste a command in the terminal of `wording`: Terminal's profile setting,
  /// Ghostty's config file, or a generic sentence for any other terminal.
  public static func whereToPaste(for wording: TerminalWording) -> String {
    switch wording.kind {
    case .terminalApp:
      return "In Terminal, choose Settings › Profiles › Shell › Run command, paste the command "
        + "there, and keep “Run inside shell” on."
    case .ghostty:
      return "In Ghostty's config file, write “command = ” followed by the command, then reload "
        + "Ghostty's config."
    case .iTerm2, .other:
      return "Paste the command in \(wording.name)'s own setting for the command a new window "
        + "runs."
    }
  } // End of static func whereToPaste(for:)
} // End of struct PersistentWorkContent
