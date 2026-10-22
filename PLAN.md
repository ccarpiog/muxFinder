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
    Config/                   HostConfig, HostStore (JSON), AppPaths
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
  MuxFinderApp/               SwiftUI menu bar app (MenuBarExtra .window style)
Tests/MuxFinderCoreTests/     Swift Testing, hermetic: no real ssh or iTerm2, never the
                              user's tmux server (one test uses real tmux on a private
                              socket directory and skips when tmux is absent)
  Fixtures/                   discovery outputs, protobuf golden bytes
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
  (`hosts.json`, `launch/`, diagnostics), with directories 0700 and files 0600. The app owns
  exactly one iTerm2 file, `~/Library/Application Support/iTerm2/DynamicProfiles/muxFinder.json`.
  Never write iTerm2 preferences, other profiles, or shell startup files.
- **D9 — Scope.** Only the current user's **default tmux server**; named sockets are deferred.
  The UI and README say so.
- **D10 — UI language is English, sentence case** ("New session", "Move here", "Refresh").
- **D11 — Tests.** `swift test` is hermetic: fakes for the process runner, the clock and
  iTerm2; no ssh; tmux only on a private, test-owned socket directory, never the user's server.
  Real-world checks run only through `muxfinder-probe` subcommands (`discover`, `attach`,
  `e2e-*`; `attach` and the `e2e-*` ones open real iTerm2 windows), are run explicitly during
  verification, and their results are recorded in `docs/TESTING.md`. A mocked attachment is
  never reported as a real integration result.
- **D12 — tmux output is always read through `tmux -u`** (decided in Phase 2, 2026-10-21).
  A tmux client whose locale is not UTF-8 (the first set of `LC_ALL`, `LC_CTYPE`, `LANG` must
  contain "UTF-8") replaces every non-ASCII byte **and every tab** in `-F` output with `_`, so
  Unicode names are lost and tab-separated records can't be split. Noninteractive SSH only
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
  and closing a connection it completes late. Connection order: running check, socket-file
  check, cookie, connect, handshake, so no cookie is requested while iTerm2 is not running or
  its API is off. Socket missing, refused or not a socket → `apiDisabled`; HTTP 401 →
  `authRejected`. The client announces the library version `python 2.11` that the protocol
  facts were checked against.
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
    entries. So, through descriptors (`ExtendedACL`): every open of the launch directory
    removes any extended ACL from it and refuses the directory (73) if that fails; every file
    the store creates loses any inherited ACL before its first byte is written; and a file
    being taken is refused (and deleted) if it carries any extended ACL entry, even a
    deny-only one. That strict rule works on a normal home directory: the ACL macOS puts on
    home folders (`group:everyone deny delete`) is not inheritable. A deny-delete entry also
    blocks the owner's unlink, so the store removes the ACL of a file the user owns before
    deleting it. Only the launch directory and its files are covered, not the Application
    Support root above it.
  - **Exit codes:** guard 64 gone, 65 changed, 66 tmux missing (the D5 rule, discovery's
    `tmuxNotFound`), 67 tmux check failed, 68 guard usage. Helper 2 usage, 70 request missing,
    71 expired, 72 unreadable, 73 launch directory unusable, 74 spawn failed, 75 check timed
    out, 128 + n interrupted by signal n before tmux attached; otherwise tmux's own status (0
    after a detach, 1 on errors), and 128 + n for signal n. 255 is left to ssh (Phase 5).
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
    **attach** is `<path> -u -CC attach-session -t <id>`, spawned directly with no shell.
    D12's `-u` applies to control mode too, so the formats iTerm2 requests keep UTF-8 and
    tabs. This replaced a single guard that `exec`ed tmux: its locator and `display-message`
    subprocesses had no deadline and were out of reach of a signal sent to the shell, and
    putting the shell in its own group would have stopped tmux with `SIGTTIN`. The price is
    the check-to-attach window described in D4.
  - **Helper process:** the attach child runs on the helper's own terminal: descriptors 0–2
    are inherited (never pipes), the child stays in the helper's foreground process group (a
    background group would get `SIGTTIN`), and it starts with default dispositions. The helper
    ignores SIGHUP, SIGINT and SIGTERM for its whole life and watches them with
    `EVFILT_SIGNAL` from its first instructions (`TerminalChildControl.watchTerminalSignals()`,
    which `LaunchHelper.standard()` starts): one that arrives before tmux attaches ends the
    launch as `interrupted(n)` without attaching (a running check is stopped with its whole
    process group, the same way as on a timeout); one that arrives while tmux runs is passed
    on to tmux. So closing the tab never orphans tmux or a check subprocess, and the result is
    always written. It restores the defaults only for the final wait. On failure it prints a
    one-paragraph explanation, and waits for Return only when stdin is a terminal,
    `MUXFINDER_LAUNCH_NO_WAIT` is not `1`, and no SIGHUP arrived.
  - **Test mode:** set by `MUXFINDER_LAUNCH_TEST_MODE=1`, or by a regular file
    `launch/test-mode` owned by the user. The marker is how 4b turns test mode on for helpers
    iTerm2 starts: the e2e run creates it (`LaunchStore.createTestModeMarker()`) and removes it
    in cleanup (`removeTestModeMarker()`), and the sweep leaves it alone. In test mode the
    helper writes `launch/argv-<pid>.json` before parsing argv: the argument count, then each
    argument's byte length and SHA-256, plus the first canonical launch id found.
    `LaunchStore.takeArgvDigests()` reads them.
  - **Overrides and paths:** `MUXFINDER_LAUNCH_DIRECTORY` (absolute) replaces the launch
    directory for development and tests; a relative or empty value is refused (73).
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
  - **Single flight** by `SessionKey`: concurrent callers share one launch and one result; when
    every waiting caller is cancelled, the launch stops at its next step (`cancelled`). A caller
    arriving while such a launch winds down (its `CreateTab` still pending) starts a new one;
    from then on only the newest launch of the session sets `state(of:)`. The older launch's
    updates are still delivered, with `AttachUpdate.isCurrent == false`, so its launch tab
    stays known.
  - **Failures:** every failure before a connection was found withdraws the request file, so a
    tab that starts late cannot attach. The read-only polls (`ListConnections`, `ListSessions`)
    end the attach at their first failure rather than retry it; `CreateTab`, the identity
    `SendCommand`, `Activate` and `detach-client` are sent once (D13). An unreadable or
    mismatching identity answer detaches the new connection once its launch tab is old enough
    (see *Teardown*); the attach reports the failure after that detach.
  - **Teardown:** ending a connection ends its launch tab, and a launch tab that ends within
    seconds of opening makes iTerm2 block its whole API behind a modal warning (*Verified
    facts*, Phase 4b). So the coordinator sends `detach-client` (after a failed identity check,
    and for `detach`) only once the launch tab is `minimumLaunchTabAge` old: 10 s, the margin
    `e2e-local` adopted after run 1, whose warning followed an end about 1.5 s after the start.
    The age counts from the `CreateTab` answer for tabs this coordinator opened (it remembers
    the latest 64), and from the call for any other tab (another process's, as with
    `muxfinder-probe detach`), which exists already and so is old enough once the time has
    passed. The identity-failure detach runs in a task of its own that the attach waits for,
    so cancelling the attach neither skips the wait nor ends the tab early; a `detach`
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
    error) and nothing is sent.
  - **Identity command:** `display-message -p "#{pid}\t#{start_time}\t#{socket_path}\t#{session_id}"`
    (double quotes: tmux turns `\t` into a tab there; verified with tmux 3.8 in control mode),
    parsed on bytes: pid and start time first, session id last, the socket path in between.
  - **Activation** is part of the result, not a state: the first tab carrying the connection id
    (waited for up to 5 s) is activated with `select_tab`, `order_window_front` and the app
    options, without `select_session` (iTerm2 refuses that for a tab target). A confirmed
    attach whose tab never appears, or whose `Activate` fails, stays confirmed.

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

Verified in Phase 4b (2026-10-22, iTerm2 3.7.6 with default preferences, tmux 3.8, the default
tmux server holding only `muxfinder-test-*` sessions; details in `docs/INTEGRATION-PROOF.md`):

- **`Command` property:** with `"Custom Command" = "Yes"` and `"Command" = "<path> attach
  <uuid>"`, the helper got exactly 3 arguments: argv[0] the absolute path, `attach`, the id
  (argv digest). A path with a space was not tried, so the D2 rule stands.
- **Launch tab:** `CreateTab` without `window_id` opens a new window holding only that tab. Its
  `session_id` is the connection's `owning_session_id`. It carries `tmux_window_id` `"-1"` and
  no connection id, and stays in its window while attached (not buried).
- **tmux windows** open as native windows with the default "open tmux windows as" preference:
  one new iTerm2 window per tmux window, one tab each.
- **tmux tabs** carry `tmux_window_id` = the tmux window id without `@` (`"0"`, `"1"`) and
  `tmux_connection_id` = the connection id. A window split in two arrives as one splitter with
  two session leaves (tmux's default top/bottom split as `vertical = false`).
- **Connections:** `ListConnections` lists the new connection within about 0.5 s of the tab
  opening. Its `connection_id` is a short name (`"tmux"` for the first one), not a UUID, so
  connections are matched by `owning_session_id`.
- **Activate:** a tab target with `select_session = true` is refused with `INVALID_OPTION`; a
  tab target with `order_window_front`, `select_tab` and the app options in one request works.
- **Detach:** `SendCommand detach-client` is answered with empty output and the connection
  disappears at once. iTerm2 closes the connection's tabs without a dialog, `tmux -CC` exits 0,
  the helper records success, and its launch tab closes by itself (`Close Sessions On End`).
  The session keeps its id, windows, panes and processes.
- **Short-lived sessions block iTerm2:** a session that ends within a few seconds of starting
  (here about 1.5 s: attach, then an immediate detach) makes iTerm2 show its "session ended
  very soon after starting" warning (`-[PTYSession _maybeWarnAboutShortLivedSessions]`, a modal
  `iTermWarning`, silenceable per profile). While it is open, iTerm2's API answers nothing
  (WebSocket handshakes time out), although AppleScript cookie requests still return. Only a
  person can dismiss it. So nothing may end a launch tab, or detach its connection, within
  seconds of opening it: the coordinator sends `detach-client` only once the launch tab is
  10 s old (D15), and `e2e-local` waits as long before it kills its session or closes a launch
  tab.

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
  is in the Phase 4b facts above.
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
    (tmux rewrites them), no leading `-`, Unicode allowed.
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
  7. Check identity with `SendCommand display-message -p '#{pid}\t#{start_time}\t#{socket_path}\t#{session_id}'`
     through that connection.
  8. The state becomes `confirmed`.
  9. `Activate` the first tab carrying that `tmux_connection_id`.
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

### Phase 6 — Session operations: create, move here, disappeared sessions (high)

Goal: New session, Move here and vanished-session handling, all correct at the core level.

Deliverables: `TmuxCommands` (detached create with `new-session -d -P -F` returning id, created
time and server identity; `-c <dir>` with `~/` expansion inside the static script),
`createAndAttach`, `moveHere` (`attach-session -d`, which requires an explicit confirmation flag
in the API), typed `sessionGone` and `sessionChanged` errors that trigger a refresh,
`muxfinder-probe new-session --host … --name … [--dir …]`, and e2e coverage.

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
