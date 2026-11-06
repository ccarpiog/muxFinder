import Foundation
import Testing

@testable import MuxFinderCore

/// The Automation permission's states, mapped from the status
/// `AEDeterminePermissionToAutomateTarget` returns (PLAN.md D38).
@Suite("Automation permission")
struct AutomationPermissionTests {
  /// The four documented statuses map to their states, with stable kinds.
  @Test func mapsTheDocumentedStatuses() {
    #expect(AutomationPermission(status: 0) == .granted)
    #expect(AutomationPermission(status: -1743) == .denied)
    #expect(AutomationPermission(status: -1744) == .notDetermined)
    #expect(AutomationPermission(status: -600) == .targetNotRunning)
    #expect(AutomationPermission(status: 0).kind == "granted")
    #expect(AutomationPermission(status: -1743).kind == "denied")
    #expect(AutomationPermission(status: -1744).kind == "notDetermined")
    #expect(AutomationPermission(status: -600).kind == "targetNotRunning")
  }

  /// Any other status is kept as it came, never read as one of the four.
  @Test(arguments: [Int32(-1), -50, -609, -1712, -1745, 1, Int32.min, Int32.max])
  func keepsOtherStatuses(status: Int32) {
    let permission = AutomationPermission(status: status)
    #expect(permission == .other(status: status))
    #expect(permission.kind == "other")
    #expect(!permission.allowsEventsWithoutPrompt)
  }

  /// Only `granted` allows sending events without a prompt (PLAN.md *Unattended-run rules* 8).
  @Test func onlyGrantedAllowsEvents() {
    #expect(AutomationPermission.granted.allowsEventsWithoutPrompt)
    for state in [AutomationPermission.denied, .notDetermined, .targetNotRunning] {
      #expect(!state.allowsEventsWithoutPrompt)
    }
  }
} // End of struct AutomationPermissionTests
