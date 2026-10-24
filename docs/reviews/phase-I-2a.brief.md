# Review brief — Phase I-2a

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM, macOS menu bar app).
  The change under review is the **uncommitted** working tree against `HEAD` (`adf79ec`).
- **Phase and goal:** I-2a — Directory store, session folders in discovery, recording (risk
  high). Scope and acceptance: `PLAN.md` "### Phase I-2 — New session: pick the directory",
  the I-2a bullet; binding specification `autoclaude/processed/20-new-session-directory-picker.md`
  (Design 1, 2, 3, 7, 8, 9 and the matching Acceptance bullets); new decision **D31** in
  `PLAN.md` *Decisions*. The app's UI must not change in I-2a (the picker is I-2b).
- **Binding conventions and safety:** `CLAUDE.md` (never build shell or AppleScript source by
  inserting runtime values; remote commands follow PLAN.md D3; no user data such as paths in
  logs, fixtures or docs; `///` doc comments; closing-brace comments past 10 lines).
- **Changed files:** `Sources/MuxFinderCore/Config/{DirectoryLists,DirectoryStore}.swift`
  (new), `Config/{HostStore,PrivateStorage}.swift` (helpers moved from `HostStore` to
  `PrivateStorage`), `Sources/MuxFinderCore/Tmux/{ProbeScript,ProbeReport,TmuxModels,
  ErrorClassifier}.swift`, `Sources/muxfinder-probe/{DiscoverCommand,RefreshCommand}.swift`,
  `Sources/MuxFinderUI/Model/{AppEnvironment,AppModel,AppModelSessions}.swift`,
  `Sources/MuxFinderUI/SelfTest/SelfTestDriver.swift`; tests
  `Tests/MuxFinderCoreTests/{DirectoryStoreTests,ProbeSessionPathTests,DiscoveryTestSupport}.swift`,
  `Tests/MuxFinderUITests/{DirectoryRecordingTests,AttachUITestSupport}.swift`, fixtures
  `Tests/MuxFinderCoreTests/Fixtures/discovery/{local-session-paths,synthetic-session-paths}.txt`;
  docs `PLAN.md` (Phase I-2 section, D31, edits to D8, D25, Architecture, Verified facts),
  `CLAUDE.md`, `docs/ARCHITECTURE.md`, `docs/TESTING.md`.
- **Verification run (orchestrator):** `swift build` exit 0; `swift test` 786 core tests in 79
  suites + 228 UI tests in 22 suites passed three times in a row — but the first run after the
  worker finished took 42 s and reported 103 issues (including the existing
  `discoversSessionsOnAPrivateServer`), the second failed only the existing
  `boundsAFloodOfTmuxErrors` (`ProbeScriptTests.swift:107`); judge whether the probe change
  could make these private-server tests load-sensitive or whether it is machine load;
  `swift format lint -r Sources Tests` exit 0; `scripts/build-app.sh` exit 0, `codesign
  --verify --deep --strict` exit 0; real read-only `discover --local` (2 sessions, 2 with a
  folder, 0 dropped) and `discover --ssh saturno-m4` with one `muxfinder-test-*` session made
  for the check (1 of 1 with a folder, 0 dropped; the session killed afterwards); real
  `--selftest new-session-local` 7/7 PASS and no `directories.json` created.
- **Risks to probe hardest:**
  1. **Path record framing** (`ProbeScript` / `ProbeReport`): each session line is followed by
     `path <nonce> <id> <session_path> <nonce>` ending only at tab + the run's nonce + newline.
     Can a path holding tabs, newlines, control characters or invalid UTF-8 break the framing
     or forge a session, client, error or other path record? How is the nonce generated and
     passed — is it data (an argument), never spliced into the shell or tmux format source,
     locally and over ssh (D3)? Is the nonce unguessable and checked on both ends? Does a
     report with no path records (and the error paths in `ErrorClassifier`) still parse and
     classify as before? Are output size caps still adequate with the extra records?
  2. **Store parity with D19** (`DirectoryStore`): 0600, safe publication, size cap, symlink
     and ownership refusal, loading never writes, unknown keys ignored, entries through
     `Validation.workingDirectory`, caps 50 saved / 8 recent per host newest first, exact-string
     duplicates, pruning removed hosts. Deviation to judge: an unusable `directories.json` is
     replaced at the next recording and the old file kept as a backup (the specification says
     the file "is left as it is" when invalid or unsafe). Each change re-reads the file first:
     any lost-update or race with a concurrent writer?
  3. **Refactor regression**: helpers moved from `HostStore` to `PrivateStorage` — any change in
     `hosts.json` behavior (backups, permissions, `save(_:expecting:)`)?
  4. **Recording rules** (`AppModelSessions`): recorded only on the `onCreated` path, also when
     the attach fails afterwards; nothing on collision, failure, `mayHaveCreated` or an empty
     field; a failed write logged by kind only and never failing the creation; the recorded
     value the checked one. Actor/isolation correctness of the write (main actor, blocking I/O?).
  5. **Injection**: the normal app uses the real file; `--selftest` an in-memory store; preview
     fixtures and `--report-popover-placement` none — can any of these touch the real file?
  6. **Privacy**: no directory path in logs, diagnostics, the operation log, fixtures or docs
     (fixtures synthetic only; `local-session-paths.txt` must hold no real user path).
- **Review file:** `docs/reviews/phase-I-2a.md` (overwrite).
- **Time budget:** 20 minutes.
