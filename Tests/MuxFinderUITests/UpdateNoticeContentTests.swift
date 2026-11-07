import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// The update notice's one pure mapping (PLAN.md D39 *The update views (I-13c2b)*):
/// `UpdateNoticeContent.make` over every flow state against every offer (none, reading, Update,
/// Download), `canUpdate` true and false: the title, What's new, the lines, the bar, the
/// activity indicator, which buttons show and which can be pressed, VoiceOver's labels, the
/// bar's value and the announcements; no line holds a path, URL or header.
@MainActor
@Suite("Update notice content")
struct UpdateNoticeContentTests {
  /// The shown release.
  static let release = UpdateFlowTests.release("0.3.0")
  /// A newer release a prepare started for before the notice changed.
  static let prepared = UpdateFlowTests.release("0.2.5")
  /// A Download offer's reason.
  static let downloadReason = UpdateIneligibility.notDeveloperID.reason
  /// A prepare failure.
  static let failure = UpdateFlowFailure.prepare(.verification(.download(.digestMismatch)))

  /// Every offer the notice can be given (`nil`: none handed to the flow).
  static let offers: [UpdateFlowOffer?] = [
    nil, .reading, .update, .download(reason: downloadReason),
  ]

  /// Every state, the downloading one with and without a known total, the ask with one and
  /// two items.
  static let states: [UpdateFlowState] = [
    .idle, .downloading(bytes: 40, total: 100), .downloading(bytes: 40, total: 0), .checking,
    .prepared, .asking(UpdateUnsavedWork(newSessionDraft: true)),
    .asking(UpdateUnsavedWork(newSessionDraft: true, settingsEdits: true)), .deferred,
    .installing, .relaunchScheduled, .failed(failure),
  ]

  /// The content for `state` and `offer`.
  static func content(
    _ state: UpdateFlowState, _ offer: UpdateFlowOffer?, canUpdate: Bool = true,
    prepared: UpdateRelease? = nil
  ) -> UpdateNoticeContent {
    UpdateNoticeContent.make(
      release: release, offer: offer, state: state, canUpdate: canUpdate,
      preparedRelease: prepared)
  }

  /// The buttons the calls give `state` with `offer` and `canUpdate`, in order.
  static func expectedActions(
    _ state: UpdateFlowState, _ offer: UpdateFlowOffer?, canUpdate: Bool
  ) -> [UpdateNoticeAction] {
    switch state {
    case .idle:
      switch offer {
      case .update?: return [.update]
      case .download?: return [.download]
      default: return []
      }
    case .downloading, .checking: return [.cancel]
    case .prepared, .installing, .relaunchScheduled: return []
    case .asking: return [.quitAndInstall, .notNow]
    case .deferred: return [.installAndRelaunch]
    case .failed:
      switch offer {
      case .update?: return canUpdate ? [.update, .releasePage] : [.releasePage]
      case .download?: return [.download, .releasePage]
      default: return [.releasePage]
      }
    }
  } // End of static func expectedActions(_:_:canUpdate:)

  /// Every state against every offer and both `canUpdate` values: the buttons as the calls
  /// say (Update or Download only from idle or a failure, never while reading or with no
  /// offer), Update enabled exactly while `canUpdate`, every other button enabled; the title
  /// and What's new everywhere but installing and relaunching.
  @Test func everyStateAgainstEveryOffer() {
    for state in Self.states {
      for offer in Self.offers {
        for canUpdate in [true, false] {
          let content = Self.content(state, offer, canUpdate: canUpdate)
          let label = "\(state) \(String(describing: offer)) canUpdate \(canUpdate)"
          #expect(
            content.buttons.map(\.action)
              == Self.expectedActions(state, offer, canUpdate: canUpdate), "\(label)")
          for button in content.buttons {
            #expect(
              button.isEnabled == (button.action == .update ? canUpdate : true), "\(label)")
          }
          switch state {
          case .installing, .relaunchScheduled:
            #expect(content.whatsNew == nil, "\(label)")
            #expect(content.lines.isEmpty, "\(label)")
            #expect(content.showsActivity, "\(label)")
          default:
            #expect(content.title == "muxFinder 0.3.0 is available", "\(label)")
            #expect(content.whatsNew?.action == .whatsNew, "\(label)")
            #expect(content.whatsNew?.isEnabled == true, "\(label)")
          }
        } // End of loop over canUpdate
      } // End of loop over the offers
    } // End of loop over the states
  } // End of func everyStateAgainstEveryOffer()

  /// The lines, the bar and the activity indicator per state.
  @Test func linesPerState() {
    /// The lines' texts.
    func texts(_ content: UpdateNoticeContent) -> [String] { content.lines.map(\.text) }
    #expect(texts(Self.content(.idle, .reading)).isEmpty)
    #expect(texts(Self.content(.idle, nil)).isEmpty)
    #expect(texts(Self.content(.idle, .update)).isEmpty)
    let download = Self.content(.idle, .download(reason: Self.downloadReason))
    #expect(
      texts(download) == ["Can't update in place: this copy isn't signed with a Developer ID"])
    #expect(download.lines.map(\.style) == [.note])

    let known = Self.content(.downloading(bytes: 40, total: 100), .update)
    #expect(texts(known) == ["Downloading… 40%"])
    #expect(known.progress?.fraction == 0.4)
    #expect(known.progress?.accessibilityValue == "40%")
    #expect(!known.showsActivity)
    let unknown = Self.content(.downloading(bytes: 40, total: 0), .update)
    #expect(texts(unknown) == ["Downloading…"])
    #expect(unknown.progress == nil)
    #expect(unknown.showsActivity)

    let checking = Self.content(.checking, .update)
    #expect(texts(checking) == ["Checking the download…"])
    #expect(checking.progress == nil)
    #expect(checking.showsActivity)
    #expect(texts(Self.content(.prepared, .update)) == ["Download checked"])

    let one = Self.content(.asking(UpdateUnsavedWork(newSessionDraft: true)), .update)
    #expect(
      texts(one) == [
        "Quitting to install loses the New session draft.",
        "Attached tmux sessions are not affected.",
      ])
    #expect(one.lines.map(\.style) == [.status, .note])
    let two = Self.content(
      .asking(UpdateUnsavedWork(newSessionDraft: true, settingsEdits: true)), .update)
    #expect(
      texts(two).first
        == "Quitting to install loses the New session draft and unsaved changes in Settings.")
    let settings = Self.content(.asking(UpdateUnsavedWork(settingsEdits: true)), .update)
    #expect(texts(settings).first == "Quitting to install loses unsaved changes in Settings.")

    #expect(texts(Self.content(.deferred, .update)) == ["muxFinder 0.3.0 is ready to install"])
    #expect(
      texts(Self.content(.deferred, .update, prepared: Self.prepared))
        == ["muxFinder 0.2.5 is ready to install"])
    #expect(Self.content(.installing, .update).title == "Installing…")
    #expect(Self.content(.relaunchScheduled, .update).title == "Relaunching…")

    let failed = Self.content(.failed(Self.failure), .update)
    #expect(
      texts(failed) == ["Couldn't update: the download doesn't match the release's checksum"])
    #expect(failed.lines.map(\.style) == [.problem])
    #expect(failed.progress == nil)
    #expect(!failed.showsActivity)
  } // End of func linesPerState()

  /// A failure: Release page always (a link); Update again only while `canUpdate`; Download
  /// when the offer turned into one, its reason shown only when the failure's phrase does not
  /// say it already.
  @Test func failedWithAndWithoutCanUpdate() {
    let able = Self.content(.failed(Self.failure), .update, canUpdate: true)
    #expect(able.buttons.map(\.action) == [.update, .releasePage])
    #expect(able.button(.update)?.isEnabled == true)
    #expect(able.button(.releasePage)?.style == .link)
    let unable = Self.content(.failed(Self.failure), .update, canUpdate: false)
    #expect(unable.buttons.map(\.action) == [.releasePage])
    #expect(unable.button(.update) == nil)

    let refusal = UpdateFlowFailure.prepare(.notEligible(.translocated))
    let turned = Self.content(
      .failed(refusal), .download(reason: UpdateIneligibility.translocated.reason),
      canUpdate: false)
    #expect(turned.buttons.map(\.action) == [.download, .releasePage])
    #expect(turned.lines.map(\.text) == [refusal.phrase])
    let other = Self.content(
      .failed(Self.failure), .download(reason: Self.downloadReason), canUpdate: false)
    #expect(
      other.lines.map(\.text) == [
        Self.failure.phrase, "Can't update in place: " + Self.downloadReason,
      ])
    #expect(Self.content(.failed(Self.failure), .reading).buttons.map(\.action) == [.releasePage])
  } // End of func failedWithAndWithoutCanUpdate()

  /// VoiceOver: each button labelled with its action and the version (the prepared release's
  /// for Cancel, the ask and Install and relaunch), with a hint; the bar's value; the failure
  /// and the ask announced, nothing else.
  @Test func voiceOver() {
    #expect(
      Self.content(.idle, .update).whatsNew?.accessibilityLabel == "What's new in muxFinder 0.3.0")
    #expect(
      Self.content(.idle, .update).button(.update)?.accessibilityLabel
        == "Update to muxFinder 0.3.0")
    #expect(
      Self.content(.idle, .download(reason: Self.downloadReason)).button(.download)?
        .accessibilityLabel == "Download muxFinder 0.3.0")
    let downloading = Self.content(
      .downloading(bytes: 40, total: 100), .update, prepared: Self.prepared)
    #expect(
      downloading.button(.cancel)?.accessibilityLabel == "Cancel the update to muxFinder 0.2.5")
    #expect(downloading.progress?.accessibilityValue == "40%")
    #expect(UpdateNoticeProgress.accessibilityLabel == "Download progress")
    let work = UpdateUnsavedWork(newSessionDraft: true)
    let asking = Self.content(.asking(work), .update)
    #expect(
      asking.button(.quitAndInstall)?.accessibilityLabel == "Quit and install muxFinder 0.3.0")
    #expect(asking.button(.notNow)?.accessibilityLabel == "Not now: install muxFinder 0.3.0 later")
    #expect(
      Self.content(.deferred, .update).button(.installAndRelaunch)?.accessibilityLabel
        == "Install muxFinder 0.3.0 and relaunch")
    #expect(
      Self.content(.failed(Self.failure), .update).button(.releasePage)?.accessibilityLabel
        == "Release page of muxFinder 0.3.0")
    for state in Self.states {
      for offer in Self.offers {
        let content = Self.content(state, offer)
        for button in content.buttons + [content.whatsNew].compactMap({ $0 }) {
          #expect(button.accessibilityLabel.contains("muxFinder 0."), "\(button.action)")
          #expect(button.accessibilityHint?.isEmpty == false, "\(button.action)")
        }
      }
    } // End of loop over the states' buttons
    #expect(Self.content(.failed(Self.failure), .update).announcement == Self.failure.phrase)
    #expect(
      asking.announcement
        == "muxFinder 0.3.0 is ready to install. Quitting to install loses the New session draft."
        + " Attached tmux sessions are not affected.")
    #expect(
      UpdateNoticeContent.announcement(state: .asking(work), version: nil)
        == "Quitting to install loses the New session draft. Attached tmux sessions are not affected."
    )
    for state in Self.states {
      switch state {
      case .failed, .asking: #expect(Self.content(state, .update).announcement != nil)
      default: #expect(Self.content(state, .update).announcement == nil, "\(state)")
      }
    }
  } // End of func voiceOver()

  /// No line, label, hint, value or announcement holds a path, URL or HTTP header, for every
  /// state and offer and the typed failures' phrases (an install's rollback that names its run
  /// folder included).
  @Test func noPathURLOrHeader() {
    let failures: [UpdateFlowFailure] = [
      Self.failure, .prepare(.notEligible(.differentVolume)), .prepare(.stagingRoot(.busy)),
      .prepare(.verification(.download(.foreignURL))),
      .prepare(.verification(.download(.redirectRefused(.hostNotAllowed)))),
      .prepare(.verification(.download(.contentLengthMismatch))),
      .prepare(.verification(.download(.httpStatus(503)))),
      .install(.swapFailed(errno: 5), rollback: .rolledBack),
      .install(.swapUnconfirmed, rollback: .recoveryRequired(runFolder: "/private/tmp/mfx.run")),
      .install(.swapUnconfirmed, rollback: .failed(runFolder: "/private/tmp/mfx.run")),
    ]
    let states = Self.states + failures.map { UpdateFlowState.failed($0) }
    let forbidden = [
      "/", "://", "github.com", "http:", "etag", "content-length", "user-agent", "accept:",
      "authorization", "if-none-match", "location:",
    ]
    for state in states {
      for offer in Self.offers + [.download(reason: UpdateFlowText.noInstallableAsset)] {
        for text in Self.content(state, offer, prepared: Self.prepared).texts {
          for word in forbidden {
            #expect(!text.lowercased().contains(word), "\(state): \(text)")
          }
        }
      }
    } // End of loop over the states
  } // End of func noPathURLOrHeader()
}
