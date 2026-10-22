import Foundation
import MuxFinderCore

/// One fixed onboarding window state for previews, the `--preview-gallery onboarding` window
/// and tests (PLAN.md D24). Built from synthetic data only.
public struct OnboardingFixture: Sendable, Identifiable {
  /// A short, stable name.
  public var id: String
  /// The caption shown above the state in the preview window.
  public var title: String
  /// The hosts being edited.
  public var drafts: [HostDraft]
  /// Whether a save runs.
  public var isSaving = false
  /// A save's error.
  public var saveError: String?
  /// Whether the save found the file changed.
  public var fileChanged = false
  /// Why a host could not be turned on, by host id.
  public var enableRefusals: [UUID: String] = [:]
  /// "Set up SSH in iTerm2…" lines, by host id.
  public var sshSetupStates: [UUID: SSHSetupState] = [:]

  /// A fixture of `drafts` with `configure` applied.
  public init(
    id: String, title: String, drafts: [HostDraft],
    configure: (inout OnboardingFixture) -> Void = { _ in }
  ) {
    self.id = id
    self.title = title
    self.drafts = drafts
    configure(&self)
  }

  /// Changes the draft with `id`.
  mutating func edit(_ id: UUID, _ change: (inout HostDraft) -> Void) {
    guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
    change(&drafts[index])
  }
}

/// Every onboarding state, from synthetic data only: the brief's example names with fixed ids
/// and `*.example` destinations (never a name from an SSH configuration). Building them runs
/// nothing.
public enum OnboardingFixtures {
  /// Shorthand.
  typealias Fixtures = PreviewFixtures

  /// The onboarding examples as `HostList.onboardingDefaults()` makes them, with fixed ids:
  /// Saturno, Neptuno and Sirio, SSH, no destination, turned off.
  static let examples: [HostDraft] = ["Saturno", "Neptuno", "Sirio"].enumerated().map {
    index, name in
    HostDraft(
      HostConfig(
        id: Fixtures.fixtureID(30 + index), displayName: name, mode: .ssh, isEnabled: false))
  }
  /// Saturno's id.
  static let saturnoID = examples[0].id
  /// Neptuno's id.
  static let neptunoID = examples[1].id
  /// Sirio's id.
  static let sirioID = examples[2].id

  /// An inert, empty model state (the popover fixtures' onboarding model).
  public static let blank = OnboardingFixture(id: "blank", title: "Blank", drafts: [])

  /// The examples as they come: nothing chosen, nothing turned on.
  public static let examplesShown = OnboardingFixture(
    id: "examples", title: "Examples as they come", drafts: examples)

  /// Neptuno chosen as This Mac, Saturno with a destination and turned on after its ssh tab
  /// opened, Sirio with a destination, still off.
  public static let filledIn = OnboardingFixture(
    id: "filled-in", title: "This Mac chosen, SSH set up", drafts: examples
  ) {
    $0.edit(neptunoID) {
      $0.mode = .local
      $0.isEnabled = true
    }
    $0.edit(saturnoID) {
      $0.sshDestination = "saturno.example"
      $0.isEnabled = true
    }
    $0.edit(sirioID) { $0.sshDestination = "admin@sirio.example" }
    $0.sshSetupStates = [saturnoID: .opened]
  }

  /// Inline errors: no name, a name another host has, a destination with a space, and a host
  /// that could not be turned on.
  public static let validation = OnboardingFixture(
    id: "validation", title: "Validation errors", drafts: examples
  ) {
    $0.edit(saturnoID) { $0.displayName = "" }
    $0.edit(neptunoID) { $0.displayName = "sirio" }
    $0.edit(sirioID) { $0.sshDestination = "sirio .example" }
    $0.enableRefusals = [sirioID: HostDraftIssues.destinationNeededToTurnOn]
  }

  /// "Set up SSH in iTerm2…" opening for Saturno and failed for Sirio (iTerm2's Python API is
  /// off, with its fix-it).
  public static let sshSetup = OnboardingFixture(
    id: "ssh-setup", title: "Set up SSH: opening and failed", drafts: examples
  ) {
    $0.edit(saturnoID) { $0.sshDestination = "saturno.example" }
    $0.edit(sirioID) { $0.sshDestination = "sirio.example" }
    $0.sshSetupStates = [saturnoID: .opening, sirioID: .failed(.iTerm2(.apiDisabled))]
  }

  /// A save in progress.
  public static let saving = OnboardingFixture(
    id: "saving", title: "Saving", drafts: filledIn.drafts
  ) {
    $0.isSaving = true
  }

  /// The save refused because the host list file appeared since launch.
  public static let fileChanged = OnboardingFixture(
    id: "file-changed", title: "Host list saved elsewhere", drafts: filledIn.drafts
  ) {
    $0.fileChanged = true
    $0.saveError = OnboardingModel.fileChangedMessage
  }

  /// The save failed for another reason.
  public static let saveFailed = OnboardingFixture(
    id: "save-failed", title: "Save failed", drafts: filledIn.drafts
  ) {
    $0.saveError = HostStoreError.directoryNotOwnedByUser.errorDescription
  }

  /// Every fixture, in the preview window's order.
  public static let all = [
    examplesShown, filledIn, validation, sshSetup, saving, fileChanged, saveFailed,
  ]
}
