import Foundation
import Testing
import os

@testable import MuxFinderCore
@testable import MuxFinderUI

/// An iTerm2 integration that records every call and answers none (as if iTerm2 did not run):
/// the never-contact proof's witness (PLAN.md D38, Phase I-12c3a). Nothing is ever sent.
actor CountingITerm2: ITerm2Integration {
  /// The names of the calls so far, in order.
  private(set) var calls: [String] = []

  /// Records `name`.
  private func record(_ name: String) { calls.append(name) }

  /// Records the call; not running.
  func isRunning() async -> Bool {
    record("isRunning")
    return false
  }

  /// Records the call; not running.
  func status() async -> ITerm2Status {
    record("status")
    return ITerm2Status(
      isRunning: false, socketPresent: false, isConnected: false, error: .notRunning)
  }

  /// Records the call; fails.
  func ensureRunning() async throws {
    record("ensureRunning")
    throw ITerm2Error.notRunning
  }

  /// Records the call; fails.
  func listSessions() async throws -> ITerm2API.ListSessionsResponse {
    record("listSessions")
    throw ITerm2Error.notRunning
  }

  /// Records the call; fails.
  func createTab(_ request: ITerm2API.CreateTabRequest) async throws
    -> ITerm2API.CreateTabResponse
  {
    record("createTab")
    throw ITerm2Error.notRunning
  }

  /// Records the call; fails.
  func listTmuxConnections() async throws -> [ITerm2API.TmuxConnection] {
    record("listTmuxConnections")
    throw ITerm2Error.notRunning
  }

  /// Records the call; fails.
  func sendTmuxCommand(_ command: String, connectionID: String) async throws -> String {
    record("sendTmuxCommand")
    throw ITerm2Error.notRunning
  }

  /// Records the call; fails.
  func sendTmuxCommand(
    _ command: String, connectionID: String, ownedBy owningSessionID: String
  ) async throws -> String {
    record("sendTmuxCommandOwned")
    throw ITerm2Error.notRunning
  }

  /// Records the call; fails.
  func activate(_ request: ITerm2API.ActivateRequest) async throws {
    record("activate")
    throw ITerm2Error.notRunning
  }

  /// Records the call; fails.
  func activateFirstTab(
    ofTmuxConnection connectionID: String, ownedBy owningSessionID: String,
    options: ITerm2API.ActivateRequest
  ) async throws -> String? {
    record("activateFirstTab")
    throw ITerm2Error.notRunning
  }

  /// Records the call; fails.
  func setBuried(_ buried: Bool, sessionID: String) async throws {
    record("setBuried")
    throw ITerm2Error.notRunning
  }

  /// Records the call; fails.
  func buryLaunchTab(sessionID: String, ifOwnsTmuxConnection connectionID: String) async throws {
    record("buryLaunchTab")
    throw ITerm2Error.notRunning
  }

  /// Records the call; fails.
  func listProfiles(properties: [String], guids: [String]) async throws -> [ITerm2API.Profile] {
    record("listProfiles")
    throw ITerm2Error.notRunning
  }

  /// Records the call; fails.
  func close(_ request: ITerm2API.CloseRequest) async throws -> ITerm2API.CloseResponse {
    record("close")
    throw ITerm2Error.notRunning
  }

  /// Records the call.
  func disconnect() async {
    record("disconnect")
  }
} // End of actor CountingITerm2

/// A local client attributor that records each call's `indexInUse` and reports one attachment
/// (in `app`) for every session of This Mac; an SSH host gets none.
final class RecordingAttributor: LocalClientAttributing {
  /// The `indexInUse` of every call, in order.
  private let state = OSAllocatedUnfairLock<[Bool]>(initialState: [])
  /// The attachment reported for every session of This Mac.
  let attachment: LocalAttachment

  /// An attributor reporting `attachment`.
  init(attachment: LocalAttachment) {
    self.attachment = attachment
  }

  /// Records `indexInUse` and reports `attachment` for every session of This Mac.
  func localAttachments(
    of sessions: [DiscoveredSession],
    on host: HostConfig,
    indexInUse: Bool
  ) -> [SessionKey: [LocalAttachment]] {
    guard host.mode == .local else { return [:] }
    state.withLock { $0.append(indexInUse) }
    return Dictionary(uniqueKeysWithValues: sessions.map { ($0.key, [attachment]) })
  }

  /// The `indexInUse` of every call so far.
  var indexInUse: [Bool] { state.withLock { $0 } }
}

/// A scripted backend for the model's routing: records every call, answers `attach` and
/// `moveHere` with what `answer` makes (after `gate`, when one is given), and `focus` with
/// `plainWindowFocused`.
actor ScriptedBackend: TerminalBackend {
  /// The terminal it stands for.
  nonisolated let terminal: LaunchTerminalApp
  /// Where `attach` waits first, if anywhere.
  private let gate: TestGate?
  /// Makes the attach result for a target.
  private let answer: @Sendable (AttachTarget) -> AttachResult
  /// The calls so far, by name.
  private(set) var calls: [String] = []
  /// The handles focused so far.
  private(set) var focused: [TerminalAttachmentHandle] = []

  /// A backend for `terminal` answering `answer`, waiting at `gate` first.
  init(
    terminal: LaunchTerminalApp,
    gate: TestGate? = nil,
    answer: @escaping @Sendable (AttachTarget) -> AttachResult
  ) {
    self.terminal = terminal
    self.gate = gate
    self.answer = answer
  }

  /// Records the call; waits at the gate; answers.
  func attach(_ target: AttachTarget) async -> AttachResult {
    calls.append("attach")
    if let gate { _ = await gate.pass() }
    return answer(target)
  }

  /// Records the call; answers.
  func moveHere(_ target: AttachTarget, confirmation: MoveHereConfirmation) async -> AttachResult {
    calls.append("moveHere")
    return answer(target)
  }

  /// Records the call; creation fails.
  func createAndAttach(
    _ request: NewSessionRequest, onCreated: (@Sendable (CreatedSession) -> Void)?
  ) async -> CreateAndAttachResult {
    calls.append("createAndAttach")
    return CreateAndAttachResult(creationFailure: .directoryMissing)
  }

  /// Records the call; gone.
  func currentSession(
    named name: String, on host: HostConfig
  ) async -> Result<AttachTarget, AttachFailure> {
    calls.append("currentSession")
    return .failure(.sessionGone)
  }

  /// Records the call; detached.
  func detach(session key: SessionKey, on host: HostConfig) async -> SessionDetachResult {
    calls.append("detach")
    return SessionDetachResult(key: key, outcome: .detached)
  }

  /// Records the call; nothing to detach.
  func detachOtherClients(
    of target: AttachTarget, confirmation: DetachOtherClientsConfirmation
  ) async -> DetachOtherClientsResult {
    calls.append("detachOtherClients")
    return DetachOtherClientsResult(key: target.key, outcome: .nothingToDetach)
  }

  /// No state.
  func state(of key: SessionKey) async -> AttachState? { nil }

  /// Never holds an unresolved launch.
  func hasUnresolvedLaunch(for key: SessionKey) async -> Bool { false }

  /// Records the handle; brought forward.
  func focus(_ handle: TerminalAttachmentHandle) async -> TerminalFocusResult {
    calls.append("focus")
    focused.append(handle)
    return .plainWindowFocused
  }
} // End of actor ScriptedBackend

extension MemoryLaunchStore: PlainLaunchRequestStore {
  /// No helper ever reports.
  func peekReport(_ id: LaunchToken) throws(LaunchStoreError) -> PlainLaunchReport? { nil }
}

/// The terminal setting's store over an in-memory one whose `load()` waits at `gate` first, so
/// the launch's resolution of the setting stays pending until the test opens it.
actor LoadGatedTerminalSettingStore: TerminalSettingStoring {
  /// The store answering once the gate lets the load through.
  let base: InMemoryPreferencesStore
  /// Where every load waits first.
  let gate: TestGate

  /// A store over `base` whose loads wait at `gate`.
  init(base: InMemoryPreferencesStore, gate: TestGate) {
    self.base = base
    self.gate = gate
  }

  /// Waits at the gate, then `base`'s.
  func load() async throws(PreferencesStoreError) -> PreferencesLoadResult {
    _ = await gate.pass()
    return await base.load()
  }

  /// `base`'s.
  func setGlobalShortcut(
    _ shortcut: GlobalShortcut?
  ) async throws(PreferencesStoreError) -> PreferencesChangeResult {
    try await base.setGlobalShortcut(shortcut)
  }

  /// `base`'s.
  func setFolderSearchScope(
    _ scope: FolderSearchScope
  ) async throws(PreferencesStoreError) -> PreferencesChangeResult {
    try await base.setFolderSearchScope(scope)
  }

  /// `base`'s.
  func setTerminal(_ id: String?) async throws(PreferencesStoreError) -> PreferencesChangeResult {
    try await base.setTerminal(id)
  }
} // End of actor LoadGatedTerminalSettingStore

/// The app on the terminal seam (PLAN.md D38, Phase I-12c3a): the model over a real engine and
/// real backends over fakes (`CountingITerm2` for iTerm2, the fake window layer for the plain
/// backend), the terminal setting in memory, Settings and onboarding over their fakes.
@MainActor
struct SeamHarness {
  /// The plain definition every harness loads: an `exec` one, never run.
  nonisolated static let sample: LoadedTerminalDefinition = {
    let json =
      #"{"schemaVersion": 1, "id": "sample-exec", "displayName": "Sample terminal", "#
      + #""bundleIdentifier": "com.example.sample-terminal", "minimumVersion": "1.0", "#
      + #""open": {"kind": "exec", "executable": "Contents/MacOS/sample", "#
      + #""arguments": ["{helper}", "{mode}", "{token}"]}, "focus": {"kind": "app"}}"#
    return LoadedTerminalDefinition(
      definition: try! TerminalDefinition.decode(Data(json.utf8)), source: .user,
      fileName: "sample-exec.json", script: nil)
  }()
  /// The sample definition's app, as ancestry names it.
  nonisolated static let sampleApp = LocalTerminalApp(
    bundleIdentifier: "com.example.sample-terminal", definitionIDs: ["sample-exec"])!
  /// A second plain definition (another app), for a change between two plain terminals.
  nonisolated static let sampleTwo: LoadedTerminalDefinition = {
    let json =
      #"{"schemaVersion": 1, "id": "sample-two", "displayName": "Second terminal", "#
      + #""bundleIdentifier": "com.example.second-terminal", "minimumVersion": "1.0", "#
      + #""open": {"kind": "exec", "executable": "Contents/MacOS/second", "#
      + #""arguments": ["{helper}", "{mode}", "{token}"]}, "focus": {"kind": "app"}}"#
    return LoadedTerminalDefinition(
      definition: try! TerminalDefinition.decode(Data(json.utf8)), source: .user,
      fileName: "sample-two.json", script: nil)
  }()

  /// The model.
  let model: AppModel
  /// The iTerm2 every iTerm2 seam is over.
  let iTerm2: CountingITerm2
  /// The terminal setting's store.
  let preferences: InMemoryPreferencesStore
  /// The LaunchServices stand-in.
  let inspector: FakeTerminalAppInspector
  /// The plain backend's window layer.
  let windows: FakePlainTerminalWindowLayer
  /// The launch store both backends write to.
  let store: MemoryLaunchStore
  /// Discovery, for the engine and the backends.
  let discovery: FakeDiscovery
  /// The engine's attributor.
  let attributor: RecordingAttributor
  /// Settings' profile list.
  let profiles: FakeProfiles
  /// "Set up SSH in iTerm2…" for every owner.
  let sshSetup: FakeSSHSetupOpener
  /// The persistent profile file.
  let files: FakeProfileFiles
  /// The terminal ids backends were built for, in order.
  let builds: OSAllocatedUnfairLock<[String]>
  /// This Mac and an SSH host.
  let hosts: [HostConfig]

  /// A started model whose stored terminal is `stored`, LaunchServices answering `snapshot`
  /// for every app; the persistent profile file is installed and out of date (its helper
  /// moved), so a rewrite would update it. `definitions` are the loaded definitions;
  /// `backend` replaces the backends the maker builds.
  static func make(
    stored: String?,
    snapshot: TerminalAppSnapshot = Self.installedSnapshot,
    definitions: [LoadedTerminalDefinition] = [sample],
    backend: (@MainActor @Sendable (ChosenTerminal) -> any TerminalBackend)? = nil
  ) async -> SeamHarness {
    let harness = build(
      stored: stored, snapshot: snapshot, definitions: definitions, backend: backend)
    let model = harness.model
    await model.start()
    await model.settings.profileOperationsFinished()
    _ = await UITestSupport.waitUntil {
      model.refreshState?.hosts.count == harness.hosts.count
        && model.refreshState?.hosts.allSatisfy(\.isLive) == true
    }
    return harness
  } // End of static func make(stored:snapshot:definitions:backend:)

  /// Every app installed, version 9.0, running.
  nonisolated static let installedSnapshot = TerminalAppSnapshot(
    url: URL(fileURLWithPath: "/Applications/Fixture.app"), version: "9.0", running: true)

  /// `make(stored:snapshot:definitions:backend:)`'s model, not started; with `loadGate`, the
  /// launch's read of the terminal setting waits there (the resolution stays pending).
  static func build(
    stored: String?,
    snapshot: TerminalAppSnapshot = Self.installedSnapshot,
    definitions: [LoadedTerminalDefinition] = [sample],
    loadGate: TestGate? = nil,
    backend: (@MainActor @Sendable (ChosenTerminal) -> any TerminalBackend)? = nil
  ) -> SeamHarness {
    let hosts = [UITestSupport.localHost(), UITestSupport.sshHost("Saturno")]
    let list = try! HostList(hosts)
    let iTerm2 = CountingITerm2()
    let preferences = InMemoryPreferencesStore(Preferences(terminal: stored))
    let inspector = FakeTerminalAppInspector(snapshot: snapshot)
    let windows = FakePlainTerminalWindowLayer()
    windows.openFailure = .appNotInstalled(appName: "Sample terminal")
    let store = MemoryLaunchStore()
    let discovery = FakeDiscovery()
    let attributor = RecordingAttributor(
      attachment: LocalAttachment(
        app: sampleApp, clientPID: 4100, terminalPath: "/dev/ttys009", isControlMode: false))
    let profiles = FakeProfiles(.available(["Default"]))
    let sshSetup = FakeSSHSetupOpener()
    let files = FakeProfileFiles()
    files.preinstall(list)
    files.moveHelper(to: "/Users/tester/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch")
    let hostStore = FakeHostListStore(UITestSupport.loaded(hosts))
    let builds = OSAllocatedUnfairLock<[String]>(initialState: [])
    let catalog = TerminalDefinitionCatalog(definitions: definitions, problems: [])
    let setting: any TerminalSettingStoring =
      loadGate.map { LoadGatedTerminalSettingStore(base: preferences, gate: $0) } ?? preferences
    let environment = AppEnvironment(
      loadHosts: { try await hostStore.load() },
      makeEngine: { hosts in
        RefreshCoordinator(
          hosts: hosts, discovery: discovery,
          attachmentIndex: AttachmentIndex(iTerm2: iTerm2, clock: PatientClock()),
          localClients: attributor, configuration: UITestSupport.quietConfiguration)
      },
      makeSystemEvents: { _ in nil },
      now: { UITestSupport.now },
      terminate: {},
      settings: SettingsTestSupport.environment(
        store: hostStore, profiles: profiles, sshSetup: sshSetup, profileFiles: files),
      makeTerminalBackend: { chosen, onUpdate in
        builds.withLock { $0.append(chosen.id) }
        if let backend { return backend(chosen) }
        switch chosen {
        case .iTerm2:
          return ITerm2TerminalBackend(
            coordinator: AttachCoordinator(
              iTerm2: iTerm2, discovery: discovery, store: store, helperPath: AttachHarness.helper,
              clock: VirtualClock(), buriedTabTimer: .off, onUpdate: onUpdate),
            appActivator: FakeTerminalAppActivator())
        case .plain(let loaded):
          return PlainTerminalBackend(
            loaded: loaded, windows: windows, helperPath: AttachHarness.helper, store: store,
            discovery: discovery, sessionCreator: FakeSessionCreator(), clock: VirtualClock(),
            appActivator: FakeTerminalAppActivator(), onUpdate: onUpdate)
        }
      },
      terminal: TerminalEnvironment(
        preferences: setting, loadDefinitions: { catalog }, inspector: inspector),
      rewritesProfilesAtLaunch: true)
    return SeamHarness(
      model: AppModel(environment: environment), iTerm2: iTerm2, preferences: preferences,
      inspector: inspector, windows: windows, store: store, discovery: discovery,
      attributor: attributor, profiles: profiles, sshSetup: sshSetup, files: files,
      builds: builds, hosts: hosts)
  } // End of static func build(stored:snapshot:definitions:loadGate:backend:)

  /// The session `FakeDiscovery` lists on This Mac.
  var localKey: SessionKey { FakeDiscovery.session(on: hosts[0]).key }

  /// The session `FakeDiscovery` lists on the SSH host.
  var remoteKey: SessionKey { FakeDiscovery.session(on: hosts[1]).key }

  /// The terminal ids backends were built for, in order.
  var built: [String] { builds.withLock { $0 } }

  /// Waits until `count` actions ended; returns whether they did.
  func waitForActions(_ count: Int) async -> Bool {
    await UITestSupport.waitUntil { model.finishedActions.count >= count }
  }
} // End of struct SeamHarness

/// The app on the terminal seam (PLAN.md D38, Phase I-12c3a; requirements 7, 8 and 12): the
/// choice resolved at launch and through the one setter, one backend per terminal id built
/// lazily and cached, every iTerm2 seam silent with a plain choice, an unavailable choice
/// failing every action with nothing run, a change while an action is pending applied once none
/// is, the plain backend's results in the model, and the engine's attributor beside or
/// without D16's index. With iTerm2 chosen everything else is the existing tests' (their
/// harness builds iTerm2's backend over their coordinator).
@Suite("Terminal seam: the app")
@MainActor
struct TerminalSeamTests {
  /// Shorthand.
  typealias Support = UITestSupport

  /// The default resolves to iTerm2; its backend is built at the first action only, once; the
  /// setter writes the setting and the next action builds the plain backend (its request is a
  /// plain one, its window layer asked); switching back reuses iTerm2's backend.
  @Test func oneBackendPerTerminalBuiltLazilyAndCached() async {
    let harness = await SeamHarness.make(stored: nil)
    let model = harness.model
    #expect(model.terminalChoice == .iTerm2)
    #expect(model.terminalDefinitions?.definitions == [SeamHarness.sample])
    #expect(harness.built.isEmpty, "nothing is built at launch")
    model.open(harness.localKey)
    #expect(await harness.waitForActions(1))
    model.open(harness.localKey)
    #expect(await harness.waitForActions(2))
    #expect(harness.built == ["iterm2"])

    let changed = await model.setTerminal("sample-exec")
    #expect(changed == .success(.plain(SeamHarness.sample)))
    #expect(model.terminalChoice == .plain(SeamHarness.sample))
    #expect(await harness.preferences.preferences.terminal == "sample-exec")
    model.open(harness.localKey)
    #expect(await harness.waitForActions(3))
    #expect(harness.built == ["iterm2", "sample-exec"])
    #expect(harness.windows.opens.map(\.definitionID) == ["sample-exec"])
    let plainRequest = harness.store.written.last
    #expect(plainRequest?.terminal == .plain(definitionID: "sample-exec"))
    #expect(harness.store.discarded.last == plainRequest?.id, "withdrawn after the open failed")
    #expect(
      model.activities[harness.localKey]
        == .failed(.attach(.terminalWindow(.appNotInstalled(appName: "Sample terminal")))))

    #expect(await model.setTerminal(nil) == .success(.iTerm2))
    #expect(await harness.preferences.preferences.terminal == nil)
    model.open(harness.localKey)
    #expect(await harness.waitForActions(4))
    #expect(harness.built == ["iterm2", "sample-exec"], "switching back reuses the backend")
    await model.shutdown()
  } // End of func oneBackendPerTerminalBuiltLazilyAndCached()

  /// Requirement 7: with a plain choice the app never contacts iTerm2. Launch (no D26 rewrite
  /// of the out-of-date file), the popover and its refreshes (no D16 check), an Open and a Move
  /// here (the plain backend), Settings' window, a save and its profile update, every "Set up
  /// SSH in iTerm2…", "Show tab": iTerm2 gets no call, its backend is never built, the profile
  /// list and the ssh setup opener are never asked, the persistent profile file is neither
  /// written nor removed, and This Mac's attribution counts every client (no index in use).
  /// Choosing iTerm2 again resumes the rewrite.
  @Test func aPlainChoiceNeverContactsITerm2() async {
    let harness = await SeamHarness.make(stored: "sample-exec")
    let model = harness.model
    #expect(model.terminalChoice == .plain(SeamHarness.sample))
    model.popoverDidOpen()
    model.refresh()
    await model.engineRequestsHandled()
    _ = await Support.waitUntil { harness.attributor.indexInUse.count >= 2 }
    model.open(harness.localKey)
    #expect(await harness.waitForActions(1))
    model.requestMoveHere(harness.localKey)
    model.confirmMoveHere()
    #expect(await harness.waitForActions(2))
    #expect(harness.store.written.last?.detachesOtherClients == true)
    model.showTab(for: harness.localKey)

    let settings = model.settings
    await settings.windowDidOpen()
    #expect(settings.profileChoices == .notUsedWithThisTerminal)
    #expect(settings.iTermProblem == nil)
    settings.setDisplayName("Neptuno M4")
    #expect(await settings.save())
    await settings.profileOperationsFinished()

    let saturno = harness.hosts[1]
    for actions in [model.sshSetup, settings.sshSetup, model.onboarding.sshSetup] {
      actions.open(saturno)
      #expect(actions.states[saturno.id] == .failed(.notUsedWithThisTerminal))
    }
    model.setUpSSH(hostID: saturno.id)
    model.popoverDidClose()
    await model.engineRequestsHandled()

    #expect(await harness.iTerm2.calls.isEmpty)
    #expect(harness.built == ["sample-exec"])
    #expect(harness.profiles.calls.value == 0)
    #expect(harness.sshSetup.calls.isEmpty)
    #expect(harness.files.updateCalls.isEmpty && harness.files.installCalls.isEmpty)
    #expect(harness.files.removeCalls == 0)
    #expect(model.refreshState?.attachmentCheck == .notChecked)
    #expect(!harness.attributor.indexInUse.isEmpty)
    #expect(harness.attributor.indexInUse.allSatisfy { !$0 })
    #expect(harness.windows.opens.count == 2)

    #expect(await model.setTerminal("iterm2") == .success(.iTerm2))
    await settings.profileOperationsFinished()
    #expect(harness.files.updateCalls.count == 1, "the rewrite resumes with iTerm2 chosen")
    #expect(model.sshSetup.usesITerm2 && settings.terminal == .iTerm2)
    await model.shutdown()
  } // End of func aPlainChoiceNeverContactsITerm2()

  /// iTerm2 chosen: D16's index runs while the popover shows and the attributor runs beside it
  /// (`indexInUse`); each row carries its session's local attachments (no view draws them).
  @Test func withITerm2TheAttributorRunsBesideTheIndex() async {
    let harness = await SeamHarness.make(stored: "iterm2")
    let model = harness.model
    #expect(model.terminalChoice == .iTerm2)
    model.popoverDidOpen()
    #expect(await Support.waitUntil { await harness.iTerm2.calls.contains("listTmuxConnections") })
    #expect(harness.attributor.indexInUse.allSatisfy { $0 })
    let row = model.content.sections.first?.rows.first
    #expect(row?.localAttachments == [harness.attributor.attachment])
    #expect(model.content.sections.last?.rows.first?.localAttachments == [])
    await model.shutdown()
  }

  /// Requirement 8: an unavailable choice is never replaced. Every action ends in the typed
  /// failure naming the choice and the reason, with no backend built, nothing written or
  /// opened; a stored `iterm2` with iTerm2 gone is unavailable too.
  @Test func anUnavailableChoiceRunsNothing() async {
    let harness = await SeamHarness.make(stored: "warp")
    let model = harness.model
    let failure = TerminalChoiceUnavailable(terminalID: "warp", reason: .unknownID)
    #expect(model.terminalChoice == .unavailable(failure))
    model.open(harness.localKey)
    #expect(model.activities[harness.localKey] == .failed(.terminalUnavailable(failure)))
    #expect(SessionProblem.terminalUnavailable(failure).recoveries == [.openSettings])
    model.newSession()
    model.newSessionDraft.name = "fresh"
    model.createSession()
    #expect(model.newSessionDraft.state == .failed(failure.message))
    model.focus(.app(SeamHarness.sampleApp), for: harness.localKey)
    #expect(model.notes[harness.localKey] == failure.message)
    #expect(harness.built.isEmpty)
    #expect(harness.store.written.isEmpty && harness.windows.opens.isEmpty)
    #expect(await harness.iTerm2.calls.isEmpty)

    harness.inspector.setSnapshot(TerminalAppSnapshot(url: nil, version: nil, running: false))
    let gone = TerminalChoiceUnavailable(terminalID: "iterm2", reason: .notInstalled)
    #expect(await model.setTerminal("iterm2") == .success(.unavailable(gone)))
    #expect(model.terminalChoice == .unavailable(gone))
    #expect(!model.sshSetup.usesITerm2 && model.settings.terminal == .unavailable(gone))
    await model.shutdown()
  } // End of func anUnavailableChoiceRunsNothing()

  /// A change while a session action is pending waits until none is, never cancelling it;
  /// the next action then runs on the new choice's backend.
  @Test func aChangeWaitsForThePendingAction() async {
    let gate = TestGate()
    gate.close()
    let harness = await SeamHarness.make(stored: nil) { chosen in
      ScriptedBackend(terminal: chosen.terminal, gate: chosen.usesITerm2 ? gate : nil) { target in
        AttachResult(key: target.key, launchID: LaunchToken(), state: .failed(.timedOut))
      }
    }
    let model = harness.model
    model.open(harness.localKey)
    await gate.waitForArrivals(1)
    #expect(await model.setTerminal("sample-exec") == .success(.plain(SeamHarness.sample)))
    #expect(model.pendingTerminalChoice == .plain(SeamHarness.sample))
    #expect(model.terminalChoice == .iTerm2)
    #expect(model.isPending(harness.localKey))
    gate.open()
    #expect(await harness.waitForActions(1))
    #expect(model.finishedActions.first?.outcome.attachResult?.failure == .timedOut)
    #expect(model.terminalChoice == .plain(SeamHarness.sample))
    #expect(model.pendingTerminalChoice == nil)
    model.open(harness.localKey)
    #expect(await harness.waitForActions(2))
    #expect(harness.built == ["iterm2", "sample-exec"])
    await model.shutdown()
  } // End of func aChangeWaitsForThePendingAction()

  /// The plain backend's results in the model (PLAN.md D38): a confirmed window is recorded,
  /// so "Detach from this Mac" is offered and goes to the backend, "Show window" brings the
  /// window forward through it; an app the session was found open in is brought forward
  /// through it too; a refused session name shows its problem.
  @Test func plainResultsReachTheModel() async throws {
    let window = PlainTerminalWindow(
      openedBy: SeamHarness.sample, windowID: nil, tty: "/dev/ttys004")
    let holder = OSAllocatedUnfairLock<ScriptedBackend?>(initialState: nil)
    let harness = await SeamHarness.make(stored: "sample-exec") { chosen in
      let backend = ScriptedBackend(terminal: chosen.terminal) { target in
        AttachResult(
          key: target.key, launchID: LaunchToken(),
          state: .plainFocused(client: Self.client(target)),
          plainWindow: window, plainClient: Self.client(target))
      }
      holder.withLock { $0 = backend }
      return backend
    }
    let model = harness.model
    let key = harness.localKey
    #expect(!model.canDetach(key))
    model.open(key)
    #expect(await harness.waitForActions(1))
    let backend = try #require(holder.withLock { $0 })
    #expect(model.activities[key] == .focused)
    #expect(model.terminalAttachments[key] == .plainWindow(window))
    #expect(model.canDetach(key))
    model.showWindow(for: key)
    #expect(await Support.waitUntil { model.showTabTasks.isEmpty })
    model.focus(.app(SeamHarness.sampleApp), for: key)
    #expect(await Support.waitUntil { model.showTabTasks.isEmpty })
    #expect(await backend.focused == [.plainWindow(window), .app(SeamHarness.sampleApp)])
    #expect(model.notes[key] == nil)
    model.detach(key)
    #expect(await harness.waitForActions(2))
    #expect(await backend.calls == ["attach", "focus", "focus", "detach"])
    #expect(model.terminalAttachments[key] == nil)
    #expect(model.activities[key] == .detached)
    await model.shutdown()

    let named = await SeamHarness.make(stored: "sample-exec")
    var bracketed = FakeDiscovery.session(on: named.hosts[0])
    bracketed.name = "build[1]"
    named.discovery.setStatus(.ok([bracketed]), for: named.hosts[0].id)
    named.model.refresh()
    #expect(
      await Support.waitUntil {
        named.model.refreshState?.snapshot(of: named.hosts[0].id)?.sessions.first?.discovered.name
          == "build[1]"
      })
    named.model.open(bracketed.key)
    #expect(await named.waitForActions(1))
    #expect(
      named.model.activities[bracketed.key] == .failed(.attach(.unsupportedSessionName)))
    #expect(named.store.written.isEmpty && named.windows.opens.isEmpty)
    await named.model.shutdown()
  } // End of func plainResultsReachTheModel()

  /// A plain client record for `target`'s session.
  nonisolated static func client(_ target: AttachTarget) -> PlainClientRecord {
    PlainClientRecord(
      session: PlainClientRecord.identity(of: target.session),
      client: OtherClient(processID: "5150", created: "1792600100", name: "/dev/ttys004")!,
      launchID: LaunchToken(), token: nil, terminalPath: "/dev/ttys004")
  }

  /// The new sentences: the unavailable choice's problem, the name refusal's, the focus notes
  /// and the not-used states (Phase I-12d writes the final ones), each a sentence, distinct from
  /// each other and from every existing failure message.
  @Test func newSentencesAreDistinct() throws {
    let samples: [String] = [
      SessionProblem.terminalUnavailable(.init(terminalID: "x", reason: .unknownID)).message,
      SessionProblem.attach(.unsupportedSessionName).message,
      ProfileChoices.notUsedWithThisTerminal.note ?? "",
      SSHSetupState.failed(.notUsedWithThisTerminal).message,
    ]
    let notes = [
      TerminalFocusResult.handleOfAnotherTerminal, .appActivation(.notRunning),
      .appActivation(.refused), .plainWindowFailed(.appNotRunning(appName: "Sample terminal")),
    ].compactMap(SessionProblem.focusNote)
    #expect(notes.count == 4)
    #expect(SessionProblem.focusNote(.plainWindowFocused) == nil)
    #expect(SessionProblem.focusNote(.appActivation(.activated)) == nil)
    #expect(
      SessionProblem.focusNote(.launchTab(.notOpenedHere))
        == SessionProblem.showTabNote(.notOpenedHere))
    #expect(FailureMessageTests.caseIndex(.unsupportedSessionName) == 24)
    let all = samples + notes
    #expect(Set(all).count == all.count)
    #expect(Set(all).isDisjoint(with: FailureMessageTests.allMessages))
    for message in all {
      let first = message.first.map(String.init) ?? ""
      #expect(
        first == first.uppercased() || message.hasPrefix("muxFinder") || message.hasPrefix("iTerm2")
          || message.hasPrefix("macOS"), "\(message)")
      #expect(message.hasSuffix("."), "\(message)")
    }
  } // End of func newSentencesAreDistinct()

  // MARK: - Review fixes of Phase I-12c3a

  /// Review fix 1: a launch the plain backend left unresolved (its window opened, its helper
  /// took the request, no client confirmed and no result: `timedOut`) blocks the same session's
  /// Open on iTerm2's backend after a change of terminal: it ends `earlierLaunchPending` with
  /// nothing written, opened or sent to iTerm2. Once the helper's result exists, the Open goes
  /// to iTerm2's backend.
  @Test func anotherTerminalsUnresolvedLaunchRefusesTheOpen() async throws {
    let harness = await SeamHarness.make(stored: "sample-exec")
    let model = harness.model
    let key = harness.localKey
    harness.windows.openFailure = nil
    harness.store.setHelperTakesRequests(true)
    model.open(key)
    #expect(await harness.waitForActions(1))
    #expect(model.finishedActions.last?.outcome.attachResult?.failure == .timedOut)
    let first = try #require(harness.store.written.first)
    #expect(harness.windows.opens.count == 1)

    #expect(await model.setTerminal("iterm2") == .success(.iTerm2))
    model.open(key)
    #expect(await harness.waitForActions(2))
    #expect(
      model.finishedActions.last?.outcome.attachResult?.failure == .earlierLaunchPending)
    #expect(
      model.activities[key] == .failed(.attach(.earlierLaunchPending, launchTab: nil)))
    #expect(harness.store.written.count == 1, "nothing written")
    #expect(harness.windows.opens.count == 1, "nothing opened")
    #expect(await harness.iTerm2.calls.isEmpty, "nothing sent to iTerm2")
    #expect(harness.built == ["sample-exec", "iterm2"])

    harness.store.setResult(
      LaunchResult(
        id: first.id, helperPID: 777, startedAt: UITestSupport.now, childStartedAt: nil,
        endedAt: UITestSupport.now, childTermination: .exited(0), failure: nil))
    model.open(key)
    #expect(await harness.waitForActions(3))
    #expect(
      model.finishedActions.last?.outcome.attachResult?.failure != .earlierLaunchPending)
    #expect(await !harness.iTerm2.calls.isEmpty, "the Open went to iTerm2's backend")
    await model.shutdown()
  } // End of func anotherTerminalsUnresolvedLaunchRefusesTheOpen()

  /// Review fix 2: until launch has read the stored choice the model's choice is `unresolved`,
  /// and nothing contacts iTerm2. Settings opened then (the menu shows it before the model
  /// starts) asks iTerm2 nothing (its profile list `notLoaded`, no iTerm2 problem), and every
  /// "Set up SSH in iTerm2…" asks no opener; with a plain choice stored, nothing does after the
  /// resolution either (no profile list, no D26 rewrite, no backend).
  @Test func settingsBeforeTheResolutionContactsNoITerm2() async {
    let gate = TestGate()
    gate.close()
    let harness = SeamHarness.build(stored: "sample-exec", loadGate: gate)
    let model = harness.model
    #expect(model.terminalChoice == .unresolved)
    #expect(model.settings.terminal == .unresolved)
    let started = Task { await model.start() }
    await gate.waitForArrivals(1)
    let settings = model.settings
    await settings.windowDidOpen()
    #expect(settings.profileChoices == .notLoaded)
    #expect(settings.iTermProblem == nil)
    let saturno = harness.hosts[1]
    for actions in [model.sshSetup, settings.sshSetup, model.onboarding.sshSetup] {
      actions.open(saturno)
      #expect(actions.states[saturno.id] == .failed(.notUsedWithThisTerminal))
    }
    #expect(harness.profiles.calls.value == 0)
    #expect(harness.sshSetup.calls.isEmpty)

    gate.open()
    await started.value
    await settings.profileOperationsFinished()
    await model.engineRequestsHandled()
    #expect(model.terminalChoice == .plain(SeamHarness.sample))
    #expect(settings.profileChoices == .notUsedWithThisTerminal)
    #expect(await harness.iTerm2.calls.isEmpty)
    #expect(harness.profiles.calls.value == 0)
    #expect(harness.sshSetup.calls.isEmpty)
    #expect(harness.files.updateCalls.isEmpty && harness.files.installCalls.isEmpty)
    #expect(harness.built.isEmpty)
    await model.shutdown()
  } // End of func settingsBeforeTheResolutionContactsNoITerm2()

  /// Review fix 2, iTerm2 stored: Settings opened before the resolution asks iTerm2 nothing
  /// then; once the stored choice resolves to iTerm2, the work deferred for it runs once: the
  /// profile list (the window still open), D26's launch rewrite, and "Set up SSH in iTerm2…"
  /// lines that said iTerm2 was not chosen are cleared.
  @Test func iTerm2WorkWaitsForTheResolution() async {
    let gate = TestGate()
    gate.close()
    let harness = SeamHarness.build(stored: "iterm2", loadGate: gate)
    let model = harness.model
    let started = Task { await model.start() }
    await gate.waitForArrivals(1)
    let settings = model.settings
    await settings.windowDidOpen()
    let saturno = harness.hosts[1]
    settings.sshSetup.open(saturno)
    #expect(harness.profiles.calls.value == 0)
    #expect(settings.profileChoices == .notLoaded)
    #expect(harness.sshSetup.calls.isEmpty)
    #expect(harness.files.updateCalls.isEmpty)

    gate.open()
    await started.value
    #expect(model.terminalChoice == .iTerm2)
    #expect(await Support.waitUntil { harness.profiles.calls.value == 1 })
    #expect(await Support.waitUntil { settings.profileChoices == .available(["Default"]) })
    await settings.profileOperationsFinished()
    #expect(harness.files.updateCalls.count == 1, "D26's launch rewrite")
    #expect(settings.sshSetup.states[saturno.id] == nil)
    #expect(harness.profiles.calls.value == 1)
    await model.shutdown()
  } // End of func iTerm2WorkWaitsForTheResolution()

  /// Review fix 4: each backend keeps its own records. A session opened in one plain terminal
  /// and then, after a change, in another: both windows are kept, each under its terminal;
  /// "Show window" and "Detach from this Mac" go to the chosen terminal's backend with its own
  /// window, never the other's; switching back offers and routes the first window again.
  @Test func eachBackendKeepsItsOwnRecords() async throws {
    let holders = OSAllocatedUnfairLock<[String: ScriptedBackend]>(initialState: [:])
    let harness = await SeamHarness.make(
      stored: "sample-exec", definitions: [SeamHarness.sample, SeamHarness.sampleTwo]
    ) { chosen in
      let backend = ScriptedBackend(terminal: chosen.terminal) { target in
        AttachResult(
          key: target.key, launchID: LaunchToken(),
          state: .plainConfirmed(client: Self.client(target)),
          plainWindow: Self.window(of: chosen), plainClient: Self.client(target))
      }
      holders.withLock { $0[chosen.id] = backend }
      return backend
    }
    let model = harness.model
    let key = harness.remoteKey
    let first = try #require(Self.window(of: .plain(SeamHarness.sample)))
    let second = try #require(Self.window(of: .plain(SeamHarness.sampleTwo)))
    model.open(key)
    #expect(await harness.waitForActions(1))
    #expect(model.terminalAttachments[key] == .plainWindow(first))

    #expect(await model.setTerminal("sample-two") == .success(.plain(SeamHarness.sampleTwo)))
    #expect(model.terminalAttachments[key] == nil, "the other terminal's window is not offered")
    #expect(!model.canDetach(key))
    model.open(key)
    #expect(await harness.waitForActions(2))
    #expect(model.terminalAttachments[key] == .plainWindow(second))
    #expect(model.terminalAttachmentsByTerminal["sample-exec"]?[key] == .plainWindow(first))
    model.showWindow(for: key)
    #expect(await Support.waitUntil { model.showTabTasks.isEmpty })
    model.detach(key)
    #expect(await harness.waitForActions(3))
    let one = try #require(holders.withLock { $0["sample-exec"] })
    let two = try #require(holders.withLock { $0["sample-two"] })
    #expect(await two.focused == [.plainWindow(second)])
    #expect(await two.calls == ["attach", "focus", "detach"])
    #expect(await one.calls == ["attach"], "nothing routed to the other backend")
    #expect(model.terminalAttachments[key] == nil)
    #expect(model.terminalAttachmentsByTerminal["sample-exec"]?[key] == .plainWindow(first))

    #expect(await model.setTerminal("sample-exec") == .success(.plain(SeamHarness.sample)))
    #expect(model.terminalAttachments[key] == .plainWindow(first))
    #expect(model.canDetach(key))
    model.showWindow(for: key)
    #expect(await Support.waitUntil { model.showTabTasks.isEmpty })
    #expect(await one.focused == [.plainWindow(first)])
    await model.shutdown()
  } // End of func eachBackendKeepsItsOwnRecords()

  /// The window a plain backend of `chosen` opens in `eachBackendKeepsItsOwnRecords()`; `nil`
  /// for iTerm2.
  nonisolated static func window(of chosen: ChosenTerminal) -> PlainTerminalWindow? {
    guard case .plain(let loaded) = chosen else { return nil }
    return PlainTerminalWindow(
      openedBy: loaded, windowID: "window-\(loaded.definition.id)", tty: nil)
  }
} // End of struct TerminalSeamTests
