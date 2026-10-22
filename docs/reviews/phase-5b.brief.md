# Phase 5b review brief

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6 SwiftPM macOS menu bar app; reviews the
  uncommitted tree against `HEAD`).
- **Phase and goal:** Phase 5b — remote attach over SSH (risk high). `PLAN.md` "### Phase 5" (its
  *Split* paragraph, 5b bullet) and the new decision **D17** (D14, D15, D16 and *Verified facts*
  edited). The launch helper runs `/usr/bin/ssh -t -o ConnectTimeout=10 -- <dest> <D3 string>`
  (interactive, no BatchMode); the remote side runs the D4 guard check and then `exec`s tmux;
  every failure (ssh 255 classified from relayed stderr, guard mismatch, auth failure) ends
  through the helper's explanation, wait for Return and ≥10 s hold. Remote attaches have a 20 s
  budget to `confirmed`; past it, with the launch tab open, the coordinator publishes
  `stillWaiting` (never success), keeps watching once a second, and may still end `confirmed`,
  `failed`, or `waitLimitReached` at 300 s. `AttachmentIndex` maps remote hosts (remote
  `uname -n`, socket path, pid, start time); the identity check matches the host name;
  `detach(session:on:)` and focus-existing work for remote hosts; probe `attach --ssh` and
  `e2e-remote <dest>` (11 steps, shared harness with `e2e-local` in `E2ERun.swift`).
- **Changed files:** new `Sources/MuxFinderCore/Launch/RemoteLaunch.swift`,
  `Sources/muxfinder-probe/E2ERun.swift`, `Tests/MuxFinderCoreTests/{RemoteLaunchTests,RemoteAttachTests}.swift`;
  modified `Sources/MuxFinderCore/Launch/{LaunchModels,LaunchGuard,LaunchFailure,LaunchHelper,TerminalChildRunner}.swift`,
  `Sources/MuxFinderCore/Attach/{AttachCoordinator,AttachModels}.swift`,
  `Sources/MuxFinderCore/Shell/Validation.swift`,
  `Sources/muxfinder-probe/{E2ELocalCommand,E2ESupport,AttachCommand,main}.swift`,
  `Tests/MuxFinderCoreTests/{LaunchTestSupport,AttachCoordinatorTests,AttachFocusTests}.swift`,
  `PLAN.md`, `CLAUDE.md`, `docs/TESTING.md`, `docs/INTEGRATION-PROOF.md`. (`PROGRESS.json` is a
  workflow record — ignore.)
- **Verification run:** `swift build -Xswiftc -warnings-as-errors` exit 0; `swift test` exit 0
  (415 tests, 41 suites); `swift format lint -r Sources Tests` exit 0, no output. Real runs before
  the last two edits: `e2e-remote saturno-m4` 11/11 PASS twice (76 s), `e2e-local` 10/10 PASS.
  A third `e2e-remote` on the final tree passed steps 1–9 and then iTerm2's API stopped answering
  in step 10 (`still waiting`); `iterm2 status` now exits 75 (`timedOut`); one launch window from
  that run is still open with ssh at a password prompt. The edits after run 2: a 10 s wait for the
  helper's result after a waiting remote tab closes (iTerm2 ended ssh 5.2 s after a forced close),
  and a clearer step-10 message.
- **Risks to probe:**
  - **D3 quoting / injection:** the ssh argv and the remote string — static script plus POSIX
    single-quoted arguments only; hostile session names, destinations (leading `-`, `@`, spaces,
    quotes, newlines) and socket paths; `--` placement; nothing interpolated unquoted; the remote
    guard semantics equal to D4 (identity check, then `exec` tmux; check-then-attach window).
  - **Modal hazard:** any path where a remote launch tab can end within 3 s of opening (ssh fast
    failure, ConnectTimeout, guard mismatch, signals, stderr relay errors) — iTerm2 then blocks its
    whole API until a person clicks OK. Is the ≥10 s hold honored on every ssh failure path?
  - **`stillWaiting` semantics:** never reported as success; transitions after it (late confirm,
    failure, 300 s limit, cancellation, single-flight generations, a superseding attach); no leak
    of the once-a-second watcher; consistency with D15/D17 and what the app will show.
  - **Remote mapping / wrong target:** host-name match in the identity check and the index
    (case, `.local` suffix, non-UTF-8 clients, hostnames with `_`/`:`), local vs remote sessions
    with equal ids/socket paths on two Macs, detach or focus hitting the wrong session or a user's
    connection; the D15 binding rule (owning session id, 10 s minimum age) for remote detaches.
  - **The step-10 stall:** could anything in `e2e-remote`'s `still waiting` step
    (`E2ERun.swift` `stillWaiting()`: an `unknownUser@host` login so ssh waits at a password
    prompt, then a forced `close` of the test's own tab after ≥10 s) or the new 10 s helper-result
    wait plausibly wedge iTerm2's API? Is a real login attempt as a nonexistent user acceptable
    under the run rules ("only discovery and `muxfinder-test-*` sessions")? Suggest a safer design
    if not.
  - **Real-run safety:** `e2e-remote` touches only `muxfinder-test-*` on `saturno-m4`, no remote
    file writes, never `kill-server`; abort/signal cleanup; the index filter keeps identity
    commands away from connections the test did not create; the `e2e-local` refactor into the
    shared harness kept every local check.
  - Conventions from `CLAUDE.md`: `///` docs, closing-brace comments over 10 lines, argv only, no
    titles or terminal contents in logs.
- **Review file:** `docs/reviews/phase-5b.md`.
- **Time budget:** 15 minutes.
