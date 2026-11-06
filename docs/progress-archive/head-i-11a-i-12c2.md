# Checkpoint head blocks moved verbatim from PROGRESS.md (phases I-11a to I-12c2)

Moved 2026-11-06 at the close of Phase I-12c3a to keep `PROGRESS.md` within its size budget.

## Acceptance

- Phases I-11a, I-11b, I-12a, I-12b1: all criteria met, 2026-11-06 (I-11a `e2e-detach-others`
  9/9 on both hosts, D37; I-11b the popover UI, real clicks owed, checklist 25; I-12a
  `plain-proof` 9/9 on both hosts, D38, Terminal and Ghostty window runs owed to the user by
  the gate; I-12b1 definitions, loader and runner hermetic, no built-in script compiled) —
  `docs/progress-archive/{i-11a,i-11b,i-12a,i-12b1}.md`.
- Phase I-12b2: all criteria met, 2026-11-06 — both mode words, the `terminal` field and its
  exit 72 refusals, the bound plain attach argv (move here included), no OSC 1337 / status
  report in plain mode, the early report, `profile-plain`, all tested (1022 core + 485 UI
  pass); the built helper's real plain attach on a pty against a private server passes in
  `swift test`; `attach` unchanged: `e2e-local` 16/16 and `e2e-bury --local` 13/13 on the
  final code — `docs/progress-archive/i-12b2.md`.
- Phase I-12b3: all criteria met, 2026-11-06 — the seam, the iTerm2 adapter (forwarding
  compared against the coordinator over its fakes) and the plain window layer, all hermetic
  (1058 core + 485 UI pass); no existing source file changed, so no real run; no built-in
  script compiled, no Apple event sent — `docs/progress-archive/i-12b3.md`.
- Phase I-12c1: all criteria met, 2026-11-06 — the plain backend hermetic (40 new tests, the
  built helper's end to end on a pty against a private tmux server among them; 1098 core + 486
  UI pass); nothing rewired, no real run; one exhaustive-switch addition in an existing UI
  test, its samples unchanged — `docs/progress-archive/i-12c1.md`.
- Phase I-12c2: all criteria met, 2026-11-06 — discovery's client fields, the attributor over a
  fake table, the per-session rule, the refresh attributor, `.app` focus and the plain backend's
  open-here focus all hermetic (1134 core + 486 UI pass); real read-only `discover --local`,
  `--ssh saturno-m4` and `local-clients` (1 client → iTerm2, 0 unmapped); nothing rewired —
  `docs/progress-archive/i-12c2.md`.

## Decisions

- Phase I-11: split into I-11a/I-11b in `PLAN.md` before the first worker, with the
  orchestrator's calls there (proof of (a) first; its own confirmation type; the attachment
  Show tab focuses is kept; identity check before sending; read-only count, nothing sent when
  none; send once; its own `e2e-detach-others` command). **D37**: (b), per-client
  `detach-client -t` after a server-wide check of name, pid, creation time and session; a 10 s
  age guard by tmux's clock on every listed client; an answer without `output` is
  `tmuxCommandFailed` for every `SendCommand` caller — `docs/progress-archive/i-11a.md`.
- Phase I-11b: the orchestrator's calls in `PLAN.md` *Phase I-11* ("calls for I-11b": popover
  only, the offer rule, the in-popover confirmation and its count, wording, recoveries, refresh,
  the hint). The worker's: only the new item disabled while an action is pending; both dialogs
  announce their title; `notAttachedHere` forgets the record. The review fix's: the switcher
  offers no "Try again" for a move here or a detach of others (popover-only confirmations),
  fixing Move here's same older flaw — `docs/progress-archive/i-11b.md`.
- Phase I-12: split into I-12a–e in `PLAN.md` before the first worker, with the orchestrator's
  calls for I-12a there (never launch Terminal or Ghostty, Apple events only to a running app
  whose permission reads granted without a prompt; plain confirmation proven on ptys the
  harness owns; D3's extension for Terminal's command text). *Unattended-run rules* 1 extended
  and rule 8 added, and the same in `CLAUDE.md`. **D38** (I-12a): remote plain clients are
  identified by the launch token in the parent shell's argv (`ps` by `client_pid`, read-only);
  Move here in plain mode is `attach-session -d`; every attach and detach is one bound
  `if-shell -F` command (review fix); Terminal's text also refuses `!` —
  `docs/progress-archive/i-12a.md`.
- Phase I-12b: split into I-12b1 (definitions, loader, runner) and I-12b2 (seam, plain
  backend's open/focus/close, helper plain mode, early report) in `PLAN.md` *Phase I-12*
  before the first worker, with the calls for I-12b1 there (schema, fixed handler names,
  `shellText`/`words`, Ghostty's token as the last word of `command` for either answer of the
  owed fact, no built-in script compiled by any check). The workers' additions (no ACL,
  `.applescript` names, placeholders at most once, duplicate keys refused, UTF-8 only) are in
  D38's "Definitions (I-12b1)" and `docs/progress-archive/i-12b1.md`.
- Phase I-12b2: **I-12b2 split again** at its selection into I-12b2 (helper plain mode, the
  request's terminal field, the early report) and I-12b3 (terminal seam), in `PLAN.md` *Phase
  I-12* with the calls for I-12b2. The worker's: a move here keeps `detachOtherClients`; the
  report is not removed by `discardRequest`; `profile-plain` keeps `profile`'s 10 s hold (for
  I-12d to revisit) — `docs/progress-archive/i-12b2.md`.
- Phase I-12b3: the orchestrator's calls in `PLAN.md` *Phase I-12* ("Calls for I-12b3": the
  seam at the session operations, not below the coordinator; nothing rewired; "open here" left
  to I-12c). The workers': `ITerm2TerminalBackend` wraps the coordinator; an unrecognised
  permission status lets an open go ahead, -1743 from any handler is `permissionDenied`, focus
  and close never launch the app; `exec` through `posix_spawn` in its own session with a
  backoff reaper; windows bound to the whole loaded definition that opened them
  (`definitionChanged`) — `docs/progress-archive/i-12b3.md`.
- Phase I-12c1: **I-12c split** into c1 (plain backend), c2 (open on this Mac), c3 (onto the
  seam, terminal setting, `attach --terminal`, `e2e-plain`, iTerm2 regression runs), with the
  calls for c1, in `PLAN.md` *Phase I-12*. The workers': `PlainTerminalWindowLayer` protocol;
  new `AttachState`/`AttachFailure` cases, not optional fields; `AttachSharedSteps` factored
  out of the coordinator; an attach waits out an earlier plain attach (`earlierLaunchPending`);
  the review fix binds every detach-others detach to the kept client's presence (D38
  "Plain backend (I-12c1)") — `docs/progress-archive/i-12c1.md`.
- Phase I-12c2: the orchestrator's calls in `PLAN.md` *Phase I-12* ("Calls for I-12c2": core
  only; pid reuse refused by terminal device and start time; iTerm2's job server names iTerm2;
  the index keeps iTerm2's control-mode clients; activation of a running app only; the iTerm2
  backend's attach unchanged). The workers': `incompleteClient`; attributor and activator off by
  default in the plain backend (I-12c3 passes them); `ITerm2TerminalBackend(appActivator:)` for
  `.app` handles; the review fix's nonce-framed `tty` record (D38 "Open on this Mac (I-12c2)") —
  `docs/progress-archive/i-12c2.md`.

## Reviews

- Phases I-11a, I-11b, I-12a: Codex wrote each file (`autoclaude-review.sh`), all
  `ship-with-fixes` (I-11a 1 blocker narrowed in D37 + 2 should-fix; I-11b 1 should-fix;
  I-12a 1 blocker + 1 should-fix, both bound into one `if-shell -F` command); review-fix
  workers fixed them with regressions failing on the old code, re-verified —
  `docs/reviews/phase-I-{11a,11b,12a}.md`, summaries in the phases' archives.
- Phase I-12b1: Codex wrote the file (`autoclaude-review.sh`, 15 min) → `ship-with-fixes`, 0
  blockers, 1 should-fix (duplicate JSON member names passed the strict schema); a review-fix
  worker added `JSONDuplicateNameScanner` and `.duplicateKey`, six raw-JSON regressions (five
  fail with the scan removed); re-verified by the orchestrator — `docs/reviews/phase-I-12b1.md`.
- Phase I-12b2: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 0
  blockers, 1 should-fix (the real-pty test's private tmux server could load the user's
  `tmux.conf`); fixed by the orchestrator with `-f /dev/null` (also in I-12a's
  `PlainBoundCommandsTests.Server.create`) and a private `HOME`, re-verified —
  `docs/reviews/phase-I-12b2.md`.
- Phase I-12b3: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 2
  blockers (close authority not bound to the opening definition; focus not revoking it on
  `windowGone` / app not running) + 1 should-fix (the reaper accepting `waitpid`'s 0 after the
  exit notice); a review-fix worker fixed all three, each regression failing with its fix
  reverted; re-verified by the orchestrator — `docs/reviews/phase-I-12b3.md`.
- Phase I-12c1: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 1
  blocker (detach others not bound to the kept client's presence) + 2 should-fix (helper result
  not rechecked after a confirming reading; the early report swept during the remote wait); a
  review-fix worker fixed all three, each regression failing with its fix reverted;
  re-verified by the orchestrator — `docs/reviews/phase-I-12c1.md`.
- Phase I-12c2: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 0
  blockers, 1 should-fix (`client_tty` raw in the line-based client record: a line feed failed
  the host's discovery); a review-fix worker moved it into a nonce-framed `tty` record, its
  full-report regression failing on the old code; re-verified by the orchestrator —
  `docs/reviews/phase-I-12c2.md`.
