# Update check: tell the user about a newer GitHub release, and update in one click

Proposed phase, queued **after the plan's remaining work** (after I-12 as of 2026-11-06). There
is no `priority:` line. Suggested risk: **high**. It adds the app's first network code, and the
app replaces its own bundle and relaunches. It also adds a preference, a popover state and a
menu bar icon state. Suggested split: **a** core (check, compare, download, verify, swap,
probe, tests, decision) and **b** UI (popover notice, icon dot, Settings, update flow wiring,
relaunch, galleries, docs).

## User request (2026-11-06, verbatim)

> Could you add a new task to the autoclaude queue? I'd like the app to be able to detect when
> there is a new version released in github and tell the user about it. Maybe even auto
> updating it.

## User decisions (2026-11-06, asked while queuing)

1. **Notify, then one-click update.** muxFinder tells the user a newer version is out. An
   **Update** button downloads, verifies, replaces the app and relaunches it. Nothing is
   downloaded or installed until the user clicks.
2. **Hand-written updater.** No Sparkle and no other dependency. It uses the GitHub API and
   the release zip that is already published.
3. **Checks at launch and then once a day.** A Settings › General toggle "Check for updates
   automatically" is **on by default**, next to a "Check for updates…" button.
4. **Notice in the popover plus a dot on the menu bar icon** until the user has seen it. No
   macOS notification, so no notification permission prompt.

## Findings (2026-11-06, read-only)

- The repository `ccarpiog/muxFinder` on GitHub is public. Its releases are `v0.1.0` and
  `v0.2.0` (Latest), and each has exactly one asset, `muxFinder.zip` (`application/zip`,
  about 6 MB): the stapled zip `scripts/release.sh` writes. In the API, the asset object
  carries `digest` `"sha256:<hex>"`, and the release body repeats the SHA-256 in text.
  `GET /repos/ccarpiog/muxFinder/releases/latest` leaves out drafts and prereleases.
- **No script creates the GitHub release.** It is published by hand with `gh`. The tag holds
  only the short version (`v0.2.0`). The build number is not in it.
- The version lives in `scripts/build-app.sh`'s Info.plist template
  (`CFBundleShortVersionString` 0.2.0, `CFBundleVersion` 2). Bundle ID `cc.carpio.muxfinder`.
  Numbering rule: PLAN.md D35. `SettingsEnvironment.swift` already formats "0.2.0 (2)" from
  the main bundle.
- There is no networking code in the app yet (no `URLSession` anywhere in `Sources/`). The
  app is not sandboxed and runs with the hardened runtime.
- Signing (D28): releases are Developer ID and notarized. Everyday builds are Apple
  Development. The Automation grant follows the designated requirement, so Developer ID →
  Developer ID keeps it. Replacing a dev build with a release makes macOS ask again.
- Preferences go through `PreferencesStore` (`preferences.json`, D32 and D36), never
  `UserDefaults`.
- iTerm2 runs `muxfinder-launch` from inside the bundle: in launch tabs, which can be buried
  for a long time (D29), and through the "Persistent work" profiles, whose
  `DynamicProfiles/muxFinder.json` names the helper's path (D26). Helpers from the old
  version can still be running when the bundle is swapped.
- `scripts/install.sh` (D27) already has the careful swap pattern: `ditto`, a rename, and each
  step bound to the folder it inspected (device and inode compared, else put back).

## What to build

### Check

- One request, `GET https://api.github.com/repos/ccarpiog/muxFinder/releases/latest`, with
  `Accept: application/vnd.github+json`, `User-Agent: muxFinder/<short version>`, no token,
  no other identifying data, a timeout, and `If-None-Match` with the last `ETag` (a 304 counts
  as a successful check). The owner and repository are compiled in, never read from a file.
- A bounded parser. Accept only a tag `v<major>.<minor>.<patch>` (plain integers) that is
  strictly newer than the running `CFBundleShortVersionString`, compared numerically. Any
  other tag means nothing is offered. The installable asset is the one named exactly
  `muxFinder.zip`, with a `sha256:` digest of 64 hex characters, an `https` URL on GitHub's
  hosts, and a sane size (refuse above, say, 50 MB). With no such asset, offer the release
  page only and no Update button.
- Schedule: a few seconds after launch (never blocking startup), then whenever 24 h have
  passed since the last successful check, including after the Mac wakes. With the toggle off,
  nothing is sent except when the user presses "Check for updates…".
- Failures (offline, timeout, 403/429 rate limit, 5xx, unparseable answer) are silent in the
  background. They are retried at the next scheduled check, never in a tight loop; on a rate
  limit, wait until the reset time GitHub reports. A manual check shows the failure in its
  status line.
- The small state (last check time, ETag, latest version seen, whether the dot was seen)
  lives in a file in `~/Library/Application Support/muxFinder/`, written like the other
  stores, never in `UserDefaults`. The toggle lives in `preferences.json` through
  `PreferencesStore`. A missing or unreadable state file means "never checked".
- **No diagnostic mode contacts GitHub or writes the state file:** `--preview-fixtures`,
  every `--report-*`, `--selftest*` and `--remove-persistent-profiles`. CLAUDE.md promises
  each of them contacts nothing, and `--report-menu-bar-item` runs with an empty private home,
  where the toggle would default to on.

### Update (only after the click)

- **Offered only when it can work.** The running app must be signed with a Developer ID
  certificate (read from its own signature through Security.framework). It must not run from
  App Translocation, and its parent folder must be writable by the user. Otherwise the notice
  shows "Download" (it opens the release page) with a short reason in place of Update, as it
  does for any dev build.
- **Download** with `URLSession` into a private staging folder **on the same volume as the
  installed bundle**, so the final swap is a rename. Show progress, allow Cancel, and bound
  the size. The file's SHA-256 must equal the asset's digest, else stop and delete it.
- **Unzip** with `/usr/bin/ditto -x -k` (argv array, never a shell string) into the staging
  folder. The result must be exactly one top-level `muxFinder.app` (a real directory) with no
  symbolic link leading out of the staging folder.
- **Verify** the extracted bundle with Security.framework (`SecStaticCodeCreateWithPath` +
  `SecStaticCodeCheckValidity` with strict validation, all architectures, nested code)
  against a requirement for identifier `cc.carpio.muxfinder`, Apple's anchor, a Developer ID
  leaf, and the **same Team ID as the running app** (read from its own signature, so no
  constant to keep in sync). Notarization must be checked too: the requirement language's
  `notarized` clause if it works for a stapled bundle, else `spctl --assess --type execute`
  as an argv array; the worker proves which one does. Its `CFBundleShortVersionString` must
  equal the tag, and its `CFBundleVersion` must be greater than the running one.
- **Ask before quitting** when muxFinder holds something unsaved: a New session window with
  text in it, or unsaved Settings edits. Attached tmux sessions are not affected (they live in
  iTerm2), and the notice may say so.
- **Swap**, following D27's binding rules: rename the running bundle aside inside the staging
  folder, rename the new one into place, compare device and inode at each step, and on any
  failure put the old bundle back and report it. The installed path stays the same, so the
  D26 profile's helper path stays valid.
- **Old helpers must keep working.** The worker checks what a running `muxfinder-launch`
  still reads from its bundle after it starts, and that the new app copes with a launch
  directory written by an older helper (D14's request and result format). Delete the old
  bundle only once nothing needs it, for example at the new version's next launch. Never
  delete it under a helper that still reads from it.
- **Relaunch:** start a small detached relauncher (argv array) that waits for this process
  to exit, then opens the new bundle, and quit normally. If the new copy fails to start, the
  old one must not be gone yet. Clean up leftover staging folders at launch.

### UI (English, sentence case)

- **Popover:** a line "muxFinder 0.3.0 is available" with **Update** and **What's new** (the
  release's `html_url` in the default browser). During an update: "Downloading… 40%" with
  Cancel, "Checking the download…", "Installing…", then the relaunch. On a failure:
  "Couldn't update: <reason>" with a link to the release page. The line stays while the newer
  version is there. There is no "skip this version" (the toggle covers it).
- **Menu bar icon:** a dot drawn into the template image (still one flat colour, still
  legible at 16 px, D28). The accessibility label becomes "muxFinder, update available". The
  dot clears once the popover has shown the notice and comes back for a newer version.
- **Settings › General:** the toggle "Check for updates automatically" (on), the button
  "Check for updates…", and a status line: "You're up to date (0.2.0)", "Last checked 2 min
  ago", "muxFinder 0.3.0 is available", "Couldn't check: no connection". The version is shown
  with its build, as Settings already does.
- VoiceOver labels for the new controls. New states in the `popover` and `settings` preview
  galleries from synthetic data, and screenshots in `docs/screenshots/`.

### Release flow and docs

- A new decision (the next free D number; D37 at the time of writing) records the source, the
  tag format, the asset contract, the verification, the swap, the schedule and why there is no
  Sparkle.
- **The release contract** goes on CLAUDE.md's release line and in D35: every release is
  published on GitHub as a non-draft, non-prerelease `v<CFBundleShortVersionString>` with the
  stapled `muxFinder.zip` attached. Otherwise no installed copy sees it. Document this only.
  Do not script or run `gh release create`: publishing happens only when the user asks.
- README: what the check sends (one anonymous request to GitHub per day), how to turn it off,
  and what Update does.
- `docs/ARCHITECTURE.md` and `docs/TESTING.md`. `docs/MANUAL-CHECKLIST.md` gets the real
  update, which is the user's: it needs a published release newer than the installed one, so
  the first real run is from the release that ships this feature to the next one. Check the
  notice, the dot, Update, the relaunch, the version in Settings, and that macOS did **not**
  ask for the Automation permission again (Developer ID → Developer ID).

## Testing and safety

- `swift test` stays hermetic: an injected transport (or a `URLProtocol` stub) and synthetic
  JSON fixtures written by hand. Cover version comparison, odd tags, a missing asset or
  digest, foreign hosts, a size over the bound, 304, rate limit, a digest mismatch, zip shapes
  (two apps, a symlink out, no app), a bundle that fails the requirement (an ad hoc signed
  stub built in a temporary folder), the swap and its rollback on private folders, and the
  schedule with an injected clock.
- Probe commands, read-only on GitHub: `muxfinder-probe update check` makes one GET and prints
  JSON (latest tag, newer or not, asset present, digest present, size). `muxfinder-probe
  update verify --into <private dir from mktemp -d>` downloads the latest zip there, checks
  the digest, unzips and runs the signature and notarization checks, prints each verdict, and
  touches nothing outside that folder. A few runs per phase at most. They never install
  anything.
- The swap and relaunch run only on private folders physically under `/private/tmp` or
  `/private/var/folders`, never on `/Applications`, `~/Applications` or `build/muxFinder.app`.
  The relauncher is injected in tests (assert its argv and never run `open`): unattended runs
  never start the app through LaunchServices.
- Never create, edit or delete a GitHub release, tag or asset, and never upload anything. No
  token is read or used.

## Acceptance

- With the toggle on, a launched app makes one request a few seconds after launch and then no
  more than one per 24 h. With it off, it makes none until "Check for updates…" is pressed.
  Proven with the injected transport and clock.
- A newer `v` tag with a valid `muxFinder.zip` shows the popover notice and the icon dot. An
  equal or older tag, a malformed tag or a missing asset shows no Update button.
- `muxfinder-probe update verify` passes every check on the real published `v0.2.0` zip,
  and a tampered copy (one changed byte) fails the digest.
- The swap and rollback pass on private folders, and no diagnostic mode contacts the network
  or writes the state file.
- `swift build`, `swift test` and `swift format lint -r Sources Tests` pass, and the
  galleries show every new state in light and dark.
