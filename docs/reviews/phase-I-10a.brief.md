# Review brief — Phase I-10a (folder search core)

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (SwiftPM macOS menu bar app, Swift 6).
  Review the **uncommitted** working tree against `HEAD`.
- **Phase and goal:** I-10a, the core of Spotlight folder search for New session (no UI). A
  static POSIX `sh` script, run locally by argv or over noninteractive ssh (PLAN.md D3), prints
  a header (home, `mdfind` present, `mdutil -s` indexing state, readability of Desktop /
  Documents / Downloads), then answers query lines from stdin (id, scope `home|disk`, escaped
  name text) with NUL-separated folder paths filtered by a fixed noise rule, at most 50, and an
  end record per query. Swift side: escaping, answer parser, streaming process transport,
  channel state machine (debounce, one in flight, latest wins, reopen once, quiet close), scope
  preference in `preferences.json`, probe `muxfinder-probe folders`.
- **Binding design:** `PLAN.md` "### Phase I-10" (the orchestrator's calls) and the new
  **D36** in *Decisions*; D3, D11 and D32 edited. Specification:
  `autoclaude/processed/100-folder-search-spotlight.md` (requirements 1, 2, 4 store side, 7).
- **Changed files:** `Sources/MuxFinderCore/FolderSearch/` (new: `FolderSearchText`,
  `FolderSearchScript`, `FolderSearchOutput`, `FolderSearchTransport`, `FolderSearchChannel`,
  `FakeFolderSearchTransport`), `Sources/MuxFinderCore/Process/StreamingProcess.swift` (new),
  `Sources/MuxFinderCore/Config/PreferencesStore.swift`, `Sources/muxfinder-probe/{FoldersCommand,main}.swift`,
  `Tests/MuxFinderCoreTests/FolderSearch*Tests.swift` + `FolderSearchTestSupport.swift`,
  `Tests/MuxFinderUITests/GlobalShortcutTestSupport.swift`, `PLAN.md`, `CLAUDE.md`, `README.md`,
  `docs/ARCHITECTURE.md`, `docs/TESTING.md` (*Phase I-10a*).
- **Verification run (orchestrator, final tree):** `swift build` exit 0; `swift format lint -r
  Sources Tests` exit 0; `swift test` exit 0 (874 core tests in 87 suites, 431 UI in 43);
  `scripts/build-app.sh` exit 0; `codesign --verify --deep --strict build/muxFinder.app` exit 0.
  Worker: `-warnings-as-errors` builds exit 0; real `folders --count-only` runs on this Mac and
  `saturno-m4` (counts and timings in `docs/TESTING.md`), no child left.
- **Risks to probe hardest:**
  1. **Injection / predicate steering.** Can any typed text (quotes, backslashes, `*`, `?`,
     newlines, NUL, Unicode separators, very long input) escape the folder-name predicate,
     reach shell evaluation, or alter `mdfind` arguments, locally or through D3's ssh string?
     Is the script truly static, and does it validate id, scope and text?
  2. **Script correctness in POSIX `sh` on macOS:** NUL-separated handling (names with
     newlines), the noise rule exactly as PLAN.md's call states (a)–(d) for both scopes, the
     50 limit, stopping `mdfind` early, end records always written (including on `mdfind`
     failure), behavior when stdin closes mid-query.
  3. **Process lifecycle:** no child (`ssh`, `sh`, `mdfind`, `xargs`) ever left running — on
     close, timeout, parent exit, probe SIGINT/SIGTERM; pipe deadlocks (stderr not drained,
     a full stdout pipe while writing stdin); bounded buffers everywhere.
  4. **Channel state machine:** races between debounce, in-flight answers, stale ids, reopen
     once vs. second failure, quiet close, host change; Swift 6 concurrency correctness.
  5. **Preference store:** the new key under D32's lock and unusable-file rules; an unknown
     value treated as absent and not rewritten; existing `preferences.json` contents
     preserved on save.
  6. **Privacy:** no folder name or path in logs, fixtures, tests, docs or probe default
     output (the home shown only as "present"); `--paths` the only way to print paths.
  7. Conventions: `///` on every declaration, closing-brace comments on >10-line functions
     and loops, no third-party dependency, docs describing present state.
- **Do not** run real Spotlight queries on hosts other than this Mac, `--paths`, the app via
  `open`, or anything touching iTerm2 or tmux. Hermetic `swift test --filter FolderSearch`
  is fine.
- **Review file:** `docs/reviews/phase-I-10a.md`.
- **Time budget:** 20 minutes.
