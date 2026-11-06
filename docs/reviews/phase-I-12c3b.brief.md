# Review brief — Phase I-12c3b (other terminals, the plain runs)

- **Repo**: /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM, macOS 14 arm64). Review
  the **uncommitted** tree against `HEAD` (`eb4c352`).
- **Goal**: a real end-to-end harness `muxfinder-probe e2e-plain --terminal <id> --local | --ssh
  saturno-m4` that drives `PlainTerminalBackend` (Terminal.app / Ghostty through the plain
  backend) through open → confirmed, open again → focused, detach, Move here, detach others,
  detach, cleanup — gated first by *Unattended-run rules* 8 (the app already running and its
  Automation permission `granted` without a prompt, else exit 2 with nothing created, written,
  discovered or sent), rechecked before every open, focus and close. Plus iTerm2's `e2e-*` runs
  as regression. The binding spec: `PLAN.md` → *Phase I-12* → "Calls for I-12c3b"; D38's new
  sub-bullet "The plain runs (I-12c3b)"; safety rules in `CLAUDE.md` and `PLAN.md`
  *Unattended-run rules*.
- **Changed files**: new `Sources/MuxFinderCore/E2EPlain/{E2EPlainOptions,E2EPlainSeams,E2EPlainRun,E2EPlainRunCleanup}.swift`,
  `Sources/muxfinder-probe/E2EPlainCommand.swift`,
  `Tests/MuxFinderCoreTests/{E2EPlainRunTests,E2EPlainStepsTests}.swift`; modified
  `Sources/MuxFinderCore/Terminals/{PlainTerminalWindows,PlainTerminalBackendFakes}.swift`,
  `Sources/muxfinder-probe/main.swift`, `PLAN.md`, `CLAUDE.md`, `docs/TESTING.md`,
  `docs/MANUAL-CHECKLIST.md` (`PROGRESS.json` is a workflow record, ignore it).
- **Verification run**: `swift build` exit 0; `swift format lint -r Sources Tests` exit 0;
  `swift test` exit 0 (1169 core in 122 suites, 497 UI in 48 suites; no existing test file
  edited). Real: `e2e-plain --terminal terminal|ghostty --local` → exit 2, nothing created,
  `pgrep` unchanged (neither app running, so the plain real runs are owed to the user);
  iTerm2's `e2e-local` 16/16, `e2e-remote saturno-m4` 15/17 then 17/17 on an immediate rerun
  (step 15 `helperEnded` after 3.2 s, no code on that path changed), `e2e-bury --local` 13/13,
  `e2e-detach-others --local` 9/9, leftovers clean.
- **Risks to check hardest**:
  1. **Safety of a future real run**: can any path launch Terminal/Ghostty, send an Apple event
     before or without the gate (including during cleanup or after a mid-run recheck fails),
     type into a window, close a window whose process still runs, close a window the harness
     did not open, touch a tmux session not named `muxfinder-test-*`, or use `kill-server`?
     Remote: only `saturno-m4`, no remote file writes.
  2. **The gate**: refuses before session creation, discovery, request write and any window
     call; an `exec` definition with the app not running refused too (an exec open would launch
     it); the recheck at each side-effect boundary.
  3. **Cleanup on every way out** (step failure, recheck failure, SIGINT/SIGTERM, watchdog):
     own plain clients ended, own backend clients detached with the bound detach, own windows
     closed only by recorded id after their process ended, own session killed, no request,
     report or child left; bounded waits everywhere.
  4. **Step assertions that would pass on a wrong outcome** (e.g. "open again → focused"
     not checking for a second client/window; Move here not checking the harness client's
     `%exit` and the backend client being the only one; a stale confirmation running
     something; detach others not keeping the backend's client).
  5. The harness's logic lives in `MuxFinderCore` (the app links it) rather than only the probe
     — the worker's reason: tests import only libraries. Judge whether anything there can run in
     the app or widens its surface.
  6. Additive-only changes outside the probe: `PlainTerminalWindows` close conformance and the
     fake's `close` — no behaviour change for existing callers.
  7. Records: `CLAUDE.md` *Commands* `e2e-plain` entry accurate to the code; `docs/TESTING.md`
     *Phase I-12c3b* and checklist 26 give exact owed commands; no user data (folder paths,
     terminal contents, titles) in docs.
- **Review file**: `docs/reviews/phase-I-12c3b.md`.
- **Time budget**: 20 minutes. Do not run real e2e commands, open terminal apps or contact
  iTerm2; `swift build`/`swift test` and reading code are fine.
