import Foundation
import MuxFinderCore
import Observation

/// A terminal app's Automation permission as the picker shows it (PLAN.md D38, Phase I-12d1;
/// requirement 8), read without a prompt (`AutomationPermission`).
public enum TerminalPermissionLabel: String, Sendable, Hashable, CaseIterable {
  /// `granted`: Apple events may be sent.
  case allowed
  /// `denied`: the user turned it off, or refused the prompt.
  case notAllowed
  /// `notDetermined`: macOS asks the first time muxFinder opens a window there.
  case notAskedYet
  /// `targetNotRunning`: macOS can tell only while the app runs.
  case checkedWhenRunning
  /// Any other status.
  case unknown
  /// An `exec` definition: it sends no Apple event.
  case notNeeded

  /// The label for `automation`.
  public init(_ automation: TerminalAppFacts.Automation) {
    switch automation {
    case .notNeeded: self = .notNeeded
    case .permission(.granted, _): self = .allowed
    case .permission(.denied, _): self = .notAllowed
    case .permission(.notDetermined, _): self = .notAskedYet
    case .permission(.targetNotRunning, _): self = .checkedWhenRunning
    case .permission(.other, _): self = .unknown
    }
  }

  /// The label's text, sentence case.
  public var text: String {
    switch self {
    case .allowed: return "Allowed"
    case .notAllowed: return "Not allowed"
    case .notAskedYet: return "Not asked yet"
    case .checkedWhenRunning: return "Checked when the app is running"
    case .unknown: return "Unknown"
    case .notNeeded: return "Not needed"
    }
  }

  /// Whether the row offers "Allow in System Settings…" (Privacy & Security › Automation).
  public var offersSystemSettings: Bool { self == .notAllowed || self == .notAskedYet }
} // End of enum TerminalPermissionLabel

/// One row of the terminal picker (PLAN.md D38, Phase I-12d1): iTerm2, a loaded definition, or
/// an unknown stored id kept selected with its reason.
public struct TerminalPickerRow: Sendable, Hashable, Identifiable {
  /// The terminal id: `iterm2`, a definition's id, or the unknown stored id.
  public var id: String
  /// The name shown: "iTerm2", a definition's display name, or the quoted unknown id.
  public var name: String
  /// The installed version, when LaunchServices reads one.
  public var version: String?
  /// The Automation permission's state; `nil` for iTerm2 and an unknown id.
  public var permission: TerminalPermissionLabel?
  /// The one-line note under the row: plain mode's under every plain row, iTerm2's own.
  public var note: String?
  /// Why the row cannot be used now; only the selected row ever carries one (an unavailable
  /// choice stays selected and is never replaced).
  public var unavailableReason: String?
  /// Whether the row is a plain definition's.
  public var isPlain: Bool

  /// A row of these values.
  public init(
    id: String, name: String, version: String? = nil, permission: TerminalPermissionLabel? = nil,
    note: String? = nil, unavailableReason: String? = nil, isPlain: Bool
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.permission = permission
    self.note = note
    self.unavailableReason = unavailableReason
    self.isPlain = isPlain
  } // End of init(id:name:version:permission:note:unavailableReason:isPlain:)

  /// Whether the row offers "Allow in System Settings…".
  public var offersSystemSettings: Bool { permission?.offersSystemSettings == true }
} // End of struct TerminalPickerRow

/// A terminal definition file (or folder) the loader could not use, as the picker lists it: its
/// file name and the reason only (PLAN.md D38, Phase I-12d1).
public struct TerminalPickerProblem: Sendable, Hashable, Identifiable {
  /// Its position in the list.
  public var id: Int
  /// The file's (or folder's) name.
  public var fileName: String
  /// Why it is not used.
  public var reason: String

  /// A problem of these values.
  public init(id: Int, fileName: String, reason: String) {
    self.id = id
    self.fileName = fileName
    self.reason = reason
  }
}

/// What LaunchServices and the Automation permission said about the terminal apps, read at the
/// window's opening and on "Check again", never on a timer (PLAN.md D38, Phase I-12d1). Reading
/// launches nothing, sends no Apple event and shows no prompt; the permission is read off the
/// main actor, so a slow answer never holds Settings or onboarding.
public struct TerminalPickerReading: Sendable, Hashable {
  /// iTerm2's snapshot (installed, version, running).
  public var iTerm2: TerminalAppSnapshot
  /// Each loaded definition's facts, by definition id.
  public var facts: [String: TerminalAppFacts]

  /// A reading of these values.
  public init(iTerm2: TerminalAppSnapshot, facts: [String: TerminalAppFacts]) {
    self.iTerm2 = iTerm2
    self.facts = facts
  }

  /// Reads iTerm2's snapshot and every definition of `catalog`'s facts through `inspector`:
  /// LaunchServices' snapshots on the main actor, then every Automation permission off it, in a
  /// detached task (`TerminalAppFacts.automation(for:inspector:)`: without a prompt,
  /// `notNeeded` for `exec`), since `AEDeterminePermissionToAutomateTarget` may take a while.
  @MainActor
  public static func read(
    catalog: TerminalDefinitionCatalog,
    inspector: any TerminalAppInspecting
  ) async -> TerminalPickerReading {
    let iTerm2 = inspector.snapshot(bundleIdentifier: TerminalChoice.iTerm2BundleIdentifier)
    let definitions = catalog.definitions.map(\.definition)
    var snapshots: [String: TerminalAppSnapshot] = [:]
    for definition in definitions {
      snapshots[definition.id] = inspector.snapshot(bundleIdentifier: definition.bundleIdentifier)
    }
    let automations = await Task.detached(priority: .userInitiated) {
      var read: [String: TerminalAppFacts.Automation] = [:]
      for definition in definitions {
        read[definition.id] = TerminalAppFacts.automation(for: definition, inspector: inspector)
      }
      return read
    }.value
    var facts: [String: TerminalAppFacts] = [:]
    for definition in definitions {
      guard let snapshot = snapshots[definition.id], let automation = automations[definition.id]
      else { continue }
      facts[definition.id] = TerminalAppFacts(
        definition: definition, snapshot: snapshot, automation: automation)
    }
    return TerminalPickerReading(iTerm2: iTerm2, facts: facts)
  } // End of static func read(catalog:inspector:)
} // End of struct TerminalPickerReading

/// What the terminal picker shows (PLAN.md D38, Phase I-12d1; requirement 8), in Settings ›
/// General and onboarding's Terminal step. A pure value, so every rule is tested without
/// SwiftUI.
///
/// - **Rows:** iTerm2 when installed, then each loaded definition whose app is installed and
///   meets its minimum version (Terminal always; Ghostty from 1.3), by display name. The current
///   choice is listed whatever its state, with its reason when it cannot be used ("Ghostty isn't
///   installed.", "Ghostty 1.2 is older than 1.3.", "No terminal named “warp”.", "Can't read
///   Ghostty's version."): it stays selected and is never replaced.
/// - **Each plain row** shows its permission state and the plain-mode note.
/// - **Below:** the loader's problems (file name and reason), a refused save's error (the old
///   choice kept), and "Applies when the current action ends." while a change waits.
public struct TerminalPickerContent: Sendable, Hashable {
  /// The note under every plain row.
  public static let plainNote = "Plain tmux: windows and panes stay inside one terminal window."
  /// The note under iTerm2's row.
  public static let iTerm2Note = "Native tmux: each tmux window opens as an iTerm2 tab or window."
  /// The note while a change waits for a session action.
  public static let pendingText = "Applies when the current action ends."
  /// The line while the setting is not read yet.
  public static let readingText = "Reading the terminal setting…"

  /// The rows, in order.
  public var rows: [TerminalPickerRow]
  /// The selected row's id: the stored choice (a waiting change's, else the applied one's);
  /// `nil` while the setting is not read yet.
  public var selectedID: String?
  /// The definition files the loader could not use.
  public var problems: [TerminalPickerProblem]
  /// Why the last change could not be saved (the store's error); the old choice stays.
  public var saveError: String?
  /// "Applies when the current action ends." while a change waits.
  public var pendingNote: String?
  /// Whether a change is being saved.
  public var isSaving: Bool
  /// Whether the setting or the apps are not read yet.
  public var isReading: Bool

  /// A content of these values (fixtures).
  public init(
    rows: [TerminalPickerRow], selectedID: String?, problems: [TerminalPickerProblem] = [],
    saveError: String? = nil, pendingNote: String? = nil, isSaving: Bool = false,
    isReading: Bool = false
  ) {
    self.rows = rows
    self.selectedID = selectedID
    self.problems = problems
    self.saveError = saveError
    self.pendingNote = pendingNote
    self.isSaving = isSaving
    self.isReading = isReading
  } // End of init(rows:selectedID:problems:saveError:pendingNote:isSaving:isReading:)

  /// The selected row, if any.
  public var selectedRow: TerminalPickerRow? { rows.first { $0.id == selectedID } }

  /// The content for `choice` (the applied resolution), `pending` (a change waiting for a
  /// session action), the loaded `catalog` and the apps' `reading`; `saveError` and `isSaving`
  /// as the picker last saw them. Not resolved yet, or nothing read yet: no rows.
  public static func make(
    choice: TerminalChoiceResolution,
    pending: TerminalChoiceResolution?,
    catalog: TerminalDefinitionCatalog?,
    reading: TerminalPickerReading?,
    saveError: String? = nil,
    isSaving: Bool = false
  ) -> TerminalPickerContent {
    let selected = pending ?? choice
    let problems = (catalog?.problems ?? []).enumerated().map { index, problem in
      TerminalPickerProblem(id: index, fileName: problem.fileName, reason: problem.message)
    }
    let pendingNote = pending == nil ? nil : pendingText
    guard selected != .unresolved, let catalog, let reading else {
      return TerminalPickerContent(
        rows: [], selectedID: selected == .unresolved ? nil : selected.terminalID,
        problems: problems, saveError: saveError, pendingNote: pendingNote, isSaving: isSaving,
        isReading: true)
    }
    let rows = Self.rows(selected: selected, catalog: catalog, reading: reading)
    return TerminalPickerContent(
      rows: rows, selectedID: selected.terminalID, problems: problems, saveError: saveError,
      pendingNote: pendingNote, isSaving: isSaving, isReading: false)
  } // End of static func make(choice:pending:catalog:reading:saveError:isSaving:)

  /// The rows for `selected` (see the type).
  static func rows(
    selected: TerminalChoiceResolution,
    catalog: TerminalDefinitionCatalog,
    reading: TerminalPickerReading
  ) -> [TerminalPickerRow] {
    let selectedID = selected.terminalID
    var rows: [TerminalPickerRow] = []
    let iTerm2Installed = reading.iTerm2.url != nil
    if iTerm2Installed || selectedID == TerminalChoice.iTerm2ID {
      var reason: String?
      if selectedID == TerminalChoice.iTerm2ID, case .unavailable = selected {
        reason = "iTerm2 isn't installed."
      }
      rows.append(
        TerminalPickerRow(
          id: TerminalChoice.iTerm2ID, name: "iTerm2",
          version: iTerm2Installed ? reading.iTerm2.version : nil, note: iTerm2Note,
          unavailableReason: reason, isPlain: false))
    }
    let definitions = catalog.definitions.sorted { left, right in
      let order = left.definition.displayName.localizedStandardCompare(
        right.definition.displayName)
      return order == .orderedSame
        ? left.definition.id < right.definition.id : order == .orderedAscending
    }
    for loaded in definitions {
      let definition = loaded.definition
      let facts = reading.facts[definition.id]
      let isSelected = definition.id == selectedID
      guard facts?.versionCheck == .meets || isSelected else { continue }
      var reason: String?
      if isSelected {
        if case .unavailable(let failure) = selected {
          reason = Self.reason(failure, name: definition.displayName, installed: facts?.version)
        } else if let facts {
          reason = Self.reason(
            facts.versionCheck, name: definition.displayName, installed: facts.version,
            minimum: definition.minimumVersion)
        }
      }
      rows.append(
        TerminalPickerRow(
          id: definition.id, name: definition.displayName, version: facts?.version,
          permission: facts.map { TerminalPermissionLabel($0.automation) }, note: plainNote,
          unavailableReason: reason, isPlain: true))
    } // End of loop over the loaded definitions
    if case .unavailable(let failure) = selected, failure.reason == .unknownID,
      !rows.contains(where: { $0.id == selectedID })
    {
      rows.append(
        TerminalPickerRow(
          id: selectedID, name: TerminalChoice.displayID(selectedID),
          unavailableReason: Self.reason(failure, name: "", installed: nil), isPlain: false))
    }
    return rows
  } // End of static func rows(selected:catalog:reading:)

  /// The sentence for an unavailable choice of the terminal `name` (`installed` its version,
  /// when read).
  public static func reason(
    _ failure: TerminalChoiceUnavailable, name: String, installed: String?
  ) -> String {
    switch failure.reason {
    case .unknownID:
      return "No terminal named \(TerminalChoice.displayID(failure.terminalID))."
    case .notInstalled:
      return "\(name) isn't installed."
    case .versionTooOld(let minimum):
      return installed.map { "\(name) \($0) is older than \(minimum.text)." }
        ?? "\(name) is older than \(minimum.text)."
    case .versionUnknown:
      return "Can't read \(name)'s version."
    }
  } // End of static func reason(_:name:installed:)

  /// The sentence for a version check that does not pass (`nil` when it does).
  static func reason(
    _ check: TerminalAppFacts.VersionCheck, name: String, installed: String?,
    minimum: TerminalVersion
  ) -> String? {
    switch check {
    case .meets: return nil
    case .notInstalled: return "\(name) isn't installed."
    case .tooOld:
      return installed.map { "\(name) \($0) is older than \(minimum.text)." }
        ?? "\(name) is older than \(minimum.text)."
    case .unknown: return "Can't read \(name)'s version."
    }
  } // End of static func reason(_:name:installed:minimum:)
} // End of struct TerminalPickerContent

/// A fixed picker state for previews and the galleries: the content shown and the wording of
/// the applied choice. Built from synthetic data only.
public struct TerminalPickerFixture: Sendable, Hashable {
  /// What the picker shows.
  public var content: TerminalPickerContent
  /// The applied choice's wording (the strings that follow it elsewhere).
  public var wording: TerminalWording

  /// A fixture of `content` whose applied choice reads as `wording`.
  public init(content: TerminalPickerContent, wording: TerminalWording) {
    self.content = content
    self.wording = wording
  }
}

/// A window that shows the terminal picker: the last one to close drops a reading under way.
enum TerminalPickerWindow: Hashable, Sendable {
  /// Settings › General.
  case settings
  /// Onboarding's Terminal step.
  case onboarding
}

/// The terminal picker (PLAN.md D38, Phase I-12d1; requirement 8), shared by Settings › General
/// and onboarding's Terminal step. `AppModel` owns the one instance and keeps it current
/// (`update(choice:pending:catalog:)`); choosing goes through `AppModel.setTerminal(_:)`.
///
/// - **Reading:** the apps' facts and permissions are read (`TerminalPickerReading`) only at a
///   window's opening and on "Check again" (`refresh()`), never on a timer; a reading asked for
///   before the setting was read happens once the definitions are known. The permissions are
///   read off the main actor and the result shown when it arrives, only while it is the newest
///   reading (a newer "Check again", the last picker window closing or quitting drops it).
///   Until the first reading arrives the picker shows "Reading the terminal setting…"; on
///   "Check again" the earlier reading stays until the new one replaces it. After each reading
///   shown, `AppModel` resolves the stored choice again (`didRead`), so an app that became
///   usable (or stopped being) is followed.
/// - **Choosing** (`choose(_:)`): saved first; a refused save shows the store's error and keeps
///   the old choice; a change held by a pending session action shows its note.
/// - **"Allow in System Settings…"** opens Privacy & Security › Automation (a URL open through
///   the seam, no Apple event).
/// - **Fixtures** show a fixed content and run nothing.
@MainActor
@Observable
public final class TerminalPickerModel {
  /// The applied choice.
  public private(set) var choice: TerminalChoiceResolution
  /// A change waiting for the pending session actions, if any.
  public private(set) var pending: TerminalChoiceResolution?
  /// The definitions as loaded at launch; `nil` before.
  public private(set) var catalog: TerminalDefinitionCatalog?
  /// The apps as last read; `nil` before the first reading.
  public private(set) var reading: TerminalPickerReading?
  /// Why the last change could not be saved.
  public private(set) var saveError: String?
  /// Whether a change is being saved.
  public private(set) var isSaving = false
  /// Whether this model renders a fixture.
  public let isPreview: Bool

  /// Reads the apps; `nil` reads nothing (an inert picker).
  @ObservationIgnored private let inspector: (any TerminalAppInspecting)?
  /// Opens System Settings' Automation pane; `nil` does nothing.
  @ObservationIgnored private let openURL: (@MainActor @Sendable (URL) -> Void)?
  /// Saves and applies a choice (`AppModel.setTerminal(_:)`); `nil` changes nothing.
  @ObservationIgnored var setter:
    (@MainActor (String) async -> Result<TerminalChoiceResolution, PreferencesStoreError>?)?
  /// The fixture shown, if any.
  @ObservationIgnored private let fixture: TerminalPickerFixture?
  /// Whether a window asked for a reading before the definitions were known.
  @ObservationIgnored private var readingRequested = false
  /// The newest reading's number: a reading that ends is shown only while it is still the
  /// newest (a newer `refresh()`, the last window closing or `shutdown()` moves it on).
  @ObservationIgnored private var readingNumber = 0
  /// The readings under way, by number; each leaves when it ends, shown or dropped.
  @ObservationIgnored private var readingTasks: [Int: Task<Void, Never>] = [:]
  /// Callers of `readingFinished()`, resumed once the newest reading is shown or dropped.
  @ObservationIgnored private var readingWaiters: [CheckedContinuation<Void, Never>] = []
  /// The windows showing the picker now.
  @ObservationIgnored private var openWindows: Set<TerminalPickerWindow> = []
  /// Whether `shutdown()` ran: nothing is read any more.
  @ObservationIgnored private var isShutDown = false
  /// Runs after each reading is shown (`AppModel.resolveTerminalAgain()`).
  @ObservationIgnored var didRead: (@MainActor () -> Void)?

  /// A picker reading the apps through `inspector` and opening System Settings through
  /// `openURL`, for the applied `choice`. Nothing is read until `refresh()`.
  public init(
    choice: TerminalChoiceResolution = .iTerm2,
    inspector: (any TerminalAppInspecting)?,
    openURL: (@MainActor @Sendable (URL) -> Void)?
  ) {
    self.choice = choice
    self.inspector = inspector
    self.openURL = openURL
    fixture = nil
    isPreview = false
  }

  /// A picker that shows `fixture` and never runs anything.
  public init(fixture: TerminalPickerFixture) {
    choice = .iTerm2
    inspector = nil
    openURL = nil
    self.fixture = fixture
    isPreview = true
  }

  /// An inert picker: iTerm2 applied, nothing read, chosen or opened (models built without the
  /// app's terminal setting).
  public static func inert() -> TerminalPickerModel {
    TerminalPickerModel(inspector: nil, openURL: nil)
  }

  /// What the picker shows.
  public var content: TerminalPickerContent {
    if let fixture { return fixture.content }
    return TerminalPickerContent.make(
      choice: choice, pending: pending, catalog: catalog, reading: reading,
      saveError: saveError, isSaving: isSaving)
  }

  /// The applied choice's wording.
  public var wording: TerminalWording {
    fixture?.wording ?? TerminalWording(choice, catalog: catalog)
  }

  /// The applied choice's row as last read (its name, version and permission), for
  /// Diagnostics; `nil` while the choice is iTerm2 or not resolved yet, or before a reading.
  public var chosenRow: TerminalPickerRow? {
    guard !wording.isITerm2 else { return nil }
    let content = self.content
    if fixture != nil { return content.selectedRow }
    return content.rows.first { $0.id == choice.terminalID }
  }

  /// `AppModel`'s current state: the applied `choice`, a `pending` change and the loaded
  /// `catalog`. A reading a window asked for before the definitions were known happens now.
  func update(
    choice: TerminalChoiceResolution,
    pending: TerminalChoiceResolution?,
    catalog: TerminalDefinitionCatalog?
  ) {
    self.choice = choice
    self.pending = pending
    self.catalog = catalog
    if readingRequested, catalog != nil {
      refresh()
    }
  } // End of func update(choice:pending:catalog:)

  /// `AppModel`'s waiting change (`nil`: none).
  func setPending(_ pending: TerminalChoiceResolution?) {
    self.pending = pending
  }

  /// A window opened, or "Check again": starts reading the apps' facts and permissions (no
  /// event, no prompt, nothing launched; the permissions off the main actor) and returns at
  /// once; the reading is shown when it ends if it is still the newest. Before the definitions
  /// are known the reading waits for them. Does nothing for a fixture, an inert picker or after
  /// `shutdown()`.
  public func refresh() {
    guard let inspector, !isShutDown else { return }
    guard let catalog else {
      readingRequested = true
      return
    }
    readingRequested = false
    readingNumber += 1
    let number = readingNumber
    readingTasks[number] = Task { [weak self] in
      let reading = await TerminalPickerReading.read(catalog: catalog, inspector: inspector)
      self?.readingEnded(number, with: reading)
    }
  } // End of func refresh()

  /// The reading `number` ended: shown (then `didRead`, then the waiters) only while it is the
  /// newest; otherwise dropped.
  private func readingEnded(_ number: Int, with reading: TerminalPickerReading) {
    readingTasks[number] = nil
    guard number == readingNumber, !isShutDown else { return }
    self.reading = reading
    didRead?()
    resumeReadingWaiters()
  }

  /// `window` (Settings or onboarding) opened: reads the apps (`refresh()`).
  func windowOpened(_ window: TerminalPickerWindow) {
    openWindows.insert(window)
    refresh()
  }

  /// `window` closed: once no picker window is open, a reading under way (or one waiting for
  /// the definitions) is dropped.
  func windowClosed(_ window: TerminalPickerWindow) {
    openWindows.remove(window)
    if openWindows.isEmpty { dropReadings() }
  }

  /// Quitting: a reading under way is dropped and nothing is read any more.
  func shutdown() {
    isShutDown = true
    dropReadings()
  }

  /// Drops the readings under way (their results are never shown) and the one waiting for the
  /// definitions, and resumes the waiters.
  private func dropReadings() {
    readingRequested = false
    readingNumber += 1
    resumeReadingWaiters()
  }

  /// Resumes every caller of `readingFinished()`.
  private func resumeReadingWaiters() {
    let waiters = readingWaiters
    readingWaiters = []
    for waiter in waiters { waiter.resume() }
  }

  /// Returns once the newest reading is shown or dropped (at once when none is under way):
  /// what Settings' opening waits for.
  func readingFinished() async {
    guard readingTasks[readingNumber] != nil else { return }
    await withCheckedContinuation { readingWaiters.append($0) }
  }

  /// Returns once every reading started has ended, shown or dropped (tests).
  func readingsEnded() async {
    while let task = readingTasks.values.first {
      await task.value
    }
  }

  /// Chooses the terminal `id` (a row's): saves it through `AppModel.setTerminal(_:)`, which
  /// applies it at once or once the pending session actions end. A refused save keeps the old
  /// choice and shows the store's error. Does nothing for the selected row, while a save runs,
  /// for a fixture or an inert picker.
  public func choose(_ id: String) async {
    guard let setter, !isSaving, id != content.selectedID else { return }
    isSaving = true
    saveError = nil
    let result = await setter(id)
    isSaving = false
    if case .failure(let error) = result {
      saveError = error.errorDescription ?? "muxFinder couldn't save the terminal setting."
    }
  } // End of func choose(_:)

  /// "Allow in System Settings…": opens Privacy & Security › Automation (a URL open, no Apple
  /// event). Nothing for a fixture or an inert picker.
  public func allowInSystemSettings() {
    openURL?(FixIt.automationSettingsURL)
  }
} // End of class TerminalPickerModel
