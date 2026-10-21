Reviewer: codex adversarial review

Codex adversarial review of the working tree at /Users/ccarpio/Developer/Utils/muxFinder.
Codex verdict: needs-attention. 1 finding(s): 0 blocker(s), 1 should-fix.

Do not ship yet: shutdown can bypass the configured SIGTERM grace period and interrupt descendant cleanup. Review was read-only; tests were not rerun.

- [SHOULD-FIX] medium · confidence 0.99 — Sources/MuxFinderCore/Process/ProcessSupervisor.swift:120 — Honor the termination grace period after the leader exits
    If the leader exits on SIGTERM while a descendant handles SIGTERM to perform cleanup, supervision ends when the pipes close or the 500 ms drain deadline expires. This unconditional…
    Fix: Keep the leader unreaped and honor escalationDeadline before killing surviving descendants, independently of output draining. Add a regressi…

Scope: the working tree only — anything already committed for this phase was outside it.

VERDICT: ship-with-fixes
BLOCKERS: none
SHOULD-FIX: Sources/MuxFinderCore/Process/ProcessSupervisor.swift:120 — Honor the termination grace period after the leader exits — Keep the leader unreaped and honor escalationDeadline before killing surviving descendants, independently of output draining. Add a regressi…
NOT-VERIFIED: Fix early escalation and test mixed leader/descendant SIGTERM behavior for both timeout and cancellation.
