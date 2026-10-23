# Phase 11b review brief — real persistent-profile runs

- Repo: `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6 SwiftPM macOS menu bar app; conventions
  in `CLAUDE.md`; design in `PLAN.md`, decision D26 for persistent profiles).
- Phase: 11b, risk high. Goal: run `muxfinder-probe e2e-profile --local` and `--ssh saturno-m4` for
  real against iTerm2 3.7.6, fix what the runs call for, record them, resolve D26's items owed to 11b.
- Review the **uncommitted** working tree against `HEAD` (`git diff`).

## What happened

The first two real local runs failed at step 8: while `DynamicProfiles/muxFinder.json` was
installed, iTerm2's `New Bookmarks` (from `defaults export com.googlecode.iterm2 -`) gained one entry,
iTerm2's own mirror of the loaded dynamic profile (GUID `muxfinder-persistent-…`, a `Dynamic Profile
Filename` key); the user's 13 entries were byte-identical, and the mirror vanished after removal. The
fix leaves exactly muxFinder's mirrored entries out of the `New Bookmarks` hash (counted in
`excludedMuxFinderEntries`) and makes step 13 wait, bounded at 30 s, for iTerm2 to drop the mirror
before requiring identical hashes. After the fix both real runs passed 14/14.

## Changed files

- `Sources/MuxFinderCore/Profiles/ITerm2ProfileSnapshot.swift` — exclusion rule
  `isMuxFinderMirror(_:)`, fingerprint `excludedMuxFinderEntries`, `hashesMatch`, `differences(from:)`.
- `Sources/MuxFinderCore/Profiles/PersistentProfileRun.swift` — step 8 filtered comparison and note;
  step 13 bounded, cancellable wait for the mirror to go; step 1 note for a stale mirror.
- `Sources/muxfinder-probe/{ProfilesCommand,E2EProfileCommand}.swift` — JSON field, wiring.
- `Tests/MuxFinderCoreTests/{ITerm2ProfileSnapshotTests,PersistentProfileRunTests}.swift`.
- `PLAN.md` (D26, *Verified facts*, Phase 11 acceptance note), `docs/TESTING.md` (11b record),
  `CLAUDE.md` (one sentence on `profiles hashes`).

## Verification run (orchestrator)

`swift build -Xswiftc -warnings-as-errors` exit 0; `swift test` exit 0 (662 core tests in 66 suites +
139 UI tests in 11 suites); `swift format lint -r Sources Tests` exit 0; real `e2e-profile --local`
exit 0 (14/14, 11.1 s) and `e2e-profile --ssh saturno-m4` exit 0 (14/14, 16.1 s); independent
`profiles hashes` before and after identical; no leftovers. Do NOT run any real e2e, probe command
that contacts iTerm2, ssh, or tmux yourself — hermetic checks only (`swift build`, `swift test`, reading).

## Risks to probe

- Could the exclusion rule hide a real change to the user's profiles (an entry the user owns that
  matches both conditions; a mirror whose content is not what muxFinder wrote; several mirrors)?
- Does a mirror that never disappears, or that reappears, fail cleanly and leave nothing behind?
- Is the wait in step 13 bounded and cancellable on every path, and does SIGTERM/cleanup still work?
- Are `==` vs `hashesMatch` used consistently (no place comparing the excluded count by accident, or
  ignoring a real difference)?
- Do the docs state truthfully what was verified for real vs still unverified?

## Output

Review file: `docs/reviews/phase-11b.md`. Time budget: 10 minutes.
