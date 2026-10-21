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
