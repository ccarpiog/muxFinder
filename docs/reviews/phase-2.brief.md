# Phase 2 review brief

- Repo: `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS 14 menu bar app).
- Phase: **2 — tmux discovery: probe, parser, identity, error classification** (risk `high`).
  Spec: `PLAN.md` "### Phase 2" plus Decisions D3, D5, D11, D12 and *Unattended-run rules*.
  Conventions and safety rules: `CLAUDE.md`.
- Goal: a correct, hardened answer to "what is running on this host, or why can't we tell" —
  one static POSIX `sh` probe (local via argv, remote via D3), a strict versioned line-based
  report parser, `HostStatus` classification of ssh/probe failures, and
  `muxfinder-probe discover --local | --ssh <dest> [--tmux-path <p>]` with JSON output.

## Changed files (uncommitted working tree)

- New: `Sources/MuxFinderCore/Tmux/` (`TmuxLocator`, `ProbeScript`, `ProbeReport`,
  `ErrorClassifier`, `HostStatus`, `TmuxModels`, `DiscoveryProbe`),
  `Sources/MuxFinderCore/Config/HostConfig.swift`, `Sources/muxfinder-probe/DiscoverCommand.swift`,
  `Tests/MuxFinderCoreTests/{DiscoveryEndToEndTests,DiscoveryProbeTests,DiscoveryTestSupport,
  ErrorClassifierTests,ProbeReportParserTests,ProbeScriptTests}.swift`,
  `Tests/MuxFinderCoreTests/Fixtures/discovery/*.txt`, `docs/TESTING.md`.
- Modified: `Package.swift` (test resources), `Sources/muxfinder-probe/main.swift`,
  `Tests/MuxFinderCoreTests/TestSupport.swift`, `PLAN.md` (D3/D5/D11 edits, new D12 `tmux -u`,
  verified facts), `CLAUDE.md` (discover command line). `PROGRESS.json` is a workflow record —
  ignore it.

## Verification already run (orchestrator)

- `swift build -Xswiftc -warnings-as-errors` → exit 0.
- `swift test` → exit 0, 97 tests in 11 suites.
- `swift format lint -r Sources Tests` → exit 0, no output.
- Real checks recorded by the worker in `docs/TESTING.md` (local no-server via private
  `TMUX_TMPDIR`, local and Saturno test sessions, `.invalid`, `192.0.2.1`, auth failure,
  host-key harness). Do NOT re-run SSH or touch the user's tmux server; hermetic checks only.

## Risks to focus on

1. **Injection / parsing integrity**: can any session name (tabs, newlines, `#{...}`, control
   chars, the per-run record token, very long names) forge a record, shift fields, or cause
   execution in the probe script or in the parser? Is the probe script truly static, with the
   tmux override passed only as a positional argument (local argv; remote via
   `ShellQuoting.remoteCommand`)?
2. **Parser strictness**: ids `^\$[0-9]+$`, strict integers, >1,000 sessions or lines > 4 KiB →
   `probeError`, missing header/terminator/unknown version → `probeError`, never a crash
   (force unwraps, integer overflow, index out of range).
3. **Classifier correctness**: ssh exit 255 + stderr patterns; "REMOTE HOST IDENTIFICATION HAS
   CHANGED" beating "Host key verification failed"; `noServer` for "no server running" and
   "error connecting to … (No such file or directory)"; runner timeout → `unreachable(.timeout)`;
   misclassification when a remote command exits 255 for non-ssh reasons, or when the probe
   report is present but ssh also printed warnings.
4. **Locator / D5 semantics**: override used alone with no fallback; candidate search order on
   noninteractive SSH PATH; `-V` check; behavior when the override path is not tmux.
5. **Environment**: local runs must strip `TMUX` / `TMUX_PANE`; `tmux -u` (D12) applied to every
   tmux call in the probe; locale assumptions.
6. **Safety/conventions**: no user data in fixtures/logs/docs; `///` doc on every
   function/type; closing-brace comments on >10-line functions/loops; tests hermetic (the
   end-to-end test uses a private socket under `/tmp` — confirm it can never hit the user's
   default server and always cleans up).

## Output

- Review file: `docs/reviews/phase-2.md` (overwrite it).
- Time budget: 15 minutes.
