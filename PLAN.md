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
  `display-message -p -t "$id" '#{pid}:#{session_created}'` still matches. Exit code 64 means
  the session is gone, 65 means it changed (for example, an id reused after a server restart).
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
  Real-world checks run only through `muxfinder-probe` subcommands (`discover`, `e2e-*`; the
  `e2e-*` ones open real iTerm2 windows), are run explicitly during verification, and their
  results are recorded in `docs/TESTING.md`. A mocked attachment is never reported as a real
  integration result.
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
