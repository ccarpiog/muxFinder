# Review brief — Phase I-12b1 (other terminals: definitions, loader, AppleScript runner)

- **Repository**: `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS 14 menu
  bar app). Review the **uncommitted** working tree against `HEAD`.
- **Phase goal**: strict JSON terminal definitions (`schemaVersion` 1, unknown keys refused),
  a read-only loader under D19's file rules (built-ins from a directory passed in, user
  definitions from `~/Library/Application Support/muxFinder/terminals/`, overrides by id,
  per-file problems never fatal), built-in Terminal.app and Ghostty definitions with their
  AppleScript files in `Resources/Terminals/` copied and signed by `scripts/build-app.sh`,
  `exec` argv expansion with whole-argument placeholders, the `shellText`/`words` command
  forms, an AppleScript handler runner seam (real over `NSAppleScript`, plus a fake), per
  definition app facts read without a prompt, and `muxfinder-probe terminals list` extended
  with definitions and problems. Nothing in the app, helper or coordinator uses it yet.
- **The binding calls**: `PLAN.md`, section *Phase I-12*, block "I-12b split, and the
  orchestrator's calls" ("Calls for I-12b1"); D38 (its new "Definitions (I-12b1)" sub-bullet,
  the Terminal and Ghostty open forms), D3's extension, D19's file rules; requirement 3 of
  `autoclaude/processed/110-other-terminal-apps.md`. Safety: `CLAUDE.md` *Safety rules* and
  `PLAN.md` *Unattended-run rules* 8 (never launch Terminal or Ghostty; never compile a
  built-in script, since compiling a `tell` block reads the target's dictionary).
- **Changed files**: new `Sources/MuxFinderCore/Terminals/{TerminalDefinition,
  TerminalDefinitionParser,TerminalDefinitionProblem,TerminalDefinitionLoader,
  TerminalLaunchCommand,AppleScriptRunner,TerminalScriptCalls,TerminalAppFacts}.swift`,
  `Resources/Terminals/{terminal,ghostty}.{json,applescript}`,
  `Tests/MuxFinderCoreTests/{TerminalDefinitionTestSupport,TerminalDefinitionTests,
  TerminalDefinitionLoaderTests,TerminalLaunchCommandTests,AppleScriptRunnerTests}.swift`;
  modified `Sources/muxfinder-probe/TerminalsCommand.swift`, `scripts/build-app.sh`,
  `PLAN.md`, `CLAUDE.md`, `docs/TESTING.md`, `PROGRESS.json` (workflow record, ignore).
- **Verification run** (orchestrator, final tree): `swift build` exit 0; `swift format lint -r
  Sources Tests` exit 0; `swift test` 986 core tests in 97 suites and 485 UI tests in 47
  suites passed; `scripts/build-app.sh` exit 0, the four files in
  `Contents/Resources/Terminals/`; `codesign --verify --deep --strict build/muxFinder.app`
  exit 0; `terminals list` exit 0 (two built-ins, no problems); Terminal and Ghostty not
  running before or after. Worker: `-warnings-as-errors` build exit 0, `terminals list` on
  private folders (user, user override, problem).
- **Risks to probe**:
  - The loader's file rules: symbolic links anywhere on the path, TOCTOU between checks and
    reads (opened without following links? checks on the open descriptor?), ownership, mode,
    ACLs, size limits enforced on what is read rather than on a `stat`, file count, a script
    referenced by a user definition held to the same rules, a script name escaping the
    folder.
  - The schema: unknown keys at every level, type confusion (numbers, nulls, duplicate keys),
    the `iterm2` reservation, placeholders (whole argument, exactly once, unknown), the
    `exec` executable path (no `..`, no leading `/`, resolved inside the app bundle), focus
    kind constraints.
  - The `words` form: is every word really limited so Ghostty's `command` cannot be split or
    expanded under any parsing; is the `shellText` form exactly D3's extension.
  - The runner: Apple event construction (no script source built from values), reply parsing
    strictness, error numbers, main-actor use of `NSAppleScript`.
  - The built-in scripts: no `do script … in`, `contents`, `history`, `input text`, `send
    key`, mouse commands; close only by the recorded id and only when nothing runs; whether
    they match the apps' dictionaries (`sdef` may be read; never compile them).
  - `terminals list`: still launches nothing, sends no prompting event, writes nothing,
    compiles nothing; the default directories.
  - Conventions: `///` doc comments everywhere, closing-brace comments on >10-line
    functions and loops, English sentence-case strings.
- **Review file**: `docs/reviews/phase-I-12b1.md`.
- **Time budget**: 15 minutes.
