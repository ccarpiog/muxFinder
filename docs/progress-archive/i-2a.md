# Phase I-2a — Directory store, session folders in discovery, recording (high)

Closed 2026-10-24 under `/autoclaude-opus`. Worker model: opus (implementation worker and
review-fix worker); the orchestrator ran the real checks and wrote the records.
Specification: `autoclaude/processed/20-new-session-directory-picker.md` (Design 1, 2, 3, 7, 8,
9); plan: `PLAN.md` "### Phase I-2", the I-2a bullet; decision **D31**.

## What was built

- **Store** — `Sources/MuxFinderCore/Config/{DirectoryLists,DirectoryStore}.swift`:
  `~/Library/Application Support/muxFinder/directories.json`, schema 1 (`saved`, `recent` per
  host id), loaded and written as D19 treats `hosts.json` (`PrivateStorage`, 0600, safe
  publication, size cap, unknown keys ignored, loading never writes). Entries pass
  `Validation.workingDirectory` and must be non-empty and at most 4,096 bytes; failures are
  dropped and counted in the notice. Caps 50 saved, 8 recent per host (newest first),
  duplicates by exact string. Operations: add, remove, reorder and replace saved; record and
  clear recents; prune recents of host ids no longer in the host list at the next write.
  After the review: every mutation refuses an unusable file (unsafe, newer schema, invalid
  JSON) with `fileNotUsable(problem)`, leaving its bytes, mode, inode and mtime unchanged; each
  write holds an exclusive `directories.lock` (2 s wait; `busy` / `lockUnavailable`) and
  re-reads under it. The lock code moved to `PrivateStorage`; `profiles.lock` (D26) calls it
  with unchanged behavior. Three backup-name and permission helpers moved from `HostStore` to
  `PrivateStorage` (`HostStore` forwards; its tests unchanged).
- **Session folders in discovery** — `Sources/MuxFinderCore/Tmux/{ProbeScript,ProbeReport,
  TmuxModels,ErrorClassifier,DiscoveryProbe}.swift`: each session line is followed, in the same
  `list-sessions` call, by a `path` record `path <nonce> <id> <session_path> <nonce>` that ends
  only at tab + the run's nonce + newline, so a path cannot end its record early or forge
  another line. The parser drops (and counts) a path that is empty, invalid UTF-8, holds a
  control character or exceeds 4,096 bytes; a report with no path records parses. After the
  review: tmux prints a path over 4,096 bytes as empty (dropped and counted, never accepted
  truncated; needs tmux ≥ 3.2), discovery's stdout cap is the largest report the parser
  accepts (about 11.8 MiB) and stderr keeps 1 MiB through a new `errorOutputLimit` in
  `Process/{ProcessRunner,ProcessSupervisor,PosixSpawnProcessRunner}.swift`. The session gains
  an optional `startDirectory` (display data only); `discover` prints it with
  `startDirectoriesDropped`, `refresh --once` too. Report format version stays 1.
- **Recording** — `Sources/MuxFinderUI/Model/{AppEnvironment,AppModel,AppModelSessions}.swift`:
  the checked directory is recorded for the host when `onCreated` fires (so an attach failure
  afterwards still records); an empty field, a collision, a failed creation or
  `mayHaveCreated` records nothing; a failed write is logged by error code only and never
  fails the creation.
- **Injection** — the app uses the real file; `--selftest` an in-memory store
  (`InMemoryDirectoryStore`, `SelfTest/SelfTestDriver.swift`); the preview fixtures and
  `--report-popover-placement` none.
- **Records** — D31 in `PLAN.md` (edits to D8, D25, Architecture, *Verified facts*),
  `CLAUDE.md` (discovery output, test-save rule), `docs/ARCHITECTURE.md`, `docs/TESTING.md`
  (*Phase I-2a*). `scripts/uninstall.sh` unchanged: it removes the whole support folder (its
  dry-run text still lists "host list, launch folder, lock file" — cosmetic).

## Acceptance

| Criterion | Met | Evidence |
|---|---|---|
| Store tests (missing, invalid JSON, unsafe, oversized, unknown keys, invalid entries dropped and counted, caps, duplicates, order, no write on load, pruning) | yes | `DirectoryStoreTests` |
| Recording rules (created, collision, failure, `mayHaveCreated`, empty, attach failure after creation, failed write) | yes | `DirectoryRecordingTests` |
| Parser folder record (spaces, Unicode, `#`, `;`, tabs/newlines/control characters, no forgery, no record) | yes | `ProbeSessionPathTests`, fixtures `{local,synthetic}-session-paths.txt` (synthetic paths only) |
| Existing tests unchanged or with recorded additions | yes | additions: fake tmux prints path records, `ReportBuilder.path(…)`, `AttachHarness.make` gained `directories` / `diagnostics`; store tests updated by the review fix (unusable files refused instead of backed up, folder listings include the lock file) |
| Real read-only discovery with folders, counts only | yes | `discover --local` 2/2 then 1/1 with a folder, 0 dropped; `discover --ssh saturno-m4` 1/1 (a `muxfinder-test-i2a-folder` session made for the check, killed after; Saturno otherwise had no server) |
| `--selftest new-session-local` with the gate | yes | 7/7 PASS twice (before and after the review fix), iTerm2 16 → 19 and 17 → 20 threads, no `directories.json` created, no test session left |
| Shared verification, bundle, codesign | yes | see *Verification* |
| D31, ARCHITECTURE, no UI change | yes | `PLAN.md` D31; `docs/ARCHITECTURE.md` |

## Review

Codex (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 0 blockers, 3 should-fix —
`docs/reviews/phase-I-2a.md`:

1. Recording replaced an unusable file → every mutation refuses it (`fileNotUsable`), file
   untouched.
2. Concurrent writers lost updates → `directories.lock` around read/modify/publish.
3. Path records could overflow the 1 MiB discovery cap → producer bound (empty past 4,096
   bytes) and a stdout cap sized for the parser's limits.

All fixed by a review-fix worker, each regression failing with its fix reverted.

## Verification (final tree, orchestrator)

- `swift build` exit 0, no warnings; `swift test` 793 core tests in 79 suites + 229 UI tests
  in 22 suites passed; `swift format lint -r Sources Tests` exit 0; `scripts/build-app.sh`
  exit 0; `codesign --verify --deep --strict build/muxFinder.app` exit 0.
- Real: `discover --local` (1 session, 1 with a folder, 0 dropped), `discover --ssh
  saturno-m4` with a test session (1/1, 0 dropped; killed, Saturno back to no server),
  `--selftest new-session-local` 7/7.

## Open risks / deviations

- Load-sensitive tests: the first `swift test` after the implementation worker reported 103
  issues in 42 s (machine load; an orphaned 2-hour-old `TestSupport.swift` fixture loop from an
  earlier iteration was found and stopped), a second failed only `boundsAFloodOfTmuxErrors`
  (the 8 MiB stderr flood hitting its 10 s timeout under load; that branch prints no path
  records); every later run passed (5/5 isolated each, several full runs).
  `discoversSessionsOnAPrivateServer` checks "no server" right after cleanup without waiting
  for the server to exit — a timing race in the test, unrelated to this phase.
- A file that changes after the store's first look still meets only the write-time checks.
- The 4,096-byte producer bound needs tmux ≥ 3.2 (only 3.8 is tested); an older tmux prints
  the path whole, and the parser still drops it.
- The remote zsh on Saturno reads a bare `=name` as equals expansion: a by-hand `ssh … tmux
  kill-session -t '=name'` must quote for the remote shell too (the app's D3 scripts already
  do).
