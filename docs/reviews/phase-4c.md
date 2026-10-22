Reviewer: codex adversarial review

Codex adversarial review of the working tree at /Users/ccarpio/Developer/Utils/muxFinder.
Codex verdict: needs-attention. 1 finding(s): 0 blocker(s), 1 should-fix.

Do not ship yet: signals can bypass the 10-second lifetime protection while the terminal remains open.

- [SHOULD-FIX] medium · confidence 0.98 — Sources/MuxFinderCore/Launch/LaunchHelper.swift:77 — Preserve the minimum lifetime across SIGINT and SIGTERM
    Restoring SIG_DFL lets SIGINT/SIGTERM terminate the helper immediately, even without a terminal hang-up. The failure prompt restores these defaults too, bypassing the subsequent ho…
    Fix: Handle SIGINT/SIGTERM as requests to finish through the remaining minimum-age wait in both waitForReturn and holdOpen. Preserve immediate te…

Scope: the working tree only — anything already committed for this phase was outside it.

VERDICT: ship-with-fixes
BLOCKERS: none
SHOULD-FIX: Sources/MuxFinderCore/Launch/LaunchHelper.swift:77 — Preserve the minimum lifetime across SIGINT and SIGTERM — Handle SIGINT/SIGTERM as requests to finish through the remaining minimum-age wait in both waitForReturn and holdOpen. Preserve immediate te…
NOT-VERIFIED: Fix signal handling and verify the lifetime bound with isolated PTY tests before repeating real integration checks.
