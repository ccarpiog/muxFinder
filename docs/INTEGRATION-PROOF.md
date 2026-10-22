# Integration proof: local attach in iTerm2

What muxFinder's attach path does against the real iTerm2 on this Mac (PLAN.md Phase 4, brief
"Choose and validate the iTerm2 integration early", steps 1–4). Everything here was observed
with `muxfinder-probe` from a shell inside iTerm2, on the default tmux server holding only
`muxfinder-test-*` sessions. No terminal contents, window titles or user command lines are
recorded; ids are shown only where their shape matters.

## Versions

| Component | Version |
|---|---|
| macOS | 27.2 (26B118), arm64, Neptuno |
| iTerm2 | 3.7.6, API protocol 1.21, default preferences for tmux integration (no `OpenTmuxWindowsIn`, `AutoHideTmuxClientSession`, `TmuxDashboardLimit` keys set) |
| tmux | 3.8, `/opt/homebrew/bin/tmux` |
| Swift | 6.4 (swiftlang-6.4.0.34.1), Xcode 27.1, debug build |

## Method

- `muxfinder-probe attach --local --session '<$id>'` and `muxfinder-probe detach --connection
  <id>` ran the real path one step at a time (six attach and detach cycles on one
  `muxfinder-test-*` session) before the end-to-end command existed.
- `muxfinder-probe e2e-local` runs the whole proof (steps in `docs/TESTING.md`). The launch
  helper's test mode was on (the `launch/test-mode` marker, created and removed through
  `LaunchStore`), so every helper iTerm2 started wrote an argv digest.

## Runs of `e2e-local`

| Run | Result | Total | Steps (ms) |
|---|---|---|---|
| 1 | exit 1: steps 1–4 PASS, 5 FAIL, cleanup FAIL | 43.2 s | 1: 32, 2: 38, 3: 1,125, 4: 0, 5: 10,318 (timed out), 9: 31,542 |
| 2, 3 | not run: iTerm2 still blocked by the warning from run 1 an hour later | — | — |

Run 1 detached about one second after the attach. That ended the launch tab and the tmux tabs
within about 1.5 s of their start, iTerm2 opened its modal short-lived-session warning (see
*Dialogs*), and from then on its API answered nothing, so step 5 and most of the cleanup timed
out. The cleanup still killed the test session by id and removed the test-mode marker; the
launch window with the warning could not be closed. Since then nothing ends a launch tab before
it is 10 s old: the attach coordinator waits that long before any `detach-client` (PLAN.md
D15), and the harness before it kills its session or closes a launch tab. The acceptance runs (two
passing runs) still have to be made once someone has answered the warning. Steps 6–8 have
therefore not run against iTerm2 yet: concurrent attaches, and what a refused launch tab does
(it should keep the explanation open and wait for Return), are so far proven only by the
hermetic tests.

## Observed behavior

### How iTerm2 runs the `Command` property

The launch tab is created with the custom profile properties `"Custom Command" = "Yes"`,
`"Command" = "<helper path> attach <launch id>"` and `"Close Sessions On End" = true`. The
helper's argv digest showed exactly three arguments: argv[0] is the helper's absolute path
(same length and SHA-256), argv[1] is `attach`, argv[2] is the launch id. So iTerm2 splits the
property into words and runs the helper directly; a plain path needs no quoting. A path with a
space was not tried, so the D2 character rule stays.

### Launch tab

- `CreateTab` without a window id opens a new window holding only the launch tab; muxFinder
  never adds tabs to the user's windows.
- `CreateTab` returns the tab's session id; it is the tmux connection's `owning_session_id`.
- In `ListSessions` the launch tab carries `tmux_window_id` `"-1"` and no
  `tmux_connection_id`, like any ordinary tab. It stays in its window while tmux is attached
  (iTerm2 does not bury it with the default preferences).
- After a clean detach the helper exits 0 and the launch tab closes by itself (`Close Sessions
  On End`), with its window: iTerm2 was back to the user's windows and tabs after each cycle.

### Where tmux windows open

With the default "open tmux windows as" preference (left unchanged), every tmux window opens
as its own new iTerm2 window with one tab. The test session's two tmux windows gave two new
windows next to the launch tab's window.

### What a tmux tab carries in `ListSessions`

- `tmux_window_id`: the tmux window id without its `@` (`"0"` and `"1"` here).
- `tmux_connection_id`: the connection id (`"tmux"` here).
- The split tree: the window split in two arrives as one splitter (`vertical = false` for
  tmux's default top and bottom split) with one session leaf per pane; the other window as a
  splitter with a single leaf.

### Connections

`ListConnections` showed the new connection about 0.4–0.5 s after `CreateTab` returned. Its
`connection_id` is a short name (`"tmux"` for the first connection), not a UUID, so the
coordinator matches connections by `owning_session_id` only. The identity check through it,
`display-message -p "#{pid}\t#{start_time}\t#{socket_path}\t#{session_id}"`, returned one line
with real tabs that matched discovery's server pid, start time, socket path and session id.

### Activation

`Activate` with a tab target and `select_session = true` is refused with `INVALID_OPTION`.
With `select_session = false`, `order_window_front`, `select_tab` and the app options
(`ignoring_other_apps`) in the same request it succeeds.

### Detach

`SendCommand detach-client` on the connection is answered (empty output). The connection is
gone from `ListConnections` by the next poll, iTerm2 closes the connection's tabs without a
dialog, `tmux -CC` exits 0 and the helper records a success result: iTerm2 treats it as a clean
detach. The session keeps its id, windows, panes and their processes. `muxfinder-probe detach`
took 0.63 s end to end.

### Dialogs

- **Short-lived session warning (blocking).** When a session ends within a few seconds of
  starting (run 1: about 1.5 s), iTerm2 shows "a session ended very soon after starting"
  (`-[PTYSession _maybeWarnAboutShortLivedSessions]`, an `iTermWarning` run modally, which can
  be silenced per profile). While it is open iTerm2's API answers nothing: WebSocket handshakes
  and requests time out, although AppleScript cookie requests still return. A sample of
  iTerm2's main thread (no window contents) showed it waiting in that warning. Only a person
  can dismiss it; muxFinder never uses UI scripting. Consequence: nothing may end a launch tab
  or detach its connection within seconds of opening it.
- No dialog appeared when attaching, when tmux windows opened, or on a detach of an attachment
  older than a few seconds.

### Timings

From the attach call (first attach of a process includes the cookie request and the API
connection):

| Step | Single attach (probe) | `e2e-local` run 1, step 3 |
|---|---|---|
| Revalidated by discovery | 37 ms | — |
| Launch tab opened (`launched`) | 1,012 ms | 621 ms |
| Connection listed | 1,441 ms | 1,056 ms |
| Identity confirmed (`confirmed`) | 1,506 ms | 1,119 ms |
| Tab activated | 1,510 ms | 1,124 ms |
