Reviewer: codex adversarial review

Codex adversarial review of the working tree at /Users/ccarpio/Developer/Utils/muxFinder.
Codex verdict: needs-attention. 2 finding(s): 2 blocker(s), 0 should-fix.

do-not-ship: Move here can detach this Mac’s existing iTerm2 connection after an identification failure or a cancelled launch race. Static review only; no files modified or real e2e commands run.

- [BLOCKER] high · confidence 0.99 — Sources/MuxFinderCore/Attach/AttachCoordinator.swift:484 — Failed identification bypasses the already-attached safety check
    Only mapped attachments trigger this refusal. AttachmentIndex converts individual command failures, timeouts and non-UTF8 responses into unmapped entries, so a successful listing f…
    Fix: For moveHere, refuse when any listed connection cannot be ruled out as the target, including stale and nonUTF8 entries. Preserve normal atta…
- [BLOCKER] high · confidence 0.98 — Sources/MuxFinderCore/Attach/AttachCoordinator.swift:351 — Cancelled moves can execute after a newer normal attach
    The cross-kind barrier ignores flights once all callers cancel, although their CreateTab request deliberately continues. A move can write its detaching request, block in CreateTab,…
    Fix: Keep conflicting launches blocked until the prior destructive launch is known to have finished or been positively revoked. Withdraw pending…

Scope: the working tree only — anything already committed for this phase was outside it.

VERDICT: ship-with-fixes
BLOCKERS: Sources/MuxFinderCore/Attach/AttachCoordinator.swift:484 — Failed identification bypasses the already-attached safety check — For moveHere, refuse when any listed connection cannot be ruled out as the target, including stale and nonUTF8 entries. Preserve normal atta…
BLOCKERS: Sources/MuxFinderCore/Attach/AttachCoordinator.swift:351 — Cancelled moves can execute after a newer normal attach — Keep conflicting launches blocked until the prior destructive launch is known to have finished or been positively revoked. Withdraw pending…
SHOULD-FIX: none
NOT-VERIFIED: Fix both safety paths and verify them with hermetic regression tests before shipping.
