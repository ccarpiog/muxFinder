import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// The host editor's persistent-profile fields (PLAN.md D26), pure values.
@Suite("Settings: persistent profile fields")
struct PersistentProfileFieldTests {
  /// The issues of `draft` alone.
  static func issues(_ draft: HostDraft) -> HostDraftIssues {
    HostDraftIssues(draft: draft, otherHosts: [])
  }

  /// A draft of an SSH host with a valid destination.
  static func draft() -> HostDraft {
    HostDraft(SettingsTestSupport.sshHost("Saturno"))
  }

  /// The default session name: empty is `main`; set, it is trimmed and must pass
  /// `Validation.persistentSessionName` (checked whether or not the profile is on, as
  /// `HostList` does); each refusal blocks the draft with the validation's sentence.
  @Test func sessionNameRules() {
    var draft = Self.draft()
    #expect(Self.issues(draft).isValid)
    #expect(draft.config.defaultSessionName == nil)
    draft.persistentProfile.defaultSessionName = "   "
    #expect(Self.issues(draft).isValid)
    #expect(draft.config.defaultSessionName == nil)
    draft.persistentProfile.defaultSessionName = " work "
    #expect(Self.issues(draft).isValid)
    #expect(draft.config.defaultSessionName == "work")
    let refusals: [(String, ValidationError)] = [
      ("$work", .sessionNameStartsWithTargetCharacter),
      ("=main", .sessionNameStartsWithTargetCharacter),
      ("a:b", .sessionNameContainsColonOrPeriod),
      ("-x", .sessionNameStartsWithHyphen),
      ("a\tb", .sessionNameContainsControlCharacter),
      ("a\\b", .sessionNameContainsBackslash),
    ]
    for (name, error) in refusals {
      draft.persistentProfile.defaultSessionName = name
      let issues = Self.issues(draft)
      #expect(issues.defaultSessionName == error.message, "\(name)")
      #expect(!issues.isValid)
      draft.persistentProfile.isEnabled.toggle()
      #expect(Self.issues(draft).defaultSessionName == error.message)
    }
    #expect(
      ValidationError.sessionNameStartsWithTargetCharacter.message.first?.isUppercase == true)
  } // End of func sessionNameRules()

  /// The parent profile: empty is none; typed, it is trimmed and must pass
  /// `Validation.profileName`; a value left exactly as loaded saves back unchanged.
  @Test func parentProfileRules() throws {
    var draft = Self.draft()
    draft.persistentProfile.parentProfileName = " Work "
    #expect(Self.issues(draft).isValid)
    #expect(draft.config.persistentProfileParentName == "Work")
    draft.persistentProfile.parentProfileName = "  "
    #expect(draft.config.persistentProfileParentName == nil)
    draft.persistentProfile.parentProfileName = "Wo\u{1}rk"
    #expect(
      Self.issues(draft).parentProfileName
        == ValidationError.profileNameContainsControlCharacter.message)
    #expect(!Self.issues(draft).isValid)

    var host = SettingsTestSupport.sshHost("Sirio")
    host.persistentProfileParentName = " Base ü "
    _ = try HostList([host])
    var loaded = HostDraft(host)
    #expect(loaded.config == host)
    #expect(Self.issues(loaded).isValid)
    loaded.persistentProfile.parentProfileName = " Base ü  "
    #expect(loaded.config.persistentProfileParentName == "Base ü")
  } // End of func parentProfileRules()

  /// A host without the fields, and one with all of them, give back exactly the same
  /// configuration; the switch is carried as it is.
  @Test func valuesRoundTrip() {
    let without = SettingsTestSupport.sshHost("Saturno")
    #expect(HostDraft(without).config == without)
    let with = HostConfig(
      displayName: "Neptuno", mode: .local, persistentProfileEnabled: true,
      defaultSessionName: "work ü", persistentProfileParentName: "Presentation")
    #expect(HostDraft(with).config == with)
    var draft = HostDraft(with)
    draft.persistentProfile.isEnabled = false
    #expect(draft.config.persistentProfileEnabled == false)
    #expect(draft.config.defaultSessionName == "work ü")
    #expect(!HostDraft.newHost().config.persistentProfileEnabled)
  } // End of func valuesRoundTrip()
}

/// The persistent profile section (PLAN.md D26): the content's rules (pure), the editor's
/// fields through the model, Install, Remove and Check again through a fake seam, the update
/// after a save, the rewrite at launch, the preview fixtures, and the real seam over a private
/// folder. Nothing here writes in iTerm2's `DynamicProfiles`, reads or writes the real
/// `hosts.json`, or contacts iTerm2.
@Suite("Settings: persistent profiles")
@MainActor
struct PersistentProfilesSettingsTests {
  /// Shorthand.
  typealias Support = SettingsTestSupport

  /// This Mac with its profile on.
  static let neptuno = HostConfig(
    displayName: "Neptuno", mode: .local, persistentProfileEnabled: true)
  /// An SSH host with its profile off.
  static let saturno = Support.sshHost("Saturno")

  /// The saved list of `hosts`.
  static func list(_ hosts: [HostConfig]) -> HostList {
    try! HostList(hosts)
  }

  // MARK: - Content

  /// Each status maps to its line, tone and buttons; installs need a saved list with a profile
  /// and a usable status; removal needs muxFinder's own file; a running operation turns every
  /// button off; the draft note only with unsaved changes.
  @Test func contentMapsEveryStatus() {
    let both = Self.list([Self.neptuno, Self.saturno])
    /// The content for `status` with the defaults below (`hosts`: `both` when `nil`).
    func content(
      _ status: PersistentProfileStatus?, saved: Bool = true, dirty: Bool = false,
      running: Bool = false, hosts: HostList? = nil
    ) -> PersistentProfilesContent {
      PersistentProfilesContent(
        status: status, hosts: hosts ?? both, isListSaved: saved, isDirty: dirty,
        isRunning: running, result: nil)
    }
    let checking = content(nil)
    #expect(checking.tone == .checking && !checking.canInstall && !checking.canRemove)
    let none = content(.notInstalled)
    #expect(none.statusText == "Not installed.")
    #expect(none.canInstall && !none.canRemove && none.installNote == nil)
    #expect(none.profileNames == ["Persistent work \u{2013} Neptuno"])
    let current = content(.current)
    #expect(current.statusText == "Installed and up to date." && current.tone == .good)
    #expect(current.canInstall && current.canRemove)
    let stale = content(.stale)
    #expect(stale.statusText.hasPrefix("Installed, but out of date") && stale.tone == .warning)
    #expect(stale.canInstall && stale.canRemove)
    let unsaved = content(.stale, saved: false)
    #expect(unsaved.statusText == "Installed." && unsaved.profileNames.isEmpty)
    #expect(
      !unsaved.canInstall && unsaved.installNote == PersistentProfilesContent.listNotSavedNote)
    #expect(unsaved.canRemove)
    let helper = content(.unavailable(.helper(.unsupportedCharacters), isInstalled: true))
    #expect(helper.tone == .problem && helper.statusText.hasPrefix("Unavailable. iTerm2 can't"))
    #expect(helper.statusText.hasSuffix("The profiles installed before stay as they are."))
    #expect(!helper.canInstall && helper.installNote == PersistentProfilesContent.unavailableNote)
    #expect(helper.canRemove)
    let foreign = content(.unavailable(.installer(.fileNotMuxFinders), isInstalled: false))
    #expect(!foreign.canInstall && !foreign.canRemove && foreign.canCheck)
    #expect(foreign.statusText.contains("doesn't hold muxFinder's profiles"))
    let nothing = content(.notInstalled, hosts: Self.list([Self.saturno]))
    #expect(!nothing.canInstall && nothing.installNote == PersistentProfilesContent.noProfilesNote)
    let running = content(.current, running: true)
    #expect(!running.canInstall && !running.canRemove && !running.canCheck && running.isRunning)
    #expect(
      content(.notInstalled, dirty: true).draftNote == PersistentProfilesContent.draftNoteText)
    #expect(content(.notInstalled).draftNote == nil)
  } // End of func contentMapsEveryStatus()

  /// Every result line is a distinct sentence, failures say so, and automatic updates that
  /// changed nothing (or found no file to update) show nothing.
  @Test func resultLines() {
    let changes: [PersistentProfileChange] = [
      .installed(count: 1), .installed(count: 2), .unchanged, .removed, .nothingToRemove,
      .failed(.installer(.busy)),
    ]
    var texts: [String] = []
    for trigger in [PersistentProfileResult.Trigger.user, .save, .launch] {
      for change in changes {
        let result = PersistentProfileResult(change, trigger: trigger)
        #expect(result.isProblem == change.isFailure)
        guard let text = result.text else {
          #expect(trigger != .user)
          continue
        }
        #expect(text.hasSuffix("."))
        #expect(text.first?.isUppercase == true || text.hasPrefix("muxFinder"))
        texts.append(text)
      }
    }
    // 6 lines for the user's actions; 3 each for a save and the launch (any count reads the
    // same there).
    #expect(texts.count == 14 && Set(texts).count == 12)
    #expect(
      PersistentProfileResult(.installed(count: 1), trigger: .user).text
        == "Installed 1 profile in iTerm2.")
    #expect(PersistentProfileResult(.unchanged, trigger: .save).text == nil)
    #expect(PersistentProfileResult(.unchanged, trigger: .launch).text == nil)
    // An update that found no file (automatic updates only) changed nothing: no line.
    for trigger in [PersistentProfileResult.Trigger.user, .save, .launch] {
      #expect(PersistentProfileResult(.notInstalled, trigger: trigger).text == nil)
    }
    let busy = PersistentProfileInstallerError.busy.message
    #expect(PersistentProfileResult(.failed(.installer(.busy)), trigger: .user).text == busy)
    #expect(
      PersistentProfileResult(.failed(.installer(.busy)), trigger: .launch).text?.hasSuffix(busy)
        == true)
  } // End of func resultLines()

  // MARK: - Editor

  /// The editor's fields: an invalid session name blocks Save with an inline sentence and
  /// writes nothing; valid values save, the draft shows them afterwards, and a parent iTerm2
  /// does not list is a warning only.
  @Test func editorSavesProfileFields() async throws {
    let (model, store) = await Support.openModel([Self.saturno])
    model.setPersistentProfileEnabled(true)
    model.setDefaultSessionName("$work")
    #expect(model.issues?.defaultSessionName != nil)
    #expect(!model.canSave)
    #expect(await model.save() == false)
    #expect(store.saves.isEmpty)
    model.setDefaultSessionName(" work ")
    model.setParentProfileName("Missing")
    #expect(model.parentProfileWarning != nil)
    #expect(model.issues?.isValid == true)
    model.setParentProfileName("Work")
    #expect(model.parentProfileWarning == nil)
    #expect(await model.save())
    let saved = try #require(store.saves.last?.hosts.first)
    #expect(saved.persistentProfileEnabled)
    #expect(saved.defaultSessionName == "work")
    #expect(saved.persistentProfileParentName == "Work")
    #expect(model.draft?.persistentProfile.defaultSessionName == "work")
    #expect(!model.isDirty)
  } // End of func editorSavesProfileFields()

  /// Through a real `HostStore` in a private folder: a host without the fields and one with
  /// them save back byte for byte after an edit and its undo (two saves).
  @Test func valuesSaveBackByteForByte() async throws {
    let folder = try Support.privateStoreFolder()
    defer { try? FileManager.default.removeItem(at: folder.base) }
    let with = HostConfig(
      displayName: "Neptuno", mode: .local, persistentProfileEnabled: true,
      defaultSessionName: "work", persistentProfileParentName: " Base ")
    let store = HostStore(fileURL: folder.file)
    _ = try await store.save(Self.list([Self.saturno, with]))
    let original = try Data(contentsOf: folder.file)
    let text = String(decoding: original, as: UTF8.self)
    #expect(text.components(separatedBy: "persistentProfileEnabled").count == 2)
    let model = SettingsModel(environment: Support.environment(store: store))
    await model.windowDidOpen()
    for host in [Self.saturno, with] {
      model.select(.host(host.id))
      model.setTmuxPath("/opt/homebrew/bin/tmux")
      #expect(await model.save())
      #expect(try Data(contentsOf: folder.file) != original)
      model.setTmuxPath("")
      #expect(await model.save())
    }
    #expect(try Data(contentsOf: folder.file) == original)
  } // End of func valuesSaveBackByteForByte()

  // MARK: - Install, remove, check

  /// Install uses the saved list, never the draft (the tab says so while it is dirty); Remove
  /// is offered only while muxFinder's file is installed; results and statuses follow.
  @Test func installAndRemoveThroughTheSeam() async {
    let files = FakeProfileFiles()
    let (model, _) = await Support.openModel([Self.neptuno, Self.saturno], profileFiles: files)
    #expect(model.profileStatus == .notInstalled)
    #expect(files.statusCalls.count == 1)
    let saved = model.hosts
    model.select(.host(Self.saturno.id))
    model.setPersistentProfileEnabled(true)
    #expect(model.persistentProfilesContent.draftNote != nil)
    #expect(model.persistentProfilesContent.canInstall)
    await model.installProfiles()
    #expect(files.installCalls == [saved])
    #expect(model.profileResult == PersistentProfileResult(.installed(count: 1), trigger: .user))
    #expect(model.persistentProfilesContent.resultText == "Installed 1 profile in iTerm2.")
    #expect(model.profileStatus == .current)
    #expect(files.installed == files.document(for: saved)?.data)
    await model.installProfiles()
    #expect(model.persistentProfilesContent.resultText?.contains("already up to date") == true)
    #expect(model.persistentProfilesContent.canRemove)
    await model.removeProfiles()
    #expect(files.removeCalls == 1)
    #expect(model.profileResult == PersistentProfileResult(.removed, trigger: .user))
    #expect(model.profileStatus == .notInstalled)
    #expect(!model.persistentProfilesContent.canRemove)
    await model.removeProfiles()
    #expect(files.removeCalls == 1)
    model.revert()
    await model.checkProfiles()
    #expect(files.statusCalls.allSatisfy { $0 == saved })
  } // End of func installAndRemoveThroughTheSeam()

  /// Install stays off (and calls nothing) with no saved host's profile on, an unusable helper
  /// path (Remove still offered for an installed file), a file of the user's, or a host list
  /// that is not saved.
  @Test func installDisabledStates() async {
    let none = FakeProfileFiles()
    let (model, _) = await Support.openModel([Self.saturno], profileFiles: none)
    #expect(model.persistentProfilesContent.installNote == PersistentProfilesContent.noProfilesNote)
    await model.installProfiles()
    #expect(none.installCalls.isEmpty)

    let broken = FakeProfileFiles()
    broken.preinstall(Self.list([Self.neptuno]))
    broken.breakHelper(.unsupportedCharacters)
    let (helperModel, _) = await Support.openModel([Self.neptuno], profileFiles: broken)
    #expect(
      helperModel.profileStatus == .unavailable(.helper(.unsupportedCharacters), isInstalled: true))
    #expect(!helperModel.persistentProfilesContent.canInstall)
    await helperModel.installProfiles()
    #expect(broken.installCalls.isEmpty)
    #expect(helperModel.persistentProfilesContent.canRemove)
    await helperModel.removeProfiles()
    #expect(broken.installed == nil)

    let foreign = FakeProfileFiles()
    foreign.placeForeignFile()
    let (foreignModel, _) = await Support.openModel([Self.neptuno], profileFiles: foreign)
    #expect(
      foreignModel.profileStatus
        == .unavailable(.installer(.fileNotMuxFinders), isInstalled: false))
    await foreignModel.installProfiles()
    await foreignModel.removeProfiles()
    #expect(foreign.writeCalls == 0)

    let examples = FakeProfileFiles()
    let (examplesModel, _) = await Support.openModel(
      [Self.neptuno], state: .notSavedYet, profileFiles: examples)
    #expect(!examplesModel.persistentProfilesContent.canInstall)
    #expect(
      examplesModel.persistentProfilesContent.installNote
        == PersistentProfilesContent.listNotSavedNote)
    #expect(examples.statusCalls == [HostList()])
  } // End of func installDisabledStates()

  /// A busy lock and a refusal are shown as failures and change nothing; the main actor stays
  /// free while an install waits (the buttons are off meanwhile).
  @Test func failuresAndWaitingInstalls() async {
    let files = FakeProfileFiles()
    let (model, _) = await Support.openModel([Self.neptuno], profileFiles: files)
    files.failWrites(with: .busy)
    await model.installProfiles()
    #expect(model.persistentProfilesContent.resultIsProblem)
    #expect(
      model.persistentProfilesContent.resultText == PersistentProfileInstallerError.busy.message)
    #expect(model.profileStatus == .notInstalled)
    files.failWrites(with: nil)

    files.holdInstalls()
    let install = Task { await model.installProfiles() }
    await files.waitForInstalls(2)
    #expect(model.profileOperations == 1)
    #expect(!model.persistentProfilesContent.canInstall)
    #expect(!model.persistentProfilesContent.canCheck)
    model.setDisplayName("Neptuno 2") // the main actor is not blocked
    #expect(model.isDirty)
    files.releaseInstalls()
    await install.value
    #expect(model.profileOperations == 0)
    #expect(model.profileStatus == .current)
  } // End of func failuresAndWaitingInstalls()

  // MARK: - After a save

  /// A save while muxFinder's file is installed updates it (a rename changes a profile's
  /// name) through `update(_:)`, never `install(_:)`, and turning off the last profile removes
  /// it; with no file installed a save writes nothing.
  @Test func saveWhileInstalledUpdatesTheFile() async throws {
    let files = FakeProfileFiles()
    files.preinstall(Self.list([Self.neptuno, Self.saturno]))
    let (model, store) = await Support.openModel([Self.neptuno, Self.saturno], profileFiles: files)
    #expect(model.profileStatus == .current)
    model.select(.host(Self.neptuno.id))
    model.setTmuxPath("/opt/homebrew/bin/tmux")
    #expect(await model.save())
    await model.profileOperationsFinished()
    #expect(files.writeCalls == 0) // the document did not change
    model.setDisplayName("Neptuno M4")
    #expect(await model.save())
    await model.profileOperationsFinished()
    let renamed = try #require(store.saves.last)
    #expect(files.updateCalls == [renamed])
    #expect(files.installCalls.isEmpty)
    #expect(files.installed == files.document(for: renamed)?.data)
    #expect(model.profileResult == PersistentProfileResult(.installed(count: 1), trigger: .save))
    #expect(model.profileStatus == .current)
    model.setPersistentProfileEnabled(false)
    #expect(await model.save())
    await model.profileOperationsFinished()
    #expect(files.installed == nil)
    #expect(model.profileResult == PersistentProfileResult(.removed, trigger: .save))
    #expect(model.profileStatus == .notInstalled)

    let fresh = FakeProfileFiles()
    let (other, _) = await Support.openModel([Self.neptuno], profileFiles: fresh)
    other.setDisplayName("Neptuno M4")
    #expect(await other.save())
    await other.profileOperationsFinished()
    #expect(fresh.writeCalls == 0)
    #expect(other.profileStatus == .notInstalled)
  } // End of func saveWhileInstalledUpdatesTheFile()

  /// Review of Phase 11c: a save's profile update held at its status check while Settings
  /// closes and reopens (the host list loading meanwhile, which reads as no host at all)
  /// updates the file to the list that save wrote, never to an empty document (which would
  /// remove the installed profiles); the reopened window's check then shows it current.
  @Test func reloadDuringASaveUpdateKeepsTheSavedList() async throws {
    let files = FakeProfileFiles()
    files.preinstall(Self.list([Self.neptuno, Self.saturno]))
    let (model, store) = await Support.openModel([Self.neptuno, Self.saturno], profileFiles: files)
    #expect(model.profileStatus == .current)
    model.select(.host(Self.neptuno.id))
    model.setDisplayName("Neptuno M4")
    files.holdStatusChecks()
    #expect(await model.save())
    let renamed = try #require(store.saves.last)
    await files.waitForStatusChecks(2) // the opening's check, then the save's, held
    model.windowDidClose()
    store.holdLoads()
    let reopening = Task { await model.windowDidOpen() }
    await store.waitForLoadCalls(2)
    #expect(model.hostListStatus == nil)
    #expect(model.profileHosts.hosts.isEmpty) // what the live list reads as while loading
    files.releaseStatusChecks()
    await model.profileOperationsFinished()
    #expect(files.updateCalls == [renamed])
    #expect(files.installCalls.isEmpty && files.removeCalls == 0)
    #expect(files.installed == files.document(for: renamed)?.data)
    #expect(files.statusCalls.allSatisfy { !$0.hosts.isEmpty })
    #expect(model.profileResult == PersistentProfileResult(.installed(count: 1), trigger: .save))
    store.releaseLoads()
    await reopening.value
    await model.profileOperationsFinished()
    #expect(model.hostListStatus == .saved)
    #expect(model.profileStatus == .current)
    #expect(files.statusCalls.last == renamed)
  } // End of func reloadDuringASaveUpdateKeepsTheSavedList()

  /// "Check again" while the host list loads does nothing (the opening checks once it has
  /// loaded); an install held while the list reloads checks the status afterwards for the list
  /// it installed, never for the loading list's none.
  @Test func operationsKeepTheirHostList() async throws {
    let saved = Self.list([Self.neptuno])
    let files = FakeProfileFiles()
    files.preinstall(saved)
    let (model, store) = await Support.openModel([Self.neptuno], profileFiles: files)
    #expect(files.statusCalls == [saved])
    store.holdLoads()
    let reload = Task { await model.reloadHosts() }
    await store.waitForLoadCalls(2)
    #expect(model.hostListStatus == nil)
    await model.checkProfiles()
    await model.profileOperationsFinished()
    #expect(files.statusCalls == [saved])
    #expect(model.profileStatus == .current)
    store.releaseLoads()
    await reload.value
    await model.checkProfiles()
    #expect(files.statusCalls == [saved, saved])

    files.holdInstalls()
    let install = Task { await model.installProfiles() }
    await files.waitForInstalls(1)
    store.holdLoads()
    let again = Task { await model.reloadHosts() }
    await store.waitForLoadCalls(3)
    files.releaseInstalls()
    await install.value
    #expect(files.installCalls == [saved])
    #expect(files.statusCalls == [saved, saved, saved])
    #expect(model.profileStatus == .current)
    store.releaseLoads()
    await again.value
  } // End of func operationsKeepTheirHostList()

  // MARK: - At launch

  /// An app model over a store loading `hosts` (as `state`) and `files`, rewriting at launch
  /// when `rewrites`.
  static func appModel(
    _ hosts: [HostConfig], state: HostStoreLoadResult.State = .saved,
    files: FakeProfileFiles, rewrites: Bool = true, diagnostics: DiagnosticsLog
  ) -> AppModel {
    let store = FakeHostListStore(Support.loaded(hosts, state: state))
    let environment = AppEnvironment(
      loadHosts: { try await store.load() },
      makeEngine: {
        RefreshCoordinator(
          hosts: $0, discovery: FakeDiscovery(), configuration: UITestSupport.quietConfiguration)
      },
      makeSystemEvents: { _ in nil },
      now: { UITestSupport.now },
      terminate: {},
      settings: Support.environment(
        store: store, diagnostics: diagnostics, profileFiles: files),
      diagnostics: diagnostics,
      rewritesProfilesAtLaunch: rewrites)
    return AppModel(environment: environment)
  } // End of static func appModel(_:state:files:rewrites:diagnostics:)

  /// Starts `model`, waits for its profile work, and shuts it down.
  static func run(_ model: AppModel) async {
    await model.start()
    await model.settings.profileOperationsFinished()
    await model.shutdown()
  }

  /// At launch: an out-of-date installed file (the helper moved) is installed again for the
  /// loaded list; a missing or current file, or an unusable helper, writes nothing; a list
  /// not loaded as `saved`, or a launch that does not rewrite, never asks the seam. The log
  /// holds kinds only.
  @Test func launchRewriteDecisions() async {
    let hosts = [Self.neptuno, Self.saturno]
    let log = DiagnosticsLog(writesToSystemLog: false, now: { UITestSupport.now })

    let stale = FakeProfileFiles()
    stale.preinstall(Self.list(hosts))
    stale.moveHelper(to: "/Users/tester/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch")
    let staleModel = Self.appModel(hosts, files: stale, diagnostics: log)
    await Self.run(staleModel)
    #expect(stale.updateCalls == [Self.list(hosts)])
    #expect(stale.installCalls.isEmpty)
    #expect(stale.installed == stale.document(for: Self.list(hosts))?.data)
    #expect(
      staleModel.settings.profileResult
        == PersistentProfileResult(.installed(count: 1), trigger: .launch))

    for setUp in [
      { (_: FakeProfileFiles) in },
      { (files: FakeProfileFiles) in files.preinstall(Self.list(hosts)) },
      { (files: FakeProfileFiles) in
        files.preinstall(Self.list(hosts))
        files.breakHelper(.unsupportedCharacters)
      },
    ] {
      let files = FakeProfileFiles()
      setUp(files)
      let before = files.installed
      let model = Self.appModel(hosts, files: files, diagnostics: log)
      await Self.run(model)
      #expect(files.statusCalls.count == 1)
      #expect(files.writeCalls == 0)
      #expect(files.installed == before)
      #expect(model.settings.profileResult == nil)
    }

    for (state, rewrites) in [
      (HostStoreLoadResult.State.notSavedYet, true), (.invalid(.notJSON), true), (.saved, false),
    ] {
      let files = FakeProfileFiles()
      files.preinstall(Self.list(hosts))
      files.moveHelper(to: "/tmp/elsewhere/muxfinder-launch")
      let model = Self.appModel(
        hosts, state: state, files: files, rewrites: rewrites, diagnostics: log)
      await Self.run(model)
      #expect(files.statusCalls.isEmpty)
      #expect(files.writeCalls == 0)
    }

    let profileEvents = await log.events().filter { $0.category == .profiles }
    #expect(
      profileEvents.map(\.detail) == [
        "profiles at launch: stale, installed", "profiles at launch: notInstalled",
        "profiles at launch: current",
        "profiles at launch: unavailable.helper.unsupportedCharacters",
      ])
    #expect(profileEvents.allSatisfy { !$0.detail.contains("Neptuno") && !$0.detail.contains("/") })
  } // End of func launchRewriteDecisions()

  /// Review of Phase 11c: when the file goes (the user, or another muxFinder) after an
  /// automatic update read it as out of date, the update creates nothing, at launch and after a
  /// save: it goes through `update(_:)`, whose check and write are one step.
  @Test func automaticUpdatesNeverRecreateARemovedFile() async throws {
    let hosts = [Self.neptuno, Self.saturno]
    let log = DiagnosticsLog(writesToSystemLog: false, now: { UITestSupport.now })
    let files = FakeProfileFiles()
    files.preinstall(Self.list(hosts))
    files.moveHelper(to: "/Users/tester/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch")
    files.holdStatusChecks()
    let app = Self.appModel(hosts, files: files, diagnostics: log)
    await app.start()
    await files.waitForStatusChecks(1)
    files.deleteFile()
    files.releaseStatusChecks()
    await app.settings.profileOperationsFinished()
    await app.shutdown()
    #expect(files.updateCalls == [Self.list(hosts)])
    #expect(files.installCalls.isEmpty)
    #expect(files.installed == nil)
    #expect(app.settings.profileResult?.text == nil)
    let details = await log.events().filter { $0.category == .profiles }.map(\.detail)
    #expect(details == ["profiles at launch: stale, notInstalled"])

    let saveFiles = FakeProfileFiles()
    saveFiles.preinstall(Self.list([Self.neptuno]))
    let (model, store) = await Support.openModel([Self.neptuno], profileFiles: saveFiles)
    model.setDisplayName("Neptuno M4")
    saveFiles.holdStatusChecks()
    #expect(await model.save())
    await saveFiles.waitForStatusChecks(2) // the opening's check, then the save's, held
    saveFiles.deleteFile()
    saveFiles.releaseStatusChecks()
    await model.profileOperationsFinished()
    #expect(saveFiles.updateCalls == [try #require(store.saves.last)])
    #expect(saveFiles.installCalls.isEmpty)
    #expect(saveFiles.installed == nil)
    #expect(model.profileStatus == .notInstalled)
    #expect(model.profileResult == nil)
  } // End of func automaticUpdatesNeverRecreateARemovedFile()

  /// Only normal mode rewrites at launch: never the preview window, a self-test, either report,
  /// the profile removal or unusable arguments.
  @Test func onlyNormalModeRewritesAtLaunch() {
    #expect(AppLaunchOptions(arguments: []).rewritesProfilesAtLaunch)
    #expect(AppLaunchOptions(arguments: ["--appearance", "dark"]).rewritesProfilesAtLaunch)
    for arguments in [
      ["--preview-fixtures"], ["--preview-fixtures", "--preview-gallery", "settings"],
      ["--selftest", "attach-local"], ["--selftest", "new-session-local", "--selftest-keep"],
      ["--report-login-item-status"], ["--report-menu-bar-item"], ["--selftest-keep"],
      ["--selftest", "nope"], ["--remove-persistent-profiles"],
      ["--remove-persistent-profiles", "--dry-run"], ["--report-popover-placement"],
    ] {
      #expect(!AppLaunchOptions(arguments: arguments).rewritesProfilesAtLaunch, "\(arguments)")
    }
    let environment = UITestSupport.environment(load: { Support.loaded([]) })
    #expect(!environment.rewritesProfilesAtLaunch)
  } // End of func onlyNormalModeRewritesAtLaunch()

  /// Shutting down skips queued profile work and refuses new work.
  @Test func shutdownStopsProfileWork() async {
    let files = FakeProfileFiles()
    let (model, _) = await Support.openModel([Self.neptuno], profileFiles: files)
    await model.shutdown()
    await model.installProfiles()
    await model.checkProfiles()
    #expect(model.keepProfilesCurrentAtLaunch(Self.list([Self.neptuno])) == nil)
    #expect(files.writeCalls == 0)
    #expect(files.statusCalls.count == 1)
  }

  // MARK: - Previews

  /// The preview fixtures cover every status, a result and a failure, and the profile fields
  /// with an error; their models have no environment, so no action reaches any installer: the
  /// state stays exactly the fixture's.
  @Test func previewsNeverTouchAnInstaller() async {
    let all = SettingsFixtures.all
    let statuses = all.filter { $0.tab == .profiles }.compactMap(\.profileStatus)
    #expect(statuses.contains(.notInstalled) && statuses.contains(.current))
    #expect(statuses.contains(.stale))
    #expect(statuses.contains { if case .unavailable = $0 { true } else { false } })
    #expect(all.contains { $0.profileResult?.isProblem == true })
    #expect(all.contains { $0.profileResult?.isProblem == false })
    let editor = SettingsModel(fixture: SettingsFixtures.profileEditor)
    #expect(editor.issues?.defaultSessionName != nil)
    #expect(editor.draft?.persistentProfile.isEnabled == true)
    for fixture in all {
      let model = SettingsModel(fixture: fixture)
      #expect(model.isPreview && model.environment == nil)
      await model.checkProfiles()
      await model.installProfiles()
      await model.removeProfiles()
      #expect(model.keepProfilesCurrentAtLaunch(fixture.hosts) == nil)
      model.setPersistentProfileEnabled(true)
      _ = await model.save()
      await model.profileOperationsFinished()
      #expect(model.profileStatus == fixture.profileStatus)
      #expect(model.profileResult == fixture.profileResult)
      #expect(model.profileOperations == 0)
    }
    for fixture in PreviewFixtures.all {
      let model = AppModel(fixture: fixture)
      #expect(model.settings.isPreview)
      #expect(model.settings.keepProfilesCurrentAtLaunch(HostList()) == nil)
    }
  } // End of func previewsNeverTouchAnInstaller()

  // MARK: - The real seam

  /// `PersistentProfileFiles` over a private stand-in for iTerm2's folders: not installed (an
  /// update creates nothing), installed (current), out of date once the helper moved, installed
  /// or updated again; a file of the user's is left exactly as it is; an unusable helper still
  /// tells whether muxFinder's file is there and Remove works without it.
  @Test func realSeamOverAPrivateFolder() async throws {
    let base = FileManager.default.temporaryDirectory
      .appending(path: "mfx-profiles-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: base.appending(path: "iTerm2/DynamicProfiles"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let installer = PersistentProfileInstaller(
      directory: base.appending(path: "iTerm2/DynamicProfiles", directoryHint: .isDirectory),
      lockDirectory: base.appending(path: "muxFinder", directoryHint: .isDirectory))
    #expect(!installer.directory.path.contains("Library/Application Support/iTerm2"))
    /// A seam whose helper is at `path`.
    func files(_ path: String) -> PersistentProfileFiles {
      PersistentProfileFiles(installer: installer) {
        Result { () throws(LaunchHelperPathError) in try LaunchHelperPath(validating: path) }
      }
    }
    let app = files("/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch")
    let moved = files("/Users/tester/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch")
    let unsafe = files("/Users/tester/My Apps/muxfinder-launch")
    let hosts = Self.list([Self.neptuno, Self.saturno])
    #expect(await app.status(for: hosts) == .notInstalled)
    #expect(await app.update(hosts) == .notInstalled)
    #expect(await app.update(HostList()) == .nothingToRemove)
    #expect(!FileManager.default.fileExists(atPath: installer.fileURL.path(percentEncoded: false)))
    #expect(
      await unsafe.status(for: hosts)
        == .unavailable(.helper(.unsupportedCharacters), isInstalled: false))
    #expect(await unsafe.install(hosts) == .failed(.helper(.unsupportedCharacters)))
    #expect(await app.install(hosts) == .installed(count: 1))
    #expect(await app.status(for: hosts) == .current)
    #expect(await app.install(hosts) == .unchanged)
    #expect(await moved.status(for: hosts) == .stale)
    #expect(
      await unsafe.status(for: hosts)
        == .unavailable(.helper(.unsupportedCharacters), isInstalled: true))
    #expect(await moved.install(hosts) == .installed(count: 1))
    #expect(await moved.status(for: hosts) == .current)
    #expect(await app.update(hosts) == .installed(count: 1))
    #expect(await app.status(for: hosts) == .current)
    #expect(await app.update(hosts) == .unchanged)
    #expect(await unsafe.update(hosts) == .failed(.helper(.unsupportedCharacters)))
    #expect(await unsafe.remove() == .removed)
    #expect(await app.remove() == .nothingToRemove)
    #expect(await app.update(hosts) == .notInstalled)
    #expect(!FileManager.default.fileExists(atPath: installer.fileURL.path(percentEncoded: false)))

    let users = Data(#"{"Profiles": [{"Name": "Mine", "Guid": "mine-1"}]}"#.utf8)
    try users.write(to: installer.fileURL)
    let refused = PersistentProfileChange.failed(.installer(.fileNotMuxFinders))
    #expect(
      await app.status(for: hosts)
        == .unavailable(.installer(.fileNotMuxFinders), isInstalled: false))
    #expect(await app.install(hosts) == refused)
    #expect(await app.install(HostList()) == refused)
    #expect(await app.update(hosts) == refused)
    #expect(await app.update(HostList()) == refused)
    #expect(await app.remove() == refused)
    #expect(try Data(contentsOf: installer.fileURL) == users)
  } // End of func realSeamOverAPrivateFolder()
}
