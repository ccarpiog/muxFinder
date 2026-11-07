import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The relauncher (PLAN.md D39, I-13b2): its argv (a constant script, every runtime value an
/// argument), and real detached runs with a harmless stand-in opener (never `/usr/bin/open`)
/// waiting for a `sleep` child of the test: nothing is opened while the pid runs, the opener
/// runs once after it ends, and a wait that runs out opens nothing and exits 75.
@Suite("Update relauncher")
struct UpdateRelauncherTests {
  /// Shorthand.
  typealias Support = UpdateInstallTestSupport

  /// The argv: `/bin/sh -c <script> muxfinder-relaunch <pid> <opener> <bundle> <wait>`, the
  /// script a constant holding none of the values; unusable values are refused.
  @Test func arguments() throws {
    let arguments = try UpdateRelauncher.arguments(
      processID: 4242, opener: "/usr/bin/open", bundlePath: "/Applications/muxFinder.app")
    #expect(
      arguments == [
        "/bin/sh", "-c", UpdateRelauncher.script, "muxfinder-relaunch", "4242", "/usr/bin/open",
        "/Applications/muxFinder.app", "60",
      ])
    #expect(!UpdateRelauncher.script.contains("4242"))
    #expect(!UpdateRelauncher.script.contains("Applications"))
    #expect(UpdateRelauncher.script.contains("exec \"$opener\" \"$bundle\""))
    #expect(UpdateRelauncher.environment == ["PATH=/usr/bin:/bin"])
    for (pid, opener, bundle, wait) in [
      (0, "/usr/bin/open", "/A.app", 60), (-3, "/usr/bin/open", "/A.app", 60),
      (1, "open", "/A.app", 60), (1, "/usr/bin/open", "A.app", 60),
      (1, "/usr/bin/open", "-a.app", 60), (1, "/usr/bin/open", "/A\n.app", 60),
      (1, "/usr/bin/open", "/A\0.app", 60), (1, "/usr/bin/open", "/A.app", 0),
      (1, "/usr/bin/open", "/A.app", 601),
    ] {
      #expect(throws: UpdateRelaunchError.unusableArgument) {
        try UpdateRelauncher.arguments(
          processID: Int32(pid), opener: opener, bundlePath: bundle, waitSeconds: wait)
      }
    } // End of loop over unusable arguments
    #expect(throws: UpdateRelaunchError.unusableArgument) {
      try UpdateRelauncher.spawn(["/usr/bin/true"])
    }
  } // End of func arguments()

  /// A real run: the relauncher starts in its own session and waits while the `sleep` child
  /// runs (nothing opened), then runs the stand-in opener once with the bundle path and exits
  /// 0 once the child has ended.
  @Test func waitsForThePidThenOpensOnce() async throws {
    let folder = try UpdateTestSupport.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let opener = try Support.makeStandInOpener(in: folder)
    let bundle = Support.path(folder) + "/muxFinder.app"
    let child = try Support.startSleep()
    defer { Support.stop(child) }
    let relauncher = DetachedUpdateRelauncher(opener: opener, waitSeconds: 30)
    let pid = try relauncher.relaunch(after: child.processIdentifier, bundlePath: bundle).get()
    #expect(getsid(pid) == pid)
    try await Task.sleep(for: .milliseconds(1200))
    #expect(Support.isRunning(pid))
    #expect(Support.openedLines(opener).isEmpty)
    Support.stop(child)
    #expect(await Support.waitForExit(pid) == 0)
    #expect(Support.openedLines(opener) == [bundle])
  } // End of func waitsForThePidThenOpensOnce()

  /// A wait that runs out opens nothing and exits 75; unusable arguments given to the script
  /// directly exit 64 and open nothing.
  @Test func timeoutOpensNothing() async throws {
    let folder = try UpdateTestSupport.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let opener = try Support.makeStandInOpener(in: folder)
    let child = try Support.startSleep()
    defer { Support.stop(child) }
    let arguments = try UpdateRelauncher.arguments(
      processID: child.processIdentifier, opener: opener,
      bundlePath: Support.path(folder) + "/muxFinder.app", waitSeconds: 1)
    let started = ContinuousClock.now
    let pid = try UpdateRelauncher.spawn(arguments)
    #expect(await Support.waitForExit(pid) == UpdateRelauncher.exitTimedOut)
    #expect(ContinuousClock.now - started >= .milliseconds(900))
    #expect(child.isRunning)
    #expect(Support.openedLines(opener).isEmpty)
    var unusable = arguments
    unusable[5] = "relative-opener"
    let refused = try UpdateRelauncher.spawn(unusable)
    #expect(await Support.waitForExit(refused) == UpdateRelauncher.exitUsage)
    unusable = arguments
    unusable[4] = "12x"
    #expect(await Support.waitForExit(try UpdateRelauncher.spawn(unusable)) == 64)
    #expect(Support.openedLines(opener).isEmpty)
  } // End of func timeoutOpensNothing()
}
