import Foundation
import MuxFinderCore

/// The Persistent profiles tab and the automatic updates of muxFinder's one iTerm2 file,
/// `DynamicProfiles/muxFinder.json` (PLAN.md D26).
///
/// - **One seam, one at a time:** every check, install, update and removal goes through
///   `SettingsEnvironment.persistentProfiles`, whose file work runs off the main actor (so the
///   installer's lock wait, at most 5 s, never blocks it) and contacts no iTerm2. Operations run
///   one at a time in the order asked: each waits for the one before. A fixture has no
///   environment, so nothing ever runs for it.
/// - **"Installed" is sticky:** the file is created only by "Install profiles"
///   (`PersistentProfileManaging.install(_:)`). The automatic updates (after a save, at launch)
///   go through `update(_:)`, which rewrites muxFinder's own installed file and never creates
///   one: it checks under the installer's lock that the file is there and muxFinder's, so a file
///   removed after the status was read stays removed. A file muxFinder did not generate is
///   never replaced or removed.
/// - **Snapshots, never the live list:** each operation takes its host list when it is asked
///   for and uses that value throughout, never the model's list after an `await` (a Settings
///   reload sets it loading, which reads as no host at all): Install and Remove the saved list
///   (`profileHosts`) as the tab showed it, Check again the same (nothing while the list is
///   loading or not loaded), the update after a save the list that save wrote. Never the host
///   editor's draft; the tab says so while the draft has unsaved changes.
/// - **After a save:** a save (or removal) that leaves muxFinder's installed file out of date
///   for the list it wrote updates the file at once, so iTerm2 sees the change; with no host's
///   profile left on, that removes the file (installer semantics).
/// - **At launch** (`keepProfilesCurrentAtLaunch(_:)`, normal mode only, `AppModel.start()`):
///   an out-of-date installed file is updated (the helper moved, say); a missing or current
///   file, an unusable helper path or any refusal writes nothing. Each outcome is logged by
///   kind only (category `profiles`); a failure stays as the tab's result line.
extension SettingsModel {
  /// Whether `hosts` is the saved, usable host list installs use: loaded or saved as `saved`,
  /// and no save found the file changed since.
  public var isProfileListSaved: Bool { hostListStatus == .saved && changedFile == nil }

  /// The hosts the profiles are made from: the saved list, or none while it is not saved (or
  /// loading). Operations read it once, when asked for, never after an `await`.
  var profileHosts: HostList { isProfileListSaved ? hosts : HostList() }

  /// What the Persistent profiles tab shows.
  public var persistentProfilesContent: PersistentProfilesContent {
    PersistentProfilesContent(
      status: profileStatus, hosts: hosts, isListSaved: isProfileListSaved, isDirty: isDirty,
      isRunning: profileOperations > 0, result: profileResult)
  }

  /// The window's opening and "Check again": reads the file's status for the saved hosts as
  /// they are now. Writes nothing; does nothing while the host list is loading or not loaded
  /// (the opening checks once it has loaded).
  public func checkProfiles() async {
    guard hostListStatus != nil else { return }
    let hosts = profileHosts
    await enqueueProfileOperation { model, files in
      model.profileStatus = await files.status(for: hosts)
    }?.value
  }

  /// "Install profiles": installs the saved hosts' profiles as the tab shows them (only while
  /// it offers that), shows the result and checks the status again for the same list.
  public func installProfiles() async {
    guard persistentProfilesContent.canInstall else { return }
    let hosts = profileHosts
    await enqueueProfileOperation { model, files in
      let change = await files.install(hosts)
      model.profileResult = PersistentProfileResult(change, trigger: .user)
      model.profileStatus = await files.status(for: hosts)
      await model.record(
        change.isFailure ? .failure : .success, category: .profiles,
        detail: "install profiles: \(change.kind)")
    }?.value
  } // End of func installProfiles()

  /// "Remove profiles": removes muxFinder's own file (only while one is installed), shows the
  /// result and checks the status again for the saved hosts as the tab showed them.
  public func removeProfiles() async {
    guard persistentProfilesContent.canRemove else { return }
    let hosts = profileHosts
    await enqueueProfileOperation { model, files in
      let change = await files.remove()
      model.profileResult = PersistentProfileResult(change, trigger: .user)
      model.profileStatus = await files.status(for: hosts)
      await model.record(
        change.isFailure ? .failure : .success, category: .profiles,
        detail: "remove profiles: \(change.kind)")
    }?.value
  } // End of func removeProfiles()

  /// After a save that wrote `saved`: when muxFinder's installed file no longer matches it,
  /// updates that file to its profiles (none left removes the file; a file gone meanwhile is
  /// not created again); otherwise only the status is updated. `saved` is used throughout,
  /// never the model's list, which a reload may have set loading by the time this runs.
  func updateProfilesAfterSave(_ saved: HostList) {
    enqueueProfileOperation { model, files in
      let status = await files.status(for: saved)
      guard status == .stale else {
        model.profileStatus = status
        return
      }
      let change = await files.update(saved)
      if PersistentProfileResult(change, trigger: .save).text != nil {
        model.profileResult = PersistentProfileResult(change, trigger: .save)
      }
      model.profileStatus = await files.status(for: saved)
      await model.record(
        change.isFailure ? .failure : .success, category: .profiles,
        detail: "profiles after a save: stale, \(change.kind)")
    }
  } // End of func updateProfilesAfterSave(_:)

  /// At launch (normal mode, a host list loaded as `saved`; PLAN.md D26): updates muxFinder's
  /// installed file to `hosts`' profiles only when it is out of date for them; a missing or
  /// current file, an unusable helper or a refusal writes nothing, and a file removed after
  /// the status was read is not created again. Logged by kind only; a change or failure
  /// becomes the tab's result line. Returns the queued operation (tests), or `nil` when
  /// nothing can run (a fixture, after `shutdown()`).
  @discardableResult
  public func keepProfilesCurrentAtLaunch(_ hosts: HostList) -> Task<Void, Never>? {
    enqueueProfileOperation { model, files in
      let status = await files.status(for: hosts)
      guard status == .stale else {
        let outcome: DiagnosticOutcome
        if case .unavailable = status { outcome = .failure } else { outcome = .info }
        await model.record(
          outcome, category: .profiles, detail: "profiles at launch: \(status.kind)")
        return
      }
      let change = await files.update(hosts)
      model.profileResult = PersistentProfileResult(change, trigger: .launch)
      await model.record(
        change.isFailure ? .failure : .success, category: .profiles,
        detail: "profiles at launch: stale, \(change.kind)")
    }
  } // End of func keepProfilesCurrentAtLaunch(_:)

  /// Returns once every profile operation queued so far has ended (tests).
  func profileOperationsFinished() async {
    await lastProfileOperation?.value
  }

  /// Queues `work` after the last profile operation, in a task `shutdown()` waits for. Nothing
  /// is queued for a fixture or after `shutdown()`; queued work that has not started by then
  /// is skipped.
  @discardableResult
  func enqueueProfileOperation(
    _ work:
      @escaping @MainActor @Sendable (SettingsModel, any PersistentProfileManaging) async
      -> Void
  ) -> Task<Void, Never>? {
    guard let files = environment?.persistentProfiles, !isShutDown else { return nil }
    let previous = lastProfileOperation
    profileOperations += 1
    let task = track { [weak self] in
      await previous?.value
      guard let self else { return }
      defer { self.profileOperations -= 1 }
      guard !self.isShutDown else { return }
      await work(self, files)
    }
    lastProfileOperation = task
    return task
  } // End of func enqueueProfileOperation(_:)
}
