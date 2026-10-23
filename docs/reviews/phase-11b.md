Reviewer: codex adversarial review

Codex adversarial review of the working tree at /Users/ccarpio/Developer/Utils/muxFinder.
Codex verdict: needs-attention. 2 finding(s): 0 blocker(s), 2 should-fix.

The preservation check can hide unrelated profile changes, and the advertised 30-second deadline is not enforced. Read-only review; no real probes or tests run.

- [SHOULD-FIX] medium · confidence 0.97 — Sources/MuxFinderCore/Profiles/ITerm2ProfileSnapshot.swift:310 — Restrict exclusions to proven muxFinder profiles
    An entry with Guid `muxfinder-persistent-custom` and filename `/other/muxFinder.json` is excluded despite having neither a generated GUID nor the owned source path. Editing that en…
    Fix: For e2e comparisons, allowlist the run's exact GUID and owned source path, validate the generated fields, and reject unexplained baseline ca…
- [SHOULD-FIX] medium · confidence 0.99 — Sources/MuxFinderCore/Profiles/PersistentProfileRun.swift:507 — Enforce the mirror deadline from removal through snapshot completion
    Step 13 starts a fresh 30-second budget after step 12 has already waited for profile removal. Each snapshot additionally permits a 20-second defaults export, and poll returns a suc…
    Fix: Use an absolute deadline derived from removedAt, cap snapshot execution and sleeps to its remaining budget, and reject results completed aft…

Scope: the working tree only — anything already committed for this phase was outside it.

VERDICT: ship-with-fixes
BLOCKERS: none
SHOULD-FIX: Sources/MuxFinderCore/Profiles/ITerm2ProfileSnapshot.swift:310 — Restrict exclusions to proven muxFinder profiles — For e2e comparisons, allowlist the run's exact GUID and owned source path, validate the generated fields, and reject unexplained baseline ca…
SHOULD-FIX: Sources/MuxFinderCore/Profiles/PersistentProfileRun.swift:507 — Enforce the mirror deadline from removal through snapshot completion — Use an absolute deadline derived from removedAt, cap snapshot execution and sleeps to its remaining budget, and reject results completed aft…
NOT-VERIFIED: Tighten exclusion ownership checks and enforce the absolute deadline.
NOT-VERIFIED: Add hermetic regression cases for both findings before accepting the verification results.
