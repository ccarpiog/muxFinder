# Phase 14 review brief

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (native macOS menu bar app, Swift 6,
  SwiftPM, macOS 14; conventions and binding safety rules in `CLAUDE.md`).
- **Phase:** 14 — Popover readability: host sections, attach state, muted offline hosts
  (risk: routine). Specification: `PLAN.md`, heading `### Phase 14 — Popover readability`
  (requirements and acceptance listed there). The change is uncommitted in the working tree.
- **Goal:** the popover reads at a glance — opaque background, a bounded section per host,
  a leading attach-state mark per row (here / attached elsewhere / detached / stale), a
  readable "Open in iTerm2 here" badge (>= 4.5:1 WCAG, light and dark, selected and
  unselected), a muted tone for `.unreachable` only (actionable statuses stay orange; red only
  for failed session actions), and footer spacing; behavior, keyboard navigation, search,
  panels, accessibility labels and the 360 pt width unchanged.
- **Changed files:** `Sources/MuxFinderUI/Views/PopoverStyle.swift` (new),
  `Sources/MuxFinderUI/Views/{PopoverView,PopoverParts,HostSectionView,SessionRowView}.swift`,
  `Sources/MuxFinderUI/Views/Settings/HostsSettingsView.swift`,
  `Sources/MuxFinderUI/Model/{HostStatusLabel,PopoverContent}.swift`,
  `Sources/MuxFinderUI/Preview/{PreviewFixtures,PreviewGallery,AttachGallery}.swift`,
  `Tests/MuxFinderUITests/PopoverStyleTests.swift` (new),
  `Tests/MuxFinderUITests/PopoverContentTests.swift`, `PLAN.md` (D22 *Look* bullet),
  `README.md`, `docs/MANUAL-CHECKLIST.md` (item 15), `docs/TESTING.md` (Phase 14 record),
  `docs/screenshots/{popover,attach,settings}-states-{light,dark}.png`. Ignore
  `PROGRESS.json` (workflow record).
- **Verification run (orchestrator, exit 0 each):** `swift build`; `swift test` (745 core
  tests in 74 suites, 177 UI tests in 15 suites); `swift format lint -r Sources Tests`;
  `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app`. The worker
  ran `--report-menu-bar-item` with `CFFIXED_USER_HOME` pointing at an empty `mktemp -d`
  folder (so the user's real `hosts.json` is not read and no host is refreshed).
- **Risks to check:**
  - The contrast test: does it resolve the colors actually drawn behind the badge (selected
    row fill, unselected row, section background) in both appearances, or a proxy? The worker
    chose fixed per-scheme colors because the system window background resolves differently
    inside a real window — is that sound, and does dark mode stay legible?
  - Opaque background inside `MenuBarExtra(.window)`: sizing, corner clipping, keyboard focus
    and Esc/close unchanged?
  - `.unreachable` alone muted; every other `HostStatusLabel` keeps its tone; nothing else
    started relying on `.problem` for unreachable.
  - Row-state mapping (here / attached / detached / stale) correct for every
    `PopoverContent` row kind, including stale rows of a reachable host and search results;
    row order unchanged; accessibility labels unchanged or only extended.
  - Footer: gap between buttons >= 3x icon–title gap; shortcuts and help texts unchanged.
  - Conventions: `///` doc comments everywhere, closing-brace comments on > 10-line functions
    and loops, sentence case, no Title Case in UI strings; D22 describes present state.
  - Is `CFFIXED_USER_HOME` a sound way to keep the shell check off the real host list (does
    every path the app uses honor it)?
- **Review file:** `docs/reviews/phase-14.md`.
- **Time budget:** 15 minutes.
