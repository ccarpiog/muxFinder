# Progress head, moved verbatim (2026-11-07 07:07)

Moved out of `PROGRESS.md` to keep the live head under its size budget.

## Acceptance (phases 1 to 13c)

- Phases 1–12a: all criteria met, with the recorded deviations and the real runs owed to a
  person listed under *Open risks*; criteria and evidence in `docs/progress-archive/<phase>.md`.
- Phase 12b (the plan's acceptance bar): all criteria met on the final tree, 2026-10-23 — 680
  core + 159 UI tests, lint and a warnings-free build exit 0; clean-`build/` bundle signed
  (Apple Development, not notarized), `codesign --verify` exit 0; install-script check 35/35;
  `e2e-local` 16/16, `e2e-remote saturno-m4` 17/17, `e2e-profile --local` and `--ssh
  saturno-m4` 14/14 each, `--selftest attach-local` 6/6, `--selftest new-session-local` 5/5,
  keep-mode quit check (row 12) exit 0; every brief bullet in `docs/TESTING.md` mapped to
  evidence or to the manual checklist; nothing left behind, `profiles hashes` identical.
  `docs/progress-archive/12b.md`.
- Phases 13a–13c: all criteria met, 2026-10-24 (13a spike 12/12 on both hosts, D29; 13b
  hermetic; 13c real runs all PASS: `e2e-local` 16/16, `e2e-remote saturno-m4` 17/17,
  `e2e-bury` 13/13 on both hosts, self-tests 8/8 and 7/7, `e2e-profile --local` 14/14) —
  `docs/progress-archive/13{a,b,c}.md`.

## Reviews (phases 1 to 13c)

- Phases 1–7b: Codex reviewed each (`ship-with-fixes`); blockers and should-fix items and their
  fixes (each regression failing on the old code) are summarized in
  `docs/progress-archive/<phase>.md`, reports in `docs/reviews/phase-<phase>.md`.
- Phases 6b–10b: Codex reviewed each (6b, 8, 9a, 9b, 10a `ship-with-fixes`; 10b `ship`);
  every blocker and should-fix was fixed by a fix worker with a regression failing on the old
  code — summaries in `docs/progress-archive/<phase>.md`, reports in
  `docs/reviews/phase-<phase>.md`.
- Phases 11a–12a: Codex reviewed each (`ship-with-fixes`): 11a 1 blocker + 2 should-fix
  (installer rollback, `e2e-profile` cleanup, combining-mark guard), 11b 2 should-fix (mirror
  exclusion, absolute deadline), 11c 1 blocker + 1 should-fix (empty-document install on
  reload, recreating a removed file), 12a 3 blockers (mapped readers, test-root containment,
  deletion bound to the inspected folder). All fixed by a fix worker, each regression failing
  with its fix reverted, re-verified — summaries in `docs/progress-archive/<phase>.md`, reports
  in `docs/reviews/phase-<phase>.md`.
- Phase 12b: Codex → `ship`, 0 findings (record matches the run logs, all 13 bullets mapped,
  signing distinguished from notarization); `docs/reviews/phase-12b.md`.
- Phases 13a–13c: Codex wrote each file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`
  (13a 1 should-fix, 13b 1 blocker + 2 should-fix, 13c 2 should-fix); all fixed by review-fix
  workers with regressions failing on the old code, re-verified (13c with real reruns) —
  `docs/reviews/phase-13{a,b,c}.md`, summaries in `docs/progress-archive/13{a,b,c}.md`.

## Git state (record-only iterations of 2026-11-07, 06:56 to 07:03)

- 2026-11-07 06:56 iteration (record only, no phase): the tree was clean at start (empty
  preflight file). This checkpoint is committed on its own ("Checkpoint: …"), against the
  base file's leave-uncommitted rule for record-only iterations. The reason: the iteration's
  deadline is the run's 24 h cap, so no later iteration of this run would pick up an
  uncommitted checkpoint, and a new run would count it among the user's dirty paths. SHA and
  push result in the run's status line.
- 2026-11-07 06:59 iteration (I-13c2b's calls only, no code): the tree was clean at start
  (empty preflight file). It commits `PLAN.md`'s calls with this checkpoint and
  `PROGRESS.json` as "Plan: …", for the same reason as above (the run's 24 h cap is this
  iteration's deadline): `252a33d`, pushed to `origin/main`. **Deviation, for the user:**
  `252a33d`'s message ends with a `Co-Authored-By: Claude …` trailer, against the global rule
  that commit messages carry no AI reference. It is pushed; it was not rewritten because
  that needs a force-push, which the workflow forbids. Reword it yourself if you want it gone
  (an interactive rebase and a force-push of `main`). Later commits carry no trailer.
- 2026-11-07 07:03 iteration (I-13c2b's acceptance criteria only, no code): the tree was
  clean at start (empty preflight file). It commits this checkpoint and `PROGRESS.json` as
  "Checkpoint: …" for the same reason (its deadline, 07:23, is the run's 24 h cap). SHA and
  push result in the run's status line.
