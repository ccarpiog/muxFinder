# muxFinder

A small native macOS menu bar app that finds the tmux sessions running on your Macs and opens
them in iTerm2 through iTerm2's native tmux integration (`tmux -CC`), so you keep iTerm2's own
windows, tabs, split panes, scrolling, selection and keys.

Click the menu bar icon, see your computers and their tmux sessions, click one: iTerm2 opens
(or comes forward) with that session attached. The session and its processes stay on the
computer where they run; muxFinder only finds them and opens them. Every Mac can be a work
host; there is no central server, no daemon on the remote Macs, no cloud account.

It also creates new persistent sessions ("New session") and can install iTerm2 "Persistent
work" profiles that start every new tab inside a tmux session, for when you forget to start
tmux.

## Requirements

- **macOS 14 or later on Apple Silicon** (the app is built for arm64 only). Developed and
  tested on macOS 27.2.
- **iTerm2**, tested with **3.7.6** (API protocol 1.21) only. Its Python API must be on:
  iTerm2 › Settings › General › Magic › "Enable Python API". muxFinder talks to that API
  directly (it does not need iTerm2's Python runtime or any script).
- **tmux on every host**, tested with tmux 3.8 from Homebrew (`/opt/homebrew/bin/tmux`).
  Without a per-host override muxFinder looks for `/opt/homebrew/bin/tmux`,
  `/usr/local/bin/tmux`, `/opt/local/bin/tmux`, `/usr/bin/tmux`, then `command -v tmux`. It
  does not rely on `PATH`: a noninteractive ssh command typically gets only
  `/usr/bin:/bin:/usr/sbin:/sbin`, so a tmux that your interactive shell finds may not be
  found over ssh. Set the host's tmux path in Settings if yours lives elsewhere.
- **SSH for remote hosts:** the system OpenSSH (`/usr/bin/ssh`) with your own
  `~/.ssh/config`, keys and agent, unchanged. Background discovery is noninteractive
  (`BatchMode`), so it needs key authentication (a key your agent holds) and a known host
  key; a host that would ask for a password or a passphrase shows "Sign-in needed". "Set up
  SSH in iTerm2…" opens a tab for the interactive part, such as accepting a new host key.
  Host names are whatever ssh resolves: an alias from your ssh config, a DNS name, or a
  Tailscale MagicDNS name such as `saturno-m4`. The remote login shell must be a POSIX shell
  (zsh or bash, the macOS default).
- **To build:** a Swift 6 toolchain (developed with Xcode 27.1, Swift 6.4). No third-party
  packages.

## Build from source

```
swift build                 # debug build
swift test                  # unit tests (hermetic: no ssh, no iTerm2, never your tmux server)
scripts/build-app.sh        # release arm64 app bundle: build/muxFinder.app
codesign --verify --deep --strict build/muxFinder.app
```

`scripts/build-app.sh` signs the bundle with hardened runtime using the first "Apple
Development" certificate in your keychain (or the identity named in `MUXFINDER_SIGN_IDENTITY`).
Without one it signs ad hoc and warns: then macOS forgets the Automation permission (below)
on every rebuild. **The app is never notarized.** The builds tested so far were signed with an
Apple Development certificate.

## Install on each Mac

Install muxFinder on every Mac you want to open sessions from. Either build it on that Mac:

```
scripts/build-app.sh
scripts/install.sh --dry-run    # shows what it would do
scripts/install.sh              # into /Applications; --user for ~/Applications
```

or copy a built `muxFinder.app` to the other Mac's `/Applications` (for example with `ditto`,
`rsync -a` or `scp -r` over ssh) and check it there with `codesign --verify --deep --strict
/Applications/muxFinder.app`.

`scripts/install.sh` checks the built app's bundle id and signature, copies it with `ditto`
next to the destination, verifies the copy, and only then swaps it into place, so a failed
copy never leaves half an app. If a copy at the destination is running, it asks that copy's
`muxFinder` to quit (SIGTERM) and waits up to 20 s; if it does not quit, nothing is changed.
It never starts the app. Prefer `/Applications`: muxFinder refuses to open sessions when its
own path has characters other than letters, digits and `. _ / -`, which a home folder with a
space in its name would add to `~/Applications`.

**Signing and Gatekeeper.** muxFinder is not notarized. A copy you built on that Mac, or copied
with a tool that does not mark files as downloaded (`ditto`, `cp`, `rsync`, `scp`), carries no
quarantine flag, so macOS opens it without Gatekeeper's notarization check; that is how it
was run during development. A copy that arrives through a browser, AirDrop, Mail or Messages
is quarantined, and macOS will refuse to open it until you allow it in System Settings ›
Privacy & Security ("Open Anyway"). That last path is how Gatekeeper treats apps that are not
notarized; it was not tried with muxFinder. An "Apple Development" signature does not change
it.

## Permissions

- **iTerm2's Python API** (an iTerm2 setting, see *Requirements*). When it is off, the popover
  says so and explains where to turn it on.
- **Automation (control iTerm2).** To use iTerm2's API, muxFinder asks iTerm2 for an access
  cookie with one fixed AppleScript command. The first time, macOS asks whether "muxFinder"
  may control "iTerm2"; allow it. If you refused, turn it on in System Settings › Privacy &
  Security › Automation › muxFinder › iTerm2 (the app's error offers "Open Automation
  settings"). muxFinder contacts iTerm2 only while iTerm2 is running and the popover or
  Settings window is open, or when you act on a session or choose "Set up SSH in iTerm2…";
  never at launch, and discovery never starts iTerm2.
- **Launch at login** is off until you turn on "Open muxFinder when you log in" in Settings ›
  General. It uses macOS's login item service for the installed app, so turn it on from the
  copy in `/Applications`; macOS may ask you to approve it under System Settings › General ›
  Login Items.
- Nothing else: no Accessibility, no Screen Recording, no Full Disk Access, no keychain items.

Started from Finder, the app has its own identity, so the Automation prompt appears the first
time it contacts iTerm2 (started from a terminal inside iTerm2, it inherits iTerm2's
permission and no prompt appears). See `docs/MANUAL-CHECKLIST.md` for what to expect.

## First run and host setup

With no saved host list, the first launch opens a short onboarding window. It explains that
the original host must stay powered on and reachable, that a disconnected client does not end
a tmux session, that a host reboot ends its running processes, and that muxFinder does not
sync files or move work between computers. It offers Saturno, Neptuno and Sirio as examples
(SSH, turned off, nothing assumed about their names or users): pick which one is **This Mac**
(discovered and opened locally, without ssh to localhost), fill in the SSH destinations of the
others and save.

Later, Settings › Hosts adds, edits, turns off and removes hosts. Each host has a display
name, a mode (This Mac or SSH), an SSH destination (any alias or `user@host` ssh accepts), an
optional tmux path, an optional iTerm2 profile for the tabs muxFinder opens, and the
persistent profile fields (below). "Test connection" runs one discovery. The host list lives in
`~/Library/Application Support/muxFinder/hosts.json`; no keys or passwords are stored.

## Usage

- **The popover** lists each turned-on host with its status ("This Mac", "Reachable", "No
  sessions", "Unreachable", "Sign-in needed", "Host key problem", "tmux not found") and "Last
  checked …", and its sessions with windows and clients ("4 windows · 1 client", "2 windows ·
  Detached"). A session open in iTerm2 on this Mac is marked as such; a client count alone
  only says it is attached somewhere. When a host stops answering, its last known sessions
  stay listed as "Last seen … · not live", never as live. It refreshes when it opens, every
  15 s while open and every 5 minutes in the background (with a growing pause for a host that
  keeps failing), at most three hosts at a time, so an unreachable host does not hold up the
  others.
- **Keys:** ↑/↓ select, Return opens, ⌘F search (host or session name), ⌘R refresh, ⌘N new
  session, ⌘, Settings, Esc closes.
- **Open a session:** click it (or Return). muxFinder checks the session is still the one
  listed, opens a dedicated iTerm2 tab that runs its helper, which attaches with `tmux -CC`
  (locally, or through `ssh -t` to the host), confirms the new tmux connection through iTerm2's
  API, then brings its window forward. The row shows "Opening…", "Waiting for iTerm2…" and
  "Confirmed — open in iTerm2 on this Mac"; a failure says why and offers a retry. If the
  session is already open in iTerm2 here, it brings that tab forward instead of opening a
  second one; repeated clicks while a launch is pending start only one. A session that
  disappeared since the last refresh is reported, never recreated.
- **Move here…** (context menu) attaches here and detaches the session's other clients (on
  other Macs); the confirmation says so. A normal open keeps other clients attached.
- **Detach from this Mac** (context menu) detaches iTerm2's tmux client with tmux's own
  `detach-client`; the session and its processes keep running. muxFinder never closes tmux
  tabs to detach (closing a tmux window in iTerm2 can kill it).
- **New session:** pick the host, a name and optionally a working directory there. muxFinder
  creates the session (refusing a name that exists, never replacing work) and opens it.
- **Set up SSH in iTerm2…** (on a host that needs a sign-in or has a host key problem) opens an
  iTerm2 tab running plain `ssh <destination>`, where you sign in or accept the host key the
  normal way. muxFinder never weakens host key checking.
- **Quit** (in the popover) leaves every tmux session and every iTerm2 tab running.

## Persistent profiles

Optional. In a host's settings turn on "Persistent profile" (and optionally set its session
name, `main` by default, and a parent profile for colors and fonts), then use Settings ›
Persistent profiles › "Install profiles". muxFinder writes one file,
`~/Library/Application Support/iTerm2/DynamicProfiles/muxFinder.json`, with one iTerm2
profile per such host, named "Persistent work – <host>". A tab opened with it runs muxFinder's
helper, which attaches that host's session with `tmux -CC new-session -A -s <name>` (creating
it when missing), locally or over ssh. To start every new iTerm2 window that way, make the
profile your default: iTerm2 › Settings › Profiles, select it, Other Actions › Set as Default.

- It never changes your other profiles, iTerm2's preferences or shell startup files; the
  file is muxFinder's only file in iTerm2's folder, and muxFinder replaces or removes it only
  while it holds muxFinder's own generated profiles.
- No nesting: where tmux or muxFinder already runs (`TMUX` or `MUXFINDER_LAUNCHED` set), the
  profile's helper says so and starts your login shell instead of another tmux client. If
  anything fails, it explains and starts your login shell too.
- Shells started from other profiles or apps, and terminals that are already open, are not
  moved into tmux.
- Moving the app is handled: at its next launch muxFinder updates an installed file to the
  new helper path. "Remove profiles" removes the file.

## Scope and limitations

- **Default tmux server only:** muxFinder sees each user's default tmux server on each host,
  not servers started with `-L` or `-S` (named sockets are a possible later addition).
- **Tested hosts:** Neptuno (the development Mac) and Saturno over Tailscale. Sirio was
  offline during development, so nothing Sirio-specific was tried. iTerm2 3.7.6 is the only
  iTerm2 tested.
- **Open in iTerm2 here** is known only for tmux connections in this Mac's iTerm2, matched by
  asking each connection which server and session it shows; a client count cannot say which
  other computer is attached, so muxFinder does not guess.
- **Not in this version:** deleting sessions, cloud sync, terminal previews, AI features,
  moving running processes between computers, bringing sessions back after a reboot,
  workspace management, a notarized download, Intel builds.
- **Known rough edges** (details in `docs/TESTING.md` and `PROGRESS.md`): a few checks need a
  person and are listed in `docs/MANUAL-CHECKLIST.md` (the real popover by hand, launch at
  login, "Show tab", the first Finder launch, Sirio, persistent profiles from Settings);
  quitting can take up to 15 s while an open is in flight; iTerm2 3.7.6 shows a modal warning
  for tabs that end within 3 s of opening, so muxFinder's tabs never end sooner than 10 s.

What was tested for real and what is only expected to work: `docs/TESTING.md`, "Tested vs
expected to work".

## Removal

```
scripts/uninstall.sh --dry-run   # shows what it would remove
scripts/uninstall.sh
```

It quits the app (SIGTERM to each installed copy's `muxFinder`, up to 20 s, never forced),
then removes `DynamicProfiles/muxFinder.json` only when it is muxFinder's generated file (the
app's own code decides), `~/Library/Application Support/muxFinder` (host list, launch folder),
`muxFinder.app` from `/Applications` and `~/Applications`, and the app's preferences
(`cc.carpio.muxfinder`, where macOS keeps the menu bar item's state). Helpers still running in
iTerm2 tabs are left alone and end with their tabs. It does not touch your tmux sessions,
iTerm2's preferences or other profiles, `~/.ssh` or shell files. Two things are left to you,
and the script prints them:

- **Launch at login:** turn off "Open muxFinder when you log in" in muxFinder's Settings ›
  General before uninstalling, or remove muxFinder afterwards in System Settings › General ›
  Login Items.
- **Automation permission:** `tccutil reset AppleEvents cc.carpio.muxfinder`.

By hand instead: quit muxFinder, use Settings › Persistent profiles › "Remove profiles", then
delete the app and `~/Library/Application Support/muxFinder`.

## More

- `docs/ARCHITECTURE.md`: how it is built, in one page.
- `docs/TESTING.md`: unit tests, real checks and the tested vs expected-to-work matrix.
- `docs/MANUAL-CHECKLIST.md`: the checks owed to a person.
- `docs/INTEGRATION-PROOF.md`: what the attach path does against the real iTerm2.
- `PLAN.md`: the plan and every design decision (D1–D27).

License: MIT (`LICENSE`).
