import Foundation
import Testing

@testable import MuxFinderUI

/// `--report-update-eligibility` (PLAN.md D39, Phase I-13b2): a mode of its own that is never
/// normal mode (no profile rewrite, no shortcut), with its usage line; combined with any other
/// mode, in either order, it is a usage error.
@Suite("Update eligibility flag")
struct UpdateEligibilityFlagTests {
  /// The flag alone, and every combination refused.
  @Test func parsing() {
    let flag = AppLaunchOptions(arguments: ["--report-update-eligibility"])
    #expect(flag.reportsUpdateEligibility && flag.usageError == nil)
    #expect(!flag.rewritesProfilesAtLaunch && !flag.registersGlobalShortcut)
    #expect(!AppLaunchOptions(arguments: []).reportsUpdateEligibility)
    #expect(
      AppLaunchOptions(arguments: ["--appearance", "dark", "--report-update-eligibility"])
        .usageError == nil)
    for other in [
      ["--preview-fixtures"], ["--report-menu-bar-item"], ["--report-login-item-status"],
      ["--report-popover-placement"], ["--report-hotkey-registration"],
      ["--selftest", "attach-local"], ["--remove-persistent-profiles"],
    ] {
      let combined = AppLaunchOptions(arguments: ["--report-update-eligibility"] + other)
      #expect(combined.usageError != nil, "\(other)")
      let reversed = AppLaunchOptions(arguments: other + ["--report-update-eligibility"])
      #expect(reversed.usageError != nil, "\(other)")
      #expect(!reversed.rewritesProfilesAtLaunch)
    } // End of loop over the other modes
    #expect(AppLaunchOptions.usage.contains(AppLaunchOptions.updateEligibilityUsage))
  } // End of func parsing()
}
