Reviewer: codex adversarial review

Codex adversarial review of the working tree at /Users/ccarpio/Developer/Utils/muxFinder.
Codex verdict: needs-attention. 2 finding(s): 0 blocker(s), 2 should-fix.

Do not ship yet: SSH setup loses pending-task ownership on window close and can show results for an obsolete destination.

- [SHOULD-FIX] medium · confidence 0.99 — /Users/ccarpio/Developer/Utils/muxFinder/Sources/MuxFinderUI/Model/SSHSetupActio…:117 — Retain cancelled requests until they finish
    Closing Settings or onboarding calls cancelAll(), which immediately deletes every task handle. Cancellation does not finish these tasks: LaunchTab.open deliberately awaits an indep…
    Fix: Keep a separate registry of unfinished tasks until completion, regardless of UI generation. Await that registry during shutdown and preserve…
- [SHOULD-FIX] medium · confidence 1 — /Users/ccarpio/Developer/Utils/muxFinder/Sources/MuxFinderUI/Model/SSHSetupActio…:109 — Invalidate pending results when the destination changes
    Both editors call clear(id) when the destination changes, but this guard ignores the change while opening. The task retains the original HostConfig and later publishes its result u…
    Fix: Associate results with a per-host configuration generation or destination/mode snapshot. Invalidate that generation on edits and suppress ob…

Scope: the working tree only — anything already committed for this phase was outside it.

VERDICT: ship-with-fixes
BLOCKERS: none
SHOULD-FIX: /Users/ccarpio/Developer/Utils/muxFinder/Sources/MuxFinderUI/Model/SSHSetupActio…:117 — Retain cancelled requests until they finish — Keep a separate registry of unfinished tasks until completion, regardless of UI generation. Await that registry during shutdown and preserve…
SHOULD-FIX: /Users/ccarpio/Developer/Utils/muxFinder/Sources/MuxFinderUI/Model/SSHSetupActio…:109 — Invalidate pending results when the destination changes — Associate results with a per-host configuration generation or destination/mode snapshot. Invalidate that generation on edits and suppress ob…
NOT-VERIFIED: Add gated regression tests for these lifecycle transitions and rerun the UI tests. This review inspected the diff read-only; it did not rerun tests.
