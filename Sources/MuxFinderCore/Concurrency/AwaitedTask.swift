/// Runs `operation` in a task of its own while `body` runs with that task, and on every way
/// out of `body` (a value, a thrown error, the calling task's cancellation) cancels the task
/// and waits until it has ended before returning or rethrowing.
///
/// This is the ordering a caller needs when the operation records something that later work
/// depends on: the e2e harness's `still waiting` step runs its attach this way, so when a
/// signal cancels the step while iTerm2's `CreateTab` is still pending, the step does not end
/// (and cleanup does not collect the launch tabs to close) before the attach has ended and
/// reported the tab it opened (the coordinator lets a `CreateTab` already sent complete, PLAN.md
/// D15). A plain `defer { task.cancel() }` does not wait, so cleanup could miss that tab.
///
/// The wait is as long as the operation takes to honor its cancellation; the caller makes sure
/// that is bounded (the attach coordinator's requests and sleeps are).
public func withAwaitedTask<Value: Sendable, Output>(
  isolation: isolated (any Actor)? = #isolation,
  _ operation: @escaping @Sendable () async -> Value,
  body: (Task<Value, Never>) async throws -> Output
) async rethrows -> Output {
  let task = Task { await operation() }
  do {
    let output = try await body(task)
    task.cancel()
    _ = await task.value
    return output
  } catch {
    task.cancel()
    _ = await task.value
    throw error
  }
} // End of func withAwaitedTask(isolation:_:body:)
