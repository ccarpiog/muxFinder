# Open risks and deviations, Phases 13–I-2a

Moved verbatim from `PROGRESS.md` *Open risks / deviations* on 2026-10-24 (Phase I-3a's
checkpoint), to keep the live head under its size budget.

- **13: iTerm2's auto-hide setting** ("Automatically bury the tmux client session after
  connecting", read only, never written) was on for 13a's spike and at its default (off) for
  13c's runs (iTerm2 exited between 12:15 and 12:24 on 2026-10-24, not the run's doing, and
  came back without the key). So the default branch is proven for real; the "on" branch only by
  the 13a spike's old harness, never by the 13c harness.
- 13a: "Return works" after an abnormal end is inferred from an answered DSR, never typed (no
  synthesized keystrokes); it is in `docs/MANUAL-CHECKLIST.md` item 14. A SIGHUP or SIGKILL of
  the helper in the middle of its exchange cannot restore raw mode (the tab ends with it).
  iTerm2 sources (`v3.7.6`) were downloaded to `/tmp/mfx-iterm2-src` for reading only.
- 13b/13c: the refresh engine's attachment checks do not feed recovery (only the coordinator's
  own listings do). The race's dangerous order (bury landing after the helper's restore) was
  not forced for real — on both hosts the bury landed first; forcing it needs a seam inside
  `ITerm2APIClient.buryLaunchTab`; 13b's unit tests cover the order. Step 7's retry path ran
  only in unit tests. `CreatedSessionTests.killsOnlyTheRecordedSessionOnAPrivateServer` (6a)
  failed once with `scripts/build-app.sh` running in parallel, then passed alone and 3/3
  isolated — another load-sensitive private-server test. `CLAUDE.md` / `docs/TESTING.md` say
  about 123 s for `e2e-remote` (13c: 120.4 s). The user's own muxFinder.app had attachments
  open during 13c's runs; every check left them out — `docs/progress-archive/13c.md`.
- 14: the real popover is unseen (needs a click): opaque corners in the menu bar window,
  badge, muted Sirio, footer — `docs/MANUAL-CHECKLIST.md` item 15. The unknown-location mark
  shows briefly on each popover open until the first attachment check ends; a working check
  with unmatched connections (5a `nonUTF8`) can still read "elsewhere" —
  `docs/progress-archive/14.md`.
- I-1a: the pre-fix popover frame is unmeasured and the cause (SwiftUI anchoring at a replica
  status-bar window's placeholder frame at the second display's right edge) inferred; where the
  system draws the icon vs window 0's x 1413 was not checked; the lock state disagreed between
  the worker's runs (unlocked) and the orchestrator's (locked); the watchdog has no unit test —
  `docs/progress-archive/i-1a.md`.
- I-1b: keys, focus, Edit-menu equivalents, the real closing paths, the other display's icon,
  ⌘-drag, a full-screen Space and content resizing are unverified for real (checklist 16);
  whether the system draws the icon at AppKit's button rect (screen 1's right edge when screen
  1 is main) is unchecked; the hardware press count inside the app is unverified (falls back to
  the old time/distance rule) — `docs/progress-archive/i-1b.md`.
- I-2a: the private-server tests `boundsAFloodOfTmuxErrors` and
  `discoversSessionsOnAPrivateServer` are load-sensitive (one run of 103 issues under machine
  load, one single failure, then every run passed; the second races the tmux server's exit).
  An orphaned `TestSupport.swift` fixture loop from an earlier iteration was found and stopped
  — another test can leave one behind. The 4,096-byte producer bound needs tmux ≥ 3.2; a file
  changed after the store's first look meets only the write-time checks; the uninstall
  dry-run text does not name `directories.json` (it removes the whole folder) —
  `docs/progress-archive/i-2a.md`.
