# Review brief — Phase 4b: attach coordinator and probe commands

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6 / SwiftPM, macOS 14 menu bar
  app). Conventions and binding safety rules: `CLAUDE.md`. Review the **uncommitted** working
  tree against `HEAD`.
- **Phase and goal:** `PLAN.md` "### Phase 4", the "Split" paragraph's **4b** bullet and the
  Requirements list (the 9-step attach flow, single-flight, detach, typed failures). Build
  `Attach/AttachCoordinator` (local host kind only; ssh is Phase 5) on top of the Phase 4a
  launch layer and the Phase 3 iTerm2 client, plus `muxfinder-probe attach --local --session`,
  `detach --connection` and `e2e-local`. Relevant decisions: D1, D2, D4, D13, D14, and the new
  **D15** in `PLAN.md` *Decisions*; the "Verified in Phase 4b" block in *Verified facts*.
- **Not in scope:** the two passing real `e2e-local` runs. They moved to Phase 4c because the
  only real run so far (steps 1–4 PASS, step 5 FAIL) detached about 1 s after attaching, and
  iTerm2's modal "session ended very soon after starting" warning has blocked its API ever
  since (confirmed: `muxfinder-probe iterm2 status` → `timedOut`). Steps 6–8 never ran for real.

## Changed files

- New: `Sources/MuxFinderCore/Attach/{AttachCoordinator,AttachModels,AttachSeams}.swift`,
  `Sources/MuxFinderCore/ITerm2/ITerm2Close.swift`,
  `Sources/muxfinder-probe/{AttachCommand,E2ELocalCommand,E2ESupport}.swift`.
- Modified: `Sources/MuxFinderCore/ITerm2/{ITerm2Envelope,ITerm2Integration,ITerm2APIClient,ITerm2Error,ITerm2ListSessions,FakeITerm2Integration}.swift`,
  `Sources/MuxFinderCore/Launch/LaunchStore.swift`,
  `Sources/MuxFinderCore/Diagnostics/DiagnosticsLog.swift`, `Sources/muxfinder-probe/main.swift`.
- Tests: new `Tests/MuxFinderCoreTests/{AttachCoordinatorTests,AttachTestSupport}.swift`, four
  `Fixtures/iterm2/close-*.bin`; modified `ITerm2APIClientTests`, `ITerm2CookieAndFakeTests`,
  `ITerm2GoldenTests`; `scripts/dev/gen-iterm2-fixtures.py`.
- Docs: `PLAN.md` (split paragraph, D11 edit, D15, Phase 4b verified facts), `docs/TESTING.md`,
  `docs/INTEGRATION-PROOF.md` (draft), `CLAUDE.md` (Commands). `PROGRESS.json` is a workflow
  record, not a deliverable.

## Verification already run (orchestrator, this tree)

- `swift build -Xswiftc -warnings-as-errors` → exit 0.
- `swift test` → exit 0, 327 tests in 32 suites (301 before).
- `swift format lint -r Sources Tests` → exit 0, no output.
- No tmux server running on the user's default socket; no `muxfinder-test-*` session left.
- Do **not** run `muxfinder-probe attach`, `detach`, `e2e-local` or any `iterm2` subcommand:
  iTerm2 is blocked and the run rules forbid touching it from a review.

## Risks to focus on

1. **Short-lived-session hazard in the product path.** D15 says an unreadable or mismatching
   identity answer detaches the new connection at once; per the Phase 4b verified facts, ending
   a launch tab or its connection within seconds of opening it raises iTerm2's modal warning,
   which blocks the whole API. Check every coordinator path that can end the launch tab or
   connection early (identity failure, cancellation, Activate failure, detach right after a
   confirmed attach) and whether the coordinator or the app layer must guarantee a minimum
   age. Same question for the `e2e-local` harness (the 10 s minimum age it now enforces).
2. **Coordinator correctness and concurrency:** the state machine (`requested` → `launched` →
   `confirmed` / `failed(reason)`), single-flight by `SessionKey` (coalescing, cancellation of
   one vs all waiters, a second attach after the first finished, actor reentrancy across
   `await`s), the 15 s connection poll budget, mapping of the helper result file and exit codes
   to typed failures (D14), request-file withdrawal on every early failure so a late tab cannot
   attach, and D13 (nothing that might have been sent is retried).
3. **Identity check:** the `display-message` format with double quotes and `\t`, byte-level
   parsing (a socket path containing tabs or odd bytes), matching against the discovered
   identity, and what happens on a mismatch.
4. **Activate and tab matching:** connection matching by `owning_session_id` (ids are short
   names like `"tmux"`, not unique across iTerm2 restarts), the first tab carrying the
   connection id, the 5 s wait, `select_session` left off.
5. **New Close message and fixtures:** encoding against the golden fixtures, and that the probe
   closes only sessions/tabs whose ids it recorded at creation (run rule 1). Any path in
   `e2e-local` that could touch a user tab, a non-`muxfinder-test-*` tmux session, or run
   `kill-server` is a blocker.
6. **e2e harness cleanup:** bounded timeouts on every step, cleanup on failure and on signals
   (detach own connections, kill own sessions, remove the `launch/test-mode` marker through
   `LaunchStore`), no shell source built from runtime values.
7. **Conventions:** `///` doc comments on every function/type, closing-brace comments on
   functions/loops over 10 lines, no terminal contents or titles in logs/docs, sentence case.

## Review file and budget

- Write the review to `docs/reviews/phase-4b.md`.
- Time budget: 20 minutes.
