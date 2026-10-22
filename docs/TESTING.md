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
  filters, tmux list connections and send command, close sessions with `force` and close windows
  without it) encodes byte for byte like the fixture
  iTerm2's Python module produced. Every response fixture decodes to the expected values:
  nested split trees, tmux tab fields, minimized and buried sessions, unknown fields of every
  wire type (top level and nested), status enums, profile `Name`/`Guid`, errors, unsupported
  submessages and notifications, close statuses both unpacked (as iTerm2 writes them) and as a
  packed run; unknown enum values decode to `unknown`. Merge fixtures, which
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
  send command, list profiles, activate and close; an ownership-bound tmux command (the listing,
  then the command on the same connection when the owner matches; only the listing for another
  owner, `tmuxConnectionNotOwned`; a listing lost with its connection → `notSent`, no
  reconnect); an ownership-bound activation (the connections, the sessions and `Activate` of
  the connection's first tab on the same connection, the given target replaced; `nil` and no
  `Activate` for a connection without a tab; only the listing for another owner; a sessions
  listing lost with its connection → `notSent`, no reconnect); a mismatched response type;
  `ensureRunning()`
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
  `FakeITerm2Integration` (queued results then fallback, call log including close, not-running and
  socket-missing guards, `ensureRunning()`, the ownership-bound tmux command checking the next
  listing), and `Tab.isTmuxTab` with iTerm2's `"-1"`.
- **Launch models** (`LaunchModelsTests`): canonical lowercase launch ids accepted, 12
  malformed ones refused (uppercase, braces, missing hyphens, non-hex, path traversal,
  whitespace, non-ASCII); request and result JSON round trips and the exact request keys; an
  unknown host kind, a non-`$N` session id or an uppercase id refused on decode; unusable
  values (format version, pid 0, relative override, negative time); every failure's
  `{"kind": …}` encoding; the full exit status → failure tables for the attach child (64–68,
  other statuses, 126/127/255, signals) and the check child (a timeout wins, 64–68, anything
  else check failed), and each failure's exit status (75 for a check timeout, 128 + n when
  interrupted; PLAN.md D14).
- **Launch store** (`LaunchStoreTests`, temporary directories only): directory 0700 and files
  0600 checked with `lstat`, no temporary file left; `<root>/launch` from `AppPaths`; a 0755
  directory tightened; a symbolic link as the directory refused for every operation (target
  untouched); a foreign directory refused (root-owned `/usr`, and a temporary one checked
  against another uid, unchanged); a file in the way; a missing directory never created by
  the helper's operations; delete on read and single use; duplicate ids refused; TTL with a
  fake clock (valid at 120 s, refused and removed at 121 s, and when dated 60 s in the
  future); the sweep (only stale request/result/digest/temporary files; the test-mode marker,
  other files and directories kept); results taken once; unsafe request files refused and
  removed (symbolic link with the target kept, FIFO without blocking, 0644, oversized,
  invalid JSON, another id); the test-mode marker only as a regular file, created 0600 and
  removed once; argv digests. Extended ACLs, set with `acl_set_link_np` inside the test's own
  temporary directory: an inheritable `everyone` ACL and a deny-only one on the launch
  directory removed by the helper's and the app's operations; a parent with an inheritable
  ACL leaves none on the created launch directory or on any file written there (request,
  result, argv digest, marker), all 0600; the writer removes an ACL a new file inherited
  (the premise checked first) before writing; request and result files with an allow or a
  deny-only ACL refused and removed; an immutable directory whose ACL cannot be removed
  refused as unusable.
- **Helper path** (`LaunchHelperPathTests`): the D2 rule (space, quotes, `$`, backticks, `;`,
  tab, line break, `~`, `\`, non-ASCII and relative paths refused; bundle, build and plain
  paths accepted), the tab command line, and locating the helper next to an executable
  (missing, not executable, through a symbolic link, in a folder with a space).
- **Guard script** (`LaunchGuardTests`): the real static guard (the check child) through
  `/bin/sh` against a fake `tmux`: exact argv and check request (stdin `/dev/null`, 10 s
  default deadline, 4 KiB cap), the separate attach argv, no `exec` or `attach-session` in
  the script; a match exits 0 and prints exactly the tmux path, nothing on stderr, no
  attach; the printed path accepted only as one line with an absolute path to a regular
  executable file (links followed) and, with an override, only the override (11 refused
  shapes: no newline, extra lines, relative, empty, missing, a directory, not executable,
  CR, NUL, invalid UTF-8); identity answers classified (changed values → 65, empty or other
  session id → 64, empty or garbage → 67); tmux errors (no server, no socket, can't find
  session → 64; permission denied, protocol mismatch → 67 with the line on stderr, sanitized
  to printable ASCII and 200 bytes); missing or non-tmux override → 66 without fallback; 11
  bad argument shapes → 68; `TMUX`/`TMUX_PANE` never reach tmux.
- **Guard on real tmux** (`LaunchGuardRealTmuxTests`): a private `TMUX_TMPDIR` server under
  `/tmp`, started with `-f /dev/null`, holding one `muxfinder-test-*` session; the check only,
  never an attach. No socket → 64; the discovered session passes and yields the located tmux,
  with and without an override; a wrong id → 64; a wrong `session_created`, pid or server
  start time → 65; after the server exits (stale socket) → 64. Cleanup kills the session by
  id, like the discovery end-to-end test. Skips when tmux is absent.
- **Terminal child runner** (`TerminalChildRunnerTests`): attach child: exit status and
  signal terminations; the child stays in the parent's process group and gets only
  descriptors 0–2 (an inheritable descriptor numbered 100 or above does not leak); signals
  forwarded through the control, both queued before the spawn and sent while the child runs
  (SIGHUP → `terminalHungUp`); task cancellation → SIGTERM; spawn failures. Check child:
  piped output and its own process group; a pending signal interrupts it before anything is
  spawned; a signal while it runs kills its whole group, including a background descendant
  that ignores SIGTERM (pids and group gone); task cancellation → `interrupted([SIGTERM])`; a
  spawn failure is thrown.
- **Helper logic** (`LaunchHelperTests`, fake child runner and terminal): success (request
  consumed; the check with the guard argv, the helper's deadline and `TMUX`, `TMUX_PANE` and
  `MUXFINDER_LAUNCH_*` removed from its environment; the attach as the printed tmux path with
  `-u -CC attach-session -t <id>` and the same environment; success result, no output, no
  wait); a guard failure ends the launch before any attach, explained, and waited for only
  when interactive; the check's stderr copied to the tab as printable ASCII before the
  explanation and kept out of the diagnostics; an unusable printed path (missing, not the
  override) → 67 without an attach; a check timeout → 75; a check interrupted by SIGHUP
  (129, no wait) or SIGINT (130, waits); a closed tab during the attach (SIGHUP passed on)
  never waited for; signal deaths exit 128 + n; missing (70), expired (71) and spawn-failure
  (74, either child) results; 7 usage errors (exit 2, nothing run or consumed) and `help`;
  an unusable directory override (73); the argv digest written by the environment variable
  or the marker file, before parsing; diagnostics free of paths and session ids. The minimum
  lifetime (D14): on an interactive terminal that was not hung up, every outcome (a tmux exit
  right after attaching, a guard failure after Return, a usage error) holds the tab until the
  helper is 10 s old, after the result is written and after any wait for Return; only the
  rest of the 10 s is held (4 s elapsed → 6 s, 9.5 s → 0.5 s, 10 s or more → none, a clock
  that went backwards → 10 s); `help`, a terminal that is not interactive and a SIGHUP never
  hold. `MUXFINDER_LAUNCH_MINIMUM_LIFETIME_MS` sets the lifetime only when it is 1 to 7
  decimal digits (else 10 s). The wait gate resumes its wait exactly once, also when the end
  comes before the wait or several ends race.
- **Stalled check** (`LaunchHelperStalledCheckTests`): the helper in the test process with
  the real child runner (300 ms grace) and the real guard against the fake tmux hanging in
  `display-message` (it ignores HUP, INT and TERM and keeps a background `sleep 30` that does
  too). With a 1 s deadline (doubled and retried, up to four times, if a loaded machine did
  not reach `display-message` in time) the launch ends as `checkTimedOut` (75) after the
  deadline and less than 5 s past it; a SIGHUP passed on through the control ends it at once
  as `interrupted` (129) without a wait for Return. Either way the fake, its sleeper and their
  process group are gone, and nothing attaches.
- **Helper binary** (`LaunchHelperBinaryTests`): the built `muxfinder-launch` run with a
  private launch directory, `MUXFINDER_LAUNCH_NO_WAIT=1` and stdin that is not a terminal:
  usage errors (2); a missing request (70) with its result and an argv digest of exactly
  argv (count 3, the binary path's length and SHA-256, the launch id); the attach path
  against the fake tmux (tmux is the helper's direct child, in the helper's process group,
  reading the helper's stdin, writing its stdout; exit 0 → success, exit 1 →
  `childExited(1)` with the explanation); SIGTERM and SIGHUP sent to the helper alone reach
  tmux (the fake's traps exit 43/44), and the helper survives to record the result; SIGTERM
  and SIGHUP sent to the helper alone while the check hangs end the launch as `interrupted`
  (143/129) with a result, and the check's process group (separate from the test runner's,
  so only the helper can have removed it) is gone; real tmux on a private server: no server
  → 64, wrong `session_created` → 65, both recorded in the result. No real tmux client is
  ever attached by `swift test`.
- **Helper binary in a terminal** (`LaunchHelperTerminalTests`): the built `muxfinder-launch`
  with its stdin on a pseudo-terminal's slave side (so it is interactive), stdout and stderr
  on a pipe, its own process group, a launch id without a request (70, no child) and a
  shortened `MUXFINDER_LAUNCH_MINIMUM_LIFETIME_MS`. Signals and Return are repeated every
  50 ms until they take effect. SIGINT and SIGTERM, from the failure prompt on or only during
  the hold after Return, never end it: it exits 70 with its result no earlier than its 3 s
  lifetime and less than 5 s after the later of that lifetime and the end of the wait, which
  the signal ended like Return. SIGHUP, at the prompt or during the hold, kills it at once,
  far inside its 60 s lifetime.

- **Attach coordinator** (`AttachCoordinatorTests`, fakes for iTerm2, discovery, the launch
  store and the clock; a manual clock makes the 15 s budget run out at once; the
  existing-attachment check off, so only the launch path's calls are seen): a successful
  attach (states `requested` → `launched(gateway)` → `confirmed(connection)`, the request file's
  values, the launch tab request — new window, `<helper> attach <uuid>`, close on end, the host's
  profile and tmux override —, the identity command through the connection, bound to the launch
  tab, activation of the
  connection's first tab without `select_session`, no close request); a connection that appears
  after two polls next to another tab's; activation waiting for the first tab, `noTab` after its
  budget (still confirmed), a refused activation, and a launch tab's connection id that is
  another tab's by the activation (`failed(tmuxConnectionNotOwned)`, nothing activated, still
  confirmed); two concurrent attaches for one session
  sharing one launch and one result (one discovery, one request, one `CreateTab`, one
  `launched`), a later attach launching again, different sessions not coalescing; cancelling
  every caller (`cancelled`, request withdrawn, launch tab still reported); an all-cancelled
  launch whose held `CreateTab` answers after a newer launch was confirmed (its updates reported
  with `isCurrent` false, the session's state left at the newer `confirmed`); the 15 s poll timeout
  (`timedOut`, request withdrawn, nothing sent through a connection); helper results mapped to
  failures (64–66 to `sessionGone`/`sessionChanged`/`tmuxMissing`, others to `helperFailed`,
  exit 0 before a connection to `helperEnded`); identity answers naming another pid, start time,
  socket or session (`identityMismatch`) or unreadable (`identityCheckFailed`), each followed by
  `detach-client` bound to the launch tab only once it is 10 s old (virtual time, counted from
  `launched`) and no activation (a tab-separated answer, wrong lengths or a client not in
  UTF-8 mode are unreadable); a failed identity request with nothing more sent;
  revalidation failures (no server, tmux missing, session gone, `session_created` changed, id
  reused by another server, probe error) before anything is written or sent; SSH hosts refused;
  a request that cannot be written; `CreateTab` failures (definitive, not sent, unknown outcome)
  sent once, never retried, request withdrawn; `ensureRunning()` failing; detach sending
  `detach-client` bound to the launch tab, waiting for the connection to close and taking the
  helper's result (clean), a detach not sent (no wait), a connection that never closes (budget,
  one command only); detach waiting until the launch tab is 10 s old (right after the attach:
  sent at 10 s; 12 s later: no wait; a tab it did not open: 10 s from the call), a detach
  cancelled during that wait sending nothing, and a connection id now owned by another session
  (an iTerm2 restart) refused with `tmuxConnectionNotOwned`, nothing sent. Every failure has a
  kind and an English message.
- **Created session** (`CreatedSessionTests`): the static `CreatedSession.format`, its parser
  (trailing line breaks; 14 refused shapes, among them a tab in the socket path or name), the
  match against discovery (server pid, start time, socket path, id, creation time and name must
  all agree: a restarted server reusing the id does not match), and recovery by exact name
  among sessions created since a given time (no match, older, ambiguous).
- **Connection identity** (`ConnectionIdentityTests`): the static length-prefixed identity
  command (PLAN.md D16) and detach command; exact answers from a client in UTF-8 mode
  (trailing `\n` or `\r\n`; `:`, `_`, a tab and non-ASCII inside the host name and socket
  path, the lengths deciding); a clean answer from a client not in UTF-8 mode; 8 answers from
  such a client that are `nonUTF8`, never an identity (`é` replaced so the path is shorter than
  its length, a tab replaced at the same length, `_` or `:` in the host or path, a dropped
  zero-width character that makes the host swallow the next separators, a non-ASCII byte, the
  old tab-separated line as tmux mangles it); and 30 unreadable shapes (no or another flag, the
  old tab-separated line, wrong or overflowing lengths, missing or extra fields, an empty or
  control-character host, leading zeros, signs, pid 0, overflow, spaces, empty fields, a
  relative or empty path, a bad session id, an extra line, invalid values from a client not in
  UTF-8 mode).
- **Attachment index** (`AttachmentIndexTests`, a fake iTerm2 with per-connection answers and a
  clock whose timeouts fire only when the test advances it): a connection mapped to its
  session, bound to the owner from the listing, with the identity command the only command
  sent; the session id taken from the answer and two connections of one session; unknown
  connections (another host name, a case difference, another pid, start time or socket, a
  restarted server, no hosts) and ambiguous ones (two hosts with the same node name and
  server; the same host listed twice counts once), each counted, never guessed; stale ones
  (no id, no owner or an empty id in the listing, with no command sent; a refused request, an
  unreadable answer, a lost connection; an owner change between the listing and the command,
  refused by the binding rule); clients not in UTF-8 mode (a clean answer maps; `é` or a tab
  replaced, or a `_` that may be a replacement, are `nonUTF8` and never mapped, even when
  discovery reports that very path; the same path through a client in UTF-8 mode maps); a
  hung connection bounded by the 3 s timeout (still waiting at
  2.999 s, stale at 3 s, its request cancelled) while the other connection maps; the filter
  (connections left out get no command and count as excluded); listing failures thrown
  (`notRunning` included); cancellation; hosts built from discovery results.
- **Attach coordinator, existing attachments** (`AttachFocusTests`, the coordinator with an
  index whose clock never fires): a session attached in the user's own tab is focused
  (`requested` → `focused`, the owning session as gateway, the first tab activated without
  `select_session`, the counts reported) with no request, no `ensureRunning` and no
  `CreateTab`, also when no tab appears (`noTab`); a connection id that is another tab's by the
  activation (the user's connection closed and its id was reused) activates nothing and opens
  nothing (`attachmentChanged`), and with two attachments the other one is focused;
  concurrent attaches share one focus; other
  sessions' connections, unknown servers and stale answers do not block a launch; a listing
  failure fails the attach (`attachmentCheckFailed`) before anything is written; iTerm2 not
  running proceeds to `ensureRunning` and the launch; the default coordinator checks before
  launching; a discovery result without a report fails. `detach(session:on:)`: an attachment
  the coordinator opened (`detach-client` at 10 s counted from its launch, the identity checked
  again first, the helper's result taken), two attachments of the user's (both at 10 s from
  the index's snapshot, in listing order, each bound to its own tab), a user's connection that
  first appears in a snapshot taking 7 s of virtual time (discovery 4 s, listing 3 s: the
  re-check and `detach-client` at 17 s, not 10 s), an owner change refused by the re-check or
  by `detach-client`'s own binding check (`notSent`), a connection that shows another session
  by then, or answers through a client not in UTF-8 mode (`identityChanged`, nothing sent),
  nothing attached (another
  session's connection, no server, iTerm2 not running), cancellation during the wait (nothing
  sent), and check failures (listing, discovery, an SSH host).

## Helper test mode: argv digest

To see exactly how iTerm2 splits a tab's `Command` property, turn on the helper's test mode
and read the digest it writes before parsing its arguments (PLAN.md D14):

- Turn it on with `MUXFINDER_LAUNCH_TEST_MODE=1` (direct runs) or, for helpers iTerm2
  starts, by creating a regular file named `test-mode` in the launch directory
  (`~/Library/Application Support/muxFinder/launch/`). An e2e run creates the marker before
  opening the tab and removes it during cleanup. The sweep never removes it.
- The helper writes `argv-<helper pid>.json` (0600) in the launch directory: `argumentCount`,
  `arguments` (per argument, argv[0] first: `byteLength` and lowercase hex `sha256`),
  `launchID` (the first argument after argv[0] that is a canonical launch id, else absent),
  `helperPID` and `recordedAt`. No other raw argument is stored.
- `LaunchStore.takeArgvDigests()` reads the digests (and deletes them), oldest first. To check
  a run, compare `argumentCount` with 3, `arguments[0]` with the helper path's length and
  SHA-256, and `launchID` with the request's id. `muxfinder-probe e2e-local` does exactly that
  for every launch it makes.

## Real-world checks with iTerm2 (`muxfinder-probe`)

These open real iTerm2 windows. Run them explicitly from a shell inside iTerm2 (so the cookie
request shows no prompt), never from `swift test`, with `TMUX_TMPDIR` unset: the helper in
iTerm2 always uses the default tmux server. Run `swift build` first: `swift run
muxfinder-probe` builds only the probe, and iTerm2 runs the `muxfinder-launch` built next to
it, which may be older. Check `muxfinder-probe iterm2 status` before and after: a timeout
(exit 75) means a modal iTerm2 dialog is open; stop and report which step caused it.

- `swift run muxfinder-probe e2e-local` — the local integration proof (PLAN.md Phases 4 and
  5a). It creates `muxfinder-test-<8 hex digits>` on the default server (two windows, the first
  split in two, every pane `sleep 600`), turns on the helper's test mode (the
  `launch/test-mode` marker, through `LaunchStore`), and prints one `PASS`/`FAIL` line per
  step: 1 create, 2 discover, 3 attach (the existing-attachment check finding nothing, states,
  activation, the argv digest: 3 arguments), 4 tabs and split through `ListSessions`, 5 focus
  existing (a second attach of the attached session ends `focused` on the same connection and
  launch tab, `requested` → `focused`, one of its tabs activated, the check counting exactly 1
  mapped and 0 unmapped connections; nothing opens: the same window and tab ids before and
  after, for the run's own windows and every other, the same connections, no new launch tab or
  argv digest), 6 detach by session (`detach(session:on:)` finds exactly that attachment,
  checks it again and sends `detach-client`: answered, connection closed, helper exit 0, tmux
  tabs and launch tab closed, session alive with the same id, 2 windows, 3 live `sleep` panes,
  no client), 7 reattach (attach, tabs, then a detach by connection with the same checks), 8
  two concurrent attaches (one launch: one launch tab, one new connection, its two tmux tabs;
  one argv digest), 9 stale guard (a stale target refused by revalidation without a tab; with
  discovery reporting the same wrong `session_created` the helper's guard refuses it:
  `sessionChanged`, no connection, no tmux client; the refused launch tab must still be open a
  second later, showing the explanation and waiting for Return, and is then closed by its
  recorded session id once it is 10 s old), 10 cleanup. Notes under the steps record what
  iTerm2 did (argv split, placement, tab fields, the check's counts and timings, whether the
  launch tab closed, how old each launch tab was when it ended). Exit 0 only when all 10 pass;
  128 + n after signal n. Safety: only its own session, which every later step (rediscovery
  before each attach, the survival checks, the kill) accepts only if its server pid, start
  time, socket path, id, creation time and exact generated name are those `new-session -P`
  reported; when a signal cuts `new-session` short, cleanup first finds the session by that
  exact name among sessions created since the attempt; it is killed by id. Its attachment
  index asks only connections owned by launch tabs the run opened (PLAN.md D16), so other tmux
  connections get no command at all; setup prints how many exist. Only connections iTerm2
  lists as owned by launch tabs it opened are detached (checked again right before each
  `detach-client`), only those launch tabs closed, and only by the ids iTerm2 reported; every
  wait is bounded (tmux calls 5 s, iTerm2 requests 10 s, the index 3 s per connection, polls
  3–5 s, attach 15 s to a connection, the whole run 300 s); cleanup runs after a failure,
  SIGINT/SIGTERM/SIGHUP or the time limit. Every launch tab is at least 10 s old before it ends
  (the coordinator waits before `detach-client`, the harness before it kills the session or
  closes a tab, and the helper does not exit younger), because iTerm2 shows a blocking modal
  warning for sessions that end within 3 s of starting (see `docs/INTEGRATION-PROOF.md`). The
  focus step opens and ends nothing. A full passing run takes about 43 s.
- `swift run muxfinder-probe attach --local --session '<$id>'` — one real attach of a session
  of the default server, the way the app does it; prints the result as JSON (state, failure,
  launch id, launch tab session, connection, activation, the existing-attachment counts,
  timings). It leaves the session attached; when the session is attached in iTerm2 already,
  it brings that tab forward instead (state `focused`, exit 0) and opens nothing. Its check
  asks every tmux connection which session it shows (a read-only `display-message`), so during
  unattended runs use it only on `muxfinder-test-*` sessions and only while `iterm2
  list-connections` shows no connection of the user's.
- `swift run muxfinder-probe iterm2 attachments` — read-only: discovers this Mac, asks every
  tmux connection which host, server and session it shows (the same `display-message`), and
  prints the mapped connections (session id, connection id, owning session) and the unmapped
  ones by kind with their counts; no titles, host names or paths. The same caution as
  `attach` applies in unattended runs.
- `swift run muxfinder-probe detach --connection <id> --gateway <session id> [--launch-id
  <uuid>]` — `detach-client` on one connection, sent only while iTerm2 lists it as owned by
  that launch tab (both ids from `attach`'s JSON), after a 10 s wait (the process cannot know
  when the tab opened); waits for it to close (and for the helper's result with
  `--launch-id`).

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

### Phase 4a — launch helper (2026-10-21)

Environment: Neptuno, tmux 3.8, debug build (`.build/debug/muxfinder-launch`). Everything ran
in a pseudo-terminal from `script -q /dev/null …` (not iTerm2), with a private launch
directory (`MUXFINDER_LAUNCH_DIRECTORY`) and a private `TMUX_TMPDIR` server under `/tmp` that
held one `muxfinder-test-*` session running `sleep 60`. iTerm2 was not involved at any point.

| Check | Command | Observed result |
|---|---|---|
| Wait for Return on a terminal | `(sleep 2; printf '\n') \| script -q /dev/null muxfinder-launch attach <fresh uuid>` (no request) | exit 70; printed the "launch request … was not found" explanation and `Press Return to close.`, then returned 2 s later, when the newline arrived |
| Real control-mode attach | request file for `$0` written 0600 by hand (identity from `display-message`), then `(sleep 2; list-clients; printf 'detach-client\n'; sleep 2) \| script -q /dev/null muxfinder-launch attach <uuid>` | exit 0; the check child passed, then tmux was spawned directly; while attached, `list-clients` showed one control-mode client on `$0`; control-mode `%`-prefixed protocol lines on the terminal; result `{"childTermination":{"kind":"exited","status":0},"exitStatus":0,…}` with no failure; no client left afterwards |
| Hung tmux server | the same request flow on a fresh private server stopped with `kill -STOP <server pid>` before the helper ran, helper stdin `/dev/null` | exit 75 after 10 s; result `{"childTermination":{"kind":"signaled","signal":15},"exitStatus":75,"failure":{"kind":"checkTimedOut"},…}`; the "did not answer … in time" explanation on the terminal; no `tmux -u display-message` process left; then `kill -CONT`, and cleanup as below |
| Cleanup | `kill-session -t '$0'` on the private server, then `list-sessions` | `no server running on /private/tmp/mfx.…/tmux-501/default`; socket and launch directories removed |

Method notes:

- The terminal's output (control-mode protocol from a `sleep 60` session) was only counted for
  its `%` markers, not recorded.
- After `swift test`, no `/tmp/mfx-*` directory created by the tests was left, and
  `/opt/homebrew/bin/tmux -u list-sessions` reported no server on the user's default socket.

### Phase 4b — attach in iTerm2 (2026-10-21/22)

Environment: Neptuno, iTerm2 3.7.6 (API protocol 1.21, default tmux preferences), tmux 3.8,
debug build, from a shell inside iTerm2 with `TMUX_TMPDIR` unset. Only `muxfinder-test-*`
sessions existed on the default server. Observed behavior and timings:
`docs/INTEGRATION-PROOF.md`.

| Check | Command | Observed result |
|---|---|---|
| Single attach and detach (6 cycles) | `attach --local --session '$0'` then `detach --connection tmux --launch-id <id>` on one `muxfinder-test-*` session (2 windows, 3 `sleep` panes) | attach confirmed in about 1.5 s each time; detach clean (connection closed, helper exit 0) in 0.63 s; the launch tab and the tmux windows closed; iTerm2 back to the user's 3 windows and 3 tabs. The first cycles showed `Activate` refusing `select_session` with a tab target (`INVALID_OPTION`); fixed before the e2e runs |
| `e2e-local`, run 1 | `swift run muxfinder-probe e2e-local` | exit 1 after 43.2 s: steps 1–4 PASS (argv digest: 3 arguments), step 5 FAIL — the detach one second after the attach ended sessions within about 1.5 s of their start, iTerm2 opened its modal short-lived-session warning and its API stopped answering; cleanup killed the test session and removed the marker, but could not close the launch window behind the warning. The harness now keeps launch tabs 10 s old before ending them |
| `e2e-local`, later runs | — | not run: the warning was still open (checked every 2 minutes for an hour by sampling iTerm2's main thread), and only a person can dismiss it |

Method notes:

- After run 1: no tmux server was left on the default socket, the launch directory was empty
  (no request, result, digest or marker), and no other window, tab or session was touched. The
  launch window holding the warning is the only thing this phase left open.
- iTerm2's main thread was inspected with `sample` (stack frames only) to tell a modal dialog
  from a hang; no screenshot and no UI scripting was used.


### Phase 4c — real local proof (2026-10-22)

Environment: as in Phase 4b, after a person had dismissed the warning run 1 left open
(`iterm2 status` connected again). iTerm2's short-lived-session threshold was read without
writing anything: `defaults read com.googlecode.iterm2` has no `ShortLivedSessionDuration`
override and no "never warn" entry for the default profile, and the setting's default in the
iTerm2 3.7.6 binary (`+[iTermAdvancedSettingsModel advancedSettingsModelDictionary_shortLivedSessionDuration]`,
read with `lldb` on the file, not the running app) is 3 s.

| Check | Command | Observed result |
|---|---|---|
| Helper refusal in a pseudo-terminal | private `TMUX_TMPDIR` server with one `muxfinder-test-*` session, private `MUXFINDER_LAUNCH_DIRECTORY`, a request with `expectedSessionCreated` + 1; `(sleep 2; printf '\n'; sleep 12) \| script -q /dev/null muxfinder-launch attach <uuid>` | exit 65 `sessionChanged`, result written 20 ms after the start; the helper waited for Return (sent at 2 s), then held until it was 10 s old: `script` ended after 10.6 s |
| Quick end in a pseudo-terminal | the same setup with a matching request; `(sleep 1; printf 'detach-client\n'; sleep 12) \| script …` | tmux attached and exited 0 after the detach at 1.0 s; the success result was written at once (1.0 s), and the helper held until `script` ended after 10.2 s; no client left |
| `e2e-local`, run 1 | `swift build`, then `env -u TMUX_TMPDIR swift run muxfinder-probe e2e-local` | exit 0, 9 of 9 steps PASS in 42.2 s; per-step timings and notes in `docs/INTEGRATION-PROOF.md` |
| `e2e-local`, run 2 | the same command, right after run 1's checks | exit 0, 9 of 9 steps PASS in 42.7 s |
| Before and after each run | `muxfinder-probe iterm2 status`; `tmux -u ls`; `ls` of the launch directory; `iterm2 list-sessions` (summary only) | always exit 0 (connected, protocol 1.21); `no server running on /private/tmp/tmux-501/default`; launch directory empty, no `test-mode` marker; 3 windows, 3 tabs, 0 tmux tabs, as before the runs |

Method notes:

- The pseudo-terminal checks ran outside iTerm2; their terminal output went to `/dev/null`.
  Their server and launch directories were removed afterwards.
- A first pseudo-terminal attempt ended after 2.0 s and 1.0 s: `swift test --filter` had
  rebuilt `muxfinder-launch` while the hold was briefly disabled to see the new tests fail,
  and nothing had rebuilt it since. That is why the real-check procedure now starts with
  `swift build`.
- No modal dialog appeared during the runs: iTerm2's API answered every request, and
  `iterm2 status` connected after each run.

### Phase 5a — existing attachments, local (2026-10-22)

Environment: as in Phase 4c. Before the runs iTerm2 listed no tmux connection, the default
tmux server was not running, the launch directory was empty, and the user's 3 windows and 3
tabs were open.

| Check | Command | Observed result |
|---|---|---|
| `#{host}` versus `uname -n` | private `TMUX_TMPDIR` server (`-f /dev/null`) with one `muxfinder-test-*` session; `tmux -u display-message -p -t <it> "#{host}\t#{pid}\t#{start_time}\t#{socket_path}\t#{session_id}"` and `uname -n`; then the session killed | one line, five fields separated by real tabs; `#{host}` byte-identical to `uname -n` (`Neptuno-M4.local`); afterwards `no server running` on the private socket, directory removed |
| Attachments, none | `muxfinder-probe iterm2 attachments`, before and after the runs | exit 0; `discovery: noServer`, every count 0, no attachment, nothing unmapped |
| `e2e-local`, run 1 | `swift build`, then `env -u TMUX_TMPDIR swift run muxfinder-probe e2e-local` | exit 0, 10 of 10 steps PASS in 42.9 s; focus existing PASS (131 ms; nothing opened); detach by session PASS; per-step timings and notes in `docs/INTEGRATION-PROOF.md` |
| `e2e-local`, run 2 | the same commands after two notes were reworded | exit 0, 10 of 10 steps PASS in 43.3 s; focus existing PASS (107 ms) |
| Clients not in UTF-8 mode | private `TMUX_TMPDIR` servers (socket directories holding `é`, a combining acute, a zero-width space, a tab and `_`) with one `muxfinder-test-*` session each; the identity command, and the tab-separated one it replaced, fed on stdin to `tmux -C attach-session` with `-u` and without, under `LC_ALL=C`, with no locale (`env -i`) and with `LANG=en_US.UTF-8`; `list-sessions -F` without `-u`; then the sessions killed | without `-u` and a UTF-8 locale: `client_utf8` 0, tabs and `é` one `_` each, the zero-width characters dropped, `_` and `:` kept, the tab-separated line one field; with `-u` or `LANG=en_US.UTF-8`: `client_utf8` 1, exact bytes; `#{n:…}` in bytes; `-F` output replaced the same way; afterwards `no server running` on each private socket, directories removed |
| `e2e-local`, run 3 | `swift build`, then `env -u TMUX_TMPDIR swift run muxfinder-probe e2e-local`, on the final tree with the review fixes (length-prefixed identity command, bound activation, an unknown tab's age from its observation) | exit 0, 10 of 10 steps PASS in 42.2 s; focus existing PASS (88 ms; 1 mapped, 0 nonUTF8, 0 stale; nothing opened); detach by session PASS (launch tab 10.3 s old) |
| After each run | `muxfinder-probe iterm2 status`; `iterm2 list-connections`; `tmux -u ls`; `ls` of the launch directory; `iterm2 list-sessions` (summary only; runs 1 and 2) | always exit 0 (connected, protocol 1.21); 0 connections; `no server running on /private/tmp/tmux-501/default`; launch directory empty, no `test-mode` marker; 3 windows, 3 tabs, 0 tmux tabs, as before |

Method notes:

- Setup reported 0 tmux connections the run had not opened, and the run's index asks only
  connections of its own launch tabs, so no connection of the user's could get a command.
- No modal dialog appeared: iTerm2's API answered every request, and `iterm2 status` connected
  after each run.
