Reviewer: codex adversarial review

Codex adversarial review of the working tree at /Users/ccarpio/Developer/Utils/muxFinder.
Codex verdict: needs-attention. 1 finding(s): 0 blocker(s), 1 should-fix.

Do not ship yet: the restore exchange can block indefinitely despite its two-second timeout.

- [SHOULD-FIX] medium · confidence 0.99 — Sources/MuxFinderCore/Launch/TerminalStatusRequest.swift:109 — Enforce the restore deadline across blocking terminal I/O
    After SIGINT/SIGTERM ends waitForReturn(), its reader remains alive. During the final restore, that reader can consume the reply between poll() and read() here. With blocking input…
    Fix: Ensure the Return reader has stopped before starting another exchange. Use nonblocking terminal I/O and one absolute deadline covering both…

Scope: the working tree only — anything already committed for this phase was outside it.

VERDICT: ship-with-fixes
BLOCKERS: none
SHOULD-FIX: Sources/MuxFinderCore/Launch/TerminalStatusRequest.swift:109 — Enforce the restore deadline across blocking terminal I/O — Ensure the Return reader has stopped before starting another exchange. Use nonblocking terminal I/O and one absolute deadline covering both…
NOT-VERIFIED: Add PTY regression coverage for a signal-ended Return wait racing the final reply and for output backpressure; require bounded completion and restored terminal…
