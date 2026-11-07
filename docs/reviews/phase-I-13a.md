Reviewer: codex adversarial review

Codex adversarial review of the working tree at /Users/ccarpio/Developer/Utils/muxFinder.
Codex verdict: needs-attention. 2 finding(s): 0 blocker(s), 2 should-fix.

Do not ship yet: startup can bypass persisted throttling, and --state can silently alter directory permissions. Read-only review; no network requests or tests run.

- [SHOULD-FIX] medium · confidence 0.98 — Sources/MuxFinderCore/Update/UpdateScheduler.swift:299 — Gate automatic scheduling on completed state loading
    By inspection, if load() remains pending past the launch delay, woke() or setAutomaticChecks(true) can arm a timer while start() awaits loading. This guard admits the check using t…
    Fix: Require loaded state before arming or starting automatic checks. Add a suspended-load test that delivers wake/toggle events after five secon…
- [SHOULD-FIX] medium · confidence 0.99 — Sources/MuxFinderCore/Update/UpdateProbe.swift:260 — Reject non-private state directories before modifying their metadata
    The --state validator accepts any user-owned directory, including shared folders and folders with ACLs. UpdateStateStore.save() subsequently uses createAndSecure, which chmods that…
    Fix: Require the supplied directory to already be private and ACL-free, and refuse incompatible directories before contacting the transport. Pres…

Scope: the working tree only — anything already committed for this phase was outside it.

VERDICT: ship-with-fixes
BLOCKERS: none
SHOULD-FIX: Sources/MuxFinderCore/Update/UpdateScheduler.swift:299 — Gate automatic scheduling on completed state loading — Require loaded state before arming or starting automatic checks. Add a suspended-load test that delivers wake/toggle events after five secon…
SHOULD-FIX: Sources/MuxFinderCore/Update/UpdateProbe.swift:260 — Reject non-private state directories before modifying their metadata — Require the supplied directory to already be private and ACL-free, and refuse incompatible directories before contacting the transport. Pres…
NOT-VERIFIED: Fix both paths and add the targeted hermetic regression tests before shipping.
