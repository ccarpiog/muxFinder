Reviewer: codex adversarial review

Codex adversarial review of the working tree at /Users/ccarpio/Developer/Utils/muxFinder.
Codex verdict: needs-attention. 2 finding(s): 2 blocker(s), 0 should-fix.

Do not ship yet: the verified result is not bound to the checked bundle, and archive expansion is bounded only after extraction. Review was read-only; tests were not rerun.

- [BLOCKER] high · confidence 0.96 — Sources/MuxFinderCore/Update/UpdateVerification.swift:283 — Bind the verified result to the bundle that passed the signature check
    After the code checker passes, checkVersions reopens the app by pathname and the result returns that pathname without comparing the app's identity. A process able to modify the sta…
    Fix: Carry the checked bundle's identity through signature verification, version reading and the returned result; reject replacement and require…
- [BLOCKER] high · confidence 0.99 — Sources/MuxFinderCore/Update/UpdateExtraction.swift:71 — Enforce expansion limits before untrusted archives consume disk
    ditto receives the archive with only a time limit; the 256 MiB and 10,000-entry limits run after extraction finishes. An in-memory ZIP constructed during review was only 522,016 by…
    Fix: Reject oversized archive manifests before invoking ditto and enforce an actual expanded-byte budget during extraction. Cover highly compress…

Scope: the working tree only — anything already committed for this phase was outside it.

VERDICT: ship-with-fixes
BLOCKERS: Sources/MuxFinderCore/Update/UpdateVerification.swift:283 — Bind the verified result to the bundle that passed the signature check — Carry the checked bundle's identity through signature verification, version reading and the returned result; reject replacement and require…
BLOCKERS: Sources/MuxFinderCore/Update/UpdateExtraction.swift:71 — Enforce expansion limits before untrusted archives consume disk — Reject oversized archive manifests before invoking ditto and enforce an actual expanded-byte budget during extraction. Cover highly compress…
SHOULD-FIX: none
NOT-VERIFIED: Close both trust-boundary gaps and add hermetic regression coverage before shipping.
