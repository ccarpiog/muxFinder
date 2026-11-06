Reviewer: codex adversarial review

Codex adversarial review of the working tree at /Users/ccarpio/Developer/Utils/muxFinder.
Codex verdict: needs-attention. 1 finding(s): 0 blocker(s), 1 should-fix.

Do not ship yet: an invalid client tty can break discovery for the entire host. Review was read-only.

- [SHOULD-FIX] medium · confidence 0.99 — Sources/MuxFinderCore/Tmux/ProbeScript.swift:127 — Frame client_tty before emitting it into the line-based report
    A client_tty containing `/dev/tty\ns003` produces a six-field first line. LineReader splits at that newline before terminalPath validation, so clientRecord throws malformed and Err…
    Fix: Use delimiter-safe framing, as the existing session-path record does, or safely encode the tty in the static format. Add a full-report regre…

Scope: the working tree only — anything already committed for this phase was outside it.

VERDICT: ship-with-fixes
BLOCKERS: none
SHOULD-FIX: Sources/MuxFinderCore/Tmux/ProbeScript.swift:127 — Frame client_tty before emitting it into the line-based report — Use delimiter-safe framing, as the existing session-path record does, or safely encode the tty in the static format. Add a full-report regre…
NOT-VERIFIED: Fix tty framing and run the parser and discovery regression suites.
