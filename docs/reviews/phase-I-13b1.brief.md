# Review brief — Phase I-13b1 (update install pipeline: download and verification)

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS 14 arm64 menu
  bar app). Review the **uncommitted** working tree against `HEAD`.
- **Phase and goal:** I-13b1 — from a GitHub release offer (I-13a's parsed release with its
  asset facts) to a verified `muxFinder.app` in a private staging folder: download through an
  injected transport and its `URLSession` implementation (redirect allowlist, exact declared
  size, streaming SHA-256, progress, cancel), extraction with `/usr/bin/ditto -x -k` (argv),
  the bundle's shape (one real top-level `muxFinder.app`, no symlink leading out), the
  Security.framework code check against a requirement (identifier `cc.carpio.muxfinder`, Apple
  anchor, Developer ID markers, Team ID, `notarized`), versions (short = tag, build greater),
  typed per-step results, and probe `muxfinder-probe update verify` (zip mode run for real on
  a local copy of the 0.2.0 release zip; latest mode built, never run). No UI, swap, relaunch
  or eligibility (I-13b2, I-13c).
- **Specification (binding):** `PLAN.md` *Phase I-13*, "The orchestrator's calls for I-13b1"
  (search that string), and D39 (search `- **D39 —`), its new "download and verification
  (I-13b1)" part; feature spec `autoclaude/processed/120-update-check-github.md`; conventions
  and safety rules `CLAUDE.md`.
- **Changed files:** new `Sources/MuxFinderCore/Update/{UpdateStaging,UpdateDownload,
  UpdateExtraction,UpdateCodeCheck,UpdateBundleVersions,UpdateVerification,
  UpdateVerifyProbe}.swift`; modified `UpdateVersion.swift`, `UpdateProbe.swift`,
  `Sources/muxfinder-probe/UpdateCommand.swift`; new tests
  `Tests/MuxFinderCoreTests/{UpdateVerifyTestSupport,UpdateDownloadTests,
  UpdateExtractionTests,UpdateCodeCheckTests,UpdateBundleVersionsTests,UpdateVerifierTests,
  UpdateVerifyProbeTests}.swift`, modified `UpdateTestSupport.swift`; docs `PLAN.md`,
  `CLAUDE.md`, `docs/TESTING.md`, `docs/MANUAL-CHECKLIST.md`. (`PROGRESS.json` is a workflow
  record.)
- **Verification run (orchestrator):** `swift build` exit 0; `swift format lint -r Sources
  Tests` exit 0; `swift test` with `TMUX_TMPDIR` unset: 1309 core tests / 143 suites + 548 UI
  tests / 55 suites passed. Worker's real runs: zip mode on a copy of `build/muxFinder.zip` →
  all checks pass, exit 0; one-byte tampered copy → digest failure, exit 1; another
  well-formed Team ID → `otherTeam`, exit 1. Notarization proof: `notarized` passed the
  stapled bundle and failed an ad hoc copy, so it is in the requirement (no `spctl`).
- **Risks to probe hardest:**
  1. Security of the verification chain: can a bundle that is not a genuine Developer ID,
     notarized, same-team `cc.carpio.muxfinder` build come out as "verified"? Requirement
     string injection (Team ID is the only runtime value), flags used, which path is
     checked vs. which path is later returned (TOCTOU between check and returned path inside
     the staging folder), versions read from the checked bundle.
  2. The shape walk: symlinks leading out (absolute, `..`, link chains), entry types, bounds,
     the top-level count after `ditto` (AppleDouble handling), races with the walk.
  3. The download: redirect allowlist really enforced on every hop (including the first URL
     being exactly the asset URL), exact size and `Content-Length` handling, the digest
     computed over exactly the bytes written, cancel/failure deleting partial files, no
     writes outside the staging folder, files created exclusively, no link followed.
  4. Hermeticity: no test can send a real request (the stub must be the sole protocol class
     on every session the tests create); no test signs with a keychain identity or contacts
     Apple; temp folders cleaned up.
  5. Probe argument validation (`--into` privacy and location rules, `--team-id`, `--sha256`,
     `--expect-version`), output free of paths in the home folder and the Team ID; the latest
     mode's wiring correct even though never run.
  6. Conventions: `///` doc comments on every declaration; closing-brace comments on
     functions/loops over 10 lines; no shell source built from runtime values; docs accurate
     to the code (`CLAUDE.md`, D39, TESTING counts).
- **Review file:** `docs/reviews/phase-I-13b1.md`.
- **Time budget:** 20 minutes.
- **Do not:** run the probe's latest mode, send any network request, run `scripts/release.sh`,
  `install.sh` or `uninstall.sh`, sign with a keychain identity, or touch `/Applications`,
  `build/muxFinder.app` or the real `~/Library/Application Support/muxFinder/`.
