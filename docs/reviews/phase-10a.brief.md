# Review brief — Phase 10a (attach UX in the app)

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM, macOS 14 menu bar app
  that attaches tmux sessions in iTerm2 via `tmux -CC`). Conventions and binding safety rules:
  `CLAUDE.md`. Plan: `PLAN.md` "### Phase 10" (and its "Split" paragraph), decision **D25**
  (new), D22 (edited), D15/D16/D21/D24 (the core this builds on).
- **Phase goal:** per-session attach state machine in `AppModel` (Open by default; focus when
  already open here; repeated clicks while pending ignored; "Confirmed" only after core
  confirmation; "Still connecting — check the iTerm2 tab" with "Show tab"); context menu
  "Move here…" (confirmation explaining it disconnects every other client, including other
  Macs) and "Detach from this Mac" (only for this Mac's attachments, core detach, never closes
  tabs); New session sheet (validation, optional directory, collision with "Open existing");
  vanished/changed banners; hidden `--selftest attach-local|new-session-local
  [--selftest-keep]` flags driving the real `AppModel` path. Real self-test runs are Phase 10b,
  not this phase: this change is proven hermetically only.
- **Changed files (uncommitted tree):** see `git status --short` / `git diff`. Main ones:
  `Sources/MuxFinderUI/Model/{AppModel,AppModelSessions,SessionProblem,SessionPanels,
  SessionActivity,AppEnvironment,AppLaunchOptions,PopoverContent}.swift`,
  `Sources/MuxFinderUI/SelfTest/{SelfTestDriver,SelfTestSeams}.swift`,
  `Sources/MuxFinderApp/{SelfTestAppDelegate,MuxFinderMenuBarApp,PreviewAppDelegate}.swift`,
  `Sources/MuxFinderUI/Views/{SessionRowView,PopoverView,SessionPanelViews}.swift`,
  `Sources/MuxFinderCore/Attach/{AttachCoordinator,AttachModels}.swift` (new
  `showLaunchTab(_:)`), `Sources/MuxFinderCore/Config/HostStore.swift`, tests
  `Tests/MuxFinderUITests/{AttachFlowTests,AttachUITestSupport,SelfTestDriverTests}.swift`,
  `Tests/MuxFinderCoreTests/ShowLaunchTabTests.swift`, docs `PLAN.md`, `CLAUDE.md`,
  `docs/TESTING.md`. `PROGRESS.json` is a workflow record, not part of the change.
- **Verification run (orchestrator, exit 0 each):** `swift build -Xswiftc -warnings-as-errors`;
  `swift format lint -r Sources Tests`; `swift test` twice (589 core tests in 58 suites + 132
  UI tests in 11 suites); `scripts/build-app.sh`; `codesign --verify --deep --strict
  build/muxFinder.app`; `--selftest bogus` exits 2 contacting nothing; shell check
  `--report-menu-bar-item` then SIGTERM exit 0, no child, no `hosts.json` created.
- **Risks to probe hardest:**
  1. **Self-test safety** (it will run against the user's live iTerm2 and default tmux server
     in 10b): does it only ever create/attach/detach/kill `muxfinder-test-*` sessions, only ask
     its own launch tabs' tmux connections, never close a tab, never touch the real
     `hosts.json`, bound every wait, and clean up on every exit path (failure, SIGTERM/SIGINT,
     timeout) — including the 10 s minimum launch-tab age before `detach-client` and iTerm2's
     3 s "ended too soon" modal hazard? Does keep mode really leave the session and connection
     and quit through `AppTermination` with exit 0?
  2. **State machine correctness:** single flight per session (5-click burst → 1 launch),
     races between a pending attach and refresh/vanish/identity change, popover close, quit
     (`AppModel.shutdown()` awaiting in-flight attaches), Move here reaching the core only with
     an explicit confirmation, Detach only for this Mac's attachments, stale results from an
     earlier generation landing on a newer state.
  3. **`showLaunchTab(_:)`:** refuses any tab the app did not create; cannot focus a user tab.
  4. **iTerm2 contact policy (D22):** nothing contacts iTerm2 at launch or after the popover
     closes except the user's own attach action; the self-test flags contact nothing on bad
     arguments.
  5. No shell/AppleScript source built from runtime values; no user data in logs or fixtures;
     distinct failure messages; sentence-case English UI text.
- **Review file:** `docs/reviews/phase-10a.md` (write the full report there; end with the
  verdict lines).
- **Time budget:** 20 minutes.
