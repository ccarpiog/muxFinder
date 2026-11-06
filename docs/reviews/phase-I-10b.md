Reviewer: codex adversarial review

Codex adversarial review of the working tree at /Users/ccarpio/Developer/Utils/muxFinder.
Codex verdict: needs-attention. 2 finding(s): 0 blocker(s), 2 should-fix.

Do not ship yet: stale scope results remain selectable, and quitting can lose a scope change. Read-only review; tests were not rerun.

- [SHOULD-FIX] medium · confidence 0.99 — /Users/ccarpio/Developer/Utils/muxFinder/Sources/MuxFinderUI/Model/FolderSearchS…:187 — Discard previous results when the search scope changes
    Search Whole disk for "pr", switch Settings to Home folder, then type "pro". While the new query runs, an earlier result such as /Volumes/Archive/projects remains selectable. Previ…
    Fix: Retain the scope with each previous answer and reuse rows only when it matches the newly loaded request scope. Add a disk-to-home test with…
- [SHOULD-FIX] medium · confidence 0.97 — /Users/ccarpio/Developer/Utils/muxFinder/Sources/MuxFinderUI/Model/SettingsModel…:64 — Await pending scope saves during shutdown
    The picker immediately displays the new scope, but its save runs in an untracked task. SettingsModel.shutdown() waits only for runningTasks and SSH setup; nothing awaits this write…
    Fix: Own the save task in the model and await it during shutdown, following GlobalShortcutModel's saveTask pattern. Test shutdown against a gated…

Scope: the working tree only — anything already committed for this phase was outside it.

VERDICT: ship-with-fixes
BLOCKERS: none
SHOULD-FIX: /Users/ccarpio/Developer/Utils/muxFinder/Sources/MuxFinderUI/Model/FolderSearchS…:187 — Discard previous results when the search scope changes — Retain the scope with each previous answer and reuse rows only when it matches the newly loaded request scope. Add a disk-to-home test with…
SHOULD-FIX: /Users/ccarpio/Developer/Utils/muxFinder/Sources/MuxFinderUI/Model/SettingsModel…:64 — Await pending scope saves during shutdown — Own the save task in the model and await it during shutdown, following GlobalShortcutModel's saveTask pattern. Test shutdown against a gated…
NOT-VERIFIED: Fix both state-management gaps and add the targeted regression tests before rerunning the hermetic UI suite.
