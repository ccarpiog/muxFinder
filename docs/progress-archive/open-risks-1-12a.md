# Open risks and deviations, Phases 1–12a

Moved verbatim from the `PROGRESS.md` live head on 2026-10-24 (Phase I-1a checkpoint) to keep it
under its size budget. Still standing unless a later phase says otherwise; per-phase detail is in
`docs/progress-archive/<phase>.md`.

- Process-runner tests use an armed-timeout helper to survive very high machine load; if they
  flake, look there first.
- Two classifier rows ("No route to host", "Network is unreachable") are standard OpenSSH
  wording, not real captures (marked in `ErrorClassifierTests`).
- The "host key changed" real check predates the `ControlMaster=no` / `ControlPath=none`
  harness options; the "unknown" check was re-run with them (same result).
- The probe uses `head -c` (POSIX.1-2024, present on macOS); fine for the Mac-only host set.
- Discovery creates the `tmux-<uid>` socket directory if missing (any tmux command does);
  recorded in `PLAN.md` *Verified facts*.
- 3a decoder is more lenient than Python in two spots: invalid UTF-8 → U+FFFD, and a oneof member
  superseded by a later member is skipped undecoded (corruption inside it goes unreported).
- iTerm2 Python module 2.11 quirks (Activate sends `ignoring_other_apps=true` with any app
  option; `rpc.async_create_tab(command=…)` raises) — later phases must not rely on them.
- 3b: `authRejected` (401) and `notRunning` are covered only by hermetic tests (run rules forbid
  bogus cookies and quitting iTerm2). What a real tmux tab carries in `ListSessions` is
  unverified until Phase 4 (ordinary tabs: `tmux_window_id = "-1"`, no connection id). While a
  LaunchServices Automation prompt shows, the main thread waits on `NSAppleScript`.
- 3b: a cancelled request throws `CancellationError` without saying whether its frame was sent.
- 4a: `~/Library/Application Support/muxFinder` itself keeps any inherited ACL (only `launch/`
  and its files are stripped) — handle when Phase 7 writes `hosts.json` there.
- 4a: dev build products live in `.build/out/Products/Debug/` (`.build/debug` links there).
- **iTerm2 modal hazard (all later phases):** any tab the app or a test creates that ends within
  3 s of opening raises iTerm2's modal "session ended very soon after starting" warning, and
  the whole iTerm2 API then answers nothing until a person clicks OK (blocked this run once, in
  4b). The helper now holds every visible launch tab ≥10 s; Phase 5's ssh path must keep that
  (ssh failing fast must still end through the helper's hold).
- 4b: `muxfinder-probe detach` needs `--gateway` and always waits 10 s; an identity failure
  reports ~10 s after the tab opened; the app pays the 10 s wait for tabs opened before a
  restart. Phase 11's profile could silence the warning (product decision left open).
- 4c: `swift run muxfinder-probe` does not rebuild `muxfinder-launch`; run `swift build` before
  any real run or iTerm2 launches a stale helper (documented, no automatic guard).
- 4c: abort / failed-step / signal cleanup in `e2e-local` and recovery of a session created
  during cancellation have run only hermetically (an aborted real run was not risked).
- 4c: a user detach within 10 s of attaching leaves the launch window open until 10 s pass; a
  Ctrl-C in the instant between the failure prompt appearing and the wait arming is ignored;
  `MUXFINDER_LAUNCH_MINIMUM_LIFETIME_MS` is test-only by convention but would also apply to a
  real launch if present in iTerm2's environment.
- 5a: probe `attach` and `iterm2 attachments` send the read-only identity `display-message` to
  every tmux connection, the user's included; unattended, run them only when `iterm2
  list-connections` shows none of the user's (`e2e-local` filters to its own launch tabs).
- 5a: a non-UTF-8 control client whose host or socket path contains `_` or `:` stays unmapped
  (`nonUTF8`), so attaching that session can open a duplicate; a connection silent for 3 s does
  not block an attach either (duplicate only if it showed the same session).
- 5a: `focused` is published after activation (up to 5 s late if no tab appears yet); the
  owned-connection `detach` still counts tab age from the call.
- **iTerm2 API stall (all later real runs).** It happened in real `e2e-remote` run 3, step 10:
  GCD worker starvation in iTerm2 (64 workers in `NSAnimation _runBlocking`), no modal dialog
  as far as the read-only sample shows. It cleared within about two hours without a restart,
  and the three final-tree runs after it left iTerm2 at 14–18 threads, so no growth was seen.
  The cause is unknown. Before and after every real run, check `iterm2 status` and the thread
  count (read-only, `ps -M -p <pid> | wc -l`); stop as `BLOCKED` on a timeout or if the count
  keeps growing.
- 5b: the earlier real `e2e-remote` runs used the old still-waiting design. That design made
  one real login attempt per run to `saturno-m4` as `nonexistent-muxfinder`, three in total.
  The review flagged it as outside the run rules, and it is gone now.
- 5b: `withAwaitedTask` has no time limit of its own; it relies on the coordinator's 10 s
  request timeouts and cancellable sleeps. On macOS, `poll` reports `/dev/null` as unsupported,
  so the relay writes such devices directly.
- **iTerm2 thread ratchet (gates every real run).** Each real e2e run adds about 12 iTerm2
  threads (GCD workers stuck in `-[NSAnimation _runBlocking]`, the 5b stall pattern at 64).
  They decay with no restart, but slowly and unevenly: during 6a the count sat at 34–35 for
  over an hour, then was back to 15 about two hours later. The final-tree `e2e-remote` took
  it from 16 to 26. Restarting iTerm2 is the user's call, never the run's.
- 6a: name edge cases (`$…`, a client's terminal name, `#[`), the harness-only
  `NewSessionRequest.command`, the never-run-for-real probe `new-session`, and the
  "server not responding" class split — `docs/progress-archive/6a.md`.
- 7a: the 4a ACL risk is only partly closed (a launch request that creates the `muxFinder`
  directory first leaves its inherited ACL until the next host-list save); saves refuse a
  symlinked, non-regular or >16 MiB `hosts.json`; no fallback where `RENAME_SWAP` is
  unsupported; more in `docs/progress-archive/7a.md`.
- 7a: the 5b test `aSilentRemoteConnectionIsStale()` flaked about once in 18 runs (a wait-
  condition race); fixed with a cancelled-sleep count on `GatedAttachClock`, 20/20 runs since.
- 7b: `doesNotBlockTheMainActor` (Phase 1) failed 2 of 12 runs under load and is now a
  deterministic handshake; `keepsTrailingSemicolonsOnAPrivateServer` (6a) failed about 1 in 20
  under heavy load in the worker's runs, unseen in the orchestrator's 14 — look there first if
  the suite flakes. `refresh --once --attachments` never ran for real (it queries the user's
  iTerm2 tmux connections); remote sessions through the engine were not seen (Saturno had no
  server); more in `docs/progress-archive/7b.md`.
- 6b: a launch that never settles (a tab left waiting for a password) makes later conflicting
  calls for that session fail `earlierLaunchPending` until the tab ends or attaches; an
  `unknown` connection whose answer names another server or session does not block a move
  here. Thread growth per real run varies widely: the worker's `e2e-local` took iTerm2 from
  25 to 42 (it stayed near 40 for hours), the closure runs only 16 → 16 → 19.
- 8: the real popover (open, keys, Esc) never ran (needs a click; covered by model tests);
  `screencapture -l` fails while the screen is locked (in-app `--preview-snapshot` used); the
  worker deleted preference sets its own early preview runs created; a cancelled caller can
  still let one iTerm2 connection open (no request sent on it); `createsOnAPrivateServer()`
  (6a) failed once (`pane_current_path` race under load), then passed — look there first if the
  suite flakes. Details in `docs/progress-archive/8.md`.
- 9a: owed to a person (needs clicks): the real launch-at-login round trip on an installed
  bundle, the fix-it buttons opening System Settings, the window coming to the front, ⌘C/⌘V in
  its fields. Shutdown does not wait for a save already in progress; the changed-file banner
  has no preview fixture — `docs/progress-archive/9a.md`.
- 9b: the real ssh-setup round trip (tab, interactive ssh, hold) is **owed to the user**
  (Phase 10b decision: an interactive login on Saturno is outside the run rules; probe
  `ssh-setup --ssh <dest>` exists, but cannot close its own tab); a destination saved in
  Settings does not clear the popover's pending ssh-setup line; clicking through onboarding is
  owed to a person — `docs/progress-archive/9b.md`.
- 10a: Show tab is unverified against the real iTerm2 (local attaches never reach "still
  waiting"); the app's own Open asks every tmux connection (only the self-tests filter to their
  own tabs); a rename between the fresh listing and the attach is not caught; quit can take up
  to 15 s with an attach in flight; self-test cleanup kills nothing while an action is still
  running and prints the `tmux kill-session` to run — `docs/progress-archive/10a.md`.
- 10b: Show tab is still unverified for real; after keep mode the helper's `*.result.json`
  stays in the launch directory until the next launch's sweep (D14, 120 s TTL); the keep
  line's cleanup prints `tmux` without a path — `docs/progress-archive/10b.md`.
- 11b (11a's owed items, the rest confirmed by the real runs): still unverified — a non-modal
  "Dynamic Profiles Error" alert during the atomic write (needs a person's glance; the
  dot-file skip is seen only indirectly), the unknown-parent fallback, `-A` target-syntax
  cases on a real server, a login shell exiting within 3 s. iTerm2 went 22 → 35 threads over
  six runs (1–4 per run) — `docs/progress-archive/11b.md`.
- 11c: the parent-inheritance warning and the second-tab note are copy only (iTerm2 not run);
  owed to the user: a real Install / Remove from an installed bundle, making a profile the
  default, a second tab of the same profile, a launch after moving the app; an outside removal
  in the instant after the locked check reports `fileChanged` (nothing created) —
  `docs/progress-archive/11c.md`.
- 12a: `shellcheck` not installed (only `bash -n`); neither script has run on the real
  `/Applications`, `~/Applications`, `DynamicProfiles/` or support folder (a real install /
  uninstall is the user's, in `docs/MANUAL-CHECKLIST.md`); the README's Gatekeeper statement
  for quarantined copies is untried; the no-symlink rule holds in test mode only —
  `docs/progress-archive/12a.md`.
