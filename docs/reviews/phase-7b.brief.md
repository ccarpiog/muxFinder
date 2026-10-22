# Phase 7b review brief — refresh engine

- Repo: /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM, macOS 14 menu bar app that
  discovers tmux sessions on the user's Macs and attaches them in iTerm2 via `tmux -CC`).
- Phase: 7b, risk high. Review the **uncommitted** working tree against `HEAD`.
- Goal (`PLAN.md` "### Phase 7", *Requirements*, *Acceptance*, *Split* 7b bullet; design recorded
  as new decision **D20** in `PLAN.md` *Decisions*): a race-free refresh loop.
  `RefreshCoordinator` (actor; concurrency limit 3; per-host single flight with coalescing;
  generation tokens plus config revision so late, edited-host or removed-host results are
  dropped; cadence immediate on popover open, 15 s while visible, 5 min in background;
  background-only failure backoff 30 s, 1 m, 2 m, 5 m, 15 m, reset on success, bypassed by
  manual retry; sleep cancels in-flight work and kills probe process groups; wake refreshes after
  5 s; network change refreshes failing hosts; `stop()` leaves no tasks or processes),
  `HostSnapshot` (live or stale, `lastSuccess`/`lastAttempt`; sessions kept but marked stale
  after a failure that follows a success; same session name on two hosts stays two entries),
  the `AttachmentIndex` (D16) merge with its failure policy, a sleep/wake/network adapter, and
  `muxfinder-probe refresh --once [--config <path>] [--attachments]`.

## Changed files

- New: `Sources/MuxFinderCore/Refresh/RefreshCoordinator.swift`, `HostSnapshot.swift`,
  `RefreshSystemEvents.swift`; `Sources/muxfinder-probe/RefreshCommand.swift`;
  `Tests/MuxFinderCoreTests/RefreshCoordinatorTests.swift`, `RefreshScheduleTests.swift`,
  `RefreshSnapshotTests.swift`, `RefreshTestSupport.swift`.
- Modified: `Sources/muxfinder-probe/main.swift`, `Tests/MuxFinderCoreTests/DiscoveryTestSupport.swift`
  (fake-tmux `hang-pids` mode), `Tests/MuxFinderCoreTests/ProcessRunnerTests.swift`
  (`doesNotBlockTheMainActor` rewritten from a load-sensitive tick count to a file handshake),
  `PLAN.md` (D20; D11 subcommand list), `CLAUDE.md` *Commands*, `docs/TESTING.md`.
- `PROGRESS.json` is a workflow record; ignore it.

## Verification already run

- `swift build -Xswiftc -warnings-as-errors` exit 0; `swift format lint -r Sources Tests` exit 0.
- `swift test`: 531 tests in 52 suites; 8 consecutive passes after the test fix (before it,
  `doesNotBlockTheMainActor` failed 2 of 12 runs under load average ~17).
- Real check by the worker: private `hosts.json` (This Mac + `saturno-m4`) in a `mktemp -d`
  folder, `refresh --once --config <file>` exit 0, both hosts live (`noServer` on both); a
  separate check with a test-owned tmux folder listed one `muxfinder-test-*` session locally.

## Risks to focus on

1. Races in `RefreshCoordinator`: actor reentrancy across `await`s (state read before an await
   and used after), results applied after `stop()`/sleep, a config edit during an attempt, a
   removed-then-re-added host, generation/revision comparisons, coalescing that can lose a
   request or loop forever.
2. Concurrency limit 3 and per-host single flight actually enforced, including follow-up runs
   and manual retries; a slow host never delays others beyond the limit.
3. Cancellation: sleep and `stop()` really cancel in-flight probes and kill their process
   groups (the Phase 1 process runner), await every task, and leave no timer/scheduler task
   alive; wake's 5 s delay and the network-change path cannot start work while asleep or
   stopped.
4. Scheduling correctness: visible vs background cadence, backoff steps and cap, reset on
   success, manual retry bypassing, visible cadence ignoring backoff; no busy loop or drift.
5. Snapshot semantics: stale sessions never presented as live; attachment merge applying D16's
   index-failure policy; identity keyed by host.
6. Safety rules in `CLAUDE.md`: the probe's default never contacts iTerm2; local discovery never
   uses SSH; no shell source built from runtime values; no user host names or terminal contents
   in fixtures, logs or docs.
7. Test determinism: no real-time sleeps used for ordering; fake clock correctness.

## Output

- Review file: `docs/reviews/phase-7b.md` (write the full report there).
- Time budget: 15 minutes.
