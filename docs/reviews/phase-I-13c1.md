Reviewer: codex adversarial review

Codex adversarial review of the working tree at /Users/ccarpio/Developer/Utils/muxFinder.
Codex verdict: needs-attention. 2 finding(s): 0 blocker(s), 2 should-fix.

Do not ship yet: asynchronous state changes can overwrite the user's update preference and clear the dot after a failed save. Review was read-only; tests were not rerun.

- [SHOULD-FIX] medium · confidence 0.98 — Sources/MuxFinderUI/Model/UpdateModel.swift:235 — Startup overwrites toggle changes made during preference loading
    The model accepts toggle changes immediately after start(), but unconditionally assigns the asynchronously loaded value here. If loading returns the old true value after the user s…
    Fix: Guard the initial load with a toggle revision and coordinate scheduler startup with pending preference saves. Add a suspended-load test that…
- [SHOULD-FIX] medium · confidence 0.97 — Sources/MuxFinderCore/Update/UpdateScheduler.swift:305 — A failed seen-version save can leave the dot cleared
    markNoticeSeen mutates the state used by status before awaiting the save. A permitted interleaving is that runCheck finishes its own persistence and publishes while this save is pe…
    Fix: Keep pending seen marks out of published state until persistence succeeds, coordinate them with check persistence, and publish rollback corr…

Scope: the working tree only — anything already committed for this phase was outside it.

VERDICT: ship-with-fixes
BLOCKERS: none
SHOULD-FIX: Sources/MuxFinderUI/Model/UpdateModel.swift:235 — Startup overwrites toggle changes made during preference loading — Guard the initial load with a toggle revision and coordinate scheduler startup with pending preference saves. Add a suspended-load test that…
SHOULD-FIX: Sources/MuxFinderCore/Update/UpdateScheduler.swift:305 — A failed seen-version save can leave the dot cleared — Keep pending seen marks out of published state until persistence succeeds, coordinate them with check persistence, and publish rollback corr…
NOT-VERIFIED: Fix both ordering defects and add deterministic regression tests using suspended preference loads and controlled state saves.
