Reviewer: codex adversarial review

Codex adversarial review of the working tree at /Users/ccarpio/Developer/Utils/muxFinder.
Codex verdict: needs-attention. 2 finding(s): 0 blocker(s), 2 should-fix.

Hold: announcements leak into the switcher, and the prepared-release fallback exposes a nonfunctional What's new button. The Download gating deviation is sound. Review was read-only; tests were not rerun.

- [SHOULD-FIX] medium · confidence 1 — Sources/MuxFinderUI/Model/UpdateModel.swift:444 — Deliver update announcements only when the notice is visible
    Start an update, then open the switcher before preparation finishes. This observer announces the failure or ask without checking isPopoverVisible. AppEnvironment posts that announc…
    Fix: Gate delivery on notice visibility, retain pending announcements while hidden, and reconsider delivery when the popover's main layout appear…
- [SHOULD-FIX] medium · confidence 0.99 — Sources/MuxFinderUI/Model/UpdateModel.swift:275 — Use the displayed release for What's new
    When an update is deferred and a later successful check stops offering a newer release, notice becomes nil while preparedRelease remains populated. This fallback correctly keeps th…
    Fix: Share the displayed-release resolution between noticeContent and openWhatsNew(), using the injected opener. Add a regression test that clear…

Scope: the working tree only — anything already committed for this phase was outside it.

VERDICT: ship-with-fixes
BLOCKERS: none
SHOULD-FIX: Sources/MuxFinderUI/Model/UpdateModel.swift:444 — Deliver update announcements only when the notice is visible — Gate delivery on notice visibility, retain pending announcements while hidden, and reconsider delivery when the popover's main layout appear…
SHOULD-FIX: Sources/MuxFinderUI/Model/UpdateModel.swift:275 — Use the displayed release for What's new — Share the displayed-release resolution between noticeContent and openWhatsNew(), using the injected opener. Add a regression test that clear…
NOT-VERIFIED: Fix both paths and add regression tests for hidden completion and a cleared offer during deferral.
