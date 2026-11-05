# Release 0.2.0 (build 2): notarize, publish to NonameDownloads, install in /Applications

Proposed phase, to run **last**: after every other phase queued, including any queued after
this item. Suggested risk: **high**. It uploads to Apple's notary service and to the user's
private download site, and replaces the app in `/Applications` on this Mac. Nothing in it can
be undone by a revert.

## User request (2026-11-05, verbatim)

> Add another step to autoclaude: build, notarize, upload to NonameDownloads and copy to
> /Applications in this computer

**This is the user's explicit authorization for this run** to do three things that are
otherwise only done when the user asks:

- Run `scripts/release.sh` for real (CLAUDE.md: "only when the user asks for a release").
- Publish to NonameDownloads (CLAUDE.md: "only when the user asks").
- Run `scripts/install.sh` for real into `/Applications` (CLAUDE.md: install and uninstall are
  "for the user: never run them for real in a check"). This phase is not a check. It is the
  install the user asked for. `uninstall.sh` stays off limits.

## User decisions (2026-11-05, asked while queuing)

- **Version 0.2.0, build 2.** 0.1.0 (build 1) is already published (2026-11-04 19:45,
  Developer ID), and `nd` refuses a version and build it already has.
- **Versioning rule from now on:** each release adds 1 to the build number. The minor version
  goes up (patch back to 0) when user-facing features were added since the last published
  release, and the patch number goes up when only fixes were. Record it as a decision, with
  the next free D number (D34 may be taken by `90-new-session-own-window.md`), and on
  CLAUDE.md's release line, so later release runs pick the number themselves. The published
  version comes from `nd list muxfinder`.

## Findings (2026-11-05)

- The version is hard-coded in `scripts/build-app.sh`'s Info.plist template
  (`CFBundleShortVersionString` `0.1.0`, `CFBundleVersion` `1`, lines 97-100).
- `scripts/release.sh` checks the notarytool keychain profile `AC_NOTARY_PROFILE` and runs
  `build-app.sh --release` (Developer ID, hardened runtime, secure timestamp). It notarizes,
  waiting up to 30 min, then staples, requires `spctl` "source=Notarized Developer ID", and
  writes `build/muxFinder.zip` *after* stapling. It last ran successfully on 2026-11-04 19:45.
- The publishing runbook is `~/Developer/Utils/NonameDownloads/docs/NONAMEDOWNLOADS.md`
  (master copy, outside this repo; read it in full before publishing). The tool is
  `~/Developer/Utils/NonameDownloads/bin/nd`. The app is declared in `nonamedownloads.json`
  (slug `muxfinder`, bundle ID `cc.carpio.muxfinder`). That file was still untracked when this
  item was written; it must exist when `nd` runs, so never delete it.
- `scripts/install.sh` (PLAN.md D27) copies `build/muxFinder.app` into `/Applications` with
  `ditto` and a rename. It stops a running copy there with SIGTERM and never starts the app.

## Steps (stop at the first failure and report it; never work around a refused check)

1. **Preconditions.** Every other queued phase is closed with its review applied, and the
   shared verification passes on the current head: `swift build`, `swift test`,
   `swift format lint -r Sources Tests`. If any phase ended blocked or failed, do not
   release. End the run reporting why.
2. **Version.** Set 0.2.0 and build 2 in `scripts/build-app.sh`, record the versioning rule
   (above), and commit.
3. **Build and notarize.** Run `scripts/release.sh`. Its exit status must be 0, and
   `spctl -a -vv build/muxFinder.app` must say "source=Notarized Developer ID". If a keychain,
   permission or other system dialog blocks a step, stop and report it. Never script the UI.
4. **Publish**, following the runbook:
   - `nd doctor`: every line must say ok.
   - `nd list muxfinder`: if 0.2.0 (2) is already there, stop. Never use `--replace` or
     `nd remove`.
   - Write the release notes: English, plain text, at most about 6 short lines, for the
     user, covering what changed since 0.1.0 (1). That is the phases closed after
     2026-11-04 19:45. Save them in `build/` (ignored by git), never in a tracked file.
   - `nd publish build/muxFinder.zip --notes-file <notes> --dry-run`, then the same without
     `--dry-run`. Hand `nd` the zip `release.sh` wrote after stapling (CLAUDE.md).
5. **Install on this Mac.** `scripts/install.sh --dry-run`, then `scripts/install.sh` (the
   system `/Applications`, not `--user`). Then check:
   - `codesign --verify --deep --strict /Applications/muxFinder.app` passes.
   - `spctl -a -vv /Applications/muxFinder.app` says "source=Notarized Developer ID".
   - The installed Info.plist says 0.2.0 (2).
   **Do not start the app**: no `open`, no LaunchServices, no running the bundle binary in
   normal mode. The unattended-run rules forbid it (it can raise the Automation prompt with
   nobody there). Starting it is the user's job.
6. **Report and commit.**
   - `docs/TESTING.md` gets a dated record: release.sh's verdict, notarization status,
     `nd`'s published lines, install checks.
   - `docs/MANUAL-CHECKLIST.md` gets an item: open muxFinder from `/Applications`, check
     About or the Info.plist for 0.2.0 (2), and answer the Automation prompt if macOS asks
     again.
   - **The repository is public**: the download site's address, the runbook's contents and
     the account it uploads with never go into a tracked file, a commit message or `PROGRESS.md`.
     Say "NonameDownloads" only. Never commit anything under `build/`.
   - The run's ending tells the user: the version published, that the installed app was
     stopped and is not running, and that they should open it from `/Applications`.

## Acceptance

- `scripts/release.sh` exit 0, with notarization "Accepted", stapled, and Gatekeeper's
  "source=Notarized Developer ID" on the built app and on the installed one.
- `nd publish` exit 0, and `nd list muxfinder` shows 0.2.0 (2) as the latest macOS build.
- `/Applications/muxFinder.app` is 0.2.0 (2) and passes `codesign --verify --deep --strict`.
  The app is not running (`pgrep -x muxFinder` finds nothing).
- No tracked file names the site's address. Check with `rg` over the repo before the commit.
