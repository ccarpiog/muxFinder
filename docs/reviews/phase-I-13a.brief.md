# Review brief — Phase I-13a (update check, the check core)

- **Repository:** /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM, macOS 14). The
  change is **uncommitted** in the working tree; review the working tree against `HEAD`.
- **Phase and goal:** I-13a — the update check's core for a hand-written GitHub-release
  updater: tag/version parsing, the bounded parser of `GET
  /repos/ccarpiog/muxFinder/releases/latest`, the transport protocol and its `URLSession`
  implementation, the 304 rule, the `update-state.json` store, the
  `checkForUpdatesAutomatically` toggle in `preferences.json`, the scheduler over an injected
  clock, and probe `muxfinder-probe update check`. No download, install or UI (I-13b, I-13c).
- **Binding requirements:** `PLAN.md` *Phase I-13* ("The run rule" and "The orchestrator's
  calls for I-13a"), *Unattended-run rules* 3 (no request to any server in a run), D39 (new,
  written by this phase), the specification `autoclaude/processed/120-update-check-github.md`
  (*Check* and *Testing and safety*), and `CLAUDE.md` conventions.
- **Changed files:** new `Sources/MuxFinderCore/Update/` (UpdateVersion, UpdateRelease,
  UpdateTransport, UpdateCheck, UpdateState, UpdateStateStore, UpdateScheduler, UpdateProbe),
  `Sources/muxfinder-probe/UpdateCommand.swift`, `Tests/MuxFinderCoreTests/Update*.swift`
  (9 files); modified `Sources/MuxFinderCore/Config/PreferencesStore.swift`,
  `Sources/muxfinder-probe/main.swift`, `PLAN.md` (Phase I-13 section, rule 3, D39, D8/D32
  lines), `CLAUDE.md`, `docs/TESTING.md`, `docs/MANUAL-CHECKLIST.md`. `PROGRESS.json` is a
  workflow record, not a deliverable.
- **Verification run (orchestrator):** `swift build` exit 0; `swift format lint -r Sources
  Tests` exit 0; `swift test` (TMUX_TMPDIR unset) 1259 core tests in 137 suites + 548 UI in
  55 suites passed; `swift run muxfinder-probe update check --help` exit 0, contacts nothing.
  No real request was made to GitHub; the real `~/Library/Application Support/muxFinder/`
  has no `update-state.json`.
- **Risks to look at hardest:**
  1. Parser strictness on untrusted JSON: tag format (leading zeros, sizes), `html_url` and
     `browser_download_url` exact-match rules, digest normalization, size bounds, duplicate
     assets, draft/prerelease; that "newer" can never come from an equal, older or malformed
     tag; and that the 1 MiB body cap really bounds memory in the `URLSession` path.
  2. The `URLSession` transport: ephemeral, no cookies/cache/credentials, headers (including
     the worker's extra constant `Accept-Language: en`), `If-None-Match`, https only, redirect
     refusal away from `api.github.com`, rate-limit parsing (`x-ratelimit-remaining: 0` +
     `x-ratelimit-reset`, `retry-after`), timeouts.
  3. The scheduler's timing and concurrency: 5 s first check, 24 h since success, ≥1 h after
     an attempt, rate-limit date (capped at 24 h ahead by the worker), clock moved back,
     toggle off sends nothing automatically, manual check joins in-flight and sends during
     toggle off, at most one request in flight, no tight retry loop, cancellation/stop.
  4. The 304 rule (kept release, ETag dropped when nothing is kept) and "newer" recomputed
     against the running version on every use.
  5. The state store and the `PreferencesStore` change: atomic write, symlink and
     non-regular refusal (never writing through), invalid → never checked, the new key's
     default and that existing `preferences.json` files and keys keep loading and saving as
     before.
  6. Tests hermetic: no real network request anywhere in `swift test` (only a `URLProtocol`
     stub or an injected transport), store tests only on private folders.
  7. Docs: D39 and `CLAUDE.md`'s new lines match the code; nothing relaxed in the safety
     rules.
- **Review file:** `docs/reviews/phase-I-13a.md` (verdict `ship`, `ship-with-fixes` or
  `do-not-ship`; BLOCKERS and SHOULD-FIX with file:line).
- **Time budget:** 15 minutes. Do not make network requests; do not run real e2e commands or
  self-tests; do not modify the tree.
