Reviewer: codex adversarial review

Codex adversarial review of the working tree at /Users/ccarpio/Developer/Utils/muxFinder.
Codex verdict: needs-attention. 1 finding(s): 0 blocker(s), 1 should-fix.

Fix the documented Open behavior before shipping this documentation-only change.

- [SHOULD-FIX] medium · confidence 1 — docs/TERMINALS.md:63 — Correct Open behavior for existing local attachments
    With a local session already attached in Terminal, choosing Ghostty and clicking Open does not open Ghostty as this sentence promises. PlainTerminalBackend.perform returns appFocus…
    Fix: Explain that a plain-terminal Open brings the existing local client's app forward. Restrict the stated behavior to iTerm2, and explain that…

Scope: the working tree only — anything already committed for this phase was outside it.

VERDICT: ship-with-fixes
BLOCKERS: none
SHOULD-FIX: docs/TERMINALS.md:63 — Correct Open behavior for existing local attachments — Explain that a plain-terminal Open brings the existing local client's app forward. Restrict the stated behavior to iTerm2, and explain that…
NOT-VERIFIED: Correct this paragraph to agree with the backend, its tests, and the architecture documentation.
