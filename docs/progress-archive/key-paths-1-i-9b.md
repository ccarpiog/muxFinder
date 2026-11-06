# Key paths, Phases 1 to I-9b (moved verbatim from `PROGRESS.md`, 2026-11-06)

- Plan: `PLAN.md`; brief: `docs/REQUIREMENTS.md`; conventions: `CLAUDE.md`; real checks:
  `docs/TESTING.md`.
- Core library:
  `Sources/MuxFinderCore/{Process,Shell,Config,Diagnostics,Tmux,ITerm2,Launch,Attach,Concurrency}/`.
- Launch helper: `Sources/muxfinder-launch/` (`muxfinder-launch attach <uuid>`); remote argv
  and D3 string: `Sources/MuxFinderCore/Launch/RemoteLaunch.swift` (D17).
- Attachment index: `Sources/MuxFinderCore/Attach/AttachmentIndex.swift` (D16).
- Refresh engine: `Sources/MuxFinderCore/Refresh/` (`RefreshCoordinator`, `HostSnapshot`,
  `RefreshSystemEvents`; D20); host list: `Sources/MuxFinderCore/Config/` (D19).
- New session directories (D31, I-2a): `Sources/MuxFinderCore/Config/{DirectoryLists,
  DirectoryStore}.swift`, path record in `Tmux/{ProbeScript,ProbeReport}.swift`, recording in
  `Sources/MuxFinderUI/Model/AppModelSessions.swift`; tests
  `Tests/MuxFinderCoreTests/{DirectoryStore,ProbeSessionPath}Tests.swift`,
  `Tests/MuxFinderUITests/DirectoryRecordingTests.swift`. Picker and Settings tab (I-2b):
  `Sources/MuxFinderUI/Model/{DirectoryPicker,AppModelDirectories,SettingsModelDirectories}.swift`,
  `Views/{DirectoryPickerViews,Settings/DirectoriesSettingsView}.swift`; tests
  `Tests/MuxFinderUITests/{DirectoryPicker,SettingsDirectories}Tests.swift`.
- Session creation: `Sources/MuxFinderCore/Tmux/TmuxCommands.swift`, `Tmux/CreatedSession.swift`
  (D18); `createAndAttach` in `Attach/AttachCoordinator.swift`; probe
  `Sources/muxfinder-probe/NewSessionCommand.swift`.
- Move here (D21): `moveHere(_:confirmation:)` in `Attach/AttachCoordinator.swift`,
  `MoveHereConfirmation` in `Attach/AttachModels.swift`, `moveHereScript` in
  `Launch/RemoteLaunch.swift`; e2e plain control client `Sources/muxfinder-probe/E2EControlClient.swift`.
- Menu bar app (D22): `Sources/MuxFinderUI/` (`Model/AppModel.swift`, `PopoverContent.swift`,
  `Views/`, `Preview/PreviewFixtures.swift`), `Sources/MuxFinderApp/` (entry point, app
  delegates); tests `Tests/MuxFinderUITests/`; bundle script `scripts/build-app.sh` →
  `build/muxFinder.app`; screenshots `docs/screenshots/`.
- Settings window (D23): `Sources/MuxFinderUI/Model/{SettingsModel,SettingsEnvironment,
  HostDraft,SettingsResults,LoginItem,FixIt,DiagnosticsReport}.swift`, `Views/Settings/`
  (`SettingsWindowController`), `Preview/{SettingsFixtures,SettingsGallery}.swift`; tests
  `Tests/MuxFinderUITests/{HostEditorTests,SettingsGeneralTests}.swift`.
- Onboarding and SSH setup (D24): `Sources/MuxFinderUI/Model/{OnboardingModel,
  SSHSetupActions}.swift`, `Views/Onboarding/`, `Preview/Onboarding{Fixtures,Gallery}.swift`;
  `Sources/MuxFinderCore/Launch/SSHSetup.swift`, `Attach/{LaunchTab,SSHSetupLauncher}.swift`;
  probe `Sources/muxfinder-probe/SSHSetupCommand.swift`; tests
  `Tests/MuxFinderCoreTests/SSHSetupTests.swift`, `Tests/MuxFinderUITests/OnboardingTests.swift`.
- Attach UX (D25): `Sources/MuxFinderUI/Model/{AppModelSessions,SessionProblem,
  SessionPanels}.swift`, `Views/SessionPanelViews.swift`, `Preview/Attach{Fixtures,
  Gallery}.swift`; self-tests `Sources/MuxFinderUI/SelfTest/{SelfTestDriver,
  SelfTestSeams}.swift`, `Sources/MuxFinderApp/SelfTestAppDelegate.swift`; tests
  `Tests/MuxFinderUITests/{AttachFlowTests,SelfTestDriverTests}.swift`.
- Persistent profiles (D26): `Sources/MuxFinderCore/Profiles/{PersistentProfiles,
  PersistentProfileInstaller,ITerm2ProfileSnapshot,PersistentProfileRun}.swift`, helper mode
  `Sources/MuxFinderCore/Launch/{ProfileLaunch,LaunchHelperProfile,LoginShell}.swift`, probe
  `Sources/muxfinder-probe/{ProfilesCommand,E2EProfileCommand}.swift`; golden files
  `Tests/MuxFinderCoreTests/Fixtures/profiles/`. Settings side (11c):
  `Sources/MuxFinderUI/Model/{PersistentProfileFiles,PersistentProfilesContent,
  SettingsModelProfiles}.swift`, `Views/Settings/ProfilesSettingsView.swift`; tests
  `Tests/MuxFinderUITests/PersistentProfilesSettingsTests.swift`.
- Probe CLI: `Sources/muxfinder-probe/` (`discover`, `iterm2 status | list-sessions |
  list-connections | list-profiles | attachments`, `attach --local|--ssh <dest> --session`,
  `detach --connection --gateway`, `e2e-local`, `e2e-remote <dest>`, `hosts show |
  suggestions`, `refresh --once`; shared harness
  `E2ERun.swift`).
- Launch tab bury (D29, 13a): client `Sources/MuxFinderCore/ITerm2/ITerm2Property.swift`
  (`setBuried`, `buryLaunchTab`, `sessionProperty`); helper restore
  `Sources/MuxFinderCore/Launch/{TerminalStatusRequest,NonBlockingTerminal,
  TerminalReturnReader}.swift` and `LaunchHelper.swift`; spike harness
  `Sources/muxfinder-probe/E2EBury{Command,Run,Support}.swift` (`e2e-bury --local | --ssh
  saturno-m4`); tests `Tests/MuxFinderCoreTests/LaunchTabRestoreTests.swift`.
- Coordinator bury and recovery (D29, 13b): `Sources/MuxFinderCore/Attach/
  AttachCoordinatorBurial.swift` (step 10, race check, buried-tab watch, `BuriedTabTimer`),
  `AttachResult.burial` / `LaunchTabBurial` in `Attach/AttachModels.swift`,
  `LaunchRequestStore.peekResult` in `Launch/LaunchStore.swift`, e2e recorder
  `Sources/MuxFinderCore/ITerm2/RecordingITerm2Integration.swift`; tests
  `Tests/MuxFinderCoreTests/{LaunchTabBurialTests,RecordingITerm2IntegrationTests}.swift`.
  13c harness judgements: `Sources/MuxFinderCore/Attach/LaunchTabChecks.swift`
  (`BuryRaceOutcome`, `KilledLaunchTabWatch`, `GatewayPlace`), tests `LaunchTabChecksTests`;
  shared "left by itself" check `checkLaunchTabLeft` in `Sources/muxfinder-probe/E2ESupport.swift`.
- Popover placement (I-1a): `Sources/MuxFinderUI/Model/{PopoverPlacement,
  PopoverWindowIdentification,NonblockingLineWriter}.swift`, diagnostic
  `Sources/MuxFinderApp/PopoverPlacement{Report,Inspection}.swift`; tests
  `Tests/MuxFinderUITests/{PopoverPlacement,PopoverWindowIdentification,
  NonblockingLineWriter}Tests.swift`.
- Menu bar item and popover panel (D30, I-1b): `Sources/MuxFinderUI/Model/{PopoverAnchoring,
  PopoverController}.swift`, `Views/{MenuBarPopover,MenuBarIcon}.swift` (`PopoverHeightLimit`
  in `MenuBarPopover.swift`); tests `Tests/MuxFinderUITests/{PopoverAnchoring,
  PopoverController,PopoverHeightLimit}Tests.swift`.
- Popover look (D22 *Look*, 14): palette, contrast helpers and state marks
  `Sources/MuxFinderUI/Views/PopoverStyle.swift`; row-state mapping in
  `Model/PopoverContent.swift`; tests `Tests/MuxFinderUITests/{PopoverStyleTests,
  PopoverContentTests}.swift`.
- Integration proof (local and over SSH, final): `docs/INTEGRATION-PROOF.md`.
- Packaging (D27): `scripts/install.sh`, `scripts/uninstall.sh`, `scripts/lib/app-copies.sh`,
  hermetic check `scripts/dev/test-install-scripts.sh`; app flag `--remove-persistent-profiles`
  (`Sources/MuxFinderCore/Profiles/PersistentProfileRemoval.swift`). User docs: `README.md`,
  `docs/ARCHITECTURE.md`, `docs/MANUAL-CHECKLIST.md`, matrix at the top of `docs/TESTING.md`.
- Global shortcut (D32, I-3a): `Sources/MuxFinderCore/Config/{GlobalShortcut,
  PreferencesStore}.swift`, `Sources/MuxFinderUI/Model/{GlobalShortcutLabel,HotkeyRegistrar,
  GlobalShortcutModel}.swift`, `Views/Settings/ShortcutRecorderView.swift`, flag
  `Sources/MuxFinderApp/HotkeyRegistrationReport.swift`; tests
  `Tests/MuxFinderCoreTests/{GlobalShortcut,PreferencesStore}Tests.swift`,
  `Tests/MuxFinderUITests/{GlobalShortcutModel,GlobalShortcutApp}Tests.swift`.
- Session switcher (D32, I-3b): `Sources/MuxFinderUI/Model/{SwitcherContent,SwitcherController,
  AppModelSwitcher}.swift`, `Views/{SwitcherView,SessionSwitcher}.swift`, gallery
  `Preview/Switcher{Fixtures,Gallery}.swift` (`--preview-gallery switcher`,
  `docs/screenshots/switcher-states-*.png`); tests
  `Tests/MuxFinderUITests/{SwitcherContent,SwitcherController,SwitcherModel}Tests.swift`.
  One click (I-5): `clickSwitcherItem(_:)` and `SwitcherClickSequence` in
  `Model/AppModelSwitcher.swift`, the mouse monitor in `Views/SessionSwitcher.swift`,
  `holdForClick()` in `Model/SwitcherController.swift`; tests
  `Tests/MuxFinderUITests/SwitcherClickTests.swift`.
- App shell (D33, I-4): main menu `Sources/MuxFinderUI/Views/MainMenu.swift`, shell report
  `Sources/MuxFinderUI/Model/AppShellReport.swift`, entry `Sources/MuxFinderApp/{MuxFinderMenuBarApp,
  AppDelegate}.swift`; tests `Tests/MuxFinderUITests/{MainMenu,AppShellReport}Tests.swift`.
- Panel key routing (I-8): `PanelKeyRoute`, `PanelFirstResponder`, `MenuTrackingObserver` in
  `Sources/MuxFinderUI/Model/PanelKeyRouting.swift`, used by `PanelKeyTrackingView`
  (`Views/PopoverWindowBridge.swift`); diagnostic `Preview/KeyViewLoopReport.swift`; tests
  `Tests/MuxFinderUITests/HostPickerKeyboardTests.swift`.
- New session window (I-9a, D34): model `Sources/MuxFinderUI/Model/AppModelNewSession.swift`,
  placement and sizing `Model/NewSessionWindowController.swift`, the panel
  `Views/NewSessionWindow.swift` (built by the app shell only); inline-form fixtures kept for
  I-9b in `Preview/AttachFixtures.swift` and `Preview/SwitcherFixtures.swift`; tests
  `Tests/MuxFinderUITests/NewSessionWindowTests.swift`. Folder drop (I-9b): pure
  `Model/FolderDrop.swift`, drop view `Views/FolderDropView.swift` (over the Directory row in
  `Views/DirectoryPickerViews.swift`), gallery `Preview/NewSessionGallery.swift`
  (`--preview-gallery new-session`, `docs/screenshots/new-session-states-*.png`); tests
  `Tests/MuxFinderUITests/FolderDropTests.swift`.
- Tests: `Tests/MuxFinderCoreTests/` (fixtures in `Fixtures/discovery/`, `Fixtures/iterm2/`).
- iTerm2 fixture generator (dev only, `-I`): `scripts/dev/gen-iterm2-fixtures.py`.
- Reviews: `docs/reviews/`; archive: `docs/progress-archive/`.
