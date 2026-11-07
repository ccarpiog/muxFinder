# Review brief — Phase I-13c3 (the update feature's documents)

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (native macOS menu bar app, Swift 6,
  SwiftPM). Conventions and binding safety rules: `CLAUDE.md`.
- **Phase and goal:** I-13c3, routine, documents only. Document the update check and
  one-click update (PLAN.md D39) for users, maintainers and agents: README "Updates" section,
  `docs/ARCHITECTURE.md` update feature, `docs/TESTING.md` summary rows and unit-test counts,
  `docs/MANUAL-CHECKLIST.md` item 33 (real update end to end on a Developer ID build, plus a
  failure case), the release contract on `CLAUDE.md`'s release line and as a D35 bullet, D35
  history with 0.3.0 (3), D39's "Not yet" rewritten. Binding scope: `PLAN.md` *Phase I-13*,
  "The orchestrator's calls for I-13c3" (`rg -n "calls for I-13c3" PLAN.md`); criteria in
  `PROGRESS.md` *Acceptance*, the "Phase I-13c3 (in progress)" bullet.
- **Changed files (uncommitted):** `README.md`, `docs/ARCHITECTURE.md`, `docs/TESTING.md`,
  `docs/MANUAL-CHECKLIST.md`, `CLAUDE.md`, `PLAN.md`; plus the workflow records
  `PROGRESS.md`, `PROGRESS.json` (not under review). No file under `Sources/`, `Tests/`,
  `scripts/` or `Resources/` changed.
- **Verification run (orchestrator):** `swift build` exit 0; `swift format lint -r Sources
  Tests` exit 0; `env -u TMUX_TMPDIR swift test` first run one failure in the "Folder search
  transport" suite (known load flake, untouched code), the suite alone 8/8, the next full run
  604 UI + 1366 core tests passed.
- **Risks to check hardest:**
  1. **Factual accuracy against the code.** Every claim about what the check sends, when it
     runs or never runs, the toggle, the notice, Update vs Download (the eligibility
     reasons), the verification steps, the ask, the swap and relaunch, and the release
     contract (tag form, draft/prerelease, the `muxFinder.zip` asset, its URL, `digest`,
     size limit, `state`, team and notarization checks, version and build rules) must match
     `Sources/MuxFinderCore/Update/`, `Sources/MuxFinderUI/Model/Update*.swift`,
     `Sources/MuxFinderUI/Views/UpdateViews.swift`, `Sources/MuxFinderApp/` and D39. The
     worker changed some claims on its own judgment (README no longer says no download was
     published; "an unchanged answer costs nothing" softened; items 31 and 32 now ask for a
     copy that has the update feature; a digest mismatch called unstageable on GitHub): check
     each is right.
  2. **Manual checklist item 33** must be executable by the user as written and safe (no
     step that writes iTerm2 preferences, `~/.ssh` or shell startup files; never a path of
     the user's), with expected results that the code would actually produce.
  3. **Safety and privacy:** the public repository must not name the private download site
     or its address, a Team ID value, the user's paths, or session names.
  4. **`CLAUDE.md`** describes present state only (no dated paragraph), and its release line
     does not contradict D28, D35 or `scripts/release.sh`.
  5. **`docs/TESTING.md` counts** agree with the run above (604 UI in 61 suites, 1366 core in
     152 suites).
- **Review file:** `docs/reviews/phase-I-13c3.md` (overwrite).
- **Time budget:** 15 minutes. Read-only: run nothing that contacts a server, launches the
  app, `open`s anything, or runs install/uninstall, release or e2e scripts.
