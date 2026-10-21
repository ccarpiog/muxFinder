# Testing

How muxFinder is tested, and what was checked against real hosts. Phase 12 turns this into
the full "tested vs expected to work" matrix.

## Unit tests (`swift test`)

Hermetic (PLAN.md D11): no ssh, no iTerm2, never the user's tmux server.

- **Discovery parser** (`ProbeReportParserTests`): real captured reports from this Mac and
  Saturno (`Tests/MuxFinderCoreTests/Fixtures/discovery/`), real hostile names captured from a
  private tmux 3.8 server, synthesized hostile names (raw tabs, text that mimics records,
  `a;rm -rf ~`, `$(touch /tmp/x)`, quotes, `-x`, emoji, CJK), a malformed corpus (bad ids,
  non-canonical integers, nonce mismatches, forged records after a line break, duplicate ids,
  mixed servers, missing or extra lines), the 4 KiB line and 1,000 session/client caps, every
  truncation of a real report, and single-byte corruption at every position.
- **Classifier** (`ErrorClassifierTests`): a table of ssh stderr strings captured on
  2026-10-21 (plus standard OpenSSH wordings that could not be produced here, marked
  synthesized), "changed beats verification failed", run failures, no-server messages,
  session keys per host.
- **Requests** (`DiscoveryProbeTests`): exact argv for local and SSH runs, `TMUX`/`TMUX_PANE`
  stripped, D6 options, strict-harness options (including no connection sharing), invalid
  configuration rejected before any process runs.
- **Probe script** (`ProbeScriptTests`): the real static script through `/bin/sh`, and the D3
  command string through `/bin/sh`, `/bin/zsh -f` and `/bin/bash`, against a fake `tmux`
  (fails if `-u` is missing or `TMUX` leaks): sessions and clients, metacharacters in the
  override path, not found / not tmux, no server, stderr sanitizing (first line, printable
  ASCII, 200 bytes), an 8 MiB stderr flood (real exit status kept, 200 bytes reported, peak
  memory of the shell and its children under 8 MiB per `/usr/bin/time -l`), an endless `-V`
  line cut to 200 bytes, client-listing failure, a hanging tmux stopped by the timeout.
- **End to end** (`DiscoveryEndToEndTests`): real tmux on a private `TMUX_TMPDIR` under `/tmp`,
  started with `-f /dev/null`, holding only `muxfinder-test-*` sessions running `sleep 60`
  (Unicode, emoji, shell metacharacters). Checks no-server, every created id and name, no
  injected file, then kills the server's `muxfinder-test-*` sessions by id and checks
  no-server again. Cleanup runs in a task of its own, so it is not cancelled with the test,
  each tmux command has a timeout, and it ends before the directory is removed; a second test
  cancels its task while a session exists and checks the session is gone. `TMUX` and
  `TMUX_PANE` are set to a bogus server to prove they are ignored. Skips when tmux is absent.
- **iTerm2 protobuf codec** (`ProtoWireTests`): varint edge cases (0, 127, 128, `UInt32.max`,
  2^63, `UInt64.max`, negative `int32`/`int64` as 10-byte varints), every scalar and
  length-delimited encoding, unknown fields of all four wire types skipped, known fields with
  the wrong wire type skipped, repeated occurrences of a singular embedded message merged (no
  value may span two occurrences, and the nesting limit still holds), split-tree link oneofs
  merged until the member changes, and typed `ProtoWireError`s for truncated keys, varints,
  length prefixes, fixed-width and length-delimited values, lengths past the end (also past a
  nested message's end), overlong varints, wire types 3/4/6/7, field numbers 0 and 2^29, and
  nesting past 100 levels; each malformed input is also checked inside a response envelope.
- **iTerm2 golden messages** (`ITerm2GoldenTests`, `ITerm2JSONTests`): every request type
  (list sessions, create tab with a command, with window/index/close-on-end, with a command
  needing every JSON escape, activate session/tab/window/app, list profiles with and without
  filters, tmux list connections and send command) encodes byte for byte like the fixture
  iTerm2's Python module produced. Every response fixture decodes to the expected values:
  nested split trees, tmux tab fields, minimized and buried sessions, unknown fields of every
  wire type (top level and nested), status enums, profile `Name`/`Guid`, errors, unsupported
  submessages and notifications; unknown enum values decode to `unknown`. Merge fixtures, which
  the generator checks against `api_pb2`'s own decoding, cover responses split across
  occurrences (`08 01 92 07 02 08 01 92 07 00`, a list-sessions response whose tab root and
  links arrive in pieces, a tmux send-command), unknown fields before and after a response
  (including Python's re-serialization of the list-sessions fixture), and oneof members
  replacing each other. Every truncation and single-byte corruption of every response fixture
  decodes or throws `ProtoWireError`. The fixtures (`Tests/MuxFinderCoreTests/Fixtures/iterm2/`)
  hold only synthetic values (a test checks for machine-specific strings) and are committed;
  `swift test` never runs Python.
  Regenerate them (dev only, after changing the generator) with iTerm2's interpreter in
  isolated mode, then check that `git status` shows only intended changes:
  `"$HOME/Library/Application Support/iTerm2/iterm2env-3.14/versions/3.14.0/bin/python3" -I scripts/dev/gen-iterm2-fixtures.py`.
- **WebSocket frames** (`WebSocketFrameTests`): the three payload-length encodings at 0, 125,
  126, 65,535, 65,536 and 70,000 bytes (header bytes, mask bit, key, masked payload), unmasked
  round trips, a fresh masking key drawn per frame (counted with an injected key source; the
  default source is random), no data frames after a close, a failed write shutting the stream
  down, the writer's queue behind a blocked write (a withdrawn message never written, one whose
  deadline passes while queued skipped with `timedOut`, the message being written no longer
  withdrawable and written whole, unstarted data before a close skipped), the close codes
  allowed on the wire (all 65,536 checked), strict UTF-8 validation, and rejected server
  frames: reserved bits, reserved opcode, masked, fragmented or over-125-byte control frames, a
  64-bit length with its top bit set, an oversized length refused from the header alone;
  every split point of a frame decodes only once complete.
- **WebSocket handshake** (`WebSocketHandshakeTests`, fake stream): the exact request iTerm2
  needs (every verified header, random 16-byte key), the RFC 6455 accept example, unsafe header
  values refused, a reply delivered one byte per read, frame bytes in the same read as the
  header tail handed to the reader, 401/406/500 replies, a wrong accept key, missing
  `Upgrade`/`Connection`, malformed status and header lines, an unrequested subprotocol or
  extension, the server closing mid-reply, an endless reply head (16 KiB cap) and a silent
  server (timeout).
- **WebSocket reader** (`WebSocketReaderTests`, fake stream): a three-fragment message with a
  ping and a pong between fragments delivered one byte per read (reassembled; pong with the
  ping's payload), several frames in one read, frames split mid-header and mid-payload, a
  server close answered with its code and the stream shut down, valid close codes with a UTF-8
  reason echoed (1000, 1003, 1007, 1014, 3000, 4999), malformed close payloads answered with
  1002 and never echoed (one byte; codes 0, 999, 1004, 1005 — the review's `88 02 03 ED` —,
  1006, 1015, 1016, 2999, 5000) or with 1007 (a reason with an invalid byte, a surrogate or an
  overlong form), a client-initiated close not answered twice, the 16 MiB cap (exactly 16 MiB
  accepted; one byte more refused from the header with close code 1009), read timeouts that
  keep partial input, protocol violations closing with 1002 (text message, stray continuation,
  new message inside a fragmented one), end of stream mid-frame.
- **Unix socket transport** (`UnixSocketStreamTests`): `socketpair()` transfer both ways
  (200 KB through a small buffer on two threads), read timeout, `shutDown()` waking a blocked
  read, peer close as end of stream and `closedByPeer` instead of `SIGPIPE`, missing socket and
  stale socket file (bound, then closed, under `/tmp`) both `apiDisabled`, an overlong path,
  and a whole handshake plus request plus close handshake over a socket pair with a server
  thread. Never iTerm2's socket.
- **Request matching** (`ITerm2ConnectionTests`, fake peer): ids 1, 2, 3; responses answered
  3, 1, 2 with a notification and an unknown id in between; a server `error` failing only its
  request; end of stream failing every pending request; per-request timeout with the late
  response ignored; an undecodable message (`protocolError`); an empty response; task
  cancellation; ping while a request waits; server close; a malformed server close
  (`protocolError`, answered with 1002); client close; a stalled half-received message
  (`timedOut`) while an idle connection stays open; a failed write (`notSent`); and, with the
  fake stream's writes held, a request queued behind a blocked write then cancelled or expired
  (fails as not sent; its frame never reaches the stream, the next frame is request 3), a
  request cancelled or expired mid-write (plain `CancellationError`/`timedOut`; its frame still
  arrives whole), and a connection end failing the request being written with `disconnected`
  and the queued one with `notSent(.disconnected)`.
- **Client lifecycle** (`ITerm2APIClientTests`, fake connector, cookie provider and app
  control): first call connects with the verified headers and decodes the list-sessions
  fixture; not running (no cookie, no connect, no launch); socket missing (no cookie);
  connection refused; cookie failures (`automationDenied`, `cookieUnavailable`); HTTP 401
  (`authRejected`); a reconnect after iTerm2 drops the connection using the second cookie;
  concurrent first calls sharing one connection; `createTabFailed`, `activateFailed`,
  `tmuxRequestFailed`; a tmux reply without payload as an empty list; successful create tab,
  send command, list profiles and activate; a mismatched response type; `ensureRunning()`
  launching only when needed and failing when the socket never appears; disconnect then
  reconnect; `disconnect()` during the cookie request (gated fake provider: the waiting call
  fails at once with `notSent(.disconnected)`, the invalidated attempt never connects, the next
  call uses the second cookie) and during the handshake (the late connection is closed with a
  1000 close frame and shut down, the next call opens a new one); a caller cancelled while
  waiting for the attempt (`CancellationError` at once, the attempt's connection serves the
  next call); diagnostics recording only the error kind.
- **Cookie and fake** (`ITerm2CookieAndFakeTests`): strict `"<cookie> <key>"` parsing (12
  malformed shapes refused, including header injection), AppleScript error mapping (-1743 →
  `automationDenied`), the static script source, the real provider refusing to run while
  iTerm2 is not running, error kinds (including `notSent`) and one-line descriptions without
  iTerm2's error text,
  `FakeITerm2Integration` (queued results then fallback, call log, not-running and
  socket-missing guards, `ensureRunning()`), and `Tab.isTmuxTab` with iTerm2's `"-1"`.

## Real-world checks

### Phase 2 — discovery (2026-10-21)

Environment: Neptuno (`neptuno-m4`, macOS 27.2, tmux 3.8 at `/opt/homebrew/bin/tmux`,
OpenSSH_10.5p1); Saturno (`saturno-m4` over Tailscale, key auth, tmux 3.8). Neither had a
tmux server running before the checks. Commands ran from the repo root with the debug build
(`.build/debug/muxfinder-probe`, i.e. `swift run muxfinder-probe`).

| Check | Command | Observed result |
|---|---|---|
| Local, no server | `TMUX_TMPDIR=$(mktemp -d /tmp/mfx.XXXXXX) muxfinder-probe discover --local` (`TMUX`, `TMUX_PANE` unset) | `noServer`; tmux `error connecting to …/tmux-501/default (No such file or directory)`; 26 ms |
| Local, tmux not found | `discover --local --tmux-path /nonexistent/tmux` | `tmuxNotFound` (no fallback to Homebrew tmux); 10 ms |
| Local, test sessions | `tmux new-session -d -P -F '#{session_id}' -s <name> 'sleep 300'` for `muxfinder-test-plain` and `muxfinder-test-ünïcödé-日本-🧪` on the default server, a control client (`tmux -u -C attach-session -t '$0'`, stdin closing after 4 s), then `discover --local` | `ok`, 2 sessions: `$0` plain (1 attached client, control mode) and `$1` with the exact Unicode name; same server pid/start time/socket `/private/tmp/tmux-501/default`; ids equal the ones `new-session -P` printed; 35 ms. Both sessions killed by id; tmux then reported `no server running` |
| Saturno, no server | `env -u LANG -u LC_ALL -u LC_CTYPE muxfinder-probe discover --ssh saturno-m4` | `noServer`, node `Saturno-M4.local`, tmux `/opt/homebrew/bin/tmux` found without PATH help; 743 ms |
| Saturno, test sessions | same two names created on Saturno over ssh, a remote control client on `$0`, then the command above (no locale on the client) | `ok`, `$0` and `$1` with the exact Unicode name, client listed as control mode; 750 ms. Sessions killed by id; Saturno then reported `no server running` |
| Unicode without `-u` (negative control, D12) | on Saturno with one `muxfinder-test-ünï` session: `env -u LANG ssh saturno-m4 "tmux list-sessions -F '#{session_id}<TAB>#{session_name}'"` vs. the same with `tmux -u` | without `-u`: `$0_muxfinder-test-_n_` (tab and Unicode both `_`); with `-u`: exact bytes. Session killed |
| DNS failure | `discover --ssh something.invalid` | `unreachable(dnsFailure)`; 6 ms |
| Timeout bound | `discover --ssh 192.0.2.1` | `unreachable(timeout)` after 5.0 s (ssh `ConnectTimeout=5`; the 12 s runner limit is the backstop) |
| Refused | `discover --ssh ssh://127.0.0.1:1` | `unreachable(refused)`; 7 ms |
| Auth failure | `discover --ssh nonexistent-muxfinder@saturno-m4` | `authFailed`; 501 ms |
| Host key unknown | `discover --ssh saturno-m4 --strict-known-hosts <empty temp file>` | `hostKeyProblem(unknown)`; 277 ms. Re-run after `ControlPath=none` was added: same result, 352 ms |
| Host key changed | `discover --ssh saturno-m4 --strict-known-hosts <temp file with a freshly generated, wrong ed25519 key for saturno-m4>` | `hostKeyProblem(changed)`; 289 ms |
| Hostile names, real tmux | 7 `muxfinder-test-*` sessions on a private `TMUX_TMPDIR` server (`-f /dev/null`) named with `;rm -rf ~`, `$(touch /tmp/mfx-x)`, quotes and backticks, `-x`, emoji, `##{pid}`, a backslash; `discover --local --raw` | every name came back as tmux stored it (`#{pid}` literal, `\` as `\\`); `/tmp/mfx-x` never created; captured as `local-hostile-names.txt`; sessions killed by id |

Method notes:

- **No server without touching the user's server:** tmux's default socket lives in
  `$TMUX_TMPDIR/tmux-<uid>/default` (default `/tmp`), and the CLI passes its environment
  through (minus `TMUX`/`TMUX_PANE`), so a fresh empty `TMUX_TMPDIR` gives a server-less
  default. Use a short `/tmp` path: socket paths must stay under 104 bytes.
- **Host-key harness:** `--strict-known-hosts <file>` adds `StrictHostKeyChecking=yes`,
  `UserKnownHostsFile=<file>`, `GlobalKnownHostsFile=/dev/null`, `ControlMaster=no` and
  `ControlPath=none` (an existing master connection would otherwise be reused without checking
  `<file>`); it is stricter than the user's configuration and ssh never writes known-hosts
  files under strict checking. The "changed" row predates the `Control*` options; the
  "unknown" row was re-run with them. The temp files were unchanged afterwards (empty file still 0 bytes). `~/.ssh` was not touched.
- **Fixtures:** captured with `discover … --raw` during the checks above, so they contain only
  `muxfinder-test-*` session names; no other session existed on either server at the time.
- **Cleanup:** after the checks, `tmux list-sessions` reported no server on Neptuno and on
  Saturno, and no `tmux` process was left on Neptuno.

### Phase 3b — iTerm2 API client (2026-10-21)

Environment: Neptuno, iTerm2 3.7.6 with the API server on. Commands ran from the repo root in
a shell inside iTerm2 (so the in-process `NSAppleScript` cookie request showed no prompt),
through `swift run muxfinder-probe` (debug build). All read-only: no tab was created or
activated, no tmux command was sent, no window, tab or session was touched, and no tmux
session was created or killed. Only the output's shape is recorded here.

| Check | Command | Exit | Observed shape |
|---|---|---|---|
| Status | `iterm2 status` | 0 | `{connected: true, protocolVersion: "1.21", running: true, socketPath, socketPresent: true}`; 0.18 s end to end (cookie, handshake, and a close handshake that iTerm2 answered) |
| tmux connections | `iterm2 list-connections` | 0 | `{connections: [], count: 0}` (no tmux integration connection was open) |
| Sessions | `iterm2 list-sessions` | 0 | `{summary: {windows: 3, tabs: 3, sessions: 3, tmuxTabs: 0, buriedSessions: 0}, windows: [{windowID, tabs: [{tabID, tmuxWindowID: "-1", sessionIDs: [1 id], layout: {vertical, children: [{sessionID}]}}]}], buriedSessionIDs: []}`; all ids strings; no tab had `tmuxConnectionID` |
| Profiles | `iterm2 list-profiles` | 0 | `{count: 13, profiles: [{guid, name}]}`; every `guid` and `name` a string, GUIDs in uppercase UUID form |
| API off (mapping) | `iterm2 status --socket /tmp/mfx-nonexistent/socket` | 69 | `{connected: false, error: {kind: "apiDisabled", message}, running: true, socketPresent: false, …}` plus the one-line stderr error; no cookie requested |
| API off, listing | `iterm2 list-sessions --socket /tmp/mfx-nonexistent/socket` | 69 | stderr only: `muxfinder-probe: iTerm2's API server is off. … [apiDisabled]` |

Method notes:

- `notRunning` and `authRejected` were not produced against the real iTerm2: the first would
  need iTerm2 to quit, the second a deliberately bogus cookie, and the run rules forbid both.
  They are covered by the hermetic client tests; `authRejected` is HTTP 401, the status
  iTerm2's Python module handles as an authentication failure (PLAN.md *Verified facts*).
  The stale-socket case (`ECONNREFUSED` → `apiDisabled`) is covered with a private socket
  under `/tmp`.
- The listings' raw stdout (ids, profile names) went to temporary files that were deleted
  after the shape above was extracted.
