# Review brief — Phase 3a: iTerm2 wire layer

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS 14). Review the
  **uncommitted** working tree against `HEAD`.
- **Phase and goal:** Phase 3a of `PLAN.md` "### Phase 3" (see its "Split" paragraph): a
  hand-written minimal protobuf (`proto2`) codec and typed Swift messages for the iTerm2 API calls
  muxFinder needs (request/response envelopes, ListSessions, CreateTab with custom profile
  properties, Tmux ListConnections/SendCommand, Activate, ListProfiles), a dev-time fixture
  generator run with iTerm2's bundled Python and `-I`, golden fixtures and hermetic golden tests.
  No socket or live iTerm2 in this phase (that is 3b).
- **Changed files:**
  - New: `Sources/MuxFinderCore/ITerm2/` (`ProtoWire.swift`, `ProtoReader.swift`,
    `ProtoWriter.swift`, `ITerm2JSON.swift`, `ITerm2Envelope.swift`, `ITerm2ListSessions.swift`,
    `ITerm2CreateTab.swift`, `ITerm2Tmux.swift`, `ITerm2Activate.swift`,
    `ITerm2ListProfiles.swift`); `Tests/MuxFinderCoreTests/ProtoWireTests.swift`,
    `Tests/MuxFinderCoreTests/ITerm2GoldenTests.swift`, 24 fixtures in
    `Tests/MuxFinderCoreTests/Fixtures/iterm2/`; `scripts/dev/gen-iterm2-fixtures.py`.
  - Edited: `PLAN.md` (Phase 3 split; *Verified facts* field numbers and CreateTab property
    keys), `docs/TESTING.md`, `CLAUDE.md`, `PROGRESS.json` (workflow record, not a deliverable).
- **Verification already run (all exit 0):** `swift build -Xswiftc -warnings-as-errors`;
  `swift test` (130 tests in 14 suites); `swift format lint -r Sources Tests` (no output);
  regenerating the fixtures with the script under `-I` → `diff -r` shows no drift; `strings` over
  the fixtures shows only synthetic values.
- **Risks to probe:**
  1. Codec robustness on hostile input: truncated/overlong varints, lengths past end or huge,
     field number 0, wire types 3/4/6/7, deep nesting — must produce typed errors, never a trap,
     integer overflow, or unbounded loop/allocation. Check `Int`/`UInt64` conversions.
  2. Byte-for-byte encoding fidelity with protobuf `SerializeToString` (field order, negative
     int32 as 10-byte varint, optional-field presence, empty strings/submessages).
  3. Correct field numbers and types vs iTerm2's `api.proto` (oneof cases in the envelopes, tmux
     ids on tabs, ListProfiles, Activate oneof, CreateTab `custom_profile_properties`), and the
     CreateTab property keys/JSON encodings matching what the Python module sends for
     `Window.async_create(command=…)`. The JSON string escaping in `ITerm2JSON.swift` must match
     Python `json.dumps` for control characters, quotes, backslashes, non-ASCII and astral
     characters.
  4. Decoder leniency choices (invalid UTF-8 → U+FFFD; unexpected wire type for a known field is
     skipped) — acceptable or dangerous?
  5. License (PLAN.md D1): no code copied from iTerm2's GPLv2 Python module, no generated code
     from `api.proto`, no SwiftProtobuf. The generator may *call* the module at dev time.
  6. Conventions in `CLAUDE.md`: `///` doc comment on every function/type, closing-brace comments
     on functions/loops over 10 lines, no user data in fixtures.
- **Review file:** `docs/reviews/phase-3a.md`.
- **Time budget:** 15 minutes.
