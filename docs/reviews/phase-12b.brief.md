# Phase 12b review brief

- Repo: `/Users/ccarpio/Developer/Utils/muxFinder` (native macOS menu bar app, Swift 6, SwiftPM).
  Conventions and binding safety rules: `CLAUDE.md`. Plan: `PLAN.md` "### Phase 12" (its
  "Split" paragraph defines 12b, its "Acceptance" paragraph the bar). Brief:
  `docs/REQUIREMENTS.md` ("Orbit" there means muxFinder).
- Phase: **12b — Acceptance run (routine, real runs).** Goal: a fresh full run on the final
  tree of every unit test, `e2e-local`, `e2e-remote saturno-m4`, `e2e-profile --local` and
  `--ssh saturno-m4`, both app self-tests and the clean-`build/` reproduction, with date,
  command and exit status recorded in `docs/TESTING.md`'s tested vs expected-to-work matrix;
  every brief acceptance bullet mapped to evidence or to "unverified: why"; signing status
  stated truthfully. The runs needed no code fix, so the change is documentation only.
- Review the **uncommitted** working tree against `HEAD` (`520b7e3`).

## Changed files

- Modified: `docs/TESTING.md` (matrix "12b fresh run" column, deliverables table, new
  "Phase 12b — acceptance run" section). `PROGRESS.json` is a workflow record, not a
  deliverable.

## Verification already run (orchestrator, 2026-10-23 WEST, tree at `520b7e3`, all exit 0)

- `swift build -Xswiftc -warnings-as-errors`; `swift test`: 680 core tests in 67 suites + 159 UI
  tests in 13 suites; `swift format lint -r Sources Tests`.
- `rm -rf build && scripts/build-app.sh` (signed "Apple Development", not notarized), then
  `codesign --verify --deep --strict build/muxFinder.app`.
- `scripts/dev/test-install-scripts.sh`: 35/35 PASS.
- Real runs, `TMUX_TMPDIR` unset, gated by `iterm2 status` and the iTerm2 thread count
  (≤ 38) before each: `e2e-local` 16/16 in 63.4 s; `e2e-remote saturno-m4` 17/17 in 121.8 s;
  `e2e-profile --local` 14/14 in 11.3 s; `e2e-profile --ssh saturno-m4` 14/14 in 15.7 s;
  `muxFinder --selftest attach-local` passed (6 steps); `--selftest new-session-local` passed
  (5 steps); plus `--selftest attach-local --selftest-keep` then `kill -TERM` (exit 0, session
  and connection survived, then cleaned up by detach and kill) for matrix row 12.
- Raw run logs (step lines only carry synthetic session names and ids):
  `/tmp/mfx-12b-e2e-local.log`, `/tmp/mfx-12b-e2e-remote.log`,
  `/tmp/mfx-12b-e2e-profile-local.log`, `/tmp/mfx-12b-e2e-profile-ssh.log`,
  `/tmp/mfx-12b-selftest-attach.log`, `/tmp/mfx-12b-selftest-new.log`,
  `/tmp/mfx-12b-selftest-keep.log`, `/tmp/mfx-12b-test.log`, `/tmp/mfx-12b-install.log`,
  `/tmp/mfx-12b-buildapp.log`; thread samples `/tmp/mfx-12b-threads.log`.

## Risks to probe

- **Truthfulness of the record.** Every result in `docs/TESTING.md` must match the logs above
  (step counts, durations, exit statuses, dates); nothing may claim more than was run (for
  example a matrix row citing an e2e step that does not prove that row's bullet, or a result
  attributed to the wrong run).
- **Coverage.** Each acceptance bullet of `docs/REQUIREMENTS.md` must map to evidence or to
  "unverified: why"; nothing owed to a person (`docs/MANUAL-CHECKLIST.md`) may be shown as
  tested. Nothing in the doc should still call the 12b run owed or in progress.
- **Consistency.** `docs/TESTING.md` against `README.md` (signing, not notarized),
  `docs/MANUAL-CHECKLIST.md` and `CLAUDE.md` (commands as documented).
- **Data hygiene.** No terminal contents, window titles, `~/.ssh/config` host names or other
  user data in the doc.

## Do not

- Run any real check (`e2e-*`, `--selftest`, `muxfinder-probe iterm2 …`, `attach`, `detach`),
  anything that contacts iTerm2, tmux or ssh, or `scripts/install.sh` / `uninstall.sh`.
  Hermetic commands (`swift build`, `swift test`, `swift format lint`) are fine.
- Edit any file other than the review file.

## Review file and budget

- Write the report to `docs/reviews/phase-12b.md`. Time budget: 10 minutes.
