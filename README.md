# muxFinder

A small native macOS menu bar app that finds the tmux sessions running on your Macs and opens
them in iTerm2 through iTerm2's native tmux integration (`tmux -CC`), so you keep iTerm2's own
windows, tabs, split panes, scrolling, selection and keys. Without iTerm2, or if you prefer,
it opens them in Terminal or Ghostty instead, with plain tmux in one window per session
(`docs/TERMINALS.md`).

Click the menu bar icon, see your computers and their tmux sessions, click one: iTerm2 (or the
terminal you chose) opens or comes forward with that session attached. The session and its
processes stay on the computer where they run; muxFinder only finds them and opens them. Every
Mac can be a work host; there is no central server, no daemon on the remote Macs, no cloud
account.

It also creates new persistent sessions ("New session") and can install iTerm2 "Persistent
work" profiles that start every new tab inside a tmux session, for when you forget to start
tmux.

## Requirements

- **macOS 14 or later on Apple Silicon** (the app is built for arm64 only). Developed and
  tested on macOS 27.2.
- **A terminal app**, chosen in Settings › General › Terminal (`docs/TERMINALS.md`):
  - **iTerm2** (the default when it is installed), tested with **3.7.6** (API protocol 1.21)
    and **3.7.7** only. Its Python API must be on: iTerm2 › Settings › General › Magic › "Enable Python
    API". muxFinder talks to that API directly (it does not need iTerm2's Python runtime or
    any script).
  - Or **Terminal** (macOS's own, the default without iTerm2) or **Ghostty 1.3 or later** (with
    its AppleScript on, as it is by default), which attach with plain tmux. Both were tested
    only with stand-ins; their real runs are owed (`docs/MANUAL-CHECKLIST.md` items 26–29).
    Other terminals can be added with a small definition file (`docs/TERMINALS.md`, "Adding a
    terminal").
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
  SSH in iTerm2…" opens a tab for the interactive part, such as accepting a new host key
  (with another terminal chosen, "Set up SSH in Terminal…" opens a window of it). Host names
  are whatever ssh resolves: an alias from your ssh config, a DNS name, or a Tailscale
  MagicDNS name such as `saturno-m4`. The remote login shell must be a POSIX shell
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
on every rebuild. These everyday builds are **not notarized**.

**Notarized builds.** `scripts/release.sh` builds the same bundle signed with your "Developer
ID Application" certificate and a secure timestamp, submits it to Apple's notary service,
staples the ticket, checks Gatekeeper's verdict, and leaves `build/muxFinder.zip` for
distribution. It needs a notarytool keychain profile named `AC_NOTARY_PROFILE` (or the name in
`MUXFINDER_NOTARY_PROFILE`), created once with `xcrun notarytool store-credentials`. macOS ties
the Automation permission (below) to the certificate, so the first Developer ID build you run
asks for it again. That zip, attached as is to a GitHub release, is what the in-app update
installs (*Updates*, below; the release contract is in `PLAN.md` D35).

The app icon and the menu bar icon are generated files in `Resources/`; their sources and the
script that regenerates them are in `scripts/dev/icon/`.

**Folder search from the command line.** `swift run muxfinder-probe folders --local --name
<text>` (or `--ssh <destination>`) runs the search New session's "Folders on <host>" uses
(below) on This Mac or a host through Spotlight: `mdfind` runs on that host, over the same
noninteractive ssh as discovery, so the host needs no muxFinder of its own. It is read-only, and by default prints only how many
folders matched and how long each search took (`--paths` prints the folders; `--name` can be
given several times, and `--repeat <n>` asks each again, all through one connection). It
finds folders whose name contains the text, ignoring case and accents, at most 50, in the
home folder (`--scope disk`: the whole disk). It leaves out `~/Library`, hidden folders and
everything in them, `node_modules`, `DerivedData`, `Pods`, `__pycache__`, the inside of apps
and other packages, and with the whole disk also other users' `Library` folders and system
folders such as `/System`, `/Library` and `/usr`. A host without Spotlight, or with indexing
off, says so; Spotlight's own privacy exclusions apply. On This Mac it never checks whether
Desktop, Documents and Downloads can be read (the header says "not checked").

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

**Signing and Gatekeeper.** A build from `scripts/build-app.sh` is not notarized. A copy you
built on that Mac, or copied with a tool that does not mark files as downloaded (`ditto`, `cp`,
`rsync`, `scp`), carries no quarantine flag, so macOS opens it without Gatekeeper's
notarization check; that is how it was run during development. A copy that arrives through a
browser, AirDrop, Mail or Messages is quarantined, and macOS will refuse to open it until you
allow it in System Settings › Privacy & Security ("Open Anyway"). That last path is how
Gatekeeper treats apps that are not notarized; it was not tried with muxFinder. An "Apple
Development" signature does not change it. A notarized build from `scripts/release.sh` opens
after macOS's usual one-time question about an app from the internet; `scripts/install.sh`
says which kind it installed.

## Permissions

- **iTerm2's Python API** (an iTerm2 setting, see *Requirements*). When it is off, the popover
  says so and explains where to turn it on.
- **Automation (control iTerm2).** To use iTerm2's API, muxFinder asks iTerm2 for an access
  cookie with one fixed AppleScript command. The first time, macOS asks whether "muxFinder"
  may control "iTerm2"; allow it. If you refused, turn it on in System Settings › Privacy &
  Security › Automation › muxFinder › iTerm2 (the app's error offers "Open Automation
  settings"). muxFinder contacts iTerm2 only while iTerm2 is running and the popover, the
  session switcher or the Settings window is open, or when you act on a session or choose
  "Set up SSH in iTerm2…";
  never at launch, and discovery never starts iTerm2. With another terminal chosen it never
  contacts iTerm2, except "Detach (opened in iTerm2)" for an attachment it opened there before
  you changed the choice.
- **Automation (control Terminal or Ghostty)**, only with that terminal chosen: muxFinder
  opens each session's window through the app's AppleScript, so the first time it does,
  macOS asks whether "muxFinder" may control "Terminal" (or "Ghostty"); allow it. Settings ›
  General shows each terminal's permission without asking ("Allowed", "Not allowed", "Not
  asked yet", "Checked when the app is running") and offers "Allow in System Settings…"; if it
  is refused, Open says "muxFinder isn't allowed to control Terminal, …" and offers "Open
  System Settings…" (Privacy & Security › Automation). A terminal added with an `exec`
  definition needs no permission.
- **Launch at login** is off until you turn on "Open muxFinder when you log in" in Settings ›
  General. It uses macOS's login item service for the installed app, so turn it on from the
  copy in `/Applications`; macOS may ask you to approve it under System Settings › General ›
  Login Items.
- Nothing else: no Accessibility, no Screen Recording, no Full Disk Access, no keychain items.
  The session switcher shortcut (below) is a standard system-wide hotkey, which needs no
  permission either.

Started from Finder, the app has its own identity, so the Automation prompt appears the first
time it contacts iTerm2, or opens a Terminal or Ghostty window (started from a terminal inside
iTerm2, it inherits iTerm2's permissions and no prompt appears). See
`docs/MANUAL-CHECKLIST.md` for what to expect.

## First run and host setup

With no saved host list, the first launch opens a short onboarding window. Its first step is
the terminal, the same picker as Settings › General: iTerm2 is preselected when it is
installed, otherwise Terminal, and you can choose any terminal listed. With iTerm2 its last
step is iTerm2's Python API; with another terminal it explains what plain tmux means and, for
Terminal and Ghostty, the Automation permission. It works on a Mac without iTerm2, and opening
it contacts no iTerm2. It explains that the original host must stay powered on and
reachable, that a disconnected client does not end a tmux session, that a host reboot ends its
running processes, and that muxFinder does not sync files or move work between computers. It
offers Saturno, Neptuno and Sirio as examples (SSH, turned off, nothing assumed about their
names or users): pick which one is **This Mac** (discovered and opened locally, without ssh to
localhost), fill in the SSH destinations of the others and save.

Later, Settings › Hosts adds, edits, turns off and removes hosts. Each host has a display
name, a mode (This Mac or SSH), an SSH destination (any alias or `user@host` ssh accepts), an
optional tmux path, an optional iTerm2 profile for the tabs muxFinder opens (used only with
iTerm2), and the persistent profile fields (below). "Test connection" runs one discovery. The
host list lives in `~/Library/Application Support/muxFinder/hosts.json`; no keys or passwords
are stored.

## Usage

- **The popover** opens directly below muxFinder's icon when you click it, on the display
  whose menu bar you clicked (on the active Space, also over a full-screen app); clicking the
  icon again, Esc, clicking elsewhere or switching apps closes it. You can ⌘-drag the icon to
  another place in the menu bar (dragging it out of the bar quits muxFinder). The popover
  lists each turned-on host with its status ("This Mac", "Reachable", "No
  sessions", "Unreachable", "Sign-in needed", "Host key problem", "tmux not found") and "Last
  checked …", and its sessions with windows and clients ("4 windows · 1 client", "2 windows ·
  Detached"). Each host gets a box of its own, and each session starts with a mark for where
  it is attached (open in iTerm2 here, attached elsewhere, detached, not live; while
  muxFinder cannot check iTerm2, a session with clients is marked attached without saying
  where). A session open in iTerm2 on this Mac is also marked "Open in iTerm2 here"; a
  client count alone only says it is attached somewhere. When a host stops answering, its last known sessions stay
  listed as "Last seen … · not live", never as live, and an unreachable host is shown muted
  rather than as an alert, since a Mac that is asleep or away is routine. It refreshes when it opens, every
  15 s while open and every 5 minutes in the background (with a growing pause for a host that
  keeps failing), at most three hosts at a time, so an unreachable host does not hold up the
  others.
- **Keys:** ↑/↓ select, Return opens, ⌘F search (host or session name), ⌘R refresh, ⌘N new
  session (its own window), ⌘, Settings, Esc closes. In the New session window, Tab and ⇧Tab
  move between Name and Directory, typing in Directory filters the directory list and
  searches the host's folders, ⌥↓ opens it, Return creates, and Esc closes the list and then the window, as ⌘W does (below); with
  macOS's keyboard navigation on, ⇧Tab from Name reaches the Host picker, where Space opens
  the host menu.
- **Open a session:** click it (or Return). muxFinder checks the session is still the one
  listed, opens a dedicated iTerm2 tab that runs its helper, which attaches with `tmux -CC`
  (locally, or through `ssh -t` to the host), confirms the new tmux connection through iTerm2's
  API, then brings its window forward. The row shows "Opening…", "Waiting for iTerm2…" and
  "Confirmed — open in iTerm2 on this Mac"; a failure says why and offers a retry. If the
  session is already open in iTerm2 here, it brings that tab forward instead of opening a
  second one; repeated clicks while a launch is pending start only one. A session that
  disappeared since the last refresh is reported, never recreated.
- **With Terminal or Ghostty chosen** (Settings › General › Terminal; `docs/TERMINALS.md`),
  Open ("Open in Terminal") opens a new window of that app running muxFinder's helper, which
  attaches with plain tmux: the session's windows and panes stay inside that one window, with
  tmux's status bar, prefix keys and copy mode. The row reads "Waiting for Terminal…", then
  "Confirmed — open in Terminal on this Mac"; a session already open in muxFinder's window is
  brought forward ("Already open here — brought its Terminal window forward"), and "Show
  window" takes the place of "Show tab". Detach from this Mac, Move here… and Detach other
  clients… work through tmux as with iTerm2; muxFinder never closes the window (after a
  detach its helper ends, and the terminal's own setting decides whether the window closes).
  A session with a client in a terminal app on this Mac reads "Open in Terminal on this Mac",
  with "Show in Terminal", whichever terminal is chosen. A session whose name has `{`, `[` or
  `]` cannot be opened in Terminal or Ghostty. If the chosen terminal is gone or too old, the
  popover and Settings say so; muxFinder never picks another one for you.
- **The launch tab is hidden while attached.** Once the session's first window shows,
  muxFinder hides the tab it opened (it buries it through iTerm2's API), so one open (or New
  session, or Move here) shows only the session's windows. While the session is attached, that
  tab is listed under iTerm2's Session › Buried Sessions. When the session is detached, the tab
  shows briefly and closes by itself (after a detach within 10 s of opening, it stays until it
  is 10 s old). If the attachment ends with a failure (the connection drops, say), the tab
  comes back with the explanation and closes when you press Return. iTerm2's own
  "Automatically bury the tmux client session after connecting" setting (Settings › General ›
  tmux) needs nothing more: muxFinder works the same with it on or off, and never changes it.
- **Move here…** (context menu) attaches here and detaches the session's other clients (on
  other Macs); the confirmation says so. A normal open keeps other clients attached.
- **Detach from this Mac** (context menu) detaches iTerm2's tmux client with tmux's own
  `detach-client`; the session and its processes keep running. muxFinder never closes tmux
  tabs to detach (closing a tmux window in iTerm2 can kill it).
- **Detach other clients…** (context menu) keeps this Mac's iTerm2 attached and has tmux
  detach the session's other clients, wherever they are (iTerm2 on your other Macs, say);
  nothing is closed and the session keeps running. It is offered only for a session open in
  iTerm2 here whose host's listing shows more clients than this Mac's attachments (the "Open
  in iTerm2 here" badge then adds "also attached elsewhere"), and it asks first. Why: while two
  iTerm2 windows (two Macs) are attached to one session, tmux keeps the session's window at
  its old size and ignores both windows' resizes, so part of your iTerm2 window stays unused;
  once the other clients are detached, resizing this Mac's window resizes the session again.
  Afterwards the row says how many were detached and the list is refreshed; the other Macs
  can attach again at any time.
- **New session:** the popover's "New session" (or ⌘N), or the session switcher's (below),
  opens a small window of its own titled "New session" where the popover or switcher was,
  and the popover or switcher closes. The window floats above other apps' windows, on every
  Space and beside full-screen apps, without making muxFinder the active app, and stays until
  the session is created, Cancel, Esc, ⌘W or its close button, so you can go to Finder to
  look for a folder and come back to it. Closing it drops what you typed (a creation already
  under way goes on and shows on its row); opening it while it shows only brings it forward,
  as you left it. Pick the host, a name and optionally a working directory there. muxFinder
  creates the session (refusing a name that exists, never replacing work), closes the window
  and opens the session; a name taken ("Open existing") or another failure stays in the
  window, and one that comes after you closed the window brings the window back with it. The
  Directory field takes any path (`~/…` is in that host's home folder; empty is the home
  folder itself). Drag a folder from Finder onto the field (or its button) to fill in its
  path: under your home folder it is written `~/…`, which a remote host with the same layout
  understands too, and elsewhere in full; while the folder hovers the field shows a ring, and
  a file, an app, several items or text are refused. The button at its end, or ⌥↓, lists that host's recent directories (the last
  8 it created sessions in), your saved directories (one list for every host) and the folders
  the host's sessions started in. Typing in Directory filters that list (case and accents
  ignored) and opens it while something matches, closing it again when nothing does; on This
  Mac, `~/proj` also finds `/Users/<you>/projects` and the other way round. Click one, or move
  with ↓ (or ↑) and press Return, to put it in the field; Esc closes the list and keeps what you
  typed (a second Esc closes the window), and Return with nothing highlighted creates in what
  the field holds (typing in the field takes the highlight away). Opened with the button or
  ⌥↓, the list stays open while you type, saying "No matching directories" when nothing
  matches. Tab and ⇧Tab
  move between Name and Directory; with macOS's keyboard navigation on (System Settings ›
  Keyboard) they also reach the Host picker, the list's button (Space opens it), Cancel and
  Create, in reading order. Tab with the list open moves on and leaves the list open. On the
  Host picker the keys are macOS's own: Space opens the host menu (↑ and ↓ go to the picker
  too, as macOS handles them), where ↑/↓ move, Return or Space picks and Esc closes only the
  menu; Return with the
  menu closed still creates, and Esc still closes the window (or the directory list first,
  which stays open while you change the host, keeping its highlight). "Save this
  directory" adds what the field holds to the saved list; "Clear recent directories on
  <host>" forgets that host's recent ones. Settings › Directories edits the saved list: add
  (checked as you type), remove, move up and down, then Save (or Revert); Save keeps any
  directory you saved from New session in the meantime. Both lists live in
  `~/Library/Application Support/muxFinder/directories.json` (paths only, never terminal
  content).
- **Folder search in New session:** as you type at least two characters of a folder's name in
  Directory (no `/`: a path is not searched), the list adds "Folders on <host>" below Recent,
  Saved and Sessions, which filter at once and never wait for it: the host's Spotlight finds
  the folders whose name contains the text (case and accents ignored), shown `~/…` under the
  host's home folder, at most 50, each listed once (a folder already in Recent, Saved or
  Sessions shows only there). Picking one fills Directory like any pick. On another Mac it
  runs over the same ssh as discovery (key authentication, nothing to install there), through
  one connection kept while you type and closed when the window closes, the host changes,
  after a quiet minute or when muxFinder quits; on This Mac it runs locally. A host without
  Spotlight, or with indexing off, says "Folder search isn't available on <host>" and why; an
  unreachable host says so in the section, never holding up the form. **Settings ›
  Directories › Search folders in:** Home folder (the default) or Whole disk; it applies to
  the next search and is kept in `preferences.json`. **The limits** ("Missing a folder?" in
  the list and in Settings explains them, with "Open muxFinder Settings" and, for This Mac,
  "Open Spotlight settings"): Spotlight matches names, not paths; folders whose names start
  with a dot and anything excluded in Spotlight's privacy settings never appear; muxFinder
  leaves out Library folders, the inside of apps and other packages, `node_modules`,
  `DerivedData`, `Pods` and `__pycache__` (and system folders with Whole disk); over SSH macOS
  may hide Desktop, Documents and Downloads unless that Mac allows full disk access for remote
  users (System Settings › General › Sharing › Remote Login › Allow full disk access for
  remote users), and when the host reports them unreadable the section says so; an apostrophe
  inside a word may find nothing. Folder names are never logged or saved.
- **Session switcher shortcut:** a keyboard shortcut that works in every app. There is none
  until you record one in Settings › General › "Show session switcher": click the shortcut
  field, then press the keys (for example ⌃⌥Space). Esc cancels, Delete (or "Clear") turns the
  shortcut off. It applies at once; there is nothing to save. It needs ⌃, ⌥ or ⌘ (F1 to F20 may
  go alone), and the combinations macOS keeps for itself (⌘Space, ⌘Tab, ⌘⇧3/4/5, ⌘⌥Esc) are
  refused. Before ⌘ with a single key it asks first, since that key's ⌘ shortcut would stop
  working in every app, and before only ⌥ or ⌥⇧ with a key, which macOS may not pass to apps.
  If another app already uses the combination, the message "Another app uses this shortcut.
  Choose another." shows beside the field. The field shows the key as your keyboard layout
  prints it. The shortcut shows and hides the session switcher (below). It lives in
  `~/Library/Application Support/muxFinder/preferences.json`; if that file cannot be used,
  muxFinder leaves it as it is and the shortcut stays off.
- **Session switcher:** press the shortcut in any app, even over a full-screen one, and a
  Spotlight-like panel opens in the upper part of the screen you are working on, with the
  search field ready. It lists the live sessions of every host in the popover's order (stale
  ones are left out), each with its state, its host and "2 windows · 1 client" or the "Open in
  iTerm2 here" badge; muted lines such as "Sirio: unreachable" or "Saturno: checking…" explain
  hosts whose sessions are missing. Type to filter by session or host name, move with ↑/↓,
  and press Return to open the selected session, or click a session once, the same way the
  popover does: a session already open here is brought forward, any other one is attached. The
  last row is always "New session…"; when what you typed is a valid session name nobody uses
  yet, it reads "New session “<name>”…" and fills the name in. A click on it, Return on it or
  ⌘N closes the switcher and opens the New session window (above) where the switcher was, for
  This Mac by default, with that name filled in (a window already open comes forward as it
  is, its name kept). ⌘R refreshes and ⌘, opens Settings; Move here, Detach and Detach other
  clients stay in the popover. The panel shows the row's progress, closes once the session is
  open (or as soon as iTerm2 comes forward), and stays open with the explanation and its
  buttons when something fails. A failure that arrives after the panel closed shows on the
  popover's row and at the top of the switcher the next time you open it. Esc, the
  shortcut, a click outside it or switching apps closes it and gives the focus back to the
  app you were in. Opening the switcher closes the popover and the other way round.
- **Set up SSH in iTerm2…** (on a host that needs a sign-in or has a host key problem) opens an
  iTerm2 tab running plain `ssh <destination>`, where you sign in or accept the host key the
  normal way. With another terminal chosen it reads "Set up SSH in Terminal…" (or Ghostty)
  and opens a new window of that app instead. muxFinder never weakens host key checking.
- **Quit** (in the popover) leaves every tmux session and every iTerm2 tab (or terminal
  window) running.

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

**With Terminal or Ghostty chosen**, muxFinder never writes that terminal's settings.
Settings › Persistent profiles then shows "Persistent work in Terminal" (or Ghostty): for each
saved host whose persistent profile is on, the command `exec '<helper path>' 'profile-plain'
'<host id>'` with a Copy button, and where to paste it: in Terminal, Settings › Profiles ›
Shell › Run command, with "Run inside shell" kept on; in Ghostty's config file, after
`command = `, then reload its config. A window that runs it attaches that host's session with
plain `tmux new-session -A -s <name>`, with the same no-nesting rule and the same fallback to
your login shell. "Install profiles" is not offered then; "Remove profiles" still is while
muxFinder's iTerm2 file is installed. The command holds the helper's path, so copy it again
after moving the app (details in `docs/TERMINALS.md`, "Persistent work").

## Updates

muxFinder tells you when a newer release is out on GitHub and, for a release build, installs
it when you click **Update**. Nothing is downloaded or installed before that click.

- **What the check sends:** one anonymous `GET` of
  `https://api.github.com/repos/ccarpiog/muxFinder/releases/latest` (GitHub leaves out drafts
  and prereleases). No account, token, identifier or analytics: besides the standard `Accept`
  headers it carries only muxFinder's version (`User-Agent: muxFinder/<version>`) and the
  `ETag` of the last answer, so an unchanged release comes back as a short "not modified"
  with no body.
- **When:** a few seconds after launch when a check is due, then about once a day (24 h after
  the last successful check, also when the Mac wakes), and whenever you click "Check for
  updates…". A failure in the background is silent and tried again later (not within the
  hour, and never before GitHub's rate limit ends). It never runs with a mode flag: the
  preview galleries, the self-tests, the `--report-*` checks and `--remove-persistent-profiles`
  send nothing and read or write no update state. What it remembers (the last check, the
  `ETag`, the latest release, the version whose notice you saw) is `update-state.json` in
  `~/Library/Application Support/muxFinder/`.
- **Turning it off:** Settings › General › Updates › "Check for updates automatically" (on
  by default, kept in `preferences.json`). Off, nothing is sent until you click "Check for
  updates…". The same section shows the result ("You're up to date (<version> (<build>))",
  "muxFinder <version> is available", "Couldn't check: no connection") and "Last checked …".
- **The notice and the dot:** when a newer release is out, the popover shows "muxFinder
  <version> is available" with **What's new** (the release page in your browser), and the menu
  bar icon gets a small dot (VoiceOver: "muxFinder, update available") until the popover has
  shown the notice once; a later release brings the dot back.
- **Update** downloads the release's `muxFinder.zip` from GitHub ("Downloading… 40%", with
  **Cancel**), checks its size and SHA-256 against the release's, unpacks it, and checks that
  it is muxFinder, signed with the same Developer ID as your copy and notarized by Apple, with
  the release's version and a newer build ("Checking the download…"). If quitting would lose
  something (text in the New session window, unsaved Settings changes) it asks first: **Quit
  and install**, or **Not now** and later **Install and relaunch**. Then muxFinder puts the
  new app in place of the old one at the same path ("Installing…"), starts a small
  relauncher and quits ("Relaunching…"); the relauncher waits for muxFinder to end (at most a
  minute) and opens the new copy. Your tmux sessions, iTerm2 tabs and terminal windows are
  not touched, and attached sessions stay attached. The old copy is kept aside in
  muxFinder's `update` folder while anything still runs from it (the helper of a session
  opened before the update) and removed at a later launch. Since the new copy carries the
  same Developer ID, macOS should not ask for the Automation permission again.
- **When the update fails** before muxFinder quits, the notice says "Couldn't update:
  <reason>" with a **Release page** link, and muxFinder keeps running. A failure during or
  after the swap (the relauncher could not start, say) is followed by an attempt to put the
  old copy back. If that attempt fails, the reason ends with "and the change couldn't be
  undone": the new version is in place but the old one is still running, so quit muxFinder
  and open it again. If something else changed the app meanwhile, the reason is "something
  else changed muxFinder during the update": nothing more is moved, whatever is at the app's
  path stays there, and a `run-…` folder marked `recovery-required` stays in the
  `update` folder (never removed by muxFinder; check the installed app, reinstall it if
  needed, then delete that folder). Once muxFinder has quit, nothing watches the relaunch:
  if the new version does not open by itself within a minute, nothing says so; open it as
  usual (it is already installed).
- **Download instead of Update:** the notice offers **Download** (the release page, to
  install by hand) with "Can't update in place: <reason>" when this copy cannot replace
  itself: it is not signed with a Developer ID (everyday builds from `scripts/build-app.sh`
  are signed "Apple Development" or ad hoc); macOS runs it from a temporary location (an app
  opened where it was downloaded; move it to `/Applications` first); it is on a read-only
  disk, in a folder you cannot change, or another user's; it is on another disk than
  muxFinder's `update` folder (in your home folder's `Library`), or that folder cannot be
  used; or the release has no installable download (a single `muxFinder.zip` with its
  checksum).

The check, the download and the update itself have run only against stand-ins so far (the
verification also on a local copy of a release zip); their real runs are owed
(`docs/MANUAL-CHECKLIST.md` items 30–33).

## Scope and limitations

- **Default tmux server only:** muxFinder sees each user's default tmux server on each host,
  not servers started with `-L` or `-S` (named sockets are a possible later addition).
- **Tested hosts:** Neptuno (the development Mac) and Saturno over Tailscale. Sirio was
  offline during development, so nothing Sirio-specific was tried. iTerm2 3.7.6 and 3.7.7 are
  the only iTerm2 versions tested.
- **Open in iTerm2 here** is known only for tmux connections in this Mac's iTerm2, matched by
  asking each connection which server and session it shows; a client count cannot say which
  other computer is attached, so muxFinder does not guess.
- **Plain mode** (Terminal, Ghostty and terminals you add): one window per session, with
  tmux's status bar, prefix keys and copy mode instead of the terminal's own tabs, panes and
  scrolling; a session whose name has `{`, `[` or `]` cannot be opened there; a session
  attached by hand in a plain terminal on another Mac shows only as attached somewhere (only
  This Mac's clients are traced to their app); muxFinder never closes those windows itself.
  Terminal and Ghostty were tested only with stand-ins (their scripts were never run for real;
  `docs/MANUAL-CHECKLIST.md` items 26–29 are owed), and Ghostty's "AppleScript is turned off"
  line rests on a guessed error number. Details, and how to add a terminal, in
  `docs/TERMINALS.md`.
- **Not in this version:** deleting sessions, cloud sync, terminal previews, AI features,
  moving running processes between computers, bringing sessions back after a reboot,
  workspace management, Intel builds.
- **Known rough edges** (details in `docs/TESTING.md` and `PROGRESS.md`): a few checks need a
  person and are listed in `docs/MANUAL-CHECKLIST.md` (the real popover by hand, launch at
  login, "Show tab", the first Finder launch, Sirio, persistent profiles from Settings, the
  hidden launch tab, Terminal and Ghostty for real, the update check and the update for real);
  quitting can take up to 15 s while an open is in flight; iTerm2 3.7.6 shows a modal warning
  for tabs that end within 3 s of opening, so muxFinder's tabs never end sooner than 10 s. A
  launch tab can be left under Session › Buried Sessions when its attachment ended abnormally
  and its helper could not bring it back (the helper itself killed, iTerm2's advanced setting
  "Tolerate unrecognized commands from server" on, or a tmux command still in flight at that
  moment) while muxFinder was not running to do it; choose it there to show it, then close it.

What was tested for real and what is only expected to work: `docs/TESTING.md`, "Tested vs
expected to work".

## Removal

```
scripts/uninstall.sh --dry-run   # shows what it would remove
scripts/uninstall.sh
```

It quits the app (SIGTERM to each installed copy's `muxFinder`, up to 20 s, never forced),
then removes `DynamicProfiles/muxFinder.json` only when it is muxFinder's generated file (the
app's own code decides), `~/Library/Application Support/muxFinder` (host list, directories,
preferences such as the session switcher shortcut and the terminal choice, your terminal
definitions, launch folder, the update check's state and `update` folder),
`muxFinder.app` from `/Applications` and `~/Applications`, and the app's preferences
(`cc.carpio.muxfinder`, where macOS keeps the menu bar item's state). Helpers still running in
iTerm2 tabs (or other terminals' windows) are left alone and end with them. It does not
touch your tmux sessions, iTerm2's preferences or other profiles, `~/.ssh` or shell files.
Two things are left to you, and the script prints them:

- **Launch at login:** turn off "Open muxFinder when you log in" in muxFinder's Settings ›
  General before uninstalling, or remove muxFinder afterwards in System Settings › General ›
  Login Items.
- **Automation permission:** `tccutil reset AppleEvents cc.carpio.muxfinder`.

By hand instead: quit muxFinder, use Settings › Persistent profiles › "Remove profiles", then
delete the app and `~/Library/Application Support/muxFinder`.

A persistent work command you pasted into Terminal's or Ghostty's settings stays there until
you remove it yourself; once muxFinder is gone it cannot run.

## More

- `docs/TERMINALS.md`: Terminal, Ghostty and plain mode, the terminal choice and its
  permission, and adding a terminal.
- `docs/ARCHITECTURE.md`: how it is built, in one page.
- `docs/TESTING.md`: unit tests, real checks and the tested vs expected-to-work matrix.
- `docs/MANUAL-CHECKLIST.md`: the checks owed to a person.
- `docs/INTEGRATION-PROOF.md`: what the attach path does against the real iTerm2.
- `PLAN.md`: the plan and every design decision (D1–D39).

License: MIT (`LICENSE`).


## Developer ID certificate renewal (November 2026)

macOS releases now select the G2 certificate by its exact SHA-1 fingerprint,
`D90FF6C655C831F11CC50642E4EF8675905EAF79` (team `CXVKS8ZNCD`, expires December 8, 2027).
The old certificate may remain in the keychain; it is never a fallback for a new release.
The selection policy is in `scripts/lib/developer-id.sh`.

For a subsequent renewal, set `DEVELOPER_ID_SHA1` to the complete new fingerprint,
install its matching private key and certificate, and update any Developer ID provisioning
profiles to contain that certificate. The scripts reject missing, malformed, wrong-team,
or wrong-type identities. Update the default fingerprint and expiry after verification.
The legacy `Certificates.p12` backup predates G2; restore only a backup verified to contain
the selected identity. Do not commit private keys or certificate backups.

Run `bash scripts/test-developer-id.sh` for identity-selection and output-certificate checks.

Development builds retain Apple Development/ad-hoc signing. For release builds, `MUXFINDER_SIGN_IDENTITY` remains an alias when `DEVELOPER_ID_SHA1` is unset, but must now be a full fingerprint.
