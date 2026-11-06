# Review brief — Phase I-12b3 (terminal seam)

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (native macOS menu bar app, Swift 6,
  SwiftPM). Conventions and binding safety rules: `CLAUDE.md`.
- **Phase and goal:** I-12b3 of *Phase I-12* (other terminal apps beside iTerm2). A
  terminal-neutral seam at the level of the attach coordinator's session operations, the
  iTerm2 backend as an adapter over `AttachCoordinator` with no behaviour change, and the plain
  window layer (open, focus, close of a Terminal.app / Ghostty / `exec` terminal window from a
  `LoadedTerminalDefinition`, through the `AppleScriptRunning` seam or a spawn seam). Nothing
  in the app is rewired yet (I-12c). The binding spec is `PLAN.md` *Phase I-12*, block "Calls
  for I-12b3"; the record is `PLAN.md` D38 sub-bullet "Terminal seam (I-12b3)"; background in
  D38's "Definitions (I-12b1)" and "Helper plain mode (I-12b2)".
- **Changed files (uncommitted):**
  - New: `Sources/MuxFinderCore/Terminals/{TerminalBackend,ITerm2TerminalBackend,PlainTerminalWindows,PlainTerminalWindowError,PlainTerminalSeams,PlainTerminalFakes}.swift`;
    `Tests/MuxFinderCoreTests/{ITerm2TerminalBackendTests,PlainTerminalWindowsTests,PlainTerminalSeamsTests}.swift`.
  - Modified: `PLAN.md` (the calls block and the D38 sub-bullet), `docs/TESTING.md` (*Phase
    I-12b3*), `PROGRESS.json` (workflow record, ignore).
- **Verification run (orchestrator):** `swift build` exit 0; `swift format lint -r Sources
  Tests` exit 0; `swift test` exit 0, 1053 core tests in 104 suites and 485 UI tests in 47
  suites. No existing source or test file changed (`git diff --stat` touches only the three
  documents above).
- **Risks to look at hardest:**
  1. The `exec` spawn (`posix_spawn`, own session, `/dev/null` stdio, a background reaper):
     descriptor leaks into the child (is everything but 0–2 closed or `CLOEXEC`?), zombie
     handling, signal masks/dispositions inherited, the call never blocking and never killing
     the program, the reaper's thread safety and lifetime, argv built only from the
     definition's argv with values as whole arguments (no shell).
  2. The facts gate: nothing sent for not installed / too old / unknown version / permission
     denied; the worker's calls that an unrecognised permission status lets an open go ahead,
     that -1743 from any handler maps to "permission denied", and that focus/close refuse an
     app that is not running (never launching it). Are these right for safety and for the
     product?
  3. Close only by a window id this layer's own open recorded; nothing sent otherwise; 1001
     (busy) and -1728 (missing) mapping; whether a recorded id is forgotten after a close or a
     `windowGone`, and whether ids from two definitions can collide.
  4. Compile once per loaded definition: the cache key (a user override replacing a built-in
     with the same id, or a definition reloaded with a changed script, must not run a stale
     compiled script), main-actor isolation, Swift 6 concurrency correctness.
  5. The iTerm2 adapter: every operation forwards with the same arguments and result; a plain
     handle is refused with nothing sent; the tests really compare against the coordinator
     over its fakes (not tautological).
  6. Safety: no test compiles a built-in `Resources/Terminals/*.applescript`, sends an Apple
     event, or launches Terminal, Ghostty or iTerm2; the real-spawner test runs only
     `/bin/sleep` / `/usr/bin/true` and leaves no process behind.
  7. Conventions: `///` doc comment on every type and function; closing-brace comments on
     functions or loops longer than 10 lines; English sentence-case user-facing sentences.
- **Review file:** `docs/reviews/phase-I-12b3.md`.
- **Time budget:** 20 minutes. Do not run real e2e runs, self-tests, or anything that touches
  iTerm2, Terminal or Ghostty; `swift build` / `swift test` are fine.
