import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// The onboarding window's model (PLAN.md Phase 9b, D24): the examples, editing, the This Mac
/// choice and its exclusivity, validation, the save through the store (success, a changed file
/// refused), closing without saving, and when the app shows it. Nothing here saves the real
/// `hosts.json`, opens a tab, runs ssh or contacts iTerm2.
@Suite("Onboarding")
@MainActor
struct OnboardingTests {
  /// Shorthand.
  typealias Support = SettingsTestSupport

  /// What the app records from the model's callbacks.
  @MainActor
  final class Callbacks {
    /// Lists handed to the app.
    var saved: [HostList] = []
    /// Window closes asked for.
    var closes = 0
    /// "Open Settings" requests.
    var settingsOpened = 0
  }

  /// The examples, loaded as `notSavedYet`.
  static func examples() -> HostStoreLoadResult {
    HostStoreLoadResult(hosts: .onboardingDefaults(), state: .notSavedYet)
  }

  /// A prepared model over a fake store that loads the examples, with its callbacks recorded.
  static func preparedModel(
    opener: FakeSSHSetupOpener? = nil
  ) async throws -> (OnboardingModel, FakeHostListStore, Callbacks) {
    let store = FakeHostListStore(examples())
    let model = OnboardingModel(environment: OnboardingEnvironment(store: store, sshSetup: opener))
    let callbacks = Self.record(model)
    #expect(model.prepare(try await store.load()))
    return (model, store, callbacks)
  }

  /// Records `model`'s callbacks; closing the window tells the model, as the window does.
  static func record(_ model: OnboardingModel) -> Callbacks {
    let callbacks = Callbacks()
    model.onHostListSaved = { callbacks.saved.append($0) }
    model.closeWindow = { [weak model] in
      callbacks.closes += 1
      model?.windowDidClose()
    }
    model.onOpenSettings = { callbacks.settingsOpened += 1 }
    return callbacks
  }

  // MARK: - Examples and when it shows

  /// The examples are D19's defaults: Saturno, Neptuno and Sirio, SSH, no destination, turned
  /// off, none This Mac; they can be saved as they are. The fixed text holds the brief's four
  /// expectations (one line each), the scope line and the iTerm2 requirements.
  @Test func showsTheExamples() async throws {
    let (model, store, _) = try await Self.preparedModel()
    #expect(model.drafts.map(\.displayName) == ["Saturno", "Neptuno", "Sirio"])
    #expect(
      model.drafts.allSatisfy { $0.mode == .ssh && $0.sshDestination.isEmpty && !$0.isEnabled })
    #expect(Set(model.drafts.map(\.id)).count == 3)
    #expect(model.thisMacID == nil)
    #expect(model.isPrepared && model.isEditable && model.isValid && model.canSave)
    #expect(store.loads == 1 && store.saves.isEmpty)
    #expect(OnboardingText.expectations.count == 4)
    #expect(OnboardingText.expectations.allSatisfy { !$0.contains("\n") })
    #expect(OnboardingText.scope.contains("default tmux server only"))
    #expect(OnboardingText.iTermRequirements.contains { $0.contains("Enable Python API") })
    #expect(OnboardingText.iTermRequirements.contains { $0.contains("Automation") })
  } // End of func showsTheExamples()

  /// Only a list not saved yet prepares onboarding; a saved or unusable list, a fixture model and
  /// a model after `shutdown()` never do.
  @Test func preparesOnlyForAListNotSavedYet() async {
    #expect(OnboardingModel.isShown(for: .notSavedYet))
    #expect(!OnboardingModel.isShown(for: .saved))
    #expect(!OnboardingModel.isShown(for: .invalid(.notJSON)))
    for state in [HostStoreLoadResult.State.saved, .invalid(.malformed)] {
      let model = OnboardingModel(
        environment: OnboardingEnvironment(store: FakeHostListStore(Self.examples())))
      #expect(!model.prepare(HostStoreLoadResult(hosts: .onboardingDefaults(), state: state)))
      #expect(model.drafts.isEmpty && !model.isPrepared && !model.canSave)
    }
    let fixture = OnboardingModel(fixture: OnboardingFixtures.examplesShown)
    #expect(!fixture.prepare(Self.examples()))
    #expect(await fixture.save() == false)
    let stopped = OnboardingModel(
      environment: OnboardingEnvironment(store: FakeHostListStore(Self.examples())))
    await stopped.shutdown()
    #expect(!stopped.prepare(Self.examples()))
  } // End of func preparesOnlyForAListNotSavedYet()

  /// The app shows the onboarding window at launch only for a list loaded as `notSavedYet`,
  /// never for a saved, unusable or unreadable one; showing it saves nothing, opens no ssh tab
  /// and discovers nothing (the examples are turned off).
  @Test(arguments: ["saved", "notSavedYet", "invalid", "unreadable"])
  func appShowsOnboardingOnlyForAListNotSavedYet(state: String) async {
    let result: HostStoreLoadResult
    switch state {
    case "saved": result = Support.loaded([Support.sshHost("Saturno", enabled: false)])
    case "invalid":
      result = HostStoreLoadResult(hosts: .onboardingDefaults(), state: .invalid(.notJSON))
    default: result = Self.examples()
    }
    let store = FakeHostListStore(result)
    if state == "unreadable" { store.failLoads(with: .directoryNotOwnedByUser) }
    let opener = FakeSSHSetupOpener()
    let discovery = FakeDiscovery()
    let seams = SeamRecorder()
    let environment = AppEnvironment(
      loadHosts: { try await store.load() },
      makeEngine: {
        RefreshCoordinator(
          hosts: $0, discovery: discovery, configuration: UITestSupport.quietConfiguration)
      },
      makeSystemEvents: { _ in nil },
      now: { UITestSupport.now },
      terminate: {},
      presentOnboarding: { seams.presented.append(ObjectIdentifier($0)) },
      settings: Support.environment(store: store, sshSetup: opener))
    let model = AppModel(environment: environment)
    await model.start()
    let shown = state == "notSavedYet"
    #expect(seams.presented == (shown ? [ObjectIdentifier(model.onboarding)] : []))
    #expect(model.onboarding.isPrepared == shown)
    #expect(model.onboarding.drafts.count == (shown ? 3 : 0))
    #expect(store.saves.isEmpty)
    #expect(opener.calls.isEmpty)
    #expect(discovery.totalCalls == 0)
    await model.shutdown()
  } // End of func appShowsOnboardingOnlyForAListNotSavedYet(state:)

  // MARK: - Editing

  /// This Mac is exclusive: choosing a host makes it local and turned on, and the previous
  /// This Mac goes back to SSH, turned off, its destination kept (D19's switch); "none" does
  /// the same to the current one; an unknown host changes nothing.
  @Test func thisMacIsExclusive() async throws {
    let (model, _, _) = try await Self.preparedModel()
    let ids = model.drafts.map(\.id)
    model.setDestination("saturno.example", for: ids[0])
    #expect(model.setEnabled(true, for: ids[0]))
    model.chooseThisMac(ids[1])
    #expect(model.thisMacID == ids[1])
    #expect(model.draft(ids[1])?.mode == .local && model.draft(ids[1])?.isEnabled == true)
    model.chooseThisMac(ids[0])
    #expect(model.thisMacID == ids[0])
    #expect(model.draft(ids[1])?.mode == .ssh && model.draft(ids[1])?.isEnabled == false)
    #expect(model.drafts.filter { $0.mode == .local }.count == 1)
    model.chooseThisMac(nil)
    #expect(model.thisMacID == nil)
    #expect(model.draft(ids[0])?.mode == .ssh && model.draft(ids[0])?.isEnabled == false)
    #expect(model.draft(ids[0])?.sshDestination == "saturno.example")
    model.chooseThisMac(UUID())
    #expect(model.thisMacID == nil)
    #expect(model.canSave)
  } // End of func thisMacIsExclusive()

  /// The Settings editor's rules: an SSH host turns on only with a valid destination (refused
  /// with a reason otherwise), destinations with spaces or a leading "-" are errors, and a name
  /// must be set and unique; a draft with an error is never saved.
  @Test func validatesEdits() async throws {
    let (model, store, _) = try await Self.preparedModel()
    let ids = model.drafts.map(\.id)
    #expect(!model.setEnabled(true, for: ids[2]))
    #expect(model.enableRefusals[ids[2]] == HostDraftIssues.destinationNeededToTurnOn)
    #expect(model.draft(ids[2])?.isEnabled == false)
    model.setDestination("sirio .example", for: ids[2])
    #expect(
      model.issues(for: ids[2])?.destination
        == ValidationError.sshDestinationContainsWhitespace.message)
    #expect(!model.canSave)
    model.setDestination("-oProxyCommand=x", for: ids[2])
    #expect(
      model.issues(for: ids[2])?.destination
        == ValidationError.sshDestinationStartsWithHyphen.message)
    #expect(!model.setEnabled(true, for: ids[2]))
    model.setDestination("admin@sirio.example", for: ids[2])
    #expect(model.setEnabled(true, for: ids[2]))
    #expect(model.enableRefusals[ids[2]] == nil)
    model.setDisplayName("  ", for: ids[0])
    #expect(model.issues(for: ids[0])?.displayName == "Enter a name for this host.")
    model.setDisplayName("SIRIO", for: ids[0])
    #expect(model.issues(for: ids[0])?.displayName == "Another host already has this name.")
    #expect(!model.isValid && !model.canSave)
    #expect(await model.save() == false)
    #expect(store.saves.isEmpty)
    model.setDisplayName("Saturno", for: ids[0])
    #expect(model.isValid && model.canSave)
  } // End of func validatesEdits()

  // MARK: - Saving

  /// "Save hosts" saves through a real `HostStore` in a private folder, expecting no file: the
  /// list reads back as saved with every edit, the app gets it, and the window closes; a second
  /// save does nothing.
  @Test func savesThroughTheStore() async throws {
    let folder = try Support.privateStoreFolder()
    defer { try? FileManager.default.removeItem(at: folder.base) }
    let store = HostStore(fileURL: folder.file)
    let loaded = try await store.load()
    #expect(loaded.state == .notSavedYet)
    let model = OnboardingModel(environment: OnboardingEnvironment(store: store))
    let callbacks = Self.record(model)
    #expect(model.prepare(loaded))
    model.windowDidOpen()
    let ids = model.drafts.map(\.id)
    model.chooseThisMac(ids[1])
    model.setDestination(" saturno.example ", for: ids[0])
    #expect(model.setEnabled(true, for: ids[0]))
    model.setDisplayName("Sirio (lab)", for: ids[2])
    #expect(await model.save())
    #expect(model.didSave && !model.isEditable && !model.canSave)
    #expect(callbacks.closes == 1 && !model.isWindowOpen)
    let reloaded = try await HostStore(fileURL: folder.file).load()
    #expect(reloaded.state == .saved)
    #expect(reloaded.hosts.hosts.map(\.id) == ids)
    #expect(reloaded.hosts.thisMac?.id == ids[1])
    #expect(reloaded.hosts.host(withID: ids[0])?.sshDestination == "saturno.example")
    #expect(reloaded.hosts.host(withID: ids[0])?.isEnabled == true)
    #expect(reloaded.hosts.host(withID: ids[2])?.displayName == "Sirio (lab)")
    #expect(reloaded.hosts.host(withID: ids[2])?.isEnabled == false)
    #expect(callbacks.saved == [reloaded.hosts])
    #expect(await model.save() == false)
    #expect(callbacks.saved.count == 1)
  } // End of func savesThroughTheStore()

  /// A host list file that appeared after launch (Settings saved, say) is never replaced: the
  /// save is refused with nothing written and no backup made, the window says so and stops
  /// editing, and "Open Settings" goes through the app.
  @Test func changedFileIsNotReplaced() async throws {
    let folder = try Support.privateStoreFolder()
    defer { try? FileManager.default.removeItem(at: folder.base) }
    let store = HostStore(fileURL: folder.file)
    let model = OnboardingModel(environment: OnboardingEnvironment(store: store))
    let callbacks = Self.record(model)
    #expect(model.prepare(try await store.load()))
    _ = try await HostStore(fileURL: folder.file).save(HostList([Support.sshHost("Vega")]))
    let before = try Data(contentsOf: folder.file)
    model.setDestination("saturno.example", for: model.drafts[0].id)
    #expect(await model.save() == false)
    #expect(model.fileChanged && model.saveError == OnboardingModel.fileChangedMessage)
    #expect(!model.didSave && !model.isEditable && !model.canSave)
    #expect(try Data(contentsOf: folder.file) == before)
    let names = try FileManager.default.contentsOfDirectory(
      atPath: folder.file.deletingLastPathComponent().path(percentEncoded: false))
    #expect(names == [HostStore.fileName])
    #expect(callbacks.saved.isEmpty && callbacks.closes == 0)
    model.openSettings()
    #expect(callbacks.settingsOpened == 1)
  } // End of func changedFileIsNotReplaced()

  /// Closing the window, or "Not now", writes nothing: no folder or file is created, and the
  /// list still loads as not saved yet (onboarding shows again at the next launch).
  @Test func closingWritesNothing() async throws {
    let folder = try Support.privateStoreFolder()
    defer { try? FileManager.default.removeItem(at: folder.base) }
    let store = HostStore(fileURL: folder.file)
    let model = OnboardingModel(environment: OnboardingEnvironment(store: store))
    let callbacks = Self.record(model)
    #expect(model.prepare(try await store.load()))
    model.windowDidOpen()
    model.setDestination("saturno.example", for: model.drafts[0].id)
    model.chooseThisMac(model.drafts[1].id)
    model.notNow()
    #expect(callbacks.closes == 1 && !model.isWindowOpen)
    #expect(callbacks.saved.isEmpty && !model.didSave)
    let muxFinderFolder = folder.file.deletingLastPathComponent().path(percentEncoded: false)
    #expect(!FileManager.default.fileExists(atPath: muxFinderFolder))
    #expect(try await HostStore(fileURL: folder.file).load().state == .notSavedYet)

    let (fake, fakeStore, _) = try await Self.preparedModel()
    fake.windowDidOpen()
    fake.windowDidClose()
    #expect(fakeStore.saves.isEmpty)
  } // End of func closingWritesNothing()

  /// A list saved in onboarding becomes the engine's list, as one saved in Settings does: the
  /// popover's load status turns saved and the turned-on host is discovered.
  @Test func savedListReachesTheEngine() async throws {
    let discovery = FakeDiscovery()
    let store = FakeHostListStore(Self.examples())
    let environment = AppEnvironment(
      loadHosts: { try await store.load() },
      makeEngine: {
        RefreshCoordinator(
          hosts: $0, discovery: discovery, configuration: UITestSupport.quietConfiguration)
      },
      makeSystemEvents: { _ in nil },
      now: { UITestSupport.now },
      terminate: {},
      settings: Support.environment(store: store))
    let model = AppModel(environment: environment)
    await model.start()
    #expect(model.hostListStatus == .notSavedYet)
    let saturno = try #require(model.onboarding.drafts.first)
    model.onboarding.setDestination("saturno.example", for: saturno.id)
    #expect(model.onboarding.setEnabled(true, for: saturno.id))
    #expect(await model.onboarding.save())
    #expect(model.hostListStatus == .saved)
    #expect(store.saves.count == 1)
    await model.engineRequestsHandled()
    #expect(
      await UITestSupport.waitUntil {
        model.refreshState?.hosts.contains { $0.host.id == saturno.id && $0.isLive } == true
      })
    #expect(discovery.calls(of: saturno.id) >= 1)
    await model.shutdown()
  } // End of func savedListReachesTheEngine()

  // MARK: - Set up SSH in iTerm2…

  /// "Set up SSH in iTerm2…" is offered only for an SSH host with a valid destination (no
  /// leading "-"), goes through the seam with the destination as typed (nothing is saved), is
  /// not sent twice while the tab opens, shows the result honestly (opened, or the failure
  /// with its fix-it), and a changed destination forgets the line; This Mac offers nothing.
  @Test func setsUpSSHForAHostAsTyped() async throws {
    let opener = FakeSSHSetupOpener()
    let (model, store, _) = try await Self.preparedModel(opener: opener)
    let id = model.drafts[0].id
    #expect(!model.canSetUpSSH(id))
    model.setUpSSH(for: id)
    model.setDestination("-oProxyCommand=x", for: id)
    #expect(!model.canSetUpSSH(id))
    model.setUpSSH(for: id)
    #expect(opener.calls.isEmpty)
    model.setDestination("admin@saturno.example", for: id)
    #expect(model.canSetUpSSH(id))
    opener.gate.close()
    model.setUpSSH(for: id)
    #expect(model.sshSetup.states[id] == .opening && !model.canSetUpSSH(id))
    model.setUpSSH(for: id)
    await opener.gate.waitForArrivals(1)
    opener.gate.open()
    await model.sshSetup.requestsFinished()
    #expect(model.sshSetup.states[id] == .opened)
    #expect(opener.calls.map(\.sshDestination) == ["admin@saturno.example"])
    #expect(opener.calls.first?.id == id && opener.calls.first?.mode == .ssh)
    #expect(store.saves.isEmpty)
    #expect(SSHSetupState.opened.message.contains("opened a new window running ssh"))

    opener.answer(.failed(.iTerm2(.apiDisabled)))
    model.setUpSSH(for: id)
    await model.sshSetup.requestsFinished()
    let failed = try #require(model.sshSetup.states[id])
    #expect(failed == .failed(.iTerm2(.apiDisabled)) && failed.isProblem)
    #expect(failed.fixIt == .explainPythonAPI)
    #expect(failed.message.hasPrefix("muxFinder couldn't open ssh in iTerm2."))
    model.setDestination("saturno.example", for: id)
    #expect(model.sshSetup.states[id] == nil)
    model.chooseThisMac(id)
    #expect(!model.canSetUpSSH(id))
    #expect(opener.calls.count == 2)
  } // End of func setsUpSSHForAHostAsTyped()

  /// Closing the window cancels a request still running (the real launcher then withdraws its
  /// request, so no tab opens) and forgets the line; quitting does too and waits for it.
  @Test func closingCancelsARunningRequest() async throws {
    let opener = FakeSSHSetupOpener()
    let (model, _, _) = try await Self.preparedModel(opener: opener)
    let id = model.drafts[0].id
    model.windowDidOpen()
    model.setDestination("saturno.example", for: id)
    opener.gate.close()
    model.setUpSSH(for: id)
    await opener.gate.waitForArrivals(1)
    model.windowDidClose()
    #expect(model.sshSetup.states.isEmpty)
    #expect(await UITestSupport.waitUntil { opener.gate.cancellations == 1 })

    model.setUpSSH(for: id)
    await opener.gate.waitForArrivals(2)
    await model.shutdown()
    #expect(opener.gate.cancellations == 2)
    model.setUpSSH(for: id)
    #expect(opener.calls.count == 2)
    opener.gate.open()
  } // End of func closingCancelsARunningRequest()

  /// A request a closed window cancelled may go on (once `CreateTab` was sent, the launcher
  /// waits for iTerm2's answer whatever its caller): quitting still waits for it, for the
  /// onboarding window and Settings alike, and its late result is never shown. The gate opens
  /// only from a task queued after the one that quits, so quitting has begun by then.
  @Test func quittingWaitsForRequestsOfAClosedWindow() async throws {
    let opener = FakeSSHSetupOpener(stopsWhenCancelled: false)
    let (onboarding, _, _) = try await Self.preparedModel(opener: opener)
    let id = onboarding.drafts[0].id
    onboarding.windowDidOpen()
    onboarding.setDestination("saturno.example", for: id)
    let saturno = Support.sshHost("Saturno")
    let settings = SettingsModel(
      environment: Support.environment(
        store: FakeHostListStore(Support.loaded([saturno])), sshSetup: opener))
    await settings.windowDidOpen()
    opener.gate.close()
    onboarding.setUpSSH(for: id)
    settings.setUpSSH()
    await opener.gate.waitForArrivals(2)
    onboarding.windowDidClose()
    settings.windowDidClose()
    #expect(onboarding.sshSetup.states.isEmpty && settings.sshSetup.states.isEmpty)

    let quit = Task {
      await onboarding.shutdown()
      await settings.shutdown()
      return opener.finishedCalls
    }
    let release = Task { opener.gate.open() }
    let finishedWhenQuit = await quit.value
    #expect(finishedWhenQuit == 2)
    await release.value
    #expect(opener.cancelledCalls == 2)
    #expect(onboarding.sshSetup.states.isEmpty && settings.sshSetup.states.isEmpty)
  } // End of func quittingWaitsForRequestsOfAClosedWindow()

  /// A result that arrives after the host's destination or mode changed belongs to the old
  /// values: it is never shown, in the onboarding window and in Settings alike. The edit
  /// forgets the line at once, so the new destination can be set up while the old request
  /// still runs.
  @Test func editsDropAPendingResult() async throws {
    let opener = FakeSSHSetupOpener()
    let (onboarding, store, _) = try await Self.preparedModel(opener: opener)
    let ids = onboarding.drafts.map(\.id)
    onboarding.setDestination("saturno.example", for: ids[0])
    onboarding.setDestination("sirio.example", for: ids[2])
    opener.gate.close()
    onboarding.setUpSSH(for: ids[0])
    await opener.gate.waitForArrivals(1)
    onboarding.setUpSSH(for: ids[2])
    await opener.gate.waitForArrivals(2)
    onboarding.setDestination("admin@saturno.example", for: ids[0])
    onboarding.chooseThisMac(ids[2])
    #expect(onboarding.sshSetup.states.isEmpty && onboarding.canSetUpSSH(ids[0]))
    opener.gate.open()
    await onboarding.sshSetup.requestsFinished()
    #expect(onboarding.sshSetup.states.isEmpty)
    onboarding.setUpSSH(for: ids[0])
    await onboarding.sshSetup.requestsFinished()
    #expect(onboarding.sshSetup.states == [ids[0]: .opened])
    #expect(
      opener.calls.map(\.sshDestination)
        == ["saturno.example", "sirio.example", "admin@saturno.example"])

    let saturno = Support.sshHost("Saturno")
    let settings = SettingsModel(
      environment: Support.environment(
        store: FakeHostListStore(Support.loaded([saturno])), sshSetup: opener))
    await settings.windowDidOpen()
    opener.gate.close()
    settings.setUpSSH()
    await opener.gate.waitForArrivals(4)
    settings.setDestination("admin@saturno.example")
    #expect(settings.sshSetup.states[saturno.id] == nil && settings.canSetUpSSH)
    opener.gate.open()
    await settings.sshSetup.requestsFinished()
    #expect(settings.sshSetup.states[saturno.id] == nil)
    #expect(store.saves.isEmpty)
  } // End of func editsDropAPendingResult()

  /// The popover offers "Set up SSH in iTerm2 first" next to a sign-in or host key problem on
  /// an SSH host, never for an unreachable host or This Mac; the action goes through the seam
  /// with the host as the engine has it, shows its line, and Retry forgets it.
  @Test func popoverOffersSSHSetupForSignInAndHostKeyProblems() async {
    let saturno = Support.sshHost("Saturno")
    let sirio = Support.sshHost("Sirio")
    let vega = Support.sshHost("Vega")
    let neptuno = UITestSupport.localHost()
    let discovery = FakeDiscovery()
    discovery.setStatus(.authFailed, for: saturno.id)
    discovery.setStatus(.hostKeyProblem(.unknown), for: sirio.id)
    discovery.setStatus(.unreachable(.timeout), for: vega.id)
    let store = FakeHostListStore(Support.loaded([saturno, sirio, vega, neptuno]))
    let opener = FakeSSHSetupOpener()
    let environment = AppEnvironment(
      loadHosts: { try await store.load() },
      makeEngine: {
        RefreshCoordinator(
          hosts: $0, discovery: discovery, configuration: UITestSupport.quietConfiguration)
      },
      makeSystemEvents: { _ in nil },
      now: { UITestSupport.now },
      terminate: {},
      settings: Support.environment(store: store, sshSetup: opener))
    let model = AppModel(environment: environment)
    await model.start()
    #expect(
      await UITestSupport.waitUntil {
        model.refreshState?.hosts.allSatisfy { $0.lastOutcome != nil } == true
      })
    let offers = Dictionary(
      uniqueKeysWithValues: model.content.sections.map { ($0.id, $0.offersSSHSetup) })
    #expect(offers == [saturno.id: true, sirio.id: true, vega.id: false, neptuno.id: false])
    model.setUpSSH(hostID: neptuno.id)
    model.setUpSSH(hostID: saturno.id)
    await model.sshSetup.requestsFinished()
    #expect(opener.calls == [saturno])
    #expect(model.content.sections.first { $0.id == saturno.id }?.sshSetup == .opened)
    model.retry(hostID: saturno.id)
    #expect(model.content.sections.first { $0.id == saturno.id }?.sshSetup == nil)
    await model.shutdown()
  } // End of func popoverOffersSSHSetupForSignInAndHostKeyProblems()

  /// The popover's content offers the action for the fixtures' sign-in and host key problems
  /// only, and shows a host's line only where the action is offered.
  @Test func popoverContentOffersSSHSetup() {
    let fixture = PreviewFixtures.hostProblems
    let states: [UUID: SSHSetupState] = [
      PreviewFixtures.saturno.id: .opened, PreviewFixtures.neptuno.id: .opening,
    ]
    let content = PopoverContent(
      state: fixture.state, hostList: .saved, query: "", activities: [:], selection: nil,
      now: PreviewFixtures.now, sshSetupStates: states)
    let sections = Dictionary(uniqueKeysWithValues: content.sections.map { ($0.id, $0) })
    #expect(sections[PreviewFixtures.saturno.id]?.offersSSHSetup == true)
    #expect(sections[PreviewFixtures.saturno.id]?.sshSetup == .opened)
    #expect(sections[PreviewFixtures.sirio.id]?.offersSSHSetup == true)
    #expect(sections[PreviewFixtures.sirio.id]?.sshSetup == nil)
    #expect(sections[PreviewFixtures.neptuno.id]?.offersSSHSetup == false)
    #expect(sections[PreviewFixtures.neptuno.id]?.sshSetup == nil)
    let overview = PopoverContent(
      state: PreviewFixtures.overview.state, hostList: .saved, query: "", activities: [:],
      selection: nil, now: PreviewFixtures.now)
    #expect(overview.sections.allSatisfy { !$0.offersSSHSetup })
    let model = AppModel(fixture: fixture)
    #expect(
      model.content.sections.first { $0.id == PreviewFixtures.saturno.id }?.sshSetup == .opened)
  } // End of func popoverContentOffersSSHSetup()

  /// The Settings editor offers the action for an SSH host with a valid destination (saved or
  /// not), with the destination as typed; next to a connection test that needed a sign-in or
  /// had a host key problem, not after other results; never for This Mac; a changed
  /// destination forgets its line and closing the window cancels a running request.
  @Test func settingsOffersSSHSetup() async throws {
    let opener = FakeSSHSetupOpener()
    let discovery = ScriptedDiscovery()
    let saturno = Support.sshHost("Saturno")
    let neptuno = UITestSupport.localHost()
    let store = FakeHostListStore(Support.loaded([saturno, neptuno]))
    let model = SettingsModel(
      environment: Support.environment(store: store, discovery: discovery, sshSetup: opener))
    await model.windowDidOpen()
    #expect(model.draft?.id == saturno.id && model.canSetUpSSH)
    model.setUpSSH()
    await model.sshSetup.requestsFinished()
    #expect(opener.calls.map(\.sshDestination) == ["saturno.example"])
    #expect(model.sshSetup.states[saturno.id] == .opened)
    model.setDestination("admin@saturno.example")
    #expect(model.sshSetup.states[saturno.id] == nil)
    model.setUpSSH()
    await model.sshSetup.requestsFinished()
    #expect(opener.calls.last?.sshDestination == "admin@saturno.example")
    #expect(store.saves.isEmpty)

    #expect(!model.connectionTestOffersSSHSetup)
    discovery.answer(.authFailed, report: nil)
    model.testConnection()
    await model.probesFinished()
    #expect(model.connectionTestOffersSSHSetup)
    discovery.answer(.hostKeyProblem(.changed), report: nil)
    model.testConnection()
    await model.probesFinished()
    #expect(model.connectionTestOffersSSHSetup)
    discovery.answer(.unreachable(.refused), report: nil)
    model.testConnection()
    await model.probesFinished()
    #expect(!model.connectionTestOffersSSHSetup)

    model.revert()
    model.select(.host(neptuno.id))
    #expect(model.draft?.id == neptuno.id && !model.canSetUpSSH)
    model.select(.host(saturno.id))
    opener.gate.close()
    model.setUpSSH()
    await opener.gate.waitForArrivals(3)
    model.windowDidClose()
    #expect(model.sshSetup.states.isEmpty)
    #expect(await UITestSupport.waitUntil { opener.gate.cancellations == 1 })
    opener.gate.open()
  } // End of func settingsOffersSSHSetup()

  // MARK: - Fixtures and options

  /// `--preview-gallery onboarding` picks the onboarding gallery (the other galleries still
  /// parse); the fixtures have unique ids, only `*.example` destinations, and never save.
  @Test func galleryOptionAndFixtures() async {
    #expect(
      AppLaunchOptions(arguments: ["--preview-fixtures", "--preview-gallery", "onboarding"])
        .previewGallery == .onboarding)
    #expect(
      AppLaunchOptions(arguments: ["--preview-gallery=ONBOARDING"]).previewGallery == .onboarding)
    #expect(
      AppLaunchOptions(arguments: ["--preview-gallery", "settings"]).previewGallery == .settings)
    #expect(AppLaunchOptions(arguments: []).previewGallery == .popover)
    let fixtures = OnboardingFixtures.all
    #expect(Set(fixtures.map(\.id)).count == fixtures.count)
    for fixture in fixtures {
      #expect(fixture.drafts.count == 3)
      for draft in fixture.drafts where !draft.sshDestination.isEmpty {
        #expect(draft.sshDestination.hasSuffix(".example"), "\(fixture.id)")
      }
      let model = OnboardingModel(fixture: fixture)
      #expect(model.isPreview && model.isPrepared)
      #expect(await model.save() == false)
    }
    #expect(OnboardingModel(fixture: OnboardingFixtures.sshSetup).sshSetup.states.count == 2)
    #expect(OnboardingModel(fixture: OnboardingFixtures.fileChanged).fileChanged)
  } // End of func galleryOptionAndFixtures()
}
