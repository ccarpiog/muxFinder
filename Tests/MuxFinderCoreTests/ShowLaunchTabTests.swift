import Foundation
import Testing

@testable import MuxFinderCore

/// `AttachCoordinator.showLaunchTab(_:)` ("Show tab", PLAN.md D25): only a launch tab the
/// coordinator opened is restored and activated, by its session id; any other id sends
/// nothing. Its order around a pending bury is in `LaunchTabBurialTests`.
@Suite("Show launch tab")
struct ShowLaunchTabTests {
  /// Shorthand.
  typealias Support = AttachTestSupport

  /// The activations among `calls`.
  static func activations(_ calls: [FakeITerm2Integration.Call]) -> [ITerm2API.ActivateRequest] {
    calls.compactMap { call in
      if case .activate(let request) = call { return request }
      return nil
    }
  }

  /// A tab the coordinator never opened (a user's, or an empty id) is refused before anything
  /// is sent.
  @Test func refusesTabsItDidNotOpen() async {
    let iTerm2 = FakeITerm2Integration(script: Support.successScript(for: Support.session()))
    let coordinator = Support.coordinator(
      iTerm2: iTerm2, discovery: FakeDiscovery(.ok([Support.session()])),
      store: FakeLaunchStore())
    #expect(await coordinator.showLaunchTab("user-session") == .notOpenedHere)
    #expect(await coordinator.showLaunchTab("") == .notOpenedHere)
    #expect(await iTerm2.calls.isEmpty)
  }

  /// After an attach opened its launch tab, that tab is restored (it was buried, PLAN.md D29)
  /// and then activated by its session id with `select_session`, `select_tab`,
  /// `order_window_front` and the app options; a refusal is reported as a failure.
  @Test func showsItsOwnLaunchTab() async {
    let session = Support.session()
    let iTerm2 = FakeITerm2Integration(script: Support.successScript(for: session))
    let coordinator = Support.coordinator(
      iTerm2: iTerm2, discovery: FakeDiscovery(.ok([session])), store: FakeLaunchStore())
    let result = await coordinator.attach(AttachTarget(host: Support.host, session: session))
    #expect(result.isConfirmed)
    await iTerm2.clearCalls()
    #expect(await coordinator.showLaunchTab(Support.gateway) == .shown)
    #expect(await iTerm2.calls.first == .setBuried(buried: false, sessionID: Support.gateway))
    let requests = Self.activations(await iTerm2.calls)
    #expect(requests.count == 1)
    #expect(requests.first?.target == .session(Support.gateway))
    #expect(requests.first?.selectSession == true)
    #expect(requests.first?.selectTab == true)
    #expect(requests.first?.orderWindowFront == true)
    #expect(requests.first?.activateApp == .init(ignoringOtherApps: true))
    await iTerm2.updateScript { $0.activate = .init(.failure(.activateFailed(.badIdentifier))) }
    #expect(
      await coordinator.showLaunchTab(Support.gateway) == .failed(.activateFailed(.badIdentifier)))
    #expect(await coordinator.showLaunchTab("user-session") == .notOpenedHere)
    #expect(Self.activations(await iTerm2.calls).count == 2)
  } // End of func showsItsOwnLaunchTab()
}
