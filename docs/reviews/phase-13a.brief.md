# Review brief — Phase 13a (client, helper and spike)

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM, macOS menu bar app).
  Review the **uncommitted** working tree against `HEAD` (`d03e146`).
- **Phase and goal:** Phase 13a of `PLAN.md` *Phase 13* (lines ~2828 onward: source facts
  S1–S8, design items 1–7, the 13a bullet). Goal: the hermetic building blocks to bury
  muxFinder's own iTerm2 launch tab (the tmux gateway) after an attach, and a gated real spike
  establishing iTerm2 3.7.6's real bury and restore behavior, recorded as *Verified facts* and
  decision **D29**. The coordinator (13b) is out of scope; no coordinator code should change.
- **Changed files:** see `git status --short`. Core:
  - `Sources/MuxFinderCore/ITerm2/ITerm2Property.swift` (new: SetProperty/GetProperty, field
    111/112), `ITerm2Envelope.swift`, `ITerm2Error.swift`, `ITerm2Integration.swift`,
    `ITerm2APIClient.swift`, `FakeITerm2Integration.swift`.
  - `setBuried(_:sessionID:)` and `buryLaunchTab(sessionID:ifOwnsTmuxConnection:)` on every
    conformer.
  - `Sources/MuxFinderCore/Launch/LaunchHelper.swift`, `TerminalStatusRequest.swift` (new),
    `LaunchArgvDigest.swift`, `LaunchModels.swift`, `TerminalChildRunner.swift`.
  - In attach mode the helper writes the result, then `OSC 1337 ; Disinter ST`, then DSR, then
    waits a bounded ~2 s in raw mode. After an unanswered first restore it writes a line feed
    and a second restore. It repeats the restore just before exit. The test-mode request field
    `testSuppressDisinter` suppresses the `Disinter`. The digest gains `attachChildProcessID`
    and `tabRestores`.
  - Harness: `Sources/muxfinder-probe/E2EBury{Command,Run,Support}.swift`, `main.swift`.
  - Tests: `Tests/MuxFinderCoreTests/LaunchTabRestoreTests.swift` (new), golden fixtures
    `Fixtures/iterm2/{set,get}-property-*.bin`, `scripts/dev/gen-iterm2-fixtures.py`, test
    fakes.
  - Docs: `PLAN.md` (*Verified facts* "Phase 13a spike", D29, D14/D15/D25 edits), `CLAUDE.md`
    (`e2e-bury` command note), `docs/TESTING.md`.
  - `PROGRESS.json` is a workflow file; ignore it.
- **Verification run (orchestrator, final tree):**
  - `swift build`: exit 0, no warnings.
  - `swift test`: exit 0, 705 core and 162 UI tests.
  - `swift format lint -r Sources Tests`: exit 0.
  - Real spike: `e2e-bury --local` 12/12 over 4 runs, the last three after the helper fix;
    `e2e-bury --ssh saturno-m4` 12/12 over 2 runs. Nothing left behind; iTerm2 thread count
    16 → 16/17.
  - Final run lines: `/tmp/muxfinder-13a-spike-local.txt`,
    `/tmp/muxfinder-13a-spike-remote.txt`.
- **Known deviation:** this Mac's iTerm2 has `AutoHideTmuxClientSession` **on**, so the spike
  could not run with default preferences. The harness re-buries the tab where the default
  (off) would leave it buried; S5's "off" branch rests on source reading only. Judge whether
  D29 and the facts overclaim from that.
- **Risks to probe:**
  1. **Wire correctness** of SetProperty/GetProperty: field numbers, the oneof identifier,
     `json_value` encoding; decoding of unknown or failed statuses; fixtures byte-exact from
     the Python module.
  2. `buryLaunchTab` keeps ownership on **one API connection**, with no reconnect between the
     list and the set, like `activateFirstTab(ofTmuxConnection:ownedBy:options:)`; D13 error
     classification (answered vs uncertain).
  3. **Helper:** order result → `Disinter` → DSR on every outcome. Check raw mode and terminal
     modes restored on every path, including signals; the bounded wait really bounded; input
     typed earlier discarded without eating the later Return; the line-feed fallback safe while
     iTerm2 may still parse tmux mode; nothing written for `profile`/`ssh-setup` or off a
     terminal; the test-only switch honored only in test mode.
  4. **Harness safety:** touches only its own session, tab and connection; kills only the
     recorded attach-child PID; every wait bounded; cleanup on every way out
     (SIGINT/SIGTERM); no iTerm2 preference written; no user data or terminal contents in its
     output.
  5. **D29 soundness:** the race closed by order, the DSR acknowledgment inference, and the
     "memory only" persistence decision drawn from the abnormal-end result. Is it adequate for
     13b to build on? Does it hold with the preference off as well as on?
  6. Conventions: `///` on everything; closing-brace comments on blocks over 10 lines; no
     third-party code; nothing copied from iTerm2's Python module (D1, licensing).
- **Review file:** `docs/reviews/phase-13a.md`.
- **Time budget:** 20 minutes.
