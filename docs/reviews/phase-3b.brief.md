# Review brief — Phase 3b (iTerm2 transport and client)

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS 14). Conventions
  and binding safety rules: `CLAUDE.md`. Plan: `PLAN.md` "### Phase 3" (3b part of the "Split"
  paragraph and Requirements), D1 and new D13 in *Decisions*, the iTerm2 bullets in *Verified
  facts*.
- **Phase goal:** a hand-written RFC 6455 WebSocket client over iTerm2's Unix socket, the cookie
  provider (static `NSAppleScript` source), connection lifecycle and typed errors, an
  id-matching request actor, `ITerm2APIClient` behind the `ITerm2Integration` protocol, a
  `FakeITerm2Integration`, and read-only `muxfinder-probe iterm2 status | list-sessions |
  list-connections | list-profiles`. Builds on the Phase 3a codec/messages (committed, already
  reviewed — review only how 3b uses them).
- **Changed files (uncommitted tree):**
  - New: `Sources/MuxFinderCore/ITerm2/{ByteStream,WebSocketFrame,WebSocketHandshake,WebSocketClient,ITerm2Connection,ITerm2APIClient,ITerm2CookieProvider,ITerm2Error,ITerm2Integration,FakeITerm2Integration}.swift`,
    `Sources/muxfinder-probe/ITerm2Command.swift`, tests
    `Tests/MuxFinderCoreTests/{ITerm2TestSupport,WebSocketFrameTests,WebSocketHandshakeTests,WebSocketReaderTests,UnixSocketStreamTests,ITerm2ConnectionTests,ITerm2APIClientTests,ITerm2CookieAndFakeTests}.swift`.
  - Modified: `Sources/muxfinder-probe/main.swift`, `Sources/MuxFinderCore/ITerm2/ITerm2ListSessions.swift`
    (`Tab.isTmuxTab`), `Sources/MuxFinderCore/Diagnostics/DiagnosticsLog.swift` (category),
    `PLAN.md`, `CLAUDE.md`, `docs/TESTING.md`. `PROGRESS.json` is a workflow record — ignore.
- **Verification already run (orchestrator, final tree):** `swift build -Xswiftc
  -warnings-as-errors` → 0; `swift test` → 0, 211 tests in 21 suites; `swift format lint -r
  Sources Tests` → 0, no output; live `swift run muxfinder-probe iterm2 status` → 0 (connected,
  protocol 1.21) and `iterm2 list-connections` → 0 (0 connections).
- **Risks to probe hardest:**
  1. Swift 6 concurrency correctness: the dedicated reader thread + serial writer queue, the
     connection actor, continuation resumption exactly once (timeouts racing responses,
     disconnect failing all pending requests, cancellation), shutdown ordering after a server
     close.
  2. RFC 6455 framing: masking on every client frame, 7/16/64-bit lengths, continuation
     reassembly with interleaved control frames, the 16 MiB cap enforced before allocation,
     rejection of masked server frames / reserved bits / fragmented control frames, close codes.
  3. Handshake parsing: headers split across reads, frame bytes arriving with the header tail,
     `Sec-WebSocket-Accept` validation, 401 → `authRejected`, 406 and others → `protocolError`,
     bounded header size.
  4. Cookie provider: static AppleScript source only (no runtime values spliced), main-actor
     execution, strict `"<cookie> <key>"` parse, -1743 → `automationDenied`, never requested
     unless iTerm2 is running; a fresh cookie on every reconnect; no cookie/key ever logged.
  5. Safety rules: the probe subcommands must be read-only (no `createTab`, `activate`,
     `sendCommand`, `ensureRunning`); `swift test` must never touch iTerm2, its socket,
     AppleScript or NSWorkspace; no user data (titles, profile names, commands) in logs/docs.
  6. Errors map correctly: socket missing / ECONNREFUSED → `apiDisabled`; not running →
     `notRunning`; timeouts and disconnects are distinguishable.
- **Review file:** `docs/reviews/phase-3b.md`.
- **Time budget:** 15 minutes.
