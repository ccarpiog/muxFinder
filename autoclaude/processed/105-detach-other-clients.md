# Detach other clients: keep this Mac's attachment, drop the session's others

Proposed phase, queued after the plan's remaining work **and before the phases from
`110-other-terminal-apps.md`**: the user asked for this order (quoted below). If that item's
phases are already in PLAN.md when this one is triaged, put this one ahead of them. There is no
`priority:` line: it does not need to follow the current phase. Suggested risk: **high** (a new
tmux command that detaches other Macs' clients, sent through iTerm2's tmux connection; the
attach coordinator, the popover's context menu and a new confirmation).

## User request (2026-11-06, verbatim)

Context: the user was in iTerm2 on one Mac, attached through muxFinder over SSH to a session on
another Mac whose own iTerm2 had the same session attached. Resizing the iTerm2 window did not
resize the usable area. After the cause was explained and Move here suggested:

> I don't see the "Move here" option.

Then:

> Add the Detach other clients accion, please. But don't do it directly, add it as a task to
> autoclaude, before the task that allows using different terminal apps

## The problem (diagnosed 2026-11-06 on the user's live session, read-only)

- Two iTerm2 tmux clients (control mode) were attached to one session: the Mac's own and
  another Mac's (over ssh).
- `window-size` is `latest` (tmux's default): a shared window takes the size of the client with
  the most recent activity. Control-mode clients never register activity (`client_activity`
  stayed at each client's attach time; iTerm2's keys and resizes arrive as commands). With two
  of them attached neither is "latest", and tmux ignores both clients' `refresh-client -C`
  requests: the window keeps the size it had (80x24 there). iTerm2 shows the rest of its
  window as unusable space.
- **Move here…** is hidden on a Mac that already shows the session
  (`PopoverContent.offersMoveHere`, D21: a new launch's `attach-session -d` would detach this
  Mac's attachment too). Today the user must Detach from this Mac and then Move here, which
  closes and reopens every window, or go to the other Mac.

## Verified facts (2026-11-06, tmux 3.8, private server)

These ran on a private socket from `mktemp -d /tmp/mfx.XXXXXX`, on `muxfinder-test-*` sessions,
with plain `tmux -C` clients standing in for iTerm2. Nothing real was touched.

1. Clients A and B on one session. A asked `refresh-client -C @0:150x50` first. B then asked
   `@0:200x60` and other sizes, also after a `send-keys` of its own. The window stayed 150x50.
   `set -g window-size largest` or `smallest`, with no resize request after it, did not change
   it either.
2. Once A was detached, the window took B's size at once (200x60) and followed B's next request
   (210x65).
3. `attach-session -d -t <session id>`, sent by B while already attached to that session:
   - A got `%exit`.
   - B stayed attached.
   - A client C on another session of the same server was untouched.
   - The window took B's size and then followed it.
   - **But B received `%session-changed $0 <name>`**, then `%layout-change` and
     `%client-detached client-<pid>`. How iTerm2 reacts to a `%session-changed` naming the
     session it already shows is unverified. It may tear down and reopen its tmux windows,
     which would defeat the point.
4. A control client without a tty is named `client-<pid>` (`client_name`). iTerm2's clients
   (`-CC` on a tty) show their tty as `client_tty`.

## Requirements

1. **Proof first, in the phase, before the UI.** Settle the command on a `muxfinder-test-*`
   session attached through a launch tab, plus a plain `tmux -C` client of the harness's own
   (as the e2e move here step does), on This Mac and on `saturno-m4`.
   - (a) `attach-session -d -t <session id>` sent through iTerm2's tmux connection. Check that
     iTerm2's windows for the session stay as they are: the same iTerm2 session and tab ids
     before and after, no window closed or reopened, and the launch tab still buried.
   - (b) Otherwise, detach each other client by name. Use `list-clients` filtered to that
     session, plus the connection's own `display-message -p '#{client_name}'`, then
     `detach-client -t <name>` for each other client. Bind it so a name reused in between can
     never detach a client of another session: one command line if tmux allows, or a check of
     `client_pid` and the session right before each detach.
   - Never `detach-client -a` (server-wide) or `detach-client -s` (it includes this
     attachment).
   - Record the choice and what was verified as a new decision (the next free D number).
2. **Core.**
   - A coordinator call such as `AttachCoordinator.detachOtherClients(of:confirmation:)`. Its
     confirmation names the session key, like D21's `MoveHereConfirmation`: a confirmation for
     another key runs nothing.
   - It goes through this Mac's attachment for the session (the attachment index, D16). It
     uses the same binding rule as `detach(session:on:)`, with the identity check right before
     sending, and sends once (D13).
   - Local and SSH hosts work alike. The command travels through iTerm2's connection: no new
     ssh, remote script or file.
   - Typed results:
     - detached *n* clients;
     - nothing to detach (the others had already left);
     - not attached here;
     - identity changed (nothing sent);
     - check failed.
   - Several attachments of the session in this Mac's iTerm2 (rare): keep the one "Show tab"
     focuses. The others count as other clients, and the confirmation counts them.
3. **UI, in the popover only** (like Move here and Detach, D32).
   - **When it shows:** the context menu item "Detach other clients…" appears when the row is
     open in this Mac's iTerm2 and the host's listing shows more clients (`clientCount`) than
     this Mac's attachments. Otherwise it is hidden.
   - **The confirmation** uses D25's panel style. It names the session and how many clients
     will be detached. It says they may be on other Macs and that the session keeps running.
     It also says why someone may want this: "While another client is attached, tmux may keep
     the window at the other client's size."
   - **Buttons:** "Cancel" and "Detach other clients".
   - **Afterwards:** the row refreshes. Failures show their recovery, as Detach's do.
   - Optional, if it fits the row without clutter: a hint when the session is open here and
     attached elsewhere too.
4. **Docs.**
   - README: the session actions list, plus a short note on the window size effect.
   - ARCHITECTURE, TESTING, MANUAL-CHECKLIST and the PLAN.md decision.
   - `docs/screenshots/attach-states-*.png` with the new confirmation, and
     `popover-states-*.png` if the row changes.

## Acceptance

- **Hermetic tests:**
  - A confirmation for another key runs nothing.
  - The offer: shown when the session is open here with 2 or more clients; hidden with 1
    client, when the session is not open here, and on a stale row.
  - The command holds only the validated session id, with no other runtime value inserted.
  - Identity changed: nothing is sent.
  - The results map as listed above.
- **A real run:** a new step in `e2e-local` and `e2e-remote saturno-m4`, or an `e2e-…` command
  of its own.
  - Attach through a launch tab, then attach a plain `tmux -C` client of the harness.
  - Run Detach other clients. The plain client must exit 0 (`%exit`). The iTerm2 attachment
    must stay, with the same tab and session ids and its launch tab still buried. The session
    must stay alive.
  - Then detach and clean up as today, with the usual iTerm2 thread-count caution.
- **Galleries:** `--preview-gallery attach` (and `popover` if the row changed), light and dark.
- **`docs/MANUAL-CHECKLIST.md`:** open the same session on two Macs. On one, run Detach other
  clients. The other Mac's windows for it close, and resizing this Mac's iTerm2 window now
  resizes the session.
- **Builds and checks:** the shared verification, `scripts/build-app.sh` and
  `codesign --verify --deep --strict build/muxFinder.app`.
