Reviewer: codex adversarial review

Codex adversarial review of the working tree at /Users/ccarpio/Developer/Utils/muxFinder.
Codex verdict: needs-attention. 2 finding(s): 0 blocker(s), 2 should-fix.

Do not ship yet: envelope decoding can discard valid responses and turn encoded failures into success. All 24 fixtures regenerated in memory without drift, but miss these cases.

- [SHOULD-FIX] medium · confidence 1 — Sources/MuxFinderCore/ITerm2/ITerm2Envelope.swift:107 — Unknown fields overwrite valid responses
    Every unknown length-delimited field numbered >=100 replaces the decoded response. Re-serializing the existing list-sessions fixture through Python protobuf moves its unknown field…
    Fix: Recognize known unmodeled oneof members explicitly; skip truly unknown fields without replacing the response. Test unknown fields both befor…
- [SHOULD-FIX] medium · confidence 0.99 — Sources/MuxFinderCore/ITerm2/ITerm2Envelope.swift:99 — Repeated response messages can erase failure statuses
    Each occurrence constructs a fresh response instead of merging repeated occurrences of the same embedded-message field. For bytes 08019207020801920700, iTerm2's Python protobuf pre…
    Fix: Implement proto2 merging for repeated singular embedded messages, including repeated occurrences of the same oneof member, or reject duplica…

Scope: the working tree only — anything already committed for this phase was outside it.

VERDICT: ship-with-fixes
BLOCKERS: none
SHOULD-FIX: Sources/MuxFinderCore/ITerm2/ITerm2Envelope.swift:107 — Unknown fields overwrite valid responses — Recognize known unmodeled oneof members explicitly; skip truly unknown fields without replacing the response. Test unknown fields both befor…
SHOULD-FIX: Sources/MuxFinderCore/ITerm2/ITerm2Envelope.swift:99 — Repeated response messages can erase failure statuses — Implement proto2 merging for repeated singular embedded messages, including repeated occurrences of the same oneof member, or reject duplica…
NOT-VERIFIED: Fix both decoding behaviors and add the reference-backed regression cases.
NOT-VERIFIED: Run the wire and golden test suites after the fixes.
