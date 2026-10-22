# Review brief — Phase 9b (onboarding and SSH setup)

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS menu bar app).
  Conventions and binding safety rules: `CLAUDE.md`. Plan: `PLAN.md` "### Phase 9" (9a/9b
  split) and the new decision **D24**; related D14 (launch protocol), D15 (launch tab), D17
  (ssh, helper hold), D19 (`hosts.json`, `notSavedYet`, `save(_:expecting:)`), D22, D23.
- **Phase goal:** an onboarding window shown at startup only while the host list is
  `notSavedYet` (Saturno/Neptuno/Sirio editable examples, exclusive "This Mac" choice, the
  brief's four expectations, scope line, iTerm2 requirements; saves only through `HostStore`
  with changed-file protection; closing writes nothing; opening contacts no iTerm2, runs no
  ssh/tmux), and a "Set up SSH in iTerm2…" action: a new launch request kind `sshSetup`, helper
  mode `muxfinder-launch ssh-setup <uuid>` running `/usr/bin/ssh -- <dest>` by argv with a
  validated destination and the ≥10 s hold on every exit path, opened through the existing
  launch-tab path, offered in onboarding, the Settings host editor and next to
  `authFailed`/`hostKeyProblem`.
- **Changed files:** the uncommitted tree (`git status`, `git diff`). New:
  `Sources/MuxFinderCore/Launch/SSHSetup.swift`, `Sources/MuxFinderCore/Attach/{LaunchTab,
  SSHSetupLauncher}.swift`, `Sources/MuxFinderUI/Model/{OnboardingModel,SSHSetupActions}.swift`,
  `Sources/MuxFinderUI/Views/Onboarding/`, `Sources/MuxFinderUI/Preview/{OnboardingFixtures,
  OnboardingGallery}.swift`, `Sources/muxfinder-probe/SSHSetupCommand.swift`, tests
  `Tests/MuxFinderCoreTests/SSHSetupTests.swift`, `Tests/MuxFinderUITests/OnboardingTests.swift`.
  Modified: `Launch/{LaunchModels,LaunchStore,LaunchHelper,LaunchHelperPath,LaunchArgvDigest}`,
  `Attach/AttachCoordinator`, `MuxFinderUI/Model/{AppEnvironment,AppModel,AppLaunchOptions,
  SettingsEnvironment,SettingsModel,PopoverContent}`, views, preview fixtures,
  `muxfinder-launch/main.swift`, `muxfinder-probe/main.swift`, `PLAN.md`, `CLAUDE.md`,
  `docs/TESTING.md`, screenshots.
- **Verification run (orchestrator, final tree):** `swift build -Xswiftc -warnings-as-errors`
  exit 0; `swift format lint -r Sources Tests` exit 0; `swift test` exit 0 (587 core tests in
  57 suites, 98 UI tests in 7 suites); `scripts/build-app.sh` and `codesign --verify --deep
  --strict build/muxFinder.app` exit 0; app shell check (`--report-menu-bar-item`, SIGTERM)
  exit 0, no child, no `hosts.json`; `muxfinder-probe hosts show` still `notSavedYet`. No real
  ssh-setup run (it would open an iTerm2 tab and an interactive ssh; owed to a later window).
- **Risks to probe hardest:**
  1. Argument injection / shell: can any destination reach `/usr/bin/ssh` as an option, or any
     runtime value reach shell or AppleScript source? Is validation enforced in the helper
     itself (not only in the app), and does the request file's `kind` gate the mode?
  2. Backward compatibility: old request files (no `kind`) must decode and behave exactly as
     attach; attach requests must be written as before; kind/mode mismatch refused.
  3. The helper's ≥10 s hold on every ssh-setup exit path (refused request, ssh exit 255, ssh
     success, signals) — iTerm2 raises a blocking modal for tabs that end within 3 s.
  4. Onboarding writes nothing unless the user saves; save goes through `save(_:expecting:)`;
     "This Mac" exclusivity; no iTerm2/ssh/tmux contact on open; shown only for `notSavedYet`.
  5. The `LaunchTab` refactor out of `AttachCoordinator`: any behavior change for attach /
     create / move here (single flight, generations, failure handling, D15).
  6. Concurrency: actor/MainActor isolation, task cancellation on window close and app
     shutdown for the new action and the onboarding window.
- **Review file:** `docs/reviews/phase-9b.md`.
- **Time budget:** 15 minutes.
