Reviewer: codex adversarial review

Codex adversarial review of the working tree at /Users/ccarpio/Developer/Utils/muxFinder.
Codex verdict: needs-attention. 2 finding(s): 0 blocker(s), 2 should-fix.

The saved logs support the documented results, but two harness paths can pass without proving the required behavior. Tighten these checks before treating Phase 13c as complete.

- [SHOULD-FIX] medium · confidence 0.98 — Sources/muxfinder-probe/E2EBuryRun.swift:877 — Do not count a refused bury as exercising the bury/restore race
    The hook awaits detach-client before forwarding the bury, whose ownership check then rejects the ended connection. Both saved runs passed step 7 with tmuxConnectionNotOwned: no bur…
    Fix: Keep ownership refusal as a separate case. Add a controlled overlapping detach/bury case that verifies an actual bury was sent and subsequen…
- [SHOULD-FIX] medium · confidence 0.99 — Sources/muxfinder-probe/E2EBuryRun.swift:1100 — Require the failed launch tab to remain visible until explicitly closed
    Step 11 requires only that the tab appeared once and a status report was answered. The helper's failure status and liveness are merely logged, and lastPlace is ignored after firstI…
    Fix: Require the expected SIGKILL failure result, then verify the helper remains alive and its tab remains visible beyond the minimum lifetime, i…

Scope: the working tree only — anything already committed for this phase was outside it.

VERDICT: ship-with-fixes
BLOCKERS: none
SHOULD-FIX: Sources/muxfinder-probe/E2EBuryRun.swift:877 — Do not count a refused bury as exercising the bury/restore race — Keep ownership refusal as a separate case. Add a controlled overlapping detach/bury case that verifies an actual bury was sent and subsequen…
SHOULD-FIX: Sources/muxfinder-probe/E2EBuryRun.swift:1100 — Require the failed launch tab to remain visible until explicitly closed — Require the expected SIGKILL failure result, then verify the helper remains alive and its tab remains visible beyond the minimum lifetime, i…
NOT-VERIFIED: Strengthen the two harness checks and add hermetic negative cases. No files were modified or live checks rerun.
