# PROGRESS.md head lines for Phases I-13a to I-13c2a (moved verbatim on 2026-11-07, the run's last iteration)

## Acceptance

- Phases I-13a, I-13b1, I-13b2: all criteria met (6, 8 and 10), 2026-11-07 — the check core,
  download and verification (`update verify` real in zip mode on private copies of
  `build/muxFinder.zip`; `notarized` proven), eligibility and install (`RENAME_SWAP` proven,
  `--report-update-eligibility` not eligible on `build/`); no request to any server, no
  `open`, no real swap — `docs/progress-archive/{i-13a,i-13b1,i-13b2}.md`.
- Phase I-13c1: all 8 criteria met, 2026-11-07 — the mode gate (normal launch only, every
  mode enumerated in a test), the scheduler wired and proven over an injected transport and
  clock, notice, dot and seen version, Settings › General "Updates", galleries and the four
  screenshots, D39 / `CLAUDE.md` / TESTING / checklist 31; 567 UI + 1365 core tests; no
  normal launch, no request, no update state in any private home or the real support folder
  — `docs/progress-archive/i-13c1.md`.
- Phase I-13c2a: all 5 criteria met, 2026-11-07 — the flow's states and transitions tested
  over a fake pipeline (`UpdateFlowTests`), cleanup and pipeline in normal mode only (the
  mode test), no visible change but the edit lock, 587 UI + 1366 core tests, no `update`
  folder in the real support folder — `docs/progress-archive/i-13c2a.md`.

## Decisions

- Phase I-13 (at selection, 2026-11-07): split into I-13a (check core), I-13b (install
  pipeline core), I-13c (UI, wiring, docs), recorded in `PLAN.md` *Phase I-13* with "The run
  rule" and "The orchestrator's calls for I-13a"; *Unattended-run rules* 3 tightened (no run
  sends a request to GitHub or any server; the OS's signature assessment of a local file is
  not such a request), since the user never edited the rule for GitHub; `update verify` may
  run for real only on a local copy of `build/muxFinder.zip` (I-13b). New decision **D39**.
  The workers' calls are in `docs/progress-archive/i-13a.md`.
- Phase I-13b (at selection, 2026-11-07): split into I-13b1 (download and verification) and
  I-13b2 (eligibility and install), with "The orchestrator's calls for I-13b1" in `PLAN.md`
  *Phase I-13* (given private staging folder, redirect allowlist, `ditto` argv, requirement
  with the Team ID validated first, the worker to prove `notarized`, ad hoc signing only).
  The workers' calls (bounds, `Accept-Encoding: identity`, local-header rule, identity
  binding) are in D39 and `docs/progress-archive/i-13b1.md`.
- Phase I-13b2 (at selection, 2026-11-07): "The orchestrator's calls for I-13b2" in `PLAN.md`
  *Phase I-13* (staging root in the support folder, never beside the bundle; `differentVolume`
  not eligible; translocation by path component, no `dlsym`; constant relauncher script; old
  sources by `git archive` for the worker). Workers' calls (no two-rename fallback, the wait
  as an argument, recovery marker, scan exceptions) in D39 and `docs/progress-archive/i-13b2.md`.
- Phase I-13c (at selection, 2026-11-07): split into I-13c1 (the notice), I-13c2 (the
  one-click update), I-13c3 (the documents), with "The orchestrator's calls for I-13c1" in
  `PLAN.md` *Phase I-13* (one pure mode gate, normal launch only; the dot drawn at runtime;
  the seen version through a scheduler method; no Update button before c2). Workers' calls
  (Settings section hidden without machinery, seen only from the main view, serialized state
  saves, ordered toggle saves) in D39 and `docs/progress-archive/i-13c1.md`.
- Phase I-13c2 (at selection, 2026-11-07): split into I-13c2a (the flow, model and wiring,
  high) and I-13c2b (the views, routine), with "The orchestrator's calls for I-13c2a" in
  `PLAN.md` *Phase I-13* (eligibility per notice version off the main actor; Download for
  every not-eligible reason and no asset; the ask over injected unsaved work with Not now
  keeping the prepared update; quit through an injected terminator only after
  `relaunchScheduled`; cleanup at launch only through `createsUpdateMachinery`, never
  creating the root). Review-fix calls: a quit before the swap aborts at a pre-swap
  checkpoint, after it waits for the swap and any rollback; edits locked at the model layer
  from the final unsaved-work decision through termination (the one view change in c2a).
  Workers' calls in D39 and `docs/progress-archive/i-13c2a.md`.

## Open risks / deviations

- I-13a (**for the user**): the real `update check` request to GitHub, checklist 30. The probe
  accepts a 0500 `--state` folder and then fails to save (exit 1, mode unchanged). Nothing in
  the app creates the scheduler or reads the toggle yet (I-13c) —
  `docs/progress-archive/i-13a.md`.
- I-13b1 (**for the user**): the real `update verify --latest` (the real download and
  GitHub's current redirect hosts), checklist 30. A size lie finishing inside one 50 ms
  watchdog interval is caught only by the final measure. The checked bundle's contents can
  still change inside the private staging folder after the check until I-13b2's re-check
  before the swap (D39). Workers: 13 test folders left once in `/private/tmp` (removed), one
  read-only `git diff --stat` against the brief — `docs/progress-archive/i-13b1.md`.
- I-13b2 (**for the user**, I-13c's checklist): the real update end to end on a Developer ID
  build, and whether `/usr/bin/open` with only `PATH` opens the new copy. An unwritable
  recovery marker lets a later cleanup delete that run folder. Flaky runs seen: one full
  `swift test` hang (killed), `panelRootIsNoTallerThanItsLimit` and `answersAndEndsAtEndOfInput`
  once each, both passing alone. **Release numbering**: `v0.3.0` (build 3) was released from
  branch `release/0.3.0` (`1c037ea`), not `main` (still 0.2.0 build 2), so the next release
  from `main` needs a build above 3 (D35) — `docs/progress-archive/i-13b2.md`.
- I-13c1 (**for the user**, checklist 31): the real notice, the dot and its clearing, the
  Settings line after a real check, and the toggle off; no run launched the app in normal
  mode, so the real wiring is proven by the gate, the composition and injected-transport
  tests only. The notice's gallery state scrolls the host list (440 pt limit). The
  implementation worker ran one read-only `git status`, against its brief —
  `docs/progress-archive/i-13c1.md`.
- I-13c2a: the regressions for review findings 2 (edits during install) and 4 (notice during
  prepare) pass but were not run against the old code; a quit during the install's pre-swap
  code check waits for that local check with no deadline; Settings' Save is refused too while
  an update installs; no real update ran (I-13c3's checklist) —
  `docs/progress-archive/i-13c2a.md`.

## Reviews

- Phases I-13a, I-13b1, I-13b2: Codex wrote each file (`autoclaude-review.sh`), all
  `ship-with-fixes` (I-13a 2 should-fix; I-13b1 2 blockers; I-13b2 2 blockers + 1 should-fix);
  every finding fixed by a review-fix worker with a regression failing on the old code,
  re-verified by the orchestrator — `docs/reviews/phase-I-13{a,b1,b2}.md`, summaries in
  `docs/progress-archive/{i-13a,i-13b1,i-13b2}.md`.
- Phase I-13c1: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 0
  blockers + 2 should-fix (startup overwrote a toggle change made during the preference load;
  `markNoticeSeen` published before its save, so a failed save could clear the dot and
  interleaved saves could lose fields); both fixed by a review-fix worker (a change after
  start wins and toggle saves run in order; serialized state saves, publish after success),
  each regression failing with its fix reverted, re-verified by the orchestrator —
  `docs/reviews/phase-I-13c1.md`, summary in `docs/progress-archive/i-13c1.md`.
- Phase I-13c2a: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 2
  blockers + 2 should-fix (a quit timeout abandoned the installer; edits during install were
  discarded; a cleared notice could not restore the same version's action; notice changes
  during prepare were dropped); all four fixed by a review-fix worker (pre-swap cancellation
  and a quit that waits for the swap; the edit lock; eligibility cached per version; the
  latest notice kept and `preparedRelease`), regressions for 1 and 3 failing with their fix
  reverted, 2 and 4 unconfirmed; re-verified by the orchestrator —
  `docs/reviews/phase-I-13c2a.md`, summary in `docs/progress-archive/i-13c2a.md`.

## Key paths

- Update check core (I-13a, D39): `Sources/MuxFinderCore/Update/{UpdateVersion,UpdateRelease,UpdateTransport,UpdateCheck,UpdateState,UpdateStateStore,UpdateScheduler,UpdateProbe}.swift`,
  `Config/PreferencesStore.swift` (`checkForUpdatesAutomatically`), probe
  `Sources/muxfinder-probe/UpdateCommand.swift`; tests
  `Tests/MuxFinderCoreTests/Update*Tests.swift` and `UpdateTestSupport.swift`.
- Download and verification (I-13b1, D39):
  `Sources/MuxFinderCore/Update/{UpdateStaging,UpdateDownload,UpdateArchive,UpdateExtraction,UpdateCodeCheck,UpdateBundleVersions,UpdateVerification,UpdateVerifyProbe}.swift`;
  tests `Tests/MuxFinderCoreTests/Update{Download,Archive,Extraction,CodeCheck,BundleVersions,Verifier,VerifyProbe}Tests.swift`
  and `UpdateVerifyTestSupport.swift`.
- Eligibility and install (I-13b2, D39):
  `Sources/MuxFinderCore/Update/{UpdateEligibility,UpdateEligibilityReader,UpdateStagingRoot,UpdateProcessScan,UpdateSwap,UpdateRelauncher,UpdatePipeline}.swift`,
  the flag in `Sources/MuxFinderUI/Model/AppLaunchOptions.swift` and
  `Sources/MuxFinderApp/MuxFinderMenuBarApp.swift`; tests listed in
  `docs/progress-archive/i-13b2.md`.
