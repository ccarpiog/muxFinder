# PROGRESS.md key paths, Phases I-10a to I-12e (moved verbatim at I-13a, 2026-11-07)

- Folder search core (I-10a, D36): `Sources/MuxFinderCore/FolderSearch/` (`FolderSearchText`
  escaping, `FolderSearchScript` the static script, `FolderSearchOutput` the parser,
  `FolderSearchTransport`, `FolderSearchChannel`, `FakeFolderSearchTransport`),
  `Sources/MuxFinderCore/Process/StreamingProcess.swift`, the scope in
  `Config/PreferencesStore.swift`, probe `Sources/muxfinder-probe/FoldersCommand.swift`; tests
  `Tests/MuxFinderCoreTests/FolderSearch*Tests.swift` and `FolderSearchTestSupport.swift`.
- Folder search UI (I-10b): `Sources/MuxFinderUI/Model/{FolderSearchSection,AppModelFolderSearch,SettingsModelFolderSearch}.swift`,
  `Views/DirectoryPickerViews.swift`, `Views/Settings/DirectoriesSettingsView.swift`,
  `Preview/FolderSearchFixtures.swift`; tests
  `Tests/MuxFinderUITests/{FolderSearchSectionTests,FolderSearchModelTests,SettingsFolderSearchTests,FolderSearchUITestSupport}.swift`.
- Detach other clients (I-11a, D37): `Sources/MuxFinderCore/Attach/{AttachCoordinatorDetachOthers,DetachOtherClientsModels}.swift`,
  `ITerm2/ITerm2APIClient.swift` (`commandOutput(of:)`), probe
  `Sources/muxfinder-probe/E2EDetachOthers{Command,Run}.swift`; tests
  `Tests/MuxFinderCoreTests/DetachOtherClientsTests.swift`.
- Detach other clients UI (I-11b): `Sources/MuxFinderUI/Model/{AppModelSessions,SessionPanels,SessionProblem,SwitcherContent}.swift`,
  `Views/{SessionPanelViews,SessionRowView,SwitcherView}.swift`, `Preview/AttachFixtures.swift`;
  tests `Tests/MuxFinderUITests/DetachOtherClientsUITests.swift`.
- Other terminals (I-12a, D38): `Sources/MuxFinderCore/Launch/{PlainLaunch,PlainBoundCommands}.swift`,
  `Sources/MuxFinderCore/Terminals/{AutomationPermission,TerminalCommandText}.swift`, probe
  `Sources/muxfinder-probe/{TerminalsCommand,PlainProofCommand,PlainProofRun,PlainProofTerminal}.swift`;
  tests `Tests/MuxFinderCoreTests/{PlainLaunch,PlainBoundCommands,TerminalCommandText,AutomationPermission}Tests.swift`.
- Terminal definitions (I-12b1): `Sources/MuxFinderCore/Terminals/{TerminalDefinition,TerminalDefinitionParser,TerminalDefinitionProblem,TerminalDefinitionLoader,TerminalLaunchCommand,AppleScriptRunner,TerminalScriptCalls,TerminalAppFacts,JSONDuplicateNameScanner}.swift`,
  built-ins `Resources/Terminals/`; tests
  `Tests/MuxFinderCoreTests/{TerminalDefinition,TerminalDefinitionLoader,TerminalLaunchCommand,AppleScriptRunner}Tests.swift`.
- Helper plain mode (I-12b2): `Sources/MuxFinderCore/Launch/{LaunchHelperPlain,PlainLaunchReport,LaunchModels,LaunchStore,TerminalChildRunner}.swift`;
  tests `Tests/MuxFinderCoreTests/{LaunchHelperPlain,PlainLaunchReport,LaunchHelperProfilePlain,LaunchHelperPlainBinary}Tests.swift`.
- Terminal seam (I-12b3): `Sources/MuxFinderCore/Terminals/{TerminalBackend,ITerm2TerminalBackend,PlainTerminalWindows,PlainTerminalWindowError,PlainTerminalSeams,PlainTerminalFakes}.swift`;
  tests `Tests/MuxFinderCoreTests/{ITerm2TerminalBackend,PlainTerminalWindows,PlainTerminalSeams}Tests.swift`.
- Plain backend (I-12c1): `Sources/MuxFinderCore/Terminals/{PlainTerminalBackend,PlainTerminalBackendDetach,PlainTerminalBackendModels,PlainTmuxCommands,PlainTerminalBackendFakes}.swift`,
  `Sources/MuxFinderCore/Attach/AttachSharedSteps.swift`; tests
  `Tests/MuxFinderCoreTests/PlainTerminalBackend{,Detach,EndToEnd}Tests.swift`,
  `PlainTerminalBackendTestSupport.swift`.
- Open on this Mac (I-12c2): `Sources/MuxFinderCore/Terminals/{ProcessTable,ProcessTableFakes,LocalClientAttribution}.swift`,
  discovery's `tty` record in `Tmux/{ProbeScript,ProbeReport}.swift`, `Refresh/RefreshCoordinator.swift`
  (`localClients:`), probe `Sources/muxfinder-probe/LocalClientsCommand.swift`; tests
  `Tests/MuxFinderCoreTests/{ProbeClientFields,LocalClientAttribution,LocalClientsReal,RefreshLocalAttachments,PlainTerminalBackendOpenHere}Tests.swift`.
- Onto the seam (I-12c3a): `Sources/MuxFinderCore/Terminals/{TerminalChoice,AttachCommandOptions}.swift`,
  `Config/PreferencesStore.swift` (`terminal`), `Sources/MuxFinderUI/Model/{TerminalEnvironment,AppModelTerminal,AppEnvironment,AppModelSessions}.swift`,
  `SelfTest/SelfTestDriver.swift`, probe `Sources/muxfinder-probe/AttachCommand.swift`; tests
  `Tests/MuxFinderCoreTests/{TerminalChoice,TerminalSeamCore}Tests.swift`,
  `Tests/MuxFinderUITests/TerminalSeamTests.swift`.
- The plain runs (I-12c3b): `Sources/MuxFinderCore/E2EPlain/{E2EPlainOptions,E2EPlainSeams,E2EPlainRun,E2EPlainRunCleanup}.swift`,
  probe `Sources/muxfinder-probe/E2EPlainCommand.swift`; tests
  `Tests/MuxFinderCoreTests/{E2EPlainRun,E2EPlainSteps}Tests.swift`.
- Settings, onboarding and SSH setup (I-12d1): `Sources/MuxFinderCore/Terminals/PlainSSHSetupLauncher.swift`,
  `Sources/MuxFinderUI/Model/{TerminalWording,TerminalPicker,PersistentWorkContent}.swift`,
  `Views/Settings/TerminalPickerView.swift`, `Preview/TerminalPickerFixtures.swift`; tests
  `Tests/MuxFinderCoreTests/PlainSSHSetupLauncherTests.swift`,
  `Tests/MuxFinderUITests/TerminalPickerTests.swift`.
- The popover, the switcher and the session states (I-12d2):
  `Sources/MuxFinderUI/Model/{TerminalWordingSessions,TerminalWordingFailures,SessionProblemTerminal,AppModelTerminalSessions}.swift`,
  `Preview/{TerminalSessionFixtures,TerminalAttachFixtures}.swift`; tests
  `Tests/MuxFinderUITests/{TerminalSessionWordingTests,TerminalSessionModelTests,TerminalReviewFixTests}.swift`,
  `Tests/MuxFinderCoreTests/TerminalPublicInitTests.swift`.
- Other terminals, user-facing reference (I-12e): `docs/TERMINALS.md`.
