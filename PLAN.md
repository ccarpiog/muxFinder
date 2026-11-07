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
                              DirectoryLists + DirectoryStore (directories.json, D31),
                              GlobalShortcut + PreferencesStore (preferences.json, D32),
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
  MuxFinderUI/                library: AppModel, popover content and views, the menu bar
                              item and popover panel (MenuBarPopover, PopoverController,
                              D30), the Settings window (SettingsModel, views, window
                              controller), the onboarding window (OnboardingModel, view,
                              window controller), the session switcher shortcut
                              (GlobalShortcutModel, CarbonHotkeyRegistrar, the recorder,
                              D32), preview fixtures (D22, D23, D24); tests import it
  MuxFinderApp/               app shell on a plain NSApplication with muxFinder's own main
                              menu (D33): entry point and app delegates only
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
  The folder-search script (D36) is a D3 user with no argument over SSH: the string is
  `/bin/sh -c '<static script>' muxfinder` (This Mac's argv adds one fixed word, `unchecked`,
  never a runtime value; Phase I-10b), and its data, the queries, arrive afterwards on
  standard input as data lines (an id, a scope token, escaped name text) that the script
  splits with parameter expansion, checks, and places into its one fixed predicate as a
  quoted word, never as shell source and never through `eval`.
  **Extension for a terminal's command text** (decided in Phase I-12a, 2026-11-06, with D38;
  code in `Sources/MuxFinderCore/Terminals/TerminalCommandText.swift`, tests in
  `TerminalCommandTextTests`): Terminal.app's `do script` types its text into the user's own
  login shell, whatever it is (zsh, bash, fish, tcsh…), so that text is shell source. It is
  `exec`, then the helper path and the helper's words (its constant mode words and the
  canonical launch id), each POSIX single-quoted, one space apart:
  `exec '<helper path>' '<mode>' … '<launch id>'`
  (`TerminalCommandText.shellCommand(helperPath:arguments:)`). The helper path is refused
  with a clear error ("… move muxFinder to /Applications …") when it holds `'` or `\` (fish
  reads `\'` and `\\` inside single quotes as escapes, POSIX shells do not), `!` (csh and
  tcsh expand history inside single quotes) or a control character (C0, DEL or C1: a line
  break would end the command); it must be absolute. The words must be non-empty ASCII
  letters, digits, `.`, `_` and `-`. So every word reads the same in every one of those
  shells, which the tests run: sh, zsh, bash, dash, ksh, tcsh and csh (fish too when
  installed; it is not on Neptuno), for a helper whose folder name holds spaces, `$`, `;`,
  parentheses, backquotes, double quotes, `*`, `~`, `#`, `&`, `|`, braces and non-ASCII.
  `exec` replaces the user's shell with the helper, so no shell code runs after it. D2's
  stricter character rule for the helper path still applies on top, so today's paths pass
  both. Ghostty's `command` is no typed text (D38): its words come from D2's character set
  and need no quoting under any of its parsings. The plain remote attach (D38) is a D3 user
  with six quoted arguments, the guard's five and the launch token.
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
  (`hosts.json`, `directories.json`, `preferences.json`, `launch/`, diagnostics), with
  directories 0700 and files 0600, and no extended ACL (D14 for `launch/`, D19 for the folder
  itself and `hosts.json`, D31 for `directories.json`, D32 for `preferences.json`; muxFinder
  keeps no setting in its defaults domain). The app owns
  exactly one iTerm2 file, `~/Library/Application Support/iTerm2/DynamicProfiles/muxFinder.json`,
  written and removed only by `PersistentProfileInstaller`, which never touches another entry of
  that folder (D26). Never write iTerm2 preferences, other profiles, or shell startup files.
- **D9 — Scope.** Only the current user's **default tmux server**; named sockets are deferred.
  The UI and README say so.
- **D10 — UI language is English, sentence case** ("New session", "Move here", "Refresh").
- **D11 — Tests.** `swift test` is hermetic: fakes for the process runner, the clock and
  iTerm2; no ssh; tmux only on a private, test-owned socket directory, never the user's server.
  Real-world checks run only through `muxfinder-probe` subcommands (`discover`, `folders`,
  `attach`, `new-session`, `e2e-*`, `hosts`, `profiles`, `refresh`; all but `discover`,
  `folders`, `hosts`, `profiles` and `refresh` open real iTerm2 windows) and the app binary run from the shell (D22: the preview window and the
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
  - **Files:** `launch/<uuid>.request.json` and `<uuid>.result.json` (and, for a plain launch,
    `<uuid>.report.json`, *Plain modes* below), the uuid only in
    canonical lowercase form (`LaunchToken`, validated before it names a file). Writes are
    atomic (temporary file with `O_CREAT|O_EXCL|O_NOFOLLOW`, mode 0600, then a rename;
    `RENAME_EXCL` for requests, so an id is never reused). The directory is 0700 (tightened if
    looser) and refused if it is a symbolic link, not a directory, or owned by another user;
    all file calls go through its descriptor. Only `writeRequest` (and
    `createTestModeMarker`) creates it. The helper takes its request by opening it with
    `O_NOFOLLOW` and unlinking it at once (the first unlink wins, so a request is used once),
    then requires a regular file owned by the user, no group or other bits, no extended ACL and
    at most 16 KiB. Results are taken the same way; `peekResult` reads one under the same
    checks without unlinking anything (the coordinator's look at a buried launch tab's helper,
    D29), so a result nobody takes is left to the sweep. Each helper mode takes only requests of
    its own kind (D24): an attach
    request has no `kind` field (so every file written before ssh setup existed reads exactly
    as before), an ssh setup request has `"kind":"sshSetup"`, and a well-formed request of the
    other kind is refused (72), gone like every refused request. An attach request's
    `terminal` (D38) splits it further: `attach` takes only `iterm2` (or no field), and
    `attach-plain` only a definition's id (*Plain modes* below). TTL: 120 s after `createdAt`
    (5 s future tolerance), on an injectable
    clock. The sweep removes request, result, report, argv-digest and temporary files whose
    mtime is older than the TTL.
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
    71 expired, 72 unreadable (also a request of the other kind, D24, or for the other
    terminal, D38), 73 launch directory
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
    `LaunchHelper.finish`; `profile` and `profile-plain`, D26, except when it hands the tab to
    the login shell, which keeps it open; `attach-plain` only when its request's
    `keepsMinimumLifetime` is true, D38): it writes the result first, waits for Return if it failed,
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
    the helper goes on. `profile`, `ssh-setup` and the plain modes never do it.
  - **Test mode:** set by `MUXFINDER_LAUNCH_TEST_MODE=1`, or by a regular file
    `launch/test-mode` owned by the user. The marker is how 4b turns test mode on for helpers
    iTerm2 starts: the e2e run creates it (`LaunchStore.createTestModeMarker()`) and removes it
    in cleanup (`removeTestModeMarker()`), and the sweep leaves it alone. In test mode the
    helper writes `launch/argv-<pid>.json` before parsing argv: the argument count, then each
    argument's byte length and SHA-256, plus the first canonical launch id found. Right before
    it starts its attach child (tmux locally, ssh remotely) it writes the file again with
    `attachChild`: that child's argv digested the same way and whether it detaches the
    session's other clients (D21); a launch that ends first has none. In `attach`,
    `attach-plain` and `profile-plain` mode it then
    writes it again with `attachChildProcessID` right after the spawn (the child is the
    helper's own and unreaped while it runs, so a harness can signal exactly it) and, in
    `attach` mode, with one
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
    (`profileCommandLine(forHostID:)`, D26), and its plain command for other terminal apps
    `<path> profile-plain <host id>` (`plainProfileCommandLine(forHostID:)`, D38).
  - **Plain modes** (Phase I-12b2, 2026-11-06; D38 *Helper plain mode (I-12b2)*; code in
    `LaunchHelperPlain.swift`, `PlainLaunchReport.swift`, `LaunchHelperProfile.swift`). Two
    more mode words, `muxfinder-launch attach-plain <uuid>` and `profile-plain <host id>`,
    named constants in `LaunchHelperMode` with the other three (D2's characters only, so
    `TerminalLaunchCommand`'s `words` and `exec` forms take them as `{mode}`); plain mode is
    chosen by the word alone, never from `TERM_PROGRAM`, `TERM` or other environment.
    **The request's terminal:** an attach request carries `terminal` (`LaunchTerminalApp`):
    `"iterm2"`, or a terminal definition's id (`TerminalDefinition.isValidID(_:)`: `[a-z0-9-]`,
    1–32 bytes, never `iterm2`); anything else is a decoding error (72). The writer always
    writes it (`LaunchRequest`'s encoding); a file without it, as every earlier build wrote,
    reads as `iterm2` (a custom decoder, every other field read as before). `attach` refuses a
    plain request and `attach-plain` an iTerm2 one (explicit or missing) with
    `requestTerminalMismatch` (72), nothing run and the file gone (`LaunchStore.takeRequest`,
    `takePlainRequest`). A plain request also carries `keepsMinimumLifetime` (the definition's;
    absent means false); on an iTerm2 request the field makes it not well formed (72), since
    there the minimum always holds. **The early report:** `attach-plain` writes
    `<uuid>.report.json` (`PlainLaunchReport`, schema 1: `id`, `helperPID`, `terminalPath`
    from standard input with `ttyname` or absent when that is not a terminal,
    `attachChildPID`, `attachChildStartTime` `{seconds, microseconds}` from `proc_pidinfo`
    `PROC_PIDTBSDINFO`) from the runner's spawn callback, right after the attach child starts
    and before the helper waits on it, atomically and 0600 like a result
    (`LaunchStore.writeReport`, a well-formed report only, never creating the directory); an
    unreadable start time or a refused write writes none (logged, kinds only) and the attach
    goes on. `peekReport` reads it under the take checks without deleting anything; a missing
    one is `nil`, a malformed one (undecodable, another id, a bad value) `fileMalformed`, an
    oversized one `fileUnsafe(.tooLarge)`, never a report. It is removed with its result
    (`takeResult`, once the result file is claimed), by the sweep, and by `removeReport`.
    `attach` writes none.
- **D15 — Attach coordinator** (decided in Phase 4b, 2026-10-22; code in
  `Sources/MuxFinderCore/Attach/`).
  - **Launch tab:** `CreateTab` without `window_id`, so the tab opens in a new window and never
    in one of the user's, with the host's profile and `Close Sessions On End = true`: it closes
    by itself after a clean detach, and after a failure once the user pressed Return. The
    request runs in a task of its own, so cancelling an attach never loses the new tab's
    session id (the result reports it on every failure after the tab opened). Both the request
    and that task are `LaunchTab` (`Attach/LaunchTab.swift`), which "Set up SSH in iTerm2…"
    uses too (D24), so muxFinder opens tabs in iTerm2 one way only. Once an attach is confirmed
    and its first tmux tab activated, the coordinator buries its launch tab (step 10,
    `Attach/AttachCoordinatorBurial.swift`), and the helper (or the coordinator's recovery)
    restores it when tmux ends (D29). A buried launch tab still owns its connection, so
    *Connection binding* below holds unchanged.
  - **Seams:** iTerm2 (`ITerm2Integration`), discovery (`HostDiscovering`), the launch files
    (`LaunchRequestStore`) and the clock (`AttachClock`) are protocols, and the buried-tab
    timer (`BuriedTabTimer`, D29) is chosen at creation, so the coordinator is tested
    hermetically with fakes and manual clocks.
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
  - **Beside other terminals:** D38's *Open on this Mac (I-12c2)* traces This Mac's tmux
    clients to the terminal app their process descends from; with this index in use (iTerm2
    chosen) iTerm2's control-mode clients are left to it, so this mapping and its unmapped kinds
    stay exactly as above.
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
    executable keeps only the entry point, the menu bar app's shell (a plain `NSApplication`
    with muxFinder's hand-built main menu, `MainMenu` in `MuxFinderUI`; no SwiftUI `App` or
    scene, D33) and the app delegates (the menu bar app's, the
    preview window's and the self-tests', D25); the menu bar item and the popover panel are
    `MenuBarPopover` in `MuxFinderUI` (D30; muxFinder's template icon, D28; the SF Symbol
    `terminal` when unbundled). `PopoverContent` is a pure value computed from the
    engine's `RefreshState`, the search text, per-session activities, the selection and
    `now`; every displayed rule lives there and is tested without SwiftUI.
  - **Model and engine:** `AppModel` (`@Observable @MainActor`) runs on an `AppEnvironment`
    (host loading, engine, system-events and terminal-backend factories, the terminal setting
    (D38), wall clock, terminate), so tests pass fakes. `start()` loads the list with `HostStore.load()` (never writes; an unusable folder
    gives an empty list and a notice), in normal mode only and for a list loaded as `saved`
    has Settings bring an installed, out-of-date persistent profile file up to date in the
    background (`AppEnvironment.rewritesProfilesAtLaunch`, D26; the only write at launch),
    shows the onboarding window when it loaded as
    `notSavedYet` (D24), builds the `RefreshCoordinator` for it
    (`DiscoveryProbe`; `AttachmentIndex` over one shared `ITerm2APIClient`), subscribes to
    `updates()`, starts `RefreshSystemEvents` on `NSWorkspace`'s notification center, then
    `start()`s the engine. Visibility changes (the popover's and the session switcher's,
    combined below), "Refresh" and "Retry" go through one queue read by one task, so the engine
    sees them in order; once `shutdown()` has begun, requests still queued are dropped, so a
    popover opening queued just before quitting starts nothing in the engine about to stop.
    Relative times are measured against `now`, updated with every engine state and when the
    popover or the switcher opens.
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
  - **Look** (`Views/PopoverStyle.swift`): the popover paints its own opaque background, the
    gray `windowBackgroundColor` draws in a window (0.925 light, 0.196 dark), so nothing
    behind the transparent panel shows through and the real popover looks like the preview
    galleries; the panel (D30) sizes to the view (360 pt wide, the host list up to 440 pt
    before it scrolls, and shorter when the display has less room below the menu bar), clips
    it to rounded corners and has no arrow. Every fill is
    opaque and fixed per color scheme (`PopoverPalette`). Each host is a bounded box, flat
    like a grouped form: a hairline border, a header band (name, "Last checked …", status),
    then its problem line, empty state and session rows, the rows separated by hairlines.
    Each row starts with an attach-state indicator (`SessionRow.AttachState`): a blue window
    glyph when open in iTerm2 here, a green dot when attached elsewhere (tmux clients, and
    this Mac's last attachment check worked, or found iTerm2 not running, and shows none of
    them in this Mac's iTerm2), a gray dot in a dashed ring when attached with the location
    unknown (tmux clients while that check failed or has not finished: one check covers
    every host, SSH ones too, so no row then claims "elsewhere"), a gray ring when detached,
    a dim clock when stale ("open here" wins over stale, since the index is live).
    The row's text still says the state, attached names are semibold, the order is
    unchanged, and accessibility labels and values are as before (the indicator is hidden
    from VoiceOver). "Open in iTerm2 here" is white semibold text on a solid blue capsule,
    at least 4.5:1 in light and dark on any row (`PopoverStyleTests`); the keyboard
    selection is a neutral gray fill with an accent outline, so accent never sits on accent.
    Status tones: green (answered), gray (checking, no sessions), orange for what the user
    can act on ("Sign-in needed", "Host key problem", "tmux not found", "Check failed", with
    the orange triangle on the problem line), and muted for "Unreachable" alone, since an
    offline Mac is routine: a hollow gray dot, the host's name in secondary color, a neutral
    info icon on the problem line, "Retry" as usual. Red is only for failed session actions.
    The footer's buttons are 16 pt apart and each icon 4 pt from its title
    (`FooterLabelStyle`), "Quit" trailing.
  - **iTerm2 and its cookie:** nothing contacts iTerm2 at launch, the onboarding window
    included (D24). The popover's and the session switcher's only iTerm2 requests on their own
    are the engine's attachment checks, which run only while one of the two is visible and are
    cancelled when the last one closes (D20, D32); the Settings window adds one, the profile
    list, asked only when its window opens while iTerm2 runs (D23); "Set up SSH in iTerm2…"
    (D24) contacts iTerm2, and may launch it, only when the user clicks it. The client checks
    that iTerm2 runs before it asks for the cookie (D13). So the cookie is requested when the
    popover, the session switcher or the Settings window opens while iTerm2 runs, when the user
    chooses "Set up SSH in iTerm2…", and when the user acts on a session (D25); never at
    launch, once neither the popover nor the switcher shows (a cookie request, connection or
    identity question the check had not made by then is never made), while iTerm2 is not
    running, or while iTerm2 is not the chosen terminal (D38 *Onto the seam (I-12c3a)*: the
    checks are off, and the profile list, "Set up SSH in iTerm2…" and session actions do not
    reach it). Tested
    through the real `ITerm2APIClient` with counting and gated cookie providers, a fake
    running check and fake connectors.
  - **Popover visibility and keys:** `PopoverController` (D30) tells the model the popover is
    visible while its panel is open and not fully occluded, on changes only (opening, closing,
    occlusion), and `SwitcherController` does the same for the session switcher (D32). The
    model combines the two (`AppModel.isSessionListVisible`): the engine gets `.popoverOpened`
    and `.popoverClosed` once each whenever "either one is visible" changes, opening one closes
    the other, and each controller reports a new visibility before its panel shows, so the swap
    never reaches the engine as a close. A press on muxFinder's status item while the switcher
    shows hands over the same way whichever of its two effects comes first: the switcher leaves
    a close from outside made by that press to the popover the press opens (D32). A local
    key-down monitor of `PopoverWindowBridge` for the panel turns ↑/↓, Return, Esc, ⌘F, ⌘R, ⌘N and ⌘, (`PopoverKey`) into `AppModel.handle(_:)` before the search
    field sees them (not while an input method composes); Esc closes the panel through the
    controller. The arrows move through the listed rows only. The search field is asked for
    the focus each time the popover opens. The controller's rules are tested over fakes
    (`PopoverControllerTests`); the panel itself opens unattended only through the placement
    diagnostic's `performClick(_:)`, and the keys and clicks on the real icon are checked by
    hand (`docs/MANUAL-CHECKLIST.md`).
  - **Actions:** a click or Return opens a session, the row's context menu offers "Move
    here…" and "Detach from this Mac", and "New session" and ⌘N open the New session window
    (D34), all through D25's attach state machine. "Settings" and ⌘, open the Settings window (D23).
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
  - **Preview fixtures:** `--preview-fixtures` runs a plain `NSApplication` (no SwiftUI app
    and no `MenuBarPopover`, so no status item, and nothing recorded for one; no engine, host
    list or iTerm2) with one
    normal window of every state in `PreviewFixtures.all` (with `--preview-gallery settings`,
    `SettingsFixtures.all` instead, D23; with `--preview-gallery onboarding`,
    `OnboardingFixtures.all`, D24; with `--preview-gallery attach`, `AttachFixtures.all`,
    D25; with `--preview-gallery switcher`, `SwitcherFixtures.all`, D32): synthetic names,
    `*.example`
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
    status-bar-level windows with visibility and frames, then every other window of the app
    (title, class, visibility and level, never contents), the Apple event the launch came
    with and the main menu (`AppShellReport`, D33; read-only), so an unexpected window at
    launch shows in its output.
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
    runs the opening (login item status, the terminal picker's reading of the apps and the
    helper's path, D38 *The UI (I-12d1)*, host list, then profiles, suggestions, log and the
    persistent profile file's status, D26) in a
    task the model owns; closing it calls `windowDidClose()`: the opening is cancelled (with
    the profile request inside it, so the iTerm2 client stops before its next contact, and a
    cancelled `ITerm2ProfileSource` asks nothing), late results are dropped by window
    generation and nothing more starts, probes and "Set up SSH in iTerm2…" requests (D24) are
    cancelled and dialogs dropped (unsaved edits are lost, since the next opening reloads the
    list); becoming key reads the login item status again; resigning key, like closing, stops
    the session switcher shortcut's recorder (D32). Quitting runs
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
    and the popover use it from here too; `plainSSHSetup` makes a plain terminal's
    `PlainSSHSetupLauncher`, and `helperPath` finds the helper for the plain persistent work
    commands, D38 *The UI (I-12d1)*), and `PersistentProfileManaging`
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
  - **Session switcher shortcut** (Phase I-3a, D32): the General tab has a "Session switcher"
    section between "Startup" and "About muxFinder": "Show session switcher" with a
    hand-written recorder and "Clear". It **applies at once**, like the launch-at-login toggle
    (no Save or Revert): whether a combination registers is only known by registering it, so
    a taken one is shown as the user records. Refusals, warnings ("Use it anyway", "Choose
    another"), a taken shortcut and a failed save show beside the recorder, never in an
    alert; an unusable `preferences.json` disables it with its notice and "Try again". The
    model is `AppModel`'s `GlobalShortcutModel` (`SettingsModel.globalShortcut`), inert in
    every mode but normal mode.
  - **Diagnostics:** the tab lists the `DiagnosticsLog` entries newest first (host ids shown as
    display names) and the last iTerm2 check's problem with its fix-it; with a terminal other
    than iTerm2 chosen, a "Terminal" row (name, version, permission) and "iTerm2: Not used with
    Terminal" above them (D38 *The UI (I-12d1)*). "Copy diagnostics"
    (`DiagnosticsReport`) is plain text: muxFinder's and macOS's versions, the launch-at-login
    status, the load state, the iTerm2 check (kind, time, counts; "not used with Terminal" with
    a plain choice, and then a `Terminal:` line after the shortcut's), each host by display name
    and id with its mode, on or off, whether a tmux path or profile is set (never which), its
    popover label and status kind, times, session count and failures in a row, then the log
    (ISO 8601, UTC), with a line for the session switcher shortcut's state by kind after the
    iTerm2 check (D32; never the combination). Decided: destinations, tmux paths, profile
    names, node names and session
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
    and Diagnostics tab, and a failed "Set up SSH in iTerm2…" line (D24; also a plain
    terminal's window macOS refused, D38) show them. The
    Automation URL was not opened in an unattended run.
  - **Preview fixtures:** `--preview-fixtures --preview-gallery settings` shows
    `SettingsFixtures.all` (40 states: the persistent profile fields and tab's, the
    Directories tab's (D31), the session switcher recorder's, empty, recording with a
    refusal, the ⌘ warning, set and taken (D32), and the terminal picker's and the plain
    choice's (D38 *The UI (I-12d1)*) included; General frames 720 pt tall, the picker's 470 pt)
    in the same plain preview window, with the same
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
    the list is still not saved. Preparing it reads nothing more; opening it reads only the
    terminal picker's facts (LaunchServices and the Automation permission without a prompt,
    D38 *The UI (I-12d1)*); it contacts no iTerm2 and runs no ssh or tmux; the examples are
    turned off, so the engine discovers nothing either.
  - **Content** (`OnboardingModel.steps`): the Terminal step, the picker Settings › General
    shows (D38 *The UI (I-12d1)*); the examples (D19's defaults: Saturno, Neptuno and Sirio,
    SSH, no destination, turned off) as rows with the name, the SSH destination (This Mac's row
    says it is checked directly), "Set up SSH in iTerm2…" (named after the chosen terminal), a
    "This Mac" checkbox and "Turned on"; then the brief's four expectations one line each, the
    scope line (default tmux server only) and, with iTerm2 chosen, the iTerm2 requirements (the
    Python API on; the one-time Automation permission), otherwise what plain mode means and
    the chosen terminal's permission line (`OnboardingText`). It works with no iTerm2
    installed. The tmux path, the profile, adding and removing hosts stay in Settings.
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
    or typed text), and waiting for the helper's result (the login can last hours). With a
    plain terminal chosen, `PlainSSHSetupLauncher` writes the same request and opens a window of
    that terminal running `<helper> ssh-setup <uuid>` instead (`openedWindow`; D38 *The UI
    (I-12d1)*), and the lines name that terminal.
  - **Where it is offered (`SSHSetupActions`, one per window):** each onboarding row with an
    SSH destination that passes validation (the destination as typed; nothing is saved for
    it); the Settings host editor under the destination ("Set up SSH in iTerm2…", or in the
    chosen terminal, D38), replaced by "Set up SSH in iTerm2 first" under a Test connection
    result of "Sign-in needed" or "Host key problem"; the popover under a host whose last check failed `authFailed` or
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
    `OnboardingFixtures.all` (9 states: the examples, This Mac chosen with a tab opened,
    validation errors, a tab opening and one failing with its fix-it, saving, a list saved
    elsewhere, a failed save, no iTerm2 installed with Terminal chosen, Ghostty chosen with
    its windows); screenshots `docs/screenshots/onboarding-states-{light,dark}.png`.
    The popover's "Host problems" and Settings' "Test connection and a fix-it" fixtures show the
    action too.

- **D25 — Attach UX in the app** (decided in Phase 10a, 2026-10-22; code in
  `Sources/MuxFinderUI/Model/AppModelSessions.swift`, `SessionActivity.swift`,
  `SessionProblem.swift`, `SessionPanels.swift`, `Views/SessionRowView.swift`,
  `Views/SessionPanelViews.swift`, `Preview/Attach{Fixtures,Gallery}.swift`, `SelfTest/`;
  `Sources/MuxFinderApp/SelfTestAppDelegate.swift`; `AttachCoordinator.showLaunchTab(_:)`,
  `currentSession(named:on:)` and `createAndAttach(_:onCreated:)`'s `onCreated`).
  - **Seam:** `AppEnvironment.makeTerminalBackend` builds the chosen terminal's
    `TerminalBackend` at the first session action that needs it (never at launch), with the
    model's update handler, and the model keeps one per terminal id (D38 *Onto the seam
    (I-12c3a)*). iTerm2's is `ITerm2TerminalBackend` over one `AttachCoordinator` over the
    shared `ITerm2APIClient`, `DiscoveryProbe`, `LaunchStore` and the bundled helper
    (`LaunchHelperPath.locate()`) with the standard existing-attachment check (D16); when the
    maker throws (the helper is missing or on a path iTerm2 cannot be given), the row says why
    and offers nothing to retry. Tests build iTerm2's over a fake iTerm2 integration (the UI
    tests' `SimulatedITerm2`: launch tabs and tmux connections as state, identity answers,
    `detach-client` closing the connection), fake discovery, an in-memory launch store and a
    virtual clock; the index gets a clock whose question timeout never fires.
  - **State machine (`AppModel`):** at most one action per session (`runningActions`); a
    click, Return or menu item for a session with one pending is ignored, so a burst of five
    clicks gives one launch. The coordinator's updates and each action's result reach the model
    through one `AsyncStream` read by one main-actor task: the coordinator publishes a launch's
    states before its call returns and the action yields its result after, so a row never goes
    back. `requested` shows "Opening…" ("Moving here…" for a move), `launched` "Waiting for
    iTerm2…", `stillWaiting` "Still connecting — check the iTerm2 tab" with "Show tab" (with a
    plain terminal chosen the states name it and its window, "Waiting for Terminal…", "…check
    the Terminal window" with "Show window", D38 *The UI (I-12d2)*),
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
    action; a move here shows its confirmation again, so after one it is offered in the popover
    only, never in the session switcher), "Refresh", "Show tab" (a timeout, a
    helper failure or a wait limit with a launch tab), "Bring forward" and "Detach from this
    Mac" (`alreadyAttachedHere`), "Open Settings" (an invalid destination, tmux missing), and
    D23's fix-it for iTerm2 permission and API errors. A helper failure's explanation says
    "shown in the tab" where the helper wrote "shown above". A plain terminal's failures are
    worded for that terminal, with "Show window" and "Open System Settings…" (D38 *The UI
    (I-12d2)*).
  - **Banners:** `sessionGone` is "vanished", `sessionChanged` and `identityMismatch`
    "changed": the row's activity is cleared, a banner names the session and its host
    (dismissible, at most 3, newest first) and the host is refreshed.
  - **Show tab:** `AttachCoordinator.showLaunchTab(_:)` activates the session id with
    `select_session`, `select_tab`, `order_window_front` and the app options (the Python
    module's `Session.async_activate`), once, only for a launch tab the coordinator opened and
    still remembers; any other id is `notOpenedHere` and nothing is sent. It first restores the
    tab (`setBuried(false)`, idempotent; a refused restore ends it, `failed`, with nothing
    activated), never while a bury of that same tab is pending (D29). iTerm2 never hands out
    a session id again, so no binding check is needed. The model passes only ids from its own
    activities. Not yet seen against iTerm2 3.7.6 (local attaches never wait, so the self-tests
    do not reach it).
  - **Move here:** the row's context menu offers "Move here…" (disabled while the attachment
    index shows the session open here, D21; a window the chosen plain terminal's backend
    recorded never dims it, since that record may be stale: the backend checks its client at
    the move and refuses while it still holds the session, D38 *The UI (I-12d2)*). It shows a
    panel in place of the host list: "Move “name”
    here?", that muxFinder disconnects every other client, including iTerm2 on other Macs
    ("terminals" with a plain terminal chosen), that nothing is closed and the session keeps
    running, and
    the last client count. Cancel or Esc runs nothing; "Move here" or Return calls
    `confirmMoveHere()`, the only caller of `moveHere(_:confirmation:)`, with
    `.detachOtherClients(of:)` for that session.
  - **Detach:** "Detach from this Mac" is offered only for a session this Mac's iTerm2 shows
    (the index's badge, or `attachedHere`), or, with a plain terminal chosen, one its backend
    holds a window of (D38 *The UI (I-12d2)*; another terminal's record offers "Detach (opened
    in <terminal>)" instead). With iTerm2 it is `detach(session:on:)` (D16: the 10 s tab age,
    the identity re-check, `detach-client`, never a closed tab); the row then says "Detached
    from this Mac — the session keeps running", the record goes and the host is refreshed.
  - **Detach other clients** (Phase I-11b; D37 has the rules): the context menu's "Detach
    other clients…" after Detach, shown only for a live row this Mac's iTerm2 shows whose
    listing has more clients than this Mac's attachments of it
    (`SessionRow.offersDetachOtherClients`), disabled while another action of the row is
    pending. Its confirmation is drawn in the popover like Move here's
    (`PopoverPanel.detachOtherClients`, `DetachOtherClientsPanelView`), with the same keys;
    "Detach other clients" or Return calls `confirmDetachOtherClients()`, the only caller of
    `detachOtherClients(of:confirmation:)`. The row shows "Detaching other clients…", then
    the result or its `SessionProblem`, and the host is refreshed.
  - **New session:** a form (in its own window since D34) with the host (enabled hosts, This
    Mac first), the name (checked
    inline with `Validation.sessionName`; an empty name is reported once Create was pressed) and
    an optional directory (`Validation.workingDirectory`). Create runs `createAndAttach(_:)`
    with `AppEnvironment.newSessionCommand` (empty, the user's shell; `sleep` in the
    self-tests). As soon as the session is created (`createAndAttach(_:onCreated:)` reports
    it before its attach publishes anything), the window closes, the host is refreshed and the
    attach becomes that session's pending action, like an Open: its row shows "Opening…",
    "Waiting for iTerm2…", "Still connecting — check the iTerm2 tab" with "Show tab", then the
    result; clicks on it are ignored meanwhile, quitting cancels it, and another New session
    can start. A collision offers "Open existing", which never trusts the popover's list (the
    listed session may have been renamed and another given its name, which is why tmux refused
    it): the coordinator lists the host afresh (`currentSession(named:on:)`, read-only) and the
    session with exactly that name there is opened (its attach revalidates it once more); when
    none has the name any more the window says it ended or was renamed and opens nothing (the
    host is refreshed), and a host that cannot be listed says so, opening nothing either. Any
    other creation failure stays in the window. The Move here confirmation is drawn inside the
    popover, not as a sheet or alert, so it stays in the menu bar window and renders in the
    fixtures; while it shows, Return confirms it, Esc closes it, and the arrows, ⌘F and ⌘N do
    nothing. New session's keys and endings are D34's (its Esc also cancels an "Open
    existing" lookup).
  - **Quit:** `shutdown()` cancels the actions in progress (opens, moves, detaches, "Detach
    other clients…" calls, New session creations and attaches, "Open existing" lookups, "Show tab"; an attach withdraws its
    request, a detach waiting for its tab's age sends nothing), stops everything else at the
    same time without waiting for them, waits for them at most 12 s and reports those still
    running (D22), and detaches nothing.
  - **Self-tests:** `muxFinder --selftest attach-local|new-session-local [--selftest-keep]`
    runs `SelfTestAppDelegate`: a plain `NSApplication` (accessory) with no window, menu bar
    item, popover, onboarding or Settings. Unusable arguments exit 2 before anything starts; a
    set `TMUX_TMPDIR` (the launch tab's tmux would use another server) or a missing helper exit
    2 before iTerm2 is contacted. `SelfTestDriver` drives the real `AppModel` over an in-memory
    This Mac (`HostStoreLoadResult.inMemory`: no `hosts.json` is read or written) and an
    in-memory directory list (`InMemoryDirectoryStore`: no `directories.json`, D31), an engine
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
    `AttachFixtures.all` (16 states: progress and results, every failure in six cards, both
    check-failure cards with a focus that did not bring its tab forward, Move here, two detach
    cards, Detach other clients' two confirmations and three result cards (D37, Phase I-11b),
    the banners; the New session form's states, empty, with an invalid name, creating,
    after a collision, failed, a folder dragged over Directory and D31's list states, are
    `AttachFixtures.newSessionStates`, shown by the New session window's gallery, D34) and
    the context menu of a session open here (and attached elsewhere too, so it lists "Detach
    other clients…") and of one attached elsewhere; screenshots
    `docs/screenshots/attach-states-{light,dark}.png`.

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
      byte (tested through `HostStore` in a private folder). With a plain terminal chosen the
      parent field says "Used only with iTerm2." and the switch's note speaks of the terminal's
      persistent work command (D38 *The UI (I-12d1)*).
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
      button while an operation runs. With a plain terminal chosen the tab shows each saved
      host's persistent work command for that terminal instead, the iTerm2 part collapsed to
      one line with Remove while muxFinder's file is installed and Install not offered (D38
      *The UI (I-12d1)*).
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
      the next launch handles a file left over). Only while iTerm2 is the chosen terminal
      (D38 *Onto the seam (I-12c3a)*): otherwise only the status is read.
    - **At launch:** only the menu bar app in normal mode (`AppLaunchOptions
      .rewritesProfilesAtLaunch`, passed to `AppEnvironment.production`; never with
      `--preview-fixtures`, `--selftest`, `--report-login-item-status`,
      `--report-menu-bar-item` or unusable arguments, and the self-tests' and tests'
      environments leave it off), only for a list loaded as `saved`, and only while iTerm2 is
      the chosen terminal (D38 *Onto the seam (I-12c3a)*: with a plain or unavailable choice
      `muxFinder.json` is left as it is, neither written nor removed, and the hosts' profile
      settings stay in `hosts.json`; when iTerm2 becomes the choice again while the app runs,
      the same rewrite runs for the saved list): `stale` updates the
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
  `Sources/MuxFinderUI/Views/MenuBarIcon.swift`, `scripts/build-app.sh`,
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
    `Bundle.main.image(forResource:)` and marked as a template; muxFinder's status item button
    (D30) shows it alone (`MenuBarIcon.statusItemImage(in:)`), with "muxFinder" as its
    accessibility label and the image's description. An unbundled run (`swift run`) has no
    such file and shows the SF Symbol `terminal`, a template too.
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
  in `Launch/LaunchHelper.swift` and `Launch/TerminalStatusRequest.swift`, the `e2e-bury`
  harness (the spike's, run through the coordinator since Phase 13c) in
  `Sources/muxfinder-probe/E2EBury*.swift`, its judgements of steps 7 and 11 in
  `Attach/LaunchTabChecks.swift` (unit-tested; the probe has no test target); the
  coordinator's part, built in Phase 13b, in
  `Attach/AttachCoordinatorBurial.swift`, with `LaunchTabBurial` in `Attach/AttachModels.swift`
  and `BuriedTabTimer` in `Attach/AttachSeams.swift`).
  - **The bury** (the coordinator's step 10): the coordinator buries a launch tab it opened
    with `buryLaunchTab(sessionID:ifOwnsTmuxConnection:)` (bound like every command, D15),
    once per launch (coalesced callers share it), for `attach`, `createAndAttach` and
    `moveHere`, only after the attach is confirmed and step 9 returned `.activated(tabID:)`
    (S6: a tmux window shows). Never after `.noTab` or a failed activation, for a failed or
    unconfirmed attach, a focus, or a tab it did not open. A failed bury is not fatal and never
    retried (D13). The outcome is `AttachResult.burial` (`LaunchTabBurial`; `nil` unless
    confirmed) and part of the attach's diagnostics record (no ids): `buried`, `skipped(noTab
    | activationFailed | turnedOff)`, `failed(error)` (not sent, `tmuxConnectionNotOwned`
    included, or answered with an error), `uncertain` (sent, no answer: a timeout, a lost
    connection) or `restoredAfterEnd`; `timings.buried` says when the bury and its check
    ended. The bury and its check run in a task of their own, so cancelling the attach cannot
    cut them short. `Configuration.buriesLaunchTabs` (on by default) is on everywhere, in the
    app, the probe, the self-tests and `e2e-bury` alike (since Phase 13c); no caller turns it
    off, and the switch remains (off, the outcome is `skipped(turnedOff)`). A buried tab still
    owns its connection, so the bound identity check and `detach-client` work as before.
    muxFinder never reads iTerm2's
    preferences: with "Automatically bury the tmux client session after connecting" on, iTerm2
    has buried the tab already (the bury answers `OK`, S2) and restores it itself when tmux
    ends (S5). Decisions read `ListSessions`' `buried_sessions`, never `GetProperty` `buried`
    (it answers `1`/`0`).
  - **The race, closed by order:** the helper writes its result before its first restore.
    After the bury's answer (or its timeout), the coordinator peeks at the result
    (`LaunchRequestStore.peekResult`, without taking it, so `detach` still does) and, with no
    result, lists the connections for the owner. A detach can take the result while the bury
    or this check still awaits iTerm2; no peek can see it then, so the detach hands it to the
    check (`buriesInFlight`), and it counts like a peeked one. When a result exists or the tab
    no longer owns the connection, the coordinator sends `setBuried(false)` (idempotent;
    `restoredAfterEnd`, the tab not watched). A bury iTerm2 handled after the helper's first
    restore was answered after the result existed, so it is undone; one handled before is
    undone by that restore; one during the hold by the helper's last restore (seen in the
    spike, (c)). A `buried` or `uncertain` tab is watched (below), and so is one whose
    restore here failed, with what the check saw: the result (peeked or handed over), or that
    the tab no longer owns its connection. So the watch acts on it as soon as it is due and
    never waits, buried, for a result a detach already took.
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
    it buried (launch id, gateway session id and connection id, the latest 64, like its
    launches; memory only). While that list is not empty, a file-only peek at their results
    runs every 2 s (`BuriedTabTimer`: `.system`, real time, in the app, the probe and the
    self-tests; `.clock` for tests that tick it by hand; `.off`) and at the start of every
    attach (also a move here or the attach of a new session) and detach; a result a detach
    took is handed over, since no peek can see it any more. iTerm2 is contacted only once a
    result has appeared or a listing showed the tab no longer owning its connection (below),
    one recovery at a time, one attempt per tab (D13), each recorded in diagnostics without
    ids. After a helper failure: `ListSessions`, `setBuried(false)` if
    the tab is in `buried_sessions`, and the tab stays visible for its explanation. After a
    clean end: nothing until `Configuration.buriedTabCloseDelay` (15 s) after the result was
    first seen, then `ListSessions`; a tab no longer listed closed by itself; one still listed
    (a dead tab, S4: the helper's restores never reached iTerm2) gets `setBuried(false)` if
    buried, then a forced `Close` by its own session id (it works on a buried session too,
    (d)), its status checked and its absence awaited for 5 s. Deviation from the design, which
    restored and checked "still listed" as soon as the result appeared: the helper lives up to
    about 12 s after a clean result (its 2 s restore exchange, the rest of its 10 s minimum
    lifetime, its last 2 s exchange), so a check right away would close a live tab in the
    middle of its own restore; the delay waits that out, and a clean tab's restore waits with
    it (its helper restores it meanwhile). A result the sweep removed (older than D14's
    120 s) leaves a tab that owns no connection: an attachment check (the existing-attachment
    check of an attach or move here, or `detach(session:on:)`'s index) whose listing left no
    connection out shows it, and the tab is restored if buried and left visible. Such a check
    judges only the tabs watched before it started: a snapshot lists the connections before
    it awaits their identity answers, so a tab an attach running alongside buried meanwhile
    cannot be in its listing and is left as it is. A tab whose check right after the bury saw
    the connection gone, but whose restore there failed, is handled the same way. "Show tab"
    restoring a tab ends its watch.
  - **Persistence (item 5's decision): memory only.** The helper alone brought the tab back
    after every abnormal end the spike tried (the attach child killed locally, the local ssh
    killed for Saturno), with iTerm2's default setting emulated, before its explanation, so a
    restart of muxFinder loses no recovery the helper does not make itself. Phase 13c's runs,
    with the setting really off, agree: on Saturno the helper's restores brought the tab back
    2.1 s after the kill; locally it was back after 0.9 s, possibly through the coordinator's
    recovery, which acts at once on a failure result, before the helper's second restore.
    Left to the running app's recovery, and stranded while muxFinder is not running (a buried
    session under Session > Buried Sessions; README, Phase 13c): a helper that died without its
    restores, iTerm2's "Tolerate unrecognized commands from server" advanced setting on, or a
    tmux command still pending at the abnormal end (both keep iTerm2 in tmux mode).
  - **Show tab** (D25): restores the tab before activating it (a refused restore ends it with
    nothing activated), never alongside a bury of that same tab: a show and a bury of one tab
    run one after the other, each in a task of its own, in the order they were asked for.
  - **Fakes and harness (Phase 13b, hermetic):** `FakeITerm2Integration`, `SimulatedITerm2`
    and `SimulatedProfileITerm2` keep buried state (a successful bury moves the session out of
    its tab, a window left without tabs going too, into `buried_sessions`; a restore brings a
    buried one back in a new window, S8; both idempotent, S2; the scripted fake places only
    sessions its listing names, and drops a session a `Close` answered `OK` for);
    `InstrumentedITerm2` can hold a bury's answer and run a hook once iTerm2 handled it, and
    hold the answers of connection listings it already took, so the tests drive every
    interleaving (`Tests/MuxFinderCoreTests/LaunchTabBurialTests.swift`).
    `e2e-local` and `e2e-remote` require, after every confirmed attach (attach, reattach,
    concurrent attaches, new session, move here), `burial` `buried` and the launch tab in
    `buried_sessions` and in no tab within 5 s; after every detach, the tab gone from both
    tabs and `buried_sessions` by itself within 10 s, before any cleanup; and cleanup closes
    each leftover launch tab, forced, checking the answer and its absence, restoring a
    still-listed buried one and closing it again. A stranded tab fails the step, and so does
    one that left only through the coordinator: the 10 s wait and the coordinator's recovery
    of a dead tab (15 s after its result was first seen, possibly by the timer while the
    detach still ran) can overlap, so "by itself" is checked, not timed. The run's
    coordinators talk to iTerm2 through `RecordingITerm2Integration` (in `MuxFinderCore`,
    unit-tested), which records each bury, restore and `Close` before sending it; once the
    tab is seen gone, any recorded restore or `Close` that may have touched it fails the step.
    The step counts are unchanged. `muxfinder-probe attach`'s JSON carries `burial` and
    `timingsMs.buried`. Phase 13c ran them for real, with `e2e-bury` through the coordinator
    (*Verified facts*, Phase 13c real runs).
- **D30 — muxFinder's own menu bar item and popover panel** (decided in Phase I-1b,
  2026-10-24, from the Phase I-1a diagnosis, *Verified facts*; the AppKit wiring in
  `Sources/MuxFinderUI/Views/MenuBarPopover.swift`, the decisions in
  `Model/PopoverController.swift` and `Model/PopoverAnchoring.swift` over I-1a's
  `Model/PopoverPlacement.swift`; tests `Tests/MuxFinderUITests/PopoverControllerTests.swift`
  over fakes and `PopoverAnchoringTests.swift`).
  - **The choice** (decided: replace SwiftUI's `MenuBarExtra(.window)` with an `NSStatusItem`
    and a borderless `NSPanel` muxFinder owns). `MenuBarExtra` gives no hook for its window's
    position, and its status item button takes no action (no action, target, menu or gesture
    recognizer; it takes the click outside them), so muxFinder could neither correct where the
    window opens nor open it in process without private API. The app's main menu (the Edit
    commands the text fields use, Quit, Close) is muxFinder's own on a plain `NSApplication`,
    with no SwiftUI scene (D33); reopening the running app opens nothing.
  - **Status item** (`StatusItemButton`): variable length, D28's template image
    (`MenuBarIcon.statusItemImage(in:)`), "muxFinder" as its accessibility label, behavior
    `removalAllowed` and `terminationOnRemoval` (6, as the `MenuBarExtra` item's: ⌘-dragging
    it out quits the app), AppKit's default autosave name; its action is sent on the left or
    right mouse press and is `PopoverController.buttonPressed()`; highlighted while open.
  - **Panel** (`PopoverPanelWindow`): borderless and non-activating, so it becomes key without
    activating the app (the frontmost app and its Space stay; the keys go to the search
    field); level `.popUpMenu`; collection behavior `canJoinAllSpaces`, `fullScreenAuxiliary`,
    `transient`, `ignoresCycle` (it opens on the active Space and over full-screen apps); not
    movable, never released, not hidden when the app deactivates (the controller decides), no
    animation; transparent with a shadow, its content clipped to 12 pt continuous corners with
    a one-pixel border in the separator color. It hosts `PopoverPanelRoot` (the live
    `PopoverView` at its natural size whatever the panel's frame, as under `fixedSize()`, but
    no taller than its height limit, `PopoverHeightLimit`; see *Size*) in an `NSHostingView`
    whose `sizingOptions` are `intrinsicContentSize` only, so the view never resizes the
    window itself. One panel, made at launch and reused. Its key view loop is recalculated as
    views come and go (`autorecalculatesKeyViewLoop`, Phase I-6): when the hosted view swapped
    whole forms (New session replacing the list, before D34), AppKit's default loop, computed
    at the panel's first showing, left the form's fields leading nowhere, so Tab stayed in
    Name (*Verified facts*, Phase I-6; the session switcher's panel is the same class, D32,
    and the New session window keeps the setting, D34). Its
    local key monitor (`PanelKeyTrackingView`, also the New session window's, D34) routes each
    key press through a pure decision,
    `PanelKeyRoute.decide` (Phase I-8), over the key, the panel's first responder at that
    moment, menu tracking, marked text and the directory list's state: while a menu of the app
    tracks (`MenuTrackingObserver`, from `NSMenu.didBeginTrackingNotification` to
    `didEndTrackingNotification`; an end whose begin was never seen forgets every menu) or an
    input method composes text, every key goes on untouched; with an `NSPopUpButton` focused
    (New session's Host picker, in the New session window since D34), ↑, ↓ and ⌥↓ go on to it
    as AppKit handles them, while Return and Esc keep the window's meaning (D31); every other
    key goes to the handler as before (*Verified facts*, Phase I-8). Phase
    14's look, width and sizing are unchanged when the content fits; no arrow.
  - **The anchor rule** (`PopoverAnchoring.decide`): when the action comes from a mouse event
    (the current event is a mouse press or release at most 1 s old), the press's location is
    `NSEvent.mouseLocation`; if it is on the button (within the button's column, in the menu
    bar of the button's display), the anchor is the button's rectangle in screen coordinates
    (`convertToScreen` of its bounds in its window), else the press itself. With no mouse
    event (`performClick(_:)`, VoiceOver) the anchor is the button's rectangle. The rectangle
    counts only when usable: its middle on a display (no nearest-display fallback) at or above
    that display's menu bar bottom (1 pt tolerance), else the pointer is the anchor. The
    replica status-bar windows' frames are never read, and their placeholders (at {0, −30} and
    at the second display's right edge) would fail the usability test anyway. The display is
    the anchor's (`PopoverPlacement.screenIndex(for:in:)`), the frame
    `PopoverPlacement.frame(contentSize:anchor:screen:)`: top at that display's menu bar
    bottom, middle on the anchor, clamped 8 pt inside its visible frame.
  - **Toggle, move and close** (`PopoverPressRules`, `PopoverController`): a press while open
    closes it, or moves it to the press's display when that is another one (only one panel);
    Esc (the panel's `close()`, routed to the controller), a mouse press another process
    received (a global mouse-down monitor, only while open; mouse monitors need no
    permission), another app becoming active, the panel resigning key, a display change and
    the session switcher opening (`CloseReason.switcherOpened`, D32) close it, and so does the
    New session window opening from it (`CloseReason.newSessionOpened`, D34). The classic
    toggle bug (one press seen both as the button's action and as an
    outside close) is handled in either order: an outside close made while a mouse button is
    held is remembered with the press's count, the pointer and the time, and the button's
    action for the same press leaves the popover closed, or opens it on the press's display if
    it was on another one; an outside close for the press the action just handled is ignored.
    The same press means the same count, and within 0.5 s and 40 pt: the count is the window
    server's number of hardware mouse-button presses (`CGEventSource.counterForEventType` on
    the HID system state, left, right and other mouse-down summed; a public, read-only query,
    which a shell on this Mac reads without any permission; the app's own reading is exercised
    by checklist 16's real clicks). A press raises it before any of its effects reach the app and its release
    does not, so both effects of one press read the same count, while a separate press, however
    quick and close (a neighboring menu bar item, then muxFinder's icon within 0.5 s and
    40 pt), reads a higher one and acts on its own. Posted events are not counted, so a relayed
    copy of a press is never a second press. The interval and distance still bound a match,
    so a count that never changed would leave the rules matching by them alone.
  - **Size:** before it reads the content's size (opening, moving), the controller limits
    the content to the anchor's display's room below the menu bar
    (`PopoverPlacement.availableHeight(on:)`: the menu bar's bottom down to 8 pt above the
    visible frame's bottom) through `PopoverPanelSurface.maximumContentHeight`, which sets
    `PopoverPanelRoot.maximumHeight`. Content that fits is laid out at its natural size, as
    before; taller content is offered the limit (`PopoverHeightLimit`), and the host list,
    the only part that gives up height (down to nothing, with a lower layout priority), shrinks
    and scrolls while the search field, banners, notices and footer keep theirs, so the panel
    never cuts the footer off (`PopoverPlacement`'s own height clamp only guards). The root
    view's geometry and the hosting view's intrinsic size each report a change of that size
    (coalesced to one per turn of the main loop); while open the controller places the panel
    again from the same anchor and display, so its top stays at the menu bar's bottom.
  - **Visibility:** `popoverVisibilityChanged` comes from the controller only: visible while
    open and not fully occluded (a locked screen, a sleeping display), on changes only, and
    reported before the panel shows, so attachment checks run only while the popover (or the
    session switcher, combined in the model, D32) shows and are cancelled when the last one
    closes (D20, D22). The search field is asked for the focus at each opening.
  - **Diagnostic:** `--report-popover-placement` clicks muxFinder's own button with
    `performClick(_:)`, so the action is the controller's and the anchor the button's
    rectangle; it prints the controller's placement and the after-fix check
    (`PopoverPlacementCheck`: middle within 2 pt of the anchor's unless clamped, top within
    1 pt of the menu bar's bottom). Phase I-1b's two runs measured it: exit 0, both offsets 0
    (`docs/TESTING.md`, *Phase I-1b*).
  - **Considered:** moving the `MenuBarExtra` window after it opens (no public hook; finding
    SwiftUI's window by class and fighting its own placement on every opening); `NSPopover`
    shown from the button (it positions from the button's window, so a press on the other
    display's icon would open on the main one, and it draws an arrow); activating the app on
    opening (the frontmost app would lose its menu bar, and closing would have to hand the
    activation back).

- **D31 — New session directories and session start folders** (decided in Phase I-2a,
  2026-10-24, from `autoclaude/processed/20-new-session-directory-picker.md`; code in
  `Sources/MuxFinderCore/Config/DirectoryLists.swift` and `DirectoryStore.swift`,
  `Tmux/ProbeScript.swift`, `ProbeReport.swift`, `TmuxModels.swift`,
  `Sources/MuxFinderUI/Model/AppModelSessions.swift` (`recordRecentDirectory(_:for:)`) and
  `AppEnvironment.swift`; tests `Tests/MuxFinderCoreTests/DirectoryStoreTests.swift`,
  `ProbeSessionPathTests.swift`, `Tests/MuxFinderUITests/DirectoryRecordingTests.swift`;
  extended in Phase I-2b with the picker, its keys and the Settings section:
  `Sources/MuxFinderUI/Model/DirectoryPicker.swift`, `AppModelDirectories.swift`,
  `SettingsModelDirectories.swift`, `PopoverKey.swift`, `Views/DirectoryPickerViews.swift`,
  `Views/Settings/DirectoriesSettingsView.swift`; tests `DirectoryPickerTests.swift`,
  `SettingsDirectoriesTests.swift`; extended in Phase I-7 with the field's filter: the same
  files and `AppEnvironment.swift` (`homeDirectory`, `announce`); tests
  `DirectoryFilterTests.swift`; extended in Phase I-10b with the folders section, D36:
  `Sources/MuxFinderUI/Model/FolderSearchSection.swift`, `AppModelFolderSearch.swift`, the same
  picker files; tests `FolderSearchSectionTests.swift`, `FolderSearchModelTests.swift`).
  - **File:** `directories.json` in muxFinder's folder (`DirectoryStore`; the path is
    injectable), schema 1: `{"schemaVersion": 1, "saved": [ … ], "recent": {"<host id>":
    [ … ]}}`, pretty-printed with sorted keys and a final newline, at most 1 MiB, unknown keys
    ignored. `saved` is one list shared by every host (a `~/…` entry resolves on each host,
    D18), `recent` each host's, newest first. It is kept apart from `hosts.json`: recents
    change at every creation, and usage state must never race with, refuse or create backups
    of the host list (D19 `save(_:expecting:)`). The store never reads or writes `hosts.json`
    or its backups.
  - **Entries (`DirectoryLists`):** not empty (the home folder is never kept), through
    `Validation.workingDirectory`, at most 4,096 bytes of UTF-8 (`maximumEntryLength`, also the
    start folder limit below). At most 50 saved (adding more is refused, `tooManySaved`) and 8
    recent per host (a ninth drops the oldest; recording one again moves it to the front).
    Duplicates collapse by exact string, compared byte for byte (no Unicode normalization),
    keeping the first place; `~/x` and `/Users/…/x` stay two entries (the app cannot know a
    remote home folder). **Byte identity** holds everywhere a directory is compared: two lists
    are equal (`DirectoryLists ==`) only byte for byte (`String`'s `==` would take two spellings
    of an accented name for one, and an `@Observable` model skips telling its views about a
    value equal to the one it holds), and so are New session's rows and the merge below
    (Phase I-2b review). Changes (`DirectoryListChange`): add, remove, move, replace and merge
    saved (`mergeSaved`, Settings' Save below), record a host's recent, clear a host's recents;
    a refused one (`DirectoryListError`) changes nothing.
  - **Loading** never writes, not even the folder (`PrivateStorage` `inspect`), and trusts the
    file under D14's rules for files read (`O_NOFOLLOW|O_NONBLOCK`, a regular file of the
    user's, no group or other bits, no ACL, at most 1 MiB): `saved`, `notSavedYet` (empty) or
    `invalid(problem)` (`unsafe(reason)`, `notJSON`, `malformed`, `newerSchemaVersion`,
    `unsupportedSchemaVersion`; empty lists, the file left as it is). In a usable file, an
    entry that is not a string or breaks a rule, a host key that is not a UUID (with its
    entries), a host value that is not an array and entries past the caps are left out and
    counted (`droppedEntryCount`); a duplicate loses nothing and is not counted. `notice` is
    `fileNotUsed(problem)` or `entriesDropped(n)`: kinds and counts, never a directory.
  - **Changing** (`apply(_:knownHosts:)`): read the file as a load does, apply the change to
    what it holds, forget the recents of hosts not in `knownHosts` (`nil` forgets none), then
    write unless the result is what the file holds already (or there is no file and the lists
    are empty). **A file that cannot be used refuses every change** (record, clear, saved add,
    remove, move, replace and merge, prune) with `fileNotUsable(problem)`: its contents and
    metadata stay as they are and nothing is written, so a file with unsafe permissions, one a
    newer muxFinder wrote (after a downgrade) or one that is not JSON is never replaced; the
    user fixes it or moves it away (Phase I-2a review). A file with entries left out is usable
    and is replaced (and kept as a backup, below).
  - **Serialization across processes** (Phase I-2a review): the first read, without the lock,
    ends a refused or unusable-file change and one that writes nothing, so those never create
    the folder or the lock file. Any other change takes an exclusive `flock` on
    `directories.lock` in the store's folder (`PrivateStorage.acquireLock(named:in:owner:wait:)`,
    the helper `PersistentProfileInstaller` now forwards to for `profiles.lock`, D26; created
    0600, never removed), waited for at most 2 s (`busy`; a lock file that is a link, not a
    regular file or another user's is `lockUnavailable`), and holding it reads the file again,
    refuses it if it became unusable, applies the change and publishes. So two store instances
    or two muxFinder processes (an installed app and a development build) never lose each
    other's changes; the actor keeps one store's own changes in order. Writing follows D19:
    the folder created (0700) or tightened and stripped of ACLs; a symbolic link or other
    non-regular file that took the name since the read, or one over 16 MiB, refuses the write;
    a temporary file (no ACL, 0600, flushed) published with one `renameatx_np` (`RENAME_SWAP`
    over a file, `RENAME_EXCL` where none is, at most 8 renames). The displaced file is deleted
    only when it holds exactly the bytes this store last read (under the lock) as fully usable
    (nothing left out) or wrote; anything else (one with entries left out, one a program
    outside muxFinder put there during the write) is kept as `directories.backup-<UTC
    yyyyMMddTHHmmssZ>[-n].json`. The publication and backup code is the store's own; the
    stateless helpers it shares with `HostStore` (`makePrivate`, `backupName`,
    `backupTimestamp`) moved to `PrivateStorage`, `HostStore` forwarding to them unchanged.
  - **Session start folders in discovery:** the probe's `list-sessions` format writes, right
    after each session line, `path <nonce> <session id> <#{session_path}> <nonce>` (the format
    holds a line break, so sessions and folders come from one listing). tmux stores a `-c`
    folder as given and prints it raw through `tmux -u`, with line breaks, tabs, escape
    sequences, C1 controls and invalid UTF-8 (*Verified facts*, Phase I-2a), so a path cannot be
    framed by its line, and no tmux 3.x format modifier escapes control characters (`q:` only
    escapes shell characters; `n:` gives the byte length, which would frame it but tie the
    parser to that modifier). The record ends at the first tab, run nonce and line feed: a path
    cannot predict the nonce, so it can neither end its record early nor forge a session,
    client, status, end or path line, and everything before the end mark is the path. tmux
    bounds the path itself (Phase I-2a review): the format prints
    `#{?#{e|>|:#{n:session_path},4096},,#{session_path}}`, so a path over 4,096 bytes (`n:`
    counts bytes, control characters and invalid UTF-8 included) comes out as nothing, which
    the parser drops and counts like an empty one, and is never cut to a length the parser
    would keep; the path is the false branch, so a tmux that cannot evaluate the comparison
    prints it whole, as before (only tmux 3.8 is tested). Discovery keeps stdout up to the
    largest report the parser accepts (`ProbeReportParser.maximumReportSize`, about 12.1 MiB:
    every line at the 4,096-byte cap, 1,000 sessions and 1,000 clients, a path record of at
    most `maximumPathRecordLength`, 4,156 bytes, after each session, and, since Phase I-12c2's
    review fix, a `tty` record of at most `maximumTerminalRecordLength`, 324 bytes, after each
    client), so 1,000 sessions in
    4,096-byte folders still report; more is "too large"; stderr keeps the runner's 1 MiB cap
    (`ProcessRequest.errorOutputLimit`). The parser requires the record to follow its own
    session's line (same id, at most one, else `malformed`; no end mark, `incomplete`), applies
    no line-length cap inside it, and keeps the path only when it is not empty, at most 4,096
    bytes, valid UTF-8, free of control characters (C0, DEL, C1) and through
    `Validation.workingDirectory`; otherwise it drops and counts it
    (`ProbeReport.droppedStartDirectoryCount`) and keeps the session. A report without `path`
    records (every earlier capture, a fake) parses as before; the format version stays 1, since
    the app always sends the script with its parser. `DiscoveredSession.startDirectory`
    carries the folder through `HostSnapshot` (a stale snapshot keeps its last success's
    sessions, folders included); it is display data only and never reaches a command by
    itself. `discover` prints it per session with `startDirectoriesDropped`, `refresh --once`
    per session.
  - **Recording (`AppModel.recordRecentDirectory(_:for:)`):** called from `sessionCreated`,
    New session's `createAndAttach` `onCreated` path, so only a creation that made the session
    records, before its attach, and an attach that fails afterwards changes nothing; the
    directory is the request's `workingDirectory` as checked; an empty field (`nil`) records
    nothing; a collision, a failed creation and every `mayHaveCreated` failure never reach it.
    The write runs in the background, one recording after another; a failure (or a displaced
    file not kept) is logged in `os.Logger` and the operation log by code only (`recent
    directory not recorded: <code>`, for example `fileNotUsable.unsafe.permissionsTooOpen` or
    `busy`), never the directory, and never blocks or fails the creation. The same write forgets the recents of hosts no longer in the host list
    (`knownHostIDs`: the list's ids when it loaded as `saved` at launch or was saved since; an
    unsaved list, onboarding defaults or an unusable file, forgets nothing). Quitting waits for
    a recording in progress for at most the session-action budget (D22).
  - **Injection:** `AppEnvironment.directories` is `DirectoryStore()` (the real file) in
    `production`, an `InMemoryDirectoryStore` in the self-tests (`SelfTestDriver
    .makeEnvironment()`, so `--selftest new-session-local` never reads or writes
    `directories.json`), and `nil` in `placementDiagnostic()` and the tests of other parts;
    preview fixtures (`AppModel(fixture:)`) have no environment, so no preview mode reaches a
    store (pinned by `DirectoryRecordingTests.eachModeGetsItsOwnStore`).
  - **The picker (Phase I-2b):** the Directory field stays a text field (typing, pasting,
    `~/…`), with a pull-down button at its trailing edge that opens a list **drawn inside the
    form** under the field (`DirectoryListView`; in the popover's and the switcher's panels
    until D34, in the New session window since), whose height follows it; the field is also
    the list's search,
    combo-box style (Phase I-7, below), with no separate search field. Decided against a SwiftUI `Menu` or
    an `NSMenu`: a menu runs its own event tracking loop, so its ↑/↓, Return and Esc would
    never reach the key monitor (then the popover's `PopoverWindowTrackingView`, now the New
    session window's, D34) or the model's key handler and could not be unit-tested through
    them; SwiftUI cannot open a `Menu` from a key, so ⌥↓
    in the text field would need an `NSMenu` popped up by hand at a computed position from a
    non-activating panel (D30) whose closing rules (resigning key closes the popover) a menu
    might trip, which was not worth verifying; and `--preview-snapshot` draws the panel's
    view, so a menu (another window) would never appear in the galleries. The content is a
    pure value, `DirectoryPickerContent`, for the draft's host: "Recent" (that host's recents,
    newest first), "Saved" (the shared list, in the user's order) and "Sessions on <host>"
    (the distinct start folders of the host's listed sessions, stale ones included, that pass
    `DirectoryLists.check`, distinct by exact string, sorted with `localizedStandardCompare`
    and byte order for ties, at most 10), each only when not empty; a folder may show in two
    sections. With all three empty the list (and the button's help and accessibility value)
    says "Nothing to pick yet", whatever the field holds. **The filter (Phase I-7):** with the
    field's text trimmed of surrounding spaces and line breaks (`query`) empty, nothing is
    filtered; otherwise each section keeps, in its order, only the entries that match (the
    session folders' cap applies first), and a section left empty is hidden. An entry matches
    when it equals the field byte for byte (picking it would change nothing, but hiding it
    would confuse) or when one of its spellings contains the query, ignoring case and
    diacritics (`PopoverContent.matches(_:query:)`, the popover's search rule). The query is
    matched as typed, never expanded; **the `~` rule:** on This Mac, whose home folder is known
    (`AppEnvironment.homeDirectory`, `NSHomeDirectory()` in the app, `nil` in tests and the
    self-tests; fixtures `/Users/example`), each entry is matched in three spellings: as stored,
    with a leading home folder written `~` (`<home>/x` as `~/x`, compared byte for byte and
    ending at a slash) and with a leading `~` or `~/` spelled out as the home folder; so `~/proj`
    finds a session folder `/Users/<me>/projects` and `/Users/<me>/pr` a saved `~/projects`. On
    an SSH host, whose home is unknown (the saved list is shared), each entry is matched only as
    stored; `~user` forms are never expanded. When the filter hides every entry the list says
    "No matching directories" above the actions (`noMatches`), distinct from "Nothing to pick
    yet". Its accessibility value is the match count (`matchSummary`: "3 matching
    directories", "No matching directories", unfiltered "8 directories"), and the field's
    accessibility hint says that typing filters the list. Below them, never filtered and with
    their rules unchanged: "Save this directory" (`addSaved` of the field as
    typed; off while the store takes no change, the field is empty or breaks the entry rules,
    the value is saved already byte for byte, or the list holds 50) and "Clear recent
    directories on <host>" (`clearRecents` of that host; off with no recent directory, shown or
    not, or while the store takes no change); an unusable file's or unreadable folder's notice shows
    at the top of the list (entries left out are Settings' notice only). Rows shorten long
    paths in the middle, with the full path as help and accessibility label; the highlighted
    row has the popover's selection look and the pointer moves the same highlight. A row's
    identity (equality, hashing, the view's row identity, the keyboard's position) is its
    section and the directory's UTF-8 bytes (`DirectoryPickerContent.Item`), and sections
    compare byte for byte, so two spellings of one accented name are two rows the keys pass
    through in turn (Phase I-2b review). Picking a
    directory only fills the field and closes the list (the model's fill is no edit,
    `fillDirectoryField(_:)`, so it never reopens the list); the draft then checks it like typed
    text (`directoryIssue`, `request(hosts:command:)`, `Validation.workingDirectory`) before
    any `NewSessionRequest` (D3, D18). Only a row the list shows (after the filter) can be
    picked. Changing the host re-filters the list with the new host's entries and keeps the
    field; it is no edit, so it neither opens nor closes the list; a highlight the new list
    lacks is dropped. The list closes with the window, on a creation and at each fresh opening
    of New session (an opening while the window shows leaves it, D34).
  - **Keys (Phase I-2b):** `PopoverKey.openList` is ⌥↓ (⌥ alone, the arrows' own flags
    ignored). In New session it opens the list on its first row; while the list is open
    (`handleDirectoryListKey(_:)`), ↑/↓ and ⌥↓ move the highlight through the rows shown (the
    filter's matches, then the actions that are on) and stop at the ends (the session rows'
    selection never moves), Return picks the highlighted row (an action runs and the list
    stays open) or, with none, closes the list and creates (Return in the field still means
    Create). Any change to the field's text (byte for byte: typing, pasting, a pick) ends the
    list's navigation and drops the highlight (`AppModel`'s `newSessionDraft` observer,
    `directoryFieldChanged(from:)`), so Return then creates from what the field holds instead of
    picking a row highlighted before the edit; ↓ or the pointer highlights again (Phase I-2b
    review). **Typing opens and closes the list (Phase I-7):** the list remembers how it was
    opened (`DirectoryPickerState.opening`: `request` for the button, Space on it or ⌥↓;
    `typing`). A user edit of the field (`directoryFieldEdited(from:)`; not a pick, a host
    change or the draft's reset), while New session shows, is not busy and has a host, opens a
    closed list as `typing` when an entry matches or the folders section shows (Phase I-10b,
    below), highlighting nothing (so Return creates from the field; ↓ or ⌥↓ highlights the
    first row), and closes a `typing` list again when neither does or the trimmed text is
    empty (clearing the field shows the whole list but never opens it); a `request` list stays open, showing "No matching directories" and the
    actions. After such an edit VoiceOver hears the match count (`AppModel.announce`, from
    `AppEnvironment.announce`: an `NSAccessibility` announcement in the app, `nil` in tests,
    which record through the model): `matchSummary` when the edit opened the list or changed
    its rows (an edit that keeps the same rows says nothing again), "No matching directories"
    when it closed a `typing` list; nothing when the list stays closed or the field is cleared
    behind a closing list. Esc closes the list, keeping the field's text (the next edit may
    open it again), and leaves the window open (a second Esc closes it); ⌘N still does nothing,
    ⌘, opens Settings, and ⌘F and ⌘R go on to the focused view, as without the list (the
    window's keys, D34). Everywhere else ⌥↓ returns
    the new `PopoverKeyResult.ignored`, and the key goes on to the focused view as before
    (`PopoverKey` used to return `nil` for it). **Tab and ⇧Tab** (Phase I-6; decided: AppKit's
    own key view loop, which the window recalculates, D30, D34) move between Name and
    Directory, and with macOS's keyboard navigation on through the host picker, Name,
    Directory, the list's button (Space presses it like any button), Cancel and Create in
    reading order, wrapping inside the window, which holds only the form (no session list for
    Tab to reach). No `PopoverKey` maps Tab, so the key monitor never takes it and an input
    method composing text gets it first, as it gets every key. Not routed through the model (a
    Tab `PopoverKey` and an `@FocusState` field held by `AppModel`): the cause was the panels'
    stale loop, and once it is recalculated AppKit already gives the reading order, the
    keyboard navigation rule and the input method's precedence for every control, which a
    model-held focus would have had to copy. Tab with the directory list open moves on and
    leaves the list open: its rows are drawn by SwiftUI and are not key views, so Tab never
    walks into them, and the list's keys are the model's wherever the focus is in the form
    (Esc, or Space on the button, closes it), the Host picker aside (below). Every other key
    is unchanged. **The Host picker's keys (Phase I-8; decided by the orchestrator:
    AppKit's own pop-up button, a generic rule in the key monitor, D30):** with keyboard
    navigation on, ⇧Tab from Name reaches the picker (an `NSPopUpButton`); while it has the
    focus the key monitor (`PanelKeyRoute`) leaves ↑, ↓ and ⌥↓ to it, and Space is no panel
    key, so the keys AppKit gives a focused pop-up button open the host menu (Space; ↑ and ↓
    through `moveUp:`/`moveDown:`, which only `NSPopUpButton` answers; ⌥↓'s key binding
    messages it does not answer), and while that menu tracks every key is the menu's (↑/↓,
    Return, Space, Esc, type-to-select; Esc closes only the menu). Return with the menu closed
    still creates and Esc still closes the window (D34). **The directory list and Host
    focus:** the
    list keeps its keys wherever the focus is except on the pop-up button (I-6's rule that Tab
    moves on and leaves the list open stands); with the list open and the focus on Host,
    ↑/↓/⌥↓ go to the picker, the list stays open with its highlight unchanged (the model never
    sees those keys), and Return and Esc keep their list meaning (Return picks the highlighted
    row, else closes the list and creates; Esc closes the list first). A host picked from the
    menu, by keyboard, click or VoiceOver (VO-Space, the pop-up's own accessibility action;
    none added), comes through the picker's one binding (`$model.newSessionDraft.hostID`), so
    it acts as a click: the list re-filters for that host, Name and Directory keep their text,
    and the picker is disabled while the draft is busy. With keyboard navigation off the
    picker is not in the loop and nothing changes (the user's decision: Host is never forced
    in). No host menu was re-implemented in the model.
  - **The folders section (Phase I-10b, D36; the orchestrator's calls in *Phase I-10*):**
    "Folders on <host>" comes last, after Recent, Saved and Sessions, while folder search
    exists (normal mode only) and applies to the field's text: at least 2 characters, not only
    spaces, and no `/` (a path being typed is no folder name; such text sends no query and hides
    the section). It is a pure value too (`FolderSearchSection`, `DirectoryPickerContent
    .folders`), built from the window's channel's latest state and answer
    (`FolderSearchSnapshot`): "Searching…" until the channel's state is for the field's exact
    text on this host (so a keystroke shows it at once; the previous answer's folders on the
    host, in the same scope, whose names still contain the text stay listed under it, so the
    list does not empty at each key), then the folders found (at most 50, in Spotlight's order), "No folders
    found" ("No other folders found" when every one is in an earlier section), "Folder search
    isn't available on <host>" with the reason (no Spotlight, indexing off for the scope's
    disk, no home folder; nothing was sent), the channel's failure (an SSH problem after its
    one reopen, a timeout; it stands until the text or host changes and never holds up the
    form), or why the text cannot be searched. Rows are written `~/…` under the host's home
    folder as the script's header reports it (the home itself `~`; absolute elsewhere),
    shortened in the middle like the others, and a pick fills the field with exactly that (a
    pick, `fillDirectoryField(_:)`: the list closes and does not reopen, nothing is
    announced), so `~/…` resolves on the host (D18). Every path passes
    `DirectoryLists.check` (a typed Directory's checks) and holds no control character before
    it is offered; any other is dropped and only counted ("N folders found can't be offered"),
    never logged. A folder an earlier section shows, compared after the `~` rule byte for byte,
    shows only there. Notes: "Showing the first 50 folders found…" for a limited answer, and,
    for an SSH host only, "Desktop, Documents and Downloads on <host> can't be searched over
    SSH." naming the folders its header found unreadable (This Mac checks none, D36). While it
    shows, the section counts as something to show for the open rule above (whatever its
    status), and the list says neither "Nothing to pick yet" nor "No matching directories" in
    its place. **Keys and pointer** as in the other sections: the folders are entry rows
    (`SectionKind.folders`) after the others in `items`, then "Missing a folder?"
    (`Action.folderSearchHelp`, a row the keys reach; Return or a click shows or hides the
    explanation below the scrolling sections, the list staying open), then the actions.
    **The explanation** (`FolderSearchSection.missingFolderExplanation`, also in Settings ›
    Directories): results come from Spotlight and match names, not paths; dot folders and
    anything excluded in Spotlight's privacy settings never appear; the noise rule's folders;
    Home folder searches only the home folder; over SSH macOS may hide Desktop, Documents and
    Downloads unless the host allows full disk access for remote users; an apostrophe inside a
    word may find nothing; only 50 are listed. Its links: "Open muxFinder Settings" (Settings
    on its Directories tab) and, for This Mac, "Open Spotlight settings" (System Settings'
    Spotlight pane, `x-apple.systempreferences:com.apple.Spotlight-Settings.extension`, through
    `AppEnvironment.openURL`; never opened by a check). **VoiceOver:** the list's value adds
    the section's summary; "Searching…" is said once when a search starts from a settled (or
    hidden) section, never again while it searches, and the summary ("3 folders found", "No
    folders found", the reason or the problem) when it settles; an edit says the directory
    count (when Recent, Saved or Sessions show rows) and "Searching…" in one announcement. The
    channel itself is the window's (D34).
  - **Store use from New session (Phase I-2b):** every load and change goes through
    `AppEnvironment.directories` on one queue (`enqueueDirectoryOperation(_:)`; the recording
    above runs on it too, and quitting waits for it within the budget). The lists are read
    afresh at each fresh opening of New session (D34; reading never writes; a problem status
    that is new is
    logged as `directory list not usable: <code>`); each change's result becomes the lists
    shown, with the recents of hosts no longer in the host list forgotten in the same write.
    A refused save or clear changes nothing else, shows "muxFinder couldn't save this
    directory." (or "…couldn't clear the recent directories.") with the store's explanation in
    the list, makes the list read-only for `fileNotUsable`, and is logged as `directory list:
    <change kind> not done: <code>`, never a directory. A model without a store (tests of
    other parts) offers no change; fixtures show the actions as on and run nothing.
  - **Settings › Directories (Phase I-2b; folder search in Phase I-10b):** its own tab,
    between Persistent profiles and General, over `SettingsEnvironment.directories` (in the
    app the same `DirectoryStore` instance as `AppEnvironment.directories`). Since Phase I-10b
    it also holds "Folder search" ("Search folders in: Home folder / Whole disk", saved at once
    through `SettingsEnvironment.preferences`, `PreferencesStore`, never `UserDefaults`; read
    when the window opens; a failed save brings the previous scope back and says why; an
    unusable file reads as Home folder, says so and turns the choice off until "Try again"
    finds it fixed) and "Missing a folder?" with "Open Spotlight settings" (D36). D23's pattern: a working copy of the saved list
    with "Add" (checked inline with `DirectoryLists.check`, which includes
    `Validation.workingDirectory`, plus no duplicate by exact string and the 50-entry cap;
    appended as typed, Return in the field adds), move up, move down and remove per row, and
    "Revert" and "Save"; nothing is written before Save, which is one `mergeSaved(base:edited:)`
    change (`knownHosts` `nil`: recents untouched, nothing pruned) and says "Saved."; closing
    the window drops unsaved edits (the next opening reads the file again). **Save's rule**
    (Phase I-2b review): a three-way merge that the store runs on the file as it is under
    `directories.lock`, in the same `apply` as its write, so it is atomic with New session's
    changes (the same store) and with other muxFinder processes. `base` is the saved list the
    tab's edits started from (as loaded, saved, reverted, or followed while there were no
    edits), `edited` the working copy; the result is `edited` (its order, its additions,
    without its removals) less the entries removed from the file since `base`, followed by the
    entries added since `base` that `edited` lacks, in the file's order, all compared byte for
    byte, then checked as `replaceSaved` is (a rule or the 50-entry cap refuses it, and the
    working copy stays). So a "Save this directory" (or another muxFinder's change) made during
    an edit is never lost or undone, recents recorded or cleared meanwhile stay as they are,
    and the tab then shows what the file holds. Chosen over refusing a Save whose base is stale
    (as D19's `save(_:expecting:)` does for the host list): New session only ever adds to the
    saved list, so the merge has nothing ambiguous to resolve, and a refusal would make the
    user redo the edits. An unusable file or
    unreadable folder shows its notice with "Try again" and offers no edit (the store would
    refuse every change); a file with entries left out is editable, and its notice says the
    save keeps that file as a backup. Saves and loads are logged by kind and count only. A save
    there hands the lists to `AppModel` (`onDirectoriesSaved`); a change from New session's
    list hands them to the tab (`directoriesChangedElsewhere(_:)`), whose saved list follows
    and whose working copy follows only while it has no unsaved edits. No recents editor:
    they are cleared per host from New session's list.
  - **Previews (Phase I-2b; I-10b):** since Phase I-10b `FolderSearchFixtures` add the
    folders section's states to the New session gallery (searching, found with one left out
    and a long path shortened, none, each unavailable reason, an SSH failure, the protected
    folders' note, "Missing a folder?" open) and `SettingsFixtures.folderSearch` and
    `folderSearchUnusable` the Directories tab's setting; synthetic paths only. New session's
    fixtures show the list open (three sections, a
    highlighted recent row, a long path shortened), nothing to pick, a value saved already and
    an unusable file (`AttachFixtures.newSessionStates`; out of the attach gallery since D34,
    in the New session window's, `--preview-gallery new-session`); the Settings gallery shows the
    Directories tab with unsaved edits and an inline issue, and with an unusable file;
    synthetic paths only. `--preview-snapshot`
    sizes the preview window to its content's natural size before drawing, since a titled
    window taller than the screen is shrunk to it and the attach gallery's host lists, which
    can shrink, then rendered squeezed.
  - **Uninstall:** `scripts/uninstall.sh` removes the whole support folder, `directories.json`,
    its backups and `directories.lock` included (no change).

- **D32 — Session switcher shortcut and panel** (decided in Phase I-3a, 2026-10-24, from
  `autoclaude/processed/30-global-hotkey-session-switcher.md` and the orchestrator's calls in
  *Phase I-3*; extended in Phase I-3b with the switcher panel. Code in
  `Sources/MuxFinderCore/Config/GlobalShortcut.swift` and `PreferencesStore.swift`,
  `Sources/MuxFinderUI/Model/GlobalShortcutLabel.swift`, `HotkeyRegistrar.swift`,
  `GlobalShortcutModel.swift`, `AppModel.swift` (`globalShortcutPressed()`, the combined
  visibility), `AppLaunchOptions.swift`, `Views/Settings/ShortcutRecorderView.swift`,
  `Sources/MuxFinderApp/HotkeyRegistrationReport.swift`; the panel (I-3b) in
  `Sources/MuxFinderUI/Model/SwitcherContent.swift`, `SwitcherController.swift`,
  `AppModelSwitcher.swift`, `Views/SwitcherView.swift`, `Views/SessionSwitcher.swift`,
  `Views/MenuBarPopover.swift` (`PanelHost`, `PanelObservers`), `Views/PopoverWindowBridge.swift`
  (`PanelKeyTrackingView`), `Preview/SwitcherFixtures.swift`, `Preview/SwitcherGallery.swift`,
  `Sources/MuxFinderApp/AppDelegate.swift`; tests `Tests/MuxFinderCoreTests/GlobalShortcutTests.swift`,
  `PreferencesStoreTests.swift`, `Tests/MuxFinderUITests/GlobalShortcutModelTests.swift`,
  `GlobalShortcutAppTests.swift`, `SwitcherContentTests.swift`, `SwitcherControllerTests.swift`,
  `SwitcherModelTests.swift`; extended in Phase I-10a with the folder search scope, D36:
  `PreferencesStore.swift`, test `FolderSearchScopePreferenceTests.swift`).
  - **The value** (`GlobalShortcut`): a virtual key code (Carbon's `kVK_…` numbering, the
    key's position whatever the layout, as `NSEvent.keyCode` gives it; at most 127) and the
    modifiers ⌃⌥⇧⌘ (`GlobalShortcut.Modifiers`, stored by name). No default: the hotkey is off
    until the user records one. `check`: **refused** a typing key with no modifier but ⇧ (or
    none), F1–F20 excepted (`needsModifier`); macOS's own combinations, ⌘Space, ⌘Tab, ⌘⇧Tab,
    ⌘⇧3, ⌘⇧4, ⌘⇧5 and ⌘⌥Esc (`systemShortcut`); a key code past 127 (`unknownKey`).
    **Warned about**, then taken if the user confirms: ⌘ and nothing else with the key
    (`commandWithOneKey`: that key's ⌘ shortcut would stop working in every app) and only ⌥ or
    ⌥⇧ (`optionOnly`). The ⌥ rule is a warning, not the refusal the specification expected:
    macOS 15 and later is reported to refuse or ignore such app hotkeys, but on this Mac
    (macOS 27.2) Carbon registered ⌥F19, ⌥⇧F19, ⌥J and ⌥⇧J with `noErr`
    (`--report-hotkey-registration`, *Verified facts*), so a refusal is not confirmed and
    whether a press is delivered is checklist 18's; should it not be, a later phase turns the
    warning into a refusal. Any other combination another app or macOS takes first shows as
    taken (below) or simply never fires.
  - **The label** (`GlobalShortcutLabel`): the modifier symbols in macOS order (⌃⌥⇧⌘), then
    the key: F1–F20 by name, Space, Return (↩), Tab (⇥), Delete (⌫), forward delete (⌦), Esc
    (⎋), Enter, Clear, Help, the arrows and Home/End/Page up/Page down by fixed symbols, every
    other key as the current layout types it with no modifier, uppercased (macOS menus show
    letters so), through `KeyboardLayoutNaming`: `SystemKeyboardLayout`
    (`TISCopyCurrentKeyboardLayoutInputSource`, falling back to the current ASCII-capable
    layout when that one has no `uchr` data, and `UCKeyTranslate` with
    `kUCKeyTranslateNoDeadKeysMask`, so a dead key shows its accent; read at each label, on
    the main actor), `StaticKeyboardLayout` for tests (a Spanish-like table: Ñ, Ç, `, +) and
    previews; a key that types nothing printable shows "Key <code>". A spoken form
    ("Control-Option-Ñ") is VoiceOver's value. The user types on a Spanish layout.
  - **Storage** (`PreferencesStore`; the orchestrator's call): `preferences.json` in
    muxFinder's folder, not the app's defaults domain, because muxFinder owns only its support
    folder (and `DynamicProfiles/muxFinder.json`), tests then use a private folder like the
    other stores and never `~/Library/Preferences`, and the app shell check's empty
    `CFFIXED_USER_HOME` isolates it without relying on `cfprefsd`. Schema 1:
    `{"folderSearchScope": "disk", "globalShortcut": {"keyCode": 49, "modifiers": ["control",
    "option"]}, "schemaVersion": 1}`, pretty-printed, sorted keys, final newline, at most
    64 KiB. Other keys are ignored when read and **kept** when written (the object read is
    written back with only the changed key and `schemaVersion` set), so a later setting or a
    newer muxFinder's key survives. **`folderSearchScope`** (Phase I-10a, D36;
    `setFolderSearchScope(_:)`, `Preferences.folderSearchScope`): `home` or `disk`; a missing
    or `null` value, or any other (a newer muxFinder's, a number), reads as `home` and is kept
    in the file as it is until the scope is saved, like an unknown key (the file stays fully
    usable, so the write that replaces it keeps no backup); choosing `home` with no value, or
    the value the file holds, writes nothing; a change (Settings › Directories' "Search
    folders in", Phase I-10b, D31) applies to the next query. **`terminal`** (Phase I-12c3a,
    D38; `TerminalSettingStoring.setTerminal(_:)`, `Preferences.terminal`): the terminal
    sessions open in, `iterm2` or a terminal definition's id, stored as given; a missing or
    `null` value is the default, resolved and never written (iTerm2 when installed, otherwise
    Terminal; `TerminalChoice`); a value that is not a string reads as the empty id, which
    names no terminal, so the choice is unavailable rather than replaced by the default;
    setting the value the file holds, or removing an absent one, writes nothing. The app reads
    it at launch and writes it only through `AppModel.setTerminal(_:)`, in normal mode only.
    Schema 1 did not change: an older muxFinder ignores these keys and keeps them. Loading
    never writes; a
    missing file or a missing or `null` shortcut is "off";
    a value that is not a usable shortcut (not an object, a key code that is not an integer
    up to 127, an unknown modifier, a combination `check` refuses) is left out
    (`droppedShortcut`, a notice "Record a new one") with the file usable; a file that cannot
    be used (D14's rules for files read, not JSON, not an object with an integer
    `schemaVersion`, another schema version) leaves the hotkey off and is left as it is, and
    every change refuses it (`fileNotUsable`), as D31 does. Written only when the user records
    or clears a shortcut, picks a folder search scope or changes the terminal, and not at all
    when nothing changes; a
    write takes `preferences.lock`
    (`PrivateStorage.acquireLock`, 2 s, `busy`), reads the file again under it and publishes
    with D31's rename and backup rules (`preferences.backup-<UTC>.json` for a displaced file
    this store did not last read as fully usable). `InMemoryPreferencesStore` for tests.
  - **Registration** (`HotkeyRegistering`; `CarbonHotkeyRegistrar`): `RegisterEventHotKey`
    for the application event target with `kEventHotKeyExclusive` (an app that holds the
    combination exclusively makes it fail, and while muxFinder holds it other apps'
    non-exclusive registrations get no press), the `EventHotKeyID` signature "mxfd" and one id
    per registration; one `kEventHotKeyPressed` handler on the event dispatcher target
    (MASShortcut's arrangement: every event the main run loop dispatches passes through it),
    installed at the first registration, removed by `unregisterAll()`. `OSStatus` mapping:
    `eventHotKeyExistsErr` is `taken` ("Another app uses this shortcut. Choose another.";
    Carbon also returns it for a second registration in the same process), `eventHotKeyInvalidErr`
    and `paramErr` `invalid`, anything else `failed(status)`. No Accessibility or Input
    Monitoring permission is needed; `NSEvent.addGlobalMonitorForEvents` would need
    Accessibility and cannot consume the key. A registration is forgotten only once
    `UnregisterEventHotKey` returned `noErr`: a failed one keeps its reference and its token
    (its presses still arrive), so a later `unregister(_:)` can still undo it, and
    `unregisterAll()` keeps and counts the ones that fail and removes the handler only once
    nothing is registered (Phase I-3a review). The Carbon calls go through
    `CarbonHotkeyCalls`, so tests drive the registrar over fakes and never reach Carbon. A fake
    registrar in the tests records calls, refuses "taken" combinations, fails unregistrations
    when told and fires presses.
  - **Lifecycle (normal mode only):** `AppEnvironment.globalShortcut` exists only when
    `AppLaunchOptions.registersGlobalShortcut` (the menu bar app with no `--report-*` flag,
    preview, self-test or removal), through `production(rewritesProfilesAtLaunch:usesGlobalShortcut:)`;
    every other mode, the placement diagnostic, the self-tests and the tests of other parts
    have none, so they never read `preferences.json` or register. `GlobalShortcutModel`
    (owned by `AppModel`, shown by Settings) loads and registers at the start of
    `AppModel.start()` (launching has finished), registers again on a change, unregisters on
    clear and in `AppModel.shutdown()` (its save in progress awaited first). A saved shortcut
    that does not register at launch shows its message beside the recorder and in
    diagnostics. The model drops its token only once the registrar unregistered it: a failure
    leaves the hotkey registered and working (`registration` stays `registered`), says so
    beside the recorder ("macOS couldn't turn off the shortcut (error …), so it still
    works.") and in diagnostics (`unregistrationFailure`), and what needed it does not go on
    (recording does not start, "Clear" keeps the shortcut and saves nothing, "Try again"
    loads nothing); the next attempt tries again. At quit it is only logged.
  - **The recorder applies at once** (the orchestrator's call; like the launch-at-login toggle,
    D23, not Save/Revert: whether a combination registers is only known by registering it).
    Settings › General gains a "Session switcher" section between "Startup" and "About
    muxFinder": "Show session switcher", the hand-written recorder (no package: a field-like
    button showing the label, "Record shortcut" without one, "Type the shortcut" while
    listening, accent border; accessibility label "Session switcher shortcut", the spoken
    label or "None" or "Recording" as value, a hint) and "Clear". Clicking it suspends the
    hotkey (unregistered, so pressing it records it) and installs a local key-down monitor on
    the Settings window (only while listening; repeats swallowed, other windows' keys passed
    on). Esc cancels (the saved shortcut is registered again), Delete or forward delete clears,
    any other combination is checked: a refusal shows beside the field and it keeps
    listening; a warning shows with "Use it anyway" (or Return) and "Choose another"; a usable
    one is registered, then saved in the background. A registration that fails keeps it
    listening with the reason; a save that fails unregisters it, brings the previous shortcut
    back and says why ("muxFinder couldn't save the shortcut. …"); nothing is ever an alert.
    A save (or a clear's save) that finds the file unusable, because another program broke or
    replaced it after it loaded, is the exception (Phase I-3a review): the hotkey is then off,
    as a launch with that file leaves it: the change's registration is undone and the
    previous shortcut is not registered again, so the notice ("… the shortcut is off until it
    is fixed or moved away") is true; the file is left as it is (D31's refusal rule); the line
    beside the field says the change was not saved; and "Try again" reloads the file, so once
    the user fixes or removes it the shortcut it holds is registered and the recorder works
    again. (Keeping the previous shortcut registered instead would have needed "Try again" to
    replace a live registration while the notice said the hotkey was off.) Clicking the field
    again, closing the window, the window losing the focus, choosing another Settings tab
    (`SettingsModel.selectedTab`) or the recorder leaving the window (`onDisappear`) stops
    listening, so the key monitor goes and the saved hotkey is registered again. While a save
    runs the recorder is disabled. An unusable file or folder disables it with its notice and
    "Try again". Diagnostics ("Copy diagnostics", `Session switcher shortcut:`) and the log
    record the state by kind (`registered`, `off`, `suspended`, `failed.taken`, `unregistration
    failed (failed(-108))`, the file's problem code), never the combination.
  - **The press** reaches one entry point, `AppModel.globalShortcutPressed()`, which toggles
    the session switcher through `AppModel.toggleSwitcher` (`SwitcherController.toggle()`, wired
    by `SwitcherController.make(for:panel:system:)`): open, it closes (`CloseReason.shortcut`);
    closed, it opens (below). Phase I-3a's interim popover toggle
    (`PopoverController.shortcutPressed()`, `AppModel.togglePopover`) is gone. The Settings note
    says what the shortcut does.
  - **The switcher panel** (Phase I-3b; `SessionSwitcher`, decisions in `SwitcherController`
    over the popover's `PopoverPanelSurface` seam): the popover's borderless, non-activating
    `PopoverPanelWindow` (D30), here at the **floating level**, with the same collection
    behavior (`canJoinAllSpaces`, `fullScreenAuxiliary`, `transient`, `ignoresCycle`: it shows on
    the active Space and over full-screen apps), rounded 12 pt, opaque (Phase 14's
    `PopoverPalette` background), its accessibility title "Session switcher", hosted through the
    shared `PanelHost` (generic over its root view) and watched by the shared `PanelObservers`.
    It is **540 pt wide** (`SwitcherPlacement.width`: a session name, its host's name and the
    detail on one line), centered horizontally on the visible frame of the display with the
    keyboard focus, its top edge 18 % of that visible frame's height below its top (on the pixel
    grid), growing downwards, its content limited to the room down to 8 pt above the visible
    frame's bottom (the list shrinks and scrolls, `PopoverHeightLimit`); a size change keeps the
    top edge. The display with the keyboard focus is the one sharing the most area with the
    frontmost app's frontmost layer-0 window (`CGWindowListCopyWindowInfo`: owner, layer and
    bounds only, never a title, readable without permission, nothing logged), else
    `NSScreen.main`, else the pointer's, else the first (`SwitcherPlacement.screenIndex`). It
    closes on Esc (its own close), the shortcut, a mouse press another process received, another
    app becoming active (iTerm2 coming forward included), the panel resigning key, a display
    change, the popover opening, an action it started succeeding, and the New session window
    opening from it (`CloseReason.newSessionOpened`, D34; a close from outside made by a press
    on muxFinder's status item is left to the popover that press opens; *Visibility* below;
    after a click on a row, a success, the New session window opening, another app becoming
    active and the panel resigning key wait for the double-click interval, *Keys*). Being
    non-activating,
    closing it leaves the focus with the app that had it. Built only in normal mode with the
    shortcut (`AppLaunchOptions.registersGlobalShortcut`): no preview, self-test or `--report-*`
    mode has one.
  - **Content** (`SwitcherContent`, a pure value): a search field (emptied and focused at each
    opening), the popover's banners, then one bounded box: pinned rows (failures carried from a
    closed switcher, then sessions of its actions the engine does not list yet, such as a just
    created one, made from their target), the **live** sessions in the popover's order (the
    popover's `SessionRow`s, with Phase 14's indicator, detail, badge and activity; stale ones
    left out) filtered by the popover's rule over host and session names, a muted "No live
    sessions." or "No session matches “…”." when none is listed, and "New session…" last, which
    reads "New session “<name>”…" and fills the name in when the trimmed filter text passes
    `Validation.sessionName` and no live session has exactly that name. Under the box, a muted
    line per host still checking or whose last check failed ("Saturno: checking…", "Sirio:
    unreachable", "Saturno: sign-in needed"), with the status's dot, never red. With no host
    turned on (or the list loading) the popover's placeholder with "Open Settings" and no New
    session row. A line of key hints closes it. The selection is the remembered item while it
    is listed, else the first; each opening and each change of the filter text select the
    first row (as Spotlight does) and remember it, and while the switcher shows the selected
    row is remembered again before each engine update is applied
    (`AppModel.rememberSwitcherSelection()`), so a refresh that inserts or removes sessions
    never moves the selection, or Return's target, to another session.
  - **Keys** (`AppModel.handleSwitcherKey(_:)` over `PopoverKey`, through the popover's local
    key monitor, now `PanelKeyTrackingView`, so an input method's marked text goes to the field):
    ↑/↓ move without wrapping, Return activates the selected row, ⌘N opens the New session
    window (D34), ⌘F focuses the search field, ⌘R refreshes, ⌘, opens Settings (which activates
    the app, so the switcher closes), Esc closes, ⌥↓ goes on. A click activates a row, as in
    the popover (`AppModel.clickSwitcherItem(_:)`: selected, then opened or the New session
    window opened, at once), and the rest of that click's sequence reaches no view in the panel
    (`SwitcherClickSequence`), nor in the New session window it opened (D34), so a quick double
    click's second click never acts on the window the first one opened (a second Open of a row
    opening is ignored anyway, D25). That rest always lands on the panel or that window: until
    the system's double-click interval has passed since the click
    (`SwitcherController.holdForClick()`), the panel is no shorter than it was (the switcher's
    background below a shorter content; a shrink waits, growth does not), and a close for the
    action's success, the New session window opening, another app becoming active or the panel
    resigning key (iTerm2 coming forward when a session open here is focused) waits for the
    end; Esc, the shortcut, a press outside, a display change and the popover opening close at
    once, and each close ends the hold. Return, ⌘N and the accessibility action hold nothing.
    New session is its own window (D34), opened with the name prefilled from the filter (for a
    fresh draft only) and placed from the switcher's frame; its form, keys and Tab order are the
    window's. Move here and Detach stay in the popover (a failure's own recoveries are the
    popover row's, but for "Try again" after a move here or a "Detach other clients…", whose
    confirmation only the popover draws, D37).
  - **Actions and carry-over** (`AppModelSwitcher.swift`): a session row opens through the
    popover's Open (D25: focused when open here, else attached), in the chosen terminal; its
    row shows the popover row's "Open in Terminal on this Mac" with "Show in Terminal" (D38
    *The UI (I-12d2)*). An Open started while the
    switcher shows, and the creation and attach of a New session draft the switcher made (D34)
    and the attach its "Open existing" starts, are followed (`switcherActions`,
    `switcherCreation`): the row shows the activity (pinned while the engine does not list
    it); a success (`SessionActivity.isAttached`: confirmed, or a tab, window or app brought
    forward) closes the switcher
    (`CloseReason.actionSucceeded`) only if it showed when the action started and stayed open
    since (rarely so for a creation: the switcher closes as the New session window opens); a failure while it shows stays on its row with the popover row's text
    and recoveries (the switcher stays open); a failure that arrives once it closed is carried
    (`switcherCarriedFailures`) to the top of its next opening, pinned and selected (Return
    retries), and forgotten when that opening closes, while the popover row keeps it as always;
    a vanished or changed session has the popover's banner, shown at the top of both. A pinned
    row the engine does not list (a session just created on a host that stopped answering, say)
    opens (Return, "Try again", "Bring forward") through its retained target
    (`switcherTargets`) on its host as the engine has it now, which the coordinator revalidates
    as always (`AppModel.pinnedSwitcherTarget(for:)`); with that host turned off or removed the
    row shows "This session's host is no longer turned on in muxFinder, so nothing was opened."
    with "Open Settings" and "Try again" (`SessionProblem.hostNotTurnedOn`), never nothing. A
    creation failure (a collision, say) stays in the New session window, which comes back with
    it, not key, when it was closed (D34); opening and closing the switcher never touch that
    window or its draft.
  - **Visibility** (D22): the model combines the two (`isSessionListVisible`): `.popoverOpened`
    and `.popoverClosed` are each sent once whenever "either one is visible" changes, and each
    opening asks the other to close (`AppModel.closePopover`, set by `MenuBarPopover` to
    `PopoverController.close(.switcherOpened)`; `AppModel.closeSwitcher`). Both controllers
    report a new visibility before their panel shows, so the swap keeps one of the two visible
    for the engine and never sends a closed and opened pair. A press on muxFinder's status item
    while the switcher shows reaches the app twice (D30): as the button's action and as a close
    from outside (the switcher resigning key, another process seeing the press), in either
    order. The switcher leaves such a close to the button's action
    (`SwitcherController.close(_:)` asks `AppModel.isStatusItemPressHeld`, which `MenuBarPopover`
    sets to `PopoverController.isButtonPressHeld`: a mouse button held on the button's usable
    rectangle, D30's rule for a press on the button); the action opens the popover, which
    closes the switcher (`popoverOpened`), so neither order sends a closed and opened pair, and
    a press elsewhere still closes the switcher at once. A press on another display's copy of
    the icon is not recognized so (AppKit gives that copy only a placeholder frame): when its
    close from outside comes first, the engine hears a close and an open. Both openings clear
    the activities of actions that succeeded. The engine's visibility changes are kept for tests
    (`engineVisibilityChanges`, the latest 32).
  - **Gallery:** `--preview-gallery switcher` (`SwitcherFixtures`, synthetic): the list, a
    filtered list, New session with a name, opening, a failure, a failure since the last
    opening, no hosts, hosts checking or unreachable; `docs/screenshots/switcher-states-*.png`.
    The New session form as the switcher opens it, its name from the filter, is
    `SwitcherFixtures.form`, in the New session window's gallery (D34, Phase I-9b).
  - **The diagnostic** (`--report-hotkey-registration`; the orchestrator's call: allowed with
    bounds, not UI scripting): in its own process, through `CarbonHotkeyRegistrar`, it
    registers ⌃⌥⇧⌘F19 (expected registered), again (expected taken), unregisters it, registers
    and unregisters it again, then registers and unregisters ⌥F19, ⌥⇧F19, ⌥J and ⌥⇧J (expected
    registered while `check` only warns about them, refused if it refuses them), runs
    `unregisterAll()` and exits: 0 all as expected, 1 a check not as expected or an
    unregistration failed, 3 SIGTERM or SIGINT arrived (they are blocked for the checks and
    found pending afterwards, so every registration is undone first), 2 combined with another
    mode. No window, menu bar item, engine, host list, iTerm2 or `preferences.json`; no event
    posted; it proves registration, never a press.

- **D33 — The menu bar app on a plain `NSApplication`** (decided in Phase I-4, 2026-11-04,
  from `autoclaude/processed/40-empty-settings-window-at-launch.md` and the diagnosis in
  *Verified facts*, Phase I-4; code in `Sources/MuxFinderApp/MuxFinderMenuBarApp.swift`,
  `Sources/MuxFinderUI/Views/MainMenu.swift`, `Sources/MuxFinderUI/Model/AppShellReport.swift`,
  `Sources/MuxFinderApp/AppDelegate.swift`; tests `Tests/MuxFinderUITests/MainMenuTests.swift`
  and `AppShellReportTests.swift`).
  - **The choice** (decided: no SwiftUI `App`). `MuxFinderMenuBarApp.run()` takes
    `NSApplication.shared`, makes `AppDelegate` its delegate, installs `MainMenu` and runs it,
    as preview mode and the self-tests already ran on a plain `NSApplication`. The SwiftUI
    `App` was there only for its standard main menu, with one empty `Settings` scene whose
    menu item was removed; but on macOS 27.3 SwiftUI shows its first scene's window when
    launching finishes, so every launch showed an empty, resizable "muxFinder Settings" window
    (*Verified facts*, Phase I-4). With no scene, only muxFinder's own code makes windows: the popover and
    switcher panels (hidden until asked for), Settings (D23), onboarding (D24, only while
    there is no host list) and the New session window (D34, made at its first opening), so a
    launch shows no window but onboarding. Hiding or closing
    SwiftUI's window once it appeared was not considered: it would depend on SwiftUI's
    undocumented launch order and still flash the window.
  - **Considered:** keeping SwiftUI with a scene macOS never opens by itself. A `Window` or
    `WindowGroup` with `defaultLaunchBehavior(.suppressed)` needs macOS 15 (the target is 14);
    an empty `MenuBarExtra` would add a second status item; and no documented API keeps a
    `Settings` scene from showing at launch, the very behavior seen.
  - **The menu** (`MainMenu.make`): never shown (an accessory app has no menu bar), it is
    there for its key equivalents, which AppKit offers the key window and the main menu, a
    non-activating panel being key included. It keeps the items of SwiftUI's menu that act on
    muxFinder's windows and text fields, as the app shell check read them off it (the rest is
    under *What differs*): the app menu (About muxFinder, Services,
    Hide muxFinder ⌘H, Hide others ⌥⌘H, Show all, Quit muxFinder ⌘Q sending `terminate:`, so
    `applicationShouldTerminate`'s orderly shutdown runs), Edit (Undo ⌘Z, Redo ⇧⌘Z, Cut ⌘X,
    Copy ⌘C, Paste ⌘V, Paste and match style ⌥⇧⌘V, Delete, Select all ⌘A) and Window (Close
    ⌘W through `performClose:`, Minimize ⌘M, Zoom, Bring all to front); every item goes to the
    first responder, and `NSApp.servicesMenu` and `windowsMenu` are its Services and Window
    menus. AppKit adds AutoFill, Start Dictation and Emoji & Symbols to Edit, as it did to
    SwiftUI's menu, and an alternate "Close All" (⌥⌘W, `closeAll:`) under Close. Titles are
    sentence case (D10).
  - **What differs from SwiftUI's menu:** no Settings item, as before (SwiftUI's was removed):
    ⌘, opens Settings only from the popover, the session switcher and the New session window,
    whose key monitor takes it before any menu (D22, D32, D34). Paste and match style and
    Close are new (SwiftUI's menu had neither, and no File menu). Close is disabled for
    muxFinder's borderless panels (`validateMenuItem` is false for `PopoverPanelWindow`), so
    ⌘W and ⌥⌘W leave the popover and the switcher alone; it is enabled for the New session
    window (`NewSessionPanel`, titled and closable, D34), which ⌘W closes like Cancel; Settings
    and onboarding close on ⌘W through `SettingsWindow` itself, as before. Gone: the empty View menu, the Help menu (⌘? only said that help is
    not available) and SwiftUI's hidden Toggle Sidebar (no window has a sidebar).
  - **Unchanged:** `AppDelegate` (the accessory policy, SIGTERM and SIGINT through
    `AppTermination`, `applicationShouldTerminate`, a reopen opening nothing). Preview mode and
    the self-tests keep their plain `NSApplication` with no main menu;
    `--report-popover-placement` runs this shell as normal mode does; the login item, hotkey
    registration and profile removal modes never run an app.
  - **The check:** `--report-menu-bar-item` also prints every other window of the app (title,
    class, visibility, level), the launch's Apple event and the main menu (`AppShellReport`;
    bounded: 32 windows, 80 menu items, titles cut to 80 characters), so an unexpected window
    at launch shows as a visible window in its output.

- **D34 — New session in its own window** (decided by the orchestrator for Phase I-9,
  2026-11-05, from `autoclaude/processed/90-new-session-own-window.md`; code in Phase I-9a:
  `Sources/MuxFinderUI/Model/NewSessionWindowController.swift` (the request and state types,
  `NewSessionWindowPlacement`, `NewSessionWindowController`), `AppModelNewSession.swift`,
  `AppModel.swift` (`newSessionWindow`), `AppModelSwitcher.swift`, `PopoverController.swift`
  and `SwitcherController.swift` (`newSessionSource`, `CloseReason.newSessionOpened`),
  `Views/NewSessionWindow.swift`, `Views/PopoverWindowBridge.swift` (`PanelKeyTrackingView`'s
  mouse filter), `Sources/MuxFinderApp/AppDelegate.swift`; tests
  `Tests/MuxFinderUITests/NewSessionWindowTests.swift` and the suites listed in
  `docs/TESTING.md`, *Phase I-9a*. The folder drop, the window's gallery and the user docs came
  in Phase I-9b, below; the window's folder search in Phase I-10b, below).
  - **The choice** (the user's decisions): New session was a form drawn inside the popover and
    the session switcher, borderless panels that close on resigning key, a click elsewhere or
    another app becoming active (D30, D32), so going to Finder for a folder lost it without a
    trace. It is now one titled, movable, always-on-top window, opened from both entry points
    (which close as it opens), staying until Create succeeds, Cancel, Esc, ⌘W or its close
    button; the close button acts like Cancel. No "Choose…" folder picker.
  - **The window** (`NewSessionPanel`, wired by `NewSessionWindow`): a non-activating `NSPanel`
    (`.titled`, `.closable`, `.nonactivatingPanel`; a class of its own, not
    `PopoverPanelWindow`, so the main menu's Close, ⌘W, is enabled for it, D33) titled "New
    session"; it becomes key without activating muxFinder, as the popover and switcher do, and
    a click into it makes it key again without taking the frontmost app's place; floating
    level (above other apps' normal windows, below the popover and switcher panels and menus);
    `canJoinAllSpaces` and `fullScreenAuxiliary` (the user leaves it to look for a folder,
    possibly on another Space or beside a full-screen app); `hidesOnDeactivate` false, not
    released when closed, movable, not resizable by the user; nothing closes it on resigning
    key, a click elsewhere or another app becoming active. One window, made at the first
    opening and reused (so the app shell check lists none at launch); its key view loop is
    recalculated (`PopoverPanelWindow.recalculatesKeyViewLoop`, Phase I-6). It hosts the form
    (`NewSessionPanelView`, without its old headline: the title says it) at
    `NewSessionWindowPlacement.width`, 540 pt (the switcher's form width), on Phase 14's
    opaque background, at its natural height (`PopoverHeightLimit` with no limit), reporting
    size changes as the panels do.
  - **The model** (`AppModel.newSessionWindow`, a `NewSessionWindowState`): whether the window
    shows and the latest `NewSessionWindowRequest`, numbered so it is carried out once:
    `.open(source:)` (the user's opening: key) or `.outcome` (a comeback: not key). The view
    layer follows it through `AppModel.newSessionWindowChanged`, which
    `NewSessionWindowController.make` sets; the controller places and shows the window over a
    `NewSessionWindowSurface` (a fake in tests). The popover's `panel` now holds only the Move
    here confirmation (`PopoverPanel.moveHere`), so a Move here confirmation and the window can
    show at the same time. The controller is installed by the app shell only (`AppDelegate`,
    normal mode, `--report-menu-bar-item` included; never `--report-popover-placement`): the
    self-tests drive `newSession()`, `createSession()` and `closeNewSession()` with no window,
    and preview mode builds the window only for `--preview-key-view-loop` (below); the
    window's gallery draws its content without a window (Phase I-9b).
  - **Opening** (`newSession()` from the popover's ⌘N and button, `newSessionFromSwitcher()`
    from the switcher's ⌘N and New session row; both `openNewSession(from:source:prefill:)`):
    a fresh opening (the window closed) starts a fresh draft for This Mac (or the first enabled
    host), named from the switcher's filter when its row offers it, records the draft's origin
    (`newSessionOrigin`), closes the directory list, asks for the Name field's focus
    (`newSessionFocusRequests`) and reads the directory lists afresh (D31); while a creation
    runs its draft shows busy instead, with no prefill. An opening while the window shows only
    brings it forward, key, its draft, directory list and frame untouched (so the switcher's
    prefill never overwrites a draft). Either way the popover and the switcher close
    (`CloseReason.newSessionOpened`), and opening or closing them never touches the window or
    its draft.
  - **Position and size** (`NewSessionWindowPlacement`, pure): a fresh opening puts the
    window's top centre at the top centre of the popover or switcher it came from
    (`PopoverController.newSessionSource`, `SwitcherController.newSessionSource`, through
    `AppModel.popoverSource` and `switcherSource`), on that display, clamped into its visible
    frame; with no source, where the switcher would show on the first display. No frame is
    remembered across closes, except for a comeback (below). While it shows the user's move
    stands: an opening only brings it forward. The height follows the content (the directory
    list included) with the top edge fixed, clamped into the visible frame of the display it is
    on (moved up when it would reach below it).
  - **Keys** (`AppModel.handleNewSessionKey(_:)`, through `NewSessionWindowTrackingView`, the
    panels' `PanelKeyTrackingView` with the same `PanelKeyRoute`): as the form's were in the
    panels: an open menu and an input method's marked text first, I-8's rule for a focused
    pop-up button (↑, ↓, ⌥↓ go to the Host picker), then the open directory list's keys (D31),
    Return creates, ⌥↓ opens the list, Esc closes the list and then the window, Tab and ⇧Tab
    through the recalculated key view loop. ⌘W and the close button reach
    `NewSessionPanel.close()`, which is `closeNewSession()`. ⌘, opens Settings (the window
    stays, above it); ⌘R and ⌘F are not the window's (it lists no sessions) and go on to the
    focused view; ⌘N and, with the list closed, ↑ and ↓ do nothing.
  - **Clicks:** each opening makes the window let the rest of the click sequence in progress
    through to no view (`newSessionClicks`, D32's `SwitcherClickSequence`;
    `newSessionWindowPasses(_:)`), and the switcher's close for the window's opening waits for
    a click's hold (`waitsForClickHold`), so a quick double click on the New session row lands
    its second click on the switcher or on the window, both ignoring it (Phase I-5's guarantee,
    kept).
  - **Ending:** Cancel, Esc (the list closed), ⌘W and the close button close the window as
    `closeNewSession()`: the directory list closes, "Open existing" stops looking (its lookup is
    cancelled, a `findingExisting` draft goes back to `collision`), a creation in progress goes
    on with its draft; otherwise the draft is dropped (the next opening starts a fresh one). A
    success closes the window and the attach goes on on its row; a collision ("Open existing")
    or a failure stays in it. However the window closes (`newSessionWindow.isShown` turning
    false: those, a success, "Open existing"), its folder search ends (below).
  - **Folder search** (Phase I-10b, D36, the orchestrator's calls in *Phase I-10*;
    `AppModelFolderSearch.swift`): one `FolderSearchChannel` per window and host, owned by the
    model (`FolderSearchSession`: the channel, the task reading its states and one queue for
    what is asked of it, each search reading the scope from `preferences.json` first, so a
    change in Settings applies to the next query and an unusable or unreadable file means
    `home`). It is made by the first searchable text while the directory list shows (an edit,
    the list's opening, a host change), not by the window's opening; asked for each new text
    (never the same text twice in a row); told to stop (`search("")`, which cancels a query
    waiting for its debounce) when the text can no longer be searched; and ended (its
    process closed and reaped in the background, nothing it found kept) when the window
    closes, when the draft's host changes (a new one for the new host searches the field's
    text at once while the list shows) and when the app quits (`shutdown()` waits for each
    closing within the session actions' budget); its process also closes by itself after a
    quiet minute without a query, a later text reopening it. The popover and the switcher
    never make one. Transport, clock and timings come from `AppEnvironment.folderSearch`
    (normal mode only: `ProcessFolderSearchTransport` and the shortcut's `PreferencesStore`;
    tests a `FakeFolderSearchTransport`, a clock they move and an in-memory or private-folder
    store), so the self-tests, the previews and every `--report-*` flag run no Spotlight and
    read no `preferences.json` for it.
  - **Failure after close** (`newSessionCreationFailed()`): when a creation whose window was
    closed ends in a collision or a failure, the window comes back with the draft as submitted
    and that outcome (`.outcome`), whichever entry point started it, ordered front at its last
    frame on its display (a fresh frame when that display is gone) without being made key, so
    it never takes typing from the app in front; a Move here confirmation no longer holds it
    back, and nothing comes back once quitting began. This replaces the switcher-only deferred
    failure (`switcherCreationFailed(_:)`, `showDeferredCreationFailure()`,
    `switcherCreationFailureDeferred`, retired), keeping its guarantee for every creation.
  - **The switcher's following** (D32, what changed): the switcher no longer shows the form
    (`switcherShowsNewSession` retired) and no longer cancels an idle form at its opening and
    closing. `switcherCreation` is now the creation of a draft the switcher made
    (`newSessionOrigin == .switcher`), so its attach is followed as before (pinned while the
    engine does not list it, a failure carried to the next opening), and so is the attach that
    draft's "Open existing" starts, though the switcher closed as the window opened
    (`switcherExistingOpened(_:target:)`, only once the attach started; a draft the popover
    made is followed only while the switcher shows, as any Open); their `closesOnSuccess`
    holds only when the switcher shows as the creation (or that attach) starts and stays open,
    which is rare now that the switcher closes as the window opens.
  - **Also retired:** `PopoverPanel.newSession` and `PanelView`; `cancelPanel()` closes only Move
    here; the popover's `handle(_:)` lost the form's keys; `closePopover` takes a reason. The
    attach and switcher galleries lost their inline form states (kept as
    `AttachFixtures.newSessionStates` and `SwitcherFixtures.form` for the window's gallery,
    Phase I-9b, which retired the switcher's filtered and no-match form states as duplicates
    of the popover's).
  - **The diagnostic:** `--preview-fixtures --preview-key-view-loop popover|switcher` (Phase
    I-6, I-8) now builds the real New session window over that entry point's fixture
    (`AttachFixtures.newSession`, `SwitcherFixtures.form`) and inspects its form; the step that
    showed the panel with the list before the form is gone.
  - **The folder drop** (Phase I-9b, the orchestrator's calls in *Phase I-9*; code
    `Sources/MuxFinderUI/Model/FolderDrop.swift`, the drop section of
    `AppModelDirectories.swift`, `Views/FolderDropView.swift`, `DirectoryFieldView`; tests
    `Tests/MuxFinderUITests/FolderDropTests.swift`): one folder dragged from Finder onto the
    Directory field's row (the field and its list button, not the whole window) fills the
    field as a pick (`fillDirectoryField(_:)`: the list closes and does not reopen, nothing is
    announced), its path standardized by its text alone (no symbolic link resolved) and written
    `~/…` under This Mac's home folder (I-7's, `thisMacHome`, compared by whole path
    components; the home itself `~`), absolute elsewhere, then checked as typed text for every
    host (D31). `FolderDrop.outcome(for:home:)` is that rule as a pure function over plain
    facts; anything but exactly one `file:` URL whose resource values say directory and not
    package (a file, an `.app`, several items, none, text, a link, a promise without a URL) is
    refused and the drag shows no "+", as is any drop while the window is closed or the draft
    busy. The drag's destination is `FolderDropView`, an invisible AppKit view laid over the
    row in front of the field: AppKit gives a drag to the frontmost view under the pointer
    registered for one of its types (`_hitTest:dragTypes:` was seen to work that way, in a
    throwaway probe, never in muxFinder's code), and the view registers for every type the
    field editor accepts, so the field editor (which would insert a path at the caret) never
    becomes the destination over the row, edited or not; its `hitTest(_:)` answers no view, so
    clicks reach the field. It reads only the dropped URL's own resource values (a Finder file
    reference URL resolved to its path), never the folder's contents, and logs nothing. The
    field shows an accent ring just outside it while a drop would fill it
    (`AppModel.isDirectoryDropTargeted`, cleared on exit, at the drop and when the window
    closes); its accessibility hint ends "Dropping a folder from Finder here fills in its
    path."
  - **The gallery** (Phase I-9b): `--preview-gallery new-session` (`NewSessionGallery`) draws
    each state in a window-like frame: `AttachFixtures.newSessionStates` with
    `SwitcherFixtures.form` second (editing from both entry points, an invalid name, the
    directory list's six states, creating, a collision, a failure, the drop highlight), then,
    since Phase I-10b, `FolderSearchFixtures.all` (the folders section's nine states, D31);
    `docs/screenshots/new-session-states-{light,dark}.png`.
  - **Considered:** a window that activates muxFinder, as Settings does (the frontmost app would
    lose its menu bar and the focus, for a form the user fills while looking elsewhere);
    showing a failure after close only on the session's row (there is no row for a session that
    was never created, and the popover may be closed); remembering the window's frame across
    closes (the orchestrator's call: a fresh opening appears where the user just looked).
- **D35 — Version numbers** (decided by the user, 2026-11-06, for the 0.2.0 release; the
  numbers live in `scripts/build-app.sh`'s Info.plist template, `CFBundleShortVersionString`
  and `CFBundleVersion`).
  - **Build number:** every release adds 1, whatever else changes.
  - **Version:** the minor number goes up (patch back to 0) when user-facing features were
    added since the last published release; the patch number goes up when only fixes were.
  - **The last published release** is the one `nd list muxfinder` shows (NonameDownloads),
    never a number guessed from the repository. `nd` refuses a version and build it already
    has; never pass `--replace` without the user's agreement.
  - **History:** 0.1.0 (1), 2026-11-04; 0.2.0 (2), 2026-11-06 (New session's keyboard host
    picker, its own window and the folder drop, Phases I-8 and I-9).

- **D36 — Folder search over Spotlight** (decided by the orchestrator for Phase I-10,
  2026-11-06, from `autoclaude/processed/100-folder-search-spotlight.md`; the core in Phase
  I-10a: code in `Sources/MuxFinderCore/FolderSearch/` (`FolderSearchText.swift`,
  `FolderSearchScript.swift`, `FolderSearchOutput.swift`, `FolderSearchTransport.swift`,
  `FolderSearchChannel.swift`, `FakeFolderSearchTransport.swift`),
  `Sources/MuxFinderCore/Process/StreamingProcess.swift`, `Config/PreferencesStore.swift`
  (D32), `Sources/muxfinder-probe/FoldersCommand.swift`; tests
  `Tests/MuxFinderCoreTests/FolderSearchTextTests.swift`, `FolderSearchOutputTests.swift`,
  `FolderSearchScriptTests.swift`, `FolderSearchTransportTests.swift`,
  `FolderSearchChannelTests.swift`, `FolderSearchScopePreferenceTests.swift`,
  `FolderSearchTestSupport.swift`; the UI in Phase I-10b, D31 and D34: `FolderSearchSection.swift`,
  `AppModelFolderSearch.swift`, `SettingsModelFolderSearch.swift`, `DirectoryPickerViews.swift`,
  `DirectoriesSettingsView.swift`, `FolderSearchFixtures.swift`; tests
  `Tests/MuxFinderUITests/FolderSearchSectionTests.swift`, `FolderSearchModelTests.swift`,
  `SettingsFolderSearchTests.swift`, `FolderSearchUITestSupport.swift`).
  - **What:** folder names only, case- and diacritic-insensitive "contains"
    (`kMDItemContentType == "public.folder" && kMDItemFSName == "*<text>*"cd`), found by
    Spotlight (`mdfind`) on the host itself, so the host needs no muxFinder: SSH hosts over
    discovery's noninteractive ssh (key authentication, BatchMode), This Mac locally.
  - **One script, both kinds of host** (`FolderSearchScript.script`, a `StaticShellScript`):
    This Mac runs it as `/bin/sh -c <script> muxfinder` by argv, not through
    `NSMetadataQuery`, so one implementation of the header, the noise rule, the limit and the
    answer format serves both and one set of tests covers both. Over SSH it takes no argument
    (D3); This Mac's transport passes one fixed word, `unchecked`
    (`FolderSearchScript.uncheckedArgument`, Phase I-10b), which turns the readability checks
    off (below); any other argument is ignored. Its standard input is the query stream and
    closing it ends the script.
  - **Query lines** (`FolderSearchScript.queryLine(id:scope:name:)`): `<id> <scope> <name
    text>` and a line feed; the id decimal digits (at most 18), the scope `home` or `disk`,
    the name text as `FolderSearchText` escapes it. The script splits the line with parameter
    expansion and checks it (a line without a usable id is skipped; otherwise `error
    malformed` for missing fields, `scope` for another scope, `length` for 0 or more than 512
    bytes, `text` for a control character, an unescaped `"`, `*` or `?`, or a `\` not
    followed by one of `\ " * ?`), then builds the one fixed predicate itself and passes it
    to `mdfind -0` as one quoted argument, after `-onlyin "$HOME"` for `home`. No `eval`: the
    channel can ask nothing but this folder-name question.
  - **Escaping** (`FolderSearchText.nameText(for:)`, pure): the scalars `\`, `"`, `*` and `?`
    get a backslash (scalars, not `Character`s, so a `*` with a combining mark is still
    escaped); everything else is kept as typed, leading and trailing whitespace included.
    Refused: fewer than 2 `Character`s (`tooShort`, the channel stays idle), a C0 or C1
    control, DEL, U+2028 or U+2029 (`controlCharacter`), more than 255 bytes of UTF-8
    (`tooLong`), checked before escaping (so at most 510 bytes escaped, under the script's
    512). **Verified on this Mac against `mdfind`, by counts** (a scratch APFS disk image
    with indexing turned on, 12 synthetic folders; `docs/TESTING.md`, Phase I-10a): each
    escaped special character matched exactly its one folder; unescaped, `*` acted as a
    wildcard; an unescaped `"` or a lone trailing `\` made a different predicate silently
    (exit 0, no message), hence the script's refusal; `cd` folded case and diacritics both
    ways, NFC and NFD alike; spaces count; `mdfind` reads its argument as UTF-8 whatever the
    locale (`LC_ALL=C` and an empty environment gave the same counts); a `'` between letters
    matched nothing mid-word, with or without a backslash (Spotlight's own word matching, for
    I-10b's "Missing a folder?", not an escaping matter).
  - **The header** (first, once, NUL-terminated records): `muxfinder-folders 1`, `home
    <$HOME>` (without a trailing slash; empty unless absolute), `mdfind yes|no` (`command
    -v`), `index home on|off|unknown` (`mdutil -s` of the volume `df -P "$HOME"` names:
    `mdutil -s "$HOME"` itself says "unknown indexing state", verified; `/System/Volumes/Data`
    on this Mac), `index disk on|off|unknown` (`mdutil -s /`; "Indexing enabled" is `on`, any
    "disabled" `off`, anything else or no `mdutil` `unknown`), `readable Desktop|Documents|
    Downloads yes|no|missing|unchecked` (`ls` of the folder, output discarded, since `[ -r ]`
    does not see macOS's privacy protection; `unchecked`, `Readability.notChecked`, with the
    `unchecked` argument, which looks at none of the three, not even `[ -d ]`; the format stays
    version 1, as the app always sends the script with its parser), `ready`. `FolderSearchHeader.unavailability(for:)`: no
    `mdfind` is `noSpotlight`, the home scope without a home `noHomeFolder`, indexing `off` for
    the scope's volume `indexingOff`; `unknown` is searched.
  - **Answers:** the kept paths (each starts with `/`, NUL-terminated, so a line feed in a
    name is kept), then one end record that never starts with `/`: `end <id> ok <count>`,
    `end <id> limited 50`, `end <id> error <code>` (also `unavailable`, `home`, `search` when
    `mdfind` failed or the pipeline broke, `timeout` when `mdfind` ran past the deadline).
  - **The noise rule** (fixed, in the script's `f`): left out when (a) it is the home's
    `Library` or below, and with `disk` any `/Users/<name>/Library` and below and the system
    roots `/System`, `/Library`, `/private`, `/usr`, `/bin`, `/sbin`, `/opt`, `/cores`, `/dev`
    and below (`/Applications`, `/Volumes` stay); (b) any component starts with `.`; (c) any
    component is `node_modules`, `DerivedData`, `Pods` or `__pycache__`; (d) any component but
    the last ends in `.app`, `.framework`, `.bundle`, `.plugin`, `.kext`, `.photoslibrary`,
    `.xcodeproj`, `.xcworkspace` or `.xcassets`. `build`, `dist`, `target` stay. Matching is
    exact (case-sensitive) on the path's bytes, in the C locale.
  - **The pipeline, the limit and the deadline** (three stages per query; the detail is in
    `FolderSearchScript`'s comment): the **producer** `sh -c "$k"` (its own process, so `$$`
    is its pid) writes `@<its pid>` first, runs `mdfind -0 …` in the background under a
    **4 s deadline** (`FolderSearchScript.searchDeadline`: a `sleep` timer that signals it)
    and writes the status marker `!<status>` after every path, or, at the deadline, kills
    `mdfind` (SIGKILL), reaps it and writes `\0!timeout` (the NUL ends a record `mdfind` may
    have left unfinished); the **filter** `xargs -0 -n 256 sh -c "$f"` applies the noise rule
    and passes `@…` and `!…` through; the **answer stage** `xargs -0 -n 52 sh -c "$g"` runs
    `g` once, as soon as 52 records are in (`@` and 51 kept paths, the limit, or 50 and the
    marker) or at the end of its input. `g` first sends the producer SIGTERM, which kills and
    reaps a `mdfind` still running (the limit stops it explicitly, also when everything after
    the 51st kept folder is left out and the filter writes nothing more) or releases a
    producer that is done; then it writes at most 50 paths and the end record (`limited` when
    a 51st was kept, `ok` for marker `0`, `error timeout`, else `error search`) and exits 255,
    which stops `xargs`. After its last record the producer closes its output and waits at
    most 1 s (`FolderSearchScript.answerSignalWait`) for that signal, so the pid `g` signals
    is still the producer's; its timers are reaped before it exits. Once `mdfind` is gone the
    filter reaches the end of its input (its later writes fail); the script reads the next
    line only once all three stages have ended, and writes `error search` itself only when no
    `g` ran (`xargs` exit 0). The deadline is below the channel's 5 s answer wait, so a slow
    Spotlight gets the host's `error timeout` on a process that stays usable. Stub `mdfind`s
    that print endless kept paths, 51 kept then endless left-out ones, or block are stopped,
    each with no stub left (tested). **Tools the script relies on**, all in the default macOS
    userland and on the noninteractive SSH `PATH`: `/bin/sh` (bash 3.2 in POSIX mode on
    macOS; the tests also run it under `dash`), `mdfind`, `mdutil`, `df -P`, `tail`, `ls`,
    `wc -c`, `xargs -0 -n`, `sleep` and shell builtins (`trap`, `wait`, `kill`). Behaviors
    verified on macOS: `wait` returns at once when a trapped signal arrives (bash and dash);
    `xargs -0` keeps line feeds inside arguments, drops empty records, does not run its
    utility on empty input (exit 0), and exits 1 whatever failed (an invocation's 255, a
    signal or another status), so only exit 0 says that no `g` ran; `xargs -x` with `-n` runs
    one argument per invocation on macOS, so it is not used (52 arguments are far below
    `xargs`'s default size).
  - **Disconnects:** over SSH, `close()` ends only the local ssh; on the host the script then
    finds its standard input at its end and its standard output gone. Idle in `read`, it
    ends at once. A query blocked in `mdfind` cannot see either while it waits (watching
    standard input during a query would need a second reader of it, which POSIX `sh` cannot
    have without consuming query lines, so it is not attempted): the deadline bounds it.
    **Worst case, a host-side query lives 4 s past its start**, plus the milliseconds its
    stages take to end (then `g` signals the producer and its first write fails, and the
    script's next read finds the end of input), 5 s if the answer stage never ran (the
    producer's 1 s wait); no `mdfind`, filter or timer outlives it. Tested by closing the
    pipes of a script whose stub `mdfind` blocks, with no signal sent: the stub and the
    script were gone after about 4 s, under bash and dash. The script (from the header's last
    record on), the producer and `g` stop at a failed write, so with SIGPIPE ignored they end
    just the same (checked by hand).
  - **Parser** (`FolderSearchOutputParser`, incremental): up to 64 KiB before the header are
    skipped (a login shell's greeting; the header's first record may end a garbage record);
    then the header strictly in order; then path records and end records; anything else is
    `unexpectedRecord`. Bounded: one record at most 16 KiB (a longer path is read to its end,
    left out and counted, like one that is not UTF-8; a longer header record is `badHeader`),
    one answer at most 50 path records (`tooManyPaths`), an `ok` count equal to the records
    before it and a `limited` one equal to 50 (`countMismatch`); an output that ends inside a
    record, the header or an answer is `truncated`. Ids are reported as written; the channel
    drops the ones it does not wait for. Paths are kept as found (a line feed included);
    I-10b must pass each through `Validation.workingDirectory` before offering it.
  - **Transport** (`FolderSearchTransport`; `ProcessFolderSearchTransport` in the app and the
    probe, `FakeFolderSearchTransport` in tests): This Mac runs `/bin/sh -c <script> muxfinder
    unchecked` by argv; This Mac's environment is this process's
    with `PATH` the system search path (so `mdfind` resolves in `/usr/bin` as on an SSH host)
    and without `TMUX`/`TMUX_PANE`; ssh gets `/usr/bin/ssh <D6 options> -T -- <destination>
    <D3 string>` with discovery's environment, no `-n` (standard input is the query stream),
    nothing that weakens host-key checking, the destination validated first. The process is a
    `StreamingProcess` (spawned like the runner's children: argv only, its own process group,
    default signals, descriptors 0–2 only); one dispatch queue reads standard output through
    the parser, so only parsed events are buffered and the first protocol error stops the
    reading; the events wait for their reader in a bounded buffer
    (`ProcessFolderSearchTransport.eventLimit`, 8, with room kept for the overflow error and
    the end): more waiting at once (a host writing answers nobody asked for, or a stalled
    reader) is `protocolError(.eventOverflow)`, after which the connection stops reading and
    ends the process as `close()` does, the end still delivered last (a flood of valid answers
    with no reader is tested); standard error keeps 4 KiB, used only to classify ssh's own
    failures (exit 255, `ErrorClassifier.sshFailureStatus`), never logged. `close()` closes
    standard input (the script ends at end of input), waits 2 s, sends the group SIGTERM,
    then SIGKILL 2 s later, and returns once the child is reaped; a child that exits by
    itself is reaped once its pipes close (at most 500 ms later), after SIGKILL to whatever is
    left of its group. No child outlives the channel (checked in tests and after every real
    run); if muxFinder dies, the closed pipe ends the script too (on an SSH host as
    *Disconnects* says).
  - **The channel** (`FolderSearchChannel`, an actor; clock `AttachClock`, transport
    injected; state `FolderSearchState`, read or streamed by `updates()`): `search(_:scope:on:)`
    on every edit; the first searchable text opens the script at once (before its debounce);
    the query is sent 150 ms after the last call (`Configuration.debounce`), only for the
    latest text, only once the header is in; at most one query in flight; an answer to an
    older text or to an id not waited for is dropped and counted (`droppedReplies`) and the
    latest text goes at once; the same text while its query is in flight changes nothing,
    and asked again once answered it is searched again. Waits: the header within 10 s of the
    start (discovery's 5 s connect timeout plus 5 s), each answer within 5 s of its line. A
    dead process, a timeout, an open or a write that fails, or a protocol error ends the
    process and counts one failure; only an answer resets the count. The first failure in a
    row opens a new process at once for the latest text (or, when nothing is pending, on the
    next query); a failure with one before it is reported (`failed`, with a code and message
    that hold no path) and stands until the text, scope or host changes, each change then
    making one new attempt; so an unreachable host shows its problem after at most two
    connect timeouts. The header's unavailability is shown at once and no query is sent; the
    script's own `unavailable`/`home` answers show the same, `search`, `timeout`
    (`searchTimedOut`) and the refusals show as failures without a reopen. A quiet minute
    without a request closes the process (not a failure); a host change closes it and forgets
    the header and the failures; `close()` ends everything and returns once every process is
    reaped. Results stay in memory only, never on disk.
  - **The scope** (D32): `preferences.json`'s `folderSearchScope`, `home` (the default, also
    when absent or unknown) or `disk`; I-10b passes it with each query, so a change applies to
    the next one.
  - **Probe:** `muxfinder-probe folders --local | --ssh <dest> --name <text> [--name …]
    [--scope home|disk] [--count-only | --paths] [--repeat <n>]` runs one channel, prints
    the header (the home only as present or absent), each query's status, count and latency,
    the open time, a latency summary and the child processes left after the close; names
    only by number and length; `--paths` only by hand, never in unattended runs; SIGINT and
    SIGTERM close the channel first (exit 128 + n); `--help` contacts nothing.
  - **Found in the real runs** (`docs/TESTING.md`, Phase I-10a): on an open channel a query
    answers in about 0.2–0.4 s on this Mac and on Saturno (median 0.31–0.39 s; a broad
    fragment's first query up to 1.7 s, its repeat 0.56 s), about the time of `mdfind`
    itself (0.23 s for `-count`); opening takes 0.06–0.1 s here and 0.8–0.9 s on Saturno
    (the SSH connection); a close takes 15 ms here and about 60 ms over SSH. Both hosts index
    `/` and the home's volume, and Desktop, Documents and Downloads were readable over SSH on
    Saturno. The three-stage pipeline keeps those times (0.12–0.46 s here, 0.26–0.41 s on
    Saturno; about 16 ms of its own per query with a stub `mdfind`), with no process left on
    either side.
  - **This Mac runs no readability check** (Phase I-10b, the orchestrator's call): there the
    `ls` would run as muxFinder's child and could make macOS ask for access to Desktop,
    Documents or Downloads the first time someone types a folder name, and the protected-folders
    note is about Remote Login's full disk access, which has no local counterpart; so This
    Mac's header says `unchecked` for the three (the probe prints "not checked") and the note
    is an SSH host's only. Whether This Mac's Spotlight answers to muxFinder leave protected
    folders out is owed to the manual checklist (item 24). The channel searches the text as
    given (the directory list's filter trims it; the folder search keeps spaces); the home
    folder for `~/…` shortening comes from the header.
  - **The UI** (Phase I-10b): New session's "Folders on <host>" section (D31) and one channel
    per window and host owned by the model (D34); Settings › Directories' "Search folders in:
    Home folder / Whole disk" (`SettingsModelFolderSearch.swift`, through `PreferencesStore`,
    applied at once, read again by the window for each query) and its "Missing a folder?"
    explanation. Only the menu bar app in normal mode has folder search
    (`AppEnvironment.folderSearch`, `SettingsEnvironment.preferences`, the same
    `PreferencesStore` as the session switcher shortcut's); every other mode reads no
    `preferences.json` for it and runs no Spotlight.

- **D37 — Detach other clients** (decided in Phase I-11a, 2026-11-06, from
  `autoclaude/processed/105-detach-other-clients.md` and the orchestrator's calls in *Phase
  I-11*; code in `Sources/MuxFinderCore/Attach/AttachCoordinatorDetachOthers.swift` and
  `DetachOtherClientsModels.swift`, tests in `DetachOtherClientsTests.swift`, the real run
  `muxfinder-probe e2e-detach-others`, `docs/TESTING.md` *Phase I-11a*). Keep this Mac's
  attachment of a session and have tmux detach the session's other clients, wherever they
  are: with two control-mode clients (iTerm2's on two Macs) neither registers activity, so
  under `window-size latest` tmux keeps the window at its old size and ignores both clients'
  resizes.
  - **The proof** (iTerm2 3.7.7, tmux 3.8, on This Mac and on Saturno; a `muxfinder-test-*`
    session with two windows attached through the coordinator's launch tab, buried, plus a
    plain `tmux -u -C` client of the harness's own):
    - **(a) `attach-session -d -t '<session id>'`**, sent through the launch tab's
      connection: tmux detached the plain client (`%exit`, exit 0 within 60 ms) and kept the
      connection attached, but iTerm2 answered the `%session-changed` tmux sends the sending
      client by closing and reopening the session's windows: locally both tmux tabs had new
      tab and session ids 201 ms after the call (none unchanged); on Saturno the connection
      had no tab at all 81 ms after it. Rejected.
    - **(b) by name, proven and chosen:** through the kept connection, its own client's name,
      the session's clients, then for each other client a check of its pid and session right
      before `detach-client -t '<name>'`. Both hosts 9 of 9: `detached(count: 1)`, the plain
      client `%exit` and exit 0 within 60 ms of the call's return, and over the next 2.15 s
      (9 looks) the same two tmux tabs and sessions, the launch tab still owning its
      connection, buried and in no tab, the connection still showing the session as its only
      client. After the review (*Phase I-11a review fixes* in `docs/TESTING.md`) the commands
      are, all read through the kept connection: `display-message -p '%s #{client_name}'`
      (tmux's clock, whole seconds since 1970, and the own client's name), `list-clients -f
      '#{==:#{session_id},<session id>}' -F '#{client_pid}:#{client_created}:#{client_name}'`
      (the session's clients with their creation times), the check `list-clients -f
      '#{&&:#{==:#{client_name},<name>},#{&&:#{==:#{client_pid},<pid>},#{&&:#{==:#{client_created},<created>},#{==:#{session_id},<session id>}}}}'
      -F '#{client_pid}'` (it must print that pid), then `detach-client -t '<name>'`; both
      hosts 9 of 9 again.
  - **The binding, and why it cannot be one command.** Verified on a private server (plain
    clients only) and in iTerm2 3.7.7's public source (`TmuxGateway.m`, `iTermAPIHelper.m`,
    read only; nothing copied):
    - tmux 3.8 answers the command `if-shell -F` inserts with a reply block of its own, marked
      `%begin … 1` like the sender's own commands (the inserted command shares the sender's
      command state); `a ; b` gives two blocks the same way. iTerm2 pairs every flag-1 block
      with the oldest command it is waiting for, so a guarded `if-shell -F '<condition>'
      'detach-client -t <name>'` would hand the second block to iTerm2's next command (with
      none waiting: "%begin with empty command queue", an alert and the connection ended).
      iTerm2 ignores a flag-0 block only when it ends with `%end`; a flag-0 `%error` ends the
      connection too. So no reply handling makes a guarded command safe.
    - Nor can one `if-shell -F` condition name the target client's session: in its
      `#{L:…}` client loop every client is evaluated against the sender's session
      (`session_id` is the sender's; on the private server a guard naming another session's
      id held for a client of that other session), so only `client_session`, the session's
      mutable name, could be compared. `detach-client -t` expands no format (`can't find
      client: #{client_name}`), and tmux detaches no client by pid or filter.
    - iTerm2 3.7.7 tolerates no tmux error for a command sent through its API (`SendCommand`
      goes through the gateway's error-intolerant path): on `%error` it shows its "tmux
      Reported a Problem" alert and ends the connection, and the API answer carries no
      output. So no command may fail: the read-only commands filter the server's clients
      (`list-clients -f`, never `-t '<session id>'`, which fails once the session is gone)
      and cannot fail; only `detach-client -t '<name>'` can, when no client has that name.
    - At the API boundary an answer counts only with its output: iTerm2 fills `output` (empty
      for a command that prints nothing) only on `%end`; a `SendCommand` answer without it
      (no `send_command`, or one without `output`) is `ITerm2Error.tmuxCommandFailed`, never
      an empty success (golden fixtures `tmux-send-command-response-empty`, `-no-output`,
      `tmux-response-ok-no-payload`). The attach's identity check retires a connection that
      answers so, as for an unreadable answer; the detach by connection records it.
    - **What remains** (D37's residual, narrowed as far as tmux 3.8 and iTerm2's pairing
      allow): the check of a client and its `detach-client` are two requests one round trip
      apart. Only a client that passed its check (one of this session's other clients, by
      name, pid, creation time and session id) can be affected, and only by what it does
      within that round trip: if it switches to another session, tmux detaches it from that
      session; if it ends, `detach-client` fails (`can't find client`), iTerm2 3.7.7 then ends
      the kept attachment with its alert, and the call reports
      `checkFailed(.send(.tmuxCommandFailed))`, counts it not and sends nothing more; if it
      ends and a new client takes its name in another session (one on the same terminal, or
      a `client-<pid>` with the same pid), that client is detached. Nothing is ever killed:
      a detach ends only a client's attachment, every session stays. No re-check after the
      detach could tell these apart from a plain detach (a detached client is gone from every
      listing, whichever session it was in), so there is no typed outcome for them.
    - A client's name, pid and creation time come only from the listing and are validated
      (`OtherClient`: `client-` and a canonical number, or `/dev/` and ASCII letters, digits,
      `.`, `_`, `-`, `/`, at most 255 bytes; a canonical positive pid; a canonical number of
      seconds) and single-quoted, like the validated session id; a listing naming any client
      that fails detaches nobody. A tty client's name is its terminal's path
      (`/dev/ttys003`), one without a terminal `client-<pid>`. Never `detach-client -a`
      (every other client of the server) or `-s` (the sender too), and never
      `attach-session -d` for this.
  - **The age rule covers every client detached.** Any other client may be an attachment in
    this Mac's iTerm2 whose tab would end within seconds of opening (iTerm2's short-lived
    session warning, D15), including one opened after the attachment snapshot, and tmux cannot
    tell which: so every other client the listing shows is left until it is
    `minimumLaunchTabAge` old before any check or detach. Its age is read on tmux's own
    clock, read before the listing (`%s`) against its `#{client_created}`, both whole
    seconds: the wait is `minimumLaunchTabAge + 1 s - (clock - created)` from the listing's
    answer, never below zero and never above `minimumLaunchTabAge` (the client existed when
    the listing answered, so a client created after the clock was read, or a creation time
    ahead of it, gets the whole `minimumLaunchTabAge`). A step of the host's wall clock
    between a client's creation and the read could shorten the wait; the cap and the snapshot
    wait for this Mac's attachments below stay as they are. Each client's check right before
    its detach then binds its creation time too.
  - **The call:** `AttachCoordinator.detachOtherClients(of: AttachTarget, confirmation:
    DetachOtherClientsConfirmation)`. The confirmation is a type of its own with one case,
    `.detachOtherClients(of: SessionKey)`; one for another key ends `notConfirmed` before
    anything runs (no discovery, no iTerm2 request, no state published). Then: discovery (the
    host's `uname -n` and server) and the attachment index (D16; the standard one when the
    coordinator's check is `.off`); a wait until every other attachment's tab in this Mac's
    iTerm2 is `minimumLaunchTabAge` old, counted as `detach(session:on:)` counts (D15); the
    attachment kept is the one Show tab focuses (`attach(_:)`'s choice: the first listed whose
    connection is still owned by its tab), the others are among the other clients; its
    identity check right before anything else is asked, as `detach(session:on:)`'s; the two
    reads (the own name with tmux's clock, the listing with creation times); the wait for
    young clients (the age rule above); then each other client's check and `detach-client`,
    each sent once (D13); the first failed request stops the call. Local and SSH hosts alike: everything travels through
    iTerm2's connection (no new ssh, script, file or request).
  - **Typed results** (`DetachOtherClientsResult.Outcome`): `detached(count:)` (the
    `detach-client`s tmux confirmed, answered with their output), `nothingToDetach` (no other client listed, or every one
    gone at its check), `notAttachedHere` (iTerm2 not running, no server, none mapped),
    `identityChanged` (another session or server, an answer through a client not in UTF-8
    mode, the own client missing from the listing, or every attachment's connection closed or
    re-owned; nothing detached), `checkFailed(DetachOtherClientsProblem)` (`attachmentCheck`,
    `identityCheck`, `clientListing`, `send`, with the problem; `send(.tmuxCommandFailed)`
    is a `detach-client` tmux did not confirm, never counted, the detaches confirmed before it
    kept in the count), `notConfirmed` and `cancelled`; with the kept attachment, the other
    attachments here, the other clients listed, the wait for young clients (`ageWait`), those
    gone before their check and detached, and `mayHaveSent`. No outcome triggers a
    refresh; diagnostics record kinds and counts only.
  - **The UI** (Phase I-11b; code in `Sources/MuxFinderUI/Model/AppModelSessions.swift`,
    `SessionPanels.swift`, `SessionProblem.swift`, `SessionActivity.swift`,
    `PopoverContent.swift`, `Views/SessionRowView.swift`, `SessionPanelViews.swift`,
    `Preview/AttachFixtures.swift`; tests in `Tests/MuxFinderUITests/DetachOtherClientsUITests.swift`):
    - **Popover only** (D32): the row's context menu, after "Detach from this Mac"; never in
      the session switcher.
    - **The offer rule** (`SessionRow.offersDetachOtherClients(isLive:clientCount:…)`, the one
      rule the row and the model use): "Detach other clients…" is shown only when the row is
      live (its host's last check succeeded: not stale, not unreachable, not still checking),
      this Mac's iTerm2 shows the session (`attachmentsHere`: the index's count for its key, at
      least 1 when only muxFinder's own record `attachedHere` says so) and the listing's
      `clientCount` is greater than `attachmentsHere`; hidden otherwise. While another action
      of the row is pending it stays shown, disabled (`SessionRow.isPending`), and
      `requestDetachOtherClients(_:)` refuses (the row's other items are ignored by the model
      then, as before).
    - **The hint:** while the rule holds, the "Open in iTerm2 here" badge reads "Open in iTerm2
      here · also attached elsewhere" (`SessionRow.openHereText`; VoiceOver's value adds
      "also attached elsewhere"). It fits on one line at the popover's width in both
      galleries. The switcher's rows share the popover's `SessionRow`, so their badge says the
      same; the action itself stays in the popover.
    - **The confirmation** (`PopoverPanel.detachOtherClients(DetachOtherClientsRequest)`) is
      drawn in place of the host list, as Move here's, with its keys (Return confirms, Esc and
      Cancel run nothing, the arrows, ⌘F and ⌘N do nothing): title "Detach other clients of
      “<name>”?"; that tmux detaches every other client of the session on its host and keeps
      this Mac's attachment, that they may be iTerm2 on other Macs, that nothing is closed and
      the session keeps running; "While another client is attached, tmux may keep the window at
      the other client's size."; the count when it opened, the listing's `clientCount` less one
      ("1 other client was attached when muxFinder last looked." / "<n> other clients were
      …"), with ", including <k> in this Mac's iTerm2" when this Mac has more than one
      attachment (`attachmentsHere` less one); "Cancel" and "Detach other clients".
      `confirmDetachOtherClients()` is the only caller of `detachOtherClients(of:confirmation:)`
      and passes `.detachOtherClients(of:)` for the key of the session the panel names, that
      session as the target. VoiceOver hears the dialog's title when it appears
      (`AppModel.announce`; Move here's dialog now announces its title the same way), and the
      dialog and its buttons are labelled.
    - **While it runs** the row shows "Detaching other clients…" (a spinner; up to about 20 s
      for young tabs and clients); clicks on the row are ignored; `shutdown()` cancels it
      (`cancelSessionActions`, kind "detach other clients").
    - **Results** (`AppModel.activity(after:wording:)`, failures through
      `SessionProblem.detachOtherClients(_:wording:)`, every line pairwise distinct, tested;
      these are iTerm2's, a plain terminal's are D38 *The UI (I-12d2)*'s: a run stopped partway
      says "Stopped after detaching N" or "Some may have been detached"):
      `detached(count:)` → "Detached <n> other client(s) — the session keeps running", then
      "(<m> had already left)" when `goneBeforeDetach` is above zero (a check mark, cleared when
      the popover opens again); `nothingToDetach` → "No other clients to detach — they had
      already left" (an information mark, not a failure, cleared the same way);
      `notAttachedHere` → "This Mac's iTerm2 no longer shows this session, so muxFinder
      detached no other client. …", "Refresh", muxFinder's own record of the attachment
      forgotten; `identityChanged` → "muxFinder detached no other client, because this Mac's tab
      of the session in iTerm2 changed, so nothing was sent. …", "Refresh";
      `checkFailed(.send(.tmuxCommandFailed))` → "tmux refused to detach one of the other
      clients (it may have just left), and iTerm2 may have ended this Mac's attachment of the
      session too. …", "Refresh"; the other `checkFailed` problems (the attachment check, the
      identity check, the client listing, another send failure) → a message of their own with
      "Try again" (which shows the confirmation again, or refreshes the host when it is no
      longer offered; popover only: the session switcher's row shows the failure without it)
      and "Refresh", and D23's fix-it for iTerm2 permission and API errors;
      `notConfirmed` → "muxFinder detached nothing, because the confirmation was for another
      session.", "Refresh"; `cancelled` → nothing. Every outcome but `cancelled` and
      `notConfirmed` refreshes the host afterwards, so `clientCount` and the offer follow.
- **D38 — Other terminal apps (plain mode)** (decided in Phase I-12a, 2026-11-06, from
  `autoclaude/processed/110-other-terminal-apps.md` and the orchestrator's calls in *Phase
  I-12*; code so far in `Sources/MuxFinderCore/Launch/PlainLaunch.swift` (`PlainLaunch`,
  `PlainClientIdentification`), `Sources/MuxFinderCore/Launch/PlainBoundCommands.swift`
  (`BoundSessionIdentity`, the bound local attach, `PlainClientDetach`) and
  `Sources/MuxFinderCore/Terminals/` (`AutomationPermission`, `TerminalCommandText`), tests in
  `PlainLaunchTests`, `PlainBoundCommandsTests`, `TerminalCommandTextTests` and
  `AutomationPermissionTests`, the probes `muxfinder-probe terminals list` and `plain-proof`,
  `docs/TESTING.md` *Phase I-12a* and *Phase I-12a review fixes*). Outside iTerm2 muxFinder attaches with plain tmux (one
  window, tmux's status bar, prefix keys and copy mode); iTerm2 keeps native control mode
  exactly as today. The helper runs it since I-12b2 (*Helper plain mode (I-12b2)* below) and
  the plain backend writes its requests since I-12c1 (*Plain backend (I-12c1)* below), and
  process ancestry tells which terminal app shows a session on This Mac since I-12c2 (*Open on
  this Mac (I-12c2)* below); nothing in the app calls either yet: I-12c3 wires them.
  - **The proof** (`plain-proof`, tmux 3.8, on This Mac and on Saturno, no terminal app and
    no iTerm2): plain clients on pseudo-terminals the harness opens itself, each the
    controlling terminal of its child's own session, 80 × 24, `TERM=xterm-256color`,
    everything printed on them drained and discarded. 9 of 9 steps on both hosts, every
    attach and detach bound as below (*Verified facts*, "Phase I-12a proof").
  - **The plain attach, bound to the recorded session** (since the review of I-12a). Every
    plain attach is one tmux command that the server checks and carries out with nothing in
    between: `tmux -u if-shell -F -t '<id>' '<condition>' "attach-session -t '<id>'"
    "run-shell 'exit 65'"` (`-d` before `-t` for a move here), never `-CC`. `<condition>`
    (`BoundSessionIdentity.condition`) is `#{==:…}` checks of `session_id`,
    `session_created`, `pid` and `start_time`, then `socket_path` and `session_name` when
    known, joined by `#{&&:…}`. tmux expands it against the session `-t` resolves (a missing
    id resolves leniently to none, and the condition is false) and runs the chosen command
    right after `if-shell` in the same command queue, so no server restart (session ids start
    over at `$0`), rename or other client can come between the check and the attach (the
    form of `CreatedSession.killIfUnchangedArguments`). When it is false nothing attaches or
    detaches and the client exits 65, the guard's "changed": `run-shell` of the constant
    `exit 65` sets an unattached client's exit status (tmux prints `'exit 65' returned 65` on
    that terminal and touches no pane). With no server tmux exits 1 and, unlike a bare
    `attach-session`, starts none. The id is single-quoted in the attach for tmux's parser
    (unquoted, `$3` reads as an environment variable). This Mac: the attach child `<tmux>`
    with `PlainLaunch.localAttachArguments(session:detachingOthers:)`; `plain-proof` binds all
    six fields of its own session's record (the name `muxfinder-test-*`), I-12b binds a
    request's four. SSH hosts: D17's `/usr/bin/ssh -t … -- <destination> <D3 string>` with
    `PlainLaunch.remoteScript`: the tmux locator; a token step (exactly six arguments, the
    sixth 36 bytes of `[0-9a-f-]`, else 68; then `set --` back to the guard's five); the
    guard's identity check (`LaunchGuard.check`, 64–68 as in D17, kept for its distinct
    codes); then the bound attach with the guard's four values (already checked to be
    `$<digits>` and decimal digits, so the format the script writes, `c="#{&&:…}"`, holds
    nothing else; a unit test checks its arguments are the local builder's for the same four
    values) and `exit "$?"`. tmux runs as a **child** of the `/bin/sh` that ran the check,
    never through `exec`, so that shell, whose argument list ends with the token, stays the
    client's parent for as long as it is attached. `PlainLaunch.remoteMoveHereScript` is the
    same with `attach-session -d`. Exit statuses are D17's (65 also when the session changed
    between the guard's check and the attach), except that a remote tmux killed by signal n
    comes back as the shell's 128 + n instead of ssh's 255 (not exercised). A detached plain
    client exits 0, and so do the shell and ssh (verified). Verified: on a private server the
    exact session's bound attach reached tmux's attach, while each of eight one-field-off
    identities, and a restarted server's session with the old id and name, exited 65 with
    nothing attached and no client detached (`PlainBoundCommandsTests`); in `plain-proof` a
    stale attach (the server's start time 1 s off) exited 65 and attached nothing on both
    Macs (locally the bound attach refused it, on Saturno the guard did, since both check the
    same values), and every real attach on both Macs went through the bound form. Nothing
    remains between the check and the attach.
  - **Confirmation on This Mac, by `client_tty`.** The launch's client is the session's client
    whose `client_tty` (also its `client_name`) is the launch's terminal: exactly one
    confirms, none is "not yet", two or more confirm nothing (`PlainClientIdentification
    .local`, over `list-clients -F` of every client filtered in Swift, so no run value enters
    a tmux format). Verified: one match (its pid the attach child's), none for a terminal with
    no client, two clients told apart, two clients on one terminal refused. A terminal's path
    is reused at once: when the process holding a terminal as its controlling terminal exits,
    macOS revokes the terminal, and the next pseudo-terminal opened gets the same
    `/dev/ttysNNN` (seen on both Macs). So a match counts only while the launch's helper still
    runs on that terminal: I-12c takes the terminal path and the attach child's pid from the
    helper's early report (requirement 5) and requires both.
  - **Confirmation over SSH, settled: reliable, by the token.**
    `PlainClientIdentification.remoteScript` runs over discovery's noninteractive ssh
    (BatchMode; a static script with three quoted arguments: override, session id, token;
    read-only `list-clients` and `ps`, no file written). For each client of the session it
    reads `ps -o ppid= -p <client_pid>` and that parent's `ps -ww -o args=`, `match` when the
    argument list ends with a space and the token. It prints only `match|other <pid>
    <created> <name>` lines and `end <count>`, never an argument list, and
    `PlainClientIdentification.remote` refuses a cut-off or malformed answer. Verified on
    Saturno: the launch's client confirmed, a token nobody carries matched none, two clients
    with different tokens told apart, two with the same token refused; one ssh connection per
    reading, 727–744 ms (median 733 ms). Why it is reliable: the token is a fresh random id
    per launch, present only in that launch's shell; that shell waits on the client and is
    its parent for as long as it is attached; a client whose shell died is reparented to
    launchd and never matches; nothing is written on the host. Its limits: a process of the
    same user on that host could forge an argument list ending with the token (the user's own
    trust boundary), and other users of that host can read the token with `ps` (it grants
    nothing: requests stay on this Mac, D2). So a remote plain attach ends **confirmed**, not
    "Opened in <app>". Remote client names are that host's terminals and are reused too (the
    move-here client got the first client's), so a client is carried forward by name, pid and
    creation time together.
  - **Detach, bound to the identified client** (since the review of I-12a; I-12a first used
    D37's two commands, a check and then `detach-client`, which could reach a client that took
    the checked one's terminal in between). One tmux command
    (`PlainClientDetach.arguments(of:in:)`, run with `tmux -u`): `if-shell -F -t '<id>'
    '<condition>' "detach-client -t '<name>'" "display-message -p muxfinder-not-this-client"`.
    `<condition>` is the session's (all six fields, the name included) and, in tmux's client
    loop `#{L:…}` (every attached client, the ones `detach-client -t` searches), exactly one
    client named `<name>`, and that client with the recorded `client_pid` and
    `client_created` attached to the session of that name (`client_session`: session names
    are unique on a server and the outer check binds the name to the id; inside the loop
    `session_id` is the target's, never the client's, so it cannot be compared there). The
    server runs `detach-client` right after `if-shell` in the same queue, so a client that
    ended, left, or whose terminal another client took (paths are reused at once) is never
    detached in its place. Outcome: exit 0 with no output `detached`; the marker line, or no
    server, `notThisClient` ("identity changed, nothing detached"); anything else `failed`.
    The tmux CLI locally, one BatchMode ssh call remotely (a static script with quoted
    arguments); never by closing a window. Only a name `OtherClient.isValidName(_:)` accepts
    is written, single-quoted for tmux's parser. Verified: on a private server with three
    control clients, the detach of one with its pid, creation time or name off, with any
    session field off, or of a client of another session, detached nothing; the exact one
    detached only it (exit 0), and once more found nothing (`PlainBoundCommandsTests`); in
    `plain-proof` on both Macs a stale detach (the client's creation time 1 s off) detached
    nothing, and the real one ended only its client (its child exited 0 by itself) in 9–11 ms
    locally and 714–717 ms over ssh (one connection); locally, while two clients shared a
    terminal and so a name, the detach of one detached nothing. **What remains:** nothing
    between the check and the detach. tmux names a client to `detach-client -t` by name only,
    so the binding rests on that name being unique among attached clients, which the same
    command checks. D37's residual stays only for iTerm2's control connection, where a
    guarded command cannot be sent.
  - **Move here, decided: `attach-session -d`, as D21.** A new plain launch whose attach is
    the bound `attach-session -d` (`localAttachArguments(session:detachingOthers: true)`,
    `remoteMoveHereScript`), not D37's per-client detach: it is one tmux command, done by the
    server as the new client attaches, so no client can come between a listing, a check and a
    detach, and it needs no listing, no age wait and no extra ssh connection. Bound, it
    detaches the session's other clients only while the session is exactly the recorded one:
    a move here with the server's start time 1 s off exited 65 and the other client stayed
    attached (both Macs). D37 rejected
    `attach-session -d` only for a command sent through iTerm2's existing control connection
    (iTerm2 closes and reopens its windows on the `%session-changed` tmux then sends it); a new
    plain client has no such reaction. D21's confirmation, its refusal while this Mac already
    shows the session (I-12c generalizes it to any terminal) and its single-flight rules stay.
    Verified on both Macs: the new client confirmed as the session's only client, the other
    client's child exited 0 by itself.
  - **Terminal.app's open form** (its dictionary, `sdef`, Terminal 2.15; the real run is
    owed): `do script <text>` with no `in` opens a new window running the text in the user's
    login shell and returns that window's tab; the text is D3's extension. A tab has no id,
    so the run records its window's `id` (an integer); the tab's `tty` (text) is the terminal
    the local confirmation compares. Focus kind `tty`: the window whose tab has the launch's
    `tty`, brought to the front (its `frontmost` or `index`, then `activate`). Never `do
    script … in` an existing tab or window, and never `do script in new tab` (it defaults to
    the frontmost window, the user's); never read `contents` or `history`. Close only that
    window, by its id, once its tab's process ended (`busy` false): a window with a running
    process asks first.
  - **Ghostty's open form** (its dictionary, Ghostty 1.3.1, and its docs; the real run is
    owed): `new surface configuration` with `command` the helper path and its constant mode
    word, and `wait after command` false (the helper's own wait for Return shows failures,
    D2); the launch id in `environment variables` (`KEY=VALUE`, under a fixed name I-12b
    chooses) if the owed run shows they reach the command, else as the last word of
    `command`; then `new window with configuration`, which returns the window (`id` is text,
    "Stable ID"; its tabs and terminals have ids too). The words are D2's characters, so the
    command means the same however Ghostty parses it: per its docs a command with arguments
    runs through `/bin/sh -c`, `direct:` skips the shell (no quoting, spaces or globs),
    `shell:` forces it, and it guesses when there is no prefix. The dictionary has no tty,
    pid or process for a terminal, so focus kind `windowID`: `activate window` (or `focus`
    its terminal) by the recorded id; close with `close window` by that id, once the helper
    ended. Never `input text`, `send key` or the mouse commands. Ghostty 1.3 or later
    (AppleScript); `macos-applescript = false` turns all of it off (how an event is answered
    then is owed).
  - **Permission.** Read with `AEDeterminePermissionToAutomateTarget(…, askUserIfNeeded:
    false)` for the bundle identifier (`AutomationPermission`: 0 granted, -1743 denied, -1744
    not determined, -600 target not running, else the raw status). It never prompts, never
    launches the app and sends no event. It is the permission of the app macOS holds
    responsible for the caller: a command run from this shell reads iTerm2's. On 2026-11-06
    `terminals list` showed iTerm2 3.7.7 running and granted, and Terminal 2.15 and Ghostty
    1.3.1 (`com.mitchellh.ghostty`) installed and not running (-600).
  - **Owed to the user** (*Unattended-run rules* 8: neither app was running, so no Apple event
    was sent and no window run made): with Terminal, then Ghostty, started by the user and
    `terminals list` showing `granted` for the app running the command, the steps in
    `docs/TESTING.md` *Phase I-12a* ("Owed": what `do script` returns and how `tty` reads,
    whether the window closes when its process ends; whether Ghostty's `environment
    variables` reach `command`, what its ids look like, and whether `direct:` works through
    AppleScript), and I-12c's `e2e-plain --terminal terminal|ghostty --local | --ssh
    saturno-m4`.
  - **Definitions (I-12b1)** (2026-11-06; code in `Sources/MuxFinderCore/Terminals/`:
    `TerminalDefinition`, `TerminalDefinitionParser`, `TerminalDefinitionProblem`,
    `TerminalDefinitionLoader`, `TerminalLaunchCommand`, `AppleScriptRunner`,
    `TerminalScriptCalls`, `TerminalAppFacts`; built-ins in `Resources/Terminals/`; tests in
    `TerminalDefinitionTests`, `TerminalDefinitionLoaderTests`, `TerminalLaunchCommandTests`,
    `AppleScriptRunnerTests`, `TerminalAppFactsTests`; `docs/TESTING.md` *Phase I-12b1*). Nothing in the app, the helper
    or the coordinator uses them yet (I-12b2, I-12c).
    **Schema 1**, strict (unknown keys refused at every level; so is a member name twice in
    one object, compared after its escapes are decoded (`duplicateKey`, checked by
    `JSONDuplicateNameScanner` before any value is read; UTF-8 text only, a UTF-16 file
    `notJSON`); the first problem reported):
    `id` `[a-z0-9-]`, 1–32 bytes, never `iterm2`; `displayName` 1–64 characters, no control
    character; `bundleIdentifier` dot-separated parts of ASCII letters, digits and `-`;
    `minimumVersion` dotted decimal (1–8 parts of 1–9 digits); optional `notes` (≤ 1 KiB, no
    control character but line feed and tab); `open` `{"kind": "appleScript", "script",
    "command": "shellText" | "words"}` (the script a name of `[A-Za-z0-9._-]`, ≤ 64 bytes, not
    hidden, ending `.applescript`) or `{"kind": "exec", "executable", "arguments"}` (a relative
    path with no empty, `.` or `..` part; at most 64 arguments, each literal or exactly one of
    `{helper}`, `{mode}`, `{token}`, a brace anywhere else refused, and each placeholder exactly
    once); `focus` `{"kind": "tty" | "windowID" | "app"}`, the first two only with
    `appleScript`; optional `keepsMinimumLifetime` (false). Built-ins: Terminal (`shellText`,
    focus `tty`, minimum 2.0) and Ghostty (`words`, focus `windowID`, minimum 1.3: the token is
    the last word of `command`, not an environment variable). **`words`** are each
    `[A-Za-z0-9._/+-]` (a helper path with a space or anything else is refused,
    "… Move muxFinder to /Applications …"); `shellText` is `TerminalCommandText`; an `exec`
    argv puts each value in as one whole argument and resolves `executable` inside the app
    LaunchServices found. **The loader** reads, never writes or creates: built-ins from a
    folder passed in (the bundle's `Contents/Resources/Terminals/`, which
    `scripts/build-app.sh` fills and the signature seals; no owner or mode rule); user
    definitions from `~/Library/Application Support/muxFinder/terminals/`, reached from `/` one
    `O_NOFOLLOW` component at a time (a symbolic link anywhere on the path, so also `/tmp` and
    `/var`, makes it unsafe; a path that does not exist, even through a link, is missing and
    no problem), the user's, mode exactly 0700, no extended ACL, else one problem and no user
    definition; each file (`*.json`, not hidden, in name order, at most 32, the rest problems)
    opened `O_NOFOLLOW | O_NONBLOCK`, a regular file of the user's, not group- or
    world-writable (readable is fine), no extended ACL, ≤ 64 KiB, its script under the same
    rules, ≤ 256 KiB and UTF-8 with no NUL. Two files of one folder with one id are both
    refused; a user id equal to a built-in's overrides it (`userOverride`). Every problem keeps
    the file's name and a plain sentence. **The handler contract** as the calls above; a
    handler raises -1728 for a window that is not there, and Terminal's `muxfinder_close`
    raises 1001 (and closes nothing) while a tab is `busy`; each script opens with a header
    saying muxFinder calls its handlers with values and never builds source. **The runner**
    (`AppleScriptRunning`, main actor): `NSAppleScriptRunner` compiles the text the loader
    read, once, and calls a handler in one `kASSubroutineEvent` with a list of texts; a reply
    is `nothing` (`typeNull`, a bare `return`), text, a list or another type by code; failures
    carry the OSA number, read whether `NSAppleScript` gives it as a number or as text (it gave
    "-1708" as text). `FakeAppleScriptRunner` records compiles and calls. **App facts**
    (`TerminalAppFacts`, behind `TerminalAppInspecting`): LaunchServices path and version, the
    minimum check (`meets`, `tooOld`, `unknown`, `notInstalled`), running, and the permission
    (`notNeeded` for `exec`). **Owed:** compiling and calling the built-ins (the first compile
    reads the app's dictionary, which may launch it, so no check of this phase compiled them):
    with the app running and `granted`, by the user or I-12c's `e2e-plain`; it shows whether
    Terminal's `do script` finds its window by the new tab's `tty`, whether `set index … to 1`
    with `selected` brings the tab forward, whether `do script` on a Terminal that was not
    running opens a second window, and Ghostty's ids, `activate window` and `close window`.
  - **Helper plain mode (I-12b2)** (2026-11-06; code in `Launch/LaunchHelperPlain.swift`,
    `Launch/PlainLaunchReport.swift`, `Launch/LaunchHelperProfile.swift`,
    `PlainLaunch.localAttachArguments(for:)` and `sshArguments(for:)`, `ProfileLaunch`'s plain
    members, `LaunchChildStandardInput`; tests in `LaunchHelperPlainTests`,
    `PlainLaunchReportTests`, `LaunchHelperProfilePlainTests`, `LaunchHelperPlainBinaryTests`;
    `docs/TESTING.md` *Phase I-12b2*; the file and request rules in D14 *Plain modes*). Nothing
    in the app or the coordinator writes a plain request yet (I-12c), and the terminal seam is
    I-12b3. `muxfinder-launch attach-plain <uuid>` takes only a plain request (its `terminal`
    a definition's id; `attach` and `attach-plain` refuse each other's with 72, nothing run).
    **The attach:** on This Mac the guard's check exactly as `attach` runs it, then the printed
    tmux with `PlainLaunch.localAttachArguments(for:)`, the bound `if-shell -F` over the
    request's four values (never `-CC`, never an unbound attach); on an SSH host D17's
    `/usr/bin/ssh -t -o ConnectTimeout=10 -- <destination> <D3 string>` with
    `PlainLaunch.remoteScript` and the request's launch id as the token, its standard error
    relayed. **A move here** is told apart exactly as for iTerm2: the request's
    `detachOtherClients: true` (D21; absent or `false` is a normal attach), which gives the
    bound `attach-session -d` locally and `remoteMoveHereScript` remotely. **Standard input:**
    the attach child gets the helper's terminal opened again read-write
    (`LaunchChildStandardInput.terminalReadWrite`: `ttyname` of the helper's descriptor 0,
    `O_RDWR | O_NOCTTY`, the same device checked; inherited as is when it is not a terminal),
    since a plain client's server draws through it; `attach`, `profile` and `ssh-setup` keep
    `inherited`, the runner's path for them unchanged. Exit statuses map as `attach`'s
    (`LaunchFailure.from`: 65 `sessionChanged`, the bound attach's refusal; 68 `guardUsage`,
    a bad token; 255 `sshFailed`; tmux's own), and the result is written exactly as `attach`
    writes it (a unit test compares both modes' results for every end). **Left out:** no OSC
    1337 (`Disinter`), no status report request, no wait for one, nothing buried or restored
    (`testSuppressDisinter` accepted and ignored). **Kept:** the result, the explanation, the
    wait for Return (`MUXFINDER_LAUNCH_NO_WAIT=1` skips it); the 10 s minimum only with
    `keepsMinimumLifetime: true` (none at all before a request is taken). **The early report**
    (`<uuid>.report.json`, D14 *Plain modes*) gives I-12c the terminal path and the attach
    child's pid and kernel start time, so a `client_tty` match counts only while that exact
    process runs. **`profile-plain <host id>`** is `profile` without `-CC`
    (`ProfileLaunch.plainTmuxArguments`, `-u new-session -A -s <escaped name>`;
    `plainRemoteScript`, the profile's remote script with `-CC` taken out of its one tmux
    line), its child on the terminal opened read-write, with `profile`'s nesting guard, host
    list, fallbacks to the login shell, hold and exit statuses (it has no request to carry
    `keepsMinimumLifetime`, so it holds as `profile` does); the per-host command is
    `LaunchHelperPath.plainProfileCommandLine(forHostID:)`. Test mode records both plain
    modes' attach child and its pid in the argv digest. **Verified** (no terminal app, no
    iTerm2): the built helper, on a pseudo-terminal of the test's (its standard input opened
    read-only, so the reopen is what lets tmux draw) against a `muxfinder-test-*` session on
    a private server, wrote a report naming that terminal, its own pid and its attach child
    (its child, the kernel's start time); the session had exactly that one client on that
    terminal, tmux drew on it, the bound `PlainClientDetach` ended it and the helper exited 0
    with a success result; with the reopen disabled tmux drew under 200 bytes and the check
    failed. The remote plain attach's real run is I-12c's `e2e-plain`.
  - **Terminal seam (I-12b3)** (2026-11-06; code in `Sources/MuxFinderCore/Terminals/`:
    `TerminalBackend.swift` (`TerminalBackend`, `TerminalAttachmentHandle`,
    `TerminalFocusResult`), `ITerm2TerminalBackend.swift`, `PlainTerminalWindows.swift`
    (`PlainTerminalWindows`, `PlainTerminalWindow`), `PlainTerminalWindowError.swift`,
    `PlainTerminalSeams.swift` (`TerminalProcessSpawning`, `DetachedTerminalProcessSpawner`,
    `DetachedChildReaper`, `TerminalAppActivating`, `RunningApplicationActivator`),
    `PlainTerminalFakes.swift` (`FakeTerminalAppInspector`, `FakeTerminalProcessSpawner`,
    `FakeTerminalAppActivator`); tests in `ITerm2TerminalBackendTests`,
    `PlainTerminalWindowsTests`, `PlainTerminalSeamsTests`; `docs/TESTING.md` *Phase
    I-12b3* and *Phase I-12b3 review fixes*). Nothing calls them yet: `AppModel`,
    `AppEnvironment.makeAttachCoordinator`, the self-tests, the probe and the refresh engine
    still call the coordinator directly, and no file under `Attach/`, `ITerm2/`, `Launch/`,
    the UI, the probe or the helper changed.
    **The seam** is the protocol `TerminalBackend` (`Sendable`): the coordinator's operations
    the app and the self-tests call, with their present signatures and result types
    (`attach(_:)`, `moveHere(_:confirmation:)`, `createAndAttach(_:onCreated:)` plus an
    extension without `onCreated`, `currentSession(named:on:)`, `detach(session:on:)`,
    `detachOtherClients(of:confirmation:)`, `state(of:)`), `terminal` (`LaunchTerminalApp`),
    and `focus(_:)` over `TerminalAttachmentHandle` (`iTerm2LaunchTab(sessionID:)` or
    `plainWindow(PlainTerminalWindow)`), answering `TerminalFocusResult`: `launchTab` with
    `showLaunchTab`'s `LaunchTabShowResult` unchanged, `plainWindowFocused`,
    `plainWindowFailed(PlainTerminalWindowError)`, or `handleOfAnotherTerminal`. No open here
    (I-12c); the connection detach `detach(connectionID:gatewaySessionID:launchID:)` stays
    iTerm2's own (the probe's and self-tests' cleanups). **The iTerm2 backend** is a wrapper,
    not a conformance (the worker's call: the coordinator stays untouched):
    `ITerm2TerminalBackend(coordinator:)` forwards every operation in the caller's task with
    the same arguments and returns the result unchanged; a plain window handle is
    `handleOfAnotherTerminal`, nothing run. Its tests run each scenario twice on fresh,
    identical coordinator fakes (directly, then through the backend) and compare results,
    published updates, the iTerm2 fake's calls, the launch store and discovery (launch ids,
    drawn at random, compared by position; the attachment index's concurrent identity checks
    of several connections in any order). **The plain window layer** `PlainTerminalWindows`
    (main actor, no default seams, so no check can reach a real one by omission) opens with
    the mode word `LaunchHelperMode.attachPlain.word`, in this order: the facts
    (`TerminalAppFacts`: `notInstalled`, `tooOld`, `unknown` and a permission read as `denied`
    are typed failures with nothing compiled, sent or started; `notDetermined`,
    `targetNotRunning`, `granted` and any other status go ahead, the worker's call for
    `other`: the event's own answer then decides), the launch command for the definition's
    form (refused with its `TerminalLaunchCommandError`, nothing compiled), then for
    `appleScript` the script compiled once per `LoadedTerminalDefinition` for the layer's
    lifetime (a reloaded definition with another script compiles again; a failed compile is
    not kept) and `muxfinder_open`, its reply read strictly into `PlainTerminalWindow` (the
    `LoadedTerminalDefinition` that opened it, `openedBy`, its `definitionID` derived; window
    id, tty), or for `exec` the spawn. A focus or close also refuses an app that is not
    running (`appNotRunning`, nothing compiled or sent: an event would launch it). **The
    opener** (review fix): a focus or close takes only a window the given loaded definition
    itself opened, `LoadedTerminalDefinition` compared whole (definition, source, file name,
    script): another id's window is `windowOfAnotherTerminal`, a window another loaded
    definition with the same id opened (a user override of a built-in, or the definition
    loaded again with another bundle identifier or script) is `definitionChanged`, both
    before anything is read, compiled or sent, so a window's id or tty never reaches another
    app or script; the same files loaded again give an equal value and still match.
    **Focus:** `tty` → `muxfinder_focus("", tty)`, `windowID` → `muxfinder_focus(id, "")`, a
    window without that value `windowLacksFocusValue`; `app` →
    `TerminalAppActivating` (`NSRunningApplication.activate(options:)` on the first running
    instance; no Apple event, no facts read, never a launch; `notRunning` → `appNotRunning`,
    `refused` → `activationFailed`). **Close** only by an id this layer's own open recorded
    for that same loaded definition (each record bound to it; the newest 64,
    `rememberedWindows`; else `notOpenedHere`), no id `windowHasNoID`, through
    `muxfinder_close`: 1001 `windowBusy` (kept), -1728 `windowGone` (forgotten), any other
    failure kept, success forgotten. **Forgetting** (review fix): a focus answered -1728
    forgets that window's record as a close does, so its stale id is never closed; an app
    seen not running (by any facts read, an open's included, or the activator's
    `notRunning`) has every record of its bundle identifier forgotten (compared without
    regard to case), whichever loaded definition opened them, since window ids are not
    stable across a restart of the app. Forgetting only ever leaves a window open. Any
    handler's -1743 is `permissionDenied`; -1728 from `open` stays `scriptFailed`. **The
    spawn** (`DetachedTerminalProcessSpawner`, behind `TerminalProcessSpawning`): `posix_spawn`
    with the argv `TerminalLaunchCommand.execArgv(_:inApp:)` builds (never a shell),
    `POSIX_SPAWN_SETSID` (a session and process group of its own, no controlling terminal, so
    no signal for muxFinder's group or terminal reaches it), standard input, output and error
    on `/dev/null`, `POSIX_SPAWN_CLOEXEC_DEFAULT`, default signal dispositions, and the layer's
    environment (this process's by default). It returns right after the spawn and never
    signals the program; `DetachedChildReaper` (one dispatch process source per child on a
    serial queue, `waitpid(WNOHANG)` at its exit, also for an exit before the watch) reaps it,
    so it is never left a zombie, and launchd adopts it when muxFinder quits first (a hermetic
    test on `/bin/sleep` and `/usr/bin/true`). XNU posts the exit event before the child is a
    zombie, so the wait may answer 0 first (review fix): the child then stays pending and is
    waited for again after 1, 2, 4, … ms, at most 1 s apart, until the wait answers its pid
    or a failure other than `EINTR` (`ECHILD`: nothing left; `EINTR` waited again at once);
    only then is its watch dropped. A bounded backoff on the reaper's queue rather than a
    blocking `waitpid` thread per child (the fix's call: no thread held for a terminal
    program's lifetime); the wait is a seam (`DetachedChildReaper(wait:)`, the spawner's
    internal `init(reaper:)`) so tests force the 0 answers. **Failures** are one enum,
    `PlainTerminalWindowError` (18 cases, each with `kind` and a plain sentence naming the
    definition's display name), never retried (D13). **Left to I-12c:** the plain backend's
    conformance (confirmation from the early report, detach and Move here through tmux, open
    here for every terminal), moving the app, self-tests and probe onto the seam with the
    backend picked from the terminal setting, a fake backend if the UI tests need one; and,
    still owed as in I-12b1, compiling and calling the built-in scripts for real.
  - **Plain backend (I-12c1)** (2026-11-06; code in `Sources/MuxFinderCore/Terminals/`:
    `PlainTerminalBackend.swift` (the actor and its attach), `PlainTerminalBackendDetach.swift`
    (detach, "Detach other clients…"), `PlainTerminalBackendModels.swift`
    (`PlainTerminalWindowLayer`, `PlainLaunchRequestStore`, `PlainClientRecord`,
    `PlainAttachment`, `PlainDetachResult`), `PlainTmuxCommands.swift` (`PlainTmuxCommands`,
    `PlainTmuxCommandFailure`, `PlainClientPresence`, `PlainSessionClients`),
    `PlainTerminalBackendFakes.swift` (`FakePlainTerminalWindowLayer`); outside it, additively:
    `Attach/AttachSharedSteps.swift`, the result types in `Attach/AttachModels.swift` and
    `Attach/DetachOtherClientsModels.swift`, `PlainClientDetach.condition(of:in:)` (the detach's
    arguments unchanged) and, as a review fix, `PlainClientDetach.arguments(of:keeping:in:)`
    and `condition(of:keeping:in:)` (below), and the minimum `MuxFinderUI` switches; tests in
    `PlainTerminalBackendTests`, `PlainTerminalBackendDetachTests`,
    `PlainTerminalBackendEndToEndTests`, the review fixes' also in `PlainBoundCommandsTests`;
    `docs/TESTING.md` *Phase I-12c1*). It does what the
    calls for I-12c1 say; nothing calls it yet (`AppModel`, `AppEnvironment`, the self-tests, the
    probe and the refresh engine still call the coordinator: I-12c3). **The worker's calls:**
    - *An actor*, `PlainTerminalBackend`, one per `LoadedTerminalDefinition` (`terminal` is
      `.plain(definitionID:)`), with the coordinator's own pattern (flights, waiters, pending
      launches, published `AttachUpdate`s, `AttachCoordinator.Configuration`'s budgets), hopping
      to the main actor only for the window layer's open and focus.
    - *The window layer behind a protocol*, `PlainTerminalWindowLayer` (main actor, `Sendable`;
      open and focus only, since the backend never closes a window), to which
      `PlainTerminalWindows` conforms unchanged (declared in its own file: Swift wants a
      `Sendable` conformance next to the class). Why: tests drive every open failure directly,
      and the end-to-end test's open starts the real helper on a pseudo-terminal of its own
      (`FakePlainTerminalWindowLayer.onOpen`), with no `exec` definition or spawner bent to it.
    - *The launch files* through `PlainLaunchRequestStore` (`LaunchRequestStore` plus
      `peekReport`), which `LaunchStore` already meets; no new writer was needed
      (`writeRequest` writes `terminal` and `keepsMinimumLifetime`). Results are peeked while
      confirming, while settling earlier launches and while checking attachments; only the
      detach, once its client was detached, takes the result (as the coordinator's detach does;
      the report goes with it). Every other file goes with the sweep.
    - *tmux, locally and remotely*, through `PlainTmuxCommands` over the `ProcessRunner` seam:
      one static script (`TmuxLocator`, the host's override as `$1`, then `exec "$t" -u "$@"`)
      run as `/bin/sh -c <script> muxfinder <values…>` with the local environment minus `TMUX`
      and `TMUX_PANE`, or over D6's `/usr/bin/ssh` (BatchMode) with the D3 string, exactly as
      discovery runs; the remote token reading is `PlainClientIdentification.remoteScript`.
      Bounded at 12 s. Locally a listing with tmux's "no server" error is a listing with no
      client (the helper's result then says the session is gone). Failures are
      `PlainTmuxCommandFailure` (no output or arguments kept).
    - *Readings start once the early report exists, locally and remotely*: the report shows
      the helper took the request and started its attach child, so no ssh connection is spent
      before; a remote launch whose report never comes stays unconfirmed (still waiting, then
      the wait limit). A local candidate counts only when its `client_pid` is the report's
      attach child and `ProcessStartTime.of` that pid (a seam, `processStartTime`) is the
      report's start time. A reading that fails ends the attach `clientCheckFailed` (as the
      coordinator's failed connection listing does), unless the helper's result exists by then.
      *Review fixes (2026-11-06):* a reading that confirms counts only if the helper's result
      still does not exist once it returns (a remote reading can see the client just before
      the helper ends; the attach then ends as the result maps); and the first report read is
      kept for the whole wait (the sweep, this launch's or another attach's, removes reports
      after 120 s while a remote wait goes on to 300 s), so later polls use it with or without
      its file, and a file that differs from it (a report is never rewritten) is
      `launchStore(fileMalformed)`, never a confirmation.
    - *An earlier launch that may still attach* (its window opened, its request not withdrawn
      before a helper took it, no client and no result seen) is waited out by every new attach
      or move here of the session, not only by a move here as in the coordinator: the plain
      backend has no attachment index that would find what a late helper attached. It settles
      only by its helper's result; unsettled within the confirmation budget, the new call fails
      `earlierLaunchPending` with nothing opened.
    - *The attachment's liveness*, the calls' "read-only bound check": `PlainClientPresence`,
      `if-shell -F -t <id>` with `PlainClientDetach`'s condition and two constant
      `display-message -p` markers (`muxfinder-client-present`, `muxfinder-not-this-client`).
      An attach checks it (after a file-only peek at the helper's result) before reusing an
      attachment; present focuses the window (`plainFocused`), gone drops the attachment, a
      check that cannot run fails `clientCheckFailed` with nothing opened. Limitation: a session
      whose name holds `{`, `[` or `]` cannot be bound by name (`CreatedSession.formatLiteral`),
      so its attachment's check and detach are `notWritable` until its helper ends (open
      question for I-12c3/I-12d: confirm such a session at all, or fall back to the helper's
      liveness).
    - *Detach outcomes:* `detached` (the attachment dropped, the helper's result waited for
      within `resultBudget` and taken), the bound check's refusal `notSent` (dropped too), a run
      that failed `notClosed` (kept: it may have run), a command that cannot be written (a
      session name with `{`, `[` or `]`) `checkFailed(clientCheckFailed(notWritable))`, no
      attachment `nothingAttached`, nothing run.
    - *"Detach other clients…"*: one read-only command, `display-message -p '%s' ; list-clients
      -F PlainClientIdentification.localFormat` (tmux's clock and every client, filtered in
      Swift, `PlainSessionClients`); the kept client is the attachment's by name, pid and
      creation time (missing: `identityChanged`); D37's age guard `OtherClient.ageWait` with
      `minimumLaunchTabAge`; each other client the bound `PlainClientDetach`, whose condition is
      the server-wide check of name, pid, creation time and session in the same command
      (stronger than D37's two requests), a failed run stopping the call (`plainDetach`, which
      `mayHaveSent` counts). *Review fix (2026-11-06; the kept client was checked only in the
      listing, so one that ended, switched sessions or was detached during the age wait left
      the session with no client of ours):* each detach is
      `PlainClientDetach.arguments(of:keeping:in:)`, whose condition adds the kept client's
      same two checks (exactly one client of its name, with its pid and creation time, in the
      session) after the detached one's, composed from the same builders
      (`PlainClientDetach.clientChecks`, no other runtime value; `nil` when both have one
      name), so the server refuses the detach once the kept client is gone or elsewhere. A
      refusal is told apart by the read-only `PlainClientPresence` of the kept client: present
      counts the other as gone before its detach; not present drops the attachment and ends
      the call `identityChanged`, nothing more sent; a check that cannot run is
      `plainClientListing`. Right before each detach the attachment must still be the
      backend's record of the session with no helper result (a file-only peek), else
      `identityChanged`, nothing more sent. The detaches tmux confirmed before such a stop stay
      counted in `detachedClients` (`identityChanged` reused; the plain wording says how many
      were detached, D38 *The UI (I-12d2)*).
    - *Result types, extended additively with new cases* (an optional field could not carry a
      plain `confirmed` without overloading iTerm2's connection id): `AttachState`
      `plainLaunched(window:)`, `plainStillWaiting(window:)`, `plainConfirmed(client:)`,
      `plainFocused(client:)`; `AttachFailure` `terminalWindow(PlainTerminalWindowError)`,
      `cannotConfirmHere`, `clientCheckFailed(PlainTmuxCommandFailure)`,
      `alreadyOpenInTerminal(window:)` (a move here while the backend's own attachment is live);
      `DetachOtherClientsProblem` `plainClientListing`, `plainDetach`; and optional fields
      `AttachResult.plainWindow`, `plainClient`, `plainWindowFocus` (with `plainWindowHandle`),
      `SessionDetachResult.plainDetach`, `DetachOtherClientsResult.keptPlainClient`. The
      terminal-neutral failures are reused (`timedOut`, `waitLimitReached`, `helperEnded`,
      `helperFailed`, `sessionGone`, `sessionChanged`, `launchStore`, `earlierLaunchPending`,
      `moveHereNotConfirmed`, `cancelled`; a plain terminal's wording is D38 *The UI
      (I-12d2)*'s). `isConfirmed` and
      `isFocused` (so `isAttached`) hold for the plain counterparts. Timings: `connected` is
      the report first seen, `activated` the window's focus.
    - *Factored out of the coordinator* (`AttachSharedSteps`, its behaviour unchanged): the
      revalidation by discovery, the current session by name and D18's creation with its
      diagnostics. Not factored: the flight and pending-launch bookkeeping (entangled with the
      coordinator's iTerm2 state; the plain backend keeps the same rules apart, the conflict
      rule above aside), D21's confirmation check (one comparison) and D37's per-client checks
      (iTerm2 commands; the plain backend's is `PlainClientDetach`).
    - *UI, the minimum that compiles:* `SessionActivity` shows `plainLaunched` and
      `plainStillWaiting` as "Waiting for iTerm2…" (a plain window has no launch tab for "Show
      tab"), `plainConfirmed` and `plainFocused` as their counterparts; `AppModel.finishAttach`
      shows them likewise and records no `AttachmentRecord` (I-12c3); `SessionProblem` gives
      `alreadyOpenInTerminal` the recoveries of `alreadyAttachedHere`, the other three "Try
      again", and the two problems sentences like `clientListing` and `send`. The UI tests'
      exhaustive `FailureMessageTests.caseIndex` gained the four new cases so it compiles (its
      20 samples and counts unchanged); a new test checks the plain messages.
    - **Verified** (no terminal app, no iTerm2, a private tmux server): the built helper, started
      by the fake open on a pseudo-terminal of the test's, was confirmed by the backend from its
      report and `list-clients` (real `DiscoveryProbe` and `PlainTmuxCommands`); attaching again
      focused the window through the real presence check; "Detach other clients…" detached a
      second plain client and kept the backend's; the backend's bound detach ended only its own
      client (a third stayed attached) and the helper exited 0 with a successful result; about
      1 s, stable over five runs. Review fixes, on a private server with control clients K, O1
      and O2 on one session: the detach of O1 keeping K with K's pid, creation time or name off
      detached nothing, keeping K it detached O1 alone; with K switched to another session, and
      again with K ended, the detach of O2 keeping K detached nothing, while O2's detach with no
      kept client went through. Each review fix's regression tests fail with that fix reverted.
      **Owed:** the real runs with Terminal and Ghostty and the remote plain attach (I-12c3's
      `e2e-plain`).
  - **Open on this Mac (I-12c2)** (2026-11-06; requirement 7, core only; code in
    `Sources/MuxFinderCore/Terminals/ProcessTable.swift` (`ProcessTableEntry`,
    `ProcessTableLookup`, `ProcessTableReading`, `SystemProcessTable`),
    `ProcessTableFakes.swift` (`FakeProcessTable`), `LocalClientAttribution.swift`
    (`LocalTerminalApp`, `LocalClientUnmappedReason`, `LocalClientAttribution`,
    `LocalAttachment`, `LocalClientAttributing`, `LocalClientAttributor`); additively in
    `Tmux/ProbeScript.swift`, `ProbeReport.swift`, `ErrorClassifier.swift`, `TmuxModels.swift`,
    `Refresh/HostSnapshot.swift`, `RefreshCoordinator.swift`, `Attach/AttachModels.swift`,
    `Terminals/TerminalBackend.swift`, `PlainTerminalBackend.swift`,
    `ITerm2TerminalBackend.swift`, `PlainTerminalSeams.swift`, the two minimum `MuxFinderUI`
    switches and the probe's `local-clients` (`LocalClientsCommand.swift`); tests in
    `ProbeClientFieldsTests`, `LocalClientAttributionTests`, `LocalClientsRealTests`,
    `RefreshLocalAttachmentsTests`, `PlainTerminalBackendOpenHereTests`; `docs/TESTING.md`
    *Phase I-12c2*). It does what the calls for I-12c2 say; nothing in the app, the self-tests
    or the existing probe commands calls it yet (I-12c3). **The worker's calls:**
    - *Discovery's client record* gains `client_created` and `client_tty` (format 1 kept, the
      script static and read-only). **Review fix:** both come in a `tty` record of their own
      right after the client's line, framed like D31's `path` record (`tty`, the nonce, the
      client's pid, the creation time, the terminal, printed as nothing over 255 bytes, and the
      nonce again as end mark), because tmux takes `client_tty` from what the client sends and
      one with a line break, raw on the client line as first written, failed the whole host's
      discovery; the parser takes everything up to the first tab, nonce and line feed as the
      terminal, so a hostile one only makes that client's path `nil` (the pid and creation time
      come before it), and `ProbeReportParser.maximumReportSize` counts one such record
      (`maximumTerminalRecordLength`, 324 bytes) per client. A five-field client line without
      the record (an older probe, a fake) still parses with both `nil`, a six-field one stays
      malformed, and a misplaced `tty` record fails the report like a misplaced `path`.
      `ClientSummary.terminalPath` (`ProbeReportParser.terminalPath(_:)`:
      `/` first, bytes 0x21–0x7E, at most 255) and `createdAt` (canonical decimal), optional,
      so `discover` JSON shows them when known (left out when `nil`; tmux prints an empty
      `client_tty` for a client with no terminal, such as `tmux -C` on a pipe). Every existing
      fixture kept its five-field lines and its expectations.
    - *The process table* behind `ProcessTableReading` (`process(_:)` → `found`, `gone`,
      `unreadable`; `terminalDevice(atPath:)`, `stat`'s `st_rdev` of a character device).
      `SystemProcessTable` reads `sysctl` `KERN_PROC_PID` (parent, `p_starttime`, `e_tdev`;
      `NODEV` is none; a pid with no process answers no data), `proc_pidpath` and
      `NSRunningApplication(processIdentifier:)` (thread-safe, `Sendable`: no main-actor hop),
      then `sysctl` again: an entry that changed meanwhile is `gone`. Verified on Neptuno
      (2026-11-06): `proc_pidpath` and `sysctl` read root's processes (`launchd`, `login`) as
      the user, and `NSRunningApplication` names iTerm2 by pid from a command-line process.
    - *The walk* (`LocalClientAttributor.attribute(_:)`) checks the client first: no usable
      terminal path or creation time is `incompleteClient` (a reason the calls did not list,
      added so the probe's counts say why), another or no controlling terminal is
      `terminalMismatch`, a start later than `client_created` + 1 s is `startedAfterClient`.
      Then up the parents, at most 64 steps; pid 1 or 0 or a repeated pid is
      `noTerminalAncestor` (launchd is never read, and a cycle counts as the chain's end); a
      parent that started after its child is a reused pid, `processGone`. Bundle identifiers
      compare without ASCII case (as LaunchServices does); the app keeps its process's
      identifier (iTerm2's constant for its job server) and `definitionIDs` in loader order.
      iTerm2's job server is an executable named `iTermServer-*` directly in
      `~/Library/Application Support/iTerm2` of the real home (`getpwuid_r` for the real uid, so
      `HOME` and `CFFIXED_USER_HOME` do not move it; injected in tests).
    - *Types:* `LocalTerminalApp` (`init?` refuses an app that is neither iTerm2 nor any
      definition's, so `terminal` is always `iterm2` or the first definition's plain one),
      `LocalAttachment` (app, client pid, terminal path, control mode) and
      `LocalAttachment.counted(_:indexInUse:)`, the per-session rule (iTerm2's control-mode
      clients dropped only with `indexInUse`). `LocalClientAttributing.localAttachments(of:on:
      indexInUse:)` returns `[:]` for an SSH host without reading anything, and only sessions
      of the given host's id.
    - *The refresh engine:* `RefreshCoordinator(localClients:)` (after `attachmentIndex`,
      default `nil`). The attempt's own detached task attributes This Mac's listed sessions
      right after discovery (`indexInUse` is "an attachment index is configured"), and the
      applied snapshot's sessions carry `HostSnapshot.Session.localAttachments` (default
      empty; a stale snapshot keeps its last success's, like its sessions).
    - *Focus:* the new handle `TerminalAttachmentHandle.app(LocalTerminalApp)` (its `terminal`
      is the app's) and `TerminalFocusResult.appActivation(TerminalAppActivation)`. It reuses
      I-12b3's `TerminalAppActivating` (now `Sendable`) and `RunningApplicationActivator`
      (`NSRunningApplication`, first instance not terminated, `activate(options: [])`; not
      running → `notRunning`, nothing launched; no Apple event), through
      `RunningApplicationActivator.activate(_:with:)` on the main actor. Every backend focuses
      an `.app` handle: the plain backend and, additively, `ITerm2TerminalBackend(coordinator:
      appActivator:)` (`nil` → the real activator), whose attach and other operations are
      unchanged.
    - *The plain backend's attach* (`PlainTerminalBackend(localClients:appActivator:)`, both
      default `nil`, so every I-12c1 test and the I-12c1 behaviour are unchanged; I-12c3 passes
      the attributor): after its own record (step 2), only for `attach(_:)` on This Mac (not a
      move here or a create-and-attach), the revalidated session's clients are attributed once,
      off the actor, with `indexInUse: false`; the first attributed client in client order
      ends the attach `AttachState.appFocused(app:)` (kind `appFocused`; `isFocused` and
      `isAttached` hold) with `AttachResult.localAttachment` and `appActivation`, published as
      `requested` → `appFocused`, nothing written or opened, whatever the activation's outcome.
      The row shows it as `.focusedApp` ("Already open in Terminal on this Mac — brought it
      forward", D38 *The UI (I-12d2)*).
    - *Remote sessions:* an SSH host's clients are never attributed (their processes run on
      that host), so a remote session attached by hand in a plain terminal is "attached
      somewhere" unless the plain backend's own record or D16's index says otherwise.
    - **Verified** (hermetic, plus read-only real runs): on a private tmux server a plain
      client on a pseudo-terminal of the test was discovered with that terminal and a creation
      time of now, its process held that terminal and started before it, the walk ended in
      iTerm2 or no terminal ancestor (never a refusal), a creation time 10 s early and another
      terminal were refused, and a control client with no terminal was `incompleteClient`.
      Real runs (2026-11-06; counts in `docs/TESTING.md` *Phase I-12c2*): `discover --local`
      and `--ssh saturno-m4` show both fields for every client; `local-clients` traced This
      Mac's one control-mode client to iTerm2. **Owed:** a client in Terminal and in Ghostty
      traced for real (neither is used here; I-12c3's real runs), and the attributor wired
      into the app (I-12c3).
  - **Onto the seam (I-12c3a)** (2026-11-06; requirements 7, 8 and 12; code in
    `Sources/MuxFinderCore/Terminals/TerminalChoice.swift` (`ChosenTerminal`,
    `TerminalChoiceUnavailable`, `TerminalChoiceResolution`, `TerminalChoice`),
    `AttachCommandOptions.swift` (`AttachCommandOptions`, `PlainRunGate`),
    `Sources/MuxFinderUI/Model/TerminalEnvironment.swift` (`TerminalEnvironment`,
    `TerminalCatalogCache`), `AppModelTerminal.swift`; changed: `Config/PreferencesStore.swift`
    (`Preferences.terminal`, `TerminalSettingStoring`), `Refresh/RefreshCoordinator.swift`
    (`setAttachmentChecksEnabled(_:)`), `PlainTerminalBackend.swift` (the name refusal),
    `TerminalAppFacts.swift` (`versionCheck(of:minimum:)`), `Attach/AttachModels.swift`
    (`unsupportedSessionName`), `Shell/Validation.swift`, `Attach/SSHSetupLauncher.swift`
    (`notUsedWithThisTerminal`), and in `MuxFinderUI` `AppEnvironment.swift`, `AppModel*.swift`,
    `SessionProblem.swift`, `SettingsModel*.swift`, `SettingsResults.swift`,
    `SSHSetupActions.swift`, `PopoverContent.swift`, `SelfTest/SelfTestDriver.swift`; the
    probe's `AttachCommand.swift` and `NewSessionCommand.swift`; tests in
    `TerminalChoiceTests`, `TerminalSeamCoreTests` (`RefreshAttachmentChecksTests`,
    `PlainTerminalBackendNameTests`, `AttachCommandOptionsTests`) and the UI's
    `TerminalSeamTests`; `docs/TESTING.md` *Phase I-12c3a*). It does what the calls for
    I-12c3a say. **The worker's calls:**
    - *The resolution* is `TerminalChoice.resolve(stored:iTerm2Installed:definitions:
      versionCheck:)`, pure: absent → `iterm2` when installed, else `terminal`
      (`candidateID`), resolved like a stored value; `iterm2` needs iTerm2 installed, else
      `unavailable(notInstalled)` (never Terminal instead); a definition id needs a loaded
      definition (`unknownID`), its app installed (`notInstalled`) and a version meeting the
      minimum (`versionTooOld`, and **`versionUnknown`** for a missing or unreadable version,
      a reason the calls did not list: the window layer's open refuses it too, so it is never
      a pass). Only the candidate definition's app is asked (LaunchServices'
      `TerminalAppFacts.versionCheck(of:minimum:)`; no permission read, no event).
      `TerminalChoiceUnavailable` (an `Error`: the id, the reason, a neutral sentence quoting
      the id cut to printable ASCII) is the typed failure; the model shows it as
      `SessionProblem.terminalUnavailable(_:wording:)` ("Open Settings"; since I-12d2 the
      sentence names a loaded definition's terminal).
    - *The key* `terminal` in `preferences.json` (D32): a string kept as stored; a value that
      is not a string reads as the empty id (so unavailable, never the default); written only
      by the setter through a new `TerminalSettingStoring` (a sub-protocol of
      `PreferencesStoring`, so the existing test fakes of `PreferencesStoring` needed no
      change); `nil` removes the key. A preferences file that cannot be read or used at launch
      gives the default, as an absent value does (the hotkey's own notice reports the file).
      The setting is read only in normal mode (`usesGlobalShortcut`): the other modes,
      `--report-menu-bar-item` included, resolve the default (definitions and LaunchServices
      read, `preferences.json` not); the self-tests, the placement diagnostic and the tests of
      other parts have no `AppEnvironment.terminal`, so iTerm2 is forced and nothing is read.
    - *The environment:* `makeTerminalBackend: @MainActor (ChosenTerminal, UpdateHandler)
      throws -> any TerminalBackend` replaces `makeAttachCoordinator` (main actor so the plain
      window layer is made lazily, on the main actor, at the first plain build), and
      `terminal: TerminalEnvironment?` (the store, the definitions loader, the inspector). The
      definitions load once through `TerminalCatalogCache`, shared by the choice, the plain
      backends and the engine's `LocalClientAttributor` (production's `makeEngine` passes it
      as `localClients` whatever the choice). `AppModel` keeps `backends[terminal id]`, builds
      at the first action that needs one, and `backendProblem` replaces `attacherProblem`.
    - *Gating iTerm2* (requirement 7), applied by one `applyTerminalChoice(_:)`: the engine's
      D16 checks through a new `RefreshCoordinator.setAttachmentChecksEnabled(_:)` (the engine
      keeps its index; off is an engine built without one: a check in flight retired, its
      waiters resumed, `notChecked`, no attachments, attribution with `indexInUse` false),
      set before the cadence starts and later through the model's request queue (a toggle
      rather than a rebuilt engine: no second engine, subscription or adapter); Settings'
      `terminal` (the profile list answers `ProfileChoices.notUsedWithThisTerminal` without
      asking, `iTermProblem` is nil, D26's update after a save reads the status only); the
      popover's, Settings' and onboarding's `SSHSetupActions.usesITerm2` (`open` then shows
      `SSHSetupFailure.notUsedWithThisTerminal`, the opener never asked; this is onboarding's
      only iTerm2 contact); D26's launch rewrite only with iTerm2 chosen, and run again when
      iTerm2 becomes the choice while the app runs (the saved list the model keeps). "Show
      tab" goes through the chosen backend once built (a plain one refuses an iTerm2 launch
      tab, nothing sent). Persistent profiles' Install and Remove stay the user's explicit
      actions (no iTerm2 contact; I-12d decides the tab's plain state). Proven by
      `TerminalSeamTests.aPlainChoiceNeverContactsITerm2` over a counting iTerm2 under the
      engine's real `AttachmentIndex`, the coordinator and every Settings seam.
    - *Changing the choice:* `AppModel.setTerminal(_:)` saves first (a refused save changes
      nothing and returns the store's error), resolves again (definitions as loaded at launch,
      LaunchServices now) and applies at once, or, while any session action is pending (an
      action, a creation, an "Open existing" lookup or a focus), keeps it as
      `pendingTerminalChoice` and applies it once the last one ends.
    - *The model's plain results:* `plainConfirmed`/`plainFocused` record the window in
      `terminalAttachments` (so `canDetach` and "Detach other clients…"'s count hold for it and
      `showWindow(for:)` focuses it), `appFocused` records the `.app` handle;
      `focus(_:for:)` brings a handle forward through the chosen backend (an `.app` through the
      activator), its outcome a note (`SessionProblem.focusNote(_:)`). Rows carry
      `SessionRow.localAttachments` (no view yet).
    - *The name refusal:* `PlainTerminalBackend.supportsName(_:)` is
      `CreatedSession.formatLiteral(_:) != nil`; attach and move here fail
      `unsupportedSessionName` up front (no state published, as the backend's other refusals
      before a launch) and again after revalidation for a renamed session;
      create-and-attach refuses a valid such name before creating
      (`invalidName(sessionNameNotSupportedByTerminal)`, shown in the New session window).
    - *Probe:* `attach` and `new-session` run on `ITerm2TerminalBackend`; `attach --terminal
      <id>` (parsing and the gate in the core, `AttachCommandOptions`, `PlainRunGate`) loads
      definitions as `terminals list`, refuses with exit 2 an unknown definition and, before
      discovery or any event, an app not installed, too old, not running, or (AppleScript
      definitions) whose permission does not read `granted`; otherwise it attaches through
      `PlainTerminalBackend` (the real window layer, This Mac's attributor) and prints the
      window, the client record (no session name or socket path) and an app focus as JSON.
      `--help` contacts nothing; `--profile` and the definition folders go with one terminal
      kind only. `detach` and the `e2e-*` harnesses stay on the coordinator.
    - **Review fixes** (adversarial review, `docs/reviews/phase-I-12c3a.md`; hermetic
      regressions, each seen failing with its fix reverted):
      1. *Unresolved launches across backends:* `TerminalBackend.hasUnresolvedLaunch(for:)`
         (read-only: a running launch, or an ended one that may still attach with no helper
         result peeked; nothing settled, taken or sent) lets `AppModel` refuse an Open or a
         Move here of a session while any other cached backend holds such a launch of it, with
         `earlierLaunchPending` and nothing written, opened or sent (detaches are not refused:
         they start no attach).
      2. *Startup:* `TerminalChoiceResolution.unresolved` is the model's choice from its
         creation until launch has read the setting (only with `AppEnvironment.terminal`), and
         gates iTerm2 like a choice that is not iTerm2 (no backend, Settings' profile list
         `notLoaded`, no iTerm2 problem, every "Set up SSH in iTerm2…" refused, no D26 update
         after a save), so Settings opened before the model starts contacts nothing; once it
         resolves to iTerm2 the deferred work runs (`SettingsModel.setTerminal(_:)` lists the
         profiles while the window is open, `SSHSetupActions.setUsesITerm2(_:)` clears the
         lines that said iTerm2 was not chosen, D26's launch rewrite as before).
      3. *The probe's gate at the side effects:* `PlainRunPolicy` (`interactive`, the app's
         default, or `unattended`, the probe's) is carried by `PlainTerminalWindows`, which
         under `unattended` applies `PlainRunGate` again to fresh facts right before every
         Apple event (open, focus, close) and `exec` spawn and, through
         `checkRunPolicy(for:)`, for `PlainTerminalBackend` right before it writes a request;
         a refusal is `terminalWindow(unattendedRunRefused)` (the request withdrawn when one
         was written, nothing sent or launched), which the probe maps to exit 2
         (`PlainRunGate.refusal(of:)`) after its early check before discovery.
      4. *Records per backend:* `terminalAttachmentsByTerminal` keeps each backend's records
         by terminal id and session (a result, detach or "not attached here" changes only the
         records of the backend its action ran on, `RunningAction.terminalID`), and
         `terminalAttachments`, `canDetach(_:)`, "Detach other clients…", "Show window" and the
         rows' iTerm2 records (`attachedHere`, only while iTerm2 is chosen) come from the chosen
         terminal's records only, so another terminal's record is kept for when it is chosen
         again and never routed to the chosen backend.
    - **Verified** (hermetic, plus the real runs in `docs/TESTING.md` *Phase I-12c3a*): both
      self-tests passed through the seam's iTerm2 path from a fresh bundle, the app shell check
      with a private home left it empty, and `attach --terminal terminal` refused with exit 2
      while Terminal did not run (nothing written or sent). **Owed:** the plain real runs
      (I-12c3b's `e2e-plain`, under *Unattended-run rules* 8) and the picker and strings
      (I-12d).
  - **The plain runs (I-12c3b)** (2026-11-06; code in `Sources/MuxFinderCore/E2EPlain/`:
    `E2EPlainOptions.swift` (`E2EPlainOptions`, `E2EPlainUsageError`, `E2EPlainRefusal`),
    `E2EPlainSeams.swift` (`E2EPlainHostTmux`, `E2EPlainTmuxOutput`, `E2EPlainProcessCommand`,
    `E2EPlainControlClient`, `E2EPlainControlClientStarter`, `PlainTerminalWindowClosing`, a
    counting discovery and the update log), `E2EPlainRun.swift` (the run and its steps),
    `E2EPlainRunCleanup.swift` (the closes and the cleanup); additively
    `PlainTerminalWindows: PlainTerminalWindowClosing` (its `close(_:of:)` unchanged) and
    `FakePlainTerminalWindowLayer.close(_:of:)`; the probe's `E2EPlainCommand.swift` and its
    line in `main.swift`; tests `E2EPlainRunTests.swift`, `E2EPlainStepsTests.swift`;
    `docs/TESTING.md` *Phase I-12c3b*, `docs/MANUAL-CHECKLIST.md` item 26). It does what the
    calls for I-12c3b say. **The worker's calls:**
    - *The run lives in the core.* The test targets import only the libraries, so, as
      `AttachCommandOptions` did for `attach --terminal`, the arguments, the gate, the steps
      and the cleanup are `MuxFinderCore` types behind four seams (the host's tmux, the run's
      own control clients, the window layer's close, the kernel for its own helpers:
      `E2EPlainHelperProcesses`); the probe wires the real parts (the
      e2e harness's `TestTmux`/`RemoteTestTmux` through an adapter, `BackgroundControlClient`,
      `PlainTerminalWindows(policy: .unattended)` over `NSAppleScriptRunner`, `LaunchStore()`,
      `DiscoveryProbe()`, `LocalClientAttributor` over the loaded definitions, by default
      `E2EPlainKernelProcesses`) and races the
      steps against `SignalWatcher` and a 300 s watchdog. The run builds its
      `PlainTerminalBackend` as the app builds a plain one (the loaded definition, the window
      layer, the helper, the store, discovery, `PlainTmuxCommands()`, the attributor, the real
      activator), adding only its update handler and a counted discovery. The coordinator,
      both backends and every existing test are unchanged.
    - *The gate, before anything.* The probe parses, refuses a set `TMUX_TMPDIR`, loads the
      definitions as `terminals list` does (an id no loaded definition has: exit 2), then
      reads the app's facts with nothing sent and applies `PlainRunGate`; the run's
      `execute(limit:interrupts:)` reads them once more as its first act. A refusal prints
      the reason and the owed command (`swift run muxfinder-probe e2e-plain` with the same
      arguments) and exits 2: no tmux call (not even `-V`), no session, discovery, request,
      control client or window call. During the run the window layer's unattended policy
      checks again before the request's write and every open, focus and close; a failure
      that stands for the gate (`unattendedRunRefused`, or the layer's own `appNotRunning`
      or `permissionDenied`) fails its step naming the gate, cleanup runs, and the run says
      it stopped (exit 1).
    - *Exit statuses:* 0 every step passed; 1 a step failed, or a signal stopped the run (the
      calls list no status of its own for a signal; cleanup runs first); 2 usage (with an
      unusable environment: `TMUX_TMPDIR` set, the helper or tmux not found) or the gate; 3
      the watchdog (then cleanup).
    - *Steps:* the calls' eight, then cleanup as step 9. Beyond them: an AppleScript
      definition's window must report its id (else it could never be closed by it); the
      helper's pid is read from its early report and its kernel start time right then, while
      it runs and no later than the report's attach child (the record every close waits on;
      the backend's detach takes the report with the result); an open publishes exactly one
      `plainLaunched`; the second open must end `plainWindowFocused`; a detach's helper result
      must be clean (exit 0, no failure: one that is not leaves the helper waiting for Return,
      which only cleanup's SIGTERM ends); the
      stale move here is checked by no published update, no discovery call and the run's
      control client still the session's only client (the launch folder is shared with the
      app, so it is not counted); Detach other clients is called at once and must return no
      earlier than `minimumLaunchTabAge` after the client started (the backend's age guard
      waits).
    - *Closing a window* (`closeWindow(of:)`): only windows the backend's `plainLaunched`
      updates reported (so also one opened by a call that was cancelled), only through the
      layer's `close` (ids its own open recorded; Terminal's script also refuses a busy window,
      1001), and only on positive evidence that the helper's process has ended: its pid
      absent (`sysctl` answered no process), or showing another start time than the one
      recorded. The helper is kept by launch token whatever became of its window: the pid its
      launch's early report, else its result (peeked), names, identified by the kernel start
      time read while it ran no later than that file's own moment (the report's attach child
      start, the result's end; pids are unique among live processes). A reading that fails,
      or a pid whose process started later, is not known: the window is left
      (`helperUnreadable`), never taken for ended. At most `Budgets.helperEnd` (15 s), else
      the window is left open. -1728 means the terminal's own settings closed it (Ghostty's
      `wait after command` false): left as it is.
    - *Cleanup order:* the run's control clients ended; the backend's own client, if it holds
      one, detached with the bound detach; every launch's helper recorded from its own files;
      a close pass; the session killed with the bound kill; helpers that may still run get
      `helperEnd` to end (the session's end may end a helper a cancelled launch left
      attached), then those still running, positively identified, are asked to stop:
      SIGTERM (`E2EPlainKernelProcesses.terminate`, only while the pid still has the
      recorded start time and runs the helper's executable), which finishes a failed
      helper's wait for Return (D14), again every second within `Budgets.helperShutdown`
      (15 s), never by typing into or closing its window; a second close pass; a launch with
      no recorded window although one may be open (a helper ran for it, or its open failed
      after its Apple event: the open call's `scriptFailed` or `malformedReply`, as when the
      script opened the window and then failed or its reply was lost) is reported with what
      to do by hand; the launch files of the run's launches (results nobody took, requests
      withdrawn, the reports of ended helpers); then the check (no launch file, control
      client, or running or unreadable helper of the run; once step 1 ran, the session gone:
      only a `list-sessions` without it, or tmux's "no server running", shows that, so a
      listing that failed, as when Saturno is unreachable after a lost `new-session` reply,
      fails cleanup; every window or session left is listed with what to do by hand). A
      launch cancelled after its helper attached has no record, so its client goes with the
      session's kill, not the bound detach; on a real terminal its helper may then wait for
      Return until cleanup asks it to stop, and then its window is closed.
    - **Verified** (hermetic; 19 tests in 9 suites, `docs/TESTING.md` *Phase I-12c3b*): the
      arguments and refusals; the gate over fake facts (not running, `denied`,
      `notDetermined`, another status, `targetNotRunning`, an `exec` definition's app not
      running) exits 2 with nothing contacted (no tmux call, discovery, control client, launch
      file, window call or run policy check); no close while the helper runs, an unknown
      helper's window left, a helper named by its result, -1728 left as it is, a refused
      close noted as the gate's; and the run itself on a private tmux server, the real helper
      started by I-12c1's fake window layer on a pseudo-terminal of the test's (its close
      refusing, as busy, a window whose helper has not exited): 9 of 9 in about 3 s with two
      windows opened and both closed after their helper exited; the window layer's recheck
      refusing the move here's request: step 6 fails naming the gate, nothing more opened,
      cleanup passes, exit 1; SIGTERM after the first close, and right after the move here's
      window opened: cleanup passes with nothing left, exit 1. The adversarial review's four
      findings (`docs/reviews/phase-I-12c3b.md`), each with a regression shown failing with its
      fix reverted: an unreadable process, at the first look or later, or a pid whose process
      started after the report, never lets a window close (B1); a real helper that failed
      (its request withdrawn) and waits for Return is stopped by cleanup's SIGTERM before its
      window closes, cleanup passing with nothing left, and over fakes a helper that keeps
      running is asked again and reported while one that cannot be read is never signalled
      (S1); an open that failed after its Apple event keeps its report-named helper, stopped
      and seen ended before its report goes, and is reported as a window with no recorded
      id, as is an uncertain open with no helper file (S2); a failed `list-sessions` after a
      lost `new-session` reply (ssh unreachable, tmux's error, a timeout) fails cleanup,
      while "no server running" and a listing without the session pass (S3); and the real
      reader and SIGTERM on a child of the test's (refused for another start time or
      executable). **How far the hermetic run
      reaches:** every step and the cleanup on This Mac with real tmux, discovery, bound
      commands, helper and control clients; not a terminal app's windows (the fake opens a
      pseudo-terminal, focuses and closes nothing), the facts (a fake inspector) or the remote
      path (the token reading and the control clients over ssh). Real (2026-11-06):
      `e2e-plain --terminal terminal --local` and `--terminal ghostty --local` exit 2 with
      nothing created, written or sent, `pgrep -x Terminal` and `pgrep -x ghostty` empty
      before and after (again after the review's fixes); iTerm2's regression (requirement 12) under the thread gate:
      `e2e-local` 16/16, `e2e-remote saturno-m4` 17/17 (its first run failed step 15 `new
      session` with `helperEnded` after 3.2 s, code this phase did not touch; the rerun at once
      passed), `e2e-bury --local` 13/13, `e2e-detach-others --local` 9/9, leftovers clean after
      each (threads 23 → 44 after `e2e-local`, held about 1 h 45 min, then 18 in one step; 16–20
      for the rest). **Owed** (to the user,
      `docs/MANUAL-CHECKLIST.md` item 26): `e2e-plain --terminal terminal|ghostty --local |
      --ssh saturno-m4` with the app running and `granted`.
  - **The UI (I-12d1)** (2026-11-06; requirements 8–11; code in `Sources/MuxFinderUI/Model/`:
    `TerminalWording.swift`, `TerminalPicker.swift` (`TerminalPermissionLabel`,
    `TerminalPickerRow`, `TerminalPickerProblem`, `TerminalPickerReading`,
    `TerminalPickerContent`, `TerminalPickerFixture`, `TerminalPickerModel`),
    `PersistentWorkContent.swift`; `Views/Settings/TerminalPickerView.swift`;
    `Preview/TerminalPickerFixtures.swift`; in the core `Terminals/PlainSSHSetupLauncher.swift`
    (`PlainSSHSetupWindowOpening`, `PlainSSHSetupLauncher`); changed: `PlainTerminalWindows`
    (`openSSHSetup(_:helperPath:token:)`), `TerminalAppFacts` (`automation(for:inspector:)`,
    `init(definition:snapshot:automation:)`), `Attach/SSHSetupLauncher.swift` (the new result and
    failure cases), `TerminalChoice.displayID(_:)` (now public), the fakes
    (`FakeTerminalAppInspector`'s per-app answers, `FakePlainTerminalWindowLayer.sshSetupOpens`),
    the probe's `SSHSetupCommand.swift` (the new result case), and in `MuxFinderUI`
    `SSHSetupActions.swift`, `SettingsEnvironment.swift`, `AppEnvironment.swift`,
    `AppModel.swift`, `AppModelTerminal.swift`, `SettingsModel.swift`,
    `SettingsModelProfiles.swift`, `SettingsResults.swift`, `OnboardingModel.swift`,
    `DiagnosticsReport.swift`, the General, Diagnostics, host editor, Persistent profiles,
    onboarding and popover host section views, the Settings and onboarding fixtures and
    galleries; tests in `TerminalPickerTests` and the core's `PlainSSHSetupLauncherTests`;
    `docs/TESTING.md` *Phase I-12d1*, `docs/MANUAL-CHECKLIST.md` item 27). It does what the
    calls for I-12d1 say; the popover's session strings and the attach states are I-12d2's.
    **The worker's calls:**
    - *One source of wording*, `TerminalWording`: the display name, a kind by bundle
      identifier (`iTerm2`, `terminalApp` for `com.apple.Terminal`, `ghostty` for
      `com.mitchellh.ghostty`, `other`, compared without regard to case) and the place ("tab"
      or "window"), with every string built from them ("Set up SSH in Terminal…", its "first"
      form and help, the ssh setup lines, "Not used with Terminal", onboarding's introduction
      and permission line). It follows the **applied** choice (`AppModel.terminalWording`,
      `SettingsModel.terminalWording`, set in `setTerminalGates(_:)`): iTerm2's wording for
      iTerm2, while the choice is `unresolved` (today's strings) and for an unavailable
      `iterm2`; an unavailable definition's own name; an id no definition has reads "the chosen
      terminal". With iTerm2 every string is byte for byte as before (tested).
    - *The picker* is one `TerminalPickerModel`, `AppModel.terminalPicker`, shared by Settings ›
      General (its first section, "Terminal", above Startup) and onboarding's Terminal step; a
      model built without `AppEnvironment.terminal` gets an inert one (iTerm2, nothing read or
      chosen). It shows custom radio rows rather than a SwiftUI `Picker` (each row holds two or
      three lines and, under it, a button). `TerminalPickerContent.make` is pure: iTerm2 first
      when installed (its note "Native tmux: each tmux window opens as an iTerm2 tab or
      window.", no permission label: iTerm2's Automation is the cookie's, covered by D23's
      fix-its), then each loaded definition whose version check is `meets`, by display name
      (`localizedStandardCompare`, ties by id); the selected row (a waiting change's, else the
      applied choice's) is listed whatever its state, with its reason as a sentence ending in a
      period ("Ghostty 1.2 is older than 1.3.", "Ghostty isn't installed.", "Can't read
      Ghostty's version.", "No terminal named “warp”." on a row named by the quoted id,
      "iTerm2 isn't installed."). "Allow in System Settings…" sits under every `denied` or
      `notDetermined` row, not only the selected one. The loader's problems are listed under
      "Terminal definitions not used", file name and reason. **Reading**
      (`TerminalPickerReading`: iTerm2's snapshot and every definition's `TerminalAppFacts`,
      the permission without a prompt) happens only when the Settings or onboarding window
      opens and on "Check again"; a window that opens before the setting was read gets its
      reading when the definitions arrive (the resolution, not a timer). LaunchServices'
      snapshots are taken on the main actor and the Automation permissions read in a detached
      task (`TerminalAppFacts.automation(for:inspector:)`), so a slow
      `AEDeterminePermissionToAutomateTarget` never holds Settings or onboarding; the result is
      shown when it arrives only while it is the newest reading: a newer "Check again", the last
      picker window closing (Settings and onboarding share the picker) or quitting drops it
      (Settings' opening waits for the reading or its drop). Until the first reading arrives the
      picker shows "Reading the terminal setting…" with no rows (onboarding's plain-mode step
      shows its permission line meanwhile); on "Check again" the earlier rows stay until the new
      reading replaces them (decided: no "Checking…" label, the read normally takes
      milliseconds). After each reading shown, `AppModel.resolveTerminalAgain()` resolves the
      stored setting again through `TerminalEnvironment.resolve` (as `setTerminal(_:)` does;
      nothing saved) and takes the result only when it changed and names the same terminal as
      the selected choice, for a plain or unavailable choice only (with iTerm2 chosen nothing
      changes): Ghostty 1.2 upgraded to 1.3.1 is applied on "Check again", one that became
      unusable shows unavailable again, and while a session action is pending the result waits
      as a change does (the review of I-12d1). **Choosing** stores the
      row's explicit id (never the absent default) through `AppModel.setTerminal(_:)`; a refused
      save shows `PreferencesStoreError.errorDescription` and changes nothing; a change held by
      a pending action is selected at once with "Applies when the current action ends." while
      every other string keeps the applied choice until it is applied.
    - *Set up SSH in a plain terminal:* `PlainTerminalWindows.openSSHSetup(_:helperPath:token:)`
      shares the attach's open (facts, launch command, compile-once script or spawn, window
      record) with only the mode word `ssh-setup` in place of `attach-plain`;
      `PlainSSHSetupLauncher` (behind `PlainSSHSetupWindowOpening`) refuses This Mac, an invalid
      destination and a missing helper first, asks the layer's run policy, writes D24's
      `SSHSetupRequest` unchanged, opens one window and withdraws the request on any failure
      after the write, or on a cancellation, checked again on the main actor right before the
      window opens (closing Settings or onboarding, or quitting, can cancel while the open waits
      for the main actor; the review of I-12d1); it answers the new
      `SSHSetupResult.openedWindow(_:)` (the open is the
      result, nothing confirmed after it) or `SSHSetupFailure.terminalWindow(_:)`. The app's
      opener is `SettingsEnvironment.plainSSHSetup`, over the one plain window layer and
      `LaunchStore()`. `SSHSetupActions` asks the opener the resolution names: iTerm2's for
      iTerm2, the plain one for a plain choice, none while `unresolved`
      (`notUsedWithThisTerminal`, its line reworded to "Still reading the terminal setting. Try
      again in a moment." and shown without a terminal's name) or unavailable (the new
      `terminalUnavailable`, "…can't be used now. Choose another in Settings › General.").
      Decided: a plain choice with **no plain opener wired** (the tests of other parts; the app
      always wires one) keeps the earlier refusal, so `aPlainChoiceNeverContactsITerm2` stands
      as written. Each line names the terminal its request was made in (`wordings`); a change
      of choice clears only the lines that refused for the previous one. A plain window macOS
      refused (`permissionDenied`) offers "Open Automation settings". The helper's `ssh-setup`
      mode is unchanged (it runs in any terminal; its 10 s hold stays).
    - *Host editor:* the iTerm2 profile field keeps its value and stays editable; with another
      choice its caption is `ProfileChoices.notUsedWithThisTerminal`'s note, now "Used only
      with iTerm2.", and the parent profile field gets the same line; the persistent profile
      switch's note speaks of the terminal's persistent work command.
    - *Persistent profiles tab* with a plain choice (`PersistentWorkContent`): decided, "per
      enabled host" is per saved host whose **persistent profile** is on (`profile-plain`
      refuses any other, `notOptedIn`), in host-list order, from the saved list only (as
      Install). The command is D3's extension through `TerminalCommandText`: `exec '<helper>'
      'profile-plain' '<host id>'`, the helper path read when the window opens
      (`SettingsEnvironment.helperPath`, `LaunchHelperPath.locate()` in the app; a missing or
      unusable one is the tab's problem line). Where to paste: Terminal, "Settings › Profiles
      › Shell › Run command" with "Run inside shell" kept on (the quoting and `exec` need the
      shell); Ghostty, after “command = ” in its config file; any other, a generic sentence.
      Copy goes through `SettingsEnvironment.copyText` (the general pasteboard; "Copied the
      command for Saturno."). The iTerm2 part is one line, "Remove profiles" while muxFinder's
      own file is installed (the status is still read when the window opens; no iTerm2
      contact), and Install refused (`canInstall` false), so nothing writes `DynamicProfiles`
      with a plain choice but the user's Remove.
    - *Diagnostics* with a choice other than iTerm2: the tab shows a "Terminal" row (name,
      version, permission as the picker last read it, or its reason) and "iTerm2: Not used
      with Terminal"; the report's iTerm2 check line reads "not used with Terminal" and a
      `Terminal:` line follows the shortcut's. Decided: with iTerm2 chosen (or not resolved
      yet) neither appears, so iTerm2's report is as before.
    - *Onboarding:* `OnboardingModel.steps` is the Terminal step first (decided: before the
      hosts, since it names the terminal their "Set up SSH" opens), the hosts, "Good to know",
      then iTerm2's Python API step with iTerm2's wording, else the plain-mode step titled with
      the terminal's name: what plain mode means and, for an AppleScript terminal, the
      permission line (none for an `exec` one). The introduction names the terminal. Opening
      the window reads the picker's facts; it still contacts no iTerm2.
    - *The popover's "Set up SSH in iTerm2 first"* and its line follow the choice too (one
      wording source; the rest of the popover is I-12d2's).
    - **Verified** (hermetic; `docs/TESTING.md` *Phase I-12d1*): 16 UI tests and 4 core tests,
      every existing expectation unchanged (no existing test's wiring changed either). The
      galleries: 15 new Settings states (the picker's eleven, the host editor, two Persistent
      profiles tabs and Diagnostics with a plain choice; General frames 720 pt, picker frames
      470 pt) and 2 new onboarding states (no iTerm2; Ghostty), light and dark. `pgrep -x
      Terminal` and `pgrep -x ghostty` empty before and after; no Apple event, no prompt.
      **Owed** (`docs/MANUAL-CHECKLIST.md` item 27): the picker's real permission states, "Set up
      SSH" in Terminal and Ghostty (a real login and an Apple event), pasting the persistent
      work command into Terminal and Ghostty.
  - **The UI (I-12d2)** (2026-11-07; requirement 9; code in `Sources/MuxFinderUI/Model/`:
    `TerminalWordingSessions.swift` and `TerminalWordingFailures.swift` (extensions of
    `TerminalWording`), `SessionProblemTerminal.swift`, `AppModelTerminalSessions.swift`;
    `Preview/TerminalSessionFixtures.swift`, `Preview/TerminalAttachFixtures.swift`; changed:
    `SessionActivity.swift` (five plain cases, `isAttached`, `launchWindow`),
    `SessionProblem.swift` (`Recovery.showWindow`, `openAutomationSettings`; `attach`,
    `detach`, `detachOtherClients`, `terminalUnavailable` take the terminal's wording),
    `PopoverContent.swift` (`SessionRow.hasWindowHere`, `openInApps`, `otherTerminalDetaches`;
    `OpenInApp`, `OtherTerminalDetach`), `SwitcherContent.swift`, `SessionPanels.swift`,
    `HostStatusLabel.swift`, `SettingsResults.swift`, `AppModel*.swift`, the row, menu,
    switcher, panel and footer views, `PreviewFixtures.swift` (a fixture's terminal) and the
    three galleries; in the core, additively, public
    `LoadedTerminalDefinition.init(definition:source:fileName:script:)`,
    `TerminalDefinitionCatalog.init(definitions:problems:)` and
    `PlainTerminalWindowError.reason(of:)`; tests `TerminalSessionWordingTests.swift`,
    `TerminalSessionModelTests.swift`, the core's `TerminalPublicInitTests.swift`;
    `docs/TESTING.md` *Phase I-12d2*, `docs/MANUAL-CHECKLIST.md` item 28). It does what the
    calls for I-12d2 say. **The worker's calls:**
    - *One wording source still:* every per-terminal string is a `TerminalWording` property or
      method (two new files extend it); with iTerm2's wording each is byte for byte the old
      literal (tested against the literals). A row's lines follow the terminal **whose backend
      ran the action** (`AppModel.wording(forTerminalID:)`, from the running action's terminal
      id), not the choice at display time, so a line stays true after a change of terminal;
      menus, hints and the panels follow the applied choice. A window error is worded by its
      own app name (`PlainTerminalWindowError` carries it), so the line is the same whatever
      calls it.
    - *States:* iTerm2's `SessionActivity` cases are unchanged; the plain backend's are
      `waitingForTerminal` ("Waiting for Terminal…"), `stillConnectingInWindow` ("Still
      connecting — check the Terminal window" with "Show window"), `confirmedInTerminal`,
      `focusedWindow` ("Already open here — brought its Terminal window forward") and
      `focusedApp` ("Already open in Ghostty on this Mac — brought it forward"). A confirmed
      window whose one focus failed keeps "Confirmed…" with the focus's note; a focus of the
      backend's own window, or an app activation, that did not bring it forward is a problem
      with "Try again" (as iTerm2's `notBroughtForward`). The session switcher closes on
      `isAttached` (any of the five success states).
    - *Show window:* the context menu offers it for a window the chosen plain backend recorded
      (`hasWindowHere`), a still-connecting launch and a failure whose window is known
      (`Recovery.showWindow`), always through the chosen terminal's backend (another
      terminal's window is refused with nothing sent, as "Show tab" is). A recorded window also
      offers "Detach from this Mac", but never dims "Move here…" (review fix): the model's copy
      of the record is not checked again by a refresh, so its client may have been detached in
      tmux or its window closed; the backend checks its own record at the move (the helper's
      result, then the bound presence check), refuses while its client still holds the session
      (`alreadyOpenInTerminal`: "This session is already open in a Terminal window…" with
      "Bring forward" and "Detach from this Mac") and otherwise drops it and moves here, the new
      window replacing the record.
    - *Errors:* `SessionProblem.plainAttach` switches over every `AttachFailure` and
      `terminalWindow(_:kind:)` over every `PlainTerminalWindowError`, both with no `default:`;
      iTerm2's own failures keep iTerm2's lines, the neutral ones the core's sentence. "Ghostty's
      AppleScript is turned off" is decided by Ghostty's open answering -1708 or -10004 (a
      guess: the real number is owed, item 28), -1708 only from muxFinder's own script (review
      fix): -1708 (`errAEEventNotHandled`) is also what a script answers for a handler it
      lacks, which the number cannot tell apart, and a built-in script defines every handler.
      From a user definition or override (`LoadedTerminalDefinition.source`, passed by the
      model as `SessionProblem.attach`'s `definitionSource`) an open answering -1708 reads as
      possibilities, for any app: "Ghostty couldn't open a window (error -1708), so muxFinder
      opened nothing. The script of your terminal definition for Ghostty may have no
      “muxfinder_open” handler, or Ghostty's AppleScript may be turned off: …" with "Try again"
      and "Open Settings" (`TerminalWording.windowOpenNotHandled(errorNumber:)`; without the
      AppleScript part for other apps). -600, -609 and -10810 from an open read "isn't running
      and couldn't be opened (error …)". A denied permission offers "Open System
      Settings…" (a new recovery opening Privacy & Security › Automation's URL, no Apple event),
      an app gone or too old "Open Settings", a refused launch command no recovery (moving
      muxFinder is the fix). The unavailable choice names a loaded definition's terminal ("The
      chosen terminal, Ghostty, isn't installed. …"); an id no definition has keeps the core's
      sentence, which quotes it.
    - *Earlier launch pending:* the refusal for another backend's launch records that backend's
      terminal id (`ActionEvent.finished`'s `heldBy`, the first holder by id) and names it;
      the chosen backend's own refusal names the chosen terminal (iTerm2's line as before).
    - *Open on this Mac:* `SessionRow.openInApps` (one per app, named from the loaded
      definitions, "another terminal" when none names it) shows "Open in Terminal on this Mac"
      with "Show in Terminal" whatever the choice; "Show in …" focuses `.app(app)` through the
      chosen backend (iTerm2's too: the activator, no Apple event, nothing launched); Open
      still opens in the chosen terminal. The row's indicator is unchanged (D16's badge stays
      iTerm2's).
    - *Another terminal's records:* "Detach (opened in <terminal>)" for each plain window kept
      by a terminal that is not chosen, and for iTerm2's `attachedHere` records while iTerm2
      is not chosen; it runs only that terminal's cached backend's `detach(session:on:)`
      (never builds one; `ActionKind.detachOpenedIn`, so "Try again" repeats it there). It
      runs on the record that terminal keeps (`AppModel.keepsRecord(of:terminalID:)`: iTerm2's
      `attachedHere`, a plain backend's window) whether or not that terminal is the chosen one
      by then (review fix), so "Try again" still works after a change of terminal that waited
      for the detach made it the chosen one; likewise "Try again" of a "Detach from this Mac"
      whose terminal is no longer the chosen one repeats it on that terminal's backend while it
      keeps the record (`lastDetachTerminalIDs`; with the same terminal chosen it is as before).
      The iTerm2 one contacts iTerm2 with a plain choice: the user's explicit detach of an
      attachment muxFinder made there, the only such contact (none exists without such a
      record, so `aPlainChoiceNeverContactsITerm2` holds as written).
    - *Detach other clients, plain:* a run that stopped says "Stopped after detaching N other
      client(s): <why>" when `detachedClients` is known, "muxFinder detached no other client:
      <why>" only when it is 0 and nothing may have run, and "Stopped detaching … Some may have
      been detached: <why>" (with "At least N were") when a failed detach may have run
      (`PlainTmuxCommandFailure.mayHaveRun`); never "none" when unproven (tested over every
      outcome and count against `mayHaveSent`). A plain Detach's lines name the window; a
      refused bound detach (`notSent`) also forgets the model's record, as the backend dropped
      it.
    - *Beyond the block:* the host problems that say where to set up SSH, Settings' "Test
      connection" and "Detect" lines, New session's "Creating … in Terminal…", the Move here
      and Detach other clients panels and Quit's help follow the choice too (iTerm2's strings
      unchanged).
    - *Galleries:* a fixture can choose a terminal (`PreviewFixture.terminal`, its definitions
      and records), Terminal's and Ghostty's decoded in memory from copies of the built-ins'
      JSON, which needed the core's two public initializers (no file read, no script). The new
      states are separate lists after the existing ones (`TerminalSessionFixtures.popover` and
      `.switcher`, `TerminalAttachFixtures.all` and `.menus`), so every existing fixture count
      stands; attach cards hold at most three rows, so no popover scrolls in a screenshot.
    - **Verified** (hermetic; `docs/TESTING.md` *Phase I-12d2*): 24 UI tests in 5 suites and 1
      core test; every existing expectation unchanged but three of I-12c3a's plain
      placeholders in `TerminalSeamTests` (a plain focus, the name refusal, the holder's
      name), which now expect the plain wording. Galleries and screenshots (popover, attach,
      switcher, light and dark). The review's three should-fix findings
      (`docs/reviews/phase-I-12d2.md`) are fixed above, each with a regression in
      `TerminalReviewFixTests` (7 UI tests in 1 suite) that fails with its fix reverted; one
      expectation of this phase's `anotherTerminalsRecordDetachesThroughItsOwnBackend` now
      expects "Move here…" offered beside a window; the attach screenshots show it so. `pgrep -x Terminal` and `pgrep -x ghostty` empty before and
      after; no Apple event, no prompt. **Owed** (`docs/MANUAL-CHECKLIST.md` item 28): a real
      Open, "Show window", Detach, Move here and "Detach other clients…" in Terminal and
      Ghostty, the real permission and AppleScript-off lines (and Ghostty's number), "Show in
      Terminal" and "Detach (opened in …)" after a change.
  - **The docs (I-12e)** (2026-11-07; requirement 13; `docs/TESTING.md` *Phase I-12e*).
    `docs/TERMINALS.md` is the user-facing reference for other terminal apps: plain mode and
    what it costs, the built-ins and how the choice resolves, the Automation permission,
    persistent work per terminal, "Adding a terminal" (schema 1 as `TerminalDefinitionParser`
    takes it, the open, command and focus kinds, the placeholders, the user folder's rules,
    overrides, the problems list), the safety rules, a worked `exec` example checked to load
    with `terminals list`, and the later candidates. `docs/REQUIREMENTS.md` gained the dated
    addendum; README, `docs/ARCHITECTURE.md` (*Terminal backends (D38)*), `docs/TESTING.md`,
    `docs/MANUAL-CHECKLIST.md` (item 29) and `CLAUDE.md` point to it. No code changed.

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

Verified in Phase I-2a (2026-10-24, tmux 3.8 on a private server on Neptuno, `TMUX_TMPDIR`
from `mktemp -d`, `-f /dev/null`, only `muxfinder-test-*` sessions with synthetic `-c` values;
the capture is `Tests/MuxFinderCoreTests/Fixtures/discovery/local-session-paths.txt`):

- **`#{session_path}` is the `-c` value as given:** `new-session -c` expands formats in it
  (`##1` is stored as `#1`, as for names) but nothing else: `~/x` and a relative path stay as
  typed, an empty `-c ""` gives an empty path, and a folder that does not exist is stored all
  the same (tmux starts the pane elsewhere, D18). A session made without `-c` has the client's
  working directory.
- **Through `tmux -u` it is printed raw:** line feeds, tabs, escape sequences, C1 controls
  (`U+0085`) and invalid UTF-8 bytes (`0xFF`) all reach `list-sessions -F` output unchanged,
  unlike session names, which `new-session` refuses with control characters. So a path can
  break any line framing; the `path` record ends at the run's nonce instead (D31).
- **Format details:** a line break inside a `-F` format prints one line per part for each
  session (two lines per session for the probe's format), and `#{n:session_path}` is the
  path's length in bytes (`#{w:…}` its display width, control characters counting zero).
- **The bound (Phase I-2a review, the same kind of private server):**
  `#{e|>|:#{n:session_path},4096}` is `1` or `0`, and
  `#{?#{e|>|:#{n:session_path},4096},,#{session_path}}` printed `-c` values of 4,096 bytes
  whole and of 4,097 and 9,000 ASCII bytes, 4,097 bytes of two-byte characters (2,049
  columns) and 8,001 bytes of them as nothing; `n:` counted a 12-byte path with a line feed,
  an escape sequence, a C1 control and an invalid byte as 12. Commas and braces in the value
  (`/x,y}z…`) do not break the conditional, since tmux splits the format before it expands
  the value.
- **The probe on that server:** seven sessions, two folders kept exactly (a synthetic absolute
  one and `~/dir with spaces ünïcödé 日本 #1 a;b`), five dropped (a line break followed by a
  forged session line, a status line and a forged `end` line; a tab and escape sequence; an
  empty one; a C1 control; invalid UTF-8), and no forged session listed.

Verified in the Phase I-1a placement diagnostic (2026-10-24, macOS 27.2, the bundle binary's
`--report-popover-placement` run from the shell with an empty private `CFFIXED_USER_HOME`;
two full runs that clicked, exit 1 both, the same numbers both times, and one SIGTERM run,
exit 3; after the review fixes it no longer clicks a button with no action and exits 4; runs
and numbers in `docs/TESTING.md`, *Phase I-1a*). **The screen was locked and both displays
asleep in the first three runs** (`CGSSessionScreenIsLocked` yes, on console yes,
`CGDisplayIsAsleep` true); the review-fix worker's two runs reported it unlocked and both
displays awake, and the orchestrator's re-run on the final tree (about 15:25, exit 4)
reported it locked and both displays asleep again; all showed the same windows, frames and
click wiring. What follows is
AppKit's in-process view only. **The popover's frame before the fix is unmeasured** (see *Not
measured* below):

- **Displays.** Screen 0 (main, primary): {{0, 0}, {3072, 1728}} at 2x, visible
  {{63, 0}, {3009, 1698}} (Dock at the left), menu bar 30 pt (bottom 1698). Screen 1
  (portrait, right of the main one): {{3072, 249}, {1080, 1920}} at 2x, visible
  {{3072, 249}, {1080, 1890}}, menu bar 30 pt (bottom 2139). "Displays have separate
  Spaces" on; `NSStatusBar.system.thickness` 22 (not the 30 pt the menu bars reserve).
- **(a) One real item, six replicas.** `NSApp.windows` holds seven `NSStatusBarWindow`s
  (level 25, 34 × 30 pt, all `isVisible`), the same seven frames `--report-menu-bar-item`
  printed in the same session. Only window 0 holds a status item button
  (`NSStatusBarContentView` › `NSView` › `NSStatusBarButton`, 34 × 22 pt); its window answers
  AppKit's `statusItem` with the scene's item, at {1413, 1698} on screen 0, inside that
  menu bar (the button's screen rect {{1413, 1702}, {34, 22}}, middle x 1430). Windows 1–6
  hold an `NSStatusItemReplicantView` (shadow and image views) and each answers another
  status item, with no button: four at {0, −30} (below the main display's bottom-left
  corner) and two at {4152, 2139}, exactly screen 1's right edge (3072 + 1080) at its menu
  bar's bottom; all six on no screen, so placeholders. Phase 8's "one on the second display"
  was most likely this pair.
- **(b) The button takes no click `performClick(_:)` can deliver.** Action none, target none,
  cell `NSStatusBarButtonCell`, no menu on the button or the item, no gesture recognizer,
  key-value observed only for `effectiveAppearance`; the item: length −1, visible, behavior
  6 (removal allowed, termination on removal). `performClick(_:)` (allowed by the
  orchestrator, see Phase I-1) therefore sends nothing: no popover window appeared within
  2 s and none was created (SwiftUI makes it only when it opens). So the in-process opening
  step cannot open the `MenuBarExtra(.window)` popover, locked screen or not; the diagnostic
  now checks the button for an action or a menu first and, finding neither, exits 4 ("not
  openable in process") without clicking.
- **(c) What a placement would give.** The popover's content measured off screen (an
  `NSHostingView` never put in a window; the never-started model's "Loading hosts…"
  placeholder) is 360 × 168 pt. `PopoverPlacement` gives {{1250, 1530}, {360, 168}} at the
  button (centered on x 1430, top 1698); anchored at windows 3 and 4 it gives
  {{3784, 1971}, {360, 168}}, screen 1's far right (its right edge less the 8 pt inset); at
  windows 1, 2, 5, 6, {{71, 1530}, …}, beside the Dock.
- **Not measured: the popover's real frame before the fix.** No run opened it, and none can
  within the run rules: SwiftUI's status button has no action, so `performClick(_:)` sends
  nothing, and the only other ways to open the `MenuBarExtra(.window)` popover in process
  are SwiftUI's private internals or synthesized mouse events (`NSApp.sendEvent`,
  `mouseDown(with:)`, CGEvent; in process or not), both outside *Unattended-run rules* and
  `CLAUDE.md` (no private API, no UI scripting or synthesized input); the first three runs
  also had the screen locked and the displays asleep, and the runs reported with the screen
  unlocked could not open it either. The only observation of the before state is the user's own
  report: it opens at the far right. Also not measured: where the system draws muxFinder's
  icon (outside the app, and `CGWindowListCopyWindowInfo` listed no other process's
  on-screen status-bar window to compare with, also in the runs reported unlocked, where Phase 8
  had listed older apps' items; why none now was not checked), so whether window 0's x 1413
  is the drawn icon's could not be checked; and which window a real click arrives through on
  each display.
- **Cause (inferred from the window frames above, not observed: no popover frame was
  measured).** muxFinder places nothing; SwiftUI places its window from status-item geometry
  it gets in process, and of the seven candidates only window 0 matches a menu bar, while the
  second display's replicas sit exactly at its right edge. A window placed below one of those
  and kept on screen would open at the far right (x 3784–4144 on screen 1), which matches the
  report; below window 0 it would open under the icon (x
  1250–1610 on screen 0). So the most likely cause is hypotheses (a) and (b) of the
  specification together: SwiftUI anchors at a replica item window (the one for the clicked
  menu bar, or the wrong one of several) whose in-process frame is a placeholder, and the
  screen clamp pushes it to the right edge. Hypothesis (c), a system-managed area the
  in-process frame does not describe, is not excluded (the drawn icon could not be seen).
- **Recommendation for I-1b.** `MenuBarExtra` gives no hook for its window's position, and it
  does not take the click through the button's action, so muxFinder cannot correct it inside
  `MenuBarExtra(.window)` without private API: use muxFinder's own `NSStatusItem` (D28's
  template image) and a borderless `NSPanel`. Anchor at the click, since the replicas'
  frames cannot be trusted: in the button's action, the current mouse event's location
  (`NSEvent.mouseLocation`), on the screen that contains it, below that screen's menu bar
  (`PopoverPlacement.screenIndex(for:in:)` and `frame(contentSize:anchor:screen:)`); use the
  real button's rectangle (`convertToScreen` of window 0's button) as the anchor when the
  click falls inside it, so the popover's middle is the icon's exactly where AppKit's frame
  is real, and when the action comes from no mouse event (`performClick(_:)`, VoiceOver). With
  muxFinder's own item the button's action is muxFinder's, so the diagnostic's
  `performClick(_:)` can open the popover in process for the "after the fix" record (anchored
  at the button by that rule); a click on each display's icon stays a person's check.

Verified in the Phase 13a spike (2026-10-24, iTerm2 3.7.6, tmux 3.8, `muxfinder-probe
e2e-bury --local` and `--ssh saturno-m4`, the default tmux servers holding only
`muxfinder-test-*` sessions; 4 local and 2 Saturno runs, all 12 of 12 PASS, the first local
one on the helper before the line feed; runs in `docs/TESTING.md`, *Phase 13a*). S1–S4 and
S6–S8 were confirmed at run time, locally and on Saturno; S5's "off" branch only from the
source:

- **This iTerm2 had `AutoHideTmuxClientSession` on** (read with `defaults read`, never
  written; Phase 4 ran with it off, and so did Phase 13c, below). So iTerm2 buried every
  launch tab itself by the time the
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

Verified in the Phase 13c real runs (2026-10-24, iTerm2 3.7.6, tmux 3.8; the coordinator's
bury on everywhere; every run exit 0 with every step PASS: `e2e-local` 16, `e2e-remote
saturno-m4` 17, `e2e-bury --local` and `--ssh saturno-m4` 13 each (both rerun after the
Phase 13c review's harness fix), the self-tests 8 and 7, `e2e-profile --local` 14; details in
`docs/TESTING.md`, *Phase 13c*):

- **iTerm2's default setting, at run time.** iTerm2 exited between two runs' gates (not by
  the run) and came back with `AutoHideTmuxClientSession` absent (read only), so these runs
  had the default (off). iTerm2 buried none of the 20 `e2e-bury` launch tabs itself before
  the coordinator's bury, and a buried tab whose helper wrote no
  `Disinter` stayed buried at the tmux end and became a dead buried session once its helper
  exited (S4, S5's "off" branch, until now known only from the source).
- **The bury.** Every confirmed attach (attach, reattach, concurrent attaches, new session,
  move here, the self-tests' Open and New session) ended `burial` `buried` with the tab in
  `buried_sessions` and in no tab; in the first two attaches of `e2e-local` and `e2e-remote`
  the bury and its check ended 29–31 ms after the activation locally, 76–105 ms over ssh.
- **The race** (`e2e-bury` step 7, the bury and a bound `detach-client` released together):
  the bury was sent and answered `OK` 8–10 ms after the release, before tmux ended, so on
  both hosts iTerm2 handled it before the helper's restore. Locally tmux ended at once (the
  detach's answer and the helper's result 39 ms after the release), the coordinator's check
  after the bury saw it and restored the tab: `restoredAfterEnd`. On Saturno the check came
  first (the attach returned at 39 ms, the helper's result at 165 ms): `buried`, undone by
  the helper's first restore. Both tabs left by themselves, with no `Close` and no restore of
  the coordinator's beyond that one. A detach sent first, with the bury only after its answer
  (the first runs), made the bury's ownership check refuse it on both hosts (`failed`
  `tmuxConnectionNotOwned`: the connection was gone, nothing buried), so that order never
  races and no longer counts as the race.
- **After a detach** the tab left both its tab and `buried_sessions` by itself in every run,
  with no restore or `Close` of the coordinator's: 1–271 ms after the helper's result for a
  detach after 10 s, 4.8–5.1 s for one at 5 s (the helper's minimum lifetime).
- **The dead tab** (no `Disinter`): the coordinator's recovery sent one restore and one forced
  `Close`, and the tab was gone within the step's 29 s bound of the helper's result. Without
  `Disinter`, a buried session answered the helper's status reports after 113 and 1004 ms
  locally; on Saturno the first two went unanswered within 2 s and the last was answered
  after 1139 ms (13a, with the setting on, saw 34–36 ms).
- **The abnormal end** (SIGKILL of the attach child while buried, setting off): the connection
  and its tmux tabs were gone 107–109 ms after the kill, the helper's first restore went
  unanswered and its second was answered (11 ms locally, 101 ms on Saturno); the tab was back
  in a tab 889 ms after the kill locally, possibly by the coordinator's recovery (it had sent a
  restore after the helper's failure result), and 2110 ms after it on Saturno by the helper's
  restores (in the reruns 1555 and 2127 ms, both possibly by the coordinator's recovery); the
  session survived in both places. The reruns also showed the helper's result
  `childSignaled(9)`, exit 137, on both hosts, and the tab in a tab at every look after it came
  back until 2 s past the helper's 10 s minimum lifetime and right before the harness closed
  it, its helper alive and waiting for Return, with no `Close` or further bury of the
  coordinator's. A forced `Close` of the restored tab answered `OK`, the tab gone 15–25 ms
  later.
- **The argv digest is rewritten after each restore** (since 13a), also after a later step
  took it, so `e2e-local` now leaves out digests of launches it already checked
  (`takeNewArgvDigests()`); its first attempt failed step 7 on that.
- iTerm2's thread count stayed at 17–23; nothing of any run was left, and `profiles hashes`
  was byte-identical before the first run and after the last.

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

Verified in Phase I-3a (2026-10-24, macOS 27.2 Build 26B118, the signed bundle binary's
`--report-hotkey-registration` run from the shell, twice; `docs/TESTING.md`, *Phase I-3a*):

- **`RegisterEventHotKey` with `kEventHotKeyExclusive`** on the application event target
  registered ⌃⌥⇧⌘F19 (`noErr`); a second registration of the same combination in the same
  process returned `eventHotKeyExistsErr` (−9878); after `UnregisterEventHotKey` it
  registered again. Nothing was left registered at exit (`unregisterAll()` reported no
  failure).
- **Only ⌥ or ⌥⇧ is not refused:** ⌥F19, ⌥⇧F19, ⌥J and ⌥⇧J all registered with `noErr` on
  this macOS 27.2, so the "macOS 15 and later refuses them" rule was not confirmed at
  registration. Whether their presses are delivered is not known (no press can be made
  unattended; checklist 18); D32 warns about them instead of refusing them.
- The run needs no permission and printed no prompt; `NSApplication.shared` was created but no
  window, status item or event was.

Verified in Phase I-4 (2026-11-04, macOS 27.3 Build 26C5035r, the signed bundle binary's
`--report-menu-bar-item` run from the shell under two private homes, before and after D33;
`docs/TESTING.md`, *Phase I-4*):

- **The empty window was SwiftUI's `Settings` scene's, and a shell launch showed it too.**
  Before D33, under an empty `CFFIXED_USER_HOME` and under one holding a saved `hosts.json`
  with every host off, the app listed a visible `SwiftUI.AppKitWindow` titled "muxFinder
  Settings" at level 0 (in the first home beside onboarding's "Welcome to muxFinder"). A
  temporary trace of `makeKeyAndOrderFront:` in the debug binary (removed before the fix)
  showed what ordered it front: `SwiftUI.AppWindowsController.showInitialWindow()`, called by
  SwiftUI's `AppDelegate.applicationDidFinishLaunching`, inside AppKit's handling of the
  launch's `oapp` Apple event (`_handleAEOpenEvent:`, `_sendFinishLaunchingNotification`). So
  SwiftUI shows its first scene's window at every launch, a `Settings` scene whose menu item
  is removed included. No saved window state was involved (there is no
  `cc.carpio.muxfinder.savedState`). Phase 9b's shell check (2026-10-22, macOS 27.2) recorded
  only the onboarding window on screen, so the window probably came with a later macOS
  (unverified).
- **A shell launch gets `oapp` as well:** `applicationDidFinishLaunching` ran with an `oapp`
  event current and `NSApplicationLaunchIsDefaultLaunchKey` true in both homes, before and
  after D33, so the app shell check takes the launch path Finder and the login item take
  (expected; a LaunchServices launch is the user's, checklist 19).
- **SwiftUI's main menu had no Settings item** (⌘, never reached it), no File menu, no Close
  and no Paste and Match Style. It had the app menu (About, Services, Hide ⌘H, Hide Others
  ⌥⌘H, Show All, Quit ⌘Q with `terminate:`), Edit (Undo ⌘Z, Redo ⇧⌘Z, Cut, Copy, Paste,
  Delete, Select All, then AutoFill, Start Dictation and Emoji & Symbols), an empty View menu,
  Window (Minimize ⌘M, Zoom, Bring All to Front, the window list) and Help (muxFinder Help
  ⌘?, a hidden Toggle Sidebar ⌥⌘S); every command went to the first responder.
- **After D33** no SwiftUI window exists: the first home lists the hidden popover panel and
  onboarding, the second only the hidden panel. AppKit added AutoFill, Start Dictation and
  Emoji & Symbols to the hand-built Edit menu and an alternate "Close All" (⌥⌘W, `closeAll:`
  to `NSApplication`) under Close. In a scratch process, the Close item (`performClose:`)
  validated as disabled for a borderless non-activating panel and a borderless status-bar
  window and enabled for a titled, closable one (`MainMenuTests` checks muxFinder's own
  classes).

Verified in Phase I-6 (2026-11-04, macOS 27.3 Build 26C5035r, the debug and the signed bundle
binary's `--preview-fixtures --preview-key-view-loop popover|switcher` run from the shell,
before and after the fix; no event made or posted, no key pressed; `docs/TESTING.md`, *Phase
I-6*):

- **Tab stayed in Name because the panel's key view loop was never recalculated.**
  `PopoverPanelWindow` had AppKit's default `autorecalculatesKeyViewLoop` (false). AppKit
  computed the loop once, when the panel was first shown with its list (search field focused;
  `initialFirstResponder` then the content view, `PopoverPanelContentView`), and nothing
  recomputed it when the New session form replaced the list. The form's controls kept the links
  SwiftUI gave them: Name's and Directory's `nextKeyView` their own
  `AppKitPlatformViewHost<PlatformViewRepresentableAdaptor<PlatformTextFieldAdaptor>>`, which
  takes no focus, the buttons' none, so `nextValidKeyView` and `previousValidKeyView` from Name
  were none, and Tab's action message to the field editor (`insertTab(_:)`, through
  `doCommand(by:)`) and ⇧Tab's (`insertBacktab(_:)`) left the editing in Name. The popover's
  panel and the switcher's alike (the switcher's form focuses Name itself; the popover's
  leaves the focus on the window until a click). With the directory list open, the views
  SwiftUI inserted relinked part of the chain (Name → Directory → the list's button → Cancel →
  Create → none) and ⇧Tab from Name still went nowhere.
- **Ruled out:** the key monitor (Tab is no `PopoverKey`, and the steps send no event at all,
  so it never runs, yet they failed the same); macOS's keyboard navigation setting (on here,
  `AppleKeyboardUIMode` 2, read only; the chain from Name ended at once, which no setting
  changes); the hosting setup (the `NSHostingView` a subview of the content view), the
  non-activating panel and the inactive app: a panel opened with the form already in it had an
  intact loop, and Tab's action message moved Name to Directory there, once with the panel key
  and the app active, once with neither.
- **With the loop recalculated** (the fix), AppKit rebuilds it the next time the window is
  asked for a key view (links read straight from the views before that are still the stale
  ones): Tab from Name goes to Directory, the list's button, Cancel, Create, the host picker
  and back to Name, ⇧Tab the same way backwards, in both panels and with the list open (its
  rows, drawn by SwiftUI, are no AppKit views, so they are not in the loop; the list stayed
  open). The order is the controls' reading order by position.
- **A text input window closes during editing:** the text cursor's indicator
  (`TUINSWindow`, closed by `TextInputUIMacHelper`'s `TUINSCursorUIController`) is a window of
  the app's that opens and closes as a field is edited; its close counted as the last window
  closing, and the preview app,
  whose delegate then quits, stopped in the middle of the first diagnostic runs (exit 0). The
  diagnostic's mode no longer quits that way; the gallery mode is unchanged.

Verified in Phase I-8 (2026-11-05, macOS 27.3 Build 26C5035r, keyboard navigation on; the debug
binary's `--preview-fixtures --preview-key-view-loop popover|switcher` before the fix, with
the routing's two new rules taken out for the run, and the signed bundle binary's after it,
run from the shell; the AppKit SDK headers, its standard key bindings file and the
Objective-C runtime of a scratch process read; no event made, posted or delivered, no key
pressed, no menu opened; `docs/TESTING.md`, *Phase I-8*):

- **The Host picker could not be changed from the keyboard because the panels' key monitor
  took its arrows.** ⇧Tab from Name does reach the picker (with keyboard navigation on): the
  window's own step back from the Name field (`selectKeyView(preceding:)`) and ⇧Tab's action
  message to Name's field editor (`insertBacktab(_:)`) both make `SwiftUIPopupButton`, an
  `NSPopUpButton` subclass (a pop-up, not a pull-down; 2 menu items in both fixtures), the
  first responder, in both panels, with the directory list closed or open (it stays open).
  (`selectPreviousKeyView(_:)` sent to the window with Name's field editor first leaves the
  focus in Name: the field editor is no key view; ⇧Tab never takes that path.) With it
  focused, the monitor sent ↑, ↓ and ⌥↓ to the panel's handler as with any other focus: ↑
  and ↓ were swallowed (`AppModel.handle(_:)` does nothing with them while a panel shows),
  ⌥↓ opened the directory list, and with the list open all three moved the list's highlight;
  so the pop-up button never saw them. Space is no panel key and already reached it; Return
  created, Esc closed the panel (or the list first). After the fix (`PanelKeyRoute`), with the
  pop-up button focused, ↑, ↓, ⌥↓ and Space go to it; Return and Esc are unchanged in both list
  states; with the focus in Name nothing changed.
- **AppKit's behaviour for a focused pop-up button, as read:** the standard key bindings
  (`/System/Library/Frameworks/AppKit.framework/Resources/StandardKeyBinding.dict`) send ↑
  `moveUp:`, ↓ `moveDown:` and ⌥↓ `moveForward:` then `moveToEndOfParagraph:`; in the runtime,
  `NSPopUpButton` implements `moveUp:`, `moveDown:` and `performClick:` itself (`NSButton`
  and `NSResponder` answer neither arrow message) and answers neither of ⌥↓'s messages, and
  `NSPopUpButtonCell` implements `keyDown:inRect:ofView:` and `performClickWithFrame:inView:`
  itself. `NSEvent.h` documents that a local monitor is
  not called for events consumed by nested tracking loops such as menu tracking, so an open
  menu's keys never reach the monitor; the menu-tracking rule is a second guard for keys that
  reach `sendEvent(_:)` while one is open. The headers do not document which key opens the
  menu: that Space opens it, what ↑/↓ do on the closed picker (open the menu, or step the
  selection), that ⌥↓ does nothing, that the menu opens from this borderless non-activating
  panel of an accessory app without the panel resigning key (a click on the picker already
  does, the user's report), that ↑/↓, Return, Space, Esc and type-to-select work inside it and
  Esc closes only the menu, and that `NSMenu.didBeginTrackingNotification` is posted for a
  pop-up button's menu, are all owed to a real press (checklist 22).
- **A never-shown panel has no AppKit pop-up button or buttons:** SwiftUI makes them only once
  the panel shows (a hidden panel's tree holds the text fields alone, after layout and a
  display pass), so the hidden-panel tests cannot reach the picker; the real picker's class
  and item count come from the diagnostic, and a pick is tested through the picker's binding.

**Phase I-12a proof.** Verified in Phase I-12a (2026-11-06, macOS 27.3 Build 26C5035r, tmux
3.8 on Neptuno and Saturno; `muxfinder-probe terminals list` and `plain-proof` run from a shell
in iTerm2 3.7.7 with `TMUX_TMPDIR` unset; `sdef` of both apps and Ghostty's public docs read;
no Apple event sent to Terminal or Ghostty, neither running; `docs/TESTING.md`, *Phase
I-12a*):

- **The apps** (LaunchServices by bundle identifier): iTerm2 3.7.7 at `/Applications/iTerm.app`,
  running; Terminal 2.15 at `/System/Applications/Utilities/Terminal.app` and Ghostty 1.3.1
  at `/Applications/Ghostty.app` (`com.mitchellh.ghostty`, as its `Info.plist` says), not
  running. `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded` false, from this
  shell (so for iTerm2 as the responsible app): 0 for iTerm2, -600 (target not running) for
  Terminal and Ghostty; no prompt appeared and neither app started.
- **Ghostty's dictionary** (`sdef /Applications/Ghostty.app`, 1.3.1): `new window [with
  configuration]` returns a window; `new tab [in <window>] [with configuration]` returns a
  tab; `new surface configuration [from]` returns a record with `font size`, `initial working
  directory`, `command` ("Command to execute instead of the configured shell"), `initial
  input`, `wait after command` ("Keep the terminal open after command exit") and `environment
  variables` (a list of `KEY=VALUE` texts). Windows, tabs and terminals each have an `id`
  (text, "Stable ID"); a terminal has `name` and `working directory`, and no tty, pid or
  process. Commands `activate window`, `close window`, `select tab`, `close tab`, `focus` ("a
  terminal, bringing its window to the front"), `close`, `split`, `perform action`, and the
  input commands `input text`, `send key` and `send mouse …` (never used).
- **Ghostty's docs** (ghostty.org, `features/applescript` and the config reference, read on
  2026-11-06): AppleScript is on by default on macOS; `macos-applescript = false` turns it all
  off; macOS asks before another app may control Ghostty. Config `command`: looked up in
  `PATH` when not absolute; with arguments it runs through `/bin/sh -c`; `direct:` skips the
  shell (no quoting, spaces or globs), `shell:` forces it (both since 1.2.0), and without a
  prefix Ghostty guesses. `wait-after-command` keeps the terminal until a key is pressed;
  `env` adds variables for a surface's commands. The pages do not say whether a surface
  configuration's `environment variables` reach its `command`, how AppleScript's `command`
  is parsed, or what the ids look like: owed.
- **Terminal's dictionary** (`sdef /System/Applications/Utilities/Terminal.app`, 2.15): `do
  script [<text>] [in <tab or window>]` returns "the tab the command was executed in"; `do
  script in new tab [<text>] [next to <tab or window>]` (default: the frontmost window)
  returns a tab. A window has `id` (integer, "unique identifier"), `index`, `frontmost`,
  `visible`, its tabs and `selected tab`; a tab has no id, and has `tty` ("The tab's TTY
  device", text), `processes` (texts), `busy`, `selected`, `contents` and `history` (never
  read).
- **Plain clients on a pseudo-terminal** (`plain-proof --local`): tmux 3.8 reports a plain
  client with `client_tty` and `client_name` both its terminal's path, `client_termname`
  `xterm-256color` (from `TERM`), its size from the terminal (80x24), `client_control_mode`
  0 and flags `attached,focused,UTF-8`. tmux's server draws through the descriptor the
  client passed as its standard input, so that descriptor must be open read-write (with a
  read-only one nothing was drawn in 2 s; only the detach line came). A detached plain client
  exits 0; one ended by SIGTERM exits 1; ssh ended by SIGTERM exits 255. When the process that
  holds a terminal as its controlling terminal exits, macOS revokes that terminal for every
  holder (the harness's own descriptor too), its master reads end of file, and the next
  pseudo-terminal opened gets the same path (locally the move-here client got the first
  client's `/dev/ttys004` in every run; on Saturno its `/dev/ttys003`). A spawn file action
  opens a terminal before macOS makes the new session, so it does not become the controlling
  terminal; a session leader opening it does (`ps -o tty=` shows it).
- **Bound commands in tmux 3.8** (the review's fixes, on private servers under `mktemp -d`
  `TMUX_TMPDIR`s with `muxfinder-test-*` sessions, plain clients on pseudo-terminals and
  control clients, then on the default servers through `plain-proof`): `if-shell -F -t
  '<id>' '<condition>' '<command>' '<otherwise>'` from the CLI runs the chosen command for
  that CLI client right after the check (an inserted `attach-session` makes that very client
  the attached one, with its terminal, pid and parent; an inserted `detach-client -t` detaches
  the named client); a missing `-t` id makes the condition false with exit 0. Inside the
  client loop `#{L:…}` (attached clients only) `client_name`, `client_pid`,
  `client_created` and `client_session` are the client's, `session_id` the target's. An
  inserted `run-shell 'exit 65'` makes the unattached CLI client exit 65 (it prints `'exit
  65' returned 65` to that client, 23 bytes on its terminal). A matching bound attach with
  no terminal on standard input fails with `open terminal failed: not a terminal` (exit 1)
  before `-d` detaches anyone. With no server `if-shell` exits 1 (`error connecting to …`)
  and creates no server or socket.
- **The runs** (`plain-proof`, final code with the review's fixes): `--local` 9 of 9 in
  1.5 s: the first client confirmed by its `client_tty` 241 ms after its start (readings
  every 200 ms, each at most 20 ms), a terminal with no client matched none and a stale
  attach there (the server's start time 1 s off) exited 65 after 60 ms attaching nothing,
  two clients told apart, two clients on one terminal refused and, while they shared that
  name, the bound detach of one detached nothing (10 ms), a stale bound detach (creation time
  1 s off) detached nothing (11 ms) and the real one ended only that client in 9 ms (its child
  exit 0), a stale move here exited 65 with the other client still attached, the move-here
  client the only one within 244 ms and the other's child exit 0, its bound detach in 11 ms.
  `--ssh saturno-m4` 9 of 9 in 20.7 s: the first client confirmed by its token 1661 ms after
  its ssh started (1661–1678 ms over four runs), readings 727–744 ms (median 730–733 ms, one
  ssh connection each), a token nobody carries matched none and a stale attach with a new
  token exited 65 after 792 ms (the guard), two tokens told apart, the same token twice
  refused, a stale bound detach detached nothing (713 ms) and the real one ended only that
  client in 717 ms (one connection), a stale move here exited 65 with the other client still
  attached, the move-here client the only one 1663 ms after its start, its bound detach in
  714 ms. The runs before the fixes (the same steps without the stale checks, D37's two-command
  detach): 9 of 9 each, 1.3 s and 17.7 s. A run stopped by SIGTERM during step 4 cleaned up
  (its two clients ended, its session killed) and exited 143. After every run: no
  `muxfinder-test-*` session and no launch shell on either Mac, no child process of the
  harness, nothing in `/private/tmp`.

## Unattended-run rules (binding for every phase)

The run is unattended and shares this Mac, and this iTerm2 instance, with the user's live
work. The autoclaude session itself runs inside an iTerm2 tab.

1. **Never touch iTerm2 windows, tabs or sessions you did not create in the current test.**
   Never send text to, close, or reorder them. Close or detach only through ids your test
   recorded at creation. The same holds for Terminal.app and Ghostty windows and tabs (since
   Phase I-12a): a test touches only windows it opened, never types into any, and closes one
   only by the id it recorded, only after its process has ended.
2. **tmux:** create only sessions named `muxfinder-test-*`, and kill only those. Never run
   `kill-server` or touch other sessions. Applies locally and on Saturno.
3. **Remote:** Saturno (`saturno-m4`) is authorized for read-only discovery and for
   creating/attaching/detaching/killing `muxfinder-test-*` sessions. No other host. No file
   writes on remote hosts. Also authorized (by the user, 2026-11-06, for remote folder
   search): read-only Spotlight queries for folders on Saturno and on this Mac (`mdfind`,
   `mdutil -s`, and readability tests such as `[ -r ~/Documents ]`). Record only counts and
   timings, never a folder name or path, in logs, fixtures, docs or commits.
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
8. **Never launch Terminal.app or Ghostty** (they restore the user's saved windows and may show
   dialogs nobody can answer), and never send either an Apple event unless it is already
   running and its Automation permission reads granted without a prompt. Otherwise its real
   runs are owed to the user.

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
S5's "off" branch, which the Mac's iTerm2 setting hid; the Phase 13c runs, with the setting
off, confirmed that branch too):
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

### Phase I-1 — Popover under the menu bar icon (high)

From the inbox (2026-10-24). The full specification, with the user's request verbatim, the
findings, the requirements (diagnose first; placement below the icon, centered, clamped to
the clicked display's visible frame, no arrow; keep `MenuBarExtra(.window)` if the cause has a
fix there, else an `NSStatusItem` and a borderless `NSPanel` muxFinder owns; placement as a
pure function with tests; the unchanged behaviors) and the acceptance, is
`autoclaude/processed/10-popover-under-menu-bar-icon.md`. It binds both sub-phases.

**Opening step decided (orchestrator, 2026-10-24):** the diagnostic may open muxFinder's own
popover by calling its own status item button's `performClick(_:)` in its own process. That
is not UI scripting under `CLAUDE.md` and *Unattended-run rules* 6: no event is posted to the
system, no Accessibility or AppleScript is used, and no other app's window is touched. It works
only once muxFinder owns the button's action (I-1b): SwiftUI's `MenuBarExtra` button has none,
and SwiftUI private internals and synthesized mouse events (in process too) stay out, so the
diagnostic exits 4 ("not openable in process") on that scene instead of clicking. Bounds:
the popover stays open at most 3 s, the flag closes it and exits on every way out, it runs at
most a few times per sub-phase (it may take the key focus from the frontmost app for that
moment), and it never runs through `open`/LaunchServices. If the screen is locked or the
display asleep, it reports what it could measure and says so.

Split (recorded before the first worker):

- **I-1a — Diagnose: placement diagnostic, placement function (high).** Deliverables: the
  read-only launch flag `--report-popover-placement` (in-memory empty host list as the
  self-tests; no `hosts.json`, refresh engine or iTerm2; no defaults written; the status
  item's visibility unchanged), printing every status-bar window with its screen, the
  button's window frame and `convertToScreen`, the popover window's frame and screen, every
  `NSScreen`'s `frame`, `visibleFrame` and scale, the menu bar's bottom per screen and the
  frame the placement function would give; the pure placement function (for example
  `PopoverPlacement.frame(contentSize:anchor:screen:)`) with the specification's five test
  cases; the diagnostic run on this Mac and its cause recorded in *Verified facts* and in
  `docs/TESTING.md` ("before the fix"); the `CLAUDE.md` command note for the flag. The app's
  normal popover is unchanged in I-1a.
  Acceptance: the placement tests pass; the diagnostic leaves no child, creates no
  `hosts.json` and leaves no window open, exiting 0 when it measured the popover and
  otherwise with its documented reason and status; the cause (or what could not be measured,
  and why) is recorded; `--report-menu-bar-item` unchanged; shared verification and
  `scripts/build-app.sh` + `codesign --verify --deep --strict` pass. Outcome: nothing within
  the run rules opens the `MenuBarExtra(.window)` popover in process, so on that scene the
  diagnostic exits 4 ("not openable in process", reason printed) without clicking, not 0; the
  before-fix popover frame is recorded as unmeasured (the cause an inference from the window
  frames, the user's report the only observation of the before state), and measuring the
  popover moves to I-1b.
- **I-1b — Place the popover under the icon (high).** Deliverables: the fix the I-1a cause
  calls for, using the placement function; a new decision **D30** (D22 and D28 edited where
  they change); the diagnostic re-run ("after the fix": the popover's horizontal middle
  within 2 pt of the icon's unless clamped, its top at the menu bar's bottom ± 1 pt) in
  `docs/TESTING.md`; tests over fakes for any new status-item controller (toggle, close,
  visibility glue); `docs/ARCHITECTURE.md`, `README.md` where they describe the popover;
  `docs/MANUAL-CHECKLIST.md` item (each display, after ⌘-drag, Esc / click outside / app
  switch close it, shortcuts, over a full-screen Space). Acceptance: the specification's, and
  the after-fix diagnostic opens the popover through muxFinder's own button action
  (`performClick(_:)` in process) and measures it: exit 0. If the screen is locked then, the
  record says what could and could not be measured, and a by-eye check stays in
  `docs/MANUAL-CHECKLIST.md`. Outcome: **D30** (muxFinder's own `NSStatusItem` and
  non-activating `NSPanel`, the anchor rule, the toggle rules); the after-fix diagnostic
  opened the panel through the button's own action and measured it (exit 0, twice: panel
  middle x 1430 on the button's 1430, and 1431 on 1431 on the next tree, top 1698 on the menu
  bar's bottom 1698, both offsets 0 each time), with the screen locked and both displays
  asleep, so the panel did not become key and its keys,
  focus and the other display's icon stay checks by hand (`docs/TESTING.md`, *Phase I-1b*;
  `docs/MANUAL-CHECKLIST.md`). The review (Codex, `ship-with-fixes`, 2 should-fix) led to the
  press identity by the hardware press count and `PopoverHeightLimit`; the final tree's run
  (unlocked, screen 1 main) found the real button at screen 1's right edge {4118, 2139} and
  the panel clamped 8 pt inside it, top on the menu bar's bottom, exit 0.

### Phase I-2 — New session: pick the directory (high)

From the inbox (2026-10-24). The full specification, with the user's request verbatim, the
user's decisions (one saved list shared by all computers, recents per host, the start folders
of the host's sessions suggested too; no Finder "Choose…" panel, no browsing over SSH), the
findings, the design (store, recording rules, session folders in discovery, the picker,
Settings, keys, self-tests, privacy) and the acceptance, is
`autoclaude/processed/20-new-session-directory-picker.md`. It binds both sub-phases; its
design is recorded as **D31**.

Split (recorded before the first worker):

- **I-2a — Directory store, session folders in discovery, recording (high).** Deliverables:
  the `directories.json` store in `MuxFinderCore` (schema 1, loaded and written as D19 treats
  `hosts.json`: `PrivateStorage`, 0600, safe publication, size cap, unknown keys ignored,
  loading never writes, an invalid or unsafe file gives empty lists and a notice and is left
  as it is; every entry through `Validation.workingDirectory`, failures dropped and counted;
  at most 50 saved and 8 recent per host, newest first, duplicates by exact string; the
  operations I-2b needs: add, remove and reorder saved, record and clear recents, prune
  removed hosts' recents at the next write); the probe's session-folder record
  (`#{session_path}`, framed so a path with tabs, newlines or control characters can neither
  break nor forge a line, dropped by the parser when it holds control characters), probe and
  parser changed together, golden fixtures and parser tests; the session's optional start
  folder through `HostSnapshot` (a stale snapshot keeps its last folders), printed by
  `discover` and `refresh --once`; the recording rules on the model's `onCreated` path
  (created → recorded, also when the attach fails afterwards; collision, failure,
  `mayHaveCreated` or an empty field → nothing; a failed write logged by kind only, never
  failing the creation); store injection so the self-tests and preview fixtures never read or
  write the real file; **D31**; `docs/ARCHITECTURE.md` (the new file, the probe record);
  `CLAUDE.md` where a command's output or a test rule changes; `scripts/uninstall.sh`
  confirmed to remove the support folder (no change expected). Acceptance: the store,
  parser and recording unit tests of the specification pass; existing tests pass unchanged
  or with recorded additions; real read-only `discover --local` and `discover --ssh
  saturno-m4` report session folders that parse (counts only recorded, in `docs/TESTING.md`);
  `--selftest new-session-local` passes with the thread-count gate (its path now injects the
  store); shared verification and `scripts/build-app.sh` + `codesign --verify --deep
  --strict` pass. The app's UI does not change in I-2a. Outcome: **D31** (the store with its
  `directories.lock`, an unusable file refused by every mutation and left untouched; the
  nonce-framed `path` record, a path over 4,096 bytes printed empty and dropped; recording on
  `onCreated`; the in-memory store for the self-tests); real `discover --local` and `--ssh
  saturno-m4` (with a test session made for it) parsed every folder, none dropped, and
  `--selftest new-session-local` passed 7/7 with no `directories.json` created. The review
  (Codex, `ship-with-fixes`, 3 should-fix) led to the refusal, the lock and the output budget
  (`docs/progress-archive/i-2a.md`).
- **I-2b — Picker, keys, Settings "Directories", galleries and documents (routine).**
  Deliverables: the picker content per host (Recent, Saved, "Sessions on <host>" with at most
  10 distinct sorted folders; empty sections hidden; the nothing-to-pick state; "Save this
  directory", "Clear recent directories on <host>"), the pull-down button at the Directory
  field's trailing edge, middle truncation with the full path in help and accessibility,
  picking fills and checks the draft, the host change keeps the field; the keys (open from
  the keyboard, ↑/↓ inside, Return still creates, Esc closes the list first); the Settings
  "Directories" section (add checked inline, remove, reorder; Save/Revert as D23 unless a
  recorded reason says otherwise); New session and Settings preview gallery states, light
  and dark through `--preview-snapshot`, in `docs/screenshots/`; `README.md`,
  `docs/ARCHITECTURE.md`, `docs/MANUAL-CHECKLIST.md` (create from a recent, a saved and a
  session folder, on This Mac and Saturno). Acceptance: the specification's picker, picking
  and key tests pass; the galleries are regenerated and inspected; the hermetic
  install-script check passes; shared verification and `scripts/build-app.sh` + `codesign`
  pass. Outcome: **D31** extended (an in-popover list rather than a menu, so its keys go
  through `PopoverKey.openList` and `AppModel.handle(_:)` and the galleries render it; the pure
  `DirectoryPickerContent`; one store queue in `AppModel`; Settings' own Directories tab with
  Save and Revert); 28 new UI tests in `DirectoryPickerTests` and `SettingsDirectoriesTests`,
  no existing test changed; the attach and Settings galleries regenerated light and dark
  (`--preview-snapshot` now fits the window to the content first); the self-test's create
  path unchanged; creating from each source in the real app and the keys by hand are
  checklist 17. Review fixes (Phase I-2b review, D31): Settings' Save is a `mergeSaved`
  three-way merge run by the store under its lock (one new `DirectoryListChange` case in
  `DirectoryLists.swift`), editing the Directory field drops the list's highlight, and list
  rows, sections and `DirectoryLists ==` compare byte for byte; 6 more UI tests and 2 more
  core tests (`everyChange` gained `mergeSaved`), each failing with its fix reverted. Real
  run: `--selftest new-session-local` 7/7 with no `directories.json` created. The
  install-script check's step 26 now matches the readers' pids instead of any "also running
  from" warning (the user's installed muxFinder had tripped it); 35/35, and it still fails
  with the uninstall script's identity check removed (`docs/progress-archive/i-2b.md`).

### Phase I-3 — Global hotkey: session switcher (routine)

From the inbox (2026-10-24). The full specification, with the user's request verbatim, the
user's decisions (a switcher panel of its own, Spotlight-like and keyboard-first; no default
shortcut; not part of Phase 14; after I-1 and I-2), the findings, the design (shortcut value,
storage, registrar, Settings recorder, panel, content, actions, engine visibility, keys,
accessibility) and the acceptance, is `autoclaude/processed/30-global-hotkey-session-switcher.md`.
It binds both sub-phases; its design is recorded as **D32** (D22 and D23 edited).

**Calls made before the first worker (orchestrator, 2026-10-24):**

- **The diagnostic flag is allowed.** `--report-hotkey-registration` calls Carbon's
  `RegisterEventHotKey`/`UnregisterEventHotKey` on muxFinder's own event target in its own
  process. That is not UI scripting under `CLAUDE.md` and *Unattended-run rules* 6: no event is
  posted or synthesized, no Accessibility or AppleScript is used, no other app is touched, and
  nothing is pressed (so it proves registration and its refusals, never that a press fires; a
  press stays a check by hand). Bounds: only fixed test combinations unlikely to be in use
  (never the user's saved shortcut), the shortcut file never read or written, every
  registration undone before exit on every way out, no window, menu bar item, engine, host
  list or iTerm2; a few runs per sub-phase at most; never through `open`/LaunchServices.
- **Storage is a file, not the defaults domain.** The shortcut lives in
  `~/Library/Application Support/muxFinder/preferences.json` (schema 1, D19's safe writes
  through `PrivateStorage`), not in `cc.carpio.muxfinder` defaults: `CLAUDE.md` binds the app to
  owning only that support folder and `DynamicProfiles/muxFinder.json`; tests then run on a
  private folder from `mktemp -d` like `HostStore` and `DirectoryStore` and never touch
  `~/Library/Preferences`; and the app shell check's empty `CFFIXED_USER_HOME` isolates it
  without relying on how `cfprefsd` treats that variable. Uninstall already removes the folder.
- **The recorder applies at once** (like the launch-at-login toggle, D23), not through
  Save/Revert: whether a combination registers is only known by registering it, and "taken"
  must show as the user records.

Split (recorded before the first worker):

- **I-3a — Shortcut, storage, registrar, Settings recorder (routine).** Deliverables: the
  shortcut value (key code + modifiers; validation: a modifier besides ⇧ unless F1–F20, the
  system's own combinations refused, a warning before ⌘ plus one key, and whatever macOS 15+
  refuses to register, verified with the flag); the label (modifier symbols plus the key as the
  current layout prints it, through a layout seam with a fake for tests); `preferences.json`
  (loading never writes; missing, invalid or unsafe → hotkey off, the file left as it is;
  written only when the user records or clears); the `HotkeyRegistering` seam, the Carbon
  implementation and a fake; the lifecycle in normal mode only (register once launching has
  finished, again on a change, unregister on clear and at quit; self-tests, previews, every
  `--report-*` flag and `--remove-persistent-profiles` never read the file or register); the
  Settings > General "Show session switcher" section with a hand-written recorder (click, type;
  Esc cancels, Delete clears, a "Clear" button; the current hotkey suspended while recording;
  a failed registration shown beside it, never an alert; diagnostics by kind only); the
  hotkey's action through one entry point that, until I-3b, toggles the existing popover panel
  (D30) as an interim; `--report-hotkey-registration`; the Settings gallery's recorder states
  (empty, recording, set, taken) light and dark; **D32** (I-3a part), D23 edited; `README.md`
  (setting the shortcut), `docs/ARCHITECTURE.md`, the `docs/TESTING.md` matrix, the `CLAUDE.md`
  flag note, `docs/MANUAL-CHECKLIST.md` (record, a taken shortcut's message, "Clear", survives
  a relaunch, the label on the user's layout, a press from another app). Acceptance: the
  specification's shortcut, label, storage and registrar tests pass (storage on a private
  folder); existing UI tests pass unchanged; the flag run in the signed bundle registers and
  unregisters its combination (exit 0, recorded in `docs/TESTING.md`) and leaves nothing
  registered; `--report-menu-bar-item` behaves as before; the hermetic install-script check
  passes and uninstall removes `preferences.json` with the support folder; shared verification
  and `scripts/build-app.sh` + `codesign --verify --deep --strict` pass. Outcome: **D32** (the
  value with its refusals and warnings, the label through `KeyboardLayoutNaming`,
  `preferences.json` with `preferences.lock` and other keys kept, the exclusive Carbon
  registrar with its handler on the event dispatcher target, the lifecycle through
  `AppEnvironment.globalShortcut` in normal mode only, the recorder applying at once, the
  interim popover toggle through `AppModel.globalShortcutPressed()`, the flag) and D23
  edited. The flag's first run found that macOS 27.2 registers only-⌥ and only-⌥⇧
  combinations (`noErr`), so they are warned about rather than refused (*Verified facts*);
  the second run on the final tree exited 0, 8 of 8 checks as expected, nothing left
  registered. 45 new unit tests (20 core, 25 UI), no existing test changed; the Settings
  gallery regenerated light and dark with five recorder states; `--report-menu-bar-item` as
  before with no `preferences.json` created; the install-script check 35/35, and
  `scripts/uninstall.sh` removes `preferences.json` with the support folder (unchanged). A
  press, a taken shortcut, a relaunch and the label on the user's layout are checklist 18.
  Review fixes (Phase I-3a review, D32): a failed unregistration keeps the registrar's
  reference and the model's token and is shown beside the recorder and in diagnostics
  instead of claiming the hotkey is off; a save that finds `preferences.json` unusable leaves
  the hotkey off as at launch, the file as it is, and "Try again" able to reload it; and
  another Settings tab or the recorder going away stops recording; with four regression
  tests (`carbonRegistrarKeepsAFailedUnregistration`, `aFailedUnregistrationKeepsTheHotkey`,
  `anUnusableFileFoundBySavingCanBeRetried`, `settingsStopsRecordingOnAnotherTab`) that fail
  with their fix reverted.
- **I-3b — Switcher panel (routine).** Deliverables: the non-activating switcher `NSPanel`
  (width recorded in D32), its content, keys, actions and failure carry-over as the
  specification's items 5–10; the hotkey's entry point switched from the interim popover toggle
  to the switcher; the combined visibility rule for the engine (D22 edited); `--preview-gallery
  switcher` light and dark; `README.md`, `docs/ARCHITECTURE.md`, the `docs/TESTING.md` matrix,
  `docs/MANUAL-CHECKLIST.md` (press over a full-screen app, filter and open, create, Esc
  returns the focus). Acceptance: the specification's content, keys, visibility-rule and
  failure-carry-over tests pass; existing UI tests pass unchanged; the gallery is rendered and
  inspected; shared verification and `scripts/build-app.sh` + `codesign` pass. Outcome: **D32**
  extended (the panel: the popover's non-activating `PopoverPanelWindow` at the floating
  level, **540 pt wide**, centered on the display with the keyboard focus, its top 18 % of the
  visible height down; `SwitcherContent` with pinned rows and the New session row's name;
  `handleSwitcherKey(_:)` over `PopoverKey` and the shared `PanelKeyTrackingView`; the popover's
  Open and New session form; success closes it, a failure stays, a failure once closed is
  carried to the next opening and the popover row; the combined visibility) and D22 and D30
  edited. The popover's panel host, observers and key view became shared (`PanelHost`,
  `PanelObservers`, `PanelKeyTrackingView`) rather than copied; `PopoverController` now reports
  a new visibility before its panel shows, so a swap never reaches the engine as a close; its
  interim `shortcutPressed()` and `AppModel.togglePopover` are gone (`CloseReason.shortcut`
  became `switcherOpened`). 25 new UI tests (`SwitcherContentTests`, `SwitcherControllerTests`,
  `SwitcherModelTests`); three I-3a tests in `GlobalShortcutAppTests` that asserted the interim
  popover toggle now assert the switcher (two count `toggleSwitcher`, and
  `theShortcutTogglesThePopover` became `theShortcutTogglesTheSwitcher`), no other test
  changed; 815 core + 317 UI tests pass. The switcher gallery rendered light and dark and
  inspected (9 states), the Settings gallery regenerated for the General tab's new note;
  `--report-menu-bar-item` as before (exit 0, no child, the private home empty). No `e2e-*`
  run or self-test (the attach path is unchanged); a press, the real panel over a full-screen
  app, opening with iTerm2 coming forward, creating and Esc giving the focus back are
  checklist 18. Review fixes (Phase I-3b review, D32): the switcher remembers the row it
  selects at each opening, each filter change and before each engine update, so a refresh
  never moves the selection or Return's target; a pinned row the engine does not list opens
  through its retained target on its host as enabled now, or shows that its host is no longer
  turned on; a creation failure held back by the popover's Move here confirmation shows once
  that ends or at the switcher's next opening; and a close from outside made by a press on
  muxFinder's status item is left to the popover that press opens, so the handoff sends no
  closed and opened pair in either order; with regression tests
  (`aRefreshKeepsTheAutomaticSelection`, `aPinnedRetryAttachesThroughItsRetainedTarget`,
  `aPinnedRetryOnAHostTurnedOffShowsWhy`, `aCreationFailureHeldBackByMoveHereShowsOnceItEnds`,
  `aCreationFailureHeldBackByMoveHereShowsAtTheNextOpening`,
  `statusItemHandoffWithTheOutsideCloseFirst`, plus `statusItemHandoffWithTheButtonActionFirst`
  for the other order) that fail with their fix reverted (the last passes either way), and
  `arrowsMoveWithoutWrapping` now expects the remembered first row instead of `nil`. On the
  final tree 815 core + 324 UI tests pass.

### Phase I-4 — No empty "muxFinder Settings" window at launch (routine)

From the inbox (2026-11-04). The specification, with the user's report verbatim, the findings,
the requirements and the acceptance, is `autoclaude/processed/40-empty-settings-window-at-launch.md`.
Its design is recorded as **D33** (D22 and D30 edited), its diagnosis under *Verified facts*
"Phase I-4". Not split. The orchestrator's one call: the specification's `CLAUDE.md` command-note
edit (its requirement 4) waits, because `CLAUDE.md` carries the user's uncommitted edit and a run
never commits the user's paths; the wording owed is in `PROGRESS.md` *Open risks*.

### Phase I-5 — Session switcher: one click activates a row (routine)

From the inbox (2026-11-04). The specification, with the user's request verbatim, the user's
decision (one click activates every row, as in the popover and Spotlight), the findings, the
requirements and the acceptance, is
`autoclaude/processed/50-switcher-single-click-activates.md`. D32's *Keys* item edited. Not
split.

Outcome: a session row and the New session row each have one tap gesture, calling
`AppModel.clickSwitcherItem(_:)`, which selects the row and activates it at once as Return
does (`activateSwitcherItem(_:)`: the popover's Open, or the form with ⌘N's draft); the
double-click handler and `selectSwitcherItem(_:)` are gone. Because the first click now
changes what is under the pointer (the form replaces the list, the panel keeping its top edge
and resizing, so a double click on "New session…" could land its second click on the form's
directory list button, Cancel or Create), the click also makes the panel ignore the rest of
that click sequence: `SwitcherClickSequence`, a pure value applied by
`SwitcherWindowTrackingView`'s local monitor to the left mouse button's events in the
switcher's window, drops presses whose click count is above 1 (with their drags and releases)
until a press starts a sequence of its own; Return and the accessibility action do not arm
it, and each opening and closing of the switcher forgets it. A second activation of a row
already opening is ignored by D25's in-flight rule as before, and `newSessionFromSwitcher()`
now does nothing while the form shows (it used to put the filter's name back over the user's
edit). Hover, the context menu, Return, ↑/↓, ⌘N, Esc, the
accessibility actions and hints (neither hint mentioned a double click), pinned rows, the
failure carry-over and closing on success are unchanged; so is the switcher gallery. New
tests in `SwitcherClickTests`: `aClickOnASessionOpensItAsReturnDoes`,
`aClickOnNewSessionShowsTheFormAsCommandNDoes`, `aSecondActivationOfARowOpeningStartsNothing`,
`aSecondActivationOfNewSessionLeavesTheDraft` (fails with the `newSessionFromSwitcher()` fix
reverted), `theRestOfAnActivatingClickIsIgnored`, `aRowActivatedOnThePressKeepsItsRelease`,
`onlyAClickIgnoresTheRestOfItsSequence`; no existing test changed. On the final tree 815
core + 343 UI tests pass. Review fixes (Phase I-5 review, D32): with a list taller than the
New session form, a quick double click on "New session…" shrank the panel under the pointer
(its top edge kept), so the second click reached the window behind it and closed the switcher
as a press outside; and a click on a session open here could close the switcher, its focus
succeeding with iTerm2 coming forward, before the second click. Now `clickSwitcherItem(_:)`
first asks the controller to hold the panel (`AppModel.holdSwitcherForClick`,
`SwitcherController.holdForClick()`): until `NSEvent.doubleClickInterval` has passed (read
through `SwitcherSystem.doubleClickInterval`, the end scheduled through
`SwitcherSystem.runAfter`) the content lays itself out no shorter than the panel was
(`PopoverPanelSurface.minimumContentHeight`, `PopoverHeightLimit.minimumHeight`: the switcher
at the top, `SwitcherPanelRoot` painting its opaque background below, so that area is the
panel's and the click is dropped there by `SwitcherClickSequence`), a shrink waiting and
growth applied at once, and a close for `actionSucceeded`, `appSwitch` or `resignedKey`
waits for the end (`CloseReason.waitsForClickHold`), so the engine hears the same one closed,
later; every other close is made at once, each close ends the hold, and a hold's end
changes nothing once a close or a later click's hold replaced it. A scratch render of the real
panel host showed the held form at the top with the background below. With regression tests
(`aClickHoldsAShrinkUntilTheIntervalEnds`, `growthDuringAHoldIsAppliedAtOnce`,
`aSuccessCloseWaitsForTheHold`, `aReopenedSwitcherInheritsNoHold` in
`SwitcherControllerTests`; `onlyAClickHoldsThePanel`,
`aFocusAfterAClickClosesOnceTheIntervalEnds` in `SwitcherClickTests`;
`switcherRootIsNoShorterThanItsMinimum` in `PopoverHeightLimitTests`) that fail with their
fix reverted (the growth test with a hold that freezes the frame instead); the test panel and
switcher system gained the minimum and the two seams, no other test changed. On the final
tree 815 core + 350 UI tests pass.

### Phase I-6 — New session: Tab moves from Name to Directory (routine)

From the inbox (2026-11-04). The specification, with the user's report verbatim, the findings,
the requirements and the acceptance, is
`autoclaude/processed/60-new-session-tab-between-fields.md`. Its diagnosis is under *Verified
facts* "Phase I-6"; D30's *Panel*, D31's *Keys* and D32's *Keys* items edited. Not split.

Outcome: the cause was the panels' key view loop, computed once when a panel was first shown
with its list and never again (`autorecalculatesKeyViewLoop` false, AppKit's default), so the
New session form that replaces the list had fields linked to SwiftUI's view hosts, and Tab and
⇧Tab left the focus in Name, in the popover and the switcher alike. The native route was
taken: `PopoverPanelWindow` (both panels' class) now recalculates its loop, and Tab and ⇧Tab
move through the form in reading order (Name and Directory; with keyboard navigation on, the
host picker, the list's button, Cancel and Create too), wrapping inside the panel; no
`PopoverKey` and no model state were added, since AppKit's loop already gives the order, the
keyboard navigation rule and the input method's precedence. Tab with the directory list open
moves on and leaves it open (D31). The diagnosis came from a new read-only preview-fixture
diagnostic, `--preview-fixtures --preview-key-view-loop popover|switcher`
(`KeyViewLoopReport`: muxFinder's real panel over a fixture, the list first, then the form;
it prints the key views, their links, the chains from Name and where each Tab or ⇧Tab step
takes the focus, a step being the key binding's own action message or the window's own
`selectNextKeyView(_:)`, never an event); in that mode the preview app no longer quits when the
text cursor's indicator window closes. New tests in `NewSessionTabOrderTests`:
`panelsRecalculateTheirKeyViewLoop` and `tabMovesFromNameToDirectoryAndBack` (both panels,
real but never shown; both fail with the fix reverted, the second on its ⇧Tab step),
`tabIsNoPanelKey`, `keyViewLoopFlag`; no existing test changed. The galleries are unchanged.
On the final tree 815 core + 354 UI tests pass.

### Phase I-7 — New session: typing in Directory filters the directory list (routine)

From the inbox (2026-11-04). The specification, with the user's request verbatim, the user's
decisions (the Directory field is the search, combo-box style; typing opens the list while
something matches and closes it when nothing does; Esc closes and keeps the text; the button
and ⌥↓ still open it), the findings, the requirements and the acceptance, is
`autoclaude/processed/70-new-session-directory-list-filter.md`. D31's list content and keys
items are edited. Not split.

The orchestrator's calls, made before the worker: **the `~` rule** — the field's text
(trimmed) is matched as typed, never expanded; on This Mac, whose home folder is known, each
entry is matched in three spellings (as stored, with a leading home folder written `~`, and
with a leading `~` or `~/` spelled out as the home folder), so `~/proj` finds a session folder
`/Users/<me>/projects` and `/Users/<me>/pr` finds a saved `~/projects`; on an SSH host, whose
home is unknown, each entry is matched only as stored (`~user` forms are never expanded).
**Clearing the field** is not a search: an edit that leaves the trimmed text empty shows the
whole list again but never opens it, and closes a list that typing opened (a list opened with
the button or ⌥↓ stays open).

Outcome: New session's Directory field is the directory list's search in the popover and the
session switcher (D31's picker and keys items edited). `DirectoryPickerContent` filters each
section by the field's trimmed text (`query`; `entry(_:matches:field:home:)`, the popover's
`PopoverContent.matches(_:query:)` rule, an exact byte-for-byte match always kept), applies the
`~` rule through `spellings(of:home:)` with This Mac's home folder injected (`thisMacHome`,
used only for a This Mac host; `AppEnvironment.homeDirectory`, `NSHomeDirectory()` in the app,
`nil` in tests and the self-tests, `/Users/example` in fixtures), and tells "No matching
directories" (`noMatches`) from "Nothing to pick yet" (`isEmpty`, now counted before the
filter); the actions are never filtered. The "opened by" state lives in
`DirectoryPickerState.opening` (`request` for the button, Space and ⌥↓; `typing`; `isOpen` is
now derived from it). The model's draft observer still drops the highlight on every change,
then hands a user edit to `directoryFieldEdited(from:)`, which opens a closed list as `typing`
when an entry matches (nothing highlighted) and closes a `typing` list when none does or the
field is cleared; a pick fills the field through `fillDirectoryField(_:)`, which is no edit, and
a host change or the draft's reset never reaches it. Return with nothing highlighted already
closed the list and created, so the creation path is unchanged. VoiceOver hears the match count
through a seam: `AppEnvironment.announce` (`postAccessibilityAnnouncement(_:)`, an
`NSAccessibility` `announcementRequested` at medium priority) becomes `AppModel.announce`,
which tests set to a recorder; it speaks when an edit opens the list or changes its rows and
when it closes a `typing` list for lack of matches. The list's accessibility value is the same
summary, and the field's accessibility hint says typing filters the list. The attach gallery
gained "typing filters the list" and "no matching directories", the switcher gallery the form
in both states (the popover gallery holds no New session state); checklist 21 added. New tests
in `DirectoryFilterTests.swift`: `DirectoryFilterContentTests` (`anEmptyFieldFiltersNothing`,
`aQueryKeepsTheMatchingEntriesOfEachSection`, `matchingIgnoresCaseAndDiacritics`,
`noMatchesWithActionsOn`, `noMatchesWithNothingOnAndNothingAtAll`, `anExactMatchStillShows`,
`actionsAreNeverFiltered`, `theTildeRuleOnThisMac`, `noTildeRuleOnSSHHosts`,
`theFieldsHintMentionsTheFilter`) and `DirectoryFilterModelTests`
(`typingThatMatchesOpensTheListWithoutAHighlight`, `noMatchClosesOnlyAListTheTypingOpened`,
`clearingTheFieldClosesATypingOpenedListAndOpensNothing`, `escKeepsTheTextAndCloses`,
`theArrowsStayInTheFilteredRows`, `returnWithNoHighlightCreatesFromTheField`,
`pickingFillsTheFieldAndDoesNotReopen`, `aHostChangeRefilters`,
`aBusyDraftOrNoHostOpensNothing`, `theMatchCountIsAnnouncedWhenTheFilterChanges`,
`theHomeFolderAndTheAnnouncerAreInjected`, `galleryFixturesCoverTheFilter`). Five existing
tests had their Directory field changed, their expectations kept, because the field now filters
(`docs/TESTING.md` *Phase I-7*): `clearRuleAndNotice`, `itemsAndMoving`,
`pickingFillsAndChecksTheDraft`, `hostChangeKeepsTheField`, `editingTheFieldDropsTheHighlight`.
On the final tree 815 core + 376 UI tests pass.

### Phase I-8 — New session: change the host from the keyboard (routine)

From the inbox (2026-11-05). The specification, with the user's request verbatim, the user's
decision (follow macOS's keyboard navigation setting; Host is never forced into the loop), the
findings, the requirements and the acceptance, is
`autoclaude/processed/80-new-session-host-picker-keyboard.md`. The Tab and ⇧Tab order (I-6) is
not changed. Not split.

The orchestrator's calls, made before the worker: **the routing rule is generic, not
host-specific** — while the panel's first responder is an `NSPopUpButton` (in the form that is
the Host picker), the panel's key monitor leaves ↑, ↓ and ⌥↓ to it instead of mapping them;
Return still presses Create and Esc still closes the panel (or, with the directory list open,
closes the list first), as now. **While any menu is tracking** (between
`NSMenu.didBeginTrackingNotification` and `didEndTrackingNotification` in the app), the
monitor passes every key through untouched, so the open host menu gets its own ↑/↓, Return,
Space, Esc and type-to-select, and Esc closes only the menu. **The directory list and Host
focus**: the list keeps its keys wherever the focus is except on the pop-up button (I-6's rule
that Tab moves on and leaves the list open stands); with the focus on Host and the list open,
↑/↓/⌥↓ go to the picker, the list stays open with its highlight unchanged, and Return and Esc
keep their list meaning (Return picks a highlighted row, else creates; Esc closes the list
first). The decision is a pure function over (key, first responder kind, menu tracking,
marked text, list state) so it is unit-testable; the diagnosis and AppKit's behaviour for a
focused pop-up button come from in-process reads and AppKit's documentation, never from a
synthesized, posted or directly delivered key event (`keyDown(with:)` with a constructed
`NSEvent` counts as one). The real presses are the user's (checklist).

Outcome: the cause was the panels' key monitor, not the focus. ⇧Tab from Name already reached
the Host picker (`SwiftUIPopupButton`, an `NSPopUpButton`) in both panels, but the monitor
mapped ↑, ↓ and ⌥↓ to `PopoverKey`s wherever the focus was, so ↑/↓ were swallowed and ⌥↓
opened the directory list (with the list open, all three moved its highlight); only Space
reached the picker (*Verified facts*, Phase I-8). The decided rule is now a pure function,
`PanelKeyRoute.decide(_:firstResponder:menuTracking:hasMarkedText:directoryListOpen:)` in
`Sources/MuxFinderUI/Model/PanelKeyRouting.swift`, with `PanelFirstResponder` (pop-up button
or other, from the panel's first responder at the press) and `MenuTrackingObserver` (the app's
menu tracking notifications); `PanelKeyTrackingView`'s monitor, shared by the popover and the
switcher, calls it with the window's first responder, the observer's state, the field editor's
marked text and the model's list state, and hands the handler only the keys it routes there.
The model's key handling, the creation path and the views are unchanged (a host picked from
the menu comes through the picker's existing binding), so no self-test or `e2e-*` run was
made. D30's *Panel*, D31's *Keys* and D32's *Keys* items edited. The diagnostic
`--preview-key-view-loop` grew a Host picker section (the first responder after the window's
own step back from Name, its menu's item count, the key binding messages it answers, and the
monitor's route for ↑, ↓, ⌥↓, Space, Return and Esc with it and with Name, list closed and
open). The galleries are unchanged; checklist 22 added. New tests in
`HostPickerKeyboardTests.swift`: `PanelKeyRouteTests` (`spaceIsNoPanelKey`,
`aPopUpButtonKeepsTheArrows`, `theListOpenAndThePopUpButtonFocused`,
`otherFocusKeepsTheOldMapping`, `firstResponderKinds`, `aTrackingMenuGetsEveryKey`,
`markedTextGetsEveryKey`, `theDirectoryListKeysAreTheModels`, `theDiagnosticsKeys`; three fail
with the two new rules taken out), `MenuTrackingObserverTests` (`beginAndEnd`, `nestedMenus`,
`unbalancedEnd`, `onlyItsCenter`) and `HostPickerBindingTests`
(`aHostPickedThroughThePickersBinding`); no existing test changed. On the final tree 815 core +
390 UI tests pass.

### Phase I-9 — New session in its own always-on-top window, with folder drop (high)

From the inbox (2026-11-05). The specification, with the user's request verbatim, the user's
decisions (always on top; both entry points; a dropped Finder folder fills Directory; no
"Choose…" button; the close button acts like Cancel), the findings, the requirements and the
acceptance, is `autoclaude/processed/90-new-session-own-window.md`. Recorded as **D34** (D30,
D31, D32 edited). Split, as the item suggests:

- **I-9a — the model and the window (high).** New session's state out of `panel`; one titled
  floating "New session" window opened from the popover and the switcher, which close as it
  opens; the opening, ending and failure-after-close rules; the window's keys (I-6's key view
  loop, I-7's list keys, I-8's `PanelKeyRoute`, ⌘W); the popover and switcher no longer show
  the form inline (their galleries lose the inline form states, so they still build); D34
  recorded, D30–D32 edited; `--selftest new-session-local`, `--report-menu-bar-item` and
  `--report-popover-placement` pass (requirements 1–5, 7's decision part).
- **I-9b — the folder drop, galleries and docs (routine).** The drop as a pure function and its
  wiring on the Directory field (requirement 6), the window's preview gallery
  (`--preview-gallery new-session`: editing, list open, filtered, busy, collision, failure,
  drop highlight), screenshots regenerated for every changed gallery, `docs/MANUAL-CHECKLIST.md`
  (a new item; 20, 21 and 22 updated for the window), `README.md`, `docs/ARCHITECTURE.md`,
  `docs/REQUIREMENTS.md`.

The orchestrator's calls, made before the first worker (the item's "decide and record"):

- **Activation.** The window is a non-activating `NSPanel` (`.titled`, `.closable`,
  `.nonactivatingPanel`; not a `PopoverPanelWindow`): opening it makes it key without
  activating muxFinder, as the popover and switcher are key today, and a click into it makes it
  key again without taking the frontmost app's place; `hidesOnDeactivate` false, not released
  when closed, not resizable by the user. It never closes on resigning key, a click elsewhere
  or another app activating.
- **Level, Spaces, full screen.** Floating level (above other apps' normal windows, below the
  popover and switcher panels and menus); `.canJoinAllSpaces` and `.fullScreenAuxiliary`, as
  the panels: the user leaves it to look for a folder, possibly on another Space or beside a
  full-screen app, and a window left behind on one Space would be the "disappears without
  trace" problem again.
- **Position and size.** A fresh opening puts the window's top centre at the top centre of the
  popover or switcher it came from (on that screen), clamped into that screen's visible frame;
  no frame is remembered across closes. While it shows, the user's move stands: opening it
  again only brings it forward. Fixed width (the switcher's form width); the height follows the
  content (the directory list included) with the top edge fixed, clamped into the visible
  frame.
- **Keys.** As the form's today (Return, Esc closing the list and then the window, ⌥↓, ↑/↓,
  Tab/⇧Tab through the recalculated key view loop, I-8's routing, marked text first). ⌘W
  closes it like Cancel. ⌘, opens Settings (the window stays); ⌘R and ⌘F are not the window's
  (it lists no sessions); ⌘N with the window key does nothing.
- **Ending.** Cancel, Esc (list closed), ⌘W and the close button all cancel as `cancelPanel()`
  does for New session today: the window closes, "Open existing" stops looking, a creation in
  progress goes on; the draft is dropped (the next opening starts a fresh one), except that the
  draft of a creation still running stays with it for its outcome, and opening the window while
  it runs shows that draft busy, as today.
- **Failure after close.** When a creation whose window was closed ends in a collision or a
  failure, **the window comes back with it** (the draft as submitted, the failure or "Open
  existing"), whichever entry point started it, ordered front on its last screen and position
  without being made key, so it never takes typing from the app in front. This replaces the
  switcher-only deferred-failure path (`switcherCreationFailed(_:)`,
  `showDeferredCreationFailure()`), keeping its guarantee for every creation; a Move here
  confirmation no longer holds it back, since the two no longer share `panel`.
- **Self-tests and previews.** The model never needs the window: the window controller is
  installed by the app shell only, so `--selftest new-session-local` drives the model with no
  window shown, and preview mode builds the window only for its gallery (I-9b).

Outcome of I-9a (2026-11-05): as decided above, recorded as D34 (D22, D25, D30–D33 edited).
The model holds the window's visibility and opening requests (`AppModelNewSession.swift`),
`NewSessionWindowController` places and sizes it as pure functions over a surface, and the app
shell alone builds the panel (`Views/NewSessionWindow.swift`). The switcher follows the attach
of a draft it made, its creation and its "Open existing" alike (the review's one should-fix),
even while closed. The inline form states left the attach and switcher galleries (kept as
fixtures for I-9b); `--preview-key-view-loop popover|switcher` now inspects the window over
that entry point's fixture. Changed and removed tests: `docs/TESTING.md`, *Phase I-9a*. 815
core + 406 UI tests pass; `--selftest new-session-local` 7/7.

The orchestrator's calls for I-9b, made before its worker (requirement 6's "decide which"):

- **Drop target: the Directory field's row only** (the field and its list button), not the
  whole window: the user's decision reads "onto Directory", the Name field and the buttons
  keep their own meaning, and the highlight belongs on the field the drop fills. A drop on
  the field fills it the same way whether or not the field is being edited: the field
  editor never inserts its own text for a dropped file.
- **What counts as a folder.** Exactly one item, a `file:` URL whose resource values say
  directory and not package (an `.app` or other bundle is refused like a file, as Finder
  shows it); anything else (a file, several items, a non-file drag, a promise without a URL)
  is refused and shows no "+". Only the URL's own resource values are read, never the
  folder's contents. The path is used as dropped (standardized, trailing slash dropped, no
  symbolic link resolved).
- **The `~` rule.** Under This Mac's home folder, compared by whole path components (a
  sibling such as `<home>2` is not under it), the path becomes `~/…`; the home itself
  becomes `~`; anything else stays absolute. This Mac's home is the one I-7's `~` rule uses.
  The text then goes through D31's checks like typed text, for every host.
- **The fill is a pick** (`fillDirectoryField(_:)`): the directory list closes and does not
  reopen on that change (I-7), the highlight drops, and the path is never logged.

Outcome of I-9b (2026-11-05): as decided above, recorded in D34 (*The folder drop*, *The
gallery*). `FolderDrop` is the rule as a pure function over plain facts; the model decides the
highlight and the fill (`directoryDropOutcome(_:)`, `directoryDragMoved(_:)`,
`dropOnDirectoryField(_:)`; a closed window or a busy draft takes none); `FolderDropView`, an
invisible AppKit view laid over the Directory row, is the drag's destination ahead of the field
editor (registered for every type it accepts, so it never inserts text of its own), letting
clicks through. The field shows an accent ring while a folder hovers, and its VoiceOver hint
mentions the drop. `--preview-gallery new-session` renders the window's 13 states (the
popover's New session fixtures with a failure and the drop highlight added, and the switcher's
`form`; the switcher's filtered and no-match form fixtures retired as duplicates); the
new-session, attach and switcher screenshots were regenerated and inspected (the popover
gallery, unchanged by I-9, was not). `docs/MANUAL-CHECKLIST.md` gained item 23 (the window and
the drop) and items 17, 18 and 20–22 describe the window; `README.md` and
`docs/ARCHITECTURE.md` describe the window and the drop (`docs/REQUIREMENTS.md`, the verbatim
brief, has no inline form to change). Tests and changed tests: `docs/TESTING.md`, *Phase
I-9b*. 815 core + 431 UI tests pass.

### Phase I-10 — New session: search the host's folders by name (high)

From the inbox (2026-11-06). The specification, with the user's request verbatim, the user's
decisions (this Mac runs Spotlight on the host over discovery's noninteractive ssh, no
muxFinder needed there; live as you type through one channel; folder names only,
case- and diacritic-insensitive "contains"; a home-folder / whole-disk setting, default home;
This Mac too; a fixed noise rule; hosts without Spotlight say so; "Missing a folder?"), the
findings (counts and timings on Saturno), the requirements and the acceptance, is
`autoclaude/processed/100-folder-search-spotlight.md`. Recorded as **D36** (D3, D31, D32 and
D34 edited). The user authorized read-only Spotlight queries on Saturno and this Mac for runs
(unattended-run rule 3): counts and timings only, never a folder name or path. Split, as the
item suggests:

- **I-10a — the core (high).** The static folder-search script, its query and answer
  formats, the escaping of typed text, the answer parser, the noise rule, the channel (its
  process transport, local and over ssh, and its state machine), the search scope preference
  in `preferences.json`, the probe command `folders`, real `--count-only` runs on this Mac and
  Saturno recorded in `docs/TESTING.md`, D36 recorded and D3 / D32 edited, `README.md`'s and
  `docs/ARCHITECTURE.md`'s core parts, `CLAUDE.md`'s probe line. No UI.
- **I-10b — the UI (routine).** The "Folders on <host>" section in New session's directory
  list (requirement 3), wiring the channel to the window (open on the first query, close with
  the window, a host change, a quiet minute, quit), the Settings › Directories setting and the
  "Missing a folder?" explanation with its links, VoiceOver announcements, galleries and
  screenshots, `docs/MANUAL-CHECKLIST.md`'s new item, D31 / D34 edited, the rest of the docs.

The orchestrator's calls, made before the first worker (the item's "decide and record"):

- **One script, both kinds of host.** This Mac runs the same static script as SSH hosts, as
  `/bin/sh -c <script> muxfinder <args…>` by argv (D3's local form), not `NSMetadataQuery`: one
  implementation of the header, the noise rule, the limit and the answer format, so one set of
  tests covers both. SSH hosts get D3's single string with discovery's noninteractive options
  (BatchMode, its connect timeout), stdin kept open as the query stream.
- **The channel asks folder-name questions only.** A query line carries only a query id
  (decimal digits), a scope token (`home` or `disk`) and the escaped name text; the script
  builds the fixed predicate itself (`kMDItemContentType == "public.folder" && kMDItemFSName ==
  "*<text>*"cd`) and passes it to `mdfind` as one quoted argument, never through `eval`, so the
  channel cannot be used for any other Spotlight query or command. A malformed line (bad id,
  unknown scope, over the length limit) gets an error answer for its id, or is skipped when it
  has no usable id; the script keeps reading.
- **Escaping and limits.** A pure Swift function turns the typed text into the name text: `\`,
  `"`, `*` and `?` are backslash-escaped, control characters (C0, DEL, C1, and line or
  paragraph separators) refuse the query, and text over 255 UTF-8 bytes (a folder name's
  maximum) refuses it; leading and trailing whitespace is kept (it is part of a name). Queries
  need at least 2 characters (counted as `Character`s). The worker verifies the escaping on
  this Mac against real `mdfind` by counts only, and records what it found.
- **Answers.** Every answer, for every query, ends with an end record that cannot be mistaken
  for a path (`mdfind` prints absolute paths, so any record not starting with `/` is
  unambiguous) carrying the query id and a status (ok with the count, limited, or the error).
  Paths are NUL-separated (`mdfind -0`), so a newline in a name is kept. At most **50**
  folders per answer after the noise rule, and the script stops `mdfind` once it has them.
  The header comes first, once: the host's home folder, whether `mdfind` exists, the indexing
  state of the volume each scope searches (`mdutil -s`), and whether `~/Desktop`, `~/Documents`
  and `~/Downloads` are readable. Its framing and the parser are tested with truncated and
  hostile input (an answer cut short, a stale id, an oversized record, garbage between
  records); every buffer is bounded.
- **The noise rule (fixed, in the script).** A folder is left out when (a) it is the home's
  `Library` or below it; with the whole-disk scope also any `/Users/<name>/Library` and
  below, and the system roots `/System`, `/Library`, `/private`, `/usr`, `/bin`, `/sbin`,
  `/opt`, `/cores`, `/dev` and below (`/Applications` and `/Volumes` stay); (b) any component
  of its path starts with `.` (hidden folders and everything under them, such as `.git`,
  `.build`, `.venv`, `.Trash`); (c) any component is `node_modules`, `DerivedData`, `Pods` or
  `__pycache__` (the folder itself and everything under it); (d) any component but the last
  ends in `.app`, `.framework`, `.bundle`, `.plugin`, `.kext`, `.photoslibrary`,
  `.xcodeproj`, `.xcworkspace` or `.xcassets` (inside a package). Folders named `build`,
  `dist` or `target` stay: they are common real folder names. The rule is tested hermetically
  by running the real script with stub `mdfind` and `mdutil` first on `PATH` that print
  synthetic paths (no Spotlight, no real folder names), which also tests the header, the limit,
  the early stop and the end records. Remote hosts resolve `mdfind` and `mdutil` through the
  noninteractive `PATH`, which holds `/usr/bin`.
- **The channel.** A core type with an injected clock and transport: debounce about 150 ms
  after typing pauses, then sends only the latest text; at most one query in flight, answers to
  older ids dropped; a result cache is never written to disk; every wait bounded (the connect
  and header within discovery's connect timeout plus a margin, each answer within 5 s);
  a timed-out or dead channel is ended (stdin closed, then the process terminated after a
  grace period, never left running) and reopens once on the next query, a second failure in a
  row reporting the problem until the text or host changes. Closing (window closed, host
  changed, a quiet minute, app quit) closes stdin, which ends the script. A host without
  `mdfind`, or with indexing off for the searched volume, is reported from the header and no
  query is sent. The probe and I-10b use this type; I-10b only wires it.
- **The scope preference.** `preferences.json` (D32's store, under its lock, with its unusable-
  file rules) gains the folder search scope, `home` (the default, also when absent) or
  `disk`; an unknown value is treated as absent, never rewritten until a save. A change
  applies to the next query.
- **Probe and real runs.** `muxfinder-probe folders --local | --ssh <dest> --name <text>
  [--scope home|disk] [--count-only] [--repeat <n>]` prints the header's facts (home folder
  shown only as "present", never its path, unless paths are asked for), each query's count,
  status and latency, and the channel's open time; `--paths` alone prints paths, and is never
  used in unattended runs. Real runs on this Mac and Saturno with `--count-only`, a few names
  each, both scopes, one channel with several queries, are recorded in `docs/TESTING.md`
  (counts and timings only).

**Outcome of I-10a (2026-11-06).** The core is in `Sources/MuxFinderCore/FolderSearch/`, with
`Process/StreamingProcess.swift` for the long-lived process, the scope in `PreferencesStore`
and the probe's `folders` command; D36 records it, D3, D11 and D32 were edited. As decided
above, with what the work settled: the script validates every query line itself (an
unescaped `"`, `*` or `?`, or a stray `\`, is `error text`), because `mdfind` silently accepts
a predicate an unescaped quote or a trailing backslash bends (verified by counts on synthetic
folders on a scratch disk image, the only way to have Spotlight index names that differ by
one special character without touching the user's folders); the home's volume for `mdutil -s`
comes from `df -P`, since `mdutil -s "$HOME"` cannot say; the readability checks use `ls`,
since `[ -r ]` does not see macOS's privacy protection; `xargs -x` is avoided (on macOS it
runs one argument per invocation). The channel opens the script on the first searchable text,
before the debounce, so the SSH connection is ready by the time the query goes; only an answer
resets the failure count, so a script whose header arrives but whose queries time out is
reported after the second failure instead of reopening forever. The adversarial review
(`docs/reviews/phase-I-10a.md`) led to the three-stage pipeline: a 4 s deadline on the host
for every query (an SSH close ends only the local ssh, and a blocked `mdfind` could not see
the disconnect), an explicit stop at the limit (left-out folders after the 51st kept one
made the filter write nothing, so SIGPIPE never reached `mdfind`), and a bounded event
buffer in the transport (D36). Hermetic: 64 new tests in 6 suites (the real script under
stub `mdfind` and `mdutil`, under bash and dash, with a name holding a line feed, the 50
limit with noise interleaved and amid endless noise, the deadline and a disconnect seen from
the host; the parser on hostile input; real local processes, the D3 string through zsh and
bash, a flood with a stalled reader; the channel over a fake transport and a gated clock;
the preference on private folders). Real: `folders --count-only` on this Mac and
Saturno, both scopes, 8 to 10 queries per channel, about 0.2–0.4 s per query on an open
channel, no process left on either side, interrupts closing the channel. Left to I-10b, besides
its own items: This Mac's readability checks may make macOS ask for access to Desktop,
Documents and Downloads the first time the app searches This Mac (TCC), so I-10b decides
whether to skip them there; paths with control characters reach the parser's output and need
`Validation.workingDirectory` before they are offered; the "Missing a folder?" text can say
that a `'` inside a word finds nothing (Spotlight's matching).

The orchestrator's calls for I-10b, made before its worker (the handovers above):

- **This Mac runs no readability check.** On This Mac the script's `ls` of `~/Desktop`,
  `~/Documents` and `~/Downloads` runs as muxFinder's child and can make macOS ask for access
  to those folders the first time someone types a folder name, a prompt nobody asked for; and
  the protected-folders note is about Remote Login's full disk access, which has no local
  counterpart. So This Mac's channel turns the checks off through a fixed script argument
  (never an inserted value; the header then says "not checked"), and the note is shown only
  for SSH hosts. Whether This Mac's Spotlight answers to muxFinder leave protected folders out
  is owed to the manual checklist.
- **Unusable paths are dropped, never offered.** Every path the parser returns goes through
  `Validation.workingDirectory` and the checks a typed Directory gets for that host (D31)
  before the section shows it; one that fails (a control character such as a line feed in a
  name, too long) is dropped and only counted, never logged. A pick therefore always passes
  New session's validation.
- **A path is not a name.** Directory text holding a `/` (a path being typed) sends no query
  and hides the section: no folder name contains one. Fewer than 2 characters (D36) hides it
  too.
- **The section.** "Folders on <host>" comes last, after Recent, Saved and Sessions, with at
  most the 50 folders the core returns, less those already in an earlier section (compared
  after the `~` rule, shown once, in the first). While folder search applies to the text, the
  section counts as something to show for I-7's open rule, its status line ("Searching…",
  "No folders found", the unavailable reason, the problem) included, so the list stays open
  while a search runs. Picking a row is a pick (`fillDirectoryField(_:)`, no reopen).
- **The channel's lifetime.** One `FolderSearchChannel` per New session window and host,
  owned by the window's model: opened by the first searchable text, closed when the window
  closes, the host changes, after a quiet minute (no query for 60 s), and when the app quits.
  The popover and the switcher never open one (New session has its own window, D34).
- **The scope is read for each query** from `preferences.json` through `PreferencesStore`
  (never `UserDefaults`), so a change in Settings applies to the next query; an unusable file
  means `home`.
- **An unreachable host** shows "Searching…" until the channel reports its failure (up to
  about 10 s over SSH), then the problem, with no retry until the text or the host changes
  (D36's reopen-once rule). The local sections and the form are never held up.
- **Announcements**, as I-7's: the section's result count when it changes, and "Searching…"
  once when a search starts from a settled state, never per keystroke.
- **"Missing a folder?"** also says that a name with an apostrophe inside a word may not be
  found.

**Outcome of I-10b (2026-11-06).** As decided above; D31 and D34 record the UI, D36 (and D3's
sentence on it) the core change. The script had no way to skip its readability checks, so it
gained one fixed argument, `unchecked` (`FolderSearchScript.uncheckedArgument`), which This
Mac's transport passes by argv (never a runtime value; SSH hosts get none): the header then
says `unchecked` for Desktop, Documents and Downloads (`Readability.notChecked`) and the
script looks at none of them; tested through the real script under the stub `mdfind`/`mdutil`
harness with a logging `ls` (bash and dash), and by one real local `folders --count-only` run
(the header said "not checked"; `docs/TESTING.md`). The section is a pure value
(`FolderSearchSection`) inside `DirectoryPickerContent`; the window's channel lives in a
`FolderSearchSession` the model owns, asked on each edit, the list's opening and a host
change while the list shows, and ended by the window's closing (whatever closed it, through
`newSessionWindow`'s observer), a host change and quitting. What the work settled: the search
runs only while the list shows (typing searchable text always opens it, the section counting as
something to show), so a window brought back by a failed creation starts no SSH connection by
itself; the same text is not asked twice in a row, so a scope changed in Settings applies to
the next new text; while a newer text is searched, the previous answer's folders whose names
still contain it stay listed under "Searching…" (the section does not empty and the window
does not jump at each key), only when that answer was for the new request's scope (the
answer keeps its scope; a scope changed in Settings drops them, as the review asked); a
scope picked in Settings is saved in a task the Settings model owns, which quitting waits
for (the choice is off while it runs); "No other folders found" when every folder found is in an earlier
section; the explanation shows below the scrolling sections so its links are always visible;
an edit's announcement joins the directory count and "Searching…" so neither cuts the other
off, and the directory count is left out while only the folders section shows rows. Folder
search, its scope setting and `SettingsEnvironment.preferences` exist only in normal mode
(the session switcher shortcut's `PreferencesStore` instance), so `--report-menu-bar-item`
still reads no `preferences.json`. Hermetic: 37 new UI tests in 3 suites and 2 new core tests;
the galleries gained nine New session states and two Settings states. Owed to a person:
checklist item 24 (a real search on Saturno and This Mac, no privacy prompt on This Mac's first
search, whether protected folders appear, the links, VoiceOver).

### Phase I-11 — Detach other clients (high)

From the inbox (2026-11-06). The specification, with the user's request verbatim, the
diagnosis (two control-mode clients on one session: neither registers activity, so with
`window-size latest` tmux keeps the window at its old size and ignores both clients'
`refresh-client -C`), the verified facts on a private server, the requirements and the
acceptance, is `autoclaude/processed/105-detach-other-clients.md`. It goes ahead of I-12, as
the user asked. To be recorded as **D37**. Split before the first worker:

- **I-11a — proof and core (high).** The real proof of the command (requirement 1) on This
  Mac and Saturno, the choice recorded as D37, the coordinator call with its session-key
  confirmation and typed results (requirement 2), hermetic tests for everything the
  acceptance lists that is not UI, and a real run command, `muxfinder-probe
  e2e-detach-others --local | --ssh saturno-m4`, passing on both hosts. `README.md`'s and
  `docs/ARCHITECTURE.md`'s core parts, `docs/TESTING.md`'s real-run record, `CLAUDE.md`'s
  probe line. No UI.
- **I-11b — the UI (routine).** The popover's "Detach other clients…" context menu item and
  its offer rule, the D25-style confirmation, the result's refresh and failures' recovery, the
  optional row hint, galleries and screenshots (`attach`, and `popover` if the row changes),
  `docs/MANUAL-CHECKLIST.md`'s new item, D37's UI part (D25 edited), the rest of the docs.

The orchestrator's calls for I-11a, made before its worker:

- **Proof first, option (a) first.** The worker proves `attach-session -d -t <session id>`
  sent through the launch tab's tmux connection (`SendCommand`, as `detach-client` is sent
  today) before fixing the core's command, on a `muxfinder-test-*` session attached through a
  launch tab by the coordinator (its bury on, as in the app) plus a plain `tmux -C` client of
  the harness (`BackgroundControlClient`, as the e2e move here step), locally and on
  `saturno-m4`. Pass means: the plain client prints `%exit` and exits 0 by itself within
  10 s; the iTerm2 sessions and tabs showing the session's tmux windows have the same ids
  before and 2 s after, none closed or reopened; the launch tab still owns its connection, is
  still in `buried_sessions` and in no tab; the session is alive with this attachment as its
  only client. If (a) fails any of it (iTerm2 reacting to the `%session-changed` the command
  sends its own client), option (b) is proven the same way: `list-clients` of the session,
  the connection's own `#{client_name}`, then `detach-client -t <name>` for each other
  client, bound so that a name reused in between can never detach a client of another
  session (one command line if tmux 3.8 allows it, else a check of `client_pid` and the
  session right before each detach). Never `detach-client -a` or `-s`. The proof's harness
  can be the `e2e-detach-others` command itself, once the core call exists with the candidate
  command; what each option did is recorded in D37 and `docs/TESTING.md`.
- **The call.** `AttachCoordinator.detachOtherClients(of:confirmation:)` with its own
  confirmation type, `DetachOtherClientsConfirmation.detachOtherClients(of: SessionKey)` (one
  case, no default, naming the session; separate from `MoveHereConfirmation`, so a move here's
  confirmation can never be used here or the other way round). A confirmation for another key
  fails before anything runs (no listing, no iTerm2 request, no state published).
- **The attachment it goes through** comes from the existing-attachment check (D16's index,
  the standard one when the coordinator's check is `.off`): with several attachments of the
  session in this Mac's iTerm2, the one Show tab focuses (`attach(_:)`'s choice) is kept and
  the others count as other clients. None: "not attached here", nothing sent. iTerm2 not
  running counts as none; a listing failure is "check failed".
- **Binding and sending once.** The identity check right before sending is the one
  `detach(session:on:)` uses (the connection still shows that session of that server); a
  changed identity sends nothing. The other clients are counted by a read-only listing
  through the same connection after the identity check (the session's clients less the
  connection's own); none left means "nothing to detach" and nothing is sent. The detaching
  command is sent once (D13), holding only the validated session id (or, under (b), only
  names read from that listing and validated); no other runtime value is inserted. The result
  carries the count detached (the listing's count, or a recount after, as the proof settles).
- **Typed results**: detached *n* clients; nothing to detach; not attached here; identity
  changed (nothing sent); check failed (the listing, the identity check or the send failed,
  with the problem). None of them triggers a refresh by itself; the UI (I-11b) refreshes the
  row afterwards.
- **Local and SSH hosts alike**: the command travels through iTerm2's connection only; no new
  ssh, remote script, file or request.
- **Real run command.** `muxfinder-probe e2e-detach-others --local | --ssh saturno-m4`
  (its own command, so `e2e-local`'s and `e2e-remote`'s step counts stay as they are;
  `--help` contacts nothing): create its own `muxfinder-test-*` session, attach it through
  the coordinator (bury on), attach a plain control client of its own, check that a
  confirmation for another key runs nothing, run the call, then the pass checks of the proof
  above and the result's count; then detach by connection and clean up as `e2e-bury` does
  (restore and close only its own launch tabs, kill only its own session, the plain client
  ended on every way out). Real runs follow the gate in `PROGRESS.md` *Next action* 3.

**Outcome of I-11a (2026-11-06).** As decided above, with option (b): D37 records the proof,
the binding and the call. Option (a) failed on both hosts on its first check, as the
specification feared: iTerm2 3.7.7 closes and reopens a connection's windows when tmux sends it
`%session-changed`, even naming the session it already shows, so `attach-session -d` would
close and reopen this Mac's windows of the session (both tmux tabs had new ids 201 ms later
here, none listed 81 ms later on Saturno). Option (b) passed every check on both. A one-line
binding is not possible (D37: tmux 3.8 marks the reply block of the command `if-shell` inserts
as the sender's, so iTerm2 would pair it with its next command; iTerm2 3.7.7 ends the
connection on any tmux error; an `if-shell -F` client loop sees only the sender's session;
`detach-client -t` expands no format), so each detach is bound by a read-only check of the
client's name, pid, creation time and session id right before it, through the same
connection, one round trip before the detach (D37 records what that round trip leaves). The
commands are `OtherClientsCommands`; the read-only ones filter the server's clients and cannot
fail in tmux; a client's name, pid and creation time are validated (`OtherClient`) and every
value single-quoted. Beyond the calls above, the call waits, as `detach(session:on:)` does,
until other attachments' tabs in this Mac's iTerm2 are 10 s old, and then until every other
client listed is 10 s old by tmux's clock (at most 10 s after the listing), before anything
ends them, and reports `cancelled` when its caller is cancelled; the result also counts the
other clients listed, gone before their check and detached, and the wait for young clients
(`ageWait`). A `SendCommand` answer without output (tmux's `%error`, or the connection ended
first) is `ITerm2Error.tmuxCommandFailed` at the API boundary, never an empty success, so a
`detach-client` tmux did not confirm is never counted (`checkFailed(.send(.tmuxCommandFailed))`).
`RecordingITerm2Integration` now counts every forwarded call (`forwardedCallCount`), so the
real run proves a confirmation for another key asks iTerm2 nothing. The adversarial review's
three findings (`docs/reviews/phase-I-11a.md`: the check not binding the detach, a tmux error
counted as a detach, the age rule missing clients found after the snapshot) are fixed as
above, the first narrowed and recorded in D37 since tmux 3.8 and iTerm2's pairing allow no
single bound command. Hermetic: 22 tests in `DetachOtherClientsTests` and the strict
`SendCommand` reading at the API boundary (905 core and 468 UI tests pass). Real:
`e2e-detach-others` (9 steps) passed 9 of 9 on This Mac and on Saturno, before and after the
review fixes, the gate and leftover checks clean before and after (`docs/TESTING.md` *Phase
I-11a* and *Phase I-11a review fixes*). For I-11b: the call takes an `AttachTarget`; the offer needs `clientCount` greater
than this Mac's attachments, and the confirmation's count is the listing's at the time, so a
result may report fewer clients (`goneBeforeDetach`) than the confirmation named.

The orchestrator's calls for I-11b, made before its worker:

- **Popover only** (D32): the row's context menu, beside "Move here…" and "Detach from this
  Mac"; not in the session switcher. No core change is expected: if the worker finds one
  necessary it reports it and runs no real e2e (the orchestrator decides on real runs).
- **The offer rule.** "Detach other clients…" is **shown** (not disabled) only when all hold:
  the row is live (its host's snapshot is not stale and not unreachable); this Mac's iTerm2
  shows the session (the same condition that offers "Detach from this Mac": the index's badge,
  or a confirmed `attachedHere`); and the listing's `clientCount` is greater than this Mac's
  attachments of the session (the attachment index's count for its key, at least 1 when only a
  confirmed `attachedHere` says so). Otherwise it is hidden. While another action of the row is
  pending it is disabled, as the row's other items are.
- **The confirmation** is drawn inside the popover in place of the host list, exactly as Move
  here's (D25: Return confirms, Esc and Cancel run nothing, the arrows, ⌘F and ⌘N do nothing).
  Title "Detach other clients of “<name>”?". Body: the count, the row's `clientCount` less one
  at the time it opens ("1 other client" / "<n> other clients"), with "including <k> in this
  Mac's iTerm2" when this Mac has more than one attachment (all but the one Show tab focuses
  are detached); that they may be on other Macs; that nothing is closed and the session keeps
  running; and "While another client is attached, tmux may keep the window at the other
  client's size." Buttons "Cancel" and "Detach other clients". Its confirm method is the only
  caller of `detachOtherClients(of:confirmation:)`, passing `.detachOtherClients(of:)` for the
  key of the session the panel names, never another row's.
- **While it runs** the row shows "Detaching other clients…" (the call can wait up to about
  20 s for young tabs and clients, D37); clicks on the row are ignored meanwhile, as for an
  Open; `shutdown()` cancels it. `cancelled` shows nothing.
- **Results**, through `SessionProblem` as Detach's (messages pairwise distinct, tested):
  `detached(count:)` → "Detached <n> other client(s) — the session keeps running", adding
  "<m> had already left" when `goneBeforeDetach` is above zero; `nothingToDetach` → an
  informational line, "No other clients to detach — they had already left", not a failure;
  `notAttachedHere` → "This Mac's iTerm2 no longer shows this session", Refresh;
  `identityChanged` → mapped as Detach's identity change is, nothing detached, Refresh;
  `checkFailed(.send(.tmuxCommandFailed))` → tmux refused a detach and iTerm2 may have ended
  this Mac's attachment (D37's residual), Refresh; other `checkFailed` problems → as Detach's
  failures (D23's fix-it for iTerm2 permission and API errors, else "Try again", which shows
  the confirmation again, and Refresh); `notConfirmed` (unreachable from the UI) → a generic
  failure with Refresh. Every outcome but `cancelled` and `notConfirmed` refreshes the host
  afterwards, so `clientCount` and the offer update.
- **The row hint**: when the offer rule holds, the row's existing attached-here text gains
  "also attached elsewhere" (no new line or control). If it truncates at the popover's width
  in the gallery, leave it out and record why.
- **VoiceOver**: the item, the confirmation and its buttons are labelled, and the confirmation
  is announced as Move here's is.
- **Galleries** (synthetic data, light and dark): `attach` gains the confirmation (one other
  client; two others including one here), the pending row, and each result above; `popover`
  gains the hint, and its screenshots are regenerated only if the row changed.

**Outcome of I-11b (2026-11-06).** As decided above, with no core change: D37's *The UI*
records the rules as built and D25 gains its "Detach other clients" bullet. The offer rule is
one function (`SessionRow.offersDetachOtherClients(isLive:clientCount:attachmentsHere:)`) for
the row and the model; the item stays shown but disabled while another action of the row is
pending (the row's other items were never disabled: the model ignores them then, unchanged).
The confirmation and the results are as listed, every line pairwise distinct. Beyond the calls:
the hint fits on one line at the popover's width, so it was kept, and since the switcher's rows
are the popover's `SessionRow` its badge reads the same (no switcher fixture shows it, so the
switcher's screenshots did not change); Move here's dialog had no announcement, so both dialogs
now announce their title through `AppModel.announce` (`showPanel(_:)`); "Try again" on a
failure whose offer no longer holds refreshes the host instead; after review, the switcher's
row of a failed move here or "Detach other clients…" offers its other recoveries without "Try
again" (`SwitcherContent`), and that retry changes nothing while the popover is not the one
showing, so no confirmation waits hidden; `notAttachedHere` also forgets
muxFinder's own record of the attachment, as Detach's `nothingAttached` does. The UI tests'
fake iTerm2 now answers the core's four commands with other clients as state, so the tests run
the real coordinator call. Hermetic: 17 tests in `DetachOtherClientsUITests` and the new
messages in `FailureMessageTests` (905 core and 485 UI tests pass). Galleries: `attach` (16
states, 5 new, and the context menu listing the item) and `popover` (the hint on "Selected
session open here, offline host"), light and dark, inspected. No real run was needed (the core
did not change); checklist item 25 is owed to the user (two Macs, the real popover, VoiceOver,
the window size afterwards, and D37's residual race).

### Phase I-12 — Other terminal apps: Terminal.app and Ghostty beside iTerm2 (high)

From the inbox (2026-11-06). The specification, with the user's request and answers verbatim,
the findings, thirteen requirements and the acceptance, is
`autoclaude/processed/110-other-terminal-apps.md`. iTerm2 keeps native control mode exactly
as today. Terminal.app and Ghostty get plain `tmux attach` through a terminal seam above
`ITerm2Integration`, with small JSON definitions. To be recorded as **D38** (with D3
extended for Terminal's command text). Split before the first worker:

- **I-12a — proof and decision (high).** Requirement 1: the read-only facts (`sdef` of both
  apps, the installed versions, the Automation permission's state read without a prompt), the
  plain-mode confirmation proven locally and on `saturno-m4` (requirement 5, remote
  identification settled), the real Terminal and Ghostty runs where the gate below allows
  them (owed otherwise), D38 and D3's extension written, and the facts in *Verified facts* and
  `docs/TESTING.md`. Only probe code: a read-only `muxfinder-probe terminals list` and the
  proof's harness command. No app, seam or helper change.
- **I-12b — core (high).** Definitions (schema, loader under D19's rules, built-ins in
  `Resources/` copied and signed by `scripts/build-app.sh`, user overrides by id, problems
  kept per file), argv expansion, Terminal's command text and its refusals, the Apple event
  handler call over an OSA runner seam, permission states, the terminal seam with the iTerm2
  backend wrapping today's code unchanged, the plain backend, the helper's plain `attach` and
  `profile` variants (requirement 4), `terminals list` extended with definitions. Hermetic
  tests for all of it. **Split into I-12b1 and I-12b2** (below, after the outcome of I-12a).
- **I-12c — coordinator (high).** Plain confirmation (requirement 5, as I-12a settled it),
  detach and Move here through tmux (requirement 6), "open on this Mac" by process ancestry
  (requirement 7; discovery's `list-clients` gains `client_pid` and `client_tty`, still
  read-only), `attach --terminal <id>` and `e2e-plain --terminal terminal|ghostty --local |
  --ssh saturno-m4`; iTerm2's existing e2e runs and self-tests rerun as regression. **Split
  into I-12c1, I-12c2 and I-12c3** (below, after the calls for I-12b3).
- **I-12d — UI (routine).** Settings › General "Terminal" (requirement 8), strings following
  the choice (9), onboarding without iTerm2 (10), persistent work's per-host command with
  Copy (11), the app never contacting iTerm2 when it is not the choice, galleries light and
  dark. **Split into I-12d1 and I-12d2** (below, after the calls for I-12c3b).
- **I-12e — docs (routine).** `docs/REQUIREMENTS.md` addendum 13, `docs/TERMINALS.md`
  ("Adding a terminal", later candidates, the Ghostty control-mode note), README,
  ARCHITECTURE, TESTING, MANUAL-CHECKLIST, `CLAUDE.md` commands and the extended safety
  rules (also in *Unattended-run rules* below, where I-12a already adds them for its own
  runs).

The orchestrator's calls for I-12a, made before its worker:

- **Never launch Terminal.app or Ghostty, and never wait on a prompt.** At launch both apps
  restore the user's saved windows and may show dialogs nobody can answer. A real run may
  drive a terminal app only when it is **already running** and its Automation permission,
  as the probe reads it without a prompt (`AEDeterminePermissionToAutomateTarget`,
  `askUserIfNeeded` false, for the process that would send the events), is **granted**.
  Otherwise no Apple event is sent to it, and its real runs are recorded as owed to the user,
  with the exact command. Reading `sdef /Applications/Ghostty.app` and
  `sdef /System/Applications/Utilities/Terminal.app` launches nothing and is always allowed,
  as is reading Ghostty's public docs (https://ghostty.org/docs/features/applescript and its
  `command` reference).
- **`muxfinder-probe terminals list`** (read-only, prints JSON; sends no Apple event that
  could prompt, launches nothing, writes nothing): for iTerm2, Terminal.app and Ghostty, the
  app found through LaunchServices by bundle identifier, its path and version, whether it is
  running, and the permission's state without a prompt (granted, denied, not determined,
  target not running, or the raw status). `--help` contacts nothing. I-12b extends it with
  definitions.
- **Plain confirmation, proven without a terminal app.** The proof's harness command (named
  by the worker, recorded in `CLAUDE.md`; it may become I-12c's `e2e-plain`) hosts plain
  clients in pseudo-terminals it opens itself, so the proof needs no terminal app and no
  permission: on This Mac, `tmux -u attach-session` of its own `muxfinder-test-*` session on
  a pty it owns; on `saturno-m4`, `/usr/bin/ssh -t` running D17's remote script with the
  attach plain (no `-CC`). Requirement 5's checks: locally, exactly one client of the session
  has the harness's pty as `client_tty`; remotely, a way to tell the launch's client from
  every other client of the session using only read-only commands over discovery's
  noninteractive ssh (BatchMode, no remote file write), for example the launch token in the
  argv of the remote client or its parent shell, read with `ps` by `client_pid`. Each check
  passes with a match, fails with none, and refuses to confirm with two candidates (a second
  plain client of the harness, carrying a different token, proves it). If no remote way is
  reliable, D38 says the remote attach ends as "Opened in <app>", not confirmed. Then
  `detach-client` aimed at that one client (locally, and over BatchMode ssh) ends only it,
  and D21's Move here in plain mode (`attach-session -d`, or per-client `detach-client` as
  D37 chose, the worker's call recorded in D38) leaves exactly the new client.
- **Terminal and Ghostty real runs, where the gate allows**: open a new window running a
  command (never typing into an existing tab, never `input text`, `send key` or mouse
  commands), the command a plain attach of the run's own session; confirm as above; focus
  that window; detach through tmux; and close only a window the run opened, only after its
  process has ended (a window with a running process asks before closing: a modal nobody can
  answer). Learn and record whether Ghostty's `command` is shell-parsed, what `new window`
  returns, whether `environment variables` reach the command, and what Terminal's `do
  script` returns and how its tab's `tty` reads.
- **D3's extension for Terminal's command text** is decided here, from requirement 3:
  `exec`, then the helper path and the validated token, each POSIX single-quoted; a helper
  path holding `'`, `\`, a control character or anything fish reads differently inside
  single quotes is refused with a clear error. Ghostty's form follows what the `sdef` and the
  docs say about `command` (token in `environment variables` when they reach the command).
- **Safety rules extended now**, before any real run: *Unattended-run rules* 1 below covers
  Terminal and Ghostty windows (a test touches only windows it opened, closes them only by
  the ids it recorded), and rule 8 forbids launching either app. `CLAUDE.md`'s safety rules
  say the same.
- **Records**: D38 (what was verified, the remote identification or its absence, Move here's
  form, Ghostty's and Terminal's open forms, what stayed owed), D3 extended, *Verified facts*
  "Phase I-12a proof", `docs/TESTING.md` (the commands and results, owed runs listed), and
  `CLAUDE.md`'s command lines for `terminals list` and the harness. Real runs follow the gate
  in `PROGRESS.md` *Next action* 3 for anything touching iTerm2; the harness itself touches
  no iTerm2.

**Outcome of I-12a** (2026-11-06). The proof passed on both Macs and D38 is recorded, with D3's
extension and *Verified facts* "Phase I-12a proof". `muxfinder-probe plain-proof --local | --ssh
saturno-m4` (9 of 9 each; with the review's fixes 1.5 s and 20.7 s) proved, with plain clients
on pseudo-terminals of its own: confirmation by `client_tty` on This Mac; and on SSH hosts
**remote identification is reliable**: the plain remote script keeps the `/bin/sh` that holds
the launch token as the tmux client's parent (no `exec`), and a read-only reading over
discovery's noninteractive ssh matches the token at the end of that parent's arguments (`ps` by
`client_pid`), so remote plain attaches end confirmed, not "Opened in <app>". In both places a
match is one candidate, none is none, and two candidates confirm nothing. Every attach and
detach is **bound** (the review's two findings, fixed): one `if-shell -F` command in which the
server checks the recorded session (and, for a detach, exactly one client with the recorded
name, pid and creation time in it) and only then attaches or detaches, so a restarted server's
session with the same id, or a client that took the checked one's terminal, is never reached; a
stale attach exits 65 and a stale detach detaches nothing. The bound detach ends only that
client, and Move here is a new plain client with the bound `attach-session -d`, as D21 (chosen
over per-client detaches; reasons in D38). Two facts for I-12b and I-12c: a terminal's path is
reused as soon as its controlling process exits, so the local match must also bind the attach
child's pid; and tmux draws through the client's standard input, which must be open read-write.
`muxfinder-probe terminals list` reads the apps and the Automation permission without a prompt.
Built only as probe code and pure core helpers that nothing uses yet (`PlainLaunch`,
`PlainClientIdentification`, `BoundSessionIdentity`, `PlainClientDetach`,
`AutomationPermission`, `TerminalCommandText` with D3's extension and its refusals), with
hermetic tests (26 new, the bound forms' on a private tmux server among them). Terminal.app and
Ghostty were not running, so no Apple event was sent: their open forms come from `sdef` and
Ghostty's docs, and their real window runs, with the facts only they can show (what `do script`
returns and the `tty` it reads, whether Ghostty's `environment variables` reach `command`, the
shape of its ids), are owed to the user (`docs/TESTING.md` *Phase I-12a*) and to I-12c's
`e2e-plain` under the same gate.

**I-12b split, and the orchestrator's calls** (2026-11-06, before its first worker). I-12b is
two workers' worth, so:

- **I-12b1 — definitions, loader, AppleScript runner (high).** Requirement 3 and the
  `terminals list` extension. Nothing in the app, helper or coordinator uses them yet.
- **I-12b2 — terminal seam and helper plain mode (high).** Requirement 2 (the seam: open,
  confirm, focus, detach, open here; the iTerm2 backend wrapping today's code unchanged; the
  plain backend's open, focus and close from a definition, its confirm, detach and open-here
  left to I-12c, which wires them into the coordinator) and requirement 4 (the helper's plain
  `attach` and `profile` variants, chosen by an explicit argument, and requirement 5's early
  report: the helper's terminal path and its attach child's pid, written next to the
  request). **Split again** (2026-11-06, at its selection, before its first worker: the
  helper and the seam are independent and each a worker's worth): **I-12b2 — helper plain
  mode (high)**, requirement 4, requirement 5's early report and the request's terminal
  field; **I-12b3 — terminal seam (high)**, requirement 2 (the seam, the iTerm2 backend over
  today's code, the plain backend's open, focus and close), its calls written at its
  selection.

Calls for I-12b1:

- **Where.** `Sources/MuxFinderCore/Terminals/`, beside `AutomationPermission` and
  `TerminalCommandText` (both reused, not rewritten). Built-ins in `Resources/Terminals/`
  (`terminal.json`, `terminal.applescript`, `ghostty.json`, `ghostty.applescript`), copied by
  `scripts/build-app.sh` into `Contents/Resources/Terminals/` and sealed by the app's
  signature (`codesign --verify --deep --strict` still exit 0).
- **Schema** (`schemaVersion` 1; unknown keys refused at every level; every string checked):
  `id` (`[a-z0-9-]`, 1–32 bytes; `iterm2` reserved, since iTerm2 is code), `displayName`
  (1–64 characters, no control character), `bundleIdentifier`, `minimumVersion` (dotted
  decimal), optional `notes` (at most 1 KiB), `open`, `focus`, optional
  `keepsMinimumLifetime` (default false). `open` is one of: `{"kind": "appleScript",
  "script": "<file name>", "command": "shellText" | "words"}` — the script a plain file name
  (no `/`, no leading `.`) in the definition's own folder, called through fixed handler names
  (`muxfinder_open`, `muxfinder_focus`, `muxfinder_close`; never configurable), and `command`
  saying which form of the launch command the script receives: `shellText`, D3's extension
  (`TerminalCommandText`, for Terminal's `do script`), or `words`, the helper path, the mode
  word and the token as separate values, each limited to D2's characters plus `/`, `.`, `_`,
  `+`, `-` (no space; a helper path outside them is refused with a clear error, so Ghostty's
  `command` means the same under every parsing its docs list); or `{"kind": "exec",
  "executable": "<path inside the app bundle>", "arguments": [ … ]}` — the executable
  relative to the app LaunchServices finds (no leading `/`, no `..`), the arguments literal
  or exactly one whole placeholder among `{helper}`, `{mode}`, `{token}` (a placeholder
  inside a longer argument, or an unknown one, is refused at load). `focus` is `{"kind":
  "tty" | "windowID" | "app"}`; `tty` and `windowID` need `open.kind` `appleScript`.
- **Ghostty's token goes in `command`, not `environment variables`**, as the last word, for
  either answer of the owed fact (whether `environment variables` reach `command`): the
  words are D2's characters, so the reason to prefer the environment (`command`'s parsing)
  does not arise. The built-in Ghostty definition is `command` `words`; Terminal's
  `shellText`.
- **The handler contract.** `muxfinder_open(commandText, helperPath, modeWord, token)` (the
  unused form an empty text) returns a list of two texts `{windowID, tty}`, either empty
  when unknown; `muxfinder_focus(windowID, tty)` and `muxfinder_close(windowID)` return
  nothing. Swift reads the reply strictly (anything else is a typed failure). Terminal's
  script never uses `do script … in`, `contents` or `history`; Ghostty's never `input text`,
  `send key` or the mouse commands; close only by the recorded id (D38).
- **The runner seam.** A protocol (compile a script file once, call a handler with text
  arguments in one Apple event, read a typed reply or a typed failure carrying the OSA
  error number), the real one over `NSAppleScript` (`kASAppleScriptSuite` /
  `kASSubroutineEvent`, `keyASSubroutineName`, the arguments as a list descriptor, script
  source never built from values) on the main actor, and a fake. **Nothing in a test, the
  probe or the build compiles a built-in script**: compiling a `tell` block reads the target
  app's dictionary, which must never risk launching Terminal or Ghostty (*Unattended-run
  rules* 8). Hermetic tests compile only test scripts with no `tell` block (a handler
  echoing its arguments, one returning a wrong shape, one raising an error) and check the
  built-ins' text for the forbidden commands. Compiling and calling the built-ins is part of
  the owed real runs.
- **The loader, under D19's rules.** Built-ins from a directory passed in (the bundle's
  `Contents/Resources/Terminals/` in the app; `Resources/Terminals/` or a test folder in
  checks). User definitions from `~/Library/Application Support/muxFinder/terminals/`
  (passed in, never created by the loader): the folder owned by the user, mode 0700, no
  symbolic link on the way; each file a regular file owned by the user, not group- or
  world-writable, opened without following links, at most 64 KiB (a script at most
  256 KiB), at most 32 definition files. A user definition overrides the built-in with its
  id; two user files with one id are both refused. Every unusable file is kept with its
  problem (path's last component and a plain reason) and is never fatal; a missing user
  folder is no problem; an unsafe folder makes every user definition unusable with one
  problem.
- **Per definition**, with no Apple event and nothing launched: the app found through
  LaunchServices by bundle identifier (path, version), whether it meets `minimumVersion`
  (numeric dotted comparison; unreadable is "unknown", not a pass), whether it is running,
  and the Automation permission without a prompt (`AutomationPermission`; `exec` definitions
  need none: "not needed").
- **`terminals list`** keeps its iTerm2, Terminal and Ghostty rows as they are and adds
  `definitions` (each: id, display name, source `builtIn` / `user` / `userOverride`, open
  kind and command form, focus kind, the app facts above) and `problems` (each unusable file
  and its reason); `--builtin-directory <dir>` and `--user-directory <dir>` for checks
  (default the repository's `Resources/Terminals/` when run from it, else none, and the real
  user folder, read-only). It still launches nothing, sends no Apple event that could prompt
  and writes nothing; it compiles no script.
- **Tests**: hermetic, for the schema's every refusal, the loader's every file rule (on
  private folders from `mktemp -d`-like temporary directories), override and duplicate
  rules, argv expansion, the `words` limits, the version comparison, the runner over test
  scripts and the fake, and both built-ins loading cleanly with the forbidden commands
  absent.

Calls for I-12b2 (helper plain mode; 2026-11-06, before its worker):

- **Explicit mode words.** `muxfinder-launch attach-plain <uuid>` and `muxfinder-launch
  profile-plain <host id>`, beside `attach`, `profile` and `ssh-setup`, which stay exactly as
  they are (byte for byte what they write to the terminal, their argv, exit codes and
  timings; no existing test's expectation edited). Plain mode is chosen only by the mode
  word, never from `TERM_PROGRAM`, `TERM` or any other environment. The words are D2's
  characters, so they pass `TerminalLaunchCommand`'s `words` and `exec` forms as `{mode}`;
  each is a named constant the seam (I-12b3) reuses.
- **The request's terminal.** An attach request gains `terminal`: `"iterm2"` or a definition
  id (`TerminalDefinition`'s id rule, `iterm2` excluded there). The app's writer always
  writes it; a request without it reads as `iterm2`, so a request an older muxFinder wrote is
  still run by `attach`. `attach` refuses a request whose terminal is not `iterm2`, and
  `attach-plain` one whose terminal is `iterm2` (or missing), with the existing wrong-kind
  exit and nothing run, as `ssh-setup` and `attach` refuse each other's kind today (72). A
  plain request also carries `keepsMinimumLifetime` (the definition's, default false); the
  field is refused on an iTerm2 request, where the 10 s minimum always holds (D14).
- **The plain attach.** No `-CC`, never an unbound attach: on This Mac the attach child is
  the tmux binary the guard finds with `PlainLaunch.localAttachArguments(session:
  detachingOthers:)` over the request's four identity values (the bound `if-shell -F`
  form, D38); on an SSH host D17's `/usr/bin/ssh -t … -- <destination> <D3 string>` with
  `PlainLaunch.remoteScript` and the launch token as its sixth argument. `detachingOthers`
  (and `remoteMoveHereScript`) exactly when the request is a move here, by the request's
  existing marker for it; the worker reads how a move here is told apart today and records
  it. The values come from the request after the guard's own checks; nothing new builds
  shell or tmux source from values. The child's standard input is the helper's terminal
  opened read-write (*Verified facts*, "Phase I-12a proof": tmux draws through it). Exit
  statuses as D17 and D38 (65 a changed session, 68 a bad token, and so on), mapped to the
  existing result kinds.
- **What plain mode leaves out and keeps.** It writes no OSC 1337 sequence (no `Disinter`),
  no status report request and waits for none, and buries nothing. It keeps the result file
  (written exactly as `attach` writes it), the failure explanation and the wait for Return
  (`MUXFINDER_LAUNCH_NO_WAIT=1` skips it as today). The 10 s minimum lifetime holds only when
  the request's `keepsMinimumLifetime` is true.
- **The early report.** `attach-plain` writes `<uuid>.report.json` next to the request
  (atomic, 0600, under `LaunchStore`'s existing directory rules) right after its attach child
  starts and before it waits on it: a schema version, the helper's pid, its terminal's path
  (from its standard input with `ttyname`; none when that is not a terminal, which I-12c
  treats as "cannot confirm here"), the attach child's pid and the child's start time as the
  kernel reports it (so a reused pid is told apart). `attach` writes none (its confirmation
  stays the tmux connection's, D15). `LaunchStore` reads it as a peek (never taking it) and
  removes it wherever it removes the request's other files; a malformed or oversized report
  reads as a typed failure, never as a confirmation.
- **The plain profile.** `profile-plain <host id>` is `profile` without `-CC`: the same
  read-only `hosts.json` read, the same session name rule and `tmux -u new-session -A -s
  <name>` (over interactive ssh for an SSH host, D26's remote form without `-CC`), and the
  same fallbacks (with `TMUX` or `MUXFINDER_LAUNCHED` set, or on any failure, it execs the
  login shell; test mode with `MUXFINDER_LAUNCH_NO_WAIT=1` and `profile-test-<host id>.json`
  as `profile`). I-12d shows it as the per-host command with Copy.
- **Test mode.** `MUXFINDER_LAUNCH_TEST_MODE=1` (or the `test-mode` file) writes the argv
  digest for `attach-plain` and `profile-plain` too (with the attach child's pid, as
  `attach` does) and honors `testLaunchDelaySeconds`; `testSuppressDisinter` has nothing to
  suppress there and is accepted and ignored.
- **Checks.** Hermetic tests through the helper's existing seams for every call above: both
  mode words and the refusals in both directions, the local and remote argv equal to the
  `PlainLaunch` builders' for the same values (move here included), the bytes written to the
  terminal (no OSC 1337 and no status report request in plain mode; `attach`'s unchanged),
  the minimum-lifetime rule, the report's contents, mode, atomic write, peek and removal, the
  plain profile's argv and fallbacks. Then one real plain attach of the built helper with no
  terminal app and no iTerm2: on a pseudo-terminal the check opens itself (as `plain-proof`
  does), against a `muxfinder-test-*` session on a private `TMUX_TMPDIR` server, with a
  private `MUXFINDER_LAUNCH_DIRECTORY` and `MUXFINDER_LAUNCH_NO_WAIT=1`: the report's
  terminal is that pty and its child pid the attach child, the session has exactly one
  client with that `client_tty`, a bound `PlainClientDetach` ends it, the helper writes its
  result and exits, nothing is left behind. Its form is the worker's (a `swift test` test if
  it stays hermetic and quick, else a recorded check in `docs/TESTING.md`). The remote plain
  attach's real run is I-12c's `e2e-plain`. **Regression** (requirement 12; the helper's
  `attach` is what iTerm2 runs): `e2e-local` and `e2e-bury --local` on the final code, under
  the gate in `PROGRESS.md` *Next action* 3, by the orchestrator.
- **Records.** D14 (the two mode words, the report file, the terminal field and its
  refusal), D38 ("Helper plain mode (I-12b2)"), `docs/TESTING.md` *Phase I-12b2*, and
  `CLAUDE.md`'s launch helper line (present state). Nothing in the app or the coordinator
  writes a plain request yet (I-12c).

Calls for I-12b3 (terminal seam; 2026-11-06, before its worker):

- **Where.** `Sources/MuxFinderCore/Terminals/`: the seam, the iTerm2 adapter, the plain
  window layer and their fakes, in new files; tests in `Tests/MuxFinderCoreTests/`. Nothing
  in `Sources/MuxFinderCore/Attach/` or `ITerm2/` changes its logic (a conformance in a new
  file at most).
- **The seam sits at the session operations, not below the coordinator.** iTerm2's open,
  confirmation by connection, burial and detach are one flow over its API (D15, D29); the
  seam must not split it (requirement 2: iTerm2 behaves exactly as now). A protocol (the
  worker names it, e.g. `TerminalBackend`, `Sendable`) whose requirements are the
  coordinator's public operations the app and the self-tests call today, with their present
  signatures and result types: attach, move here (with `MoveHereConfirmation`), create and
  attach (with `onCreated`), the current session by name, detach a session on a host, detach
  other clients (D37), the per-key state; plus `terminal` (`LaunchTerminalApp`, I-12b2) naming
  the backend, and focus of an attachment the backend opened through a terminal-neutral
  handle (an enum: iTerm2's launch tab session id, or a plain window from the layer below),
  the iTerm2 case mapped to `showLaunchTab`. Today's result types are kept byte for byte;
  I-12c may extend them for plain attachments. "Open here" is not in the seam yet:
  requirement 7 rewrites it for every terminal, iTerm2 included, through discovery's
  `client_pid` / `client_tty` and process ancestry, and I-12c adds it.
- **The iTerm2 backend** is an adapter over `AttachCoordinator` (a wrapper or a conformance,
  the worker's call): each operation forwards to the existing method with the same arguments
  and returns its result unchanged; a plain handle given to it is refused with a typed
  result, nothing run. Tested over the existing coordinator test fakes: for the same fake
  run, the adapter's result equals the coordinator's and the same requests reach the fakes.
- **Nothing is rewired yet.** `AppModel`, `AppEnvironment.makeAttachCoordinator`, the
  self-tests, the probe and the refresh engine keep calling the coordinator directly; I-12c
  moves them onto the seam and picks the backend from the terminal setting (I-12d shows it).
  So no runtime path changes in this phase, and its regression is every existing test passing
  with no expectation edited; no real run is needed.
- **The plain window layer** (the plain backend's open, focus and close; its confirmation,
  detach, move here and its conformance to the seam are I-12c's), built from a
  `LoadedTerminalDefinition`, the helper path and the launch token:
  - **Open.** The command from `TerminalLaunchCommand` for the definition's form, with the
    mode word the I-12b2 constant for `attach-plain` (never a literal) and the token.
    `appleScript`: the definition's script compiled once per loaded definition for the
    layer's lifetime through `AppleScriptRunning`, then `muxfinder_open` through
    `TerminalScriptCalls`, the reply read strictly; the result a plain window value
    (definition id, window id and tty, each optional as the reply gives them). `exec`: the
    argv `TerminalLaunchCommand` builds, the executable resolved inside the app
    LaunchServices found, spawned without a shell through a seam with a fake; the spawn must
    neither block the call until the terminal app exits nor end that process when the call
    returns (the worker records how). Its window has no id or tty (the schema already ties
    `tty` and `windowID` focus to `appleScript`).
  - **Before any event** the app's facts (`TerminalAppInspecting`): not installed or too old
    (`tooOld`; `unknown` refused too) and an Automation permission read as `denied` are typed
    failures with nothing sent; `notDetermined` and `targetNotRunning` go ahead (in the app a
    person asked for the window and can answer the prompt; launching the app is the open's
    purpose there). Checks never take that path (fakes only; *Unattended-run rules* 8).
  - **Focus** by the definition's focus kind: `tty` calls `muxfinder_focus` with the window's
    tty, `windowID` with its window id (the other argument empty, as the handler contract
    says); a window lacking the value its kind needs is a typed failure, nothing sent; `app`
    brings the app forward by bundle identifier with no Apple event (`NSRunningApplication`,
    behind a seam with a fake), never launching it (not running: a typed result).
  - **Close** only by a window id this layer's own open recorded (any other is refused,
    nothing sent), through `muxfinder_close`; never as a detach (detach is tmux's, D38). The
    script's refusal of a busy window (1001) and of a missing one (-1728) map to typed
    results. A window with no id cannot be closed (typed result).
  - **Failures** are one typed enum (app missing or too old, permission denied, the launch
    command refused with its reason, compile or handler failure with the OSA number, a
    malformed reply, spawn failed, not this layer's window, …), each with a plain sentence for
    I-12d; never a retry (D13). The layer runs on the main actor, as `AppleScriptRunning` does.
- **No real Apple event and no compile of a built-in.** Tests use `FakeAppleScriptRunner`, a
  fake app inspector, a fake spawner and a fake activator. A test may load the built-in
  definitions (text only, as I-12b1's tests do) and drive them through the fake runner to
  check the arguments each handler gets (Terminal's command text, Ghostty's words with the
  token last).
- **Records.** D38 "Terminal seam (I-12b3)", `docs/TESTING.md` *Phase I-12b3*. `CLAUDE.md`
  changes only if a command does (none expected).

**I-12c split, and the orchestrator's calls** (2026-11-06, before its first worker). I-12c is
three workers' worth, so:

- **I-12c1 — the plain backend (high).** Requirements 5 and 6 as I-12a settled them: the
  plain backend's conformance to `TerminalBackend` (plain request, open through
  `PlainTerminalWindows`, confirmation from the early report, detach and Move here through
  tmux, its in-memory attachments), the result types extended additively, hermetic. Nothing
  rewired: the app, self-tests, probe and refresh engine still call the coordinator.
- **I-12c2 — open on this Mac (high).** Requirement 7: discovery's `list-clients` gains
  `client_pid` and `client_tty` (still read-only, D6, D12), a read-only process ancestry
  reader by pid mapping a local client to the terminal app it descends from (over a fake
  process table in tests), "open in <app> on this Mac" for every terminal, iTerm2 included
  (with iTerm2 chosen, D16's focus by connection unchanged), focus by that terminal's focus
  kind, and the remote "attached somewhere" rule. Its calls are written at its selection.
- **I-12c3 — onto the seam, and the real runs (high).** The app (`AppModel`,
  `AppEnvironment`), the self-tests and the probe move onto `TerminalBackend`, the backend
  picked from a terminal setting in `preferences.json` through `PreferencesStore` (D32's
  rules; default iTerm2 when installed, else Terminal; I-12d adds its UI), the app never
  contacting iTerm2 when it is not the choice; probe `attach --terminal <id>` and `e2e-plain
  --terminal terminal|ghostty --local | --ssh saturno-m4` (its real runs only through the gate
  of *Unattended-run rules* 8, else owed); iTerm2's `e2e-*` runs and self-tests rerun as
  regression (requirement 12). **Split into I-12c3a and I-12c3b** (below, after the calls for
  I-12c2).

Calls for I-12c1 (the plain backend; 2026-11-06, before its worker):

- **Where.** New files in `Sources/MuxFinderCore/Terminals/` (the backend, its records and
  its fakes; the worker names them, e.g. `PlainTerminalBackend`), tests in
  `Tests/MuxFinderCoreTests/`. Changes outside `Terminals/` only where the conformance needs
  them and only additively: the result types in `Attach/AttachModels.swift` (below), a plain
  request writer in `Launch/` if none exists, a shared helper factored out of
  `AttachCoordinator` only when the plain backend would otherwise copy it (revalidation by
  discovery, D18's creation, D21's confirmation check, D37's per-client checks), the
  coordinator's behaviour and every existing test's expectation unchanged.
- **One backend per loaded definition.** `PlainTerminalBackend` is built from one
  `LoadedTerminalDefinition`, a `PlainTerminalWindows`, the helper path, the launch store,
  discovery and the remote runners the coordinator already uses (its seams, so tests use the
  existing fakes); `terminal` is `.plain(definitionID:)`. It is `Sendable` (an actor, or the
  coordinator's own pattern), hopping to the main actor only for the window layer.
- **Attach**, in D15's order where it applies: revalidate the session by discovery (the
  coordinator's step and failures); the existing-attachment check is the backend's own
  in-memory record for the key (below; open here by ancestry is I-12c2), and a record whose
  client still holds the session focuses its window instead of opening another (a focused
  result); else write a plain request (`terminal` the definition id, `keepsMinimumLifetime`
  the definition's, the session's four identity values, the move-here marker only for Move
  here), open through `PlainTerminalWindows` (a typed open failure ends the attach `failed`
  with that error kept for I-12d's sentence, the request discarded, nothing retried, D13),
  then confirm. Concurrent attaches of one key coalesce into one launch, and an earlier launch
  still unresolved refuses a new one exactly as the coordinator does (its existing failure).
- **Confirmation, only evidence** (requirement 5, D38). Read the early report by
  `peekReport` (never taken) and the helper's result by `peekResult`, polling within the
  coordinator's budgets (D15 locally; D17's 20 s remotely, then a still-waiting state that is
  never a success and keeps watching, as D17). **This Mac:** confirmed when the session has
  exactly one client whose `client_tty` is the report's terminal path and whose `client_pid`
  is the report's attach child, and that child still runs with the report's kernel start
  time; a report without a terminal path never confirms ("cannot confirm here"). **SSH
  host:** confirmed when exactly one client of the session has the launch token at the end of
  its parent shell's arguments (I-12a's read-only `ps` by `client_pid` over discovery's
  noninteractive ssh). In both, none is no confirmation yet and two candidates never confirm
  (`PlainClientIdentification`, as I-12a built it). A helper result before confirmation ends
  the attach `failed` with its mapped failure (the coordinator's mapping); a malformed or
  oversized report is a typed failure, never a confirmation. The confirmed attach records the
  client as D38's bound detach needs it (session identity, client name, pid and creation
  time; remotely the token too).
- **After confirmation** the window is shown once by its definition's focus kind (as D15's
  activation; its outcome recorded in the result, never failing the attach). No bury, no
  `Disinter`, nothing restored; the backend never closes a window by itself (the window's own
  process end closes it or not, per the user's terminal settings; `close` stays for checks).
- **Its attachments, in memory only** (requirement 7's "sessions muxFinder opened"): key →
  loaded definition, window, client record, launch id. A record is dropped once its helper's
  result appears or a read-only bound check finds its client gone; it never outlives the
  backend.
- **Detach** (`detach(session:on:)`, requirement 6): the record's client only, with D38's
  bound `PlainClientDetach` (locally, or over BatchMode ssh as discovery runs), never by
  closing a window; the record dropped once the client is gone; no record → the existing "not
  attached here" result, nothing run.
- **Move here** (`moveHere(_:confirmation:)`): D21's confirmation check as the coordinator
  does it, then the attach above with the move-here marker (the helper's bound `attach-session
  -d`, D38); a stale confirmation runs nothing.
- **Create and attach** (D18's creation, then the attach above), **current session by name**
  (discovery, as the coordinator), **detach other clients** (D37's rules: the server-wide
  check of name, pid, creation time and session, the 10 s age guard, the kept client being
  the record's; no record → the existing refusal, nothing sent), **state** (per key, as the
  coordinator publishes it) and **focus** (`.plainWindow` through the window layer with this
  backend's loaded definition; `.iTerm2LaunchTab` → `handleOfAnotherTerminal`, nothing run).
- **The result types, extended additively** (the I-12b3 call allowed it). Every iTerm2 value
  stays as it is, its `kind` strings too, and no existing test's expectation changes. Plain
  attachments get their own states or payloads (the worker's call between new cases and new
  optional fields, recorded in D38), never iTerm2's connection or session ids overloaded with
  plain values; `isConfirmed`, `isFocused` and `isAttached` hold for their plain
  counterparts, and the window handle and client record are reachable from the result. Where
  an exhaustive `switch` in `MuxFinderUI` or the probe needs the new cases, the minimum that
  compiles, with plain states treated like their iTerm2 counterparts (I-12d writes the
  strings); no UI behaviour changes for iTerm2.
- **Tests, hermetic** (fakes for the window layer, discovery, the launch store's files on a
  private folder, the remote runner and the clock): local and remote confirmation with a
  match, none, two candidates, a report without a terminal path, a stale report (another
  start time, the child gone); a helper result before confirmation; every open failure; the
  remote still-waiting state; coalescing and the unresolved earlier launch; focus of a live
  record and a dropped stale one; detach and move here (the exact bound argv locally and over
  ssh), no record; detach others keeping the record's client; create and attach; the iTerm2
  handle refused. **And one end to end on This Mac with no terminal app**: the window layer's
  fake open runs the built `muxfinder-launch attach-plain` on a pseudo-terminal of the test
  against a private tmux server (`-f /dev/null`, a private `HOME` and `TMUX_TMPDIR`, as
  `LaunchHelperPlainBinaryTests`), the backend confirms it, its detach ends only that client
  and the helper exits 0.
- **No real run** (nothing rewired, no terminal app, no iTerm2): the regression is every
  existing test passing unedited. No Apple event, no compile of a built-in script.
- **Records.** D38 "Plain backend (I-12c1)", `docs/TESTING.md` *Phase I-12c1*. `CLAUDE.md`
  changes only if a command does (none expected).

Calls for I-12c2 (open on this Mac; 2026-11-06, before its worker). Requirement 7 of
`autoclaude/processed/110-other-terminal-apps.md`, as core only: nothing in `MuxFinderUI`,
`AppEnvironment`, the self-tests or the existing probe commands' behaviour changes (I-12c3
wires it, I-12d writes the strings).

- **Discovery's client record** (`Tmux/ProbeScript.swift`, `ProbeReport`, `TmuxModels`): the
  `list-clients` format gains `#{client_tty}` and `#{client_created}` after `client_pid`, still
  read-only (D6, D12; the script stays static). The client model gains an optional terminal
  path (kept only when it is an absolute path of printable ASCII without whitespace, at most
  255 bytes) and an optional creation time (canonical decimal seconds); an unusable value is
  nil, never a failed session or host. `discover` JSON shows both. Existing tests keep their
  expectations; the worker may extend their client input lines with the new fields.
- **The process table, read-only, behind a seam** (new files in `Terminals/`, names the
  worker's, e.g. `ProcessAncestry`): per pid, its parent pid, kernel start time and controlling
  terminal device (`sysctl` `KERN_PROC_PID`), its executable path (`proc_pidpath`) and, for a
  registered app, its bundle identifier (`NSRunningApplication(processIdentifier:)`). Nothing
  is signalled, launched or sent an Apple event; a fake table in tests.
- **A local client's terminal app** (verified on Neptuno 2026-11-06: iTerm2 runs every
  session's processes under its job server `~/Library/Application Support/iTerm2/iTermServer-3.7.7`,
  whose parent is iTerm2 while it runs, and launchd after an iTerm2 restart; Terminal is
  `Terminal → login → shell`; Ghostty is not installed here, its chain unverified): walk the
  parent chain from the client's pid, at most 64 steps, stopping at pid 1 or 0 or a repeated
  pid. The first ancestor whose bundle identifier is iTerm2's (`com.googlecode.iterm2`) or
  that of any loaded definition names the app; an ancestor that is iTerm2's job server (an
  executable named `iTermServer-*` in `~/Library/Application Support/iTerm2/` of the user's
  real home, injected in tests) names iTerm2 whatever its parent. **Pid reuse is refused**:
  the client's own process must have the controlling terminal whose device is the client
  path's (`stat` `st_rdev`) and must not have started after `client_created` (one second of
  rounding allowed); a client with no usable terminal path or creation time is unmapped. The
  answer is typed: the app (its bundle identifier, and the loaded definition ids sharing it,
  in loader order; iTerm2 needs none) or an unmapped reason (no terminal ancestor, process
  gone, terminal mismatch, started after the client, unreadable, too deep). Only This Mac's
  sessions are ever attributed; **an SSH host's clients never are** (their processes run on
  that host): a remote session attached by hand in a plain terminal is "attached somewhere",
  unless the plain backend's own record or D16's index says otherwise (documented in D38).
- **Per session**, This Mac only: the local attachments, one per attributed client (app,
  client pid, terminal path, control mode). With D16's index results beside them (iTerm2
  chosen), a control-mode client attributed to iTerm2 is left to the index (so D16's mapping
  and its unmapped kinds stay exactly as today); every other attributed client is "open in
  <app> on this Mac". Without the index (iTerm2 not chosen, so never contacted), every
  attributed client counts, iTerm2's control-mode clients included.
- **The refresh engine**, additively: an optional attributor seam on `RefreshCoordinator`
  (nil, the default, changes nothing, every existing test unedited); with it, This Mac's
  snapshot sessions carry their local attachments (a new field defaulting to empty).
- **Focus by the terminal's focus kind.** iTerm2 with D16's index: focus by connection,
  unchanged. A session the plain backend opened: its own record's window (`.plainWindow`,
  I-12c1). Any other attributed client: activation of that app (a new handle kind, e.g.
  `.app(bundleIdentifier:)`) through a main-actor seam over `NSRunningApplication` (a running
  app only: never `NSWorkspace` open, never a launch, never an Apple event; not running → a
  typed outcome, nothing launched; macOS 14's cooperative activation may refuse, so the
  outcome is recorded and never fails an attach).
- **The plain backend's attach** gains the check I-12c1 left out, after its own records and
  before any request is written: on This Mac, a session with an attributed local client
  becomes a focus of that app (a new focused result carrying the app and the activation
  outcome), nothing opened, as D16 never opens a duplicate; unmapped clients and a table that
  cannot be read never block the attach (D16's unmapped kinds); the table is read once per
  attach. Move here is unchanged (it attaches with `-d` whatever is attached). **The iTerm2
  backend and the coordinator are unchanged** (requirement 12): no ancestry check in their
  attach.
- **Probe**, read-only, new: `muxfinder-probe local-clients [--builtin-directory <dir>]
  [--user-directory <dir>]` discovers This Mac, attributes every client and prints JSON (per
  client: session id, never its name; control mode; the app or the unmapped reason) and the
  counts per app; contacts no iTerm2, launches and activates nothing; `--help` contacts
  nothing. Its real run and `discover --local` / `--ssh saturno-m4` are the phase's only real
  runs; record counts only.
- **Tests, hermetic**: the parser's new fields (present, absent, unusable); the walk over a
  fake table (Terminal's chain, an app chain, iTerm2's job server under iTerm2 and under
  launchd, nested tmux, sshd, a cycle, the depth bound, a process gone mid-walk, a terminal
  mismatch, a start after the client, two definitions sharing a bundle identifier); the per
  session rule with and without the index; the refresh engine with and without the
  attributor; the plain backend focusing another app instead of opening (own record first;
  unknown never blocks; app not running opens nothing); the app activation's outcomes; SSH
  clients never attributed.
- **Records.** D38 "Open on this Mac (I-12c2)", a sentence in D16 pointing to it,
  `docs/TESTING.md` *Phase I-12c2* (the real runs' counts), the `local-clients` command in
  `CLAUDE.md` *Commands*.

**I-12c3 split, and the orchestrator's calls** (2026-11-06, before its first worker). I-12c3 is
two workers' worth, so:

- **I-12c3a — onto the seam (high).** The terminal setting, the app, the self-tests, the
  refresh engine's attributor and the probe's one-off commands onto `TerminalBackend`;
  hermetic tests, then the two self-tests real (the seam's iTerm2 path) as regression. Calls
  below.
- **I-12c3b — the plain runs (high).** `e2e-plain --terminal terminal|ghostty --local | --ssh
  saturno-m4` (its own `muxfinder-test-*` sessions and its own windows only, cleaned up at the
  end), its real runs only through the gate of *Unattended-run rules* 8 (else owed, with the
  exact command), and iTerm2's `e2e-*` runs as regression (requirement 12). Its calls are
  written at its selection.

Calls for I-12c3a (onto the seam; 2026-11-06, before its worker):

- **The terminal setting.** `preferences.json` gains an optional `terminal` (a terminal id:
  `iterm2`, or a loaded definition's id), read and written only through `PreferencesStore`
  under D32's rules (its lock, its refusal of unusable files and its merging save unchanged).
  Absent, the default is resolved and never written: iTerm2 when installed (LaunchServices by
  bundle identifier, as `terminals list` finds it), otherwise `terminal`. The resolution is
  typed and pure over its inputs (the stored value, iTerm2's presence, the loaded definitions
  with their app facts): `iterm2`, a plain definition, or **unavailable** with a reason
  (unknown id, app not installed, version below the definition's minimum). An unavailable
  choice is never silently replaced (requirement 8): session actions end in a new typed
  failure naming the choice and the reason, nothing written, launched or sent; I-12d writes
  its sentence and the picker.
- **One backend per terminal id.** `AppEnvironment` hands the model a `TerminalBackend` maker
  instead of an `AttachCoordinator` maker: `iterm2` → `ITerm2TerminalBackend` over today's
  coordinator, built exactly as today (same client, launch store, helper, bury on, the app
  activator for `.app` handles); a plain definition → `PlainTerminalBackend` with its loaded
  definition, `PlainTerminalWindows` over the real `NSAppleScript` runner, the helper, the
  launch store, discovery, the remote runners, and the `LocalClientAttributor` and app
  activator passed in (I-12c2 left them off by default). Built lazily at the first session
  action, as today, and cached per terminal id for the app's life, so switching back reuses
  the earlier backend (no record lost, never two coordinators on one iTerm2). Definitions load
  once at launch (built-ins from the bundle's `Resources/Terminals/`; the user's from
  `~/Library/Application Support/muxFinder/terminals/`, read only, never created), their
  problems kept for I-12d to show.
- **The app never contacts iTerm2 when it is not the choice** (requirement 7). Every iTerm2
  contact in the app is gated on the resolved choice: the API client and its connection, D16's
  `AttachmentIndex`, the profile list (`ITerm2ProfileSource`), Settings' iTerm2 diagnostics,
  onboarding's API check, and D26's persistent-profile rewrite at launch and after a save
  (with a plain choice the existing `DynamicProfiles/muxFinder.json` is left as it is, neither
  written nor removed; the rewrite resumes when iTerm2 is chosen; the hosts' profile settings
  stay in `hosts.json`). Where a view needs a value, a neutral "not used with this terminal"
  state; I-12d writes the strings. Work started under an earlier iTerm2 choice (a buried tab's
  recovery) finishes; nothing new starts. A test proves it over the environment's seams: with
  a plain choice the iTerm2 seams are never called.
- **The refresh engine** gets the attributor for This Mac in both cases
  (`RefreshCoordinator(localClients:)`): with iTerm2 chosen beside D16's index (its
  control-mode clients left to the index, I-12c2's rule), with a plain choice without the
  index. The model carries each session's local attachments into its rows' state (a field, no
  new UI; I-12d draws it), and focusing an `.app` handle goes through the activator.
- **The model moves onto `TerminalBackend`** for every session action: Open, Move here,
  Detach, New session, Detach other clients, Show tab or window, state updates, current
  session by name. With iTerm2 chosen every behaviour, state, banner, string and test
  expectation is unchanged (requirement 12); existing UI tests may change how they wire the
  model (an `ITerm2TerminalBackend` over their coordinator fake), never their expectations.
  Plain results reach the model's states as I-12c1's minimal switches treat them (I-12d writes
  the strings).
- **Changing the choice while the app runs.** The model re-resolves through one setter (I-12d's
  picker will call it); no new file watcher. A change while any session action is pending is
  applied once none is, never cancelling one; the next action uses the new choice's backend.
- **Plain-only refusal** (I-12c1's open question): a session name containing `{`, `[` or `]`
  is refused up front by the plain backend with a typed failure, before anything is written or
  opened, since D38's bound commands cannot check it. The iTerm2 backend is unchanged.
- **The iTerm2 backend's attach never consults ancestry** (I-12c2's open question, settled by
  requirement 12). With iTerm2 chosen, a session open by hand in Terminal on this Mac shows so
  in the model's local attachments and Open still opens it in iTerm2 as today; I-12d may offer
  that row its app's focus.
- **Self-tests** (`--selftest attach-local`, `new-session-local`, `--selftest-keep`) build their
  model through the same `TerminalBackend` path with iTerm2 forced (never reading the user's
  `preferences.json`, as today); steps, output and exit codes unchanged.
- **Probe one-offs.** `attach`, `new-session` and `detach` keep today's iTerm2 behaviour by
  default. `attach --terminal <id>` loads definitions as `terminals list` does
  (`--builtin-directory`, `--user-directory`); `--terminal iterm2` is today's path; for a plain
  id it attaches through `PlainTerminalBackend` and prints the result as JSON (the client
  record a later bound detach needs). Before any Apple event it applies *Unattended-run rules*
  8 itself: the app running and its permission reading `granted` without a prompt, else exit 2
  with the reason, nothing written or sent. `--help` contacts nothing. The `e2e-*` harnesses
  keep calling the coordinator directly (they test its internals).
- **Tests, hermetic**: the resolution (default both ways, round trip, each unavailable reason,
  a stored `iterm2` with iTerm2 gone); the environment's backend choice, the cache and the
  never-contact proof; the model's actions through the seam (iTerm2 over the coordinator fake,
  plain over I-12c1's fakes) and the pending-change rule; the refresh attributor wired; the
  name refusal; the probe's argument parsing and its gate over fake facts. Every existing
  test passes with its expectations unedited.
- **Real runs** (the gate of `PROGRESS.md` *Next action* 3: thread count 38 or lower, leftover
  checks after): `--selftest attach-local` and `--selftest new-session-local` from a fresh
  `scripts/build-app.sh` bundle (the seam's iTerm2 path), `--report-menu-bar-item` with a
  private home, read-only `terminals list` and `local-clients`. No plain real run here (that
  is I-12c3b's `e2e-plain`, under the gate).
- **Records.** D38 "Onto the seam (I-12c3a)", D32 (the `terminal` key), D26 (the rewrite only
  with iTerm2 chosen), sentences of D22/D25 the change invalidates, `docs/TESTING.md` *Phase
  I-12c3a*, `CLAUDE.md` *Commands* for `attach --terminal`.

Calls for I-12c3b (the plain runs; 2026-11-06, before its worker). At its selection neither
Terminal nor Ghostty was running (`pgrep -x Terminal`, `pgrep -x ghostty` both empty), so the
phase builds and proves the harness hermetically, proves its gate refuses for real, and owes the
plain real runs to the user; iTerm2's runs are its real regression.

- **The harness, a new probe command** (`Sources/muxfinder-probe/E2EPlain*.swift`, names the
  worker's): `muxfinder-probe e2e-plain --terminal <id> --local | --ssh saturno-m4
  [--builtin-directory <dir>] [--user-directory <dir>]`, definitions loaded as `terminals list`
  loads them; `--terminal iterm2` refused (exit 2; iTerm2 has its own `e2e-*`), any other id not
  a loaded plain definition refused; `--ssh` with any host but `saturno-m4` refused; `--help`
  contacts nothing. It drives `PlainTerminalBackend` built as I-12c3a's environment builds it
  (its loaded definition, `PlainTerminalWindows` over the real `NSAppleScript` runner, the
  helper, the launch store, discovery, the remote runners, the attributor), never the app's
  `preferences.json`.
- **The gate first** (*Unattended-run rules* 8), before anything is created, written,
  discovered or sent: the app running and, for an AppleScript definition, its permission
  reading `granted` without a prompt (as `attach --terminal` reads it), else exit 2 with the
  reason and the exact command owed to the user; nothing created, no request written, no Apple
  event, no launch. Rechecked at the side-effect boundary before every open, focus and close
  (the window layer's unattended run policy, I-12c3a); a recheck that fails mid-run stops the
  run and cleans up what it made (exit 1).
- **Steps** (one PASS/FAIL line each, every wait bounded, D15/D17 budgets): create its own
  `muxfinder-test-*` session (one `sleep 600` window; remotely over BatchMode ssh as
  `e2e-remote` does); discover it; **open** → confirmed (the client record with name, pid,
  creation time and, remotely, the token; the window handle recorded); **open again** → focused
  through its own record, no second window and no second client; **detach** through the backend
  → its client gone within 10 s, the helper's result present, the record dropped; its window
  closed only by the recorded id after its process ended (left as it is when the terminal's
  own settings already closed it); **Move here**: a plain `tmux -u -C` client of the harness's
  own (BatchMode ssh remotely, as `e2e-local`'s move here step), then `moveHere` with a fresh
  confirmation → confirmed, the harness's client gone (`%exit`), the backend's client the
  session's only one; a stale confirmation runs nothing; **detach others**: a second plain
  control client of its own, `detachOtherClients` once it is 10 s old → `detached(count: 1)`,
  the backend's client kept; **detach** again and close that window as above; **cleanup** on
  every way out (SIGINT/SIGTERM included): end its own plain clients, detach only its own
  backend clients with the bound detach, close only its own windows by recorded id after their
  process ended, kill only its own session, then check none of its sessions, requests, reports
  or children is left. Exit 0 all passed, 1 a step failed, 2 usage or the gate refused, 3 its
  watchdog. It never types into a window, never closes one whose process still runs, never
  launches either app.
- **Hermetic tests**: the argument parsing and refusals; the gate over fake facts (not running,
  `denied`, `notDetermined`, `other`, `targetNotRunning`, an `exec` definition with the app not
  running) refusing with nothing contacted (no session created, no discovery, no request, no
  window call); the step sequence over I-12c1's fakes where a seam allows (the worker decides
  how far, recorded); the cleanup order (no window closed while its process runs).
- **Real runs.** `e2e-plain --terminal terminal --local` and `--terminal ghostty --local`
  for real only to show the gate's refusal (exit 2, nothing created; `pgrep -x Terminal` and
  `pgrep -x ghostty` the same before and after); if, at the run's time, an app shows `running`
  and `granted` in `terminals list`, its `--local` and `--ssh saturno-m4` runs too. Then
  iTerm2's `e2e-local`, `e2e-remote saturno-m4`, `e2e-bury --local` and `e2e-detach-others
  --local` as regression, each under the gate of `PROGRESS.md` *Next action* 3 (38 threads or
  lower, threads let fall back between runs, leftover checks after each).
- **Changes outside the probe** only additively and where the harness needs a seam; the
  coordinator, the backends' behaviour and every existing test's expectation unchanged.
- **Records.** D38 "The plain runs (I-12c3b)"; `docs/TESTING.md` *Phase I-12c3b* (the gate's
  refusals, the regression results, and *Owed* with the exact commands per terminal and host);
  `docs/MANUAL-CHECKLIST.md` (the `e2e-plain` runs beside the existing Terminal/Ghostty items);
  `CLAUDE.md` *Commands* for `e2e-plain`.

Calls for I-12d (the UI; 2026-11-06, at its selection). I-12d is too wide for one worker
(Settings, onboarding, SSH setup, every session string, four galleries per terminal), so it is
**split into I-12d1 and I-12d2**, both routine. Common to both:

- **Strings follow the resolved choice** through one source of terminal wording in
  `MuxFinderUI` (the worker names it): the display name ("iTerm2", "Terminal", "Ghostty", a
  user definition's `name`), the place ("tab" in iTerm2, "window" otherwise) and the verbs
  built from them. Sentence case, English. With iTerm2 chosen every existing string, state and
  test expectation is unchanged (requirement 12); existing tests may change how they wire the
  model, never what they expect.
- **No real terminal-app run** (*Unattended-run rules* 8): `pgrep -x Terminal` and `pgrep -x
  ghostty` are read before and after and must not change; no Apple event, no permission prompt.
  Permission states in the UI are read only with `AEDeterminePermissionToAutomateTarget`
  without a prompt (`AutomationPermission`), at the window's opening and on an explicit "Check
  again", never on a timer. Screenshots only through `--preview-fixtures --preview-snapshot`
  (synthetic fixtures, light and dark, `docs/screenshots/`); never a real window of another app.
- **No new dependency, no core behaviour change** beyond what is listed; core additions
  additive, hermetically tested.

**I-12d1 — Settings, onboarding and SSH setup (routine).**

- **Settings › General "Terminal"** (requirement 8): a picker listing iTerm2 when installed,
  then each loaded definition whose app is installed and meets its minimum version (Terminal
  always; Ghostty from 1.3), user definitions by their `name`; each row with its permission
  state (`granted` "Allowed", `denied` "Not allowed", `notDetermined` "Not asked yet",
  `targetNotRunning` "Checked when the app is running", `other` "Unknown", an `exec`
  definition "Not needed") and a one-line note of plain mode under every plain row ("Plain
  tmux: windows and panes stay inside one terminal window."). Choosing calls
  `AppModel.setTerminal(_:)`: a refused save shows the store's error beside the picker and
  keeps the old choice; a change held by a pending action says "Applies when the current
  action ends." An unavailable current choice stays selected and is shown with its reason
  ("Ghostty isn't installed", "Ghostty 1.2 is older than 1.3", "No terminal named …",
  "Can't read Ghostty's version"), never replaced. Definition problems (the loader's, kept since
  I-12c3a) are listed under the picker, file name and reason only. "Allow in System Settings…"
  opens Privacy & Security › Automation (an URL open, no Apple event) for a `denied` or
  `notDetermined` row.
- **Host editor:** the iTerm2 profile field keeps its value and stays editable; with a plain
  choice its caption says "Used only with iTerm2." "Set up SSH in iTerm2…" follows the choice
  ("Set up SSH in Terminal…", "… in Ghostty…").
- **SSH setup in a plain terminal:** an additive core path that opens the helper's existing
  `ssh-setup <uuid>` mode (D24's request unchanged) in a window of the chosen plain terminal
  through `PlainTerminalWindows` (the same facts gate, compile-once and window binding as an
  attach; no confirmation: the window's open is the result), wired through
  `SSHSetupActions` in place of `notUsedWithThisTerminal` for a resolved plain choice. While
  the choice is still `unresolved` the line keeps today's refusal, reworded to "Still reading
  the terminal setting. Try again in a moment." Hermetic tests over the window layer's fakes;
  no real run (it would be an interactive login and an Apple event: owed to the user).
- **Persistent profiles tab** (requirement 11): with iTerm2 chosen, unchanged. With a plain
  choice, per enabled host the command for that terminal's own "run command" setting, built
  from the bundle's helper path (POSIX single-quoted, D3) and `profile-plain <host id>`, with
  a Copy button (the general pasteboard; nothing else written), and where to paste it
  (Terminal: "Settings › Profiles › Shell › Run command"; Ghostty: "`command = ` in Ghostty's
  config file"; a user definition: the generic sentence). muxFinder never writes another
  terminal's settings. The iTerm2 section collapses to one line: Remove stays offered while
  muxFinder's own `DynamicProfiles/muxFinder.json` exists (the user's explicit action, as
  today); Install is offered only with iTerm2 chosen.
- **Diagnostics:** with a plain choice the iTerm2 rows read "Not used with Terminal" (the
  choice's name) in place of today's neutral placeholder, and a row shows the chosen terminal,
  its version and its permission state (as the picker reads them).
- **Onboarding** (requirement 10): a "Terminal" step before the API step with the same picker
  (default preselected, iTerm2 first when installed); the iTerm2 Python API step and its
  check appear only with iTerm2 chosen; with a plain choice a short plain-mode explanation and
  the permission line take their place ("macOS asks once, the first time muxFinder opens a
  Terminal window."). Onboarding works with no iTerm2 installed (the fixture proves it).
- **Galleries** (`--preview-gallery settings` and `onboarding`, light and dark): the picker's
  states (iTerm2 chosen; Terminal chosen with each permission state; Ghostty chosen;
  unavailable choice; definition problems; pending change; refused save), the host editor and
  Persistent profiles tab with a plain choice, onboarding without iTerm2 and with a plain
  choice. Screenshots replaced in `docs/screenshots/settings-states-*.png` and
  `onboarding-states-*.png`.
- **Tests, hermetic:** the picker's rows from installed apps and definitions (Ghostty below
  its minimum left out unless it is the current choice), every permission label, the
  unavailable reasons, the refused save and the pending note; the plain persistent-work
  command's quoting and per-host lines; SSH setup's plain path over fakes (request written,
  window opened once, nothing sent to iTerm2) and its `unresolved` refusal; onboarding's steps
  per choice; the never-contact proof (`aPlainChoiceNeverContactsITerm2`) still passing.
- **Records:** D38 "The UI (I-12d1)", D23/D24/D26 sentences the change invalidates,
  `docs/TESTING.md` *Phase I-12d1*, `docs/MANUAL-CHECKLIST.md` (the picker's real permission
  states, SSH setup in Terminal and Ghostty, pasting the persistent work command).

**I-12d2 — the popover, the switcher and the session states (routine).**

- **Actions and states** (requirement 9): "Open in <terminal>", "Show window" in plain mode
  and "Show tab" in iTerm2, "Detach" and "Move here" unchanged, the launch's pending and
  failure lines naming the choice; the "earlier launch pending" refusal names the terminal of
  the launch that holds it (I-12c3a's open risk); a session with local attachments in another
  app on this Mac (`SessionRow.localAttachments`) shows "Open in Terminal on this Mac" and its
  focus action ("Show in Terminal"), with iTerm2 chosen too (I-12c3a's call: Open still opens
  in iTerm2).
- **Errors:** "Ghostty's AppleScript is turned off" (with where to turn it on),
  "muxFinder isn't allowed to control Terminal" with "Open System Settings…" to Privacy &
  Security › Automation, "Terminal isn't running and couldn't be opened", the unavailable
  choice ("The chosen terminal, Ghostty, isn't installed." with "Open Settings"), the plain
  name refusal ("Terminal windows can't attach a session whose name has { [ or ]."); every
  `PlainTerminalWindowError` and plain `AttachFailure` case mapped, none falling to a generic
  line.
- **Detach other clients**, plain wording: a run stopped partway says "Stopped after
  detaching N" when the count is known and "Some may have been detached" when it is not
  (I-12c1's open risk), never "none detached" when that is unproven.
- **Detach from another terminal's records** (I-12c3a's open risk): while a session has a
  record kept for a terminal that is not chosen, its row offers "Detach (opened in <that
  terminal>)" through that terminal's cached backend; nothing else of that backend is used.
- **Galleries** (`--preview-gallery popover`, `attach` and `switcher`, light and dark): each
  of iTerm2, Terminal and Ghostty for the row actions, pending, confirmed, focused, failed
  (each new error), local attachment in another app, unavailable choice. Screenshots in
  `docs/screenshots/{popover,attach,switcher}-states-*.png`.
- **Tests, hermetic:** strings per terminal for every action and state, each error mapping,
  the detach-others wording, the other-terminal detach routed to its own backend, and every
  existing popover/switcher expectation unchanged under iTerm2.
- **Records:** D38 "The UI (I-12d2)", D25/D32/D37 sentences the change invalidates,
  `docs/TESTING.md` *Phase I-12d2*, `docs/MANUAL-CHECKLIST.md` (real Open, Show window,
  Detach, Move here in Terminal and Ghostty, the errors).

Calls for I-12e (the docs; 2026-11-07, at its selection). One worker, routine, **documents
only**: no file under `Sources/`, `Tests/`, `Resources/` or `scripts/` changes, and no real
run of any kind. Every fact comes from D38's sections (I-12a to "The UI (I-12d2)"), D3's
extension, the code (`Sources/MuxFinderCore/Terminals/`, `Resources/Terminals/`) and the
probe commands' `--help` (which contacts nothing); never from memory. The repository is
public: no host name beyond those the docs already name, no user path (only `~/…` forms of
muxFinder's own folders), nothing of the private download site.

- **`docs/REQUIREMENTS.md`:** the brief above stays byte for byte; one dated addendum at the
  end ("Addendum, 2026-11-06: other terminal apps") quoting the user's decisions verbatim from
  the specification's *User decisions* (plain mode outside iTerm2, for everyone, generalize,
  JSON definitions, one Terminal setting), and saying in a sentence that it supersedes the
  brief's "iTerm2's native tmux control mode only" for Terminal and Ghostty, iTerm2 unchanged.
- **`docs/TERMINALS.md`** (new): what plain mode is beside iTerm2's control mode, and what it
  costs (one window, tmux's status bar, prefix keys and copy mode); the built-ins (Terminal,
  Ghostty from 1.3) and how the choice resolves; the Automation permission and what reads it;
  persistent work per terminal (where to paste the command); **"Adding a terminal"**: the
  schema 1 keys exactly as the parser takes them, the open, command and focus kinds, the
  whole-argument placeholders, the minimum version, the user folder
  (`~/Library/Application Support/muxFinder/terminals/`) and its rules, override by id, the
  problems list; the safety rules (what muxFinder never does to another terminal); a worked
  `exec` example that **loads** (the worker writes it into a private folder from `mktemp -d
  /private/tmp/mfx.XXXXXX`, mode 0700, and runs `swift run muxfinder-probe terminals list
  --builtin-directory Resources/Terminals --user-directory <that folder>`, read-only, with
  `pgrep -x Terminal` and `pgrep -x ghostty` the same before and after; it must show under
  `definitions` with source `user` and no entry under `problems`; the folder removed after);
  **later candidates**: WezTerm (`wezterm start -- …`), Kitty (`kitty @ launch` or
  `--single-instance`), Alacritty (`alacritty msg create-window`) and Warp, each with what
  would be needed; and the sentence "Ghostty may ship tmux control mode; revisit native mode
  for it then."
- **README:** requirements (iTerm2 or Terminal or Ghostty 1.3+), permissions (Automation for
  the chosen plain terminal), first run (the Terminal step), usage (the choice and what
  changes in plain mode), persistent profiles (the plain command), scope and limitations
  (plain mode's), a pointer to `docs/TERMINALS.md`. Existing iTerm2 text stays true.
- **`docs/ARCHITECTURE.md`:** a "Terminal backends (D38)" section (the seam, the iTerm2
  backend wrapping the coordinator, the plain backend, the window layer, the helper's plain
  modes, local client attribution, definitions and their loader), the modules list, the
  security rules and the decision index brought up to date.
- **`docs/TESTING.md`:** the tested vs expected-to-work matrix gains Terminal and Ghostty
  rows (hermetic, gate refusals real, window runs owed); one *Phase I-12e* note (docs only,
  the example's load check); nothing earlier rewritten except a sentence it falsifies.
- **`docs/MANUAL-CHECKLIST.md`:** items 26–28 checked against the specification's
  acceptance (Automation granted for Terminal and Ghostty; open, detach and Move here in each,
  locally and for a session on Saturno; pasting the persistent work command into Ghostty's
  config; onboarding on a Mac without iTerm2, if one is available); anything missing added.
- **`CLAUDE.md`:** the first paragraph names `docs/TERMINALS.md`; every probe command and flag
  it documents for I-12 (`terminals list`, `local-clients`, `plain-proof`, `attach
  --terminal`, `e2e-plain`, the helper's plain modes) checked against `--help` and the code,
  sentences that are wrong corrected in place; the safety rules and *Unattended-run rules* 1
  and 8 checked to say the same (a test touches only what it opened), tightened if they
  differ, nothing relaxed.
- **`PLAN.md`:** D38 gains a short "The docs (I-12e)" paragraph naming `docs/TERMINALS.md` as
  the user-facing reference; nothing else of D38 rewritten.

## Deferred (explicitly out of scope for v1)

Named tmux sockets, session deletion, cloud sync, terminal previews, AI features, process
migration, reboot resurrection, workspace management, Intel builds. (Notarized distribution
was deferred too until D28 added `scripts/release.sh`.)
