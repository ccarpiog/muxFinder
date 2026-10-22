# Phase 5a review brief

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6 SwiftPM macOS menu bar app; reviews the
  uncommitted tree against `HEAD`).
- **Phase and goal:** Phase 5a — existing-attachment detection, local (risk high). `PLAN.md`
  "### Phase 5" (its *Split* paragraph) and the new decision **D16**. An `AttachmentIndex` maps
  iTerm2 tmux connections to discovered `SessionKey`s by `#{host}` (= `uname -n`), socket path,
  pid and start time, never titles, counting unknown, ambiguous and stale connections; attach of
  an already-attached session becomes focus (Activate, no new tab); `detach(session:on:)` detaches
  every attachment of a session in this Mac's iTerm2 through the D15 binding rule and 10 s
  minimum tab age; `e2e-local` gains focus-existing and detach-by-session steps; read-only probe
  `iterm2 attachments`.
- **Changed files:** new `Sources/MuxFinderCore/Attach/AttachmentIndex.swift`,
  `Tests/MuxFinderCoreTests/AttachmentIndexTests.swift`, `Tests/MuxFinderCoreTests/AttachFocusTests.swift`;
  modified `Sources/MuxFinderCore/Attach/{AttachCoordinator,AttachModels}.swift`,
  `Sources/muxfinder-probe/{E2ELocalCommand,E2ESupport,ITerm2Command,AttachCommand}.swift`,
  `Tests/MuxFinderCoreTests/{AttachCoordinatorTests,AttachTestSupport}.swift`, `PLAN.md`,
  `CLAUDE.md`, `docs/TESTING.md`, `docs/INTEGRATION-PROOF.md`. (`PROGRESS.json` is a workflow
  record — ignore.)
- **Verification run:** `swift build -Xswiftc -warnings-as-errors` exit 0; `swift test` exit 0
  (373 tests, 36 suites); `swift format lint -r Sources Tests` exit 0, no output; real
  `env -u TMUX_TMPDIR swift run muxfinder-probe e2e-local` exit 0, 10/10 PASS, three runs (42–43 s);
  `iterm2 status` connected after; no leftover session, connection or launch file.
- **Risks to probe:**
  - Wrong mapping → focusing or detaching the wrong session (host/socket/pid/start-time match,
    ambiguous handling, parser on bytes, `#{host}` vs `uname -n` comparison).
  - The binding rule: does every `SendCommand` (index identity, detach-client) still go through
    owning-session-id binding on one API connection? Can a reused short connection id redirect a
    detach to a user's attachment? Is identity re-checked right before `detach-client`?
  - Duplicate attach: index failures, per-connection 3 s timeout, stale connections; is there a
    path that opens a second tab when the session is attached? Index-failure policy
    (`attachmentCheckFailed` vs proceeding when iTerm2 is not running).
  - Interaction with 4b single flight, generations and cancellation (does focus participate in
    single flight; cancelled detach sends nothing; modal hazard — no tab may end within 3 s, 10 s
    minimum age honored for tabs not opened by this coordinator).
  - Real-run safety: the e2e index filter must keep the read-only `display-message` away from
    connections the test did not create; probe `attach`/`iterm2 attachments` ask every connection.
  - Legacy coordinator tests now run with the check `.off` — does that hide a regression in the
    default-on path?
  - Conventions from `CLAUDE.md`: `///` docs, closing-brace comments over 10 lines, argv only, no
    titles or terminal contents in logs.
- **Review file:** `docs/reviews/phase-5a.md`.
- **Time budget:** 15 minutes.
