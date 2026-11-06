import Foundation
import Testing

@testable import MuxFinderCore

/// The core parts of moving onto the terminal seam (PLAN.md D38, Phase I-12c3a): the refresh
/// engine's attachment checks turned off and on with the terminal choice (never asking the
/// index while off, its attributor then counting iTerm2's control-mode clients too), and the
/// attributor wired beside the index while on. Fakes only: a scripted prober, a fake index and a
/// fake process table; nothing contacts iTerm2.
@Suite("Terminal seam: refresh engine")
struct RefreshAttachmentChecksTests {
  /// Shorthand.
  typealias Support = RefreshTestSupport
  /// Shorthand.
  typealias Local = RefreshLocalAttachmentsTests

  /// An engine over This Mac (its session with Terminal's plain client and iTerm2's control
  /// client) with `index` and the built-ins' attributor over the fake table.
  static func engine(index: FakeAttachmentIndex) -> (RefreshCoordinator, HostConfig) {
    let mac = Support.thisMac()
    let prober = ScriptedProber()
    prober.setAnswer(.ok([Local.session(on: mac)]), for: mac.id)
    let attributor = LocalClientAttributor(
      table: Local.table(), definitions: LocalClientSupport.builtIns(),
      iTerm2JobServerDirectory: LocalClientSupport.jobServerFolder)
    let coordinator = RefreshCoordinator(
      hosts: Support.list([mac]), discovery: prober, attachmentIndex: index,
      localClients: attributor, clock: GatedAttachClock())
    return (coordinator, mac)
  } // End of static func engine(index:)

  /// Off before the popover opens (a plain choice): no check runs, explicitly asked or not,
  /// the check stays `notChecked`, and This Mac's attribution counts iTerm2's control-mode
  /// client too. Turned on (iTerm2 chosen again): a check runs at once while the popover shows,
  /// and the next attempt leaves iTerm2's control-mode client to the index.
  @Test func offAsksNothingAndOnChecksAgain() async {
    let index = FakeAttachmentIndex(.fail(.notRunning))
    let (coordinator, mac) = Self.engine(index: index)
    await coordinator.setAttachmentChecksEnabled(false)
    await coordinator.popoverDidOpen()
    #expect(
      await Support.waitUntil {
        await coordinator.state.snapshot(of: mac.id)?.isLive == true
      })
    let state = await coordinator.refreshOnce(includeAttachments: true)
    #expect(index.calls.isEmpty)
    #expect(state.attachmentCheck == .notChecked)
    #expect(
      state.snapshot(of: mac.id)?.sessions.first?.localAttachments
        == [Local.terminalAttachment, Local.iTerm2Attachment])

    await coordinator.setAttachmentChecksEnabled(true)
    #expect(await Support.waitUntil { index.calls.count == 1 })
    #expect(
      await Support.waitUntil {
        await coordinator.state.attachmentCheck.kind == "iTermNotRunning"
      })
    let again = await coordinator.refreshOnce()
    #expect(
      again.snapshot(of: mac.id)?.sessions.first?.localAttachments
        == [Local.terminalAttachment])
    await coordinator.stop()
  } // End of func offAsksNothingAndOnChecksAgain()

  /// Turning checks off while one is in flight retires it (its task cancelled, so it contacts
  /// iTerm2 no further; its result discarded), resumes a caller waiting for it, and forgets the
  /// last check and every attachment; turning off twice, or with no index, does nothing.
  @Test func offRetiresTheCheckInFlight() async {
    let index = FakeAttachmentIndex(.hang)
    let (coordinator, mac) = Self.engine(index: index)
    await coordinator.popoverDidOpen()
    #expect(await Support.waitUntil { index.calls.count == 1 })
    let waiter = Task { await coordinator.refreshOnce(includeAttachments: true) }
    #expect(await Support.waitUntil { index.calls.count >= 1 })
    await coordinator.setAttachmentChecksEnabled(false)
    #expect(await Support.waitUntil { index.cancelled >= 1 })
    let waited = await waiter.value
    #expect(waited.attachmentCheck == .notChecked)
    #expect(await coordinator.state.attachmentCheck == .notChecked)
    #expect(
      await coordinator.state.snapshot(of: mac.id)?.sessions.allSatisfy(\.attachments.isEmpty)
        == true)
    let calls = index.calls.count
    await coordinator.setAttachmentChecksEnabled(false)
    await coordinator.retryAll()
    #expect(
      await Support.waitUntil { await coordinator.state.snapshot(of: mac.id)?.isLive == true })
    #expect(index.calls.count == calls)
    await coordinator.stop()

    let plain = RefreshCoordinator(hosts: Support.list([mac]), discovery: ScriptedProber())
    await plain.setAttachmentChecksEnabled(false)
    #expect(await plain.state.attachmentCheck == .notChecked)
    await plain.stop()
  } // End of func offRetiresTheCheckInFlight()
} // End of struct RefreshAttachmentChecksTests

/// The plain backend's up-front refusal (PLAN.md D38, Phase I-12c3a; I-12c1's open question): a
/// session name holding `{`, `[` or `]` cannot be checked by D38's bound commands, so attach,
/// move here and create-and-attach refuse it before anything is written, opened, created or
/// run; a name renamed so between the listing and revalidation is refused after revalidation,
/// still before any request. iTerm2's backend is unchanged (its tests are untouched).
@Suite("Terminal seam: plain session names")
@MainActor
struct PlainTerminalBackendNameTests {
  /// Shorthand.
  typealias Support = PlainBackendSupport

  /// `Support.target()` with its session named `name`.
  static func target(named name: String) -> AttachTarget {
    var session = Support.session()
    session.name = name
    return AttachTarget(host: AttachTestSupport.host, session: session)
  }

  /// Attach and move here refuse each of the three characters with nothing run: no discovery,
  /// no request, no window, no tmux command; the failure's kind and sentence.
  @Test func attachAndMoveHereRefuseUpFront() async throws {
    for name in ["a{b", "[work]", "x]"] {
      let harness = try PlainBackendHarness()
      defer { harness.cleanUp() }
      let target = Self.target(named: name)
      let attach = await harness.backend.attach(target)
      #expect(attach.state == .failed(.unsupportedSessionName), "\(name)")
      let move = await harness.backend.moveHere(
        target, confirmation: .detachOtherClients(of: target.key))
      #expect(move.state == .failed(.unsupportedSessionName), "\(name)")
      #expect(harness.discovery.calls == 0)
      #expect(harness.windows.opens.isEmpty)
      #expect(harness.runner.requests.isEmpty)
      #expect(try harness.files().isEmpty)
      #expect(await harness.backend.state(of: target.key) == nil, "no state published")
      #expect(harness.log.all.isEmpty)
    } // End of loop over the refused names
    #expect(AttachFailure.unsupportedSessionName.kind == "unsupportedSessionName")
    #expect(AttachFailure.unsupportedSessionName.message.hasSuffix("."))
    #expect(PlainTerminalBackend.supportsName("fixture-session"))
    #expect(PlainTerminalBackend.supportsName("a#b,c}d"))
    #expect(!PlainTerminalBackend.supportsName("a[b"))
  } // End of func attachAndMoveHereRefuseUpFront()

  /// A session renamed with a bracket since the listing is refused after revalidation, before
  /// any request is written or window opened.
  @Test func aRenameSeenAtRevalidationIsRefused() async throws {
    var renamed = Support.session()
    renamed.name = "fixture[2]"
    let harness = try PlainBackendHarness(sessions: [renamed])
    defer { harness.cleanUp() }
    let result = await harness.backend.attach(Support.target())
    #expect(result.state == .failed(.unsupportedSessionName))
    #expect(harness.discovery.calls == 1)
    #expect(harness.windows.opens.isEmpty)
    #expect(try harness.files().isEmpty)
  }

  /// Create-and-attach refuses a valid name with a bracket before anything is created (a
  /// validation error, shown where New session shows creation's); an invalid name still gets
  /// creation's own check; a fine name is created as before.
  @Test func createAndAttachRefusesBeforeCreating() async throws {
    let harness = try PlainBackendHarness()
    defer { harness.cleanUp() }
    let host = AttachTestSupport.host
    let refused = await harness.backend.createAndAttach(
      NewSessionRequest(host: host, name: "  build{1}  ", workingDirectory: nil))
    #expect(refused.creationFailure == .invalidName(.sessionNameNotSupportedByTerminal))
    #expect(refused.created == nil && refused.attach == nil)
    #expect(harness.creator.requests.isEmpty)
    #expect(harness.windows.opens.isEmpty)
    let invalid = await harness.backend.createAndAttach(
      NewSessionRequest(host: host, name: "", workingDirectory: nil))
    #expect(invalid.creationFailure != .invalidName(.sessionNameNotSupportedByTerminal))
    #expect(ValidationError.sessionNameNotSupportedByTerminal.message.hasSuffix("."))
  } // End of func createAndAttachRefusesBeforeCreating()
} // End of struct PlainTerminalBackendNameTests

/// `muxfinder-probe attach`'s arguments and its *Unattended-run rules* 8 gate (PLAN.md D38,
/// Phase I-12c3a), over fake facts: nothing is read from LaunchServices or sent.
@Suite("Terminal seam: probe attach")
struct AttachCommandOptionsTests {
  /// Parses `arguments`, expecting options.
  static func options(_ arguments: [String]) throws -> AttachCommandOptions {
    guard case .attach(let options) = try AttachCommandOptions.parse(arguments) else {
      throw AttachCommandUsageError("not an attach")
    }
    return options
  }

  /// The usage error `arguments` give, or `nil`.
  static func usageError(_ arguments: [String]) -> String? {
    do {
      _ = try AttachCommandOptions.parse(arguments)
      return nil
    } catch {
      return error.message
    }
  }

  /// Today's options stay: no `--terminal` (or `iterm2`) is iTerm2's path with the host's
  /// override and profile; `--help` alone asks for the usage.
  @Test func todaysOptionsAndHelp() throws {
    let local = try Self.options(["--local", "--session", "$3"])
    #expect(local.terminal == .iterm2 && local.sessionID == TmuxSessionID("$3"))
    #expect(local.host.mode == .local && local.builtInDirectory == nil)
    let remote = try Self.options([
      "--ssh", "saturno-m4", "--session", "$1", "--tmux-path", "/opt/homebrew/bin/tmux",
      "--profile", "Work", "--terminal", "iterm2",
    ])
    #expect(remote.terminal == .iterm2 && remote.host.mode == .ssh)
    #expect(remote.host.sshDestination == "saturno-m4")
    #expect(remote.host.tmuxPathOverride == "/opt/homebrew/bin/tmux")
    #expect(remote.host.iTermProfileName == "Work")
    for help in [["--help"], ["-h"], ["help"]] {
      #expect(try AttachCommandOptions.parse(help) == .help)
    }
  } // End of func todaysOptionsAndHelp()

  /// A plain `--terminal` with its definition folders.
  @Test func aPlainTerminalWithFolders() throws {
    let parsed = try Self.options([
      "--local", "--session", "$2", "--terminal", "terminal", "--builtin-directory", "/b",
      "--user-directory", "/u",
    ])
    #expect(parsed.terminal == .plain(definitionID: "terminal"))
    #expect(parsed.builtInDirectory == "/b" && parsed.userDirectory == "/u")
  }

  /// Every refusal: no host, both hosts, no or a bad session, a repeated option, a missing
  /// value, an unknown option, a terminal that is no id, folders without a plain terminal, an
  /// iTerm2 profile with one, and `--help` with anything else.
  @Test func refusals() {
    let cases: [[String]] = [
      ["--session", "$1"],
      ["--local", "--ssh", "host", "--session", "$1"],
      ["--ssh", "a", "--ssh", "b", "--session", "$1"],
      ["--local"],
      ["--local", "--session", "3"],
      ["--local", "--session", "$1", "--session", "$2"],
      ["--local", "--session"],
      ["--local", "--session", "$1", "--terminal", ""],
      ["--local", "--session", "$1", "--frobnicate"],
      ["--local", "--session", "$1", "--terminal", "Ghostty!"],
      ["--local", "--session", "$1", "--builtin-directory", "/b"],
      ["--local", "--session", "$1", "--terminal", "iterm2", "--user-directory", "/u"],
      ["--local", "--session", "$1", "--terminal", "ghostty", "--profile", "Work"],
      ["--help", "--local"],
    ]
    for arguments in cases {
      #expect(Self.usageError(arguments) != nil, "\(arguments)")
    }
  } // End of func refusals()

  /// Facts for the gate.
  static func facts(
    installed: Bool = true,
    check: TerminalAppFacts.VersionCheck = .meets,
    running: Bool = true,
    automation: TerminalAppFacts.Automation = .permission(.granted, status: 0)
  ) -> TerminalAppFacts {
    TerminalAppFacts(
      installed: installed, path: installed ? "/Applications/Fixture.app" : nil,
      version: "9.0", versionCheck: installed ? check : .notInstalled, running: running,
      automation: automation)
  }

  /// The gate goes ahead only for an installed, recent enough, running app whose permission
  /// reads granted (an `exec` definition needs none, but must still be running); every other
  /// case is refused with its reason.
  @Test func theGateFollowsRuleEight() throws {
    let terminal = try PlainBackendSupport.terminal().definition
    let exec = try TerminalDefinition.decode(
      TerminalDefinitionTestSupport.data(TerminalDefinitionTestSupport.execObject()))
    #expect(PlainRunGate.check(terminal, facts: Self.facts()) == nil)
    #expect(
      PlainRunGate.check(exec, facts: Self.facts(automation: .notNeeded)) == nil)
    let refusals: [(TerminalDefinition, TerminalAppFacts, PlainRunGate.Refusal)] = [
      (terminal, Self.facts(installed: false), .notInstalled),
      (terminal, Self.facts(check: .tooOld), .versionNotUsable(.tooOld)),
      (terminal, Self.facts(check: .unknown), .versionNotUsable(.unknown)),
      (terminal, Self.facts(running: false), .notRunning),
      (exec, Self.facts(running: false, automation: .notNeeded), .notRunning),
      (
        terminal, Self.facts(automation: .permission(.denied, status: -1743)),
        .permissionNotGranted(.denied)
      ),
      (
        terminal, Self.facts(automation: .permission(.notDetermined, status: -1744)),
        .permissionNotGranted(.notDetermined)
      ),
      (
        terminal, Self.facts(automation: .permission(.other(status: -1), status: -1)),
        .permissionNotGranted(.other(status: -1))
      ),
      (terminal, Self.facts(automation: .notNeeded), .permissionNotGranted(.notDetermined)),
    ]
    for (definition, facts, expected) in refusals {
      let refusal = PlainRunGate.check(definition, facts: facts)
      #expect(refusal == expected, "\(expected.kind)")
      #expect(refusal?.message.isEmpty == false)
    }
  } // End of func theGateFollowsRuleEight()
} // End of struct AttachCommandOptionsTests

/// The seam's read-only question behind the model's cross-terminal refusal (PLAN.md D38 *Onto
/// the seam (I-12c3a)*, review fix 1): whether a backend holds a launch of a session that may
/// still attach it. Both backends answer from memory and a peek at the helper's result: nothing
/// is settled, taken, written or sent (iTerm2 is not asked).
@Suite("Terminal seam: unresolved launches")
struct UnresolvedLaunchQueryTests {
  /// The plain backend: none before any launch; one whose helper took the request and whose
  /// client was never confirmed is unresolved; once its helper's result exists it is not, the
  /// result left in place and the launch still pending inside the backend.
  @MainActor @Test func thePlainBackendAnswersReadOnly() async throws {
    let harness = try PlainBackendHarness()
    defer { harness.cleanUp() }
    harness.report = nil
    let key = PlainBackendSupport.target().key
    #expect(await !harness.backend.hasUnresolvedLaunch(for: key))
    let first = await harness.backend.attach(PlainBackendSupport.target())
    #expect(first.failure == .timedOut)
    #expect(await harness.backend.hasUnresolvedLaunch(for: key))
    try harness.store.writeResult(
      PlainBackendSupport.result(for: first.launchID, failure: .sessionGone))
    #expect(await !harness.backend.hasUnresolvedLaunch(for: key))
    #expect(await harness.backend.unsettledLaunchCount(for: key) == 1, "nothing settled")
    #expect(try harness.store.peekResult(first.launchID) != nil, "peeked, never taken")
  } // End of func thePlainBackendAnswersReadOnly()

  /// iTerm2's coordinator: a launch whose `CreateTab` is held is unresolved while it runs, and
  /// after all its callers were cancelled (its helper took the request) it stays unresolved;
  /// once its helper's result exists it is not. Asking sends iTerm2 nothing and settles
  /// nothing; the result is left for the coordinator to take.
  @Test func theCoordinatorAnswersReadOnly() async throws {
    let harness = MoveHereCoordinatorTests.settlementHarness(.helperResult)
    let coordinator = harness.coordinator
    let target = harness.target
    #expect(await !coordinator.hasUnresolvedLaunch(for: target.key))
    let attach = Task { await coordinator.attach(target) }
    try await waitUntil("the attach's CreateTab is held") { harness.iTerm2.isHoldingCreateTab }
    #expect(await coordinator.hasUnresolvedLaunch(for: target.key), "a running launch")
    attach.cancel()
    try await waitUntil("the attach winds down") {
      await coordinator.cancelledWaiterCount(for: target.key) == 1
    }
    harness.iTerm2.releaseCreateTab()
    let attached = await attach.value
    #expect(attached.failure == .cancelled)
    #expect(await coordinator.unsettledLaunchCount(for: target.key) == 1)
    let calls = await harness.fake.calls
    #expect(await coordinator.hasUnresolvedLaunch(for: target.key))
    let request = try #require(harness.store.snapshot.written.first)
    harness.store.update {
      $0.results[attached.launchID] = AttachTestSupport.result(for: request, failure: .sessionGone)
    }
    #expect(await !coordinator.hasUnresolvedLaunch(for: target.key))
    #expect(await harness.fake.calls == calls, "iTerm2 is not asked")
    #expect(await coordinator.unsettledLaunchCount(for: target.key) == 1, "nothing settled")
    #expect(harness.store.snapshot.results[attached.launchID] != nil, "peeked, never taken")
  } // End of func theCoordinatorAnswersReadOnly()
} // End of struct UnresolvedLaunchQueryTests

/// A launch store over a real one that runs `onWrite` right after each request is written: a
/// test changes the app's facts there, between the plain backend's write and its open.
final class WriteHookLaunchStore: PlainLaunchRequestStore {
  /// The real store.
  let base: LaunchStore
  /// Runs after each write.
  let onWrite: @Sendable () -> Void

  /// A store over `base` running `onWrite` after each write.
  init(base: LaunchStore, onWrite: @escaping @Sendable () -> Void) {
    self.base = base
    self.onWrite = onWrite
  }

  /// Writes through `base`, then runs the hook.
  func writeRequest(_ request: LaunchRequest) throws(LaunchStoreError) {
    try base.writeRequest(request)
    onWrite()
  }

  /// `base`'s.
  func discardRequest(_ id: LaunchToken) throws(LaunchStoreError) -> Bool {
    try base.discardRequest(id)
  }

  /// `base`'s.
  func takeResult(_ id: LaunchToken) throws(LaunchStoreError) -> LaunchResult? {
    try base.takeResult(id)
  }

  /// `base`'s.
  func peekResult(_ id: LaunchToken) throws(LaunchStoreError) -> LaunchResult? {
    try base.peekResult(id)
  }

  /// `base`'s.
  func sweep() throws(LaunchStoreError) -> Int {
    try base.sweep()
  }

  /// `base`'s.
  func peekReport(_ id: LaunchToken) throws(LaunchStoreError) -> PlainLaunchReport? {
    try base.peekReport(id)
  }
} // End of class WriteHookLaunchStore

/// The probe's unattended gate at the side-effect boundary (PLAN.md D38 *Onto the seam
/// (I-12c3a)*, review fix 3): the plain backend over the real window layer with the
/// `unattended` policy, over fake facts, a fake AppleScript runner and a fake spawner. The
/// early check (`PlainRunGate.check`, as the probe makes it before discovery) passes; then the
/// app stops running, or its permission stops reading granted, before the request write or
/// between the write and the open: no Apple event, no compile, no spawn, the request never
/// written or withdrawn, and the typed refusal the probe exits 2 with.
@Suite("Terminal seam: unattended run policy")
@MainActor
struct PlainRunPolicyTests {
  /// One unattended run's parts.
  struct Run {
    /// The definition.
    let loaded: LoadedTerminalDefinition
    /// The app's facts.
    let inspector: FakeTerminalAppInspector
    /// AppleScript.
    let runner: FakeAppleScriptRunner
    /// `exec` programs.
    let spawner: FakeTerminalProcessSpawner
    /// The real launch files.
    let store: LaunchStore
    /// The private folder holding them.
    let root: URL
    /// The backend.
    let backend: PlainTerminalBackend

    /// The files left in the launch folder.
    func files() throws -> [String] { try LaunchTestSupport.names(in: store.directory) }

    /// Removes the private folder.
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
  } // End of struct Run

  /// A run of `loaded` whose app answers `version`, running, its permission granted; `onWrite`
  /// runs right after the request is written (it gets the inspector).
  static func run(
    _ loaded: LoadedTerminalDefinition,
    version: String,
    onWrite: (@Sendable (FakeTerminalAppInspector) -> Void)? = nil
  ) throws -> Run {
    let root = try TestSupport.makeTemporaryDirectory()
    let clock = ManualAttachClock()
    let store = LaunchStore(directory: root.appending(path: "launch"), now: { clock.date() })
    try store.prepareDirectory()
    let inspector = FakeTerminalAppInspector(
      snapshot: TerminalAppSnapshot(
        url: URL(fileURLWithPath: "/Applications/Fixture.app"), version: version, running: true))
    let runner = FakeAppleScriptRunner()
    let spawner = FakeTerminalProcessSpawner()
    let windows = PlainTerminalWindows(
      runner: runner, inspector: inspector, spawner: spawner,
      activator: FakeTerminalAppActivator(), environment: [:], policy: .unattended)
    let hooked = WriteHookLaunchStore(base: store) { onWrite?(inspector) }
    let backend = PlainTerminalBackend(
      loaded: loaded, windows: windows, helperPath: AttachTestSupport.helper, store: hooked,
      discovery: FakeDiscovery(.ok([PlainBackendSupport.session()])), clock: clock)
    return Run(
      loaded: loaded, inspector: inspector, runner: runner, spawner: spawner, store: store,
      root: root, backend: backend)
  } // End of static func run(_:version:onWrite:)

  /// The facts the probe's early check reads.
  static func facts(_ run: Run) -> TerminalAppFacts {
    TerminalAppFacts.read(for: run.loaded.definition, inspector: run.inspector)
  }

  /// Terminal quits after the early check: the backend's check right before the write refuses;
  /// nothing is written, compiled, sent or spawned.
  @Test func anAppThatQuitIsRefusedBeforeTheWrite() async throws {
    let run = try Self.run(try PlainBackendSupport.terminal(), version: "2.14")
    defer { run.cleanUp() }
    #expect(PlainRunGate.check(run.loaded.definition, facts: Self.facts(run)) == nil)
    run.inspector.setSnapshot(
      TerminalAppSnapshot(
        url: URL(fileURLWithPath: "/Applications/Fixture.app"), version: "2.14", running: false))
    let result = await run.backend.attach(PlainBackendSupport.target())
    #expect(PlainRunGate.refusal(of: result) == .notRunning)
    #expect(result.failure?.kind == "terminalWindow")
    #expect(result.failure?.detail == "unattendedRunRefused")
    #expect(try run.files().isEmpty, "no request written")
    #expect(run.runner.compiled.isEmpty && run.runner.calls.isEmpty)
    #expect(run.spawner.requests.isEmpty)
  } // End of func anAppThatQuitIsRefusedBeforeTheWrite()

  /// Terminal's permission stops reading granted between the write and the open: the window
  /// layer refuses before compiling or sending anything, and the request is withdrawn.
  @Test func aPermissionChangedAfterTheWriteIsRefusedBeforeTheEvent() async throws {
    let run = try Self.run(try PlainBackendSupport.terminal(), version: "2.14") { inspector in
      inspector.setStatus(AutomationPermission.notDeterminedStatus)
    }
    defer { run.cleanUp() }
    #expect(PlainRunGate.check(run.loaded.definition, facts: Self.facts(run)) == nil)
    let result = await run.backend.attach(PlainBackendSupport.target())
    #expect(PlainRunGate.refusal(of: result) == .permissionNotGranted(.notDetermined))
    #expect(try run.files().isEmpty, "the request was withdrawn")
    #expect(run.runner.compiled.isEmpty && run.runner.calls.isEmpty, "no Apple event")
    #expect(run.spawner.requests.isEmpty)
  } // End of func aPermissionChangedAfterTheWriteIsRefusedBeforeTheEvent()

  /// An `exec` definition's app quits between the write and the open: no spawn (which would
  /// launch it), the request withdrawn.
  @Test func anExecAppThatQuitAfterTheWriteIsNotSpawned() async throws {
    let exec = LoadedTerminalDefinition(
      definition: try TerminalDefinition.decode(
        TerminalDefinitionTestSupport.data(TerminalDefinitionTestSupport.execObject())),
      source: .user, fileName: "sample-exec.json", script: nil)
    let run = try Self.run(exec, version: "20250101") { inspector in
      inspector.setSnapshot(
        TerminalAppSnapshot(
          url: URL(fileURLWithPath: "/Applications/Fixture.app"), version: "20250101",
          running: false))
    }
    defer { run.cleanUp() }
    #expect(PlainRunGate.check(exec.definition, facts: Self.facts(run)) == nil)
    let result = await run.backend.attach(PlainBackendSupport.target())
    #expect(PlainRunGate.refusal(of: result) == .notRunning)
    #expect(try run.files().isEmpty, "the request was withdrawn")
    #expect(run.spawner.requests.isEmpty, "nothing launched")
  } // End of func anExecAppThatQuitAfterTheWriteIsNotSpawned()

  /// The app's policy (`interactive`, the default) is unchanged: no extra facts read for the
  /// policy, and a not-running app is still opened (launching it is the open's purpose).
  @Test func theInteractivePolicyAddsNothing() async throws {
    let inspector = FakeTerminalAppInspector(
      snapshot: TerminalAppSnapshot(
        url: URL(fileURLWithPath: "/Applications/Fixture.app"), version: "2.14", running: false))
    let runner = FakeAppleScriptRunner()
    let windows = PlainTerminalWindows(
      runner: runner, inspector: inspector, spawner: FakeTerminalProcessSpawner(),
      activator: FakeTerminalAppActivator(), environment: [:])
    #expect(windows.policy == .interactive)
    let loaded = try PlainBackendSupport.terminal()
    try windows.checkRunPolicy(for: loaded)
    #expect(inspector.snapshotReads.isEmpty, "nothing read for the policy")
    _ = try windows.open(loaded, helperPath: AttachTestSupport.helper.path, token: LaunchToken())
    #expect(runner.calls.map(\.handler) == [.open])
  } // End of func theInteractivePolicyAddsNothing()
} // End of struct PlainRunPolicyTests
