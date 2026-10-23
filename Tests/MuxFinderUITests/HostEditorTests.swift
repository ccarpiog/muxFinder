import Darwin
import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// The host editor's validation rules (`HostDraftIssues`), pure values.
@Suite("Settings: host editor validation")
struct HostDraftValidationTests {
  /// Shorthand.
  typealias Support = SettingsTestSupport

  /// The issues of `draft` among `others`.
  static func issues(_ draft: HostDraft, others: [HostConfig] = []) -> HostDraftIssues {
    HostDraftIssues(draft: draft, otherHosts: others)
  }

  /// A draft of an enabled SSH host with a valid destination.
  static func validDraft() -> HostDraft {
    HostDraft(Support.sshHost("Saturno"))
  }

  /// The name: required, at most 50 characters, no control characters, not another host's
  /// (ignoring case and surrounding spaces).
  @Test func nameRules() {
    var draft = Self.validDraft()
    #expect(Self.issues(draft).isValid)
    draft.displayName = "   "
    #expect(Self.issues(draft).displayName == "Enter a name for this host.")
    draft.displayName = String(repeating: "x", count: HostDraft.maximumNameLength + 1)
    #expect(Self.issues(draft).displayName == "Names can be at most 50 characters long.")
    draft.displayName = String(repeating: "x", count: HostDraft.maximumNameLength)
    #expect(Self.issues(draft).displayName == nil)
    draft.displayName = "Sat\turno"
    #expect(
      Self.issues(draft).displayName
        == "Names can't contain line breaks, tabs or other control characters.")
    draft.displayName = "  sirio "
    let others = [Support.sshHost("Sirio")]
    #expect(Self.issues(draft, others: others).displayName == "Another host already has this name.")
    draft.displayName = "Saturno"
    #expect(Self.issues(draft, others: others).isValid)
  } // End of func nameRules()

  /// The destination: required while an SSH host is on, otherwise empty or valid; ignored for
  /// This Mac.
  @Test func destinationRules() {
    var draft = Self.validDraft()
    draft.sshDestination = ""
    let missing = Self.issues(draft)
    #expect(missing.destination == ValidationError.sshDestinationEmpty.message)
    #expect(missing.enabled == HostDraftIssues.destinationNeededToTurnOn)
    draft.isEnabled = false
    #expect(Self.issues(draft).isValid)
    draft.sshDestination = "sat urno.example"
    #expect(Self.issues(draft).destination == "SSH destinations can't contain spaces.")
    #expect(Self.issues(draft).enabled == nil)
    draft.sshDestination = "-oProxyCommand=x"
    #expect(Self.issues(draft).destination == "SSH destinations can't start with “-”.")
    draft.sshDestination = "a\u{7}b"
    #expect(
      Self.issues(draft).destination == "SSH destinations can't contain control characters.")
    draft.sshDestination = "  someone@saturno.example "
    draft.isEnabled = true
    #expect(Self.issues(draft).isValid)
    draft.mode = .local
    draft.sshDestination = "not valid"
    #expect(Self.issues(draft).isValid)
  } // End of func destinationRules()

  /// The tmux path is empty (automatic) or a full path; the profile has no control characters.
  @Test func tmuxPathAndProfileRules() {
    var draft = Self.validDraft()
    draft.tmuxPath = "bin/tmux"
    #expect(
      Self.issues(draft).tmuxPath
        == "Enter a full path that starts with “/”, such as /opt/homebrew/bin/tmux.")
    #expect(!draft.canTest)
    #expect(draft.canDetect)
    draft.tmuxPath = "/opt/tm\u{1}ux"
    #expect(Self.issues(draft).tmuxPath == "Executable paths can't contain control characters.")
    draft.tmuxPath = " /opt/homebrew/bin/tmux "
    #expect(Self.issues(draft).isValid)
    #expect(draft.canTest)
    draft.profileName = "Wo\u{1}rk"
    #expect(Self.issues(draft).profileName == "Profile names can't contain control characters.")
    draft.profileName = "Work"
    #expect(Self.issues(draft).isValid)
  } // End of func tmuxPathAndProfileRules()

  /// What a draft saves: trimmed values, an empty tmux path or profile stored as none; Detect
  /// probes without the tmux path.
  @Test func configTrimsAndStoresEmptyAsNone() {
    var draft = Self.validDraft()
    draft.displayName = "  Saturno  "
    draft.sshDestination = " saturno.example\n"
    draft.tmuxPath = "  "
    draft.profileName = " Work "
    let config = draft.config
    #expect(config.displayName == "Saturno")
    #expect(config.sshDestination == "saturno.example")
    #expect(config.tmuxPathOverride == nil)
    #expect(config.iTermProfileName == "Work")
    draft.tmuxPath = "/usr/local/bin/tmux"
    #expect(draft.probeConfig(detecting: false).tmuxPathOverride == "/usr/local/bin/tmux")
    #expect(draft.probeConfig(detecting: true).tmuxPathOverride == nil)
    let new = HostDraft.newHost()
    #expect(new.isNew && new.mode == .ssh && !new.isEnabled && new.sshDestination.isEmpty)
  } // End of func configTrimsAndStoresEmptyAsNone()

  /// A draft keeps a host's persistent-profile values (PLAN.md D26) exactly: the editor has no
  /// controls for them yet, and saving an edit must not drop them.
  @Test func draftKeepsPersistentProfileValues() {
    let host = HostConfig(
      displayName: "Saturno", mode: .ssh, sshDestination: "saturno.example",
      persistentProfileEnabled: true, defaultSessionName: "work",
      persistentProfileParentName: "Base")
    var draft = HostDraft(host)
    #expect(draft.config == host)
    draft.displayName = "Saturno 2"
    #expect(draft.config.persistentProfileEnabled)
    #expect(draft.config.defaultSessionName == "work")
    #expect(draft.config.persistentProfileParentName == "Base")
    #expect(!HostDraft.newHost().config.persistentProfileEnabled)
  }
}

/// The Settings model's Hosts tab over fakes, and over a real `HostStore` in a private folder.
@Suite("Settings: hosts")
@MainActor
struct SettingsHostsTests {
  /// Shorthand.
  typealias Support = SettingsTestSupport

  /// An SSH host cannot be turned on without a valid destination: the model refuses and says
  /// why; with one it can. This Mac needs none.
  @Test func turningOnNeedsADestination() async {
    let blank = HostConfig(displayName: "Vega", mode: .ssh, isEnabled: false)
    let (model, store) = await Support.openModel([blank])
    #expect(model.selection == .host(blank.id))
    #expect(model.setEnabled(true) == false)
    #expect(model.draft?.isEnabled == false)
    #expect(model.enableRefusal == HostDraftIssues.destinationNeededToTurnOn)
    model.setDestination("bad value")
    #expect(model.setEnabled(true) == false)
    model.setDestination("vega.example")
    #expect(model.enableRefusal == nil)
    #expect(model.setEnabled(true))
    #expect(model.canSave)
    #expect(await model.save())
    #expect(store.saves.last?.hosts.first?.isEnabled == true)
    model.setMode(.local)
    model.setDestination("")
    #expect(model.setEnabled(false))
    #expect(model.setEnabled(true))
  } // End of func turningOnNeedsADestination()

  /// Choosing This Mac follows D19's switch: the host becomes local and on, and saving turns
  /// the previous This Mac into an SSH host, turned off, its destination kept.
  @Test func thisMacDemotesThePreviousOne() async throws {
    var neptuno = HostConfig(displayName: "Neptuno", mode: .local)
    neptuno.sshDestination = "neptuno.example"
    let saturno = Support.sshHost("Saturno", enabled: false)
    let (model, store) = await Support.openModel([neptuno, saturno])
    model.select(.host(saturno.id))
    #expect(model.thisMacNotice == nil)
    model.setMode(.local)
    #expect(model.draft?.isEnabled == true)
    let notice = try #require(model.thisMacNotice)
    #expect(notice.contains("“Neptuno” an SSH host again and turns it off"))
    #expect(await model.save())
    let saved = try #require(store.saves.last)
    #expect(saved.thisMac?.id == saturno.id)
    let demoted = try #require(saved.host(withID: neptuno.id))
    #expect(demoted.mode == .ssh && !demoted.isEnabled)
    #expect(demoted.sshDestination == "neptuno.example")
    #expect(model.hosts == saved)
    #expect(model.selection == .host(saturno.id))
    #expect(!model.isDirty)
  } // End of func thisMacDemotesThePreviousOne()

  /// "Add host" edits a new SSH host, off; saving adds it (here as This Mac, demoting the old
  /// one); Cancel drops an unsaved one.
  @Test func addingAHost() async throws {
    let neptuno = HostConfig(displayName: "Neptuno", mode: .local)
    let (model, store) = await Support.openModel([neptuno])
    model.addHost()
    #expect(model.selection == .newHost)
    #expect(model.draft?.isNew == true)
    #expect(model.hostRows.last?.detail == "Not saved yet")
    model.revert()
    #expect(model.selection == .host(neptuno.id))
    model.addHost()
    model.setDisplayName("Lab")
    model.setMode(.local)
    #expect(await model.save())
    let saved = try #require(store.saves.last)
    #expect(saved.hosts.map(\.displayName) == ["Neptuno", "Lab"])
    #expect(saved.thisMac?.displayName == "Lab")
    #expect(saved.hosts[0].mode == .ssh && !saved.hosts[0].isEnabled)
    #expect(model.draft?.isNew == false)
    #expect(model.selection == .host(saved.hosts[1].id))
  } // End of func addingAHost()

  /// Removing asks first: nothing is saved until "Remove"; then the next host is selected.
  @Test func removingAsksFirst() async {
    let hosts = [Support.sshHost("Saturno"), Support.sshHost("Sirio"), Support.sshHost("Vega")]
    let (model, store) = await Support.openModel(hosts)
    model.select(.host(hosts[1].id))
    model.requestRemoval()
    #expect(model.pendingRemoval == hosts[1].id)
    #expect(model.pendingRemovalName == "Sirio")
    model.cancelRemoval()
    #expect(model.pendingRemoval == nil)
    #expect(await model.confirmRemoval() == false)
    #expect(store.saves.isEmpty)
    model.requestRemoval()
    #expect(await model.confirmRemoval())
    #expect(store.saves.last?.hosts.map(\.displayName) == ["Saturno", "Vega"])
    #expect(model.selection == .host(hosts[2].id))
    model.addHost()
    model.requestRemoval()
    #expect(model.pendingRemoval == nil)
  } // End of func removingAsksFirst()

  /// Selecting another host with unsaved changes asks first; keeping them changes nothing,
  /// discarding switches. Without changes, selecting switches at once.
  @Test func unsavedChangesAskBeforeSwitching() async {
    let hosts = [Support.sshHost("Saturno"), Support.sshHost("Sirio")]
    let (model, _) = await Support.openModel(hosts)
    model.select(.host(hosts[1].id))
    #expect(model.selection == .host(hosts[1].id))
    model.setDisplayName("Sirio 2")
    model.select(.host(hosts[0].id))
    #expect(model.pendingSelection == .init(target: .host(hosts[0].id)))
    #expect(model.selection == .host(hosts[1].id))
    model.cancelDiscard()
    #expect(model.draft?.displayName == "Sirio 2")
    model.select(.host(hosts[0].id))
    model.confirmDiscard()
    #expect(model.selection == .host(hosts[0].id))
    #expect(model.draft?.displayName == "Saturno")
    model.select(.host(hosts[1].id))
    #expect(model.draft?.displayName == "Sirio")
  } // End of func unsavedChangesAskBeforeSwitching()

  /// A failed save shows the store's error and keeps the old list and the draft.
  @Test func saveErrorsAreShown() async {
    let saturno = Support.sshHost("Saturno")
    let (model, store) = await Support.openModel([saturno])
    store.failSaves(with: .existingFileNotRegular)
    model.setDisplayName("Saturno M4")
    #expect(await model.save() == false)
    #expect(model.saveError == HostStoreError.existingFileNotRegular.errorDescription)
    #expect(model.hosts.hosts == [saturno])
    #expect(model.isDirty)
    model.setDisplayName("")
    #expect(!model.canSave)
    #expect(await model.save() == false)
  } // End of func saveErrorsAreShown()

  /// Saving goes through a real `HostStore` in a private folder: loading the examples writes
  /// nothing, a save creates the file, and a fresh store loads the change.
  @Test func savesThroughHostStoreInAPrivateFolder() async throws {
    let folder = try Support.privateStoreFolder()
    defer { try? FileManager.default.removeItem(at: folder.base) }
    let store = HostStore(fileURL: folder.file)
    let model = SettingsModel(environment: Support.environment(store: store))
    var saved: [HostList] = []
    model.onHostListSaved = { saved.append($0) }
    await model.windowDidOpen()
    #expect(model.hostListStatus == .notSavedYet)
    #expect(model.banner == .examples)
    #expect(!FileManager.default.fileExists(atPath: folder.file.deletingLastPathComponent().path))
    model.setDestination("saturno.example")
    #expect(model.setEnabled(true))
    #expect(await model.save())
    #expect(model.saveNotice == "Saved.")
    #expect(model.hostListStatus == .saved)
    #expect(saved.count == 1)
    let reloaded = try await HostStore(fileURL: folder.file).load()
    #expect(reloaded.state == .saved)
    #expect(reloaded.hosts == saved[0])
    #expect(reloaded.hosts.hosts[0].sshDestination == "saturno.example")
    #expect(reloaded.hosts.hosts[0].isEnabled)
  } // End of func savesThroughHostStoreInAPrivateFolder()

  /// An unusable file is shown with its problem and never written without consent: no edit,
  /// save, add or removal touches it. Once the user chooses Replace, the first save puts a new
  /// list in place and the store keeps the old bytes as a backup.
  @Test func invalidFileNeedsConsent() async throws {
    let folder = try Support.privateStoreFolder()
    defer { try? FileManager.default.removeItem(at: folder.base) }
    let directory = folder.file.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let bytes = Data("not json at all".utf8)
    #expect(FileManager.default.createFile(atPath: folder.file.path, contents: bytes))
    #expect(chmod(folder.file.path, 0o600) == 0)
    let store = HostStore(fileURL: folder.file)
    let model = SettingsModel(environment: Support.environment(store: store))
    await model.windowDidOpen()
    #expect(model.hostListStatus == .invalid(.notJSON))
    #expect(model.banner == .invalidFile(.notJSON, consented: false))
    #expect(model.banner?.text.contains(HostFileProblem.notJSON.message) == true)
    #expect(!model.isEditable)
    let name = model.draft?.displayName
    model.setDisplayName("Changed")
    #expect(model.draft?.displayName == name)
    #expect(model.setEnabled(true) == false)
    #expect(!model.canSave)
    #expect(await model.save() == false)
    #expect(model.saveError == SettingsModel.replaceFirstMessage)
    model.addHost()
    #expect(model.selection != .newHost)
    model.requestRemoval()
    #expect(await model.confirmRemoval() == false)
    #expect(try Data(contentsOf: folder.file) == bytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["hosts.json"])

    model.confirmReplaceFile()
    #expect(model.isEditable)
    #expect(model.banner == .invalidFile(.notJSON, consented: true))
    #expect(try Data(contentsOf: folder.file) == bytes)
    model.setDisplayName("Saturno M4")
    #expect(await model.save())
    #expect(model.hostListStatus == .saved)
    #expect(model.saveNotice?.contains("hosts.backup-") == true)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    #expect(names.count == 2)
    let backup = try #require(names.first { $0.hasPrefix("hosts.backup-") })
    #expect(try Data(contentsOf: directory.appending(path: backup)) == bytes)
    let reloaded = try await HostStore(fileURL: folder.file).load()
    #expect(reloaded.state == .saved)
    #expect(reloaded.hosts.hosts.first?.displayName == "Saturno M4")
  } // End of func invalidFileNeedsConsent()

  /// A file another program changed after Settings loaded it is never replaced by Save or
  /// Remove (PLAN.md D23): a valid file replaced by one that is not JSON or by a newer format,
  /// and a missing file that appeared, are each left byte for byte, with no backup, and the
  /// user's draft is kept.
  @Test func changedFileIsNotReplaced() async throws {
    let created = try HostStore.encode(HostList([Support.sshHost("Elsewhere")]))
    let cases: [(label: String, startsSaved: Bool, bytes: Data)] = [
      ("valid, then not JSON", true, Data("edited elsewhere, not JSON".utf8)),
      ("valid, then a newer format", true, Data(#"{"schemaVersion": 2, "hosts": []}"#.utf8)),
      ("missing, then created", false, created),
    ]
    for (label, startsSaved, bytes) in cases {
      for removing in [false, true] {
        let name = "\(label), \(removing ? "remove" : "save")"
        let folder = try Support.privateStoreFolder()
        defer { try? FileManager.default.removeItem(at: folder.base) }
        let directory = folder.file.deletingLastPathComponent()
        if startsSaved {
          try await HostStore(fileURL: folder.file).save(HostList([Support.sshHost("Saturno")]))
        }
        let model = SettingsModel(
          environment: Support.environment(store: HostStore(fileURL: folder.file)))
        await model.windowDidOpen()
        #expect(model.isEditable, "\(name)")
        model.setDisplayName("Changed here")
        try Self.replaceFile(folder.file, with: bytes)
        if removing {
          model.requestRemoval()
          #expect(await model.confirmRemoval() == false, "\(name)")
        } else {
          #expect(await model.save() == false, "\(name)")
        }
        #expect(model.saveError == SettingsModel.fileChangedMessage, "\(name)")
        #expect(try Data(contentsOf: folder.file) == bytes, "\(name)")
        #expect(
          try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["hosts.json"],
          "\(name)")
        #expect(model.draft?.displayName == "Changed here", "\(name)")
        #expect(model.hosts.hosts.count == (startsSaved ? 1 : 3), "\(name)")
        #expect(model.banner == .fileChanged(consented: false), "\(name)")
        #expect(!model.isEditable && !model.canSave, "\(name)")
        model.setDisplayName("Edited after the refusal")
        #expect(model.draft?.displayName == "Changed here", "\(name)")
        #expect(await model.save() == false, "\(name)")
        #expect(try Data(contentsOf: folder.file) == bytes, "\(name)")
      } // End of loop over save and remove
    } // End of loop over changes
  } // End of func changedFileIsNotReplaced()

  /// After a save found the file changed, Reload shows the file as it is now (here unusable,
  /// so its own Replace flow applies), and Replace saves the list shown over it, keeping the
  /// changed file as a backup. A file that changes again after Replace refuses the save again.
  @Test func changedFileReloadOrReplace() async throws {
    let folder = try Support.privateStoreFolder()
    defer { try? FileManager.default.removeItem(at: folder.base) }
    let directory = folder.file.deletingLastPathComponent()
    try await HostStore(fileURL: folder.file).save(HostList([Support.sshHost("Saturno")]))
    let model = SettingsModel(
      environment: Support.environment(store: HostStore(fileURL: folder.file)))
    await model.windowDidOpen()
    model.setDisplayName("Saturno M4")
    let first = Data("first change, not JSON".utf8)
    try Self.replaceFile(folder.file, with: first)
    #expect(await model.save() == false)

    await model.reloadHosts()
    #expect(model.banner == .invalidFile(.notJSON, consented: false))
    #expect(model.changedFile == nil)
    #expect(model.draft?.displayName == HostList.onboardingDefaults().hosts.first?.displayName)

    model.confirmReplaceFile()
    let second = Data("second change, not JSON".utf8)
    try Self.replaceFile(folder.file, with: second)
    model.setDisplayName("Lab")
    #expect(await model.save() == false)
    #expect(model.banner == .fileChanged(consented: false))
    #expect(try Data(contentsOf: folder.file) == second)

    model.confirmReplaceFile()
    #expect(model.banner == .fileChanged(consented: true))
    #expect(model.isEditable && model.canSave)
    #expect(model.draft?.displayName == "Lab")
    #expect(await model.save())
    #expect(model.banner == nil)
    #expect(model.saveNotice?.contains("hosts.backup-") == true)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    let backup = try #require(names.first { $0.hasPrefix("hosts.backup-") })
    #expect(names.count == 2)
    #expect(try Data(contentsOf: directory.appending(path: backup)) == second)
    let reloaded = try await HostStore(fileURL: folder.file).load()
    #expect(reloaded.state == .saved)
    #expect(reloaded.hosts.hosts.first?.displayName == "Lab")

    model.setDisplayName("Lab 2")
    #expect(await model.save())
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
  } // End of func changedFileReloadOrReplace()

  /// The fake store's revisions go through the model like `HostStore`'s: saves chain on the
  /// revision each returns, and a change made elsewhere refuses the next save.
  @Test func savesChainOnRevisions() async {
    let saturno = Support.sshHost("Saturno")
    let (model, store) = await Support.openModel([saturno])
    model.setDisplayName("Saturno 1")
    #expect(await model.save())
    model.setDisplayName("Saturno 2")
    #expect(await model.save())
    #expect(store.saves.count == 2)
    store.changeFile(to: Support.loaded([Support.sshHost("Elsewhere")]))
    model.setDisplayName("Saturno 3")
    #expect(await model.save() == false)
    #expect(store.saves.count == 2)
    #expect(model.changedFile == FakeHostListStore.revision(3))
  } // End of func savesChainOnRevisions()

  /// Puts `bytes` at `file` as another program would: a new 0600 file renamed over the name
  /// (creating the private folder first if needed).
  static func replaceFile(_ file: URL, with bytes: Data) throws {
    let directory = file.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
    let draft = directory.appending(path: "editor-draft")
    try bytes.write(to: draft)
    try #require(chmod(draft.path, 0o600) == 0)
    try #require(rename(draft.path, file.path) == 0)
  } // End of static func replaceFile(_:with:)

  /// Editing another host while a removal saves keeps that selection and draft: the editor
  /// moves to the next host only when it still shows the removed one (PLAN.md D23).
  @Test func editsMadeWhileARemovalSavesAreKept() async {
    let hosts = [Support.sshHost("Saturno"), Support.sshHost("Sirio"), Support.sshHost("Vega")]
    let (model, store) = await Support.openModel(hosts)
    #expect(model.selection == .host(hosts[0].id))
    store.holdSaves()
    model.requestRemoval()
    let removal = Task { await model.confirmRemoval() }
    await store.waitForSaveCalls(1)
    model.select(.host(hosts[2].id))
    model.setDisplayName("Vega 2")
    store.releaseSaves()
    #expect(await removal.value)
    #expect(model.hosts.hosts.map(\.displayName) == ["Sirio", "Vega"])
    #expect(model.selection == .host(hosts[2].id))
    #expect(model.draft?.displayName == "Vega 2")
    #expect(model.isDirty)

    model.revert()
    store.holdSaves()
    model.requestRemoval()
    let second = Task { await model.confirmRemoval() }
    await store.waitForSaveCalls(2)
    store.releaseSaves()
    #expect(await second.value)
    #expect(model.selection == .host(hosts[1].id))
    #expect(model.draft?.displayName == "Sirio")
  } // End of func editsMadeWhileARemovalSavesAreKept()

  /// Closing the window while it still loads the host list stops the opening there: no
  /// profile request (so no iTerm2 contact), no suggestions (PLAN.md D23).
  @Test func closingWhileLoadingStopsTheOpening() async {
    let profiles = FakeProfiles(.available(["Work"]))
    let store = FakeHostListStore(Support.loaded([Support.sshHost("Saturno")]))
    store.holdLoads()
    let model = SettingsModel(environment: Support.environment(store: store, profiles: profiles))
    let opening = Task { await model.windowDidOpen() }
    await store.waitForLoadCalls(1)
    model.windowDidClose()
    store.releaseLoads()
    await opening.value
    #expect(profiles.calls.value == 0)
    #expect(model.profileChoices == .notLoaded)
    #expect(model.suggestions.isEmpty)
  } // End of func closingWhileLoadingStopsTheOpening()

  /// Closing the window while iTerm2's profiles are being asked for cancels that request and
  /// drops its answer (PLAN.md D23).
  @Test func closingCancelsTheProfileRequest() async {
    let gate = TestGate()
    gate.close()
    let profiles = FakeProfiles(.available(["Work"]), gate: gate)
    let store = FakeHostListStore(Support.loaded([Support.sshHost("Saturno")]))
    let model = SettingsModel(environment: Support.environment(store: store, profiles: profiles))
    let opening = Task { await model.windowDidOpen() }
    await gate.waitForArrivals(1)
    #expect(model.profileChoices == .loading)
    model.windowDidClose()
    #expect(gate.cancellations == 1)
    gate.open()
    await opening.value
    #expect(profiles.calls.value == 1)
    #expect(model.profileChoices == .notLoaded)
  } // End of func closingCancelsTheProfileRequest()

  /// An unreadable folder is shown and nothing can be edited; "Try again" loads again.
  @Test func unreadableFolder() async {
    let store = FakeHostListStore(Support.loaded([Support.sshHost("Saturno")]))
    store.failLoads(with: .directoryIsSymbolicLink)
    let model = SettingsModel(environment: Support.environment(store: store))
    await model.windowDidOpen()
    #expect(
      model.banner
        == .unreadable(HostStoreError.directoryIsSymbolicLink.errorDescription ?? ""))
    #expect(!model.isEditable)
    #expect(model.draft == nil)
    store.failLoads(with: nil)
    await model.reloadHosts()
    #expect(model.isEditable)
    #expect(model.draft?.displayName == "Saturno")
  } // End of func unreadableFolder()

  /// Detect looks for tmux without the tmux path and fills it in; a host without tmux and an
  /// unreachable host say so, with the popover's wording.
  @Test func detectFillsTheTmuxPath() async throws {
    let discovery = ScriptedDiscovery()
    var saturno = Support.sshHost("Saturno")
    saturno.tmuxPathOverride = "/wrong/tmux"
    let (model, _) = await Support.openModel([saturno], discovery: discovery)
    discovery.answer(
      .ok([]),
      report: ProbeReport(
        nodeName: "n", tmuxPath: "/opt/homebrew/bin/tmux", tmuxVersion: "tmux 3.8"))
    model.detectTmux()
    #expect(model.detection == .running)
    await model.probesFinished()
    #expect(model.detection == .found(path: "/opt/homebrew/bin/tmux", version: "tmux 3.8"))
    #expect(model.detection.message == "Found tmux 3.8 at /opt/homebrew/bin/tmux.")
    #expect(model.draft?.tmuxPath == "/opt/homebrew/bin/tmux")
    let call = try #require(discovery.calls.last)
    #expect(call.tmuxPathOverride == nil)
    #expect(call.sshDestination == "saturno.example")
    discovery.answer(.tmuxNotFound, report: ProbeReport(nodeName: "n"))
    model.detectTmux()
    await model.probesFinished()
    #expect(model.detection == .notFound)
    #expect(model.detection.isProblem)
    discovery.answer(.unreachable(.timeout), report: nil)
    model.detectTmux()
    await model.probesFinished()
    #expect(model.detection.message == "Unreachable. The connection timed out.")
  } // End of func detectFillsTheTmuxPath()

  /// Test connection shows the popover's status wording for every classified status, with the
  /// popover's explanation for failures; it probes the draft as it stands.
  @Test func testConnectionShowsClassifiedStatuses() async throws {
    let discovery = ScriptedDiscovery()
    var saturno = Support.sshHost("Saturno")
    saturno.tmuxPathOverride = "/opt/homebrew/bin/tmux"
    let (model, _) = await Support.openModel([saturno], discovery: discovery)
    let session = FakeDiscovery.session(on: saturno)
    let report = ProbeReport(nodeName: "n", tmuxPath: "/t", tmuxVersion: "tmux 3.8")
    let cases: [(HostStatus, HostStatusLabel)] = [
      (.ok([session]), .reachable), (.ok([]), .noSessions), (.noServer, .noSessions),
      (.unreachable(.dnsFailure), .unreachable), (.authFailed, .signInNeeded),
      (.hostKeyProblem(.changed), .hostKeyProblem), (.tmuxNotFound, .tmuxNotFound),
      (.probeError("The discovery report is too large."), .checkFailed),
    ]
    for (status, label) in cases {
      discovery.answer(status, report: report)
      model.testConnection()
      #expect(model.connectionTest == .running)
      await model.probesFinished()
      guard case .finished(let result) = model.connectionTest else {
        Issue.record("no result for \(status.kind)")
        continue
      }
      #expect(result.status == label)
      #expect(result.explanation == HostProblemText.explanation(for: status))
    } // End of loop over the statuses
    discovery.answer(.ok([session]), report: report)
    model.testConnection()
    await model.probesFinished()
    #expect(
      model.connectionTest == .finished(.init(status: .reachable, detail: "1 session · tmux 3.8")))
    #expect(discovery.calls.last?.tmuxPathOverride == "/opt/homebrew/bin/tmux")
    model.setMode(.local)
    discovery.answer(.noServer, report: report)
    model.testConnection()
    await model.probesFinished()
    guard case .finished(let local) = model.connectionTest else {
      Issue.record("no result for This Mac")
      return
    }
    #expect(local.status == .thisMac)
    #expect(local.status.text == "This Mac")
  } // End of func testConnectionShowsClassifiedStatuses()

  /// A probe whose host fields changed while it ran is dropped, and an incomplete draft runs
  /// no probe at all.
  @Test func staleProbesAreDropped() async {
    let discovery = ScriptedDiscovery()
    let saturno = Support.sshHost("Saturno")
    let (model, _) = await Support.openModel([saturno], discovery: discovery)
    discovery.hold()
    model.testConnection()
    model.detectTmux()
    #expect(model.connectionTest == .running)
    model.setDestination("other.example")
    #expect(model.connectionTest == .idle)
    #expect(model.detection == .idle)
    discovery.release()
    await model.probesFinished()
    #expect(model.connectionTest == .idle)
    #expect(model.detection == .idle)
    #expect(model.draft?.tmuxPath == "")
    model.setDestination("")
    let calls = discovery.calls.count
    model.testConnection()
    model.detectTmux()
    #expect(discovery.calls.count == calls)
    #expect(model.connectionTest == .idle)
  } // End of func staleProbesAreDropped()

  /// The profile picker offers iTerm2's profiles when it can list them, and falls back to free
  /// text (with a note, and a fix-it for a permission problem) when it can't.
  @Test func profilePickerFallsBackToFreeText() async {
    let saturno = Support.sshHost("Saturno")
    let (listed, _) = await Support.openModel([saturno])
    #expect(listed.profileChoices == .available(["Default", "Work"]))
    #expect(listed.profileChoices.offersPicker)
    #expect(listed.profileChoices.note == nil)
    listed.setProfileName("Gone")
    #expect(listed.profileWarning == "iTerm2 has no profile with this name right now.")
    listed.setProfileName("Work")
    #expect(listed.profileWarning == nil)

    let (notRunning, _) = await Support.openModel(
      [saturno], profiles: FakeProfiles(.iTermNotRunning))
    #expect(!notRunning.profileChoices.offersPicker)
    #expect(notRunning.profileChoices.note?.hasPrefix("iTerm2 isn't running") == true)
    #expect(notRunning.profileChoices.fixIt == nil)
    notRunning.setProfileName("Anything")
    #expect(notRunning.profileWarning == nil)
    #expect(notRunning.draft?.profileName == "Anything")

    let (denied, _) = await Support.openModel(
      [saturno], profiles: FakeProfiles(.failed(.automationDenied)))
    #expect(!denied.profileChoices.offersPicker)
    #expect(denied.profileChoices.fixIt == .openAutomationSettings)
    #expect(denied.profileChoices.note?.contains("Privacy & Security") == true)
  } // End of func profilePickerFallsBackToFreeText()

  /// The real profile source asks iTerm2 only while it runs, never launches it, and sorts and
  /// de-duplicates the names.
  @Test func profileSourceNeverLaunchesITerm2() async {
    let stopped = FakeITerm2Integration(
      script: {
        var script = FakeITerm2Integration.Script()
        script.isRunning = false
        return script
      }())
    #expect(await ITerm2ProfileSource(iTerm2: stopped).profileNames() == .iTermNotRunning)
    let stoppedCalls = await stopped.calls
    #expect(stoppedCalls == [.isRunning])
    let profile = { (name: String) in
      ITerm2API.Profile(properties: [
        ITerm2API.ProfileProperty(key: "Name", jsonValue: ITerm2JSON.encode(name))
      ])
    }
    let running = FakeITerm2Integration(
      script: {
        var script = FakeITerm2Integration.Script()
        script.listProfiles = .init(
          .success([profile("Work"), profile("Default"), profile("Work")]))
        return script
      }())
    #expect(
      await ITerm2ProfileSource(iTerm2: running).profileNames() == .available(["Default", "Work"]))
    let runningCalls = await running.calls
    #expect(runningCalls == [.isRunning, .listProfiles(properties: ["Name"], guids: [])])
    let off = FakeITerm2Integration(
      script: {
        var script = FakeITerm2Integration.Script()
        script.listProfiles = .init(.failure(.apiDisabled))
        return script
      }())
    #expect(await ITerm2ProfileSource(iTerm2: off).profileNames() == .failed(.apiDisabled))
    let offCalls = await off.calls
    #expect(!offCalls.contains(.ensureRunning))
    let cancelled = FakeITerm2Integration(script: FakeITerm2Integration.Script())
    let task = Task { await ITerm2ProfileSource(iTerm2: cancelled).profileNames() }
    task.cancel()
    #expect(await task.value == .cancelled)
    let cancelledCalls = await cancelled.calls
    #expect(!cancelledCalls.contains(.listProfiles(properties: ["Name"], guids: [])))
  } // End of func profileSourceNeverLaunchesITerm2()

  /// Opening loads everything once; reopening while open does nothing; closing stops probes.
  @Test func windowLifecycle() async {
    let discovery = ScriptedDiscovery()
    let profiles = FakeProfiles(.available([]))
    let (model, store) = await Support.openModel(
      [Support.sshHost("Saturno")], discovery: discovery, profiles: profiles)
    #expect(store.loads == 1)
    #expect(profiles.calls.value == 1)
    #expect(model.suggestions == ["build-box.example"])
    await model.windowDidOpen()
    #expect(store.loads == 1)
    discovery.hold()
    model.testConnection()
    model.windowDidClose()
    #expect(model.connectionTest == .idle)
    discovery.release()
    await model.probesFinished()
    #expect(model.connectionTest == .idle)
    await model.windowDidOpen()
    #expect(store.loads == 2)
  } // End of func windowLifecycle()
}
