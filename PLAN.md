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
                              AttachmentIndex (iTerm2 tmux connections -> session keys),
                              LaunchTab (the shared launch tab), SSHSetupLauncher (D24)
    Refresh/                  RefreshCoordinator actor, backoff, live/stale snapshots
    Profiles/                 Persistent Work dynamic-profile generator/installer, the hash
                              snapshot of iTerm2's other profiles, the e2e-profile run (D26)
    Diagnostics/              operation log (ring buffer + os.Logger), no terminal content
  muxfinder-launch/           helper executable that iTerm2 runs inside the launch tab
  muxfinder-probe/            developer/diagnostic CLI that drives the core without the GUI
  MuxFinderUI/                library: AppModel, popover content and views, the Settings
                              window (SettingsModel, views, window controller), the
                              onboarding window (OnboardingModel, view, window controller),
                              preview fixtures (D22, D23, D24); tests import it
  MuxFinderApp/               SwiftUI menu bar app (MenuBarExtra .window style): entry
                              point, scene and app delegates only
Tests/MuxFinderCoreTests/     Swift Testing, hermetic: no real ssh or iTerm2, never the
                              user's tmux server (one test uses real tmux on a private
                              socket directory and skips when tmux is absent)
  Fixtures/                   discovery outputs, protobuf golden bytes
Tests/MuxFinderUITests/       Swift Testing, hermetic: the app model over fakes
scripts/                      build-app.sh, install.sh, uninstall.sh (D27), lib/ shared by
                              the two, dev/ helpers and the scripts' hermetic check
docs/                         REQUIREMENTS, ARCHITECTURE, INTEGRATION-PROOF, TESTING,
                              MANUAL-CHECKLIST (the checks owed to a person)
README.md                     purpose, requirements, build, install, permissions, usage
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
session, verifies its identity, and then activates the tab. "Set up SSH in iTerm2…" opens the
same kind of launch tab with `muxfinder-launch ssh-setup <uuid>`, whose helper runs plain
interactive `/usr/bin/ssh -- <destination>` there (D24).

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
  ad-hoc fallback warns that macOS permission grants reset on every build. Everyday builds are
  not notarized; `scripts/release.sh` signs with Developer ID and notarizes (D28). Never claim
  notarization for a build that did not go through it. Target arm64 only, since all three
  Macs are Apple Silicon (M4, M4, M5).
- **D8 — Storage.** Configuration lives in `~/Library/Application Support/muxFinder/`
  (`hosts.json`, `launch/`, diagnostics), with directories 0700 and files 0600, and no
  extended ACL (D14 for `launch/`, D19 for the folder itself and `hosts.json`). The app owns
  exactly one iTerm2 file, `~/Library/Application Support/iTerm2/DynamicProfiles/muxFinder.json`,
  written and removed only by `PersistentProfileInstaller`, which never touches another entry of
  that folder (D26). Never write iTerm2 preferences, other profiles, or shell startup files.
- **D9 — Scope.** Only the current user's **default tmux server**; named sockets are deferred.
  The UI and README say so.
- **D10 — UI language is English, sentence case** ("New session", "Move here", "Refresh").
- **D11 — Tests.** `swift test` is hermetic: fakes for the process runner, the clock and
  iTerm2; no ssh; tmux only on a private, test-owned socket directory, never the user's server.
  Real-world checks run only through `muxfinder-probe` subcommands (`discover`, `attach`,
  `new-session`, `e2e-*`, `hosts`, `profiles`, `refresh`; all but `discover`, `hosts`,
  `profiles` and `refresh` open real iTerm2 windows) and the app binary run from the shell (D22: the preview window and the
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
    at most 16 KiB. Each helper mode takes only requests of its own kind (D24): an attach
    request has no `kind` field (so every file written before ssh setup existed reads exactly
    as before), an ssh setup request has `"kind":"sshSetup"`, and a well-formed request of the
    other kind is refused (72), gone like every refused request. TTL: 120 s after `createdAt`
    (5 s future tolerance), on an injectable
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
    71 expired, 72 unreadable (also a request of the other kind, D24), 73 launch directory
    unusable, 74 spawn failed, 75 check timed out, 76 and 77 in `profile` mode when it ends
    without starting the login shell (the host list or host unusable; the nesting guard; D26),
    128 + n interrupted by signal n before tmux attached; otherwise tmux's own status (0
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
  - **Helper process:** every child gets the helper's environment minus `TMUX`, `TMUX_PANE` and
    the `MUXFINDER_LAUNCH_*` variables, plus `MUXFINDER_LAUNCHED=1`, the nesting guard's
    variable (D26). The attach child runs on the helper's own terminal: descriptors 0–2
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
    ends that wait like Return (seen through dispatch signal sources, which stop the wait's
    reader, `TerminalReturnReader`). That reader reads only after `poll`, through a
    non-blocking descriptor of its own for the terminal, and also polls a wake pipe the stop
    writes to, so it ends at once; the wait returns only once it has (Phase 13a review, D29),
    so nothing reads the terminal after the wait.
  - **Minimum lifetime** (decided in Phase 4c, 2026-10-22): under that same condition the helper
    never exits before it is 10 s old (`LaunchHelper.minimumLifetime`, counted from its start),
    whatever the outcome and in every mode (`attach` or `ssh-setup`, D24, through
    `LaunchHelper.finish`; `profile`, D26, except when it hands the tab to the login shell,
    which keeps it open): it writes the result first, waits for Return if it failed,
    then holds the rest (`LaunchTerminal.holdOpen(for:)`: closing the tab, SIGHUP, still ends it
    at once; SIGINT and SIGTERM never end it, so Ctrl-C at the prompt or during the hold cannot
    end a visible tab early). A launch tab that ends within 3 s of starting raises iTerm2's
    blocking short-lived-session warning (*Verified facts*, Phase 4), and tmux can end right
    after attaching (iTerm2 or someone detaching early, the session killed), ssh can fail at
    once, or Return can be pressed at once; the coordinator's own 10 s wait (D15) covers only
    the ends it causes.
  - **Launch tab restore** (Phase 13a, 2026-10-24; design item 4 of Phase 13, D29): in
    `attach` mode only, once the attach child (tmux, or ssh) has run, whatever its end, and
    unless a SIGHUP came (no child, a refused request or a failed check: none), the helper
    writes the result, then a line feed (`LaunchHelper.tmuxModeEndSequence`), `OSC 1337 ;
    Disinter ST` and a status report request (`ESC [ 5 n`) to its terminal, and waits for the
    answer `ESC [ 0 n` in raw mode (non-canonical, no echo; input typed earlier discarded first,
    any other byte dropped, the modes restored on every path; `TerminalStatusRequest`). The
    whole exchange, writes included, ends within 2 s (`LaunchHelper.tabRestoreTimeout`): one
    deadline taken at its start bounds every `poll`, and it writes and reads only through
    non-blocking descriptors of its own for the terminal (opened again, so the descriptors
    shared with the attach child stay blocking; only if that fails, `O_NONBLOCK` on the shared
    one for the exchange, restored after), so a tab that takes no output or input another
    reader took cannot hold it. When that goes unanswered (after an
    abnormal end iTerm2 still parses the tab in tmux mode: the line feed ends that, and the
    rest of that write is lost, D29) it writes `Disinter` and the request again at once. Then
    the explanation, the wait for Return and the hold as above, and just before it exits
    `Disinter` and the request once more. Nothing is written unless standard input and output
    are both terminals (`unavailable`). A missing answer is logged (stage and wait only) and
    the helper goes on. `profile` and `ssh-setup` never do it.
  - **Test mode:** set by `MUXFINDER_LAUNCH_TEST_MODE=1`, or by a regular file
    `launch/test-mode` owned by the user. The marker is how 4b turns test mode on for helpers
    iTerm2 starts: the e2e run creates it (`LaunchStore.createTestModeMarker()`) and removes it
    in cleanup (`removeTestModeMarker()`), and the sweep leaves it alone. In test mode the
    helper writes `launch/argv-<pid>.json` before parsing argv: the argument count, then each
    argument's byte length and SHA-256, plus the first canonical launch id found. Right before
    it starts its attach child (tmux locally, ssh remotely) it writes the file again with
    `attachChild`: that child's argv digested the same way and whether it detaches the
    session's other clients (D21); a launch that ends first has none. In `attach` mode it then
    writes it again with `attachChildProcessID` right after the spawn (the child is the
    helper's own and unreaped while it runs, so a harness can signal exactly it) and with one
    `tabRestores` record per launch tab restore (`afterChild`, `afterTmuxModeEnd` when the
    first went unanswered, `beforeExit`: whether `Disinter` was written, when it asked and when
    the wait ended, `answered`/`unanswered`/`unavailable`, the answer's delay in ms); both
    fields are optional, so the format stays version 1. In
    `profile` mode the login shell is recorded there instead of started (`startsLoginShell`,
    D26), and the helper reads a test host list for its host id from the launch directory when
    one exists. `LaunchStore.takeArgvDigests()` reads them.
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
  - **Suppressed restore** (Phase 13a, 2026-10-24): a request may carry
    `testSuppressDisinter: true` (absent from every request the app writes). Only in test mode
    does the helper honor it: every launch tab restore then writes the status report request
    without `Disinter` (recorded as `wroteDisinter: false`; the first restore's line feed still
    goes out), so a tab buried through the API stays buried. `e2e-bury`'s step (b) uses it.
  - **Overrides and paths:** `MUXFINDER_LAUNCH_DIRECTORY` (absolute) replaces the launch
    directory for development and tests; a relative or empty value is refused (73).
    `MUXFINDER_LAUNCH_MINIMUM_LIFETIME_MS` (1 to 7 decimal digits, tests only) replaces the
    10 s minimum lifetime, so tests can run the binary in a pseudo-terminal quickly; any other
    value keeps 10 s.
    `LaunchHelperPath.locate()` finds `muxfinder-launch` next to the running executable and
    applies the D2 rule. The tab command is `LaunchHelperPath.commandLine(for:kind:)`:
    `<path> attach <uuid>` (`attachCommandLine(for:)`), or `<path> ssh-setup <uuid>` for "Set
    up SSH in iTerm2…" (D24); a persistent profile's `Command` is `<path> profile <host id>`
    (`profileCommandLine(forHostID:)`, D26).
- **D15 — Attach coordinator** (decided in Phase 4b, 2026-10-22; code in
  `Sources/MuxFinderCore/Attach/`).
  - **Launch tab:** `CreateTab` without `window_id`, so the tab opens in a new window and never
    in one of the user's, with the host's profile and `Close Sessions On End = true`: it closes
    by itself after a clean detach, and after a failure once the user pressed Return. The
    request runs in a task of its own, so cancelling an attach never loses the new tab's
    session id (the result reports it on every failure after the tab opened). Both the request
    and that task are `LaunchTab` (`Attach/LaunchTab.swift`), which "Set up SSH in iTerm2…"
    uses too (D24), so muxFinder opens tabs in iTerm2 one way only. Once an attach is confirmed
    and its first tmux tab activated, the coordinator buries its launch tab, and the helper (or
    the coordinator's recovery) restores it when tmux ends (D29, built in Phase 13b). A buried
    launch tab still owns its connection, so *Connection binding* below holds unchanged.
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
  - **`createAndAttach(_:onCreated:)`:** creation through the coordinator's `SessionCreating`
    seam (`TmuxCommands()` by default), then the attach of the created target with the
    existing-attachment check (step 1b, D16) skipped. A session created a moment ago cannot
    be attached in iTerm2 yet, so none of the user's tmux connections is asked anything; the
    only iTerm2 requests are the launch's own. Revalidation still runs: it confirms the session
    and gives the node name for the identity check. A creation failure returns before
    discovery, the request file, `ensureRunning` or `CreateTab`, so it never opens a tab.
    `CreateAndAttachResult` carries the created session, the creation failure or the attach.
    The optional `onCreated` gets the created session after a successful creation and before
    the attach publishes any state, so the app follows that attach on the new session's row
    (D25); it is never called for a failed creation.
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
    `isEnabled`, and `tmuxPathOverride`, `iTermProfileName`, `defaultSessionName` and
    `persistentProfileParentName` only when set, `persistentProfileEnabled` only when `true`
    (D26; a file without them loads with the defaults and saves back unchanged). Written
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
    whitespace or control characters, no leading `-`); a set default session name passes
    `Validation.persistentSessionName` exactly as stored, and a set persistent profile parent
    `Validation.profileName` (D26). A disabled SSH host may hold any
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
    given for one session could move another). The popover's Move here confirmation (D25) is
    in front of it.
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
    executable keeps only the entry point, the `MenuBarExtra(.window)` scene (muxFinder's
    template icon, D28; the SF Symbol `terminal` when unbundled) and the app delegates (the menu bar app's, the preview window's and the
    self-tests', D25). `PopoverContent` is a pure value computed from the
    engine's `RefreshState`, the search text, per-session activities, the selection and
    `now`; every displayed rule lives there and is tested without SwiftUI.
  - **Model and engine:** `AppModel` (`@Observable @MainActor`) runs on an `AppEnvironment`
    (host loading, engine, system-events and attach-coordinator factories, wall clock,
    terminate), so tests pass fakes. `start()` loads the list with `HostStore.load()` (never writes; an unusable folder
    gives an empty list and a notice), in normal mode only and for a list loaded as `saved`
    has Settings bring an installed, out-of-date persistent profile file up to date in the
    background (`AppEnvironment.rewritesProfilesAtLaunch`, D26; the only write at launch),
    shows the onboarding window when it loaded as
    `notSavedYet` (D24), builds the `RefreshCoordinator` for it
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
    ignored). Per-session activity ("Opening…", "Waiting for iTerm2…", "Still connecting —
    check the iTerm2 tab" with "Show tab", "Confirmed…", a failure with its recoveries) is model
    state set by D25's attach state machine; `SessionActivity.init(_:movingHere:)` maps
    `AttachState`.
  - **iTerm2 and its cookie:** nothing contacts iTerm2 at launch, the onboarding window
    included (D24). The popover's only iTerm2 requests on their own are the engine's
    attachment checks, which run only while the popover is visible and are cancelled when it
    closes (D20); the Settings window adds one, the profile list, asked only when its window
    opens while iTerm2 runs (D23); "Set up SSH in iTerm2…" (D24) contacts iTerm2, and may
    launch it, only when the user clicks it. The client checks that iTerm2 runs before it asks
    for the cookie (D13). So the cookie is requested when the popover or the Settings window
    opens while iTerm2 runs, when the user chooses "Set up SSH in iTerm2…", and when the user
    acts on a session (D25); never at launch, once the popover has closed (a cookie request, connection or
    identity question the check had not made by then is never made), or while iTerm2 is not
    running. Tested
    through the real `ITerm2APIClient` with counting and gated cookie providers, a fake
    running check and fake connectors.
  - **Popover visibility and keys:** `PopoverWindowBridge` follows the menu bar extra's
    window: open while it is visible and not occluded, rechecked on becoming or resigning key,
    occlusion changes and closing (repeats ignored). A local key-down monitor for that window
    turns ↑/↓, Return, Esc, ⌘F, ⌘R, ⌘N and ⌘, (`PopoverKey`) into `AppModel.handle(_:)`
    before the search field sees them (not while an input method composes); Esc closes the
    window. The arrows move through the listed rows only. No unattended run can open the real
    popover (no UI scripting), so this glue is checked by the model's tests and by hand only.
  - **Actions:** a click or Return opens a session, the row's context menu offers "Move
    here…" and "Detach from this Mac", and "New session" and ⌘N show the New session sheet,
    all through D25's attach state machine. "Settings" and ⌘, open the Settings window (D23).
    A failure's "Try again" repeats its action. A host's sign-in or host key problem also
    offers "Set up SSH in iTerm2 first" (D24).
  - **Quit:** "Quit", SIGTERM and SIGINT go through `AppTermination.request()`, which calls
    `terminate(_:)` from a run-loop block. `applicationShouldTerminate` answers
    `.terminateLater`, runs `AppModel.shutdown()` and replies, so the process exits 0.
    `shutdown()` starts every stop at once: it cancels the session actions in progress (D25)
    and, without waiting for them, stops Settings (`shutdown()`, which refuses new work and
    cancels and awaits its probes and window opening, D23), onboarding's and the popover's
    "Set up SSH in iTerm2…" requests (cancelled and awaited, D24) and, in this order, the
    queue (dropping requests not yet handed over), the system events adapter and the engine,
    whose `stop()` cancels any attachment check and kills any probe's process group. It waits
    for the cancelled session actions at most `AppModel.sessionActionShutdownBudget`, 12 s: a
    cancelled attach whose `CreateTab` was already sent first waits for iTerm2's answer (the
    request runs in a task of its own so the tab's session id is never lost, D15; the API
    client's request timeout is 10 s) and then withdraws its request, and one whose identity
    check failed sends its `detach-client` only once the launch tab is 10 s old. Actions
    still running after the budget are reported (the system log and the operation log, kinds
    only, and `ShutdownReport`) and not waited for. The deadline that replies anyway,
    `AppModel.terminationDeadline` (15 s, used by the menu bar app and the self-tests' keep
    mode), is that budget plus 3 s, so the session actions' cleanup is never cut off before
    the model reported on it, Settings, the probes and the engine stop whatever the session
    actions do, and quitting never hangs; with no session action in progress nothing waits
    for the budget. Calling `terminate(_:)` from a main-queue block or a
    main-actor task never returned: AppKit waits for the reply in a nested run loop, which
    cannot drain the main queue while one of its blocks runs, and the shutdown task needs it.
    Quitting detaches nothing, kills no session and closes no tab; an attach still in progress
    is cancelled (it withdraws its request, D15).
  - **Preview fixtures:** `--preview-fixtures` runs a plain `NSApplication` (no SwiftUI scene,
    so no status item, and nothing recorded for one; no engine, host list or iTerm2) with one
    normal window of every state in `PreviewFixtures.all` (with `--preview-gallery settings`,
    `SettingsFixtures.all` instead, D23; with `--preview-gallery onboarding`,
    `OnboardingFixtures.all`, D24; with `--preview-gallery attach`, `AttachFixtures.all`,
    D25): synthetic names, `*.example`
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
    hosting `SettingsView` with the Hosts, Persistent profiles (D26), General and Diagnostics
    tabs. It is made on first
    use and reused: `AppModel.openSettings()` (the footer's "Settings", ⌘, in the popover, the
    "Open Settings" placeholder button) calls `AppEnvironment.presentSettings`, which calls
    `NSApp.activate()` (an accessory app stays behind the active app otherwise) and brings the
    window to the front. Opening a closed window calls `SettingsModel.windowDidOpen()`, which
    runs the opening (login item status, host list, then profiles, suggestions, log and the
    persistent profile file's status, D26) in a
    task the model owns; closing it calls `windowDidClose()`: the opening is cancelled (with
    the profile request inside it, so the iTerm2 client stops before its next contact, and a
    cancelled `ITerm2ProfileSource` asks nothing), late results are dropped by window
    generation and nothing more starts, probes and "Set up SSH in iTerm2…" requests (D24) are
    cancelled and dialogs dropped (unsaved edits are lost, since the next opening reloads the
    list); becoming key reads the login item status again. Quitting runs
    `SettingsModel.shutdown()` from `AppModel.shutdown()` (D22): no opening, load, profile
    request, probe, ssh tab or save starts any more, the opening, every probe still running (a
    replaced one too) and any ssh tab request are cancelled, and it returns only once all have
    ended, so no probe's process group outlives the app. The window
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
    versions, the clock, `SSHSetupOpening` (`SSHSetupLauncher`, D24; the onboarding window
    and the popover use it from here too), and `PersistentProfileManaging`
    (`PersistentProfileFiles`, D26). `AppEnvironment` gained `openURL`,
    `presentSettings`, `presentOnboarding` (D24), `settings` and `diagnostics`. Tests pass
    fakes for every one; saves are also tested through a real `HostStore` in a private folder.
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
    (`notSavedYet`) are editable, with a note that nothing is saved until a change; at launch
    the onboarding window offers them too (D24), and a list saved there makes a later save
    here, from a window opened before it, refuse as a changed file.
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
    and session failures (`SessionActivity.failed(message:fixIt:)`), Settings' profile note
    and Diagnostics tab, and a failed "Set up SSH in iTerm2…" line (D24) show them. The
    Automation URL was not opened in an unattended run.
  - **Preview fixtures:** `--preview-fixtures --preview-gallery settings` shows
    `SettingsFixtures.all` (16 states, the persistent profile fields and tab's included) in the
    same plain preview window, with the same
    `--appearance` and `--preview-snapshot` flags; screenshots
    `docs/screenshots/settings-states-{light,dark}.png`. Synthetic data only (`*.example`
    destinations, invented profile and suggestion names, a fixed log).

- **D24 — Onboarding and "Set up SSH in iTerm2…"** (decided in Phase 9b, 2026-10-22; code in
  `Sources/MuxFinderUI/Model/OnboardingModel.swift`, `SSHSetupActions.swift`,
  `Views/Onboarding/`, `Preview/Onboarding{Fixtures,Gallery}.swift`;
  `Sources/MuxFinderCore/Launch/LaunchModels.swift`, `LaunchStore.swift`, `SSHSetup.swift`,
  `LaunchHelper.swift`; `Attach/LaunchTab.swift`, `Attach/SSHSetupLauncher.swift`).
  - **When onboarding shows:** `AppModel.start()` hands the launch's load result to
    `OnboardingModel.prepare(_:)`, which accepts only `notSavedYet` (no `hosts.json` yet), and
    then shows the window through `AppEnvironment.presentOnboarding`
    (`OnboardingWindowController.shared`: one AppKit window, "Welcome to muxFinder", 780×760
    points, at least 700×480, resizable, not restorable, no saved frame, the Settings window's
    class for its editing keys and ⌘W; `NSApp.activate()` brings it forward). Never for a
    `saved` list; an `invalid` file keeps D23's banner and the popover's notice; an unreadable
    folder shows nothing. Closing it without saving brings it back at the next launch, while
    the list is still not saved. Preparing and opening it reads nothing more, contacts no
    iTerm2 and runs no ssh or tmux; the examples are turned off, so the engine discovers
    nothing either.
  - **Content:** the examples (D19's defaults: Saturno, Neptuno and Sirio, SSH, no
    destination, turned off) as rows with the name, the SSH destination (This Mac's row says it
    is checked directly), "Set up SSH in iTerm2…", a "This Mac" checkbox and "Turned on"; then
    the brief's four expectations one line each, the scope line (default tmux server only) and
    the iTerm2 requirements (the Python API on; the one-time Automation permission)
    (`OnboardingText`). The tmux path, the profile, adding and removing hosts stay in Settings.
  - **Editing** reuses D23's `HostDraft` and `HostDraftIssues` (name required, at most 50
    characters and unique among the rows; a destination empty or valid, required to turn an
    SSH host on, `setEnabled(_:for:)` refusing with the reason). This Mac is exclusive and
    follows D19's switch: the chosen row becomes local and turned on, the previous This Mac
    goes back to SSH, turned off, its destination kept; unchecking leaves none.
  - **Saving:** "Save hosts" builds a checked `HostList` from the rows and saves it only
    through `HostListPersisting.save(_:expecting:)` (the app's `HostStore`) with the revision
    of the launch's load. A file that appeared since (Settings saved, or another program) is
    left as it is: nothing is written or backed up, the window says "The host list file
    changed after muxFinder loaded it (for example, it was saved in Settings), so nothing was
    saved here…", stops editing and offers "Open Settings". A saved list goes to the app like
    one saved in Settings (load status `saved`, `RefreshCoordinator.setHosts(_:)`) and the
    window closes. Closing the window, or "Not now", writes nothing. The log records the
    outcome with counts only (hosts turned on, whether This Mac was chosen).
  - **Request kind:** `LaunchRequestKind` (`attach`, `sshSetup`) is the request file's `kind`.
    An attach request is still written without it, byte for byte as before;
    `LaunchRequestFile.decode(_:)` reads a file without `kind` (every older file) or with
    `"attach"` as a `LaunchRequest`, `"sshSetup"` as an `SSHSetupRequest` (`formatVersion`,
    `kind`, `id`, `createdAt`, `hostID`, `destination`; nothing else), anything else as
    unreadable (72). `LaunchStore.writeRequest(_:)` refuses an ssh setup request that is not
    well formed before creating anything; `takeRequest(_:)` and `takeSSHSetupRequest(_:)` refuse
    a well-formed request of the other kind (`requestKindMismatch`, 72), which, like every
    refused request, is gone. Rejected: optional session fields on `LaunchRequest`, which
    would have changed how attach requests decode.
  - **Helper mode:** `muxfinder-launch ssh-setup <uuid>` (usage `attach|ssh-setup <launch id>`)
    takes only an ssh setup request and runs one child on the tab's terminal, exactly
    `/usr/bin/ssh -- <destination>` (`SSHSetup.sshArguments`), by argv: no option (no `-t`,
    `ConnectTimeout` or `BatchMode`), no remote command (ssh starts the login shell), nothing
    that weakens host-key checking, the user's configuration, keys and agent as they are, the
    helper's cleaned environment (D14), ssh's standard error relayed and classified as in D17.
    Any exit but 255 is a success (ssh connected and signed in; the status is the remote
    shell's), 255 is `sshFailed(class)`, a signal `childSignaled`; the tab's wording is
    `LaunchFailure.sshSetupExplanation`. Every way out goes through D14's finish: the result
    file first (nobody waits for it; the sweep removes it), the explanation, the wait for
    Return after a failure, and the hold until the helper is 10 s old, so ssh failing at once
    never ends the tab inside iTerm2's 3 s window; only a closed tab (SIGHUP) ends it early.
    In test mode the argv digest records the ssh child (`detachesOtherClients` false).
  - **Validation:** the destination passes `Validation.sshDestination(_:)` (not empty, no
    whitespace or control characters, no leading `-`) before the launcher writes anything or
    contacts iTerm2, when the store writes and takes the request, and again before ssh starts;
    a destination ssh could read as an option never reaches a process.
  - **Opening the tab (`SSHSetupLauncher`, the `SSHSetupOpening` seam):** refuses This Mac, an
    invalid destination or a missing helper before anything; sweeps, writes the request,
    `ensureRunning()` (it may launch iTerm2: the user clicked), then `CreateTab` through
    `LaunchTab` (D15: a new window, the host's profile, the command `<helper> ssh-setup
    <uuid>`, Close Sessions On End), over the app's shared `ITerm2APIClient` and `LaunchStore`.
    A failure after the write, or a caller cancelled before `ensureRunning()` or `CreateTab`,
    withdraws the request. It returns `opened(sessionID)` or `failed(SSHSetupFailure)` and does
    not watch the tab: what ssh does there is for the user to see. The UI says so honestly:
    "iTerm2 opened a new window running ssh to this host. Sign in or answer the host key
    question there, then check the host again." or "muxFinder couldn't open ssh in iTerm2.
    <reason>", with D23's fix-it for an iTerm2 error. The log records the outcome kind,
    duration and host id, never the destination. Rejected: a second iTerm2 route (AppleScript
    or typed text), and waiting for the helper's result (the login can last hours).
  - **Where it is offered (`SSHSetupActions`, one per window):** each onboarding row with an
    SSH destination that passes validation (the destination as typed; nothing is saved for
    it); the Settings host editor under the destination ("Set up SSH in iTerm2…"), replaced
    by "Set up SSH in iTerm2 first" under a Test connection result of "Sign-in needed" or "Host
    key problem"; the popover under a host whose last check failed `authFailed` or
    `hostKeyProblem` ("Set up SSH in iTerm2 first"; "Retry" forgets its line). One request
    per host at a time while its line shows; each line waits for one request's result only,
    so changing the destination or mode (or "Retry") forgets the line and drops the result of
    a request still running, asked for the old values, and a new request may start at once;
    closing the window cancels the requests still running and forgets the lines. A cancelled
    or dropped request may still run (once `CreateTab` was sent, the launcher waits for
    iTerm2's answer), so each window keeps every request until it ends, and quitting cancels
    and awaits all of them, a closed window's too.
  - **Real runs:** `muxfinder-probe ssh-setup --ssh <dest> [--profile <name>]` opens the tab
    the app's way and prints the outcome (no destination). It opens a real iTerm2 window and
    starts a real ssh login, so it never ran unattended: the real run (Saturno only; its tab
    must end at least 10 s old, and an unattended run first needs a way to close its own tab
    by the printed session id) is owed to a real-run window.
  - **Preview fixtures:** `--preview-fixtures --preview-gallery onboarding` shows
    `OnboardingFixtures.all` (7 states: the examples, This Mac chosen with a tab opened,
    validation errors, a tab opening and one failing with its fix-it, saving, a list saved
    elsewhere, a failed save); screenshots `docs/screenshots/onboarding-states-{light,dark}.png`.
    The popover's "Host problems" and Settings' "Test connection and a fix-it" fixtures show the
    action too.

- **D25 — Attach UX in the app** (decided in Phase 10a, 2026-10-22; code in
  `Sources/MuxFinderUI/Model/AppModelSessions.swift`, `SessionActivity.swift`,
  `SessionProblem.swift`, `SessionPanels.swift`, `Views/SessionRowView.swift`,
  `Views/SessionPanelViews.swift`, `Preview/Attach{Fixtures,Gallery}.swift`, `SelfTest/`;
  `Sources/MuxFinderApp/SelfTestAppDelegate.swift`; `AttachCoordinator.showLaunchTab(_:)`,
  `currentSession(named:on:)` and `createAndAttach(_:onCreated:)`'s `onCreated`).
  - **Seam:** `AppEnvironment.makeAttachCoordinator` builds one `AttachCoordinator` at the
    first session action (never at launch), with the model's update handler. The app's is over
    the shared `ITerm2APIClient`, `DiscoveryProbe`, `LaunchStore` and the bundled helper
    (`LaunchHelperPath.locate()`) with the standard existing-attachment check (D16); when it
    throws (the helper is missing or on a path iTerm2 cannot be given), the row says why and
    offers nothing to retry. Tests build it over a fake iTerm2 integration (the UI tests'
    `SimulatedITerm2`: launch tabs and tmux connections as state, identity answers,
    `detach-client` closing the connection), fake discovery, an in-memory launch store and a
    virtual clock; the index gets a clock whose question timeout never fires.
  - **State machine (`AppModel`):** at most one action per session (`runningActions`); a
    click, Return or menu item for a session with one pending is ignored, so a burst of five
    clicks gives one launch. The coordinator's updates and each action's result reach the model
    through one `AsyncStream` read by one main-actor task: the coordinator publishes a launch's
    states before its call returns and the action yields its result after, so a row never goes
    back. `requested` shows "Opening…" ("Moving here…" for a move), `launched` "Waiting for
    iTerm2…", `stillWaiting` "Still connecting — check the iTerm2 tab" with "Show tab",
    `confirmed` "Confirmed — open in iTerm2 on this Mac" (only from the core's `confirmed`,
    which follows its identity check) and `focused` "Already open here — brought its tab
    forward"; an Open of a session this Mac's iTerm2 shows already is the coordinator's focus,
    with no launch. That text needs the result's activation to be `activated`: a focus whose
    activation found no tab (`noTab`) or that iTerm2 refused (`failed`) keeps the attachment
    record (Detach stays offered) but shows its own problem ("…but muxFinder found no tab of it
    to bring forward…", "…but iTerm2 did not bring its tab forward…", the latter with D23's
    fix-it) with "Try again", which focuses again. Updates of a replaced launch
    (`isCurrent == false`) or of no pending action change nothing; failures and focuses come
    from the result. Results ("Confirmed", "Detached") are cleared when the popover opens
    again; failures stay until retried. `attachedHere` keeps the
    attachments muxFinder made or found (confirmed, focused, or a move here's
    `alreadyAttachedHere`); `finishedActions` keeps the latest 32 results for the self-tests
    and the tests.
  - **Failures:** `SessionProblem` gives every failure path its own plain-English message
    (pairwise distinct, tested): each `AttachFailure` (`identityMismatch`'s core message is now
    its own, no longer `sessionChanged`'s), each detach outcome but `detached`, the two "Show
    tab" notes, the missing helper, the two focuses that did not bring the tab forward and the
    two "Open existing" outcomes that open nothing. Recoveries: "Try again" (repeats the last
    action; a move here shows its confirmation again), "Refresh", "Show tab" (a timeout, a
    helper failure or a wait limit with a launch tab), "Bring forward" and "Detach from this
    Mac" (`alreadyAttachedHere`), "Open Settings" (an invalid destination, tmux missing), and
    D23's fix-it for iTerm2 permission and API errors. A helper failure's explanation says
    "shown in the tab" where the helper wrote "shown above".
  - **Banners:** `sessionGone` is "vanished", `sessionChanged` and `identityMismatch`
    "changed": the row's activity is cleared, a banner names the session and its host
    (dismissible, at most 3, newest first) and the host is refreshed.
  - **Show tab:** `AttachCoordinator.showLaunchTab(_:)` activates the session id with
    `select_session`, `select_tab`, `order_window_front` and the app options (the Python
    module's `Session.async_activate`), once, only for a launch tab the coordinator opened and
    still remembers; any other id is `notOpenedHere` and nothing is sent. From Phase 13b it
    first restores the tab (`setBuried(false)`, idempotent), never while a bury of that same tab
    is pending (D29). iTerm2 never hands out
    a session id again, so no binding check is needed. The model passes only ids from its own
    activities. Not yet seen against iTerm2 3.7.6 (local attaches never wait, so the self-tests
    do not reach it).
  - **Move here:** the row's context menu offers "Move here…" (disabled while the attachment
    index shows the session open here, where the move would refuse, D21). It shows a panel in
    place of the host list: "Move “name” here?", that muxFinder disconnects every other client,
    including iTerm2 on other Macs, that nothing is closed and the session keeps running, and
    the last client count. Cancel or Esc runs nothing; "Move here" or Return calls
    `confirmMoveHere()`, the only caller of `moveHere(_:confirmation:)`, with
    `.detachOtherClients(of:)` for that session.
  - **Detach:** "Detach from this Mac" is offered only for a session this Mac's iTerm2 shows
    (the index's badge, or `attachedHere`). It is `detach(session:on:)` (D16: the 10 s tab age,
    the identity re-check, `detach-client`, never a closed tab); the row then says "Detached
    from this Mac — the session keeps running", the record goes and the host is refreshed.
  - **New session:** a panel with the host (enabled hosts, This Mac first), the name (checked
    inline with `Validation.sessionName`; an empty name is reported once Create was pressed) and
    an optional directory (`Validation.workingDirectory`). Create runs `createAndAttach(_:)`
    with `AppEnvironment.newSessionCommand` (empty, the user's shell; `sleep` in the
    self-tests). As soon as the session is created (`createAndAttach(_:onCreated:)` reports
    it before its attach publishes anything), the panel closes, the host is refreshed and the
    attach becomes that session's pending action, like an Open: its row shows "Opening…",
    "Waiting for iTerm2…", "Still connecting — check the iTerm2 tab" with "Show tab", then the
    result; clicks on it are ignored meanwhile, quitting cancels it, and another New session
    can start. A collision offers "Open existing", which never trusts the popover's list (the
    listed session may have been renamed and another given its name, which is why tmux refused
    it): the coordinator lists the host afresh (`currentSession(named:on:)`, read-only) and the
    session with exactly that name there is opened (its attach revalidates it once more); when
    none has the name any more the panel says it ended or was renamed and opens nothing (the
    host is refreshed), and a host that cannot be listed says so, opening nothing either. Any
    other creation failure stays in the panel. Both panels are drawn inside the popover, not
    as sheets or alerts, so they stay in the menu bar window and render in the fixtures. While
    one shows, Return confirms it, Esc closes it (which also cancels an "Open existing" lookup),
    and the arrows, ⌘F and ⌘N do nothing.
  - **Quit:** `shutdown()` cancels the actions in progress (opens, moves, detaches, New session
    creations and attaches, "Open existing" lookups, "Show tab"; an attach withdraws its
    request, a detach waiting for its tab's age sends nothing), stops everything else at the
    same time without waiting for them, waits for them at most 12 s and reports those still
    running (D22), and detaches nothing.
  - **Self-tests:** `muxFinder --selftest attach-local|new-session-local [--selftest-keep]`
    runs `SelfTestAppDelegate`: a plain `NSApplication` (accessory) with no window, menu bar
    item, popover, onboarding or Settings. Unusable arguments exit 2 before anything starts; a
    set `TMUX_TMPDIR` (the launch tab's tmux would use another server) or a missing helper exit
    2 before iTerm2 is contacted. `SelfTestDriver` drives the real `AppModel` over an in-memory
    This Mac (`HostStoreLoadResult.inMemory`: no `hosts.json` is read or written), an engine
    over `DiscoveryProbe` with no attachment checks, and a coordinator whose index asks only
    connections owned by launch tabs recorded from its own updates (`LaunchTabRecorder`, as in
    `e2e-local`), so the user's connections never get a command. Setup reads iTerm2's status
    (never launching it) and counts the connections it will not ask. `attach-local`: create
    `muxfinder-test-<hex>` (`TmuxCommands`, pane `sleep 600`), wait until the engine lists it,
    Open five times (one launch, confirmed), Open again (focused, the same connection, still one
    launch), Detach from this Mac (detached, the connection gone), kill it.
    `new-session-local`: This Mac listed, New session through the panel (created and confirmed,
    the panel closed), the same name again (a collision with "Open existing", no launch),
    Detach, kill. Every wait is bounded (listing 20 s, an attach or creation 45 s, a detach
    45 s; the model's shutdown waits for session actions at most 12 s, as in the app). On a
    failure, or SIGTERM or SIGINT (which cancel the driver's task; this cleanup runs outside
    any termination deadline and exits on its own), cleanup cancels the model's actions and
    waits for them at most the attach timeout (45 s), finds the session by its exact name if
    its creation's output was lost, detaches its attachments in the run's own launch tabs
    through `detach(session:on:)`, waits until every launch tab of the run is 11 s old, kills
    the session only while it is still exactly the created one
    (`CreatedSession.killIfUnchangedArguments`), prints the coordinator's log (kinds only) and
    exits 1. When an action is still running after that wait (a launch tab of unknown age may
    still attach the session, and ending the session could end a tab younger than iTerm2's 3 s
    limit), cleanup detaches and kills nothing and prints `cleanup: <n> session action(s) still
    running …` with the `tmux kill-session -t '=<name>'` to run once its launch tabs are gone,
    and still exits 1. Exit 0 means every step passed and nothing is left.
  - **Keep mode (`--selftest-keep`):** after the attachment is confirmed (step 3 of
    `attach-local`, step 2 of `new-session-local`; pane `sleep 3600`) the app prints
    `muxFinder self-test keep: session <name> connection <id> gateway <session id>` and the
    cleanup commands, then waits. SIGTERM or SIGINT quit through `AppTermination.request()` and
    `applicationShouldTerminate` (the model's shutdown, with the app's 15 s deadline, D22) with
    exit 0, leaving the session and the connection. Cleanup afterwards: `swift run
    muxfinder-probe detach --connection <id> --gateway <session id>` (it waits until the tab
    is 10 s old), then `tmux kill-session -t '=<name>'`.
  - **Proof:** hermetic only in 10a (`AttachFlowTests`, `NewSessionSheetTests`,
    `FailureMessageTests`, `SelfTestDriverTests`: both self-tests passing, a failing step and a
    failed detach cleaned up, an interrupted run, a cleanup that reports an attach still
    waiting for iTerm2 instead of killing, keep mode; the user's connection never asked, no tab
    ever closed; a quit while an attach waits for iTerm2 stopping Settings and the engine at
    once; a New session attach followed on its row with "Show tab"; a focus that did not bring
    its tab forward; "Open existing" resolving the name afresh). The real runs are Phase 10b's.
  - **Preview fixtures:** `--preview-fixtures --preview-gallery attach` shows
    `AttachFixtures.all` (15 states: progress and results, every failure in six cards, both
    check-failure cards with a focus that did not bring its tab forward, Move here, two detach
    cards, the New session panel empty, with an invalid name, creating and
    after a collision, the banners) and the context menu of a session open here and of one
    attached elsewhere; screenshots `docs/screenshots/attach-states-{light,dark}.png`.

- **D26 — Persistent work profiles** (decided in Phase 11a, 2026-10-23, Settings in Phase 11c;
  code in `Sources/MuxFinderCore/Profiles/`: `PersistentProfiles.swift`,
  `PersistentProfileInstaller.swift`, `ITerm2ProfileSnapshot.swift`, `PersistentProfileRun.swift`;
  `Launch/ProfileLaunch.swift`, `LaunchHelperProfile.swift`, `LoginShell.swift`;
  `Config/HostConfig.swift`, `HostList.swift`; `Tmux/TmuxWord.swift`; probe
  `ProfilesCommand.swift`, `E2EProfileCommand.swift`).
  - **Host-list fields (D19, still schema 1):** per host, `persistentProfileEnabled` (written
    only when `true`), `defaultSessionName` and `persistentProfileParentName` (each only when
    set). A file without them (every file written before) loads with the defaults and saves
    back byte for byte. An unset session name is `main` (`HostConfig.standardDefaultSessionName`,
    the name iTerm2's own documentation uses for `tmux -CC new -A -s main`). The parent is per
    host, not global: hosts differ (a remote host's profile may want other colors), it sits
    beside the host's `iTermProfileName`, and the file stays a list of hosts. Invariants
    (`HostList`, checked whether or not the profile is on, as a set tmux path is kept): a set
    session name passes `Validation.persistentSessionName` exactly as stored (trimmed): D18's
    `sessionName` rules plus no leading `$ = @ % ! ~ { + ^`, because with `-A` tmux attaches an
    existing session through a target lookup of its name, where those characters mean an id,
    an exact match, the marked pane, a token, the last window or an offset (tmux's target
    syntax; not tried on a server, since test sessions must be named `muxfinder-test-*`;
    Phase 11b's runs show only that `-A -s muxfinder-test-profile` attaches the existing
    session of that exact name, locally and on Saturno),
    checked on the first Unicode scalar, the byte tmux reads first, not the first `Character`
    (a combining mark after `$` makes another grapheme cluster but leaves the `$` in front); a set
    parent name passes `Validation.profileName` (not empty, no control characters). A file
    breaking them is `invariantBroken`, left as it is. The profile is independent of
    `isEnabled` (discovery). The Settings controls are 11c's (below).
  - **The profile file (`PersistentProfiles`, pure):** `{"Profiles": […]}`, one profile per host
    with the profile on, in list order: `Guid` `muxfinder-persistent-<host id, lowercase>`,
    `Name` `Persistent work – <display name>` (en dash), `Tags` `["muxFinder"]`, `"Custom
    Command": "Yes"`, `Command` `<helper> profile <host id, lowercase>`
    (`LaunchHelperPath.profileCommandLine(forHostID:)`), `"Close Sessions On End": true`, and
    `Dynamic Profile Parent Name` only when set; pretty-printed, sorted keys, a final newline,
    deterministic (golden files in `Tests/MuxFinderCoreTests/Fixtures/profiles/`). The keys are
    iTerm2's own: all seven appear in the 3.7.6 binary's strings and the profile ones in its
    Python module (read only; `Dynamic Profile Parent GUID` exists too and is not used). The
    command carries the host id alone: the helper reads mode, destination, tmux path and
    session name from `hosts.json` when the tab starts, so editing them needs no new file. The
    helper path must pass D2's rule (`LaunchHelperPath(validating:)`, else
    `unsupportedHelperPath` and nothing is generated), so the line is three words under any
    splitting rule, as the attach command was verified to be (*Verified facts*, Phase 4).
  - **Installer (`PersistentProfileInstaller`, both folders injectable):** writes and removes
    `DynamicProfiles/muxFinder.json` only. The folder must be the user's and not a symbolic
    link (decided: a synced or shared folder would carry this Mac's helper path and host ids
    to other Macs); an install creates it (0755, as iTerm2 does) only when missing and its
    parent exists; the folder itself is never changed. `muxFinder.json` is opened with
    `O_NOFOLLOW` only: a link, a non-regular file, another user's or one over 1 MiB is refused
    and left alone. An install of identical bytes writes nothing (`unchanged`); otherwise a
    hidden temporary file (`.muxFinder.json.<hex>.tmp`, `O_EXCL|O_NOFOLLOW`, 0600, flushed;
    iTerm2 3.7.6's binary logs "Skipping it because of leading dot") is published with one
    rename, `RENAME_EXCL` when no file is there or `RENAME_SWAP` with the checked file, the
    displaced entry deleted only when it is still that file (device and inode), anything else
    swapped back, and what that swap back displaces deleted only when it is the install's own
    temporary file (device and inode taken before publishing), else kept under the hidden name
    (`displacedEntryKept`). Removal renames the checked file aside (`RENAME_EXCL`) and deletes
    it only when it is still that file; with expected bytes (the harness), only while it holds
    them. Installs and removals of every muxFinder process are serialized by an exclusive
    `flock` on `profiles.lock` in muxFinder's own folder, held from before the file is looked
    at until the operation ends, waited for at most 5 s (`busy`); reads take no lock (decided:
    the lock lives in the app's folder, not in `DynamicProfiles`, which is iTerm2's; the folder
    is opened as D19's stores open it, the file 0600, empty, never removed, since removing a
    lock file lets two processes hold it). So only a writer outside muxFinder can take the name
    during an operation, and the identity checks keep its file. Unlike D19's `HostStore`, which
    has one writer and keeps any displaced file as a backup, the installer swaps a foreign file
    back to its name, so it must know whose file that swap back displaces.
    No other entry is ever read, renamed or deleted (a test hashes the siblings at every
    step). Zero hosts with a profile means no file (decided: an empty file is noise, and it is
    the state "Remove profiles" leaves), so installing an empty document removes it.
    `status(for:)` (`notInstalled`, `current`, `stale`: the bytes differ, as when the helper
    moved; `notMuxFinders`: the file is not a generated document) is what Settings shows and
    what the automatic updates look at first (the update checks again under the lock). **The
    app's own file only** (decided in 11c): "Install profiles" installs with
    `replaceGenerated`, the automatic updates (at launch, after a Settings save) with
    `updateExistingGenerated`, and "Remove profiles" removes with `onlyIfGenerated`; all three
    refuse (`fileNotMuxFinders`) a `muxFinder.json` that `PersistentProfiles.isGenerated(_:)`
    does not recognize: a JSON object with the single key `Profiles`, a non-empty array whose
    every entry has a generated `Guid` (prefix and lowercase host id, nothing more) and the
    `muxFinder` tag; other keys are not compared, so a file of an earlier build or helper path
    is still muxFinder's. The check runs under the lock on the examined bytes.
    `updateExistingGenerated` never creates anything (decided after the 11c review: a status
    read and a separate install let a file removed in between come back): no folder or no
    file, found under the lock, is `notInstalled` with nothing written; otherwise it is
    `replaceGenerated`'s swap, which fails (`fileChanged`) rather than create the name when an
    outside writer removed the file after the check; an empty document removes only a
    generated file (`nothingToRemove` with none). `replaceExisting` (any file) and
    `createOnly` (the harness) stay as they were.
  - **Helper `muxfinder-launch profile <host id>`** (`LaunchHelperProfile.swift`): no request
    file. **Nesting guard** first, before reading anything: `TMUX` or `MUXFINDER_LAUNCHED` set
    and not empty (empty counts as unset, as tmux treats `TMUX=`) prints one line and starts the
    login shell. `MUXFINDER_LAUNCHED=1` is in the environment of everything the helper starts,
    in every mode (attach and ssh-setup children too, for consistency; a tmux server the profile
    starts keeps it in its global environment, harmless since its panes have `TMUX` anyway).
    Then `hosts.json` through `HostStore.load()` (read-only: no folder or file created or
    written) and `ProfileLaunchPlan.make`: no list, an unusable list, an unknown host, the
    profile off, or an unusable session name, destination or tmux path each explains and
    starts the login shell. Locally D14's two children: the check `/bin/sh -c
    <ProfileLaunch.locateScript> muxfinder <override>` (the D5 locator, its own group, the 10 s
    deadline), then `<tmux> -u -CC new-session -A -s <name>` by argv on the tab's terminal, the
    name as `TmuxWord.escaped` makes it (`#` doubled, a trailing `;` written `\;`, D18). On an
    SSH host D17's interactive ssh with the static `ProfileLaunch.remoteScript` (the locator,
    D18's word functions, `exec "$t" -u -CC new-session -A -s "$w"`) and two quoted arguments,
    the override and the name. tmux ending normally ends the helper after D14's hold (the tab
    closes); any failure explains in profile wording and starts the login shell; a closed tab
    (SIGHUP) starts nothing. **Login shell** (`LoginShell`): the passwd entry's shell
    (`getpwuid_r(getuid())`), else `/bin/zsh`, else `/bin/sh`, each only when an executable
    regular file; argv `[-<name>]`; it replaces the helper (`posix_spawn` with
    `POSIX_SPAWN_SETEXEC`: same pid and process group, default signal dispositions, empty mask,
    only descriptors 0–2); environment the helper's minus `MUXFINDER_LAUNCH_*` plus
    `MUXFINDER_LAUNCHED=1` (`TMUX` kept). It is not started in test mode (recorded in the argv
    digest as `attachChild` with `startsLoginShell`) or on a terminal that is not interactive;
    the helper then ends like a failed attach (explanation, wait for Return, D14's hold) with
    76 (host list or host unusable), 77 (nesting guard) or the failure's own status; when every
    shell fails to exec, the same with 74. Accepted: once the shell runs, a shell ending by
    itself within 3 s (broken start-up files) is beyond the helper's hold, as for any iTerm2
    profile with that shell.
  - **Test seam:** iTerm2, not the probe, starts the profile command, and the production command
    stays exactly `<helper> profile <id>`. In test mode only (D14's marker or variable), the
    helper reads `launch/profile-test-<host id>.json` (`LaunchStore.profileTestHostsURL`, the
    `hosts.json` format under D19's read rules) in place of `hosts.json` when one exists for
    that very host id; `e2e-profile` writes it (exclusive, 0600) for a fresh test host id and
    removes it with the marker, so the user's `hosts.json` is never read or written by the run,
    and a real profile's tab during a run still reads `hosts.json` (no test file has its id).
  - **Probe:** `profiles show [--config <path>] [--helper <path>]` prints the document the app
    would install (writes nothing; `--config` is the host list file, as for `hosts show`);
    `profiles hashes [--directory <path>]` prints `ITerm2ProfileSnapshot`: each other
    `DynamicProfiles` entry's name, kind and SHA-256 (a file's bytes, a link's text, never
    followed; folders not descended), and the count and SHA-256 of a canonical form of `New
    Bookmarks` (`CanonicalPropertyList`: typed, length-prefixed, dictionary keys sorted) from
    `/usr/bin/defaults export com.googlecode.iterm2 -` run by argv, never a profile's content;
    `iterm2 list-profiles` already prints every GUID with its name. iTerm2 writes every loaded
    dynamic profile into its saved `New Bookmarks` (with a `Dynamic Profile Filename` key) and
    drops it once the file goes (within 0.3 s of the removal in Phase 11b's passing runs;
    *Verified facts*), so the hash leaves out
    only what it can prove is iTerm2's copy of muxFinder's own profile
    (`ITerm2ProfileSnapshotter.MirrorRule`): a dictionary whose `Guid` is a well-formed
    generated GUID (`muxfinder-persistent-` and a lowercase UUID, nothing more) and whose
    `Dynamic Profile Filename` is an absolute path ending in `muxFinder.json` that,
    standardized (`.` and repeated `/` dropped, `..` applied), is exactly the snapshotter's
    own `<DynamicProfiles>/muxFinder.json`; and, when the caller knows what it wrote (the
    e2e-profile run passes the profile dictionaries of its file), whose `Guid` is one of the
    written ones and which holds every written key with an equal value (the same canonical
    form; the keys iTerm2 fills in are not compared). Everything else is hashed: other dynamic
    profiles' copies, a look-alike GUID (`muxfinder-persistent-custom`), another folder's or a
    relative `muxFinder.json`, a copy whose written key changed or went. `profiles hashes`
    knows no install, so it uses the GUID format and the exact path alone (with `--directory`,
    that folder's `muxFinder.json`). `count` is the hashed entries;
    `excludedMuxFinderEntries` counts the copies left out, never naming them. Comparisons use
    `differences(from:)` / `hashesMatch`, which ignore that count (`==` does not).
  - **`e2e-profile --local | --ssh <destination>` (`PersistentProfileRun`, every part a seam,
    tested with fakes):** refuses to start when `DynamicProfiles/muxFinder.json` exists (the
    user's then) or a session named `muxfinder-test-profile` exists; snapshot, which must hold
    no copy of a muxFinder profile (decided: with no `muxFinder.json` such a copy is
    unexplained, and leaving it out of the baseline while steps 8 and 13 hash it would make
    the comparison inconsistent; so step 1 snapshots every 0.5 s for at most 5 s until none is
    left, notes how long that took, and otherwise fails before anything is created); creates that
    session itself (panes `sleep 600`) so the profile's `-A` attaches it and no login shell
    ever starts inside tmux (the create branch of `-A` is proven by argv only); writes the
    test host list and the marker; installs with `createOnly`; waits for `ListProfiles`
    (filtered to the GUID) to show the profile; `CreateTab(profile_name:)` without a window id
    and without custom properties; waits for a connection owned by that tab, checks the argv
    digest (exactly `<helper> profile <id>`, and the expected tmux or ssh child) and the
    identity through D15's binding (the created server and session, `#{host}` as discovery
    reported); snapshot (step 8: only iTerm2's unchanged copy of the run's own profile in `New
    Bookmarks`, by its exact GUID, the owned path and the written keys, is left out and counted
    in a note; anything else that appeared is hashed, and a note gives the hashed counts when
    they differ); detaches through the binding once the tab is 10 s old and waits for
    the connection and the tab to close by themselves; kills the session only while unchanged;
    removes the file only while it holds the run's bytes, and the test host list; waits until
    the GUID is gone; then (step 13) snapshots every 0.5 s, cancellable, until `New Bookmarks`
    holds no copy of the run's profile and reports how long after the removal that was. Step
    13 has one absolute deadline, 30 s after step 11 removed the file (a slow step 12 leaves
    less); each snapshot's `defaults export` timeout (normally 20 s) and each pause are capped
    to what is left, and a snapshot that ends after the deadline, or is cut by it, does not
    count, so the step FAILs then (the file is gone by then, nothing else to clean up); all
    three snapshots hash the same. Cleanup on every way out (failure, signal, the 180 s
    limit), once the tab is 10 s old: every connection iTerm2 lists as owned
    by its own tab (one that appeared after step 6's wait too) detached through the binding,
    once per connection, until a listing shows none (a failed or unanswered detach proves
    nothing); the tab closed (forced) only when it did not close by itself and a listing taken
    just before shows it owns none; then the conditional kill. A connection still owned, or no
    listing, leaves the tab open and the session alive (never a forced close of a possible
    gateway, never a kill under it), and cleanup FAILs with the commands to finish by hand
    (`muxfinder-probe detach --connection <id> --gateway <tab>`, then the kill by exact name).
    Then the file only with the run's bytes; the test host list and the marker. Remotely:
    only `saturno-m4`, the run's own tmux calls over ssh
    with `BatchMode` and a static script, the tab's ssh interactive as D17's (key
    authentication), no remote file written.
  - **Owed to 11b, settled by its real runs (`docs/TESTING.md`, Phase 11b):** the runs
    confirm that iTerm2 loads the file and drops it (`ListProfiles` shows the GUID 0.2–0.6 s
    after the install and stops about 0.2 s after the removal); that the profile command splits
    into exactly three arguments (`<helper> profile <id>`, its child the expected seven); that
    `Close Sessions On End` works from a dynamic profile (the tab closes by itself once tmux
    ends after the detach); that the hashes (muxFinder's copies left out) stay the same through
    install and removal, iTerm2 dropping its copy 238–266 ms after the removal; that iTerm2's
    copy keeps every key the run wrote with an equal value and names the file by exactly the
    installer's path, so the strict exclusion rule and step 13's absolute deadline above pass
    (the final-tree runs; the first fixed runs used a looser rule); and that
    `CreateTab(profile_name:)` gets a confirmed control-mode connection locally and on Saturno.
    For `-A` they show only that the run's existing session is attached by its exact name on
    both hosts (the target-syntax cases above stay untried). Still unverified: the dot-file
    skip, seen only indirectly (no stray profile, no failure, the API answering throughout),
    and whether iTerm2 shows a non-modal "Dynamic Profiles Error" alert during the install,
    which an unattended run cannot see (no screen capture of iTerm2), so a person's glance is
    owed; the unknown-parent fallback ("Using default profile as parent" in the binary's
    strings), not tried for real (the harness installs a parentless profile, and a try needs a
    synthetic parent name and a harness option); a login shell ending by itself within
    3 s, not exercised (the runs never reach the login-shell fallback). Both items left open
    for 11c are settled by copy (below); iTerm2's behavior for a second tab is still unknown.
  - **Settings and keeping the file current** (decided in Phase 11c, 2026-10-23; code in
    `Sources/MuxFinderUI/Model/`: `PersistentProfileFiles.swift`,
    `PersistentProfilesContent.swift`, `SettingsModelProfiles.swift`, `HostDraft.swift`;
    `Views/Settings/ProfilesSettingsView.swift`, `HostEditorView.swift`).
    - **Host editor:** a "Persistent profile" section below iTerm2: the switch, "Session"
      (placeholder `main`) and "Parent profile" (a picker of iTerm2's profile names when D23's
      profile list has them, "None" first, else free text; never launching iTerm2). The
      session name is stored trimmed, empty as none, and must pass
      `Validation.persistentSessionName`; the parent is stored trimmed, empty as none, and must
      pass `Validation.profileName`, except that a parent field left exactly as loaded saves
      back the stored value unchanged; both are checked whether or not the profile is on, as
      `HostList` checks. An error is inline (the validation's sentence) and blocks Save; a
      parent iTerm2 does not list is a warning. A host without the fields saves back byte for
      byte (tested through `HostStore` in a private folder).
    - **Where:** its own tab, "Persistent profiles", between Hosts and General (decided: the
      status, three buttons, results and four paragraphs of copy would crowd General): the
      status line, the profile names the saved hosts make, "Install profiles", "Remove
      profiles", "Check again", the last result, and "Using persistent profiles". Unavailable
      shows the reason: an unusable helper path or a missing helper (D2), the folder a link, not
      a folder or another user's, the file a link, not regular, another user's, too large or not
      muxFinder's, or a failed system call; with muxFinder's file still installed it says so
      and Remove stays offered. Install is off, with a note, while the list is not saved
      (examples, an unusable or changed file), while no saved host has its profile on, and
      while the status is unavailable; Remove only while muxFinder's own file is there; every
      button while an operation runs.
    - **Seam:** `SettingsEnvironment.persistentProfiles` (`PersistentProfileManaging`:
      `status(for:)`, `install(_:)`, `update(_:)`, `remove()`), production
      `PersistentProfileFiles` (the
      real installer, `LaunchHelperPath.locate()` for the helper, the file work on a global
      dispatch queue so the lock wait of up to 5 s never blocks the main actor). Every check,
      install, update and removal goes through it, one at a time in the order asked;
      `shutdown()` waits for the one running and skips the rest. Fixture models have no environment, so the
      preview gallery never reads, installs or removes anything (tested).
    - **Saved list only** (decided): installs and checks use the saved host list, never the
      draft; while the editor holds unsaved changes the tab says so and Install stays on
      (a later save updates an installed file anyway). Each operation takes its list when
      asked and keeps that value (decided after the 11c review: a reload sets the model's list
      loading, which reads as no host, so a list read after an `await` could turn an update
      into a removal): Install and Remove the saved list as the tab showed it, the update
      after a save the list that save wrote; "Check again" does nothing while the list is
      loading (the opening checks once it has loaded).
    - **"Installed" is sticky:** only "Install profiles" creates `muxFinder.json`; the
      automatic updates (`update(_:)`, `updateExistingGenerated`) rewrite muxFinder's own
      installed file and never create one, the check and the write one step under the lock,
      so a file removed after the status was read stays removed.
    - **After a Settings save** (Save or a removal; decided: update rather than show "out of
      date"): when muxFinder's installed file no longer matches the list the save wrote, the
      file is updated to its profiles at once (a rename, a profile turned on or off; edits that
      do not change the document write nothing); with no host's profile left on that removes
      the file (installer semantics, accepted). Onboarding saves are not followed (they cannot turn a profile on;
      the next launch handles a file left over).
    - **At launch:** only the menu bar app in normal mode (`AppLaunchOptions
      .rewritesProfilesAtLaunch`, passed to `AppEnvironment.production`; never with
      `--preview-fixtures`, `--selftest`, `--report-login-item-status`,
      `--report-menu-bar-item` or unusable arguments, and the self-tests' and tests'
      environments leave it off) and only for a list loaded as `saved`: `stale` updates the
      file to the regenerated document (an empty one removes the file, accepted; a file gone by
      then is not created again, "stale, notInstalled"); `notInstalled`, `current`,
      `unavailable` (an unusable helper, a refusal) write nothing. In the
      background, contacting no iTerm2; logged by kind only (category `profiles`, e.g.
      "profiles at launch: stale, installed", "…: unavailable.helper.unsupportedCharacters"),
      and a change or failure becomes the tab's result line; the tab's own check shows the
      status when the window opens.
    - **Copy (decided):** how to make a profile the default (iTerm2 › Settings › Profiles,
      select it, Other Actions › Set as Default); that shells started from other profiles or
      apps are not moved into tmux; for a second tab, that opening the profile again attaches
      the same session once more, so iTerm2 may show its windows a second time (copy only, not
      tried); and the parent warning: iTerm2 bases a dynamic profile without a parent on the
      default profile, so once a persistent profile is the default, another dynamic profile
      that sets no parent and no command of its own would start that host's session too; the
      generator is unchanged (it cannot fix the user's other profiles), the copy says so.
- **D27 — Install and uninstall scripts** (decided in Phase 12a, 2026-10-23; code in
  `scripts/install.sh`, `scripts/uninstall.sh`, `scripts/lib/app-copies.sh`,
  `Sources/MuxFinderCore/Profiles/PersistentProfileRemoval.swift`, `AppLaunchOptions`; check
  `scripts/dev/test-install-scripts.sh`).
  - **Which processes belong to a copy** (decided: the kernel's executable path, after the
    Phase 12a review): a process of this user whose executable, as the kernel reports it, is
    that copy's file, matched by device and inode. `lsof -d txt` only finds the candidates
    (device and inode of the file): its `txt` records list every file a process maps, so a
    Spotlight, QuickLook or backup reader that merely maps the executable is one too. Each
    candidate's executable is then read with `codesign -dv <pid>`, whose `Executable=` comes
    from the kernel (`proc_pidpath`, the text vnode); `ps`'s `comm` is argv[0], relative for a
    relative start and forgeable (`exec -a`), so it cannot prove anything (checked: for a stub
    started absolutely, relatively, through a symbolic link, and a reader with a forged argv[0]
    naming the copy, `codesign` gave the true path each time; for a helper in the bundle its
    own path, not the bundle's main executable; about 9 ms per call). A candidate whose
    executable is another file only maps it and is never signalled; one whose executable
    cannot be established (`codesign` fails: the process is gone, or its own executable was
    deleted) is named, never signalled, and counts as running, so the run waits for it and
    changes nothing while it stays. Only SIGTERM is sent, once, then up to 20 s (longer than
    the app's 15 s quit deadline, D22) re-checked the same way; a process still running is
    reported and nothing is changed, never SIGKILL, `killall`, `osascript` or `open`.
  - **Install with a running copy** (decided: stop it): quitting muxFinder leaves sessions and
    iTerm2 tabs as they are (D22), so `install.sh` sends the destination copy's `muxFinder`
    SIGTERM once the new copy is staged and verified, just before replacing it, and refuses
    (nothing changed) if it does not quit; a failed copy never stops the app. Only that copy's
    `muxFinder`; a copy elsewhere (`build/`) is never signalled.
  - **Which processes uninstall stops** (decided: the app only): `muxFinder` of each copy being
    removed. `muxfinder-launch` processes of that copy run in iTerm2 tabs (an attach, ssh setup
    or a persistent profile's tab, holding the user's tmux client or login), so stopping one
    could end that tab's work; they are reported and left, and keep running after the bundle
    is gone (the executable stays mapped). Other muxFinder processes (the same kernel-path
    rule, any `…/muxFinder.app/Contents/MacOS/muxFinder`) are only warned about.
  - **Deletions bound to what was inspected** (decided after the Phase 12a review): an app
    copy or the support folder has its device and inode recorded when it is inspected.
    Deleting it means one `rename` into a new hidden folder beside it (`.muxFinder-install.*`
    or `.muxFinder-remove.*`, same parent, so atomic), comparing the moved entry's device and
    inode with the recorded ones, and only then `rm -rf` of the hidden folder (itself checked
    to be the one just made). When the moved entry is something else (the place was swapped
    after the check), it is put back, never deleted (kept in the hidden folder and named if its
    place is taken again), and the run exits 1; a deletion that fails part way puts what is
    left back too. The install's temporary folder is deleted only while it is the one the run
    made and an old copy in it is the inspected one.
  - **Install procedure:** source `build/muxFinder.app` (bundle id, both executables and
    `codesign --verify --deep --strict` checked first); the destination copy must be a folder
    with muxFinder's bundle id, never a symbolic link, and its device and inode are recorded;
    `ditto` into a hidden `mktemp -d` folder beside the destination, verified with `codesign`,
    then the old copy renamed into that folder and checked to be the inspected one (if not, it
    is put back, nothing is installed, exit 1), and the new one renamed into place (the old
    one put back if that fails, kept and named if it cannot be), the folder deleted last.
    `--user` installs into `~/Applications` (created if missing) and warns when the path has
    characters D2 refuses. It never starts the app; it prints how, and which prompts the first
    launch may show.
  - **The profile file's ownership** (decided: Swift, not shell): `uninstall.sh` runs the app
    copy's own binary, `muxFinder --remove-persistent-profiles [--dry-run]`, which removes
    `DynamicProfiles/muxFinder.json` through `PersistentProfileInstaller.remove(onlyIfGenerated:
    true)` under the `profiles.lock` flock (D26), so the generated-file rule is the app's
    "Remove profiles" rule. `--dry-run` reads without the lock and creates nothing. Exit 0
    removed, nothing installed or would remove; 1 left as it is (not a generated document, a
    link, not regular, another user's, too large, or the folder a link, not a folder or another
    user's); 3 failed (busy, lock, system call, changed meanwhile); 2 usage. The mode exits
    before any window, menu bar item, host list or iTerm2 contact. `--profiles-directory` and
    `--lock-directory` (both or neither, absolute) stand in for the two folders, for checks.
    The flag's options without the flag, or the flag with another mode, are usage errors.
  - **Old binaries:** an app built before the flag ignores unknown arguments and would start
    the menu bar app, so the bundle declares `MuxFinderScriptInterface` = 1 in its Info.plist
    (`build-app.sh`), and `uninstall.sh` runs the binary only for a copy with that key whose
    signature verifies. Without one (no copy, an older or a broken copy) the file is left, its
    path printed with why, and the run exits 1.
  - **Support folder:** `~/Library/Application Support/muxFinder` removed, bound to the folder
    inspected (above; `rm -rf` removes links inside, never follows them), after the profile
    file (whose lock lives there); a symbolic link or a non-folder there is refused and left
    (exit 1). **Preferences** (decided:
    remove): AppKit may keep the menu bar item's state in the app's own domain (seen in Phase
    8), so `/usr/bin/defaults delete cc.carpio.muxfinder` runs when `defaults read` finds the
    domain, never in a dry run or test mode. **Never:** `tccutil` (the command is printed for
    the user), the login item (`SMAppService` can only be unregistered by the app; the script
    says where to remove it), tmux, iTerm2 preferences or other profiles, `~/.ssh`, shell files.
    Order: find copies, stop them (any failure stops the run before a removal), profile file,
    support folder, app copies, preferences; exit 0 when everything of muxFinder's is gone
    (files proven not muxFinder's are named and left), 1 when something was refused or failed.
  - **Test mode** (checks only; contained after the Phase 12a review): `MUXFINDER_TEST_HOME`
    and `MUXFINDER_TEST_APPLICATIONS`, both set, stand in for the home folder and
    `/Applications`. Each must be an absolute existing folder, not itself a link, whose
    physical path (`pwd -P`, used from then on, so no link remains on the way) lies strictly
    beneath `/private/tmp` or `/private/var/folders` (the user's `$TMPDIR`), owned by the user,
    writable by neither group nor others, never the real home, inside it (so never
    `~/Applications`) or `/Applications`; the two must be apart, and `HOME` must resolve.
    Every path a script then derives (both app copies, the destination folder, the support
    folder, `DynamicProfiles/muxFinder.json`, the hidden temporary folders) must lie strictly
    beneath one of them with no `.`, `..` or symbolic link among the folders on the way,
    checked before anything is created, moved or deleted (exit 2 otherwise; the last
    component is each script's own check, which never follows a link), and again just before
    each deletion. Then `MUXFINDER_TEST_SOURCE` (install), `MUXFINDER_TEST_STOP_WAIT` (1–60 s)
    and the swap hook are honored: `MUXFINDER_TEST_SWAP_AT` and `MUXFINDER_TEST_SWAP_WITH`
    (both, beneath the test folders, the second a folder) make the entry at the first path
    and the second folder exchange places just before that path is moved aside, standing in
    for another program replacing a folder after the check; outside test mode they are refused
    (exit 2). The profile flag gets the private folders, the preferences domain is never read
    or written, and signals reach only processes of the private copies. Both scripts refuse to
    run as root.
- **D28 — App icon, menu bar icon and release signing** (decided 2026-10-23, after Phase 12;
  sources in `scripts/dev/icon/`, generated files in `Resources/`, code in
  `Sources/MuxFinderUI/Views/MenuBarIconLabel.swift`, `scripts/build-app.sh`,
  `scripts/release.sh`; test `Tests/MuxFinderUITests/MenuBarIconTests.swift`).
  - **The mark** (decided: "split window", chosen by the user from three directions on one
    contact sheet): a rounded window frame split into three panes the way tmux splits them,
    with a solid status bar along the bottom. White on midnight blue in the app icon; the same
    mark in black on transparency is the menu bar template image. Its brief (construction,
    palette, 16 px legibility rule) is `scripts/dev/icon/BRIEF.md`.
  - **How the art is made** (decided: background painted, mark drawn by code): the background
    (`plate.png`) is a raster painted by ChatGPT from the prompt in
    `scripts/dev/icon/README.md`; the mark is drawn by `glyph.swift` (written with Codex),
    because a template image needs one flat colour, a clean alpha channel and legibility at
    16 px, which image generators get wrong. The mark is drawn natively at every size
    (fractions of the size snapped to whole pixels), never scaled; at 32 px and below the
    background is the brief's two-stop gradient instead of the painting. The generated files
    are committed in `Resources/`; `build-app.sh` only copies them, and regenerating them
    (`scripts/dev/icon/build-icon.sh`) is a dev step, never part of `swift build` or `swift
    test`.
  - **Menu bar icon** (decided: template PNGs in the bundle): `MenuBarIcon.png`, `@2x`, `@3x`
    (18, 36, 54 px; the mark drawn on a canvas 24/18 the slot and centre-cropped, so it fills
    about 15 of the 18 pt like system symbols) in `Contents/Resources`, read with
    `Bundle.main.image(forResource:)` and marked as a template; the scene's label is a `Label`
    titled "muxFinder" (the menu bar shows only the icon; accessibility reads the title). An
    unbundled run (`swift run`) has no such file and shows the SF Symbol `terminal`.
    Considered: drawing the mark in Swift inside the app (duplicates the renderer's geometry)
    and an asset catalog (needs Xcode's `actool`; this repo is SwiftPM only).
  - **App icon:** `Contents/Resources/AppIcon.icns` with `CFBundleIconFile` `AppIcon`. The app
    is an accessory app (`LSUIElement`), so the icon shows in Finder, System Settings and the
    Automation prompt, not in the Dock.
  - **Release signing and notarization** (decided: a separate release flow, replacing D7's "no
    notarization"): everyday builds keep the Apple Development signature without a timestamp.
    macOS ties the Automation grant to the designated requirement, which for those builds
    names the Apple Development leaf certificate, so a different identity would reset it.
    `scripts/release.sh` checks first that notarytool's keychain profile works
    (`AC_NOTARY_PROFILE`, or `MUXFINDER_NOTARY_PROFILE`; the script never reads, prints or
    stores credentials), runs `build-app.sh --release` (the first "Developer ID Application"
    identity or `MUXFINDER_SIGN_IDENTITY`, hardened runtime, secure timestamp, no ad hoc
    fallback; the helper is signed before the app, as for every build), uploads a `ditto` zip,
    waits up to 30 minutes, saves the notary log on any verdict but Accepted, staples (three
    tries, 30 s apart), validates, requires `spctl`'s "source=Notarized Developer ID", and
    writes `build/muxFinder.zip`. A Developer ID build is a different app to the Automation
    check, so the first one run asks for that permission again, once.
- **D29 — Hiding the launch tab once attached** (decided in Phase 13a, 2026-10-24, from the
  spike's facts, *Verified facts*, Phase 13a; client in `ITerm2/ITerm2Property.swift`, helper
  in `Launch/LaunchHelper.swift` and `Launch/TerminalStatusRequest.swift`, spike harness in
  `Sources/muxfinder-probe/E2EBury*.swift`; the coordinator's part is built in Phase 13b).
  - **The bury:** the coordinator buries a launch tab it opened with
    `buryLaunchTab(sessionID:ifOwnsTmuxConnection:)` (bound like every command, D15), once
    per launch (coalesced callers share it), for `attach`, `createAndAttach` and `moveHere`,
    only after the attach is confirmed and step 9 returned `.activated(tabID:)` (S6: a tmux
    window shows). Never after `.noTab` or a failed activation, for a failed or unconfirmed
    attach, a focus, or a tab it did not open. A failed bury is not fatal and never retried
    (D13). The outcome goes on `AttachResult` and into diagnostics: `buried`,
    `skipped(reason)`, `failed(error)`, `uncertain` (sent, no answer) or `restoredAfterEnd`. A
    buried tab still owns its connection, so the bound identity check and `detach-client` work
    as before. muxFinder never reads iTerm2's preferences: with "Automatically bury the tmux
    client session after connecting" on, iTerm2 has buried the tab already (the bury answers
    `OK`, S2) and restores it itself when tmux ends (S5). Decisions read `ListSessions`'
    `buried_sessions`, never `GetProperty` `buried` (it answers `1`/`0`).
  - **The race, closed by order:** the helper writes its result before its first restore.
    After the bury's answer (or its timeout), the coordinator peeks at the result (without
    taking it, so `detach` still does) and checks the connection's owner; when the result
    exists or the tab no longer owns the connection it sends `setBuried(false)` (idempotent;
    `restoredAfterEnd`). A bury iTerm2 handled after the helper's first restore was answered
    after the result existed, so it is undone; one handled before is undone by that restore;
    one during the hold by the helper's last restore (seen in the spike, (c)).
  - **The helper's restore** (D14 *Launch tab restore*): after the attach child ends, for every
    outcome unless the tab was closed: the result, then a line feed, `Disinter` and a status
    report request, the exchange bounded to 2 s writes included (non-blocking I/O under one
    deadline, and no other reader: the wait for Return returns only once its reader stopped,
    after the Phase 13a review); when unanswered, `Disinter` and the request again at once;
    then the explanation, the wait for Return and the hold; and just before exit `Disinter`
    and the request once more. The line feed is for the abnormal end (the attach child killed,
    ssh dropped: tmux sent no `%exit`), when iTerm2 still parses the tab as a tmux gateway: it
    reads the line as an unrecognized tmux command and ends tmux mode at once (its default),
    the rest of that write being lost with the gateway. Before the line feed existed the
    first restore was swallowed and tmux mode ended only with the explanation, so with
    iTerm2's default setting the tab would have stayed buried while its helper waited for
    Return (spike (e)); on a clean end the line feed is one blank line. The status report
    answer is the acknowledgment: iTerm2 answers only after it ran what came before, so an
    answer after `Disinter` means the restore ran (S7; no run-time sample contradicted it). A
    buried session answers too, so without `Disinter` before it an answer says nothing about
    where the tab is. A missing answer is logged, and the helper goes on.
  - **Recovery while the app runs** (design item 5): the coordinator remembers the launch tabs
    it buried (launch id and gateway session id, the latest 64, like its launches). While that
    list is not empty, a file-only peek at their results runs every 2 s and on every attach,
    detach and attachment check; iTerm2 is contacted only once a result has appeared. Then it
    sends `setBuried(false)`; when the result is clean and the session is still listed (a dead
    tab, S4: the helper's restores never reached iTerm2), a forced `Close` by its session id,
    statuses and absence checked (it works on a buried session directly, (d)); a tab whose
    helper reported a failure stays visible for its explanation. A result the sweep removed
    (older than D14's 120 s) leaves a tab that owns no connection: restored and left visible.
  - **Persistence (item 5's decision): memory only.** The helper alone brought the tab back
    after every abnormal end the spike tried (the attach child killed locally, the local ssh
    killed for Saturno), with iTerm2's default setting emulated, before its explanation, so a
    restart of muxFinder loses no recovery the helper does not make itself. Left to the
    running app's recovery, and stranded while muxFinder is not running (a buried session
    under Session > Buried Sessions; README, Phase 13c): a helper that died without its
    restores, iTerm2's "Tolerate unrecognized commands from server" advanced setting on, or a
    tmux command still pending at the abnormal end (both keep iTerm2 in tmux mode).
  - **Show tab** (D25): restores the tab before activating it, never alongside a pending bury
    of that same tab.
  - **What 13b builds** (hermetic): the bury call site and its outcome on `AttachResult`; the
    peek (a non-consuming read on `LaunchRequestStore`) and the post-bury check; the
    remembered list with its timer and triggers; `showLaunchTab`'s restore; buried state in
    `SimulatedITerm2`, `InstrumentedITerm2`, `SimulatedProfileITerm2` and
    `FakeITerm2Integration` (a bury moves the tab to `buried_sessions`, a restore brings it
    back in a new window, S8); and design item 7's harness assertions in `e2e-local` and
    `e2e-remote` (buried after confirmation; after each detach the tab gone from tabs and
    `buried_sessions` by itself, before any cleanup). 13c runs them for real, with
    `e2e-bury` through the coordinator.

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
- **iTerm2 saves loaded dynamic profiles into `New Bookmarks`** (3.7.6, seen in Phase 11b's
  `e2e-profile` runs, compared by digests only): while `muxFinder.json` was installed, the
  `New Bookmarks` array of `com.googlecode.iterm2` held one more entry, the profile with its
  `Guid` (`muxfinder-persistent-…`) and a `Dynamic Profile Filename` key, the user's entries
  byte-identical. The copy goes after the removal: in the two passing runs (local and
  Saturno) step 13's first snapshot, taken right after `ListProfiles` stopped showing the
  GUID, found it gone, 238 ms and 266 ms after the removal, and the array hashed as before;
  the diagnosis during the second failing run saw it still there right after the removal and
  gone seconds later. So the snapshot leaves muxFinder's copies out and step 13 waits for the
  drop (D26).
- Signing identities: `Apple Development: Carlos Carpio García (5XHQZ98534)`, plus a Developer
  ID Application identity that is unused here.

Verified in the Phase 13a spike (2026-10-24, iTerm2 3.7.6, tmux 3.8, `muxfinder-probe
e2e-bury --local` and `--ssh saturno-m4`, the default tmux servers holding only
`muxfinder-test-*` sessions; 4 local and 2 Saturno runs, all 12 of 12 PASS, the first local
one on the helper before the line feed; runs in `docs/TESTING.md`, *Phase 13a*). S1–S4 and
S6–S8 were confirmed at run time, locally and on Saturno; S5's "off" branch only from the
source:

- **This iTerm2 has `AutoHideTmuxClientSession` on** (read with `defaults read`, never
  written; Phase 4 ran with it off). So iTerm2 buried every launch tab itself by the time the
  attach was confirmed (S6) and restored it itself when tmux ended, 144–228 ms after a detach
  (S5's "on" branch). The harness emulated the default by burying its own tab again where the
  default would have left it buried.
- **(a) The bury.** `SetProperty` `buried` `true` answers `OK` in 0–20 ms; within 55 ms
  `ListSessions` lists the tab in `buried_sessions` and in no tab, and its window (its only
  tab) is gone. The tmux tabs stay, and `ListConnections` still names the buried tab as the
  connection's owner, so the bound `detach-client` works while it is buried. A second bury
  answers `OK` (S2). `GetProperty` `buried` answers `1` or `0`, not `true`/`false`.
  `SetProperty` `false` answers `OK` in 111–140 ms, and the tab is back within 40 ms, in a new
  window (S8).
- **(b) Without `Disinter`.** A tab buried while its helper holds (tmux ended) stays in
  `buried_sessions` after the helper exits, a dead session (S4); with the default setting a
  clean detach of a buried tab would leave one every time (S5). A buried session still answers
  a status report (34–36 ms), so an answer alone shows only that iTerm2 parsed what preceded
  it.
- **(c) With the 13a helper.** A tab buried during the hold is restored by the helper's last
  restore (answered in 120–146 ms) and closes with the helper: nothing is left. No
  `ListSessions` sample sent after a restore's answer saw the tab buried (about 205 samples
  25 ms apart after (e)'s second restore, the last buried one 1–22 ms before the request):
  consistent with S7. The first restore after a clean detach (answered in 92–163 ms) could not
  be seen alone, since the setting restores the tab at `%exit`.
- **(d) `Close`.** A forced `Close` by the session id of a buried session answers `OK`, and the
  session is gone within 18 ms, dead or live (a live one's helper gets SIGHUP and ends).
- **(e) The abnormal end.** After SIGKILL of only the attach child while buried (locally
  `tmux -CC`; for Saturno the local `/usr/bin/ssh`, `ssh -G` showing `controlmaster false`)
  tmux sends no `%exit`, and iTerm2 keeps parsing the tab as a tmux gateway. With the first
  helper the first restore went unanswered (swallowed), and the gateway left tmux mode only
  about 2.1 s later, when the explanation's leading line feed completed a line (iTerm2's
  `TmuxGateway` ends the connection at any line not starting with `%`, printing "Unrecognized
  command from tmux…", unless the advanced setting "Tolerate unrecognized commands from
  server" is on); with the default setting the tab would have stayed buried while the helper
  waited for Return. With the line feed and the second restore (D29), locally and on Saturno:
  the connection and its tmux tabs were gone 112–255 ms after the kill, the first restore went
  unanswered, the second was answered in 112–185 ms, and the tab, buried again by the
  harness, was back in a tab 113–181 ms after that second request. The explanation follows
  that answer, so iTerm2 draws it as terminal output (not looked at: no screen capture).
  Return was not pressed (no keystrokes): the helper still waited for it, and after the tmux
  end the tab is an ordinary terminal, so Return would reach it (inferred). The
  `muxfinder-test-*` session survived with no client in both places (on Saturno its tmux
  client ended with the ssh connection).
- iTerm2's thread count stayed at 15–17 before and after all six runs.

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
  readable in light and dark; menu bar icon is a template image (an SF Symbol until D28).
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

Split (2026-10-22, before the first worker): Phase 10 is two sub-phases, each with its own
worker, verification, review and commit, so the real iTerm2 runs come only after the state
machine and the UI are proven hermetically.

- **10a — Attach UX in the app (high).** Every deliverable and requirement above: the
  per-session attach state machine in `AppModel` replacing D22's `DeferredIntent`
  placeholders, the row actions and context menu, the Move here confirmation, Detach, the New
  session sheet, the vanished/changed banners, preview fixtures and screenshots of the new
  states, and the `--selftest attach-local` / `--selftest new-session-local` flags. Proven
  with the fake integration (the 5-click burst, a distinct message per failure path) and with
  hermetic tests of the self-test drivers; it opens no iTerm2 window.
- **10b — Real self-tests (high).** Both self-tests run from the shell against the real
  iTerm2 and local tmux and exit 0; the quit-leaves-work-running check; fixes the real runs
  call for. Gated by the iTerm2 thread-count rule like every real run.

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
  `defaults export com.googlecode.iterm2 -` (without iTerm2's own copies of muxFinder's
  profiles, D26), are identical before install, after install and after removal.
- iTerm2's `ListProfiles` shows the GUID.
- Real e2e: `CreateTab(profile_name=…)` gets a confirmed control-mode connection to
  `muxfinder-test-profile`, locally and on Saturno. Clean up afterwards.
- A nesting-guard test passes.

Split (2026-10-23, before the first worker): Phase 11 is three sub-phases, each with its own
worker, verification, review and commit, so the profile format meets the real iTerm2 before the
Settings UI is built on it.

- **11a — Profile core, helper mode and probe (high, hermetic).** The host-list fields the
  profiles need (per-host opt-in, default session name, optional parent profile; existing
  `hosts.json` files still load), the `Profiles/` generator (pure) and atomic installer and
  remover for `DynamicProfiles/muxFinder.json` (injectable directory, never touching any
  other file), helper mode `muxfinder-launch profile <hostUUID>` with the nesting guard and
  the login-shell fallback, and the probe commands the real runs need (`ListProfiles` with
  GUIDs, a read-only hash snapshot of the other `DynamicProfiles/*` files and of `New
  Bookmarks` from `defaults export com.googlecode.iterm2 -`, and an `e2e-profile` harness).
  Unit tests, the nesting-guard test included; opens no iTerm2 window, writes no real
  `DynamicProfiles` file.
- **11b — Real profile runs (high).** The hash snapshot before install, after install and
  after removal; `ListProfiles` shows the GUID; `CreateTab(profile_name=…)` gets a confirmed
  control-mode connection to `muxfinder-test-profile` locally and on Saturno; cleanup. Fixes
  the real runs call for. Gated by the iTerm2 thread-count rule like every real run.
- **11c — Settings section and launch-time rewrite (routine).** The Settings controls over
  11a's fields, "Install profiles" / "Remove profiles", the copy (Set as Default path; shells
  started elsewhere are not adopted), the rewrite at app launch when the helper path changed,
  preview fixtures and screenshots.

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

Split (2026-10-23, before the first worker): Phase 12 is two sub-phases, each with its own
verification, review and commit, so the documents and scripts exist before the acceptance run
records its results in them.

- **12a — Scripts and documents (routine, hermetic).** `scripts/install.sh` and
  `scripts/uninstall.sh` (each with a dry run and test overrides for the destination and home
  folders, so they can be exercised on private folders; the uninstall script stops only
  processes of the copy it removes, with SIGTERM, never through LaunchServices or Apple
  events, and removes `DynamicProfiles/muxFinder.json` only when it is muxFinder's generated
  file, D26), a hermetic check of both scripts on private folders, `README.md`,
  `docs/ARCHITECTURE.md`, the tested vs expected-to-work matrix in `docs/TESTING.md` (each
  brief acceptance bullet mapped to the evidence so far or to "unverified: why") and the
  manual checklist for the user (`docs/MANUAL-CHECKLIST.md`). The build script reproduces the
  `.app` from a clean `build/`. Opens no iTerm2 window; neither script runs for real on the
  user's `/Applications`, `~/Applications`, `DynamicProfiles/` or Application Support.
- **12b — Acceptance run (routine, real runs).** A fresh full run on the final tree: every
  unit test, `e2e-local`, `e2e-remote saturno-m4`, `e2e-profile --local` and `--ssh
  saturno-m4`, both self-tests, the clean-`build/` reproduction; results with dates, commands
  and exit statuses recorded in `docs/TESTING.md`'s matrix. Gated by the iTerm2 thread-count
  rule like every real run; fixes the run calls for.

### Phase 13 — Hide the launch tab once attached (high)

Goal: an attach shows only the session's tmux windows. Today the launch tab (the tmux gateway,
showing "** tmux mode started **" and iTerm2's command menu) stays visible in a window of its
own next to them (reported by the user on 2026-10-24 for New session; Open and Move here do the
same, PLAN.md *Verified facts*, Phase 4). iTerm2's "Automatically bury the tmux client session
after connecting" (`AutoHideTmuxClientSession`) is off by default and muxFinder never writes
iTerm2 preferences, so muxFinder buries its own launch tab through the API. The user chose this
on 2026-10-24 over documenting the iTerm2 setting.

Source facts (iTerm2 tag `v3.7.6`, read on 2026-10-24 from the public `gnachman/iTerm2`
sources; seen at run time in the 13a spike, *Verified facts*, Phase 13a: all confirmed but
S5's "off" branch, which the Mac's iTerm2 setting hid):
- **S1.** `SetPropertyRequest` is `ClientOriginatedMessage` field 111 (`window_id` 1 and
  `session_id` 5 in the oneof `identifier`, `name` 3, `json_value` 4); `SetPropertyResponse`
  is `ServerOriginatedMessage` field 111 (`status` 1: `OK` 0, `UNRECOGNIZED_NAME` 1,
  `INVALID_VALUE` 2, `INVALID_TARGET` 3, `DEFERRED` 4, `IMPOSSIBLE` 5, `FAILED` 6). The Python
  module's `Session.async_set_buried(b)` is `rpc.async_set_property(name="buried",
  json_value=json.dumps(b), session_id=…)`; `GetProperty` (112) also knows `"buried"`.
- **S2.** The API's `buried` setter (`iTermAPIHelper.m`) is idempotent: it answers `OK` without
  acting when the session is already in the requested state, else it calls `-[PTYSession bury]`
  or restores the session.
- **S3.** `-[PTYSession bury]` adds the session to `iTermBuriedSessions`, removes it from its
  tab (the window closes when that was its only tab) and sets its delegate to nil. Burying a
  buried session again does nothing.
- **S4.** A buried session whose program ends is **not closed**: `brokenPipe` with the end action
  Close asks the nil delegate `sessionShouldAutoClose:` (so NO); the session stays under
  Session > Buried Sessions as a dead session.
- **S5.** `tmuxHostDisconnected:` restores a buried gateway only when `AutoHideTmuxClientSession`
  is on. With the default (off), a gateway buried through the API stays buried after tmux ends,
  so with S4 every attach would leave a dead buried session unless muxFinder restores it.
- **S6.** iTerm2's own auto-hide buries the gateway only once the first tmux window has opened
  (`_hideAfterTmuxWindowOpens`), never while only the tmux dashboard shows.
- **S7.** `OSC 1337 ; Disinter ST` makes a session restore itself (`VT100Terminal` key
  `Disinter`, then `screenDisinterSession`; nothing happens when it is not buried). It runs as an
  unmanaged *paused* side effect, so token execution waits until the restore ran; a report
  request written after it (DSR `ESC [ 5 n`, answered `ESC [ 0 n`) should therefore be answered
  only after the restore. That would be the acknowledgment the helper needs (an inference; 13a
  verifies it).
- **S8.** Restoring a session whose window is gone creates a new window for it.

A Codex design review (2026-10-24, verdict "proceed with changes") shaped the requirements
below. Its findings: two `Disinter` writes alone do not close the race between a bury and the
helper's end; a written OSC is not an acknowledged restore; an abnormal end (the attach child
killed without `%exit`, ssh dropping) may leave iTerm2's parser in tmux mode, so neither the
OSC nor the helper's explanation would be parsed; e2e cleanup must never hide a stranded
gateway.

Design (13a records it as **D29**, as far as the spike's facts support it, and edits D14, D15
and D25 where they change):
1. **Client.** `SetPropertyRequest`/`SetPropertyResponse` in the hand-written client (envelope
   field 111 both ways); `ITerm2Error.setPropertyFailed(status)` (answered, definitive, D13);
   `ITerm2Integration.setBuried(_:sessionID:)`; and an ownership-bound compound
   `buryLaunchTab(sessionID:ifOwnsTmuxConnection:)` that lists the tmux connections and sends
   SetProperty on the same API connection, never reconnecting in between, like
   `activateFirstTab(ofTmuxConnection:ownedBy:options:)` (`tmuxConnectionNotOwned` when the
   launch tab no longer owns that connection). Golden fixtures come from the Python module
   (`scripts/dev/gen-iterm2-fixtures.py`): bury and unbury requests, an `OK` response and a
   non-`OK` one. Every conformer gets the methods: `ITerm2APIClient`, `FakeITerm2Integration`,
   `InstrumentedITerm2`, `SimulatedITerm2` and `SimulatedProfileITerm2`.
2. **When the coordinator buries.** Only a launch tab this launch opened, only after step 9
   returned `.activated(tabID:)` (S6). It never buries after `.noTab` or a failed activation,
   for a failed or unconfirmed attach, for a `focused` attach, or any tab muxFinder did not
   open. It buries once per launch (coalesced callers share it), for `attach`,
   `createAndAttach` and `moveHere` alike. A failed bury is not fatal and is never retried
   (D13). The outcome goes on `AttachResult` (new field) and into diagnostics: `buried`,
   `skipped(reason)`, `failed(error)`, `uncertain` (sent, no answer) or `restoredAfterEnd`.
   muxFinder never reads iTerm2's preference: the setter is idempotent (S2), and with the
   preference on, iTerm2 restores its gateway itself (S5).
3. **Closing the race by order.** The helper writes its result before its first `Disinter`
   (item 4). After the bury's answer (or its timeout), the coordinator checks, without
   consuming the result (a peek, so `detach` still takes it later), whether the helper's
   result exists or the launch tab no longer owns the connection. If either holds, it sends
   `setBuried(false)` (idempotent). A bury that iTerm2 handled after the helper's `Disinter`
   was therefore answered after the result existed, and is undone. Unit tests drive every
   interleaving with the fakes. Mind `LaunchStore.sweep()`, which deletes result files older
   than its time to live.
4. **The helper** (`attach` mode only, not `profile` or `ssh-setup`; only on a terminal). After
   the child exits, for every outcome, it writes the result, then `Disinter`, then a DSR, and
   waits a bounded time (about 2 s; raw mode; input typed earlier discarded) for the reply
   (the spike added a line feed before it and a second restore when it goes unanswered, D29). A
   missing reply is logged without user data, and the helper goes on. Then come the
   explanation, the Return wait and the minimum-lifetime hold, as today. Just before exiting,
   it writes `Disinter` and a DSR again and waits again (this covers a bury during the hold).
   Hermetic tests use the `LaunchTerminal` seam: the bytes written, their order relative to
   the result, and the bounded wait.
5. **Recovery by the app while it runs.** The coordinator remembers the launch tabs it buried
   (launch id and gateway session id, bounded like `rememberedLaunches`). While that list is
   not empty, a cheap file-only check (a peek at the result) runs on a timer, and on every
   attach, detach and attachment check. A remembered tab whose helper ended gets
   `setBuried(false)`. If its result is clean and the session is still listed afterwards (a
   dead tab, S4), muxFinder closes it (forced `Close` by its own session id, statuses
   checked). A tab that ended with a failure is left visible so the user can read it. iTerm2
   is contacted only once a result has appeared. 13a's abnormal-end result decides whether the
   list must survive a restart of muxFinder: if the helper alone recovers abnormal ends,
   memory is enough; otherwise persist it under `~/Library/Application Support/muxFinder/`
   with D19-style safe writes. The helper alone did, so D29 keeps the list in memory.
6. **Show tab.** `showLaunchTab(_:)` restores the tab (`setBuried(false)`) before activating
   it, and never runs alongside a pending bury of that same tab.
7. **The harness.** After confirmation, `e2e-local` and `e2e-remote` assert that the gateway is
   in `buried_sessions` and in no tab. After each detach, they assert that it left both tabs
   and `buried_sessions` by itself before any cleanup; a stranded gateway fails the step.
   Cleanup's `Close` checks every status and the session's absence afterwards, falling back to
   restore, then close.

Acceptance:
- With default iTerm2 preferences, an attach (Open, New session, Move here), locally and on
  Saturno, leaves exactly the session's tmux windows visible, and the launch tab is in
  `buried_sessions`.
- After every detach, the launch tab leaves both tabs and `buried_sessions` by itself. This
  covers muxFinder's Detach, a tmux detach inside the session, and a detach within 10 s of
  attaching. No real run leaves a dead buried session (checked before cleanup).
- After a failure following confirmation (the attach child killed in a test), the launch tab
  comes back with its explanation readable and Return working. If 13a proves the terminal
  cannot do that, muxFinder's recovery (item 5) restores the tab within a stated time while
  it runs. The case it cannot cover (muxFinder not running) is documented.
- Nothing is buried for a focused attach, `.noTab`, a failed activation or a failed attach;
  coalesced callers get exactly one bury.
- The unattended-run rules still hold: no other tab or session is touched, and no iTerm2
  preference is written. The shared verification, every existing `e2e-*` run and both
  self-tests still pass.

Split (2026-10-24, when the phase was written): three sub-phases, each with its own
verification, review and commit, so iTerm2's real behavior is known before the coordinator is
built on it.

- **13a — Client, helper and spike (high; hermetic code plus one gated real spike).** Design
  items 1 and 4 with unit and golden tests. In test mode, the helper records its attach
  child's PID in the argv digest, so a harness can kill exactly that process and nothing
  matched by name. Also a probe harness, `muxfinder-probe e2e-bury --local | --ssh
  saturno-m4`: it uses its own `muxfinder-test-*` session and its own launch tab, bounds every
  wait, cleans up on every way out, prints one PASS/FAIL/observation line per step and changes
  no coordinator code. On the real iTerm2 3.7.6 with default preferences, it establishes:
  (a) burying its gateway answers `OK` and moves the session from its tab to
  `buried_sessions` (S1–S3), and `GetProperty`/`ListSessions` show it; (b) a clean detach of a
  buried gateway when the helper writes no `Disinter` (a test-mode switch) leaves a dead buried
  session (S4, S5), which the harness then restores and closes; (c) with the 13a helper, a
  clean detach of a buried gateway leaves nothing behind, and the DSR reply arrives only after
  the restore (S7); (d) what `Close` answers for a buried session id, and whether the session
  is gone afterwards; (e) the abnormal end: SIGKILL of only the helper's attach child (locally
  the `tmux -CC` client; remotely the local ssh child, `ControlMaster=no`) while the gateway is
  buried. Does the tab come back, does the explanation show, does Return work, and does the
  `muxfinder-test-*` session survive? The answers go into *Verified facts*; D29 is written
  from them, including item 5's persistence decision. Gated by the iTerm2 thread-count rule.
- **13b — Coordinator, race and recovery (high, hermetic).** Design items 2, 3, 5, 6 and 7 as
  D29 settled them. Unit tests cover: a bury before or after the helper's restore; the result
  appearing before or after the peek; a bury timeout; the connection gone; coalesced callers;
  focused attaches; Move here; `.noTab`; a failed activation; `showLaunchTab` during a pending
  bury; recovery closing a clean dead tab while leaving a failed one visible.
  `SimulatedITerm2` gains buried state. No user-facing string changes are planned.
- **13c — Real runs and documents (high).** Gated real runs: `e2e-local`, `e2e-remote
  saturno-m4`, `e2e-bury --local` and `--ssh saturno-m4` (now through the coordinator), both
  self-tests (which then also assert the buried launch tab), `e2e-profile --local` unchanged;
  fixes the runs call for. The `e2e-bury` runs cover: confirmation, then buried; a detach
  within 10 s, one after 10 s, and one timed right at the bury; the attach child killed after
  confirmation. Documents: `README.md` (one attach shows the session's windows; while
  attached, the launch tab is under Session > Buried Sessions; it shows briefly on detach;
  iTerm2's own setting needs nothing more), `docs/ARCHITECTURE.md`, the `docs/TESTING.md`
  matrix and results, `docs/INTEGRATION-PROOF.md` (its "stays in its window" statement),
  `docs/MANUAL-CHECKLIST.md` (which window has focus after a detach brings the tab back; the
  flow through the real popover), and the project `CLAUDE.md` command notes (step counts,
  `e2e-bury`).

### Phase 14 — Popover readability: host sections, attach state, muted offline hosts (routine)

Goal: the popover reads at a glance. The user reviewed the real popover on 2026-10-24 and
asked for four things:
1. **Distinct items, not a "Material/iOS 7" look.** They want a clear section per computer
   and, inside it, a clear view of which sessions are active.
2. **"Open in iTerm2 here" is hard to read**: blue text on gray.
3. **An unreachable computer should not draw the eye.** Its red dot reads as an alert. Gray
   it out instead.
4. **Footer spacing is wrong.** The refresh arrow sits much closer to "New session" than to
   "Refresh".

Findings behind it (2026-10-24):
- **The real popover is translucent.** `MenuBarExtra` with `.menuBarExtraStyle(.window)`
  (`Sources/MuxFinderApp/MuxFinderMenuBarApp.swift`) draws on the system's vibrant material.
  The preview galleries paint `windowBackgroundColor` behind the same views
  (`Sources/MuxFinderUI/Preview/PreviewGallery.swift`), so `docs/screenshots/popover-states-*`
  never showed what the menu bar shows. On the material, `.secondary` text, the selection tint
  (`Color.accentColor.opacity(0.22)`, `SessionRowView`) and the badge (accent text on an
  accent capsule at 0.14, `OpenHereBadge`) all lose contrast. A selected row with the badge
  becomes blue on blue-gray.
- **Hosts are separated by whitespace only.** `HostSectionView` lays out a header, then rows
  with `spacing: 12` between hosts, with no boundary.
- **Unreachable is the only red host status.** `StatusLabelView` maps
  `HostStatusLabel.Tone.problem` (only `.unreachable`) to a red dot, and its problem line
  carries an orange warning triangle. Sirio is offline most of the time, so this is the
  normal state and should look routine.
- **The footer packs its buttons together.** `FooterView` uses `HStack(spacing: 2)` with
  `.labelStyle(.titleAndIcon)`, so the gap between one button's title and the next one's icon
  is narrower than the gap inside a label.

Deliverables: changes in `Sources/MuxFinderUI/Views/` (`PopoverView`, `PopoverParts`,
`HostSectionView`, `SessionRowView`, `SessionPanelViews` where the panels share the styles),
in `Model/HostStatusLabel.swift` (tones), and in the preview galleries. Regenerated
`docs/screenshots/popover-states-{light,dark}.png` and `attach-states-{light,dark}.png`.
Tests, and D22 edited for the new look.

Requirements:
- **Opaque popover.** It draws its own opaque background (`windowBackgroundColor` or
  equivalent), with no vibrancy or blur under the content, so the real popover and the
  preview gallery look the same. Verify that the `.window` style still sizes and closes as
  before.
- **A clear section per computer.** Each host is a visibly bounded group: for example a box
  with a hairline border and a header band (name; "Last checked …"; status) set off from its
  session rows. Sections are separated by more than whitespace. No translucent cards, glows or
  heavy shadows; flat, macOS-native grouping in the spirit of a grouped form or a source
  list. Rows inside a section are told apart by separators or a consistent row rhythm.
- **Active sessions stand out inside each section.** Here "active" means *attached*: at least
  one tmux client, or open in iTerm2 on this Mac. It never claims process activity or
  idleness (the brief and Phase 8 forbid that). Each row gets a leading state indicator with
  a distinct shape and color: open in iTerm2 here; attached elsewhere ("1 client"); detached;
  stale (last seen … · not live). The row's text still says the state, so color is never the
  only signal. Attached rows read stronger than detached ones (for example, primary versus
  secondary name weight). The order of rows does not change.
- **"Open in iTerm2 here" is readable.** Its text contrasts at least 4.5:1 with what is
  actually behind it, in light and dark, on a selected row and an unselected one. Do not
  stack accent on accent: for example, give the badge a solid fill with white or primary
  text, and show the selection as a neutral fill or an outline that keeps the badge legible.
- **Muted unreachable host.** `.unreachable` gets a new muted tone: no red, and the status
  dot is gray or hollow. The section is dimmed: name, caption and status in secondary
  colors, and its stale rows dimmed. The problem line ("The connection timed out.") uses a
  neutral icon in secondary color instead of the orange triangle. "Retry" stays usable.
  Statuses the user can act on ("Sign-in needed", "Host key problem", "tmux not found",
  "Check failed") keep their orange attention tone. Red stays for failed session actions
  (`ActivityLine` `.failed`), not for host reachability.
- **Footer spacing.** Each icon sits clearly closer to its own title than to its neighbor:
  the gap between buttons is at least three times the icon–title gap, or the buttons are
  separated visibly. "Quit" stays trailing. The keyboard shortcuts and help texts are
  unchanged.
- **Unchanged.** Behavior, keyboard navigation (↑/↓, Return, ⌘F, ⌘R, ⌘N, ⌘, and Esc), search,
  panels (Move here, New session), accessibility labels, values and traits (they may gain the
  attach state), sentence-case text, and the width (360 pt) unless the layout needs more,
  recorded in D22.

Acceptance:
- Unit tests: `HostStatusLabel.unreachable` has the muted tone and every other status keeps
  its tone. A contrast test resolves the badge's text color, and the background behind it on
  selected and unselected rows, in light and dark environments (`Color.resolve(in:)`). It
  computes the WCAG ratio and requires at least 4.5:1. The row-state mapping (here, attached,
  detached, stale) has its own test. The existing UI tests pass unchanged, or with recorded
  label additions.
- The preview galleries (`--preview-fixtures`, and `--preview-gallery attach`) are rendered
  with `--preview-snapshot` in light and dark and committed. The popover gallery includes a
  state with a selected row carrying the badge, and an unreachable host next to a host in an
  "attention" state. They show: bounded sections per host, attach state at a glance,
  a muted unreachable host, a readable badge and even footer spacing.
- `scripts/build-app.sh` exits 0, and `codesign --verify --deep --strict build/muxFinder.app`
  passes. `--report-menu-bar-item` still shows the item and quits with exit 0.
- `docs/MANUAL-CHECKLIST.md` gains an item: open the real popover and confirm it matches the
  screenshots (opaque, readable badge, muted Sirio when offline, footer spacing).
- Shared verification (`swift build`, `swift test`, `swift format lint -r Sources Tests`)
  passes. No iTerm2 window is opened, and no real run is needed.

## Deferred (explicitly out of scope for v1)

Named tmux sockets, session deletion, cloud sync, terminal previews, AI features, process
migration, reboot resurrection, workspace management, Intel builds. (Notarized distribution
was deferred too until D28 added `scripts/release.sh`.)
