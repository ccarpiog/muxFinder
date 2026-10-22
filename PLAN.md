# muxFinder implementation plan

Native macOS menu bar app that discovers tmux sessions on the user's Macs (Saturno, Neptuno,
Sirio) and attaches them in iTerm2 through native tmux control mode (`tmux -CC`).

- **What to build:** `docs/REQUIREMENTS.md` (the user's brief, verbatim). It is the acceptance
  authority. Read the sections a phase names, not the whole file.
- **How to build it:** this file. Shared sections first, then one section per phase. A phase
  worker reads *Architecture*, *Decisions*, *Verified facts*, *Unattended-run rules* and its own
  phase only.
- **Conventions and commands:** `CLAUDE.md`.

## Architecture

One SwiftPM package. No `.xcodeproj`; the `.app` bundle is assembled by a script.

```
Package.swift                 swift-tools-version 6.0, macOS 14, Swift 6 language mode
Sources/
  MuxFinderCore/              library: all logic, no SwiftUI, fully unit-testable
    Config/                   HostConfig, HostList, HostStore (JSON), SSHConfigSuggestions,
                              AppPaths, PrivateStorage + ExtendedACL (private files)
    Process/                  ProcessRunner protocol + posix_spawn implementation
    Shell/                    POSIX quoting, remote-command builder, input validation
    Tmux/                     tmux locator, discovery probe script, parser, models,
                              error classification, tmux command builders
    ITerm2/                   ITerm2Integration protocol, native API client
                              (WebSocket over Unix socket + minimal protobuf codec)
    Launch/                   launch request/result files shared with muxfinder-launch
    Attach/                   AttachCoordinator (revalidate, launch, confirm, focus),
                              AttachmentIndex (iTerm2 tmux connections -> session keys)
    Refresh/                  RefreshCoordinator actor, backoff, live/stale snapshots
    Profiles/                 Persistent Work dynamic-profile generator/installer
    Diagnostics/              operation log (ring buffer + os.Logger), no terminal content
  muxfinder-launch/           helper executable that iTerm2 runs inside the launch tab
  muxfinder-probe/            developer/diagnostic CLI that drives the core without the GUI
  MuxFinderUI/                library: AppModel, popover content and views, the Settings
                              window (SettingsModel, views, window controller), preview
                              fixtures (D22, D23); tests import it
  MuxFinderApp/               SwiftUI menu bar app (MenuBarExtra .window style): entry
                              point, scene and app delegates only
Tests/MuxFinderCoreTests/     Swift Testing, hermetic: no real ssh or iTerm2, never the
                              user's tmux server (one test uses real tmux on a private
                              socket directory and skips when tmux is absent)
  Fixtures/                   discovery outputs, protobuf golden bytes
Tests/MuxFinderUITests/       Swift Testing, hermetic: the app model over fakes
scripts/                      build-app.sh, install.sh, uninstall.sh, dev/ helpers
docs/                         REQUIREMENTS, ARCHITECTURE, INTEGRATION-PROOF, TESTING
```

Data flow: `RefreshCoordinator` runs `DiscoveryProbe` per enabled host (local process or
`/usr/bin/ssh`) → parser → `HostSnapshot` (live or stale). `AttachmentIndex` asks iTerm2 which
tmux connections exist locally and which server and session each is attached to, so the UI can
tell "open in iTerm2 on this Mac" from "attached somewhere". A click goes to
`AttachCoordinator`. It revalidates the session, writes a launch request file, and asks iTerm2
(through `ITerm2Integration`) to create a tab whose command is
`<bundle>/Contents/MacOS/muxfinder-launch attach <uuid>`. The helper reads the request, runs
local tmux or `ssh -t` as its child inside that iTerm2 PTY, and writes a result file. The
coordinator confirms attachment by finding a new iTerm2 tmux connection owned by the tab's
session, verifies its identity, and then activates the tab.

## Decisions

- **D1 — iTerm2 integration: a native Swift client of iTerm2's API** (decided with the user on
  2026-10-21). The client opens a WebSocket over the Unix socket
  `~/Library/Application Support/iTerm2/private/socket` using a hand-written RFC 6455 client on
  a POSIX socket, plus a hand-written minimal protobuf codec for the few messages needed.
  - **No Network.framework WebSocket.** `NWProtocolWebSocket` on a `.unix` endpoint failed
    with POSIX 53 (ECONNABORTED). The raw handshake worked (see *Verified facts*).
  - **No Python, no SwiftProtobuf, no code generated from `api.proto`.** iTerm2 is GPLv2 and
    this repo is MIT. iTerm2's installed Python module is a read-only reference for protocol
    facts (field numbers, property keys, call sequences). Never copy its code.
  - **Auth cookie** comes from static AppleScript source,
    `tell application "iTerm2" to request cookie and key for app named "muxFinder"`, executed
    in-process with `NSAppleScript`. Never splice runtime values into AppleScript source.
    Request the cookie only when iTerm2 is already running, or right after an attach has
    deliberately launched it. Discovery must never launch iTerm2.
  - Everything sits behind an `ITerm2Integration` protocol so the backend can be replaced. A
    fake implementation exists for tests.
- **D2 — Launch helper plus request token.** iTerm2 only ever receives the helper's absolute
  path and a UUID. Host values, session ids, paths and directories travel in a 0600 JSON request
  file under `~/Library/Application Support/muxFinder/launch/`. The helper deletes the file on
  read, and stale files expire after 2 minutes. If the helper path contains characters outside
  `[A-Za-z0-9._/-]`, refuse with a clear "move muxFinder to /Applications" error. Lift this only
  if Phase 4 proves iTerm2's command quoting rules and a test with a space in the path passes.
  The helper runs ssh or tmux as a **child** (not `exec`) so it can write a result file
  (exit status, failure class) when the child ends. On failure it prints a plain explanation
  and waits for Return before exiting, so the tab shows why.
- **D3 — Remote commands.** OpenSSH concatenates its remote arguments into one string that the
  remote login shell parses, so build exactly one string:
  `/bin/sh -c '<static script>' muxfinder '<arg1>' '<arg2>' …`. Every argument goes through
  POSIX single-quote escaping (`'` → `'\''`). Script bodies are static constants with no
  interpolated data. Locally, use `posix_spawn` with argv only and never a login shell; a
  static script runs as `/bin/sh -c <script> muxfinder <arg1> …`, data only as argv. This requires
  a POSIX-compatible login shell on remote hosts (zsh or bash, the macOS default); document it.
- **D4 — Session identity.** `SessionKey = (hostID, socketPath, serverPID, serverStartTime,
  sessionID)`. `session_created` is kept for revalidation. Names are display data only, and all
  targets use `$N` ids. Before attaching, the helper's guard script checks that
  `display-message -p -t "$id" '#{session_id}:#{pid}:#{start_time}:#{session_created}'` still
  matches (the session id is in the format because `display-message` resolves a missing target
  leniently; see D14). Exit code 64 means the session is gone, 65 means it changed (for
  example, an id reused after a server restart). The check and the attach are separate
  processes (D14), so a few milliseconds pass between the check's `display-message` and tmux's
  `attach-session` (reaping the check, validating its output, one `posix_spawn`). A session
  that ends in that window makes `attach-session` exit 1; a server restarted in it is caught
  by the coordinator's identity check through the new control connection (Phase 4, step 7).
  Within one server a `$N` id is never reused.
- **D5 — Locating tmux.** An explicit override is used alone: if it is missing, or does not
  answer `-V` with `tmux …`, the host reports "tmux not found" (no fallback to another tmux).
  Without an override, use `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`,
  `/opt/local/bin/tmux`, `/usr/bin/tmux`, and finally `command -v tmux`. Never rely on PATH
  alone: noninteractive SSH on Saturno has `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, verified. The
  locator runs on the target host as a static `sh` fragment (`TmuxLocator.script`).
- **D6 — Discovery is read-only and noninteractive.** It runs only `list-sessions`,
  `list-clients` and `display-message`. SSH gets
  `-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -n -T`
  and nothing that weakens host-key checking. A 12 s hard timeout kills the whole process group.
  The user's `~/.ssh/config`, keys and agent are used as-is; OpenSSH resolves aliases.
- **D7 — Build and platform.** SwiftPM only. `scripts/build-app.sh` builds release arm64 and
  assembles `build/muxFinder.app` with bundle id `cc.carpio.muxfinder`, `LSUIElement`,
  `LSMinimumSystemVersion` 14.0 and `NSAppleEventsUsageDescription`. It signs with the first
  "Apple Development" identity (override with `MUXFINDER_SIGN_IDENTITY`), using hardened
  runtime plus the `com.apple.security.automation.apple-events` entitlement, not sandboxed. The
  ad-hoc fallback warns that macOS permission grants reset on every build. No notarization;
  never claim it. Target arm64 only, since all three Macs are Apple Silicon (M4, M4, M5).
- **D8 — Storage.** Configuration lives in `~/Library/Application Support/muxFinder/`
  (`hosts.json`, `launch/`, diagnostics), with directories 0700 and files 0600, and no
  extended ACL (D14 for `launch/`, D19 for the folder itself and `hosts.json`). The app owns
  exactly one iTerm2 file, `~/Library/Application Support/iTerm2/DynamicProfiles/muxFinder.json`.
  Never write iTerm2 preferences, other profiles, or shell startup files.
- **D9 — Scope.** Only the current user's **default tmux server**; named sockets are deferred.
  The UI and README say so.
- **D10 — UI language is English, sentence case** ("New session", "Move here", "Refresh").
- **D11 — Tests.** `swift test` is hermetic: fakes for the process runner, the clock and
  iTerm2; no ssh; tmux only on a private, test-owned socket directory, never the user's server.
  Real-world checks run only through `muxfinder-probe` subcommands (`discover`, `attach`,
  `new-session`, `e2e-*`, `hosts`, `refresh`; all but `discover`, `hosts` and `refresh` open
  real iTerm2 windows) and the app binary run from the shell (D22: the preview window and the
  menu bar item check, neither of which contacts iTerm2),
  are run explicitly during verification, and their results are recorded in
  `docs/TESTING.md`. A mocked attachment is never reported as a real integration result.
- **D12 — tmux output is always read through `tmux -u`** (decided in Phase 2, 2026-10-21).
  A tmux client whose locale is not UTF-8 (the first set of `LC_ALL`, `LC_CTYPE`, `LANG` must
  contain "UTF-8") gets `-F` and `display-message -p` output with every tab, other control
  character and non-ASCII character replaced by one `_` per column (a zero-width character
  vanishes; printable ASCII is kept), so Unicode names are lost and tab-separated records can't
  be split. This holds for control clients too (Phase 5a facts). Noninteractive SSH only
  has a locale when the client forwards `LANG` (macOS `SendEnv LANG LC_*` / `AcceptEnv LANG
  LC_*`), and GUI apps started by launchd normally have no `LANG`, so the remote side gets
  none. `-u` forces UTF-8 output whatever the locale and needs no locale to exist on the host;
  `LC_ALL=…UTF-8` would need a locale name valid on every host and changes other tools too.
  Verified locally with `env -i` and on Saturno with `env -u LANG ssh …`: without `-u` tabs
  and Unicode both came back as `_`; with `-u` the bytes were exact. Every tmux command whose
  output muxFinder parses uses `-u`.
- **D13 — iTerm2 transport model** (decided in Phase 3b, 2026-10-21). Each API connection has
  one dedicated reader thread (bounded `poll()` reads, never on Swift's cooperative pool) that
  hands whole messages to the `ITerm2Connection` actor through an `AsyncStream`, and one serial
  writer queue that writes every frame whole, so no actor or reader ever blocks on the socket.
  The actor matches responses to requests by `id`; a stream end, undecodable message or
  stalled half-received message ends the connection and fails every pending request. Each
  request's frame carries the request's absolute deadline: a request that times out, is
  cancelled or loses its connection before its frame starts writing withdraws the frame (it is
  never sent) and fails with `ITerm2Error.notSent(reason)`, and the writer never starts a frame
  after its deadline or after a close frame was queued. A frame whose write has started is
  written whole; its request then fails with the plain reason (`timedOut`, `disconnected`, …,
  or `CancellationError`), meaning the outcome is unknown. `ITerm2APIClient` connects on demand
  with a fresh cookie for every connection and never retries a request (a request may have
  taken effect before its connection broke; only `notSent` and the connect-time errors
  guarantee it did not). Concurrent callers share one connection attempt; `disconnect()`
  invalidates the attempt in progress by generation, failing its callers with `disconnected`
  and closing a connection it completes late. A caller cancelled while it waits leaves the
  attempt at once (`CancellationError`); right before asking for the cookie and right before
  connecting, the attempt goes on only while it is still current and a caller still waits,
  and otherwise stops, so a cancelled caller (the popover closing, D20) leaves nothing behind
  that contacts iTerm2 later, while a caller that joins in time keeps it (no second cookie).
  Connection order: running check, socket-file check, cookie, connect, handshake, so no
  cookie is requested while iTerm2 is not running or its API is off. Socket missing, refused
  or not a socket → `apiDisabled`; HTTP 401 → `authRejected`. The client announces the
  library version `python 2.11` that the protocol facts were checked against.
- **D14 — Launch protocol** (decided in Phase 4a, 2026-10-21; code in
  `Sources/MuxFinderCore/Launch/`).
  - **Files:** `launch/<uuid>.request.json` and `<uuid>.result.json`, the uuid only in
    canonical lowercase form (`LaunchToken`, validated before it names a file). Writes are
    atomic (temporary file with `O_CREAT|O_EXCL|O_NOFOLLOW`, mode 0600, then a rename;
    `RENAME_EXCL` for requests, so an id is never reused). The directory is 0700 (tightened if
    looser) and refused if it is a symbolic link, not a directory, or owned by another user;
    all file calls go through its descriptor. Only `writeRequest` (and
    `createTestModeMarker`) creates it. The helper takes its request by opening it with
    `O_NOFOLLOW` and unlinking it at once (the first unlink wins, so a request is used once),
    then requires a regular file owned by the user, no group or other bits, no extended ACL and
    at most 16 KiB. TTL: 120 s after `createdAt` (5 s future tolerance), on an injectable
    clock. The sweep removes request, result, argv-digest and temporary files whose mtime is
    older than the TTL.
  - **ACLs:** mode bits alone are no private boundary on macOS, since an extended ACL entry
    grants access whatever they say and new files inherit their directory's inheritable
    entries. So, through descriptors (`ExtendedACL`; with the directory and atomic-write
    primitives in `Config/PrivateStorage.swift`, shared with the host store, D19): every open
    of the launch directory removes any extended ACL from it and refuses the directory (73) if
    that fails; every file the store creates loses any inherited ACL before its first byte is
    written; and a file
    being taken is refused (and deleted) if it carries any extended ACL entry, even a
    deny-only one. That strict rule works on a normal home directory: the ACL macOS puts on
    home folders (`group:everyone deny delete`) is not inheritable. A deny-delete entry also
    blocks the owner's unlink, so the store removes the ACL of a file the user owns before
    deleting it. The launch store covers only the launch directory and its files. The
    Application Support root above it is created by `AppPaths` (0700, ACL untouched) and is
    secured by every host-list save (D19).
  - **Exit codes:** guard 64 gone, 65 changed, 66 tmux missing (the D5 rule, discovery's
    `tmuxNotFound`), 67 tmux check failed, 68 guard usage. Helper 2 usage, 70 request missing,
    71 expired, 72 unreadable, 73 launch directory unusable, 74 spawn failed, 75 check timed
    out, 128 + n interrupted by signal n before tmux attached; otherwise tmux's own status (0
    after a detach, 1 on errors), and 128 + n for signal n. For a remote attach ssh hands back
    the remote status (the guard's codes, tmux's 0 or 1) and uses 255 for its own errors (D17).
    `LaunchFailure.fromCheck(_:timedOut:)` (the check child) and `LaunchFailure.from(_:host:)`
    (the attach child) are the pure mappings.
  - **Gone versus error:** in tmux 3.8, `display-message -t '$N'` for a missing id exits 0
    and prints empty session fields, so the guard reads the output. Exactly
    `<id>:<pid>:<start>:<created>` is a match. `<id>:` with other values is changed. An empty
    or different session id is gone. Any other shape is 67. A tmux failure with `no server
    running on`, `error connecting to … (No such file or directory)` or `can't find session`
    is gone; any other tmux failure is 67, with tmux's first line (printable ASCII, 200 bytes)
    on stderr.
  - **Check, then attach (two children):** the **check** is the static guard,
    `/bin/sh -c <script> muxfinder <override> <id> <pid> <start> <created>`, run through
    `PosixSpawnProcessRunner`: stdin `/dev/null`, piped output (4 KiB cap), its own process
    group and a 10 s hard deadline (`LaunchGuard.defaultTimeout`, injectable) after which the
    whole group gets SIGTERM, then SIGKILL 2 s later, so the locator, `display-message` and
    every other subprocess end together. A timeout is `checkTimedOut` (75). On a match the
    check prints the tmux path it used; the helper accepts exactly one line holding an
    absolute path without NUL or line breaks that names a regular executable file (links
    followed), and with an override only the override itself, else `tmuxCheckFailed`. The D2
    character rule does not apply: the path is only ever argv. The check's stderr (tmux's
    sanitized first line) is copied to the tab as printable ASCII, never to the logs. The
    **attach** is `<path> -u -CC attach-session -t <id>` (`attach-session -d -t <id>` when the
    request moves the session here, D21), spawned directly with no shell.
    D12's `-u` applies to control mode too, so the formats iTerm2 requests keep UTF-8 and
    tabs. This replaced a single guard that `exec`ed tmux: its locator and `display-message`
    subprocesses had no deadline and were out of reach of a signal sent to the shell, and
    putting the shell in its own group would have stopped tmux with `SIGTTIN`. The price is
    the check-to-attach window described in D4.
  - **Helper process:** the attach child runs on the helper's own terminal: descriptors 0–2
    are inherited (the one exception is the ssh child's standard error, relayed through a pipe,
    D17), the child stays in the helper's foreground process group (a
    background group would get `SIGTTIN`), and it starts with default dispositions. The helper
    ignores SIGHUP, SIGINT and SIGTERM for its whole life and watches them with
    `EVFILT_SIGNAL` from its first instructions (`TerminalChildControl.watchTerminalSignals()`,
    which `LaunchHelper.standard()` starts): one that arrives before tmux attaches ends the
    launch as `interrupted(n)` without attaching (a running check is stopped with its whole
    process group, the same way as on a timeout); one that arrives while tmux runs is passed
    on to tmux. So closing the tab never orphans tmux or a check subprocess, and the result is
    always written. For the final wait and hold it restores only SIGHUP's default (closing the
    tab ends it at once, unseen) and keeps SIGINT and SIGTERM ignored. On failure it prints a
    one-paragraph explanation, and waits for Return only when stdin is a terminal,
    `MUXFINDER_LAUNCH_NO_WAIT` is not `1`, and no SIGHUP arrived; a SIGINT (Ctrl-C) or SIGTERM
    ends that wait like Return (seen through dispatch signal sources, the wait returning once
    whichever comes first).
  - **Minimum lifetime** (decided in Phase 4c, 2026-10-22): under that same condition the helper
    never exits before it is 10 s old (`LaunchHelper.minimumLifetime`, counted from its start),
    whatever the outcome: it writes the result first, waits for Return if it failed, then holds
    the rest (`LaunchTerminal.holdOpen(for:)`: closing the tab, SIGHUP, still ends it at once;
    SIGINT and SIGTERM never end it, so Ctrl-C at the prompt or during the hold cannot end a
    visible tab early). A launch tab that ends within 3 s of starting raises iTerm2's blocking
    short-lived-session warning (*Verified facts*, Phase 4), and tmux can end right after
    attaching (iTerm2 or someone detaching early, the session killed) or Return can be pressed
    at once; the coordinator's own 10 s wait (D15) covers only the ends it causes.
  - **Test mode:** set by `MUXFINDER_LAUNCH_TEST_MODE=1`, or by a regular file
    `launch/test-mode` owned by the user. The marker is how 4b turns test mode on for helpers
    iTerm2 starts: the e2e run creates it (`LaunchStore.createTestModeMarker()`) and removes it
    in cleanup (`removeTestModeMarker()`), and the sweep leaves it alone. In test mode the
    helper writes `launch/argv-<pid>.json` before parsing argv: the argument count, then each
    argument's byte length and SHA-256, plus the first canonical launch id found. Right before
    it starts its attach child (tmux locally, ssh remotely) it writes the file again with
    `attachChild`: that child's argv digested the same way and whether it detaches the
    session's other clients (D21); a launch that ends first has none.
    `LaunchStore.takeArgvDigests()` reads them.
  - **Test launch delay** (decided after the Phase 5b review, 2026-10-22): a request may carry
    `testLaunchDelaySeconds` (1–120; any other value makes it unreadable, 72; absent from every
    request the app writes). Only in test mode does the helper honor it: it prints one line
    saying so and, before its first child, runs `/bin/sleep <seconds>` as a check-stage child
    (own process group, a deadline 5 s past the delay, stdin `/dev/null`), so nothing else runs
    meanwhile (no check, tmux or ssh) and a signal ends the wait exactly as it ends a check:
    `interrupted(n)` without attaching, with the explanation, the wait for Return and the 10 s
    hold unless the tab closed (SIGHUP). When the delay runs out the launch goes on as usual.
    Outside test mode the field changes nothing, so it cannot be triggered by a request alone.
    `e2e-remote`'s `still waiting` step uses it (D17 *Real-run safety*).
  - **Overrides and paths:** `MUXFINDER_LAUNCH_DIRECTORY` (absolute) replaces the launch
    directory for development and tests; a relative or empty value is refused (73).
    `MUXFINDER_LAUNCH_MINIMUM_LIFETIME_MS` (1 to 7 decimal digits, tests only) replaces the
    10 s minimum lifetime, so tests can run the binary in a pseudo-terminal quickly; any other
    value keeps 10 s.
    `LaunchHelperPath.locate()` finds `muxfinder-launch` next to the running executable and
    applies the D2 rule. The tab command is `LaunchHelperPath.attachCommandLine(for:)`, that
    is `<path> attach <uuid>`.
- **D15 — Attach coordinator** (decided in Phase 4b, 2026-10-22; code in
  `Sources/MuxFinderCore/Attach/`).
  - **Launch tab:** `CreateTab` without `window_id`, so the tab opens in a new window and never
    in one of the user's, with the host's profile and `Close Sessions On End = true`: it closes
    by itself after a clean detach, and after a failure once the user pressed Return. The
    request runs in a task of its own, so cancelling an attach never loses the new tab's
    session id (the result reports it on every failure after the tab opened).
  - **Seams:** iTerm2 (`ITerm2Integration`), discovery (`HostDiscovering`), the launch files
    (`LaunchRequestStore`) and the clock (`AttachClock`) are protocols, so the coordinator is
    tested hermetically with fakes and a manual clock.
  - **Single flight** by `SessionKey`: concurrent callers of the same kind (attach, or move
    here, D21) share one launch and one result; a caller of the other kind waits until that
    launch ended and is settled (D21), then starts its own. When
    every waiting caller is cancelled, the launch stops at its next step (`cancelled`). An
    attach arriving while such an attach winds down (its `CreateTab` still pending) starts a
    new one; from then on only the newest launch of the session sets `state(of:)`. The older
    launch's updates are still delivered, with `AttachUpdate.isCurrent == false`, so its launch
    tab stays known. A move here, and an attach after a move here, instead wait until such a
    launch ended and is settled (D21).
  - **Failures:** every failure before a connection was found withdraws the request file, so a
    tab that starts late cannot attach. The read-only polls (`ListConnections`, `ListSessions`)
    end the attach at their first failure rather than retry it; `CreateTab`, the identity
    `SendCommand`, `Activate` and `detach-client` are sent once (D13). An unreadable or
    mismatching identity answer detaches the new connection once its launch tab is old enough
    (see *Teardown*); the attach reports the failure after that detach.
  - **Teardown:** ending a connection ends its launch tab, and a launch tab that ends within
    3 s of opening makes iTerm2 block its whole API behind a modal warning (*Verified facts*,
    Phase 4). So the coordinator sends `detach-client` (after a failed identity check, and for
    `detach`) only once the launch tab is `minimumLaunchTabAge` old: 10 s, more than three
    times iTerm2's threshold, the margin `e2e-local` adopted after its first run (whose warning
    followed an end about 1.5 s after the start). The helper keeps the same 10 s minimum
    lifetime on its side (D14). In the passing runs the launch tabs ended 10.1–10.7 s old.
    The age counts from the `CreateTab` answer for tabs this coordinator opened (the
    identity-failure detach takes it from its own launch; `detach` looks it up among the latest
    64 it remembers), and for any other tab from a moment it surely existed by: the call for
    `detach(connectionID:gatewaySessionID:launchID:)` (the caller saw the connection before
    calling, as with `muxfinder-probe detach`), and the end of the index snapshot that revealed
    the connection for D16's `detach(session:on:)` (a tab opened during its discovery or
    listing did not exist at the call). The identity-failure detach runs in a task of its own
    that the attach waits for, so cancelling the attach neither skips the wait nor ends the tab
    early; a `detach`
    cancelled during its wait sends nothing (`DetachResult.cancelled`). `detach` takes the
    launch tab's session id with the connection id.
  - **Connection binding:** connection ids are short names (`"tmux"`) that iTerm2 hands out
    again, so after an iTerm2 restart a recorded id can name a user's attachment. Every command
    for a connection (the identity check and `detach-client`) goes through
    `ITerm2Integration.sendTmuxCommand(_:connectionID:ownedBy:)`: `ListConnections`, then the
    command only if the connection's `owning_session_id` is the launch tab's session id
    recorded at `CreateTab`, both on one API connection with no reconnect in between (the
    client exposes no connection generation; this rule is what keeps a reconnect from
    redirecting the command). Otherwise it fails with `tmuxConnectionNotOwned` (a "not sent"
    error) and nothing is sent. Every activation follows the same rule through
    `activateFirstTab(ofTmuxConnection:ownedBy:options:)`: `ListConnections`, then (owner
    unchanged) `ListSessions` and `Activate` of the connection's first tab, on one API
    connection.
  - **Identity command:** D16's `ConnectionIdentity.command`, read on bytes (D16). The
    launch's client runs with `-u`, so its answer is exact; any other answer is unreadable. The
    attach's check compares the server and the session and, when revalidation reported a node
    name, `#{host}` with it (D17: an SSH destination that reached another Mac never confirms).
  - **Activation** is part of the result, not a state: the first tab carrying the connection id
    (waited for up to 5 s) is activated with `select_tab`, `order_window_front` and the app
    options, without `select_session` (iTerm2 refuses that for a tab target), bound to the
    launch tab (*Connection binding*). A confirmed attach whose tab never appears, whose
    `Activate` fails, or whose connection is no longer the launch tab's
    (`failed(tmuxConnectionNotOwned)`, nothing activated) stays confirmed.
- **D16 — Existing attachments** (decided in Phase 5a, 2026-10-22; code in
  `Sources/MuxFinderCore/Attach/AttachmentIndex.swift` and `AttachCoordinator.swift`).
  - **Identity command:** `ConnectionIdentity.command`,
    `display-message -p "#{client_utf8}:#{n:host}:#{host}:#{pid}:#{start_time}:#{n:socket_path}:#{socket_path}:#{session_id}"`,
    is the one command for the attach's identity check and for the index, with one reader on
    bytes (`ConnectionIdentity.read(_:)`): the UTF-8 flag `0` or `1`, the host name (non-empty,
    valid UTF-8, no control characters) and the socket path (valid UTF-8, starting with `/`)
    each exactly as many bytes as its `#{n:…}` length (bytes, verified), the pid and start time
    as canonical decimals, the session id last, every field ended by `:`. Only printable ASCII
    frames the fields, because the index asks control clients muxFinder did not start: a
    user's `tmux -CC` without `-u` under a non-UTF-8 locale gets every tab, control and
    non-ASCII character replaced by one `_` per column, zero-width ones dropped (D12), so the
    old tab-separated line came back unsplittable and the attachment went unmapped. A client in
    UTF-8 mode (`1`) sends the exact bytes. For a client that is not (`0`) a line is exact only
    when the host name and socket path are printable ASCII without `_` or `:` (no `_` means
    nothing was replaced; no `:` means each field ends at a real separator, so its length is
    the original byte length and nothing was dropped); anything else from it is `nonUTF8`,
    never matched. `#{host}` is the server's `gethostname()`, the text `uname -n` prints.
  - **Mapping:** `AttachmentIndex.snapshot(of:)` lists iTerm2's tmux connections and asks each
    one, concurrently, through the D15 binding rule with the owning session from that same
    listing; this read-only `display-message` is the only command it ever sends. An answer
    maps to `SessionKey(hostID, server, session id)` when exactly one given host has a
    discovery node name (`uname -n`) byte-equal to `#{host}` and a discovered server with the
    same socket path, pid and start time. The session id is the answer's, so a session
    discovery has not listed yet still maps. No title or name is ever matched.
  - **Unmapped kinds, counted and never guessed:** `unknown` (no host matches), `ambiguous`
    (several do, for example "This Mac" and an SSH entry for the same Mac), `nonUTF8` (a
    client not in UTF-8 mode whose answer may have lost bytes, see *Identity command*), `stale`
    (the listing gave no id or owner; the request failed, including `tmuxConnectionNotOwned`
    when the connection closed or changed owner first; the answer was unreadable; or no answer
    came in time). Connections a configured filter leaves out are not asked and count as
    `excluded`.
  - **Timeouts:** every command is bounded by `commandTimeout` (3 s) on the injectable clock.
    At the deadline the request is cancelled (D13: withdrawn if not yet written; a late answer
    is dropped), so a hung connection costs at most 3 s and never delays the others. The
    listing has the client's 10 s request timeout.
  - **Focus:** after revalidation an attach runs the index over the target's host alone (so
    `ambiguous` cannot arise there). When connections map to the target's key, the attach
    becomes a focus on the first listed one whose binding still holds. Its activation is D15's
    (first tab of the connection, waited for up to 5 s) bound to the owning session from the
    index's listing, because the index waits on every connection and meanwhile the short id
    can come to name another tab's connection. A connection that closed or changed owner
    (`tmuxConnectionNotOwned`) is skipped with nothing activated; the next attachment is
    tried. The first one whose binding holds ends the attach `focused(connectionID)`
    (`requested` → `focused`, published once the activation ended), the result carrying that
    connection, its owning session as `gatewaySessionID`, the check's counts and the
    activation. When every attachment changed, the attach fails with `attachmentChanged` and
    opens nothing, since the session may be attached again elsewhere; attaching again checks
    afresh. No request file, no `ensureRunning`, no `CreateTab`, even when activation fails or
    no tab appears: the index answered "attached", so a duplicate is never opened. Concurrent
    callers share the focus (single flight).
  - **When the index fails:** iTerm2 not running means nothing is attached, so the launch goes
    on (`ensureRunning` launches it). Any other listing failure ends the attach with
    `attachmentCheckFailed(error)` before anything is written or opened. Unmapped connections
    never block an attach (a move here refuses those that cannot be ruled out as showing the
    session, D21); a duplicate is possible only when a connection showing the session
    gave no usable answer within 3 s (the result reports the counts).
  - **`detach(session:on:)`:** discovers the host, runs the index, and handles every attachment
    of the key, whoever opened it, the earliest allowed end first. Each waits until its owning
    tab is 10 s old (D15 *Teardown*: from `CreateTab` for launch tabs this coordinator opened,
    for any other tab from the end of the snapshot that revealed its connection), then repeats
    the identity check through the binding rule, because a user's tab can detach and attach
    another session during the wait, reusing the short id; another session or server (or a
    `nonUTF8` answer) is `identityChanged` and no answer is `identityCheckFailure`, and nothing
    is sent. Otherwise `detach-client`, bound to the owner,
    goes out once; it waits for the connection to close and, for its own launches, the
    helper's result. Outcomes: `nothingAttached` (iTerm2 not running, no server, or no
    connection maps; nothing sent), `detached`, `notSent`, `notClosed`, `cancelled` (during a
    wait; nothing more is sent) and `checkFailed` (discovery or the listing failed). The
    remaining race is the gap between the check and `detach-client`, two consecutive requests
    on one API connection. Remote hosts work the same way (D17); an SSH host whose destination
    is not valid is `checkFailed` (`invalidDestination`) before anything runs.
  - **Seam:** `AttachCoordinator(existingAttachments:)` is `.standard` (an index over the
    coordinator's iTerm2 integration and clock; the default), `.index(_)` (a given one: a
    filtered index, or one with its own clock in tests) or `.off` (launch-path tests only; a
    move here still checks, with the standard index, D21).
  - **Real-run safety:** `e2e-local` gives its coordinators an index whose filter admits only
    connections owned by launch tabs this run opened, so no other connection ever gets a
    command, not even the read-only one. It does not refuse to start when other connections
    exist; it reports how many. A pre-check of `ListConnections` before an unfiltered index was
    rejected: a connection the user opens between the check and the index would get the
    command. `muxfinder-probe attach` and `iterm2 attachments` ask every connection, so
    unattended runs use them only while `list-connections` shows none of the user's.
- **D17 — Remote attach over SSH** (decided in Phase 5b, 2026-10-22; code in
  `Sources/MuxFinderCore/Launch/RemoteLaunch.swift`, `LaunchHelper.swift`,
  `TerminalChildRunner.swift` and `Attach/AttachCoordinator.swift`).
  - **Request:** `LaunchHost.ssh(destination:)`, `{"kind":"ssh","destination":…}`. The
    coordinator validates the destination (`Validation.sshDestination`: not empty, no
    whitespace or control characters, no leading `-`) before discovery runs
    (`invalidDestination` otherwise), and `takeRequest` refuses a request whose destination is
    not valid (`requestUnreadable`, 72), so ssh never sees one.
  - **ssh child:** the helper runs one child on the tab's terminal,
    `/usr/bin/ssh -t -o ConnectTimeout=10 -- <destination> <D3 string>`: interactive, no
    `BatchMode`, the user's configuration, keys and agent as they are, nothing that weakens
    host-key checking, so password and host-key prompts appear in the tab (ssh writes them to
    `/dev/tty`). `-t` because tmux's control mode needs a terminal (Phase 4a facts).
    `ConnectTimeout=10` is the one option the plan's argv did not name: an unreachable host
    fails in the tab within 10 s instead of the system's 75 s, inside the 20 s budget; it does
    not limit authentication.
  - **Remote script (D3, D4):** `RemoteLaunch.script` is `TmuxLocator.script`, the guard's own
    identity check (`LaunchGuard.check`, the same static text as the local check) and
    `exec "$t" -u -CC attach-session -t "$id"`; a move here sends the static
    `RemoteLaunch.moveHereScript` instead, the same with `attach-session -d` (D21). Its
    arguments are the local check's five values
    (override, id, pid, start time, creation time), each POSIX single-quoted. The check and the
    attach are one remote process, so D4's window shrinks to the `exec`. The remote check has
    no deadline of its own (a second ssh connection for a separate check would ask for a
    password twice): a hung remote server leaves the tab waiting, which the coordinator reports
    as `stillWaiting`, and closing the tab ends it.
  - **Exit statuses:** ssh exits with the remote status: the guard's 64–68, tmux's 0 after a
    detach or 1. 255 is ssh's own error, `sshFailed(class)`, the class read from ssh's
    standard error with discovery's patterns (`ErrorClassifier.sshFailureStatus`):
    `unreachable`, `authFailed`, `hostKeyProblem`, else `other` (a remote tmux killed by a
    signal also comes back as 255). ssh killed by a signal is `childSignaled`. The tab shows a
    remote wording (`LaunchFailure.explanation(for:)`: tmux missing "on the remote host", "could
    not start ssh").
  - **Standard error relay:** ssh's standard error is a pipe the helper copies to the tab as it
    arrives, keeping the first 16 KiB for the classification only (never logged). With `-t` the
    remote side's output arrives on ssh's standard output, so only ssh's own messages pass the
    relay. After ssh exits the helper drains it for at most 0.5 s, so a `ProxyCommand` that
    outlives ssh cannot hold the helper. The relay never stalls supervision (passing on
    signals, noticing the exit, that deadline; decided after the Phase 5b review): each round
    reads at most 64 KiB, and it never blocks on the tab: it writes through a descriptor of its
    own opened on the tab's terminal with `O_NONBLOCK` (a separate open file description, so
    ssh's descriptors stay blocking); a destination that is not a terminal is written only when
    `poll` reports it writable, at most `PIPE_BUF` bytes at a time (a device `poll` does not
    support, such as `/dev/null`, directly). Bytes the tab does not take wait in a 64 KiB
    buffer; while it is full the relay stops reading (its read watch disabled, a one-shot write
    watch armed), so ssh waits on the pipe as it would on a slow terminal while the loop goes
    on. What still waits at the drain deadline, and everything after a failed write (the tab
    is gone), is dropped from the tab, never from the capture.
  - **Hold:** every remote outcome ends through D14: the result first, the explanation, the
    wait for Return, then the hold until the helper is 10 s old. ssh failing fast
    (authentication, an unreachable host, a host key, a guard refusal on the remote host) never
    ends a visible launch tab inside iTerm2's 3 s window.
  - **Budget and `stillWaiting`:** a remote attach has 20 s from `launched` to a connection
    (local stays 15 s, with no `stillWaiting`). When the 20 s run out, each round also lists
    iTerm2's sessions: a launch tab closes when its helper exits, so a listed tab with no
    result means the helper still runs (ssh waiting for a password or a host-key answer, or a
    hung remote check). The attach then publishes `stillWaiting(sessionID)` once, never a
    success, and keeps polling every 1 s. `stillWaiting` is not terminal and is never
    returned: a connection that appears later goes through the usual identity check and ends
    `confirmed` (published then); a helper result ends `failed` with its failure; a launch tab
    that left the listing can no longer attach, and its helper's result is waited for 10 s
    (`closedTabResultBudget`: in the real runs iTerm2 ended ssh about 5 s after a forced
    close), else `timedOut`; 300 s after `launched` the attach ends `waitLimitReached` and
    leaves the tab to the user (an attachment made after that is found by the index). Callers
    arriving meanwhile join the flight, so a waiting password prompt never gets a second tab;
    cancelling every caller ends it `cancelled`.
  - **Identity, index, focus, detach:** the attach's identity check also requires `#{host}` to
    be the revalidated node name (D15). `AttachmentIndex` needs no remote special case: a remote
    host is its discovery node name (the remote `uname -n`) and servers, and since the default
    socket path is the same on every Mac with the same user id, the node name with the pid and
    start time is what tells two Macs' servers apart. Focus and `detach(session:on:)` work for
    remote hosts unchanged (D16).
  - **Real-run safety (`e2e-remote`):** its tmux calls on the remote host go through ssh with
    discovery's noninteractive options (`BatchMode=yes`), a static script and quoted arguments,
    and only ever name its own `muxfinder-test-*` session by id; it writes no remote file. Its
    index asks only its own launch tabs' connections. The `still waiting` step makes no login
    attempt at all: it attaches the test session through the run's own destination with
    requests that ask for the helper's test launch delay (60 s, D14 *Test launch delay*;
    honored because the run turned test mode on), so the helper waits before it would start
    ssh, its tab open with no prompt and no connection past the 20 s budget; once
    `stillWaiting` arrived the step closes that launch tab itself, forced, once it is older
    than 10 s, and the helper ends `interrupted` without having started ssh. The attach runs in
    a task the step cancels and awaits on every way out (`withAwaitedTask`), so a signal while
    its `CreateTab` is pending ends the step only after the launch tab is recorded for cleanup.
    (Until the Phase 5b review the step logged in as `nonexistent-muxfinder@<host>` so ssh
    waited at a password prompt; the review ruled that a real authentication attempt outside
    the run rules.)

- **D18 — Creating sessions and vanished sessions** (decided in Phase 6a, 2026-10-22; code in
  `Sources/MuxFinderCore/Tmux/TmuxCommands.swift`, `CreatedSession.swift`,
  `Attach/AttachCoordinator.swift` and `AttachModels.swift`).
  - **Runs:** `TmuxCommands.createSession(_:)` runs one static script, `TmuxCommands.script`
    (the D5 locator, then the steps below). Locally:
    `/bin/sh -c <script> muxfinder <override> <name> <directory> [command…]`, argv only, the
    local environment without `TMUX` and `TMUX_PANE`. Remotely:
    `/usr/bin/ssh <D6 options> -n -T -- <destination> <D3 string>` with the same arguments, so
    creation is noninteractive (`BatchMode=yes`) with the user's configuration and nothing that
    weakens host-key checking. A 12 s deadline kills the process group; output is capped at
    16 KiB. The name (`Validation.sessionName`), directory, destination and override are
    validated before any process runs (`invalidName`, `invalidDirectory`,
    `invalidDestination`, `invalidTmuxPath`). `NewSessionRequest.command` (argv, empty by
    default for the user's shell) exists for harnesses, which run `sleep` rather than a login
    shell; it is not validated, so its first word must not start with `-` (tmux would read it
    as an option), and it never comes from user input.
  - **Script:** `tmux -u has-session -t '=<name>'` (exact name, output discarded) first: a
    session with that name exits 80, `sessionExists(hasSession)`, and nothing else runs. Then
    the directory is resolved on the host: empty or `~` is `$HOME`, `~/rest` is `$HOME/rest`,
    any other path not starting with `/` is relative to `$HOME` (`~user` is not expanded). One
    that is not a directory the script can enter exits 81, `directoryMissing`, and nothing is
    created; tmux itself would start the pane in the home directory without an error
    (*Verified facts*, Phase 6a). Every `#` in the name and the directory is doubled, since
    tmux expands formats in `-s` and `-c` and `##` is its escape for `#`. Every value handed to
    tmux as an argument (the `has-session` target, the name, the directory, each command word)
    then has a trailing `;` written `\;` (`muxfinder_tmux_word`): tmux reads an argument
    ending in `;` as a command separator even as its own argv element, and `\;` is its escape
    (tmux(1); only the last character counts, so a trailing `\;` becomes `\\;`). Unescaped,
    `-c '<dir>;'` silently used `<dir>`, a name ending in `;` made the check look for the name
    without it, and command words after either became a separate tmux command (*Verified
    facts*, Phase 6a). The D3 string carries the values unchanged; the escaping happens on the
    host, after the directory check. Last,
    `exec tmux -u new-session -d -P -F <CreatedSession.format> -s <name> -c <dir> [command…]`.
    Never `-A`: an existing session is never attached, replaced, killed or changed. tmux's own
    `duplicate session` error (exit 1; a session named so after the check) is
    `sessionExists(duplicateSession)`; any other exit 1 is `tmuxFailed` with tmux's first
    error line (printable ASCII).
  - **Statuses:** 66 tmux missing and 68 usage (the guard's codes, D14), 80, 81; tmux's 0 and
    1; over ssh, 255 is ssh's own error. It is `sshFailed(class)`, nothing created, only when
    stderr shows ssh failed before the remote command could run
    (`TmuxCommands.failedBeforeRemoteCommand`): one of discovery's patterns (`SSHFailureClass`:
    unreachable, refused or timing out on connect, the name not resolving, the login refused,
    the host key unknown or changed) and none of the messages OpenSSH prints once the
    connection is up (`Timeout, server … not responding`, which discovery counts as
    unreachable; `Read from remote host`, `client_loop`, `packet_write`, `Broken pipe`,
    `Connection reset`, `ssh_dispatch_run_fatal`, `closed by remote host`, `Killed by
    signal`). `authFailed` and `hostKeyProblem` explain "Set up SSH in iTerm2 first". Any other
    255 (a lost connection, an unknown message, none) is `connectionLost`: ssh may have lost
    the exit status after the script created the session. `connectionLost`, a timeout
    (`timedOut`), a cancelled caller (`cancelled`), a success whose output is not one valid
    record (`unexpectedOutput`), and a signal or an exit status above 128 (`scriptFailed`; a
    shell's or ssh's report of a child killed by a signal) are `mayHaveCreated` and
    refresh-triggering: the session may exist, so the caller refreshes first, and no message
    says nothing was created.
  - **Output:** exactly one line of valid UTF-8 in `CreatedSession.format` (session id,
    creation time, server pid and start time, socket path, name), parsed strictly by
    `CreatedSession.parse`. `CreatedSession.attachTarget(on:)` turns it into the coordinator's
    target: the key and creation time are tmux's, the counts a new session's (one window, no
    client), which revalidation replaces.
  - **Names:** `\` is now refused by validation, since tmux stores it doubled (Phase 1's
    rules). `#` is allowed, through the doubling, and a trailing `;` through the escaping
    (directories alike). `has-session`'s target is not
    format-expanded (verified), so it takes the name as it is. Known false positive: tmux
    resolves an exact target starting with `$` as a session id, and one naming a client's
    terminal as that client's session, so such a name can be refused as existing although no
    session has it. There is no false negative: `new-session`'s duplicate check decides.
  - **`createAndAttach(_:)`:** creation through the coordinator's `SessionCreating` seam
    (`TmuxCommands()` by default), then the attach of the created target with the
    existing-attachment check (step 1b, D16) skipped. A session created a moment ago cannot
    be attached in iTerm2 yet, so none of the user's tmux connections is asked anything; the
    only iTerm2 requests are the launch's own. Revalidation still runs: it confirms the session
    and gives the node name for the identity check. A creation failure returns before
    discovery, the request file, `ensureRunning` or `CreateTab`, so it never opens a tab.
    `CreateAndAttachResult` carries the created session, the creation failure or the attach.
  - **Vanished sessions:** `AttachFailure.triggersRefresh` is true for `sessionGone`,
    `sessionChanged` and `identityMismatch` (`LaunchFailure.triggersRefresh` for the guard's 64
    and 65); `AttachResult`, `SessionCreationError` (a collision, or `mayHaveCreated`) and
    `CreateAndAttachResult` (also whenever a session was created) expose the same property, which
    the refresh engine (Phase 7) and the UI (Phase 10) read. A session killed between discovery
    and attach ends `sessionGone` at revalidation (no request, no tab) or, when it vanishes
    after revalidation, by the guard's 64; nothing recreates it, since the attach path never
    runs `new-session`.
  - **Real-run safety:** the e2e steps create only `<run session>-gone` (by the harness) and
    `<run session>-new #ü 日本;` (by `createAndAttach`; the trailing `;` exercises the escaping
    above), both `muxfinder-test-*`, their panes running `sleep 600`, so no login shell starts
    and no shell start-up or history file is touched. Each, like the main test session, is
    killed only while it is still the recorded session (`CreatedSession`), and the check is
    made by the same tmux command that kills, never by an earlier call (a server restarted
    between two calls could have given the id to a session of the user's):
    `CreatedSession.killIfUnchangedArguments`, `tmux -u if-shell -F -t '$N' <condition>
    "kill-session -t '$N'" "display-message -p muxfinder-not-this-session"`, one tmux client
    and one server connection (one ssh invocation remotely). `<condition>` compares the session
    id, creation time, server pid and start time, socket path and exact name (written as
    format literals; values that cannot be are refused before anything runs), since
    `if-shell` resolves a missing target without an error; the id is single-quoted inside the
    kill's command string, which tmux's parser reads (`$1` unquoted is an environment
    variable). tmux runs the chosen command right after `if-shell` in the same command queue
    (verified on a private server, *Verified facts*). A session whose output was lost is first
    found by its exact name. The refused ones (`-nodir`, the invalid names, the existing name)
    create nothing. Remotely they write no file: the existing directory is
    `~/Library/Application Support`, and the missing one is `~/<run session>-missing ünïcödé
    日本`. Locally the new session's directory is `dir with spaces ünïcödé 日本 #1;` in the
    run's private directory. Other check-then-change pairs of this phase need no such
    pairing: `has-session` before `new-session` is advisory (`new-session` never replaces a
    session and its own duplicate check decides, inside the same command), and the attach of a
    created session goes through the D4 guard.

- **D19 — Host configuration** (decided in Phase 7a, 2026-10-22; code in
  `Sources/MuxFinderCore/Config/`: `HostList.swift`, `HostStore.swift`,
  `SSHConfigSuggestions.swift`, and the D14 primitives moved to `PrivateStorage.swift` and
  `ExtendedACL.swift`).
  - **File:** `hosts.json` in muxFinder's folder (`HostStore`; the path is injectable). A
    JSON object, schema 1: `{"schemaVersion": 1, "hosts": [ … ]}`, each host with `id` (UUID
    string), `displayName`, `mode` (`local` or `ssh`), `sshDestination` (may be empty),
    `isEnabled`, and `tmuxPathOverride` and `iTermProfileName` only when set. Written
    pretty-printed with sorted keys and a final newline, at most 1 MiB (`maximumFileSize`);
    unknown keys are ignored when read. Another format gets another `schemaVersion`.
  - **Storage (D8, D14):** `HostStore` is an actor, so its file work runs off the main actor
    and saves of one store never interleave; the app is meant to be the only writer. Every
    load returns the file's `HostFileRevision` (no file; its bytes and any trust problem; or,
    for a file too large to read or not a regular file, what identifies it), and
    `save(_:expecting:)`, the save Settings uses (D23), first looks at the file as a load does,
    writing nothing, and refuses (`fileChanged`, carrying the revision now there) unless it is
    still the one a load returned or the last save wrote, so a change made by anything else,
    a missing file that appeared included, is never replaced without the user's say; it
    returns the new revision, and reports a `displacedFileNotKept` in its result since the
    list is in place. The unchecked `save(_:)` skips that look (tests and tools). A change
    made between the check and the publication is still kept (*Backup rule*). A save creates the
    `muxFinder` folder (0700; its parent must exist) or tightens it to 0700, removes any
    extended ACL from it and refuses the folder (`directoryHasExtendedACL`) if that fails, and
    refuses a folder that is a symbolic link, not a folder or another user's, exactly as D14
    treats `launch/`. That closes the 4a open risk (the folder kept an inherited ACL) at the
    first save; a folder first created by a launch request (`AppPaths`, 0700 only) keeps an
    inherited ACL until then, which in the app is before any attach (only an enabled host has
    sessions, and enabling one is a save). The list is written as D14 writes, to a temporary
    file (`O_CREAT|O_EXCL|O_NOFOLLOW`), ACL removed, 0600, flushed (`F_FULLFSYNC`, else
    `fsync`), then published as the *Backup rule* says.
  - **Loading never writes anything:** the folder is only checked (not a link, a folder, the
    user's), never tightened or stripped, and never created. The file is opened with
    `O_NOFOLLOW|O_NONBLOCK` and trusted only under D14's rules for files read: a regular file
    of the user's, no group or other bits, no extended ACL, at most 1 MiB. The result is
    `saved` (the list), `notSavedYet` (no file or no folder: the onboarding defaults) or
    `invalid(problem)` (the defaults, the file left untouched), where the problem is
    `unsafe(reason)`, `notJSON`, `malformed` (no integer `schemaVersion`, wrong types, missing
    fields), `newerSchemaVersion(n)`, `unsupportedSchemaVersion(n)` (zero or negative) or
    `invariantBroken(error)`. Only an unusable folder or a failed system call throws.
  - **Backup rule (a save never discards what it displaces):** before writing, a save looks
    at `hosts.json` without reading it. A symbolic link or other non-regular file there is
    never followed, read or replaced (`existingFileNotRegular`), and a file over 16 MiB
    (`maximumBackupSize`) is not replaced either (`existingFileTooLarge`); both refuse the
    save and need the user to move the file away. A regular file loses its ACL, since a
    deny-delete entry makes the swap below fail (measured: `EACCES`). The temporary file is
    then published with one `renamex_np`: `RENAME_SWAP` when a file was there, so whatever is
    at `hosts.json` at that instant lands atomically at the temporary name, or `RENAME_EXCL`
    when none was, so a file that appeared is never overwritten; `EEXIST` sends the save to
    the swap and a swap's `ENOENT` to the exclusive rename, at most 8 renames
    (`maximumPublishAttempts`). A file system without `RENAME_SWAP` fails the save with
    nothing replaced. The backup decision is about the displaced entry, never about the file
    looked at earlier: it is deleted only when it is a regular file that would load as `saved`
    and holds exactly the bytes this store last loaded (as `saved`) or wrote. Anything else
    is kept: an invalid or unsafe file, a newer schema, a valid file another program changed
    or created, every file displaced by a store that has loaded or written none, and a link
    or folder that took the name after the check. It is made 0600 without ACL and flushed
    when it is the user's regular file (best effort), then renamed, never followed or copied,
    to `hosts.backup-<UTC yyyyMMddTHHmmssZ>.json`, or with `-2`, `-3`, … when that name
    exists (`RENAME_EXCL`, so a backup is never replaced). If no name is free or that rename
    fails, the entry stays under its hidden temporary name, never deleted, and the save
    throws `displacedFileNotKept` with that name although the new list is in place. A save
    that fails before publication removes its temporary file. Tests change the file between
    the check and the publication through the store's `beforePublishing` hook.
  - **Invariants (`HostList`):** ids are unique; at most one host is in `local` mode ("This
    Mac"); an enabled SSH host's destination passes `Validation.sshDestination` (not empty, no
    whitespace or control characters, no leading `-`). A disabled SSH host may hold any
    destination, so incomplete entries are kept; other fields are validated where they are
    used (D5 for the override). Each change (`add`, `update`, `remove`, `setEnabled`,
    `makeThisMac`) checks its result and throws a typed `HostListError` without changing the
    list. A `HostList` cannot be built invalid; `save` checks again (`invalidList`) and refuses
    a list over 1 MiB (`listTooLarge`), both before touching the disk.
  - **This Mac switch:** `makeThisMac(id:)` on the current This Mac changes nothing.
    Otherwise that host becomes local and enabled (local discovery needs no destination), and
    the previous This Mac goes back to SSH mode, disabled, its destination kept, so nothing
    starts connecting to it over SSH until the user turns it on again. This Mac can also be
    removed, or edited back to SSH (then disabled or with a valid destination).
  - **Onboarding defaults:** Saturno, Neptuno and Sirio, in that order: SSH, empty
    destination, disabled, no override or profile, none of them This Mac, fresh ids on every
    call. No user name, address or reachability is assumed.
  - **SSH config suggestions (`SSHConfigSuggestions`):** read-only; it opens files for
    reading and writes nothing, under `~/.ssh` or anywhere else. It collects `Host` names
    from `~/.ssh/config` (the home directory is injectable) and its includes, following
    OpenSSH's `readconf.c`. Keywords are case-insensitive, with `Keyword value`,
    `Keyword=value` and `Keyword = value` forms. Arguments are split like `argv_split`:
    single or double quotes, `\` escaping a quote, a backslash or (unquoted) a space, and an
    unquoted `#` at the start of a word ending the line; a line with an unterminated quote
    is skipped. Each `Host` word is a suggestion unless it contains `*` or `?`, starts with
    `!`, or fails `Validation.sshDestination`. `Include` takes several paths, each a glob(3)
    pattern expanded in lexical order: `~/` is the home directory, a relative path is under
    `~/.ssh/`, and `~user` is not expanded. Includes are followed wherever they appear, inside
    `Host` and `Match` blocks too, down to depth 16 (OpenSSH's limit; the user's config is
    depth 0, deeper files are not read). Each file, by device and inode with links followed,
    is read once, which ends cycles. Missing, unreadable and non-regular files, and files over
    1 MiB, are skipped; at most 256 files are read. Names are de-duplicated in first-seen
    order. They are suggestions only: the destination is stored as the user picks or types
    it, and OpenSSH resolves it.
  - **Probe:** `muxfinder-probe hosts show [--config <path>]` prints the file, the state, the
    problem's code and message, the hosts and This Mac's id; `hosts suggestions` prints
    `{"suggestions": [ … ]}`. Both are read-only: no folder or file is created, no ssh runs
    and iTerm2 is not contacted.

- **D20 — Refresh engine** (decided in Phase 7b, 2026-10-22; code in
  `Sources/MuxFinderCore/Refresh/`: `RefreshCoordinator.swift`, `HostSnapshot.swift`,
  `RefreshSystemEvents.swift`).
  - **Actor and seams:** `RefreshCoordinator` is an actor built from a `HostList` (its enabled
    hosts, in list order). Probes and attachment checks run in detached tasks, never on the
    main actor. Its seams are the attach coordinator's: discovery is `HostDiscovering`
    (`DiscoveryProbe` in production, so This Mac runs `/bin/sh` and never ssh, D3/D6), time
    is `AttachClock` (monotonic instants for schedules, wall-clock dates for timestamps), and
    the attachment index is `AttachmentIndexing` (`AttachmentIndex` conforms; `nil` never
    checks). The app reads `updates()` (D22): an `AsyncStream<RefreshState>` per subscriber,
    the current state first, then one after every change (newest only by default), finished
    by `stop()`. Lifecycle: created idle (explicit requests and `refreshOnce` run, nothing is
    scheduled), `start()` begins the cadence, `stop()` ends everything for good.
  - **Slots and single flight:** at most 3 probes run at once (`Configuration
    .concurrencyLimit`), first come first served, so a slow host holds one slot and never
    delays the others; a retired probe (below) keeps its slot until its task has ended, so the
    limit counts processes really running. A host has at most one probe running, a retired one
    included: a host whose retired probe has not ended waits in the queue without holding up
    the hosts behind it, and starts as soon as that probe ends, with no further request. A
    request while the host's attempt runs marks **one follow-up** attempt, started when it
    ends; more requests during that attempt change nothing; a request while the host waits for
    a slot (or for its retired probe) joins the queued attempt. Joining the running attempt instead was rejected: its result
    may predate the reason for the request (a session just created, D18 `mayHaveCreated`; a
    network change), and "every request is answered by an attempt that started after it" is
    what callers need. Overlapping requests cost at most two attempts.
  - **Generations and revisions:** attempts are numbered from one global generation counter
    and record their host's configuration revision. `configRevision` increases whenever an
    enabled host is added, removed, or changes **mode, destination or tmux override** (what
    discovery runs); a renamed host or a new profile keeps its snapshot and its attempt in
    flight, since discovery is the same. A discovery change resets the host (snapshot
    `notChecked` under the new revision), and once started refreshes it at once (as soon as its
    retired probe has ended). Cancelling an
    attempt (sleep, a configuration change, removal, `stop()`) **retires** it. A result is
    applied only when its attempt is not retired, is still its host's current attempt, ran
    under the host's current revision and is newer than the last applied generation;
    anything else is counted in `discardedResults` and never published.
  - **Cadence and backoff:** `start()` refreshes every host at once; then each host's next
    attempt is due one step after its last attempt **ended**: 5 min in the background, 15 s
    while the popover is visible (`popoverDidOpen()` also refreshes every host at once;
    `popoverDidClose()` reschedules from the last end and cancels the attachment check, below).
    In the background only, a host whose last attempt failed waits the backoff step for its
    consecutive failures instead of 5 min: 30 s, 1 min, 2 min, 5 min, then 15 min for every
    later failure; a success resets the count. The visible cadence and every explicit request (`retry(_:)`, `retryAll()`, popover
    opening, wake, network change) ignore backoff; their failures still count. Successes are
    `ok` and `noServer`; every other status (including `tmuxNotFound`) is a failure.
  - **Sleep, wake, network:** `systemWillSleep()` retires every attempt, cancels every timer,
    the pending wake refresh and the attachment check, and returns once all of those tasks
    have ended; the process runner kills each probe's process group before its cancelled run
    returns (Phase 1), so no probe process survives it. Sleep and `stop()` also end a
    `refreshOnce` round in progress: each of their cancellations opens a new work epoch, and a
    round submits a host request or its attachment check only while the epoch it began in is
    current, so a round their cancellation resumes submits nothing more. While asleep nothing
    scheduled runs (explicit requests, a round begun while asleep included, still do: the user
    is there). `systemDidWake()` refreshes every host after 5 s (`wakeDelay`).
    `networkPathChanged()` refreshes the hosts whose last attempt failed, at once; it is
    ignored while asleep or while the wake refresh is pending.
    `RefreshSystemEvents` adapts `NSWorkspace` sleep and wake notifications (from a
    notification center the app passes in, since MuxFinderCore does not link AppKit) and an
    `NWPathMonitor` (its first update and unchanged paths not forwarded), feeding one ordered
    stream so a wake never overtakes its sleep. Its `start()` and `stop()` stay one lifecycle
    even when they race: each opens a new generation; a start claims the stream and its reader
    under the lock (so a stop finishes that stream and waits for that reader), then installs
    its observers and monitor only if its generation is still current, and otherwise removes
    them itself before returning; events are forwarded only from the current generation's
    observers and monitor. The app wires it to `NSWorkspace`'s notification center (D22).
  - **Snapshots (`HostSnapshot`):** per enabled host: the config and its revision, freshness
    (`notChecked`, `live`, `stale`), the sessions, the last outcome (`sessionsListed`,
    `noServer`, or `failed` with the classified `HostStatus`), `lastAttempt` and `lastSuccess`
    (wall clock, when the attempt ended), consecutive failures, the node name of the last
    success, `isRefreshing` and `nextRefreshAt` (monotonic). A failure after a success keeps
    that success's sessions and marks them `stale`, never live; a failure with no success
    before is `stale` with no sessions. Session identity is the D4 `SessionKey`, which holds
    the host id, so the same name (even the same id and server) on two hosts stays two
    entries.
  - **Attachments (D16):** a check runs only while the popover is visible (after each applied
    result, one at a time with at most one follow-up) or once at the end of
    `refreshOnce(includeAttachments: true)`; never in the background. Closing the popover
    cancels the automatic check in progress and drops its follow-up (one a `refreshOnce`
    caller waits for runs on). The cancelled check is retired at once: its result is
    discarded, and a check started when the popover reopens runs at once instead of waiting
    for it (`stop()` still waits for its task). Cancelling stops its iTerm2 contact: the index
    asks no connection once cancelled, no request leaves a cancelled task, and its connection
    attempt, left without callers, stops before the cookie or the connection (D13). So once
    the popover has closed no cookie request, connection or identity question starts; one
    already on the wire may finish, and its answer starts nothing. Hosts are given as their
    last success's node name and servers (stale hosts too). Each session gets the connections
    the snapshot maps to its key. The failure policy follows D16: iTerm2 not running is `iTermNotRunning` (nothing
    attached); any other listing failure is `failed(error)`: every session's attachments are
    cleared (an older check's are never kept) and the UI must read that as unknown, not "not
    open here"; connections without a usable answer are unmapped counts inside a `checked`
    result.
  - **Probe:** `muxfinder-probe refresh --once [--config <path>] [--attachments]` loads the
    list through `HostStore.load()` (read-only, `--config` as for `hosts show`), runs
    `refreshOnce` on an idle coordinator over the real `DiscoveryProbe`, prints the state as
    JSON (load state, configuration revision, attachment check, every host with its outcome,
    timestamps and sessions) and stops it. Without `--attachments` iTerm2 is never contacted;
    with it the check sends the read-only identity `display-message` to every iTerm2 tmux
    connection, the user's included (the 5a caution applies).

- **D21 — Move here** (decided in Phase 6b, 2026-10-22; code in
  `Sources/MuxFinderCore/Attach/AttachCoordinator.swift`, `AttachModels.swift`,
  `AttachmentIndex.swift`, and
  `Launch/LaunchModels.swift`, `LaunchGuard.swift`, `RemoteLaunch.swift`, `LaunchHelper.swift`,
  `LaunchArgvDigest.swift`).
  - **API:** `AttachCoordinator.moveHere(_:confirmation:)` with
    `MoveHereConfirmation.detachOtherClients(of: SessionKey)`: one case, no default, naming the
    session. A confirmation for any other key fails `moveHereNotConfirmed` before anything runs
    (no discovery, no iTerm2 request, no file, no state published). Otherwise it is an attach
    (D15, D17: revalidation, request, `ensureRunning`, launch tab, confirmation by connection
    within 15 s locally or 20 s and `stillWaiting` remotely, identity check, activation, the
    10 s minimum tab age before any end the coordinator causes, the same `AttachResult` and
    typed failures) whose request asks for `attach-session -d`. Rejected: a defaulted `Bool`
    (a call could move a session without saying so) and a confirmation without a key (one
    given for one session could move another). Phase 10 puts the user's confirmation dialog in
    front of it.
  - **Request and helper:** `LaunchRequest.detachOtherClients` (`Bool?`) is written only as
    `true`, by a move here; an attach request is without it, byte for byte what earlier builds
    wrote, and a request without it (or with `false`) is a normal attach; any other value makes
    the file unreadable (72). Locally the attach child becomes
    `<tmux> -u -CC attach-session -d -t <id>` (the check is unchanged). Remotely the D3 string
    carries a second static script, `RemoteLaunch.moveHereScript` (`TmuxLocator.script`,
    `LaunchGuard.check`, `exec "$t" -u -CC attach-session -d -t "$id"`), with the same five
    quoted check values: the helper picks the constant, so nothing at run time selects
    anything in the remote shell. A validated token argument was rejected because it would
    change the five-argument contract of the check shared with the local guard.
    `attach(_:)` and `createAndAttach(_:)` never set the field.
  - **What `-d` does:** tmux detaches every other client of that one session, wherever it runs,
    as the launch tab's client attaches; a plain control client gets `%exit` and exits 0
    (verified on a private server and on Saturno before the e2e steps). Never
    `detach-client -a` (server-wide) or `-s` (it would include this attach).
  - **Already attached in this Mac's iTerm2:** a move here always runs the existing-attachment
    check (D16; the standard index when the coordinator's check is `.off`). When this Mac's
    iTerm2 shows the session, it fails `alreadyAttachedHere(connectionID:owningSessionID:)`
    (the first listed attachment) and runs, writes, opens and activates nothing: `-d` would
    detach that attachment too, and detaching and reattaching inside the same iTerm2 is not a
    move. The UI offers to bring it forward (`attach(_:)` focuses it) or detach it
    (`detach(connectionID:gatewaySessionID:launchID:)` with those ids, or
    `detach(session:on:)`) first. iTerm2 not running means nothing is attached here, so the
    launch goes on; a listing failure is `attachmentCheckFailed`, nothing opened.
  - **Connections that cannot be ruled out** (decided after the Phase 6b review, 2026-10-22):
    unlike an attach, a move here also refuses when a connection in this Mac's iTerm2 may show
    the session, since `-d` would detach it and it may be this Mac's own attachment.
    `AttachmentSnapshot.unresolvedConnections(for:)` lists every `stale` connection (no id or
    owner in the listing, a failed request including `tmuxConnectionNotOwned`, an unreadable
    answer, no answer within 3 s), every `nonUTF8` one, and every `unknown` or `ambiguous` one
    whose exact answer names the session's server and session (only its host name matched no
    host, as after a host name change). When any exists the move here fails
    `possiblyAttachedHere(unresolved:)` and runs, writes, opens and activates nothing; the
    result carries the check's counts. An exact answer naming another server or session rules
    its connection out (`-d` detaches only clients of that session), and so does an index
    filter (`excluded` connections are never asked; only `e2e-local`'s index has one, admitting
    its own launch tabs' connections). An attach keeps D16's policy: unmapped connections never
    block it. Rejected: refusing on every `unknown` connection, which would block every move
    here while a session of another host is attached in iTerm2 (the check runs the index over
    the target's host alone).
  - **Single flight across kinds, and launches that may still attach** (the second part
    decided after the Phase 6b review, 2026-10-22): callers of the same kind share one live
    launch (D15). A caller never joins a live launch of the other kind (an attach must never
    end up detaching others, a move here never end up not doing so), and never starts while a
    conflicting launch of the session may still attach it in this Mac's iTerm2: for a move
    here every other launch conflicts (its `-d` would detach that launch's attachment, or that
    launch's `-d` this one's), for an attach every move here; an attach never waits for
    another attach (D15). A launch is pending from its start until its run ends settled: a
    connection found, the helper's result taken, no `CreateTab` sent, or the withdrawal
    removed the request (`discardRequest` returned `true`; the first unlink wins, D14, so no
    helper can use it). A launch whose callers were all cancelled still sends its `CreateTab`
    (D15) and its helper may take the request before the withdrawal, so it can end unsettled,
    as can a timed-out one. A conflicting caller polls every `pollInterval` on the
    coordinator's clock: a running launch is waited out (it ends within its own budgets); for
    an ended one it looks for proof that it can no longer attach: the helper's result (the
    helper ended), a connection owned by its launch tab (it attached, its `-d` ran, and the
    check now sees it), or its launch tab gone from iTerm2 (or iTerm2 not running) for
    `closedTabResultBudget` (10 s, D17) without a result. Proof forgets the launch; without it
    within the confirmation budget (15 s, 20 s for a remote launch) from when the caller first
    saw the launch ended, the call fails `earlierLaunchPending` and runs nothing, and the
    launch stays pending for the next call. Once nothing conflicts, the caller starts its own
    launch, whose check sees the other's outcome (an attach after a move here focuses it; a
    move here after an attach ends `alreadyAttachedHere`). A caller cancelled while it waits
    gets `cancelled` and starts nothing. Only a conflicting caller looks for proof, so a
    pending launch costs nothing until then. Rejected: holding the ended launch's own run
    until it settles, which would make its cancelled callers wait and change an attach's
    timing.
  - **Failures:** `moveHereNotConfirmed`, `alreadyAttachedHere`, `possiblyAttachedHere` and
    `earlierLaunchPending` are not refresh-triggering; every other failure, state sequence and
    request withdrawal is the attach's (tested side by side). Diagnostics say "move here"
    instead of "attach".
  - **Test mode:** the argv digest gains `attachChild` (D14): the attach child's argv digested
    like the helper's own, and `detachesOtherClients`.
  - **Real-run safety (the e2e `move here` step):** on the run's own session, with nothing
    attached, the harness starts a plain control client (`BackgroundControlClient`:
    `tmux -u -C attach-session -t '=<exact generated name>'`, argv only, its own process group
    with default signal dispositions and only descriptors 0–2, stdin a pipe the harness holds
    open, stdout and stderr drained by threads; stdout is only scanned for a line starting
    `%exit` and never kept, stderr keeps at most 200 bytes of printable ASCII for a failure
    message). Remotely it is `/usr/bin/ssh` with discovery's options plus `ControlMaster=no`,
    `ControlPath=none` and `-T` (no `-n`: stdin is the pipe) and `RemoteTestTmux`'s static D3
    script, so no file is written there and no shared ssh master is created or used. The step
    checks that the plain client is the session's only client (locally by its pid), that a
    move here confirmed for another key runs nothing, that the confirmed move here is
    confirmed with `-d` in the digest's exact attach-child argv, that the plain client printed
    `%exit` and exited by itself within 10 s, that the session's only client is then another
    control client, and, 2 s later, that the launch tab still owns its connection, which still
    shows the session with both tmux tabs; then a clean detach by connection. On any failure
    the step ends the plain client (stdin closed, up to 3 s, then SIGTERM and 2 s later SIGKILL
    to its group, which stays pinned until it is reaped), and cleanup does the same first.

- **D22 — Menu bar app** (decided in Phase 8, 2026-10-22; code in `Sources/MuxFinderUI/` and
  `Sources/MuxFinderApp/`).
  - **Layers:** the `MuxFinderUI` library holds the model, the popover's content and views,
    and the preview fixtures; `Tests/MuxFinderUITests/` imports it. The `MuxFinderApp`
    executable keeps only the entry point, the `MenuBarExtra(.window)` scene (SF Symbol
    `terminal`) and two app delegates. `PopoverContent` is a pure value computed from the
    engine's `RefreshState`, the search text, per-session activities, the selection and
    `now`; every displayed rule lives there and is tested without SwiftUI.
  - **Model and engine:** `AppModel` (`@Observable @MainActor`) runs on an `AppEnvironment`
    (host loading, engine and system-events factories, wall clock, terminate), so tests pass
    fakes. `start()` loads the list with `HostStore.load()` (never writes; an unusable folder
    gives an empty list and a notice), builds the `RefreshCoordinator` for it
    (`DiscoveryProbe`; `AttachmentIndex` over one shared `ITerm2APIClient`), subscribes to
    `updates()`, starts `RefreshSystemEvents` on `NSWorkspace`'s notification center, then
    `start()`s the engine. Popover open/close, "Refresh" and "Retry" go through one queue read
    by one task, so the engine sees them in order; once `shutdown()` has begun, requests still
    queued are dropped, so a popover opening queued just before quitting starts nothing in the
    engine about to stop. Relative times are measured against `now`, updated with every
    engine state and when the popover opens.
  - **What the popover shows:** host status "Checking…" until an attempt ends, then "This
    Mac" for the local host after any success, "Reachable" (SSH, sessions) or "No sessions"
    (SSH, no server or none), and for failures "Unreachable", "Sign-in needed", "Host key
    problem", "tmux not found", or "Check failed" (`probeError`) with a one-line explanation
    and "Retry". A refresh in progress keeps the last label and adds a spinner. The caption is
    "Last checked <time>" from `lastSuccess` ("Not reached yet" without one). A stale host's
    sessions read "Last seen <time> · not live"; live ones "4 windows · 1 client" or
    "2 windows · Detached". "Open in iTerm2 here" comes only from the attachment index; a
    failed check shows a notice and no badge, never "not open here". Only enabled hosts are
    listed; none gives "No hosts turned on". Search keeps a host whose name matches with all
    its sessions, else only matching sessions (case, diacritics and surrounding spaces
    ignored). Per-session activity ("Opening…", "Waiting for iTerm2…", "Waiting for you in
    iTerm2", a failure with "Retry") is model state; `SessionActivity.init?(_ state:)` maps
    `AttachState` for Phase 10.
  - **iTerm2 and its cookie:** nothing contacts iTerm2 at launch. The popover's only iTerm2
    requests are the engine's attachment checks, which run only while the popover is
    visible and are cancelled when it closes (D20); the Settings window adds one, the profile
    list, asked only when its window opens while iTerm2 runs (D23). The client checks that
    iTerm2 runs before it asks for the cookie (D13). So the cookie is requested when the
    popover or the Settings window opens while iTerm2 runs, and (Phase 10) on an attach; never
    at launch, once the popover has closed (a cookie request, connection or identity question
    the check had not made by then is never made), or while iTerm2 is not running. Tested
    through the real `ITerm2APIClient` with counting and gated cookie providers, a fake
    running check and fake connectors.
  - **Popover visibility and keys:** `PopoverWindowBridge` follows the menu bar extra's
    window: open while it is visible and not occluded, rechecked on becoming or resigning key,
    occlusion changes and closing (repeats ignored). A local key-down monitor for that window
    turns ↑/↓, Return, Esc, ⌘F, ⌘R, ⌘N and ⌘, (`PopoverKey`) into `AppModel.handle(_:)`
    before the search field sees them (not while an input method composes); Esc closes the
    window. The arrows move through the listed rows only. No unattended run can open the real
    popover (no UI scripting), so this glue is checked by the model's tests and by hand only.
  - **Placeholders:** opening a session and "New session" (Phase 10) only record a
    `DeferredIntent`: nothing is attached or launched. "Settings" and ⌘, open the Settings
    window (D23). "Retry" on a session failure clears it and refreshes the session's host.
  - **Quit:** "Quit", SIGTERM and SIGINT go through `AppTermination.request()`, which calls
    `terminate(_:)` from a run-loop block. `applicationShouldTerminate` answers
    `.terminateLater`, runs `AppModel.shutdown()` (Settings' `shutdown()`, which refuses new
    work and cancels and awaits its probes and window opening, D23; the queue, dropping
    requests not yet handed over; the system events adapter; then the engine, whose `stop()`
    cancels any attachment check and kills any probe's process group) and replies, so the process
    exits 0; a 5 s deadline replies anyway. Calling `terminate(_:)` from a main-queue block or a
    main-actor task never returned: AppKit waits for the reply in a nested run loop, which
    cannot drain the main queue while one of its blocks runs, and the shutdown task needs it.
    Quitting detaches nothing, kills no session and sends iTerm2 nothing.
  - **Preview fixtures:** `--preview-fixtures` runs a plain `NSApplication` (no SwiftUI scene,
    so no status item, and nothing recorded for one; no engine, host list or iTerm2) with one
    normal window of every state in `PreviewFixtures.all` (with `--preview-gallery settings`,
    `SettingsFixtures.all` instead, D23): synthetic names, `*.example`
    destinations, a fake socket path, a fixed `now`. It is shown without activating the app
    and its window number is printed for `screencapture -l`. `--appearance light|dark` sets
    `NSApp.appearance` only. `--preview-snapshot <file.png>` also draws the window's content
    view into that PNG from inside the app (`cacheDisplay`) and quits; Phase 8's screenshots
    were made so, because the screen was locked and the display asleep and both
    `screencapture -l` and a single-window ScreenCaptureKit capture failed. Such a render
    shows AppKit spinners as a still frame. The same fixtures back the SwiftUI previews.
  - **Bundle:** `scripts/build-app.sh` builds release for `arm64-apple-macosx14.0` (checked
    with `lipo`) and assembles `build/muxFinder.app`: `Contents/MacOS/muxFinder` and, next to
    it where `LaunchHelperPath.locate()` looks, `Contents/MacOS/muxfinder-launch`; D7's
    `Info.plist` keys; `PkgInfo`. Every bundle value is a constant of the script. It signs the
    helper, then the app with the apple-events entitlement, both with hardened runtime and
    `--timestamp=none`, choosing the first "Apple Development" identity by its SHA-1 hash
    (codesign did not match this Mac's identity by its name, which holds "í"), or
    `MUXFINDER_SIGN_IDENTITY`, else ad hoc with D7's warning; then `codesign --verify --deep
    --strict`. `build/` is git-ignored.
  - **Menu bar item check:** on macOS 26 and later the item is drawn outside the app's
    process: `CGWindowListCopyWindowInfo` lists no window under the app's pid (its
    `NSStatusBarWindow`s carry numbers that are not window-server ids), unlike older apps'
    items. So `--report-menu-bar-item` prints, two seconds after launch, the app's own
    status-bar-level windows with visibility and frames (read-only).
  - **The app's own defaults:** AppKit records status-item state in the
    `cc.carpio.muxfinder` defaults domain; a hidden item (as a preview with an un-inserted
    `MenuBarExtra` once made) is stored as `NSStatusItem VisibleCC Item-0 = 0`. That is why
    preview mode creates no status item. A normal run that changes nothing wrote nothing.

- **D23 — Settings window** (decided in Phase 9a, 2026-10-22; code in
  `Sources/MuxFinderUI/Model/`: `SettingsModel.swift`, `SettingsEnvironment.swift`,
  `HostDraft.swift`, `SettingsResults.swift`, `LoginItem.swift`, `FixIt.swift`,
  `DiagnosticsReport.swift`; `Views/Settings/`; `Preview/SettingsFixtures.swift`,
  `Preview/SettingsGallery.swift`).
  - **Window:** one AppKit window (`SettingsWindowController.shared`, "muxFinder settings",
    720×740 points, at least 640×520, resizable, not restorable, no saved frame, no tabbing)
    hosting `SettingsView` with the Hosts, General and Diagnostics tabs. It is made on first
    use and reused: `AppModel.openSettings()` (the footer's "Settings", ⌘, in the popover, the
    "Open Settings" placeholder button) calls `AppEnvironment.presentSettings`, which calls
    `NSApp.activate()` (an accessory app stays behind the active app otherwise) and brings the
    window to the front. Opening a closed window calls `SettingsModel.windowDidOpen()`, which
    runs the opening (login item status, host list, then profiles, suggestions and log) in a
    task the model owns; closing it calls `windowDidClose()`: the opening is cancelled (with
    the profile request inside it, so the iTerm2 client stops before its next contact, and a
    cancelled `ITerm2ProfileSource` asks nothing), late results are dropped by window
    generation and nothing more starts, probes are cancelled and dialogs dropped (unsaved
    edits are lost, since the next opening reloads the list); becoming key reads the login
    item status again. Quitting runs `SettingsModel.shutdown()` from `AppModel.shutdown()`
    (D22): no opening, load, profile request, probe or save starts any more, the opening and
    every probe still running (a replaced one too) are cancelled, and it returns only once
    all have ended, so no probe's process group outlives the app. The window
    handles ⌘X, ⌘C, ⌘V, ⌘A, ⌘Z, ⇧⌘Z and ⌘W itself (`SettingsWindow.performKeyEquivalent`),
    since a menu bar app shows no main menu. Rejected: a SwiftUI `Settings` scene, which an
    accessory menu bar app cannot reliably open and bring forward, and which preview mode's
    plain `NSApplication` does not have.
  - **Seams (`SettingsEnvironment`):** `HostListPersisting` (`HostStore`, the same instance the
    app loads with, so saves keep D19's rules; `load()` gives the file's revision and
    `save(_:expecting:)` takes it back), `HostDiscovering` (`DiscoveryProbe`) for
    Detect and Test connection, `ITerm2ProfileListing` (`ITerm2ProfileSource` over the shared
    `ITerm2APIClient`: `isRunning()` first, then `ListProfiles` for the names only; never
    `ensureRunning()`, so iTerm2 is never launched to fill the picker), SSH suggestions
    (`SSHConfigSuggestions`, read off the main actor), `LoginItemControlling`
    (`SystemLoginItem`, `SMAppService.mainApp`), the `DiagnosticsLog` (one per app, shared with
    the iTerm2 client, which records its connections in it), the pasteboard, `openURL`, the
    versions and the clock. `AppEnvironment` gained `openURL`, `presentSettings`, `settings`
    and `diagnostics`. Tests pass fakes for every one; saves are also tested through a real
    `HostStore` in a private folder.
  - **Editing:** the editor works on a `HostDraft` with explicit "Save" and "Revert" (no
    autosave, so a half-typed destination is never stored). Inline rules (`HostDraftIssues`,
    sentence case): a name is required, at most 50 characters, without control characters
    and not another host's (ignoring case); an SSH destination is empty or passes
    `Validation.sshDestination`, and is required while the host is on; an SSH host turns on
    only with a valid destination (`setEnabled(_:)` refuses and says why; the toggle is
    disabled); the tmux path is empty (automatic) or passes `Validation.executablePath`; a
    profile has no control characters. Values are trimmed, and an empty path or profile is
    stored as none. A profile iTerm2 does not list is a warning, not an error. Choosing This
    Mac turns the host on, and saving applies `makeThisMac(id:)`, so the previous This Mac
    becomes an SSH host, turned off (the editor says so before the save). A new host is added
    as SSH and off, then made This Mac if chosen, then updated, all on a copy that `HostList`
    checks before the store sees it. Selecting another host with unsaved changes asks
    ("Discard changes" or "Keep editing"), and so does removing ("Remove"). Editing stays
    enabled while a removal saves (decided: preserve rather than disable): when the save ends,
    the editor moves to the next host only if it still shows the removed one, so a host
    selected or edited meanwhile keeps its selection and draft. A save updates the
    popover's load status to `saved` and hands the list to the engine
    (`RefreshCoordinator.setHosts(_:)`, through `AppModel`'s request queue). A save that put
    the list in place but could not keep the displaced file (`displacedFileNotKept`) counts as
    saved, with its error shown.
  - **Changed file:** every save and removal expects the revision the list was loaded with or
    last saved as (`HostStore.save(_:expecting:)`, D19). If another program changed the file
    since, a valid or missing file included (one that appeared counts as changed), the store
    writes nothing and refuses; Settings keeps the draft as it was, shows "The host list file
    changed after muxFinder loaded it, so nothing was saved. Choose Reload or Replace." and a
    banner with "Reload" (load the file as it is now; a now unusable file then gets its own
    Replace flow) and "Replace…" ("Replace the host list file?", which saves the list shown
    over the file as the refused save found it). Until one is chosen nothing is editable or
    saved. A save after Replace still refuses a file that changed again, and `HostStore`
    keeps the replaced file as a backup.
  - **Unusable file:** an `invalid` load state is shown in a banner with its problem, and
    nothing is editable or saved (the save path refuses too) until the user confirms "Replace
    the host list file?" (`confirmReplaceFile()`). Even then nothing is written until a save,
    which expects that same unusable file (one changed again refuses the save as above), and
    `HostStore` keeps the displaced file as a backup, since it never loaded it as `saved`
    (D19). An unreadable folder disables editing and offers "Try again". The examples
    (`notSavedYet`) are editable, with a note that nothing is saved until a change.
  - **Detect and Test connection:** both run discovery on the draft as it stands, never on the
    saved file: Detect without the tmux path, filling the field with `ProbeReport.tmuxPath`
    ("Found tmux 3.8 at …"); Test connection with it, showing `HostStatusLabel` and
    `HostProblemText` exactly as the popover does (This Mac, Reachable or No sessions for an
    answer, with the session count and tmux version; never a session name). A newer request,
    another selection, a change of mode, destination or tmux path, closing the window or
    quitting cancels the running probe (the runner kills its process group) and drops its
    result by generation.
  - **Launch at login:** `LoginItemStatus` maps every `SMAppService.Status` (`@unknown
    default` to `unknown(raw)`). The toggle registers or unregisters, then reads the status
    again; an error is shown ("muxFinder couldn't turn on launch at login. …"), never
    swallowed. `requiresApproval` shows the toggle on with a fix-it that opens Login Items
    (`SMAppService.openSystemSettingsLoginItems()`); `notFound` says that launch at login works
    for the app installed in /Applications (or ~/Applications) and opened from there.
    Unattended runs only read the status: `muxFinder --report-login-item-status` prints it and
    exits before any window, menu bar item, host list or iTerm2 contact. Registering changes
    the user's login items, so the real round trip is owed to the user.
  - **Diagnostics:** the tab lists the `DiagnosticsLog` entries newest first (host ids shown as
    display names) and the last iTerm2 check's problem with its fix-it. "Copy diagnostics"
    (`DiagnosticsReport`) is plain text: muxFinder's and macOS's versions, the launch-at-login
    status, the load state, the iTerm2 check (kind, time, counts), each host by display name
    and id with its mode, on or off, whether a tmux path or profile is set (never which), its
    popover label and status kind, times, session count and failures in a row, then the log
    (ISO 8601, UTC). Decided: destinations, tmux paths, profile names, node names and session
    names are the user's and never appear, and neither does a failed probe's message, which
    may quote ssh or tmux output naming the destination; a log host id no host has is shown
    as the id, anything else as "unknown". Settings records its own events (category
    `settings`: loads, saves, removals, connection tests, detections, launch-at-login changes)
    with host ids and outcome kinds only; the app model records the load at launch.
  - **Fix-its (`FixIt`):** `automationDenied` (also inside `notSent`, and in attach failures
    that carry it) gets "Open Automation settings", which opens
    `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation` through
    `openURL`; `apiDisabled` gets "How to turn it on", an inline explanation (iTerm2 ›
    Settings, General › Magic, "Enable Python API") that never opens iTerm2; launch at login
    waiting for approval gets "Open Login Items settings". The popover's iTerm2-check notice
    and session failures (`SessionActivity.failed(message:fixIt:)`), and Settings' profile
    note and Diagnostics tab show them. The Automation URL was not opened in an unattended run.
  - **Preview fixtures:** `--preview-fixtures --preview-gallery settings` shows
    `SettingsFixtures.all` (11 states) in the same plain preview window, with the same
    `--appearance` and `--preview-snapshot` flags; screenshots
    `docs/screenshots/settings-states-{light,dark}.png`. Synthetic data only (`*.example`
    destinations, invented profile and suggestion names, a fixed log).

## Verified facts (planning session, 2026-10-21)

- This Mac is **Neptuno** (`neptuno-m4`), macOS 27.2 arm64, Xcode 27.1, Swift 6.4, tmux 3.8
  at `/opt/homebrew/bin/tmux`, no tmux server running. `swift format` is available; SwiftLint
  is not.
- **Saturno** (`ssh saturno-m4`, via Tailscale MagicDNS; no `Host` block in `~/.ssh/config`)
  works with BatchMode. It has user `ccarpio`, `/bin/zsh`, tmux 3.8 at `/opt/homebrew/bin`,
  noninteractive `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, and no tmux server running.
- **Sirio** (`sirio-m5`) was **offline**. Treat everything Sirio-specific as unverified.
- **iTerm2 3.7.6** with the API server enabled (`EnableAPIServer = 1`). Its Python runtime
  holds the reference module at
  `~/Library/Application Support/iTerm2/iterm2env-3.14/versions/3.14.0/lib/python3.14/site-packages/iterm2/`
  (version 2.11). The interpreter is
  `~/Library/Application Support/iTerm2/iterm2env-3.14/versions/3.14.0/bin/python3`. Run it
  only with `-I`, and only for dev-time fixture generation and protocol lookups.
- **Cookie:** `osascript -e 'tell application "iTerm2" to request cookie and key for app named
  "X"'` returns `"<cookie> <key>"`. When run from a process descended from iTerm2 (this shell,
  `swift test`, `muxfinder-probe`, an app binary started from the shell) **no prompt appears**.
  `muxFinder.app` launched through LaunchServices has its own identity and will get a one-time
  macOS Automation prompt. An unattended run cannot answer it.
- **Handshake that works** (spike: `docs/spikes/iterm2-socket-spike.swift`):
  `GET / HTTP/1.1` with `Host: localhost`, `Upgrade: websocket`, `Connection: Upgrade`,
  `Sec-WebSocket-Key`, `Sec-WebSocket-Version: 13`, `Sec-WebSocket-Protocol: api.iterm2.com`,
  `Origin: ws://localhost/`, `x-iterm2-library-version: python 2.11`,
  `x-iterm2-disable-auth-ui: true`, `x-iterm2-cookie`, `x-iterm2-key`,
  `x-iterm2-advisory-name`. The reply is `101 Switching Protocols`, and its headers can span
  several reads. Binary frames carry protobuf. `ListSessions` and `Tmux.ListConnections`
  round-trips succeeded.
- **Protobuf field numbers** (`proto2`, iterm2 module 2.11 / protobuf 6.33 upb; dump more with
  the interpreter above plus `from iterm2 import api_pb2`, walking
  `DESCRIPTOR.message_types_by_name`). All modeled in `Sources/MuxFinderCore/ITerm2/`:
  - `ClientOriginatedMessage` / `ServerOriginatedMessage`: `id`=1 (int64; absent on
    notifications), then the `submessage` oneof: `error`=2 (server, string), `list_sessions`=106,
    `create_tab`=108, `activate`=114, `variable`=115, `list_profiles`=118, `tmux`=124 (each
    `*_request` / `*_response`); every request/response type sits in 100–133, and the server's
    `notification`=1000.
  - `ListSessionsResponse`: `windows`=1, `buried_sessions`=2. `Window`: `tabs`=1,
    `window_id`=2, `frame`=3, `number`=4. `Tab`: `tab_id`=2 (string), `root`=3 (SplitTreeNode),
    `tmux_window_id`=4 and `tmux_connection_id`=5 (strings), `minimized_sessions`=6
    (SessionSummary). Only tabs carry tmux fields; `SessionSummary` has none.
  - `SplitTreeNode`: `vertical`=1, `links`=2 (`SplitTreeLink`, oneof `child`: `session`=1,
    `node`=2). `SessionSummary`: `unique_identifier`=1, `frame`=2, `grid_size`=3, `title`=4.
  - `CreateTabRequest`: `profile_name`=1, `window_id`=2, `tab_index`=3 (uint32),
    `command`=4 (deprecated), `custom_profile_properties`=5 (ProfileProperty `key`=1,
    `json_value`=2). `CreateTabResponse`: `status`=1 (`OK`=0, `INVALID_PROFILE_NAME`=1,
    `INVALID_WINDOW_ID`=2, `INVALID_TAB_INDEX`=3, `MISSING_SUBSTITUTION`=4), `window_id`=2,
    `tab_id`=3 (**int32**, unlike the string `Tab.tab_id`), `session_id`=4.
  - `TmuxRequest` (oneof `payload`): `list_connections`=1 (empty), `send_command`=2
    (`connection_id`=1, `command`=2), `set_window_visible`=3, `create_window`=4.
    `TmuxResponse`: `list_connections`=1 (`connections` → `connection_id`=1,
    `owning_session_id`=2; nothing else), `send_command`=2 (`output`=1),
    `set_window_visible`=3, `create_window`=5, `status`=4 (`OK`=0, `INVALID_REQUEST`=1,
    `INVALID_CONNECTION_ID`=2, `INVALID_WINDOW_ID`=3).
  - `ActivateRequest`: oneof `identifier` (`window_id`=1, `tab_id`=2, `session_id`=3),
    `order_window_front`=4, `select_tab`=5, `select_session`=6, `activate_app`=7
    (`raise_all_windows`=1, `ignoring_other_apps`=2). `ActivateResponse`: `status`=1 (`OK`=0,
    `BAD_IDENTIFIER`=1, `INVALID_OPTION`=2).
  - `ListProfilesRequest`: `properties`=1, `guids`=2 (both repeated string; empty means all).
    `ListProfilesResponse`: `profiles`=1 → `Profile.properties`=1 (ProfileProperty).
  - No message muxFinder uses has a repeated scalar (packable) field.
- **How the Python module serializes requests** (the golden fixtures reproduce it):
  `SerializeToString` writes fields in field-number order; `id` is always set (numbered from 0);
  empty requests are still present (`SetInParent`); `rpc.async_activate` always sets the three
  activate flags, even when false, and sends `activate_app` fields only when true (its
  `ignoring_other_apps` check is buggy, so any app options set both). `rpc.async_create_tab`'s
  own `command` argument raises a `TypeError` in 2.11; `Window.async_create(command=…)` and
  `Window.async_create_tab(command=…)` build the properties themselves.
- **Profile property keys and JSON values** (`LocalWriteOnlyProfile`, `profile.py`): a custom
  command is `"Custom Command"` = `"Yes"` (`Profile.USE_CUSTOM_COMMAND_ENABLED`; `"No"` and
  `"SSH"` also exist), then `"Command"` = the command line, sent in that order;
  `"Close Sessions On End"` = `true`/`false`; `"Name"` and `"Guid"` are strings
  (`PartialProfile` asks for `["Guid", "Name"]`). Each `json_value` is Python `json.dumps`
  output: ASCII only, `"` `\` and `\b \f \n \r \t` escaped, every other character outside
  U+0020–U+007E as lowercase `\uXXXX` (surrogate pairs above U+FFFF), `/` not escaped.
- Signing identities: `Apple Development: Carlos Carpio García (5XHQZ98534)`, plus a Developer
  ID Application identity that is unused here.

Verified in Phase 6a (2026-10-22, tmux 3.8, a private `TMUX_TMPDIR` server with
`muxfinder-test-*` sessions only; the real `e2e-local` and `e2e-remote` results are in
`docs/TESTING.md`):

- **Formats in `new-session`:** tmux expands formats in `-s` and `-c`. `-c '<dir>/d#{pid}'`
  became `d<server pid>`, a missing directory, and tmux started the pane in the home directory
  with exit 0 and no error; `-c '<dir>/d##{pid}'` gave the literal `d#{pid}`, and
  `-s 'x##y'` stored `x#y`. A `-s` holding `#(…)` lost it (stored without the text). A missing
  `-c` directory also starts the pane in the home directory, exit 0.
- **`\` in `-s`** is stored doubled (`a\\b`), as Phase 2 saw for listing.
- **`has-session -t '=<name>'`:** exit 0 for an existing exact name; `can't find session:
  <name>` (exit 1) for a missing one or a prefix; with no server `error connecting to …
  (No such file or directory)` (exit 1). The target is not format-expanded (`=…#{pid}` found
  the session literally named so). An exact target starting with `$` is an id lookup
  (`=$0` found session `$0`).
- **`new-session` with an existing name:** exit 1, `duplicate session: <name>`.
- **`#{pane_current_path}`** of the new pane is the directory byte for byte (spaces, Unicode,
  `#`), with `/private/tmp` for `/tmp`.
- **A trailing `;` in an argv argument is a command separator** (tmux(1) says so too), checked
  in the review fixes with `<dir>/work` and `<dir>/work;` both existing: `new-session -d -c
  '<dir>/work;'` started the pane in `<dir>/work`, exit 0; with `sleep 600` after it, `unknown
  command: sleep`, exit 1, nothing created; `-s 'x;' -c …` gave `unknown command: -c`;
  `has-session -t '=x;'` looked for `x` (a false collision when `x` exists, `can't find
  session: x` when only `x;` does). Written `\;`, each is literal: the pane in `<dir>/work;`,
  `-s 'x\;'` stored `x;`, `has-session -t '=x\;'` found `x;` and not `x`, a lone `\;` named a
  session `;`, `x##\;` stored `x#;`, and `<dir>/w\\;` reached the directory `w\;`. A trailing
  `\` alone, and `{`, `}`, `,` in `-s` and `-c`, need nothing.
- **`##[` survives format expansion undoubled:** `-s 'x##[y]'` stored `x##[y]`, not `x#[y]`
  (tmux keeps a run of `#` before `[` for its style parser), so the `#` doubling does not give
  back a name containing `#[` exactly. Seen during the review fixes; not changed (an open
  question for the name rules).
- **The conditional kill** (`if-shell -F -t '$N' <condition> "kill-session -t '$N'"
  "display-message -p <marker>"`, D18 *Real-run safety*): with two sessions of one server
  created in the same second (so the same creation time, pid and start time), a record with
  the other session's id, a missing id (`$99`: exit 0 and no error, `if-shell` resolves it
  leniently), the creation time, pid or start time plus one, another socket path or another
  name each printed the marker, exit 0, and killed nothing; the exact record killed only its
  session (exit 0, no output), and again printed the marker; the server's only session was
  killed the same way (exit 0, the server then exited); with no server, exit 1 `no server
  running on …`. A name with `#`, `,`, `}`, Unicode and a `;` matched as a format literal
  (`##`, `#,`, `#}`). The race it closes, reproduced: the old two calls (`display-message`
  matched the record, then the server restarted and its new session got `$0` and the same
  name, creation time and start time, only the pid differed) ended with `kill-session -t '$0'`
  killing the new session; the one-command kill with the old record printed the marker and
  left it alone.
- **iTerm2's blocked workers pile up for a while:** each `e2e-local` or `e2e-remote` run of
  this phase raised iTerm2's `ps -M` line count by about 12 (15 to 28, then 38 after the next
  run), and a read-only `sample` at 38 showed 23 GCD workers blocked in
  `-[NSAnimation _runBlocking]`, the frames of the Phase 5b stall, with the API still
  answering. About four minutes after the runs stopped the count was back at 15, so the
  workers are reclaimed, but runs made in quick succession add up, and the stall comes once
  they reach the pool's 64. Real runs check the count first and wait for it to come down.

Verified in Phase 5b (2026-10-22, iTerm2 3.7.6, tmux 3.8 on Neptuno and Saturno, Saturno's
default server holding only `muxfinder-test-*` sessions; `e2e-remote saturno-m4` passed twice,
a third run passed steps 1–9 before iTerm2's API stopped answering, and two more passed on the
final tree; details in `docs/INTEGRATION-PROOF.md`):

- **tmux over `ssh -t`:** iTerm2 takes up the remote `tmux -u -CC attach-session` exactly like a
  local one: connection id `tmux`, owned by the launch tab's session, each tmux window as its
  own native window, the split as one two-leaf splitter, the launch tab staying in its window.
  `detach-client` through it is answered, the remote tmux client exits 0, ssh exits 0, the
  helper records success and the launch tab closes by itself (10.3–10.6 s old).
- **`#{host}`** through the remote control connection is `Saturno-M4.local`, byte-identical to
  discovery's remote `uname -n`, and the index mapped every remote attachment by it. Saturno's
  default socket path is `/private/tmp/tmux-501/default`, the same path as this Mac's.
- **Timings:** discovery over ssh about 0.7–0.78 s; from the attach call, the launch tab about
  0.85–0.95 s, the connection 1.7–1.8 s, confirmed 1.8–1.9 s, activated 2.2–2.55 s; a focus of
  the remote attachment ended 0.76–0.85 s after the call (discovery most of it). The remote
  guard's refusal (`sessionChanged`, ssh exit 65) reached the coordinator 1.7–1.8 s after the
  call.
- **ssh waiting for a password** (seen with the `still waiting` step's original design, since
  replaced by the test launch delay, D17): with an unknown user
  (`nonexistent-muxfinder@saturno-m4`, no
  `BatchMode`) ssh waited at its password prompt in the launch tab; no connection appeared and
  the attach published `stillWaiting` 21 s after the call (the tab 20.2–20.3 s old). After a
  forced `Close` of that tab iTerm2 dropped it from `ListSessions` at once, but ssh ended (by
  SIGHUP; helper result `childSignaled(1)`, exit 129) only about 5 s later, and the attach ended
  5.2 s after the close. No dialog appeared.
- **Hang-up after a forced close:** that 5 s is iTerm2's, not ssh's. With the test launch
  delay (the helper alone, ssh never started) the helper's SIGHUP also came 5.0–5.2 s after
  the forced close (`interrupted`, exit 129).
- **Remote session lifetime:** a session created with `new-session -d` over a noninteractive
  ssh connection keeps its server after ssh ends; killing that only session ends the server
  (`noServer` afterwards).
- **iTerm2's API can stall without a modal:** after a day of e2e runs (iTerm2 up 15.7 h), its
  API stopped answering in the third `e2e-remote` run, right after step 10's launch tab opened
  (requests on an open connection and new handshakes timed out; `iterm2 status` exit 75). A
  read-only `sample` showed the main thread idle in `-[NSApplication run]` (no modal run loop)
  and 64 GCD worker threads, the pool's limit, each blocked in AppKit's
  `-[NSAnimation _runBlocking]` with no iTerm2 frame. So the pool was exhausted and the API's
  work queued behind it. What starts those animations, and whether the windows the runs open,
  activate and close leak them, is not known yet (no UI was touched to find out). It cleared
  by itself within about two hours, without a restart: iTerm2, still the same process, then
  answered with 18 threads, and three more real runs left it at 14–18 threads (no growth).
  Real runs therefore check `iterm2 status` and the thread count before and after, and stop on
  a timeout.

Verified in Phase 5a (2026-10-22, iTerm2 3.7.6, tmux 3.8, the default tmux server holding only
`muxfinder-test-*` sessions; `e2e-local` with the focus-existing step passed twice, and once
more with the length-prefixed identity command and the bound activation; details in
`docs/INTEGRATION-PROOF.md`):

- **`#{host}`** prints `Neptuno-M4.local`, byte-identical to `uname -n` (a private
  `TMUX_TMPDIR` server, and through the control connection, where the index mapped every
  attachment by it).
- **The D16 identity command** answers through a control connection with one line in its
  length-prefixed form, flag `1` (the helper's `-u` client), that matched discovery in every
  attach and index query (the tab-separated form it replaced did too).
- **Clients not in UTF-8 mode** (private `TMUX_TMPDIR` servers with one `muxfinder-test-*`
  session each, control clients `tmux -C attach-session` fed the identity command on stdin,
  socket directories holding `é`, a combining acute, a zero-width space, a tab and `_`):
  without `-u`, under `LC_ALL=C` or with no locale (`env -i`), `#{client_utf8}` is `0` and the
  output has every tab and `é` replaced by one `_` each, the combining mark and the zero-width
  space dropped, and `_`, `:` and all other printable ASCII kept, so the tab-separated line
  arrived as one field. With `-u`, or with `LANG=en_US.UTF-8` and no `-u`, it is `1` and the
  bytes are exact. `#{n:socket_path}` counts bytes (`é` counts 2), so a replaced or dropped
  character shows as a field shorter than its length. A normal client's `list-sessions -F`
  without `-u` replaced `é` and a tab by one `_` each the same way.
- **Focus:** `Activate` (tab target, `select_tab`, `order_window_front`, app options) on a tab
  of an existing connection brings it forward and opens nothing: the same window and tab ids
  everywhere, the same connections, no launch tab, no helper started. The index over one
  connection answered within 1–2 ms of discovery; a focused attach ended about 50 ms after the
  call, discovery taking most of it.
- **Detach by session:** the repeated identity check and then `detach-client`, both bound to
  the launch tab, behaved like D15's detach: the connection closed, the helper exited 0, and the
  launch tab closed by itself, 10.4–10.5 s old.

Verified in Phase 4 (4b and 4c, 2026-10-22, iTerm2 3.7.6 with default preferences, tmux 3.8,
the default tmux server holding only `muxfinder-test-*` sessions; `e2e-local` passed twice in
4c; details in `docs/INTEGRATION-PROOF.md`):

- **`Command` property:** with `"Custom Command" = "Yes"` and `"Command" = "<path> attach
  <uuid>"`, the helper got exactly 3 arguments: argv[0] the absolute path, `attach`, the id
  (argv digest). A path with a space was not tried, so the D2 rule stands.
- **Launch tab:** `CreateTab` without `window_id` opens a new window holding only that tab. Its
  `session_id` is the connection's `owning_session_id`. It carries `tmux_window_id` `"-1"` and
  no connection id, and stays in its window while attached (not buried). iTerm2 answers
  `CreateTab` after the helper has started (a guard refusal is already in the result file at
  the first poll). A refused launch tab stays open with the helper's explanation until it is
  closed; `Close` (forced) by its session id closes it without a dialog.
- **tmux windows** open as native windows with the default "open tmux windows as" preference:
  one new iTerm2 window per tmux window, one tab each.
- **tmux tabs** carry `tmux_window_id` = the tmux window id without `@` (`"0"`, `"1"`) and
  `tmux_connection_id` = the connection id. A window split in two arrives as one splitter with
  two session leaves (tmux's default top/bottom split as `vertical = false`).
- **Connections:** `ListConnections` lists the new connection within about 0.5 s of the tab
  opening. Its `connection_id` is a short name (`"tmux"` for the first one), not a UUID, and
  iTerm2 hands it out again: three successive connections in one run were all `"tmux"`. So
  connections are matched by `owning_session_id`.
- **Socket path:** discovery's `#{socket_path}` equals the one `new-session -P` prints for the
  default server (`/private/tmp/tmux-501/default`).
- **Single flight:** two concurrent attaches of one session opened one launch tab and one
  connection and both got the same confirmed result.
- **Activate:** a tab target with `select_session = true` is refused with `INVALID_OPTION`; a
  tab target with `order_window_front`, `select_tab` and the app options in one request works.
- **Detach:** `SendCommand detach-client` is answered with empty output and the connection
  disappears at once. iTerm2 closes the connection's tabs without a dialog, `tmux -CC` exits 0,
  the helper records success, and its launch tab closes by itself (`Close Sessions On End`).
  The session keeps its id, windows, panes and processes.
- **Short-lived sessions block iTerm2:** a session that ends within 3 s of starting (the
  advanced setting `shortLivedSessionDuration`, default 3 s, read from the 3.7.6 binary and not
  overridden in `defaults read com.googlecode.iterm2`; 4b's first run ended one after about
  1.5 s: attach, then an immediate detach) makes iTerm2 show its "session ended very soon after
  starting" warning (`-[PTYSession _maybeWarnAboutShortLivedSessions]`, a modal
  `iTermWarning`, silenceable per profile, not silenced for the default profile here). While
  it is open, iTerm2's API answers nothing (WebSocket handshakes time out), although
  AppleScript cookie requests still return. Only a person can dismiss it. So nothing may end a
  launch tab, or detach its connection, before it is 10 s old: the coordinator sends
  `detach-client` only then (D15), the helper never exits younger while its tab is visible
  (D14), and `e2e-local` waits as long before it kills its session or closes a launch tab.

Verified in Phase 4a (2026-10-21, tmux 3.8, private `TMUX_TMPDIR` servers only):

- `tmux -u display-message -p -t '$99' '#{session_id}:#{pid}:#{start_time}:#{session_created}'`
  for a missing id exits **0** and prints `:<pid>:<start_time>:`. It did not fall back to
  another session, even with a control client attached to one. `has-session -t '$99'` fails
  with `can't find session: $99` (exit 1). A new server numbers its sessions from `$0` again.
- `tmux -u -CC attach-session` whose stdin is not a terminal prints `tcgetattr failed:
  Operation not supported by device`, exits 1 and attaches nothing. Under a pseudo-terminal
  (`script -q /dev/null …`), `muxfinder-launch attach <uuid>` → check child → a directly
  spawned `tmux -u -CC attach-session` attached as a control client and exited 0 after
  `detach-client`.
- A tmux client whose server is stopped (`SIGSTOP`) blocks in `display-message` with no
  timeout of its own, and SIGTERM ends it. The helper's check deadline ended such a check
  after 10 s (exit 75, `checkTimedOut`) and left no client behind.
- `EVFILT_SIGNAL` reports signals whose disposition is `SIG_IGN`. The helper relies on it, and
  the helper binary tests show it.
- With Swift 6.4's build system the products are in `.build/out/Products/Debug/`, and
  `.build/debug` links there. `swift test` builds the executables too.

Verified in Phase 3b (2026-10-21, iTerm2 3.7.6, read-only checks from a shell inside iTerm2):

- **Handshake reply:** `101` with `Upgrade: websocket`, `Connection: Upgrade`, a correct
  `Sec-WebSocket-Accept`, and `X-iTerm2-Protocol-Version: 1.21`. The in-process
  `NSAppleScript` cookie request (main actor, CLI started from this shell) shows no prompt and
  returns two printable-ASCII tokens separated by one space. iTerm2 answers a client close
  frame, so the close handshake completes at once.
- **Handshake refusals** (from iTerm2's Python module `connection.py`, not produced live: the
  run rules forbid sending a bogus cookie): HTTP **401** means the cookie or key was not
  accepted (the module fetches a fresh cookie and retries once); HTTP **406** means iTerm2
  considers the client library version too old. Cookies are single-use: the module discards
  them after every connection attempt.
- **Ordinary tabs carry `tmux_window_id` `"-1"`** and no `tmux_connection_id` in
  `ListSessionsResponse` (`ITerm2API.Tab.isTmuxTab` accounts for it). What a tmux tab carries
  is in the Phase 4 facts above.
- With no tmux integration connection, `Tmux.ListConnections` answers `status=OK` with no
  payload (also seen in the planning spike); the client returns an empty list.

Verified in Phase 2 (2026-10-21):

- **tmux 3.8 names:** `new-session -s` rejects names with control characters ("invalid
  session name"), expands formats in the name (`##{pid}` is stored as `#{pid}`) and stores `\`
  as `\\`. Listing never re-expands a stored name. Names are still treated as hostile by the
  parser (raw tabs and line breaks are possible in principle).
- **tmux client side effects and errors:** any client command, including `list-sessions`,
  creates `$TMUX_TMPDIR/tmux-<uid>` (0700; default `/tmp`) if it is missing. With no socket
  the error is `error connecting to <socket> (No such file or directory)`; after a server
  exits its socket file stays and the error becomes `no server running on <socket>`.
  `#{socket_path}` is the resolved path, e.g. `/private/tmp/tmux-501/default`. Unix socket
  paths must stay under 104 bytes, so test servers use `/tmp/mfx-XXXXXX`, not `$TMPDIR`.
- `uname -n` is `Neptuno-M4.local` here and `Saturno-M4.local` on Saturno.
- **ssh (OpenSSH_10.5p1, LibreSSL 3.3.6):** `ssh … -- <dest> <cmd>` works. Exit 255 stderr:
  `ssh: Could not resolve hostname something.invalid: nodename nor servname provided, or not
  known`; `ssh: connect to host 192.0.2.1 port 22: Operation timed out` (after the 5 s
  `ConnectTimeout`); `nonexistent-muxfinder@saturno-m4: Permission denied
  (publickey,password,keyboard-interactive).`; `ssh: connect to host 127.0.0.1 port 1:
  Connection refused` (destination `ssh://127.0.0.1:1`). With `StrictHostKeyChecking=yes`
  and an empty known-hosts file: `No ED25519 host key is known for saturno-m4 and you have
  requested strict checking.` plus `Host key verification failed.`; with a wrong key the
  `REMOTE HOST IDENTIFICATION HAS CHANGED!` banner comes first, then the same last line.

## Unattended-run rules (binding for every phase)

The run is unattended and shares this Mac, and this iTerm2 instance, with the user's live
work. The autoclaude session itself runs inside an iTerm2 tab.

1. **Never touch iTerm2 windows, tabs or sessions you did not create in the current test.**
   Never send text to, close, or reorder them. Close or detach only through ids your test
   recorded at creation.
2. **tmux:** create only sessions named `muxfinder-test-*`, and kill only those. Never run
   `kill-server` or touch other sessions. Applies locally and on Saturno.
3. **Remote:** Saturno (`saturno-m4`) is authorized for read-only discovery and for
   creating/attaching/detaching/killing `muxfinder-test-*` sessions. No other host. No file
   writes on remote hosts.
4. **Never write** iTerm2 preferences (`com.googlecode.iterm2`), profiles other than
   `DynamicProfiles/muxFinder.json`, `~/.ssh/*`, or shell startup files.
5. Do not launch `muxFinder.app` through LaunchServices (`open`) in a way that triggers the
   Automation prompt. For real GUI-path checks, run the bundle binary directly from the shell
   (`build/muxFinder.app/Contents/MacOS/muxFinder --selftest …`), which inherits iTerm2's
   permission. Mark the LaunchServices permission path as a manual user check.
6. Every e2e command must have bounded timeouts and must clean up on failure (detach, then kill
   its own test sessions). A modal iTerm2 dialog shows up as a timeout and gets reported. Never
   use UI scripting or synthesized keystrokes to dismiss anything.
7. Never paste terminal contents or window titles into fixtures, logs or docs. Generate protobuf
   fixtures synthetically.

## Phases

Each phase lists its goal, deliverables, requirements, acceptance criteria and risk. Shared
verification for every phase: `swift build` and `swift test` exit 0, no new compiler warnings
in project code, and `swift format lint -r Sources Tests` is clean or has its exceptions
recorded.

### Phase 1 — Package skeleton, process runner, quoting and validation (routine)

Goal: the foundation every later phase uses for running commands safely.

Deliverables: `Package.swift`, `.gitignore` updates, `Sources/MuxFinderCore/{Process,Shell,
Config/AppPaths.swift,Diagnostics}`, placeholder targets `muxfinder-launch`, `muxfinder-probe`
and `MuxFinderApp` (a minimal MenuBarExtra that compiles), and `Tests/MuxFinderCoreTests`.

Requirements:
- **`ProcessRunner`** protocol plus a `posix_spawn` implementation.
  - Executable URL plus argv only, explicit environment (helper that adds Homebrew dirs to
    PATH for local runs), stdin from `/dev/null` by default.
  - New process group (`POSIX_SPAWN_SETPGROUP`). Timeout sends SIGTERM to the group, then
    SIGKILL after 2 s.
  - Task cancellation kills the group. stdout and stderr are captured separately, capped at
    1 MiB each.
  - Returns exit code or signal, duration and a `timedOut` flag. No main-thread blocking.
- **`ShellQuoting`**: `posixSingleQuote(_:)` and
  `remoteCommand(script:args:) -> String` producing `/bin/sh -c '<script>' muxfinder '<a>' …`.
- **`Validation`** with typed errors and user-facing English messages:
  - Session name: trimmed, non-empty, ≤ 100 characters, no control characters, no `:` or `.`
    (tmux rewrites them), no `\` (tmux stores it doubled; added in Phase 6a, D18), no leading
    `-`, Unicode allowed.
  - SSH destination: non-empty, no whitespace or control characters, no leading `-`.
  - Executable path: absolute, no control characters.
  - Working directory: no NUL or newline, and a leading `~/` is allowed. Expand it remotely
    inside the static script from `$HOME`, never by string splicing.
- **`AppPaths`**: Application Support directory (0700), with an override for tests.
- **`DiagnosticsLog`**: an actor ring buffer of `{time, category, hostID?, outcome,
  durationMs, detail}` with `os.Logger` subsystem `cc.carpio.muxfinder`. Details never hold
  command lines with user data or any terminal output.

Acceptance:
- Quoting tests run `/bin/sh -c` locally against an adversarial corpus (spaces, `'`, `"`, `$()`,
  backticks, `;`, `|`, `&`, `*`, leading `-`, emoji, CJK) and argv comes back byte-identical.
- A timeout test proves grandchildren die (`/bin/sh -c 'sleep 30 & sleep 30'` leaves no
  survivors). Cancellation and output-cap tests exist.
- Validation tests cover every rejection reason.

### Phase 2 — tmux discovery: probe, parser, identity, error classification (high)

Goal: a correct, hardened answer to "what is running on this host, or why can't we tell".

Deliverables: `Tmux/` (locator, static probe script, parser, models `ServerIdentity`,
`DiscoveredSession`, `ClientSummary`, `SessionKey`, `HostStatus`, `ErrorClassifier`), the
`HostConfig` model (struct only; persistence comes in Phase 7),
`muxfinder-probe discover --local | --ssh <dest> [--tmux-path <p>]` with JSON output, and
fixtures plus tests.

Requirements:
- The probe is one static POSIX `sh` script, run locally through argv or remotely through D3.
  Its only argument is the optional tmux override.
  - It emits a **versioned, line-based report**: header `MUXFINDER-PROBE 1`, `uname -n`, the
    chosen tmux path or a not-found marker, the tmux version, the `list-sessions` exit status
    and its first stderr line sanitized to printable ASCII, and a terminator.
  - Session lines come from `list-sessions -F` with explicit formats: `session_id`,
    `session_created`, `session_windows`, `session_attached`, `session_activity`, server `pid`,
    `start_time`, `socket_path`, and `session_name` **last**, tab-separated.
  - Client lines come from `list-clients -F`: `session_id`, `client_control_mode`, pid.
  - Find out whether `tmux -u` or `LC_ALL=…UTF-8` is needed for Unicode names, and record why.
- The parser is strict.
  - Ids match `^\$[0-9]+$`; integers parse strictly. The name is the remainder after the fixed
    fields, kept as display text.
  - Unknown, malformed or oversized input (more than 1,000 sessions or lines over 4 KiB)
    becomes `probeError` and never crashes. A session name can never change parsing or
    trigger execution.
- **`HostStatus`** cases: `ok(sessions)`, `noServer`, `tmuxNotFound`,
  `unreachable(.timeout | .dnsFailure | .refused | .noRoute)`, `authFailed`,
  `hostKeyProblem(.unknown | .changed)`, `probeError(String)`.
  - Classify from ssh exit 255 plus stderr patterns ("Permission denied",
    "Host key verification failed", "REMOTE HOST IDENTIFICATION HAS CHANGED",
    "Could not resolve hostname", "Operation timed out" or "Connection timed out",
    "Connection refused", "No route to host") and from the probe report.
  - Treat "no server running" and "error connecting to … (No such file or directory)" as
    `noServer`. A runner timeout means `unreachable(.timeout)`.

Acceptance:
- Fixture tests: real captured outputs (local, Saturno), Unicode names, and hostile names
  (`a;rm -rf ~`, `$(touch /tmp/x)`, quotes, tabs, `-x`, emoji). Plus a classifier table test
  over captured ssh stderr strings.
- Real checks recorded in `docs/TESTING.md`:
  - Local with no server gives `noServer`.
  - Local with `muxfinder-test-*` sessions, including a Unicode one, finds every session with
    the right ids; clean up afterwards.
  - `saturno-m4` gives `noServer` or `ok`.
  - A bogus `.invalid` destination gives `dnsFailure`. `192.0.2.1` times out within the bound.
  - `nonexistent-muxfinder@saturno-m4` gives `authFailed`.
  - A host-key failure, made in the test harness only with an empty `UserKnownHostsFile` and
    `StrictHostKeyChecking=yes` (stricter, never weaker), gives `hostKeyProblem`.

### Phase 3 — Native iTerm2 API client (high)

Goal: a reliable, replaceable Swift client for the iTerm2 API calls muxFinder needs.

Deliverables: `ITerm2/` (`WebSocketClient` over a Unix socket, `ProtoWire` codec, typed
messages, `CookieProvider`, `ITerm2APIClient`, the `ITerm2Integration` protocol and a
`FakeITerm2Integration`), `scripts/dev/gen-iterm2-fixtures.py` (dev-time only, run with iTerm2's
interpreter and `-I`), golden fixtures, and `muxfinder-probe iterm2 status | list-sessions |
list-connections | list-profiles`.

Split (autoclaude run, 2026-10-21), each sub-phase with its own commit and review:
- **3a — wire layer (hermetic):** the `ProtoWire` codec, the typed messages (request and
  response envelopes plus every message listed below), `scripts/dev/gen-iterm2-fixtures.py`,
  the golden fixtures and the golden encode/decode tests. No socket, no iTerm2 at test time.
- **3b — transport and client:** the RFC 6455 `WebSocketClient` over the Unix socket (with
  fake-socket tests for fragmentation and partial reads), `CookieProvider`, the connection
  lifecycle and error cases, `ITerm2APIClient`, the `ITerm2Integration` protocol and
  `FakeITerm2Integration`, the `muxfinder-probe iterm2 …` subcommands and the real checks.

Requirements:
- **WebSocket client (RFC 6455):** client masking, continuation frames, ping→pong, close
  handshake, 16 MiB message cap, read timeouts, and requests matched to responses by `id`
  inside an actor.
- **Connection lifecycle:**
  - Reconnect with a fresh cookie. Detect "iTerm2 not running" from the bundle id
    `com.googlecode.iterm2`.
  - Error cases: `apiDisabled` (socket missing), `automationDenied` (AppleScript -1743),
    `notRunning`, `authRejected`, `protocolError`.
  - `ensureRunning()` launches iTerm2 via `NSWorkspace`. Only the attach path calls it.
- **Messages:**
  - `ListSessions`: windows, tabs, split trees, session ids, `tmux_window_id`,
    `tmux_connection_id`.
  - `CreateTab`: profile name plus `custom_profile_properties` for the custom command and
    close-on-end. Copy the property keys and JSON encodings the Python module uses for
    `Window.async_create(command=…)` / `LocalWriteOnlyProfile`.
  - Tmux `ListConnections` and `SendCommand` (returns output), and `Activate` (tab, window,
    app).
  - `ListProfiles` (names and GUIDs; find the field numbers first).
- **Codec:** generic varint and length-delimited reader/writer with unknown-field skipping.
  Golden tests compare encodings byte-for-byte with fixtures generated synthetically by iTerm2's
  `api_pb2`, and decode synthetic responses. No real window titles.

Acceptance:
- Unit tests pass, including frame fragmentation and partial reads (fake socket).
- `muxfinder-probe iterm2 status` and `list-connections` work against the real iTerm2 from the
  shell with no prompt. Record the output shape, not titles.

### Phase 4 — Integration proof, local: attach, native tabs and splits, detach, reattach (high)

Goal: prove the central workflow end to end on this Mac before any real UI exists (brief:
"Choose and validate the iTerm2 integration early", steps 1–4).

Deliverables: `Launch/` (request and result files, TTL, 0600), `muxfinder-launch attach
<uuid>`, `Attach/AttachCoordinator` (local path), `muxfinder-probe attach --local --session
<$id>`, `muxfinder-probe e2e-local`, and `docs/INTEGRATION-PROOF.md` with the real results.

Split (autoclaude run, 2026-10-21), each sub-phase with its own commit and review:
- **4a — launch layer and helper (hermetic):** `Launch/` (request and result models, the
  0700 launch directory, 0600 files, atomic writes, delete on read, 2-minute TTL and stale-file
  sweep, helper-path validation), the static guard script (the bounded D4 check, then a
  direct `tmux -u -CC attach-session` child), the `muxfinder-launch attach <uuid>` executable
  (child processes, result file, plain failure text and wait for Return, argv digest in test
  mode), and the mapping of guard and child exit codes to typed failures. Local host kind
  only; the ssh launch path is Phase 5. Tests are hermetic, plus guard checks against real
  tmux on a private socket directory. No iTerm2 at any point.
- **4b — attach coordinator and probe commands:** `Attach/AttachCoordinator` (local path, the
  states, single-flight, `ListConnections` polling, identity check, `Activate`, detach) with
  hermetic tests, `muxfinder-probe attach --local --session <$id>`, `muxfinder-probe
  e2e-local`, and the first draft of `docs/INTEGRATION-PROOF.md` from the single attaches and
  e2e run 1.
- **4c — real local proof** (split from 4b on 2026-10-22, when e2e run 1 detached too soon and
  iTerm2's modal short-lived-session warning blocked its API until a person dismisses it):
  `muxfinder-probe e2e-local` passing at least twice, fixes for what those runs reveal, and the
  final `docs/INTEGRATION-PROOF.md`. Starts only once `muxfinder-probe iterm2 status` connects
  again.

Requirements:
- **Attach flow:**
  1. Revalidate through discovery.
  2. Write the request file.
  3. Call `ensureRunning`.
  4. `CreateTab` with command `<helper> attach <uuid>`, using the host's iTerm2 profile when
     one is set.
  5. The state becomes `launched(sessionID)`.
  6. Poll `ListConnections` until a connection's `owning_session_id` equals the created
     session, or the helper's result file reports failure (15 s budget locally).
  7. Check identity with `SendCommand` of the D16 identity command (`display-message -p`
     with `#{client_utf8}`, `#{host}`, `#{pid}`, `#{start_time}`, `#{socket_path}`,
     `#{session_id}`, the host and path after their byte lengths) through that connection.
  8. The state becomes `confirmed`.
  9. `Activate` the first tab carrying that `tmux_connection_id`, while the launch tab still
     owns the connection (D15 *Connection binding*).
  - The states `requested`, `launched`, `confirmed` and `failed(reason)` are distinct.
- The helper's guard runs the D4 check before `tmux -CC attach-session -t <id>`. Its exit codes
  map to typed failures (`sessionGone`, `sessionChanged`, `tmuxMissing`, `sshFailed(class)`).
- Single-flight: concurrent attach requests for the same `SessionKey` coalesce into one launch.
- Detach uses `SendCommand detach-client` on the connection. Verify that iTerm2 treats it as a
  clean detach. Never close tmux tabs.
- Verify and record in `INTEGRATION-PROOF.md`:
  - how iTerm2 parses the `Command` property (the helper logs an argv digest in test mode);
  - whether the gateway tab closes when the helper exits;
  - where tmux windows open (user pref; leave it unchanged);
  - any dialogs.

`e2e-local` steps:
1. Create `muxfinder-test-<rand>` with 2 windows, one split into 2 panes running `sleep 600`.
2. Discover it.
3. Attach it.
4. Check through `ListSessions`: 2 tabs with the connection id, and one tab with a two-leaf
   split tree.
5. Detach. The session survives with the same id, window and pane counts, and a live `sleep`.
6. Reattach and verify again.
7. Fire two concurrent attaches; exactly one new tab appears.
8. Use a stale guard (wrong `session_created`); the result is `sessionChanged` and nothing
   attaches.
9. Clean up.

Acceptance: `muxfinder-probe e2e-local` exits 0 with each step's PASS line, run at least twice.
`INTEGRATION-PROOF.md` records versions, timings and observed iTerm2 behavior.

### Phase 5 — Integration proof over SSH, and existing-attachment detection (high)

Goal: brief step 5 (SSH), plus "open in iTerm2 on this Mac" detection and focusing an existing
attachment instead of duplicating it.

Deliverables: remote path in the coordinator and helper (`/usr/bin/ssh -t -- <dest>
<D3 string>`, interactive with no BatchMode so the user can authenticate in the tab),
`Attach/AttachmentIndex`, focus-existing, `detach(sessionKey)` for attachments created in
iTerm2 on this Mac, `muxfinder-probe e2e-remote saturno-m4`, and an extended `e2e-local`.

Requirements:
- `AttachmentIndex` lists iTerm2 tmux connections. Through each one it reads
  `#{host}`, `#{socket_path}`, `#{pid}`, `#{start_time}` and `#{session_id}`, then maps them to
  `SessionKey`s by matching the probe's `uname -n`, socket path, pid and start time. No title
  matching. Ambiguous or unknown connections stay unmapped and are counted, never guessed.
- When a session is already attached in this Mac's iTerm2, attach becomes focus: `Activate` its
  tab and no new tab.
- The remote attach budget is 20 s to `confirmed`. If the helper is still alive past that,
  report `stillWaiting` (for example, SSH waiting for user input in the tab), never success.

Acceptance:
- `e2e-remote saturno-m4` covers create test session, discover, attach, verify tabs and splits,
  detach, survive, reattach, second attach focuses the existing tab, and cleanup. It exits 0.
- `e2e-local` also passes the focus-existing step.

Split (2026-10-22, before the first worker): Phase 5 is two sub-phases, each with its own
worker, verification, review and commit.

- **5a — existing-attachment detection, local (high).** `Attach/AttachmentIndex` (the mapping
  above, with the local host's `uname -n` and discovery's socket/pid/start time), attach
  becoming focus when the session is already attached in this Mac's iTerm2, `detach(sessionKey)`
  for attachments in this Mac's iTerm2 (not only connections the app opened), and `e2e-local`
  extended with the focus-existing step. Acceptance: hermetic tests for mapped, unknown,
  ambiguous and stale connections, the focus path and `detach(sessionKey)`; `e2e-local` exits 0
  with the focus-existing step passing (second attach opens no tab or window); no leftovers.
- **5b — remote attach over SSH (high).** The remote path in the coordinator and the helper
  (`/usr/bin/ssh -t -- <dest> <D3 string>`, interactive, no BatchMode, the helper's 10 s hold
  kept when ssh fails fast), the 20 s `stillWaiting` budget, `AttachmentIndex` mapping for
  remote hosts, and `muxfinder-probe e2e-remote saturno-m4`. Acceptance: the `e2e-remote`
  bullet above, plus hermetic tests for the remote argv, the budget and `stillWaiting`.

### Phase 6 — Session operations: create, move here, disappeared sessions (high)

Goal: New session, Move here and vanished-session handling, all correct at the core level.

Deliverables: `TmuxCommands` (detached create with `new-session -d -P -F` returning id, created
time and server identity; `-c <dir>` with `~/` expansion inside the static script),
`createAndAttach`, `moveHere` (`attach-session -d`, which requires an explicit confirmation flag
in the API), typed `sessionGone` and `sessionChanged` errors that trigger a refresh,
`muxfinder-probe new-session --local | --ssh <dest> --name … [--dir …]`, and e2e coverage.

Requirements:
- **Collision:** check `has-session -t '=<name>'` first, and still treat tmux's
  duplicate-session error as a collision. Never `-A`, never replace or kill existing work.
- **Working directory:** missing directories give a clear error, and spaces or Unicode work.
- Creation runs noninteractive (BatchMode, D6 options). An auth failure means "set up SSH in
  iTerm2 first".

Acceptance (local and Saturno):
- Creating `muxfinder-test-*` attaches and gets confirmed.
- A collision returns an error, and the existing session's id and window count are unchanged.
- Invalid names are rejected before any process runs.
- A directory with spaces and Unicode works.
- A session killed between discovery and attach gives `sessionGone`, and the
  `list-sessions` count is unchanged (nothing recreated).
- Move here: a background plain control client (`tmux -C attach`, started by the harness) gets
  detached and the iTerm2 attachment remains.

Split (2026-10-22, before the first worker): Phase 6 is two sub-phases, each with its own
worker, verification, review and commit.

- **6a — new session and vanished sessions (high).** `TmuxCommands` (collision check, detached
  create returning id, created time and server identity, `-c <dir>` with `~/` expansion and a
  missing-directory error), `createAndAttach`, `sessionGone`/`sessionChanged` marked as
  refresh-triggering, `muxfinder-probe new-session`, and e2e coverage, local and on Saturno.
  Acceptance: the acceptance bullets above except Move here, plus hermetic tests for the create
  argv and D3 string, output parsing, collision classification and name rejection with no
  process run. On Saturno the directory check uses an existing directory with a space (the
  run rules forbid remote file writes) and a missing Unicode directory; the local check covers
  a real directory with spaces and Unicode.
- **6b — Move here (high).** `moveHere` (`attach-session -d` behind an explicit confirmation
  flag) and its e2e coverage, local and on Saturno: a harness-started plain control client is
  detached and the iTerm2 attachment remains.

### Phase 7 — Host configuration and refresh engine (high)

Goal: persistent hosts and a race-free refresh loop.

Deliverables: `HostStore` (`hosts.json` schema v1, atomic writes, a corrupt file backed up and
reported, never silently discarded), onboarding defaults (Saturno, Neptuno and Sirio entries
with empty destinations, disabled until completed, no assumed users or addresses),
`SSHConfigSuggestions` (`Host` names from `~/.ssh/config` and its `Include`s, wildcards
excluded, offered as suggestions only), `RefreshCoordinator`, `HostSnapshot`,
`muxfinder-probe refresh --once`, and tests.

Requirements:
- **Exactly one host may be "This Mac"** (mode local). Local discovery never uses SSH.
- **RefreshCoordinator:**
  - Concurrency limit 3. Per-host single-flight; coalesce requests that arrive while one is in
    flight.
  - Generation tokens plus the config revision, so a result older than the newest applied one,
    or from an edited or removed host, is dropped.
  - Cadence: refresh immediately when the popover opens, every 15 s while it is visible, and
    every 5 min in the background.
  - Failure backoff for background only: 30 s, 1 m, 2 m, 5 m, 15 m. Manual retry bypasses it.
  - On sleep, cancel in-flight work and kill the process groups. On wake, refresh after 5 s.
    When the network path changes, refresh failing hosts.
  - Everything runs off the main actor.
- **Snapshots:**
  - A snapshot is live or stale, with `lastSuccess` and `lastAttempt` timestamps.
  - After a failure that follows a success, keep the sessions but mark them stale; they are
    never presented as live.
  - Merge in `AttachmentIndex` results.

Acceptance:
- Unit tests with a fake prober and clock cover:
  - a slow host not delaying the others;
  - overlapping refreshes coalescing;
  - a late stale result being discarded;
  - a config edit invalidating in-flight work;
  - backoff progression and reset;
  - stale marking;
  - no leaked tasks or processes after `stop()`;
  - the same session name on two hosts staying two entries.
- `muxfinder-probe refresh --once` against real config with the local host and Saturno.

Split (2026-10-22, before the first worker): Phase 7 is two sub-phases, each with its own
worker, verification, review and commit. Neither opens iTerm2 windows, so both may run while
6a's final-tree `e2e-remote` waits for iTerm2's thread count to fall.

- **7a — host configuration (routine).** `HostStore` (`hosts.json` schema v1, atomic writes,
  0700/0600 with ACLs stripped as in D14 — including the `muxFinder` directory itself, the 4a
  open risk; loading never writes; a corrupt or unsupported file is preserved byte for byte in a
  backup before anything replaces it, and the load result reports it), the host-list invariants
  (at most one "This Mac"; an SSH host with no valid destination cannot be enabled), onboarding
  defaults (Saturno, Neptuno and Sirio as SSH entries with empty destinations, disabled, none
  local until the user picks "This Mac"), `SSHConfigSuggestions`, read-only probe commands
  `hosts show [--config <path>]` and `hosts suggestions`, and hermetic tests.
- **7b — refresh engine (high).** `RefreshCoordinator`, `HostSnapshot`, the `AttachmentIndex`
  merge, sleep/wake/network-change entry points, `muxfinder-probe refresh --once [--config
  <path>]`, the fake-prober/fake-clock tests in *Acceptance* above, and the real check against a
  private `hosts.json` holding This Mac and Saturno (`saturno-m4`).

### Phase 8 — Menu bar app and popover (routine)

Goal: the popover from the brief's "Menu bar interface" section, wired to the core.

Deliverables: `MuxFinderApp` (`MenuBarExtra(.window)`, an `@Observable @MainActor AppModel`
over the core), popover views, `scripts/build-app.sh` (D7) producing a signed
`build/muxFinder.app`, a `--preview-fixtures` launch flag that renders every UI state from
fixtures in a normal window for screenshots, and SwiftUI previews.

Requirements:
- **Hosts:**
  - Grouped by host, each with a status ("Reachable", "This Mac", "Unreachable", "Sign-in
    needed", "Host key problem", "tmux not found", "No sessions", "Checking…").
  - Last successful refresh ("Last checked 2 min ago").
  - Stale sessions visibly marked, e.g. "Last seen 3 min ago · not live".
- **Session rows:**
  - "4 windows · 1 client" or "Detached".
  - A separate "Open in iTerm2 here" badge from `AttachmentIndex`. A client count alone never
    implies this Mac, and nothing claims activity or idleness.
- **Other states:**
  - Empty state per host.
  - Per-session progress ("Opening…", "Waiting for iTerm2…", "Waiting for you in iTerm2").
  - Errors with "Retry".
- **Controls:**
  - Search field filtering host and session names.
  - Footer: "New session", "Refresh", "Settings", plus Quit. Quitting leaves all work running.
- **Keyboard:** ↑/↓ move, Return opens, ⌘F search, ⌘R refresh, ⌘N new session, ⌘, settings,
  Esc closes.
- **Appearance and accessibility:** accessibility labels and values on rows and badges;
  readable in light and dark; menu bar icon is an SF Symbol.
- Do not request the iTerm2 cookie at app launch. Request it only when the popover opens while
  iTerm2 is running, or on an attach.

Acceptance: build script exits 0, and `codesign --verify --deep --strict` passes.
`muxFinder --preview-fixtures` screenshots (light and dark, via `screencapture -l`) look right
and are saved under `docs/screenshots/`. The app binary run from the shell shows its menu bar
item and quits cleanly.

### Phase 9 — Settings, onboarding, launch at login, diagnostics (routine)

Goal: host management and first-run guidance (brief: "Host setup and discovery",
"Session lifecycle and user expectations").

Deliverables: Settings window (Hosts, General and Diagnostics tabs), onboarding window, the
"Set up SSH in iTerm2…" action (helper mode `ssh-setup <uuid>` runs plain interactive
`/usr/bin/ssh -- <dest>` in a new iTerm2 tab so the user can accept host keys or authenticate
normally), launch at login through `SMAppService.mainApp`, a diagnostics list plus "Copy
diagnostics", and view-model tests.

Requirements:
- **Host editor:** display name, mode (local or SSH), "This Mac" (exclusive), destination
  (free text plus alias suggestions), tmux path override with "Detect" (runs the probe),
  iTerm2 profile picker (from `ListProfiles` when available, free text otherwise), enabled
  toggle, remove with confirmation, and "Test connection" showing the classified status.
- **Onboarding:**
  - Saturno, Neptuno and Sirio as editable examples, plus the "This Mac" choice.
  - The brief's four expectations, each in one line.
  - The scope line: default tmux server only.
  - The iTerm2 requirements: Python API enabled, and the one-time Automation permission.
- **Fix-it buttons:** Automation-denied and API-disabled errors get buttons that open the right
  System Settings pane or explain the iTerm2 setting.

Acceptance: view-model validation tests pass, preview-fixture screenshots of the Settings and
onboarding states are saved, and the launch-at-login toggle round-trips its status
(`SMAppService.Status`), recorded honestly if it needs the app in `/Applications`.

Split (2026-10-22, before the first worker): Phase 9 is two sub-phases, each with its own
worker, verification, review and commit. Neither opens iTerm2 windows, so both may run while
6b's real runs wait for iTerm2's thread count to fall.

- **9a — Settings window (routine).** The Settings window (Hosts, General and Diagnostics
  tabs) opened by the popover's `openSettings()`; the host editor with every *Host editor*
  requirement above, saving only through `HostStore`; launch at login through
  `SMAppService.mainApp` behind a seam; the diagnostics list plus "Copy diagnostics"; the
  *Fix-it buttons*; Settings preview fixtures and screenshots; view-model tests. Unattended
  real checks only read `SMAppService.mainApp.status` (registering changes the user's login
  items, so the real round trip is owed to the user) and never save the real `hosts.json`.
- **9b — Onboarding and SSH setup (routine).** The onboarding window (every *Onboarding*
  requirement above, shown while the host list is `notSavedYet`), the "Set up SSH in iTerm2…"
  action with its launch request kind and helper mode `ssh-setup <uuid>` (argv only,
  `/usr/bin/ssh -- <dest>` with a validated destination, the helper's 10 s hold kept),
  onboarding preview fixtures and screenshots, and tests. Its real run opens an iTerm2 tab and
  ssh, so unattended it is proven hermetically and the real run (Saturno only) is owed to a
  later real-run window.

### Phase 10 — Attach UX: open, focus, new session, move here, detach (high)

Goal: the brief's "Opening and reconnecting in iTerm2" end to end through the app.

Deliverables: per-session attach state machine in `AppModel`, row actions (Open by default;
context menu with "Move here…" and "Detach from this Mac"), New session sheet (host, name with
inline validation, optional directory, collision error with "Open existing"), banners for
vanished or changed sessions, and hidden self-test flags (`--selftest attach-local`,
`--selftest new-session-local`) that drive the real AppModel path and exit with a status.

Requirements:
- **Clicks:**
  - A click on a session already open here focuses it.
  - Repeated clicks while pending are ignored.
  - "Confirmed" is shown only after core confirmation.
  - "Still connecting — check the iTerm2 tab" comes with a "Show tab" button.
- **Move here** explains, in a confirmation dialog, that it disconnects every other client,
  including other Macs.
- **Detach** is offered only for attachments in this Mac's iTerm2. It uses the core detach
  (never closes tabs) and states that the session keeps running.

Acceptance: state-machine tests with the fake integration (a burst of 5 clicks gives 1 launch;
failure paths each have a distinct message). The self-tests, run from the shell against the
real iTerm2 and local tmux, exit 0. Quit-leaves-work-running check: attach through the
self-test, terminate the app, and verify the tmux session and the iTerm2 connection persist.

### Phase 11 — Persistent Work profiles (high)

Goal: the brief's "Creating persistent work and preventing forgotten tmux" profile flow.

Deliverables: `Profiles/` generator and installer, helper mode `profile <hostUUID>`, a Settings
section, and e2e coverage.

Requirements:
- **The profile file:**
  - One app-owned file, `DynamicProfiles/muxFinder.json`, with one profile per opted-in host.
  - GUID `muxfinder-persistent-<hostUUID lowercase>`. Name "Persistent work – <host>". Tag
    `muxFinder`.
  - Optional parent profile via `Dynamic Profile Parent Name`.
  - `"Custom Command": "Yes"`, `Command` set to the helper path plus `profile <uuid>`, and
    close on end.
  - Written atomically. Rewritten at launch if the helper path changed. Removed on "Remove
    profiles" and by the uninstall script.
- **Profile-mode helper:**
  - Reads `hosts.json`, then runs `new-session -A -s <default name>` with control mode, locally
    or through D3.
  - **Nesting guard:** if `TMUX` or `MUXFINDER_LAUNCHED` is set, it prints why and execs the
    user's login shell instead.
  - On failure it explains, then falls back to a login shell.
- **Settings copy** explains:
  - how to make a profile the default (Settings → Profiles → select → Other Actions → Set as
    Default);
  - that ordinary shells started elsewhere are not adopted into tmux.

Acceptance:
- Hashes of other `DynamicProfiles/*` files, and of the `New Bookmarks` array from
  `defaults export com.googlecode.iterm2 -`, are identical before install, after install and
  after removal.
- iTerm2's `ListProfiles` shows the GUID.
- Real e2e: `CreateTab(profile_name=…)` gets a confirmed control-mode connection to
  `muxfinder-test-profile`, locally and on Saturno. Clean up afterwards.
- A nesting-guard test passes.

### Phase 12 — Packaging, documentation, acceptance run (routine)

Goal: the deliverables in the brief's "Delivery and scope".

Deliverables:
- `scripts/install.sh` (to `/Applications`, or `~/Applications` with `--user`).
- `scripts/uninstall.sh`: quits the app; removes the app, the dynamic profile file and
  `~/Library/Application Support/muxFinder`; tells the user how to clear the login item and the
  Automation permission; never touches tmux sessions.
- `README.md`: purpose, requirements (macOS 14+, Apple Silicon, iTerm2 version as tested, Python
  API enabled, tmux on each host, SSH keys), build from source, install on each Mac (copy the
  app, or build per Mac; signed for development, **not notarized**), permissions, usage,
  persistent profiles, scope and limitations, removal.
- `docs/ARCHITECTURE.md`.
- `docs/TESTING.md` with a **tested vs expected-to-work** matrix covering each acceptance
  bullet of the brief, with dates, commands and results.
- A manual checklist for the user: the LaunchServices Automation prompt, Sirio, launch at login
  from `/Applications`.

Acceptance: a fresh full run of every unit test and every `muxfinder-probe e2e-*` (local and
Saturno) plus the self-tests, all exit 0 and recorded. The build script reproduces the
`.app` from a clean `build/`. The docs state signing status truthfully, and every brief
acceptance bullet maps to evidence or to "unverified: why".

## Deferred (explicitly out of scope for v1)

Named tmux sockets, session deletion, cloud sync, terminal previews, AI features, process
migration, reboot resurrection, workspace management, notarized distribution, Intel builds.
