import Foundation
import MuxFinderCore
import Testing

@testable import MuxFinderUI

/// A directory store whose every change fails (a write error), counting the attempts.
actor FailingDirectoryStore: DirectoryStoring {
  /// How many changes were attempted.
  private(set) var attempts = 0

  /// No lists.
  func load() -> DirectoryStoreLoadResult {
    DirectoryStoreLoadResult(lists: DirectoryLists(), state: .notSavedYet)
  }

  /// Fails like a publication the file system refused.
  func apply(
    _ change: DirectoryListChange,
    knownHosts: Set<UUID>?
  ) throws(DirectoryStoreError) -> DirectoryStoreChangeResult {
    attempts += 1
    throw .systemCallFailed(name: "renameatx_np", errno: EIO)
  }
}

/// New session's recent directories (PLAN.md D31): only a creation that made the session
/// records its directory (as checked, for its host), also when the attach fails afterwards; an
/// empty field, a collision, a failed creation or `mayHaveCreated` record nothing; a failed write
/// is logged by kind only and never fails the creation; hosts removed from the list lose their
/// recents at the next write. And which store each mode gets.
@Suite("Session actions: recent directories")
@MainActor
struct DirectoryRecordingTests {
  /// Shorthand.
  typealias Support = UITestSupport

  /// Creates `name` in `directory` on `harness`'s first host with `outcome` as the creator's
  /// answer, and waits until the creation (and its attach, if any) ended and every recording
  /// was written.
  static func create(
    _ name: String,
    in directory: String,
    outcome: Result<CreatedSession, SessionCreationError>,
    harness: AttachHarness
  ) async {
    harness.creator.script([outcome])
    let model = harness.model
    model.newSession()
    model.newSessionDraft.hostID = harness.hosts[0].id
    model.newSessionDraft.name = name
    model.newSessionDraft.directory = directory
    let before = model.finishedActions.count
    model.createSession()
    _ = await Support.waitUntil { model.finishedActions.count > before }
    await model.directoryRecordingsHandled()
  } // End of static func create(_:in:outcome:harness:)

  /// A creation that made the session records the directory as checked, newest first, for its
  /// host only; its attach is confirmed as before.
  @Test func aCreatedSessionRecordsItsDirectory() async {
    let store = InMemoryDirectoryStore()
    let harness = await AttachHarness.make(directories: store)
    let host = harness.hosts[0]
    let (discovered, record) = NewSessionSheetTests.created("fresh", id: 7, on: host)
    harness.discovery.setStatus(.ok([FakeDiscovery.session(on: host), discovered]), for: host.id)
    await Self.create(
      "fresh", in: "~/projects/site ü #1;", outcome: .success(record), harness: harness)
    #expect(harness.model.activities[discovered.key] == .confirmed)
    #expect(await store.lists.recent == [host.id: ["~/projects/site ü #1;"]])
    #expect(await store.lists.saved.isEmpty)

    let (second, secondRecord) = NewSessionSheetTests.created("second", id: 8, on: host)
    harness.discovery.setStatus(
      .ok([FakeDiscovery.session(on: host), discovered, second]), for: host.id)
    await Self.create(
      "second", in: "/Users/example/other", outcome: .success(secondRecord), harness: harness)
    #expect(
      await store.lists.recent(for: host.id) == ["/Users/example/other", "~/projects/site ü #1;"])
    await harness.model.shutdown()
  } // End of func aCreatedSessionRecordsItsDirectory()

  /// The session was made, but its attach fails afterwards (it vanished before revalidation):
  /// the directory is recorded all the same.
  @Test func anAttachFailureAfterCreationStillRecords() async {
    let store = InMemoryDirectoryStore()
    let harness = await AttachHarness.make(directories: store)
    let host = harness.hosts[0]
    let (_, record) = NewSessionSheetTests.created("gone", id: 9, on: host)
    await Self.create("gone", in: "~/work", outcome: .success(record), harness: harness)
    let finished = harness.model.finishedActions.last
    #expect(finished?.outcome.attachResult?.failure == .sessionGone)
    #expect(await store.lists.recent(for: host.id) == ["~/work"])
    await harness.model.shutdown()
  }

  /// An empty field (the home folder), a collision, a failed creation and every
  /// `mayHaveCreated` failure record nothing, and never call the store.
  @Test func nothingIsRecordedWithoutACreatedSessionInADirectory() async {
    let store = InMemoryDirectoryStore()
    let harness = await AttachHarness.make(directories: store)
    let host = harness.hosts[0]
    let (discovered, record) = NewSessionSheetTests.created("home", id: 7, on: host)
    harness.discovery.setStatus(.ok([FakeDiscovery.session(on: host), discovered]), for: host.id)
    await Self.create("home", in: "", outcome: .success(record), harness: harness)
    #expect(harness.model.activities[discovered.key] == .confirmed)
    let failures: [SessionCreationError] = [
      .sessionExists(.hasSession), .sessionExists(.duplicateSession), .directoryMissing,
      .tmuxMissing, .sshFailed(.unreachable), .tmuxFailed("no space"), .connectionLost,
      .timedOut, .unexpectedOutput, .scriptFailed(.signaled(9)), .cancelled,
    ]
    for failure in failures {
      await Self.create("work", in: "~/projects/site", outcome: .failure(failure), harness: harness)
      #expect(
        harness.model.finishedActions.last?.outcome
          == .created(
            CreateAndAttachResult(creationFailure: failure)), "\(failure.kind)")
      harness.model.cancelPanel()
    } // End of loop over creation failures
    #expect(await store.changeCount == 0)
    #expect(await store.lists.isEmpty)
    await harness.model.shutdown()
  } // End of func nothingIsRecordedWithoutACreatedSessionInADirectory()

  /// A failed write changes nothing about the creation: the attach is confirmed and the next
  /// creation runs; the operation log says what failed by kind, never the directory.
  @Test func aFailedWriteNeverFailsTheCreation() async {
    let store = FailingDirectoryStore()
    let diagnostics = DiagnosticsLog(writesToSystemLog: false)
    let harness = await AttachHarness.make(directories: store, diagnostics: diagnostics)
    let host = harness.hosts[0]
    let (discovered, record) = NewSessionSheetTests.created("fresh", id: 7, on: host)
    harness.discovery.setStatus(.ok([FakeDiscovery.session(on: host), discovered]), for: host.id)
    let directory = "/Users/example/secret project"
    await Self.create("fresh", in: directory, outcome: .success(record), harness: harness)
    let model = harness.model
    #expect(model.activities[discovered.key] == .confirmed)
    #expect(model.finishedActions.last?.outcome.attachResult?.isConfirmed == true)
    #expect(model.panel == nil)
    #expect(await store.attempts == 1)
    let events = await diagnostics.events().filter { $0.detail.hasPrefix("recent directory") }
    #expect(
      events.map(\.detail) == [
        "recent directory not recorded: systemCallFailed.renameatx_np.\(EIO)"
      ])
    #expect(events.first?.outcome == .failure)
    #expect(await diagnostics.events().allSatisfy { !$0.detail.contains("secret") })
    await model.shutdown()
  } // End of func aFailedWriteNeverFailsTheCreation()

  /// A recording never replaces a directory list file that cannot be used (here valid lists
  /// with group and other permissions, in a private folder): the real store refuses it, the
  /// operation log says so by kind only, the file keeps its bytes, mode and modification time,
  /// nothing else appears in the folder, and the creation is confirmed as usual.
  @Test func aRecordingLeavesAnUnusableFileAsItIs() async throws {
    let base = FileManager.default.temporaryDirectory
      .appending(path: "mfx-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: base) }
    let file = base.appending(path: DirectoryStore.fileName)
    let original = Data(#"{"recent": {}, "saved": ["~/kept"], "schemaVersion": 1}"#.utf8)
    try original.write(to: file)
    try #require(chmod(file.path(percentEncoded: false), 0o644) == 0)
    let before = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
    let diagnostics = DiagnosticsLog(writesToSystemLog: false)
    let harness = await AttachHarness.make(
      directories: DirectoryStore(fileURL: file), diagnostics: diagnostics)
    let host = harness.hosts[0]
    let (discovered, record) = NewSessionSheetTests.created("fresh", id: 7, on: host)
    harness.discovery.setStatus(.ok([FakeDiscovery.session(on: host), discovered]), for: host.id)
    await Self.create(
      "fresh", in: "/Users/example/secret project", outcome: .success(record), harness: harness)
    #expect(harness.model.activities[discovered.key] == .confirmed)
    let events = await diagnostics.events().filter { $0.detail.hasPrefix("recent directory") }
    #expect(
      events.map(\.detail) == [
        "recent directory not recorded: fileNotUsable.unsafe.permissionsTooOpen"
      ])
    #expect(await diagnostics.events().allSatisfy { !$0.detail.contains("secret") })
    #expect(try Data(contentsOf: file) == original)
    let after = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
    #expect(after[.posixPermissions] as? Int == 0o644)
    #expect(after[.modificationDate] as? Date == before[.modificationDate] as? Date)
    #expect(after[.systemFileNumber] as? Int == before[.systemFileNumber] as? Int)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: base.path(percentEncoded: false))
        == [DirectoryStore.fileName])
    await harness.model.shutdown()
  } // End of func aRecordingLeavesAnUnusableFileAsItIs()

  /// The recents of hosts no longer in the host list (one removed in Settings, one never in it)
  /// go at the next write; the remaining hosts keep theirs.
  @Test func removedHostsLoseTheirRecentsAtTheNextWrite() async {
    let local = Support.localHost()
    let saturno = Support.sshHost("Saturno")
    let stranger = UUID()
    let store = InMemoryDirectoryStore(
      DirectoryLists(
        saved: ["~/saved"],
        recent: [saturno.id: ["~/s"], stranger: ["~/x"], local.id: ["~/old"]]))
    let harness = await AttachHarness.make(hosts: [local, saturno], directories: store)
    let (discovered, record) = NewSessionSheetTests.created("fresh", id: 7, on: local)
    harness.discovery.setStatus(.ok([FakeDiscovery.session(on: local), discovered]), for: local.id)
    await Self.create("fresh", in: "~/new", outcome: .success(record), harness: harness)
    #expect(await store.lists.recent == [local.id: ["~/new", "~/old"], saturno.id: ["~/s"]])

    harness.model.hostListSaved(try! HostList([local]))
    let (later, laterRecord) = NewSessionSheetTests.created("later", id: 8, on: local)
    harness.discovery.setStatus(
      .ok([FakeDiscovery.session(on: local), discovered, later]), for: local.id)
    await Self.create("later", in: "~/newer", outcome: .success(laterRecord), harness: harness)
    #expect(await store.lists.recent == [local.id: ["~/newer", "~/new", "~/old"]])
    #expect(await store.lists.saved == ["~/saved"])
    await harness.model.shutdown()
  } // End of func removedHostsLoseTheirRecentsAtTheNextWrite()

  /// A host list that did not load as `saved` (onboarding defaults, an unusable file) prunes
  /// nothing.
  @Test func anUnsavedHostListPrunesNothing() async {
    let store = InMemoryDirectoryStore()
    let stranger = UUID()
    _ = try? await store.apply(.recordRecent("~/x", hostID: stranger), knownHosts: nil)
    let model = AppModel(
      environment: AppEnvironment(
        loadHosts: { Support.loaded([Support.localHost()], state: .notSavedYet) },
        makeEngine: { RefreshCoordinator(hosts: $0, discovery: FakeDiscovery()) },
        makeSystemEvents: { _ in nil },
        terminate: {},
        directories: store))
    await model.start()
    #expect(model.knownHostIDs == nil)
    model.recordRecentDirectory("~/y", for: UUID())
    await model.directoryRecordingsHandled()
    #expect(await store.lists.recent(for: stranger) == ["~/x"])
    await model.shutdown()
  } // End of func anUnsavedHostListPrunesNothing()

  /// Which store each mode gets: the app the real `directories.json`; the self-tests an
  /// in-memory one (never the real file); the placement diagnostic and preview fixtures none.
  @Test func eachModeGetsItsOwnStore() async {
    let production = AppEnvironment.production(rewritesProfilesAtLaunch: false)
    let real = production.directories as? DirectoryStore
    #expect(real?.fileURL == DirectoryStore().fileURL)
    #expect(real?.fileURL.lastPathComponent == "directories.json")

    let run = await SelfTestDriverTests.run(SelfTestRequest(kind: .newSessionLocal))
    #expect(run.driver.makeEnvironment().directories is InMemoryDirectoryStore)
    #expect(!(run.driver.makeEnvironment().directories is DirectoryStore))

    #expect(AppEnvironment.placementDiagnostic().directories == nil)
    for fixture in PreviewFixtures.all + AttachFixtures.all {
      #expect(AppModel(fixture: fixture).environment == nil)
    }
  } // End of func eachModeGetsItsOwnStore()

  /// The `new-session-local` self-test passes and records nothing anywhere (its field is empty,
  /// and its store is in memory).
  @Test func theNewSessionSelfTestUsesItsInMemoryStore() async {
    let run = await SelfTestDriverTests.run(SelfTestRequest(kind: .newSessionLocal))
    await SelfTestDriverTests.prepare(run)
    #expect(await run.driver.run() == .passed, "\(run.log.all)")
    let store = run.driver.model?.environment?.directories as? InMemoryDirectoryStore
    #expect(store != nil)
    #expect(await store?.lists.isEmpty == true)
  }
}
