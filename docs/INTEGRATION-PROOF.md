# Integration proof: attach in iTerm2, on this Mac and over SSH

What muxFinder's attach path does against the real iTerm2 on this Mac (PLAN.md Phase 4, brief
"Choose and validate the iTerm2 integration early", steps 1–4, and Phase 5a: focusing an
existing attachment instead of opening another, and detaching a session by its key), and over
SSH to Saturno (Phase 5b, brief step 5: *Over SSH* below). Everything here was observed with
`muxfinder-probe` from a shell inside iTerm2, on default tmux servers holding only
`muxfinder-test-*` sessions. No terminal contents, window titles or user command lines are
recorded; ids are shown only where their shape matters.

## Versions

| Component | Version |
|---|---|
| macOS | 27.2 (26B118), arm64, Neptuno |
| iTerm2 | 3.7.6, API protocol 1.21, default preferences for tmux integration (no `OpenTmuxWindowsIn`, `AutoHideTmuxClientSession`, `TmuxDashboardLimit` keys set); short-lived-session warning threshold 3 s (the `shortLivedSessionDuration` default, not overridden) |
| tmux | 3.8, `/opt/homebrew/bin/tmux` |
| Swift | 6.4 (swiftlang-6.4.0.34.1), Xcode 27.1, debug build |

## Method

- `muxfinder-probe attach --local --session '<$id>'` and `muxfinder-probe detach --connection
  <id>` ran the real path one step at a time (six attach and detach cycles on one
  `muxfinder-test-*` session) before the end-to-end command existed (Phase 4b, before the
  existing-attachment check).
- `muxfinder-probe e2e-local` runs the whole proof (steps in `docs/TESTING.md`), built with
  `swift build` first and run with `env -u TMUX_TMPDIR swift run muxfinder-probe e2e-local`.
  The launch helper's test mode was on (the `launch/test-mode` marker, created and removed
  through `LaunchStore`), so every helper iTerm2 started wrote an argv digest.
- Before and after every run: `muxfinder-probe iterm2 status` connected, `tmux -u ls` reported
  no server, the launch directory was empty (no marker), iTerm2 listed no tmux connection, and
  the user's 3 windows and 3 tabs, none of them touched.
- Since Phase 5a the run's attachment index asks only connections owned by launch tabs the run
  opened (PLAN.md D16); no other connection existed during the 5a runs anyway (setup reported
  0).

## Runs of `e2e-local`

| Run | Result | Total | Steps (ms) |
|---|---|---|---|
| Phase 4b, run 1 | exit 1: steps 1–4 PASS, 5 FAIL, cleanup FAIL | 43.2 s | 1: 32, 2: 38, 3: 1,125, 4: 0, 5: 10,318 (timed out), 9: 31,542 |
| Phase 4c, run 1 | **exit 0: 9 of 9 PASS** | 42.2 s | 1: 34, 2: 38, 3: 538, 4: 1, 5: 10,009, 6: 10,485, 7: 10,440, 8: 10,518, 9: 30 |
| Phase 4c, run 2 | **exit 0: 9 of 9 PASS** | 42.7 s | 1: 34, 2: 38, 3: 528, 4: 1, 5: 10,295, 6: 10,356, 7: 10,934, 8: 10,332, 9: 26 |
| Phase 5a, run 1 | **exit 0: 10 of 10 PASS** | 42.9 s | 1: 30, 2: 37, 3: 631, 4: 0, 5: 131, 6: 9,850, 7: 10,619, 8: 10,839, 9: 10,545, 10: 28 |
| Phase 5a, run 2 | **exit 0: 10 of 10 PASS** | 43.3 s | 1: 35, 2: 38, 3: 584, 4: 7, 5: 107, 6: 10,008, 7: 10,653, 8: 10,872, 9: 10,785, 10: 30 |
| Phase 5a, run 3 | **exit 0: 10 of 10 PASS** | 42.2 s | 1: 32, 2: 42, 3: 603, 4: 0, 5: 88, 6: 9,839, 7: 10,503, 8: 10,453, 9: 10,454, 10: 27 |

The 4b run detached about one second after the attach, so the launch tab and the tmux tabs
ended within about 1.5 s of their start; iTerm2 opened its modal short-lived-session warning
(see *Dialogs*) and its API answered nothing until a person dismissed it. Since then nothing
ends a launch tab before it is 10 s old, which is why the detach and stale steps each take
about 10 s. The 4c runs had 9 steps: no focus step, and their step 5 detached by connection.
Phase 5a's run 3 is on the final tree, after the review fixes (the length-prefixed identity
command, activation bound to the connection's owner, an unknown tab's age counted from its
observation); runs 1 and 2 used the tab-separated identity command and unbound activation.

What the Phase 5a runs printed (the same in each, apart from timings, ids and pids):

1. **create session:** `$0` with 2 windows, 3 panes running `sleep 600`.
2. **discover:** `$0` found with its name and 2 windows, the only session on the server;
   discovery used `/opt/homebrew/bin/tmux` (37–38 ms). Its server pid, start time, socket
   path, id, creation time and name all equal what `new-session -P` printed, so the socket path
   discovery reports is the one `new-session` reports (`/private/tmp/tmux-501/default`).
3. **attach:** the existing-attachment check found nothing; confirmed on connection `tmux`,
   states `requested → launched → confirmed`, the first tmux tab activated; the argv digest
   note (see below).
4. **tabs and split:** 2 tabs carry connection `tmux` (tmux windows `0` and `1`); one holds a
   two-pane split, the other one pane; placement notes (see below).
5. **focus existing:** a second attach of `$0` focused connection `tmux` (`requested →
   focused`) and activated its first tab; nothing opened: the run's 3 windows and 3 tabs, every
   other window and tab, and the 1 connection unchanged, no launch tab, no argv digest; the
   check counted 1 mapped connection, 0 unknown, 0 ambiguous, 0 stale (run 3 also 0 nonUTF8).
6. **detach by session:** `detach(session:on:)` found that 1 attachment, checked its identity
   again and sent `detach-client` bound to the launch tab; connection `tmux` closed cleanly,
   its tabs closed; `$0` survived with 2 windows and 3 live `sleep` panes; the helper exited
   0, the launch tab closed by itself.
7. **reattach:** the same checks as steps 3 and 4 on a new launch tab and connection, then a
   detach by connection with the same checks as step 6.
8. **concurrent attaches:** both callers got the same confirmed launch: 1 launch tab, 1 new
   connection, 2 tmux tabs; then the same detach checks.
9. **stale guard:** revalidation refused the stale target without a tab; the guard refused the
   stale request (`sessionChanged`), no connection or tmux client appeared; the refused tab
   stayed open until the test closed it.
10. **cleanup:** killed `$0`, removed the test-mode marker; no test session, launch tab, tmux
    tab, connection or marker left.

## Observed behavior

### How iTerm2 runs the `Command` property

The launch tab is created with the custom profile properties `"Custom Command" = "Yes"`,
`"Command" = "<helper path> attach <launch id>"` and `"Close Sessions On End" = true`. In every
launch (4 per run) the helper's argv digest showed exactly three arguments: argv[0] is the
helper's absolute path (same length and SHA-256), argv[1] is `attach`, argv[2] is the launch
id. So iTerm2 splits the property into words and runs the helper directly; a plain path needs
no quoting. A path with a space was not tried, so the D2 character rule stays.

### Launch tab

- `CreateTab` without a window id opens a new window holding only the launch tab; muxFinder
  never adds tabs to the user's windows.
- `CreateTab` returns the tab's session id; it is the tmux connection's `owning_session_id`.
  iTerm2 answers it after the helper has started: in step 8 the guard's refusal was already in
  the result file at the coordinator's first poll (139 ms after the attach call in both runs,
  the same moment the tab was reported open).
- In `ListSessions` the launch tab carries `tmux_window_id` `"-1"` and no
  `tmux_connection_id`, like any ordinary tab, in a window with that one tab. It stays in its
  window while tmux is attached (iTerm2 does not bury it with the default preferences).
- **Whether it closes when the helper exits:** yes. After a clean detach the helper exits 0
  and the launch tab closes by itself (`Close Sessions On End`), with its window; iTerm2 was
  back to the user's windows and tabs after each cycle.
- A refused launch (step 8) does not end: the helper prints its explanation and waits for
  Return, and the tab stayed open until the test closed it with `Close` (forced) by the session
  id `CreateTab` reported, 10.2 s and 10.1 s after it opened. The close showed no dialog.

### Where tmux windows open

With the default "open tmux windows as" preference (left unchanged), every tmux window opens
as its own new iTerm2 window with one tab. The test session's two tmux windows gave two new
windows next to the launch tab's window, in every attach.

### What a tmux tab carries in `ListSessions`

- `tmux_window_id`: the tmux window id without its `@` (`"0"` and `"1"`).
- `tmux_connection_id`: the connection id (`"tmux"`).
- The split tree: the window split in two arrives as one splitter (`vertical = false` for
  tmux's default top and bottom split) with one session leaf per pane; the other window as a
  splitter (`vertical = true`) with a single leaf.

### Connections

`ListConnections` showed the new connection about 350–390 ms after `CreateTab` returned. Its
`connection_id` is a short name, not a UUID: every connection in both runs (steps 3, 6 and 7,
one at a time) was named `"tmux"`, since iTerm2 hands the name out again once the previous
connection closed. That is why the coordinator matches connections only by
`owning_session_id`, and sends `detach-client` only while the connection is still listed as
owned by its launch tab. The identity check through it returned one line that matched
discovery: `#{host}` equal to `uname -n` (`Neptuno-M4.local`), and the server pid, start time,
socket path and session id. Phase 5a's run 3 used the length-prefixed command
(`#{client_utf8}:#{n:host}:#{host}:…`, PLAN.md D16), whose UTF-8 flag was `1` (the helper's
`-u` client); the earlier runs used the tab-separated one (4b and 4c without `#{host}`), which
came back with real tabs.

### Focus existing

With the session attached (step 5 of the 5a runs), a second attach revalidated it, asked the
one connection through the binding rule which session it shows (1–2 ms after discovery), found
it mapped to the session, and activated that connection's first tmux tab with the usual
`Activate` (tab target, `select_tab`, `order_window_front`, app options); in run 3 that went
through the binding rule (`ListConnections`, `ListSessions` and `Activate` on one API
connection, the owner unchanged). It wrote no request,
sent no `CreateTab` and opened nothing: before and after, iTerm2 listed the same window and tab
ids (the run's 3 windows and 3 tabs and the user's), the same single connection, and no helper
started (no argv digest). The focused attach ended about 40–50 ms after the call (discovery
39–48 ms of it).

### Detach by session

`detach(session:on:)` (step 6 of the 5a runs) found the session's one attachment through the
index, waited until its launch tab was 10 s old (counted from when the coordinator opened it),
asked the connection again which session it shows, and sent `detach-client` bound to the
launch tab. The connection closed, the helper exited 0 and the launch tab closed by itself, as
with a detach by connection.

### Activation

`Activate` with a tab target and `select_session = true` is refused with `INVALID_OPTION`.
With `select_session = false`, `order_window_front`, `select_tab` and the app options
(`ignoring_other_apps`) in the same request it succeeds (every attach in both runs).

### Detach

`SendCommand detach-client` on the connection is answered (empty output). The connection is
gone from `ListConnections` by the next poll, iTerm2 closes the connection's tabs without a
dialog, `tmux -CC` exits 0 and the helper records a success result: iTerm2 treats it as a clean
detach. The session keeps its id, windows, panes and their processes. The coordinator sends it
only once the launch tab is 10 s old; when the connection had closed and the helper's result
had arrived, the launch tabs were 10.4, 10.2 and 10.2 s old (4c run 1, steps 5–7), 10.6, 10.1
and 10.7 s old (4c run 2), 10.4, 10.3 and 10.5 s old (5a run 1, steps 6–8) and 10.5, 10.4 and
10.6 s old (5a run 2).

### Concurrent attaches

Two attaches of the same session started together share one launch (single flight): one
request file, one launch tab, one argv digest, one new connection with its two tmux tabs, and
the same confirmed result for both callers. No second tab opened, so nothing had to end one.

### Dialogs

- **Short-lived session warning (blocking).** When a session ends within 3 s of starting
  (iTerm2's `shortLivedSessionDuration` default; the 4b run ended one after about 1.5 s),
  iTerm2 shows "a session ended very soon after starting" (`-[PTYSession
  _maybeWarnAboutShortLivedSessions]`, an `iTermWarning` run modally, which can be silenced per
  profile; it is not silenced for the default profile here). While it is open iTerm2's API
  answers nothing: WebSocket handshakes and requests time out, although AppleScript cookie
  requests still return. Only a person can dismiss it; muxFinder never uses UI scripting. So
  nothing ends a launch tab before it is 10 s old: the coordinator waits before every
  `detach-client`, the helper never exits younger while its tab is visible (even if tmux ends
  right after attaching, Return is pressed at once or Ctrl-C is typed; only closing the tab
  ends it early), and `e2e-local` waits before it kills
  its session or closes a tab. Every launch tab in the passing runs ended at 10.1–10.7 s.
- No other dialog appeared: not when attaching, when tmux windows opened, on a focus, on a
  detach, nor on the forced close of the refused launch tab. iTerm2's API answered every
  request in every passing run, and `iterm2 status` connected after each.

### Timings

From the attach call (the first attach of a process includes the cookie request and the API
connection; in `e2e-local` that happened during setup, so the first attach and the reattach
are alike). Phase 4c:

| Step | Single attach (probe, 4b) | 4c run 1, step 3 | 4c run 1, step 6 | 4c run 2, step 3 | 4c run 2, step 6 |
|---|---|---|---|---|---|
| Revalidated by discovery | 37 ms | — | — | — | — |
| Launch tab opened (`launched`) | 1,012 ms | 142 ms | 142 ms | 136 ms | 150 ms |
| Connection listed | 1,441 ms | 490 ms | 509 ms | 502 ms | 542 ms |
| Identity confirmed (`confirmed`) | 1,506 ms | 533 ms | 533 ms | 524 ms | 574 ms |
| Tab activated | 1,510 ms | 537 ms | 536 ms | 528 ms | 577 ms |

Phase 5a, with the existing-attachment check before the launch (from the attach call; run 1
printed only the check's time, which comes right after revalidation):

| Step | Run 1, step 3 | Run 1, step 7 | Run 2, step 3 | Run 2, step 7 | Run 2, focus (step 5) |
|---|---|---|---|---|---|
| Revalidated by discovery | — | — | 38 ms | 46 ms | 47 ms |
| Existing attachments checked | 37 ms | 44 ms | 38 ms | 46 ms | 48 ms |
| Launch tab opened (`launched`) | 148 ms | 142 ms | 157 ms | 145 ms | — |
| Connection listed | 551 ms | 533 ms | 164 ms | 499 ms | — |
| Identity confirmed (`confirmed`) | 623 ms | 613 ms | 207 ms | 605 ms | — |
| Tab activated | 630 ms | 625 ms | 583 ms | 614 ms | 50 ms |

In run 2's step 3 the connection was listed 7 ms after the launch tab and activation waited
for the first tmux tab instead. Run 1's focus ended 51 ms after the call.

Other timings from the passing runs: discovery 37–38 ms; a stale launch refused by the
helper's guard and reported to the coordinator 139–156 ms after the attach call; cleanup
26–30 ms (no launch tab was younger than 10 s by then, so it did not wait).

## Over SSH (Phase 5b)

`muxfinder-probe e2e-remote saturno-m4` runs the same kind of proof against Saturno's default
tmux server (steps in `docs/TESTING.md`). Its launch tabs run
`/usr/bin/ssh -t -o ConnectTimeout=10 -- saturno-m4 <D3 string>` (PLAN.md D17): interactive,
key authentication through the user's agent, the remote script checking the session's identity
and then `exec`ing `tmux -u -CC attach-session`. Saturno: tmux 3.8 at `/opt/homebrew/bin/tmux`,
`uname -n` `Saturno-M4.local`, reached over Tailscale.

### The `still waiting` step

The step proves that a remote attach whose launch tab stays open with no connection past its
20 s budget reports `stillWaiting`, never a success, and fails once the tab closes. It now
attaches the test session through `saturno-m4` itself, with requests asking for the helper's
60 s test launch delay (PLAN.md D14 *Test launch delay*), honored because the run turns the
helper's test mode on: the helper prints one line and waits before it would start ssh, so the
tab shows no password prompt and nothing logs in. After `stillWaiting` the test closes that tab
(forced, once 10 s old) and the helper ends `interrupted` without having started ssh. This
design has not had a real run yet: iTerm2's API stalled during run 3 below, and real runs wait
for a person to restart iTerm2.

All three runs below used the step's original design: an attach through
`nonexistent-muxfinder@saturno-m4`, so ssh waited at a password prompt for a user that does
not exist. The Phase 5b review replaced it, because it was a real authentication attempt on
Saturno outside the run rules (only discovery and `muxfinder-test-*` sessions).

### Runs of `e2e-remote`

| Run | Result | Total | Steps (ms) |
|---|---|---|---|
| 1 | **exit 0: 11 of 11 PASS** | 75.9 s | 1: 3,464, 2: 716, 3: 2,194, 4: 5, 5: 10,608, 6: 2,899, 7: 1,480, 8: 9,075, 9: 14,139, 10: 28,351, 11: 2,098 |
| 2 | **exit 0: 11 of 11 PASS** | 76.3 s | 1: 3,585, 2: 758, 3: 2,288, 4: 30, 5: 10,302, 6: 3,046, 7: 1,560, 8: 8,809, 9: 14,324, 10: 28,500, 11: 2,171 |
| 3 | exit 1: 1–9 PASS, 10 and 11 FAIL | 92.2 s | 1: 3,607, 2: 763, 3: 2,256, 4: 7, 5: 10,760, 6: 3,052, 7: 1,578, 8: 8,890, 9: 14,280, 10: 11,597 (iTerm2's API stopped answering), 11: 34,450 |

Run 3 was on the final tree (the closed-tab result wait raised to 10 s after run 2). Its step
10 failed because iTerm2's API stopped answering right after that step's launch tab opened,
not because of the remote path: the helper and its ssh were running as in runs 1 and 2, ssh at
its password prompt. iTerm2's main thread was idle (no modal), and 64 GCD worker threads, the
pool's limit, were each blocked in AppKit's `-[NSAnimation _runBlocking]` (*Verified facts*,
Phase 5b). Cleanup killed the session and removed the marker, but could not close that launch
tab; it waits for a person, as does restarting iTerm2.

What the passing runs printed (the same in both, apart from timings, ids and pids):

1. **create session** (over ssh, about 3.5 s for five tmux calls): `$0` with 2 windows and 3
   panes running `sleep 600`.
2. **discover** (over ssh, 0.72–0.76 s): `$0` with its name and 2 windows, the only session; the
   remote `uname -n` `Saturno-M4.local`, which the index matches connections by.
3. **attach:** the launch tab ran ssh to Saturno; confirmed on connection `tmux` (`requested →
   launched → confirmed`, within the 20 s budget, so no `stillWaiting`), the first tmux tab
   activated; the helper's argv digest showed 3 arguments as locally.
4. **tabs and split:** 2 tabs carry connection `tmux` (tmux windows `0` and `1`), one with a
   two-pane split (`vertical = false`), the other one pane; each tmux window opened as its own
   new iTerm2 window; the launch tab stayed in its own window with `tmux_window_id` `"-1"`.
5. **detach by session:** `detach(session:on:)` for the SSH host found the 1 attachment (1
   mapped, 0 unmapped), checked its identity again and sent `detach-client` bound to the launch
   tab: answered, the connection closed, ssh and the helper exited 0, the launch tab closed by
   itself (10.6 and 10.3 s old), `$0` survived with 2 windows and 3 `sleep` panes.
6. **reattach:** the same checks as steps 3 and 4 on a new launch tab and connection.
7. **focus existing:** a second attach focused connection `tmux` (`requested → focused`, 1
   mapped and nothing unmapped) and activated its tab; nothing opened: the run's 3 windows and 3
   tabs, every other window and tab and the 1 connection unchanged, no launch tab, no argv
   digest. It ended 0.76–0.81 s after the call, discovery over ssh taking most of it.
8. **detach** (by connection): the same checks as step 5 (launch tab 10.4 and 10.3 s old).
9. **stale guard:** revalidation refused the stale target without a tab; with discovery
   reporting the same wrong `session_created`, the guard on Saturno refused it and ssh exited
   65 (`sessionChanged`) 1.7 s after the call; no connection or tmux client appeared; the
   helper kept the tab open with its explanation until the test closed it, 10.3 and 10.5 s old.
10. **still waiting** (original design, see above): an attach through
    `nonexistent-muxfinder@saturno-m4` (revalidated against
    `saturno-m4`): ssh waited at its password prompt; no connection appeared; the attach
    published `stillWaiting` 21.0 s after the call (the launch tab 20.3 and 20.2 s old),
    never `confirmed`. The test closed that tab (forced); the attach then ended
    `helperFailed(childSignaled)` (run 2: exit 129, SIGHUP) 5.2 s after the close, and `$0`
    survived unattached.
11. **cleanup** (about 2.1 s, mostly ssh): killed `$0`; Saturno's server exited with its last
    session (`noServer` afterwards); the marker removed; nothing of the run left.

### Observed behavior over SSH

- **Native integration:** iTerm2 treats `tmux -u -CC` arriving through `ssh -t` like a local
  one: the connection is named `tmux` and owned by the launch tab's session, the windows,
  tabs and split tree look the same, and `detach-client` is a clean detach (ssh exits 0 with
  the remote tmux client; the helper records success).
- **Identity:** the D16 identity line through the remote control connection carried
  `#{host}` `Saturno-M4.local`, byte-identical to the remote `uname -n` from discovery, and
  Saturno's server pid and start time; the socket path `/private/tmp/tmux-501/default` is the
  same path as this Mac's default socket, so the node name is what keeps the two apart.
- **Timings** (from the attach call; discovery over ssh is most of the difference to the local
  path):

  | Step | Run 1, step 3 | Run 1, step 6 | Run 2, step 3 | Run 2, step 6 |
  |---|---|---|---|---|
  | Revalidated by discovery | 712 ms | 710 ms | 749 ms | 757 ms |
  | Existing attachments checked | 713 ms | 710 ms | 751 ms | 758 ms |
  | Launch tab opened (`launched`) | 848 ms | 843 ms | 883 ms | 878 ms |
  | Connection listed | 1,693 ms | 1,685 ms | 1,758 ms | 1,718 ms |
  | Identity confirmed (`confirmed`) | 1,772 ms | 1,764 ms | 1,839 ms | 1,785 ms |
  | Tab activated | 2,193 ms | 2,188 ms | 2,288 ms | 2,290 ms |

  The connection appears about 0.85 s after the tab (ssh connecting and authenticating with
  the agent's key, then the remote check), and activation waited about 0.4 s for the first
  tmux tab.
- **ssh waiting for a password** (the step's original design): with no key for the user, ssh
  asked for a password in the
  launch tab and the attach reported `stillWaiting` once its 20 s ran out, not before and never
  as a success. Closing that tab (forced, by its session id) removed it from `ListSessions` at
  once, but ssh ended only about 5 s later (by SIGHUP), so the attach learned the helper's
  result 5.2 s after the close; the closed-tab result wait is now 10 s (D17). Saturno closed
  the unauthenticated connection on its own a few minutes later; ssh, still reading the
  password prompt, only notices that when the prompt ends.
- **Dialogs:** none in runs 1 and 2, nor on the forced closes. In run 3 iTerm2's main thread
  was not in a modal run loop when its API stopped answering (see above); the screen was not
  looked at, so a window-level sheet cannot be ruled out.
