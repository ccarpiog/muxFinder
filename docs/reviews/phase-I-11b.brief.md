# Review brief — Phase I-11b: Detach other clients, the UI (routine)

- **Repo**: /Users/ccarpio/Developer/Utils/muxFinder (macOS menu bar app, SwiftPM, Swift 6). The
  change under review is the **uncommitted working tree** against `HEAD`.
- **Goal**: the popover's "Detach other clients…" context menu item over the core call shipped
  in I-11a (`AttachCoordinator.detachOtherClients(of:confirmation:)`, PLAN.md D37). The
  specification is PLAN.md *Phase I-11*, block "The orchestrator's calls for I-11b" (offer rule,
  in-popover confirmation with its text and keys, the confirm method as the only caller, the
  pending row, the result mapping through `SessionProblem`, refresh after every outcome but
  `cancelled`/`notConfirmed`, `shutdown()` cancelling it, the row hint, VoiceOver, galleries).
  The user's request: `autoclaude/processed/105-detach-other-clients.md` (requirements 3–4,
  *Acceptance*). The worker's own record: PLAN.md "Outcome of I-11b" and the D25/D37 edits.
- **Changed files**: `Sources/MuxFinderUI/Model/{AppModel,AppModelSessions,PopoverContent,SessionActivity,SessionPanels,SessionProblem}.swift`,
  `Sources/MuxFinderUI/Views/{PopoverView,SessionPanelViews,SessionRowView,SwitcherView}.swift`,
  `Sources/MuxFinderUI/Preview/{AttachFixtures,PreviewFixtures}.swift`,
  `Tests/MuxFinderUITests/{AttachFlowTests,AttachUITestSupport,DetachOtherClientsUITests}.swift`
  (the last new), `README.md`, `PLAN.md`, `docs/{ARCHITECTURE,TESTING,MANUAL-CHECKLIST}.md`,
  `docs/screenshots/{attach,popover}-states-{light,dark}.png`. No core (`MuxFinderCore`) change.
  `PROGRESS.json` is a workflow record, not under review.
- **Verification run (orchestrator)**: `swift build` exit 0; `swift format lint -r Sources Tests`
  exit 0; `swift test` exit 0 (905 core tests in 88 suites, 483 UI tests in 47 suites);
  `scripts/build-app.sh` exit 0; `codesign --verify --deep --strict build/muxFinder.app` exit 0.
  No real e2e run (no core change).
- **Risks to probe**:
  1. The offer rule: shown only for a live row, open in this Mac's iTerm2, `clientCount` greater
     than this Mac's attachments of the session; hidden on stale/unreachable rows; a row whose
     attachment is known only from a confirmed `attachedHere` counts as 1.
  2. The confirmation can only ever pass `.detachOtherClients(of:)` for the key of the session it
     names (a refresh or another row's action while the panel is open must not retarget it);
     Cancel/Esc run nothing; Return confirms; arrows, ⌘F, ⌘N inert.
  3. Result mapping: every `DetachOtherClientsResult.Outcome` reaches a distinct message and the
     specified recovery; `goneBeforeDetach` wording; `checkFailed(.send(.tmuxCommandFailed))`
     tells the user this Mac's attachment may have ended; "Try again" shows the confirmation
     again and never calls the core directly; refresh after the right outcomes only.
  4. Concurrency: the pending action is cancelled by `shutdown()`; clicks on the row ignored
     while it runs; no stale activity left after the result; Swift 6 isolation correct.
  5. The worker's deviations (PLAN.md "Outcome of I-11b"): only the new item is disabled while
     another action is pending; both dialogs now announce their title (Move here changed too);
     "Try again" refreshes when the item is no longer offered; `notAttachedHere` forgets
     muxFinder's own attachment record. Check each is safe and does not regress Move here or
     Detach.
  6. The UI tests' fake iTerm2 now answers the core's four commands: check the tests exercise
     the real coordinator path and are hermetic.
  7. Conventions (CLAUDE.md): `///` on every function/type, closing-brace comments on >10-line
     functions/loops, sentence-case English UI text, no user data in fixtures/docs.
- **Review file**: `docs/reviews/phase-I-11b.md`.
- **Time budget**: 15 minutes.
