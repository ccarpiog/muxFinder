# Open risks and deviations, Phases I-2b to I-9a (moved verbatim from `PROGRESS.md`, 2026-11-06)

- I-2b: the list highlight drops on a field edit, not on a click back into the field.
  `NewSessionDraft.directory`'s observer still compares with `String ==`. Real keys in the
  non-activating panel and creating from each source are unverified (checklist 17). The full
  `swift test` fails in private-tmux-server suites under extreme machine load (~500, another
  project's simulator run). Install-script step 35 can fail while the user's installed app
  writes its `launch/` folder — `docs/progress-archive/i-2b.md`.
- I-3a: no key was pressed, so whether a real press fires the Carbon handler (dispatcher
  target, registration on the application target) and whether macOS 27.2 delivers ⌥-only
  shortcuts are checklist 18's. The flag briefly registers the plain-letter ⌥J and ⌥⇧J
  system-wide. Leaving the General tab mid-recording is tested in the model only. The
  uninstall dry-run text does not name `preferences.json` — `docs/progress-archive/i-3a.md`.
- I-3b: no press and no real panel (checklist 18). A press on another display's copy of the
  status item, when its outside close comes first, still sends a closed/opened pair. A creation
  failure that comes during an unconfirmed Move here closes that confirmation when the switcher
  opens. "Detach from this Mac" on a pinned row whose host is gone does nothing. Beyond the spec:
  a key-hint footer — `docs/progress-archive/i-3b.md`.
- I-4: **`CLAUDE.md` note owed** — once the user has committed their own `CLAUDE.md` edit, its
  `--report-menu-bar-item` note should say the check also prints every other window, the
  launch event and the main menu, and that only onboarding may be visible (exact wording in
  `docs/progress-archive/i-4.md`). Real Finder/login launches and the Edit shortcuts in the real
  panels are checklist 19. A closed stdout still raises `SIGPIPE` in the shell check (as
  before; not ignored, since children would inherit it). One worker run named a nonexistent
  `CFFIXED_USER_HOME`; nothing real was read or written — `docs/progress-archive/i-4.md`.
- I-5: a real double click (long and short lists, a session already open here) is checklist
  18's. A ⌘-Tab right after an activating click leaves the switcher up for the rest of the
  double-click interval. The popover's panel carries the unused `minimumContentHeight` —
  `docs/progress-archive/i-5.md`.
- I-6: real Tab presses are checklist 20's. **Second `CLAUDE.md` note owed**: its
  `--preview-fixtures` paragraph should say `--preview-key-view-loop popover|switcher` shows a
  real panel and makes it key for ~10 s (exits 0/1/2/3) — wording in
  `docs/progress-archive/i-6.md`. The stalled-pipe case of the review fix was not run.
- I-7: a button-opened list with text in the field shows only the matches (the spec's pure
  rule). "Sessions on <host>" is capped at 10 before filtering. VoiceOver says nothing on a host
  change and was never on in a check; real typing, keys and VoiceOver are checklist 21's —
  `docs/progress-archive/i-7.md`.
- I-8: what ↑/↓ and ⌥↓ do on a closed picker, whether the menu's tracking notifications fire
  for it in the non-activating panel, and VO-Space are unverified until a real press
  (checklist 22). Tests pick a host through the picker's binding, not the real menu (SwiftUI
  builds no pop-up button in a never-shown panel) — `docs/progress-archive/i-8.md`.
- I-9a: no real window shown, moved, typed into or dragged (floating, Spaces, full screen, key
  without activation, ⌘W, height growth: I-9b's checklist item). ⌘R/⌘F in the window beep;
  ⌘N is swallowed. The committed attach and switcher screenshots show the inline form until
  I-9b. One first `swift test` run had 1 core-suite issue (core untouched), not reproduced in
  three reruns. A **third `CLAUDE.md` note owed**: the `--preview-fixtures` paragraph should
  add `--preview-gallery new-session` (every New session window state) to its gallery list
  and `new-session-states-*.png` to its screenshot list (made concrete by I-9b) —
  `docs/progress-archive/i-9a.md`, `i-9b.md`.
