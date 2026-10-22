import Foundation
import Testing
import os

@testable import MuxFinderCore

/// `withAwaitedTask(_:body:)`: the operation is cancelled and waited for on every way out of
/// the body, so whatever it records is there when the caller goes on. The last test is the
/// e2e harness's `still waiting` step in miniature (the Phase 5b review): a step cancelled
/// while iTerm2's `CreateTab` is pending still learns the launch tab before it ends, which a
/// `defer { attach.cancel() }` that does not wait misses.
@Suite("Awaited task")
struct AwaitedTaskTests {
  /// An operation that waits until it is cancelled, then takes another 100 ms before it ends,
  /// so a caller that does not wait for it returns before it has ended.
  final class SlowToStop: Sendable {
    /// Whether the operation started and whether it ended.
    private let state = OSAllocatedUnfairLock(initialState: (started: false, ended: false))

    /// Whether the operation started.
    var started: Bool { state.withLock { $0.started } }
    /// Whether the operation ended.
    var ended: Bool { state.withLock { $0.ended } }

    /// The operation: waits for cancellation, then 100 ms more, records its end and returns 7.
    func run() async -> Int {
      state.withLock { $0.started = true }
      try? await Task.sleep(for: .seconds(3600))
      // `Task.sleep` would end at once in a cancelled task.
      let deadline = ContinuousClock.now + .milliseconds(100)
      while ContinuousClock.now < deadline { await Task.yield() }
      state.withLock { $0.ended = true }
      return 7
    }
  } // End of class SlowToStop

  /// An error a body throws.
  struct BodyError: Error, Equatable {}

  /// After the body returns, the operation is cancelled and has ended before the call returns
  /// the body's value; the body could see the running task.
  @Test(.timeLimit(.minutes(1)))
  func waitsForTheOperationAfterTheBodyReturns() async throws {
    let operation = SlowToStop()
    let output = await withAwaitedTask(
      { await operation.run() },
      body: { task in
        _ = await TestSupport.eventually { operation.started }
        return task.isCancelled ? "cancelled" : "running"
      })
    #expect(output == "running")
    #expect(operation.ended)
  } // End of func waitsForTheOperationAfterTheBodyReturns()

  /// After the body throws, the operation is cancelled and has ended before the error comes
  /// back.
  @Test(.timeLimit(.minutes(1)))
  func waitsForTheOperationAfterTheBodyThrows() async throws {
    let operation = SlowToStop()
    await #expect(throws: BodyError()) {
      try await withAwaitedTask(
        { await operation.run() },
        body: { _ in
          _ = await TestSupport.eventually { operation.started }
          throw BodyError()
        })
    }
    #expect(operation.ended)
  } // End of func waitsForTheOperationAfterTheBodyThrows()

  /// When the calling task is cancelled while the body waits, the body's cancellation error
  /// comes back only once the operation has ended.
  @Test(.timeLimit(.minutes(1)))
  func waitsForTheOperationWhenTheCallerIsCancelled() async throws {
    let operation = SlowToStop()
    let caller = Task { () -> (cancelled: Bool, endedFirst: Bool) in
      do {
        try await withAwaitedTask(
          { await operation.run() }, body: { _ in try await Task.sleep(for: .seconds(3600)) })
        return (false, operation.ended)
      } catch {
        return (error is CancellationError, operation.ended)
      }
    }
    #expect(await TestSupport.eventually { operation.started })
    caller.cancel()
    let outcome = await caller.value
    #expect(outcome.cancelled)
    #expect(outcome.endedFirst)
  } // End of func waitsForTheOperationWhenTheCallerIsCancelled()

  /// A step running an attach through `withAwaitedTask`, cancelled (a signal) while the
  /// launch's `CreateTab` is pending, ends only after `CreateTab` answered and the attach
  /// reported its launch tab, so the tab is among the updates when cleanup collects them.
  @Test(.timeLimit(.minutes(1)))
  func aCancelledStepStillLearnsItsLaunchTab() async throws {
    let (harness, iTerm2) = AttachCoordinatorTests.instrumented(holdsFirstCreateTab: true) {
      script in
      script.listTmuxConnections = .init(.success([]))
    }
    let coordinator = harness.coordinator
    let target = harness.target
    let log = harness.log
    let step = Task { () -> (gateways: [String], result: AttachResult?) in
      var result: AttachResult?
      do {
        try await withAwaitedTask(
          { await coordinator.attach(target) },
          body: { attach in
            // The step's polling, until a signal cancels it.
            try await Task.sleep(for: .seconds(3600))
            result = await attach.value
          })
      } catch {}
      let gateways = log.all.compactMap { update -> String? in
        if case .launched(let sessionID) = update.state { return sessionID }
        return nil
      }
      return (gateways, result)
    }
    try await waitUntil(timeout: .seconds(5), "the CreateTab is held") {
      iTerm2.isHoldingCreateTab
    }
    step.cancel()
    // iTerm2 answers the CreateTab a moment later.
    try await Task.sleep(for: .milliseconds(200))
    iTerm2.releaseCreateTab()
    let outcome = await step.value
    #expect(outcome.gateways == [AttachTestSupport.gateway])
    #expect(outcome.result == nil)
    let states = log.all.map(\.state)
    #expect(states.first == .requested)
    #expect(states.contains(.launched(sessionID: AttachTestSupport.gateway)))
    #expect(states.last == .failed(.cancelled))
  } // End of func aCancelledStepStillLearnsItsLaunchTab()
}
