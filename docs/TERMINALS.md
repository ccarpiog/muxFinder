# Terminal apps

muxFinder opens tmux sessions in iTerm2 through iTerm2's native tmux control mode, or in
another terminal app with plain tmux: Terminal and Ghostty are built in, and a small JSON file
adds any other terminal that can open a window running a given program. This page says what
plain mode is and costs, how the choice and its permission work, where persistent work goes in
each terminal, and how to add a terminal. The design and the verified facts behind it are in
`PLAN.md`, decision D38 (and D3's extension for Terminal's command text); what was tested is in
`docs/TESTING.md` (*Phases I-12a* to *I-12e*).

## Plain mode beside iTerm2's control mode

**iTerm2** attaches with `tmux -CC`: each tmux window becomes an iTerm2 tab or window, with
iTerm2's own split panes, scrolling, selection and keys, and the tab muxFinder opened to run
its helper is hidden once the session shows (README, "The launch tab is hidden while
attached"). Nothing about iTerm2 changes when other terminals are available.

**Every other terminal** gets plain tmux: muxFinder opens one new window of that app running
its helper, `muxfinder-launch attach-plain <launch id>`, which attaches the session with an
ordinary tmux client (never `-CC`). What that costs:

- **One window per session.** The session's tmux windows and panes stay inside that one
  terminal window; they do not become the terminal's own tabs or splits.
- **tmux's status bar** in the window shows the session's windows.
- **tmux's prefix keys** switch windows and panes, split and detach, as your tmux
  configuration sets them.
- **tmux's copy mode** for scrolling back and selecting inside the session's panes.

What stays the same: discovery, the check that a session is still the one listed before it is
attached, "confirmed" only from evidence, "Detach from this Mac" through tmux's own
`detach-client`, "Move here…" (after its confirmation), "Detach other clients…", New session,
and "Set up SSH in …", which opens a window of the chosen terminal. The strings name the
chosen terminal and its window: "Open in Terminal", "Show window" instead of "Show tab",
"Waiting for Terminal…", "Confirmed — open in Terminal on this Mac", "Already open here —
brought its Terminal window forward".

How it works, in short:

- muxFinder writes a request file (0600) in `~/Library/Application Support/muxFinder/launch/`
  and opens the window; the window runs only the helper's path, a mode word and a random
  launch id. The helper takes the request, checks the session's identity, and runs one tmux
  command that the tmux server itself checks and carries out (`if-shell -F … attach-session`,
  with `-d` for a move here), locally or through `ssh -t` to the host, as its child. Right after
  starting that child, the helper writes a short report: its terminal device and the child's
  pid and start time.
- **Confirmation on This Mac:** the session's client whose terminal (`client_tty`) is the
  helper's, while that same helper and attach child still run.
- **Confirmation over SSH:** the launch id is passed as the last argument of the remote shell
  that runs tmux, and muxFinder finds it with `ps` over the same noninteractive ssh discovery
  uses, writing nothing on the host. Other users of that host can see the launch id with `ps`;
  it grants nothing (requests stay on this Mac).
- **Detach** is one tmux command bound to that exact client (its name, pid and creation time,
  and the session's identity), never a window closing. muxFinder never closes a terminal
  window itself: after a detach the helper ends, and the terminal's own setting decides
  whether its window closes.
- A failure is explained in the window, which waits for Return.

Limits of plain mode:

- A session whose name contains `{`, `[` or `]` cannot be opened in a plain terminal (tmux
  could not be told its name safely): "Terminal windows can't attach a session whose name has
  “{”, “[” or “]”, …". Rename it, or choose iTerm2.
- **Open on this Mac.** A session with a client in Terminal, Ghostty or any defined terminal on
  this Mac, or in iTerm2 (whose own tmux connections show as "Open in iTerm2 here" while iTerm2
  is chosen), reads "Open in Terminal on this Mac" (naming that app) with "Show in Terminal"
  (which only brings that app forward), whatever terminal is chosen. What Open then does depends
  on the choice: with iTerm2 chosen, Open still opens the session in iTerm2; with a plain
  terminal chosen, Open on this Mac brings forward the app that client already runs in and
  opens nothing, so no second window attaches the same session.
  muxFinder finds this from each client's process ancestry, read by pid and read-only. Clients
  on another Mac cannot be traced, so a session attached by hand in a plain terminal there
  shows only as attached somewhere.
- While another terminal is chosen, muxFinder never contacts iTerm2: no API, no Automation
  prompt. The one exception is "Detach (opened in iTerm2)", your explicit detach of an
  attachment muxFinder made in iTerm2 before you changed the choice; likewise "Detach (opened
  in Terminal)" for a window muxFinder opened in a terminal that is no longer chosen.

## The built-in terminals

Both ship in the app bundle (`Contents/Resources/Terminals/`, sealed by the app's signature;
in the source tree, `Resources/Terminals/`). Each opens its windows through a static
AppleScript file that muxFinder compiles as it is and calls with values; it never builds
script source.

- **Terminal** (id `terminal`, `com.apple.Terminal`, version 2.0 or later; macOS ships it).
  `do script` opens a new window whose shell runs `exec '<helper>' 'attach-plain' '<launch
  id>'`. That text is shell source in your login shell, whatever it is, so each word is POSIX
  single-quoted and reads the same in sh, zsh, bash, dash, ksh, tcsh and csh (the tests run
  each, and fish where it is installed); `exec` replaces the shell, so nothing runs after it.
  The window is found and brought forward by its tab's terminal device. A helper path holding
  `'`, `\`, `!` or a control character is refused for this text ("… move muxFinder to
  /Applications …").
- **Ghostty** (id `ghostty`, `com.mitchellh.ghostty`, version **1.3 or later**, which has
  AppleScript). A new window with a configuration whose command is the helper's path, the mode
  word and the launch id, and "wait after command" off (the helper's own wait for Return shows
  failures); the window is brought forward by the id Ghostty returned. The three words may hold
  only ASCII letters, digits and `/ . _ + -`, so they mean the same however Ghostty parses its
  command; a helper path with a space or anything else is refused (move muxFinder to
  `/Applications`). Ghostty's AppleScript is on by default; `macos-applescript = false` in its
  config turns it off, and then Open says "Ghostty's AppleScript is turned off" with how to
  turn it back on (muxFinder takes Ghostty's error -1708 or -10004 to mean that; the real
  number is still to be confirmed).

The built-ins were tested with stand-ins only: no unattended run may start Terminal or Ghostty
or send either an Apple event without its permission already granted, and neither was running.
Their real runs are owed to a person (`docs/MANUAL-CHECKLIST.md` items 26–29).

## Choosing a terminal

Settings › General › Terminal (also onboarding's first step) lists iTerm2 when it is
installed, then every terminal whose app is installed at its definition's minimum version, by
name: Terminal, Ghostty only from 1.3, and your own definitions. Each row shows the installed
version; plain rows show "Plain tmux: windows and panes stay inside one terminal window." and,
for a terminal driven by AppleScript, its permission (below). Definition files muxFinder could
not use are listed under "Terminal definitions not used", with the file name and why.

How the choice resolves:

- **Nothing chosen yet:** iTerm2 when it is installed, otherwise Terminal. muxFinder writes
  nothing for this default.
- **A choice** is stored as `terminal` in
  `~/Library/Application Support/muxFinder/preferences.json`, written only when you choose a
  row. It is used only while it is usable: for `iterm2`, iTerm2 installed; for a definition's
  id, that definition loaded, its app installed, and its version readable and at least the
  definition's minimum.
- **An unusable choice is never replaced** by another terminal (a stored iTerm2 is not
  replaced by Terminal when iTerm2 is gone): Settings keeps it selected with its reason
  ("Ghostty isn't installed.", "Ghostty 1.2 is older than 1.3.", "Can't read Ghostty's
  version.", "No terminal named “warp”."), and Open says so and opens nothing ("The chosen
  terminal, Ghostty, isn't installed. …", with "Open Settings").
- A change made while a session is opening is shown at once and applies when that action ends
  ("Applies when the current action ends.").
- "Check again" reads the apps' versions and permissions again and resolves the choice again
  (Ghostty updated to 1.3 is then used). Definition files are read once, when muxFinder
  starts.

## The Automation permission

Terminal and Ghostty are driven with AppleScript, so macOS's Automation permission is needed
for each one muxFinder opens windows in: System Settings › Privacy & Security › Automation ›
muxFinder › Terminal (or Ghostty). macOS asks once, the first time muxFinder sends that app an
Apple event: your first Open (or "Set up SSH in …") with it chosen. Started from a shell inside
iTerm2, muxFinder runs with iTerm2's permissions instead, as for iTerm2 itself. A terminal added
with an `exec` definition sends no Apple event and needs no permission.

What reads it, never with a prompt (`AEDeterminePermissionToAutomateTarget` without asking):

- **Settings › General and onboarding**, when their window opens and on "Check again":
  "Allowed", "Not allowed", "Not asked yet", "Checked when the app is running" (macOS can tell
  only while the app runs), "Unknown", or "Not needed" (`exec`). "Not allowed" and "Not asked
  yet" offer "Allow in System Settings…", which opens the Automation pane. Diagnostics shows
  the permission as last read.
- **An Open the permission refuses** ends with "muxFinder isn't allowed to control Terminal,
  so it opened nothing. Allow it in System Settings › Privacy & Security › Automation, then try
  again." and "Open System Settings…".
- **`swift run muxfinder-probe terminals list`** (from a checkout; read-only) prints each app's
  state for the app the command runs in, iTerm2 when run from an iTerm2 shell. The probe's real
  runs in another terminal (`attach --terminal`, `e2e-plain`) refuse with exit 2 unless the app
  is running and its permission reads `granted`, so they never cause a prompt.

Reading the permission sends the app nothing and never starts it. An Open sends its event even
when the app is not running, and macOS starts the app; bringing a window forward never does
(the app must already run).

## Persistent work

iTerm2 keeps its generated "Persistent work" profiles (README, "Persistent profiles"). With
another terminal chosen, muxFinder never writes that terminal's settings; Settings ›
Persistent profiles shows "Persistent work in Terminal" instead: for each saved host whose
"Persistent profile" is on, in host-list order, the command

```
exec '<helper path>' 'profile-plain' '<host id>'
```

with a Copy button, and where to paste it:

- **Terminal:** Settings › Profiles › Shell › Run command (in a profile of your choice), with
  "Run inside shell" kept on (the quoting and `exec` need the shell).
- **Ghostty:** in Ghostty's config file, write `command = ` followed by the command, then
  reload Ghostty's config.
- **Any other terminal:** that terminal's own setting for the command a new window runs.

A window that runs it attaches that host's session with plain `tmux new-session -A -s
<name>` (creating it when missing), locally or over interactive ssh, with the same rules as
iTerm2's profiles: where tmux or muxFinder already runs (`TMUX` or `MUXFINDER_LAUNCHED` set),
for a host whose persistent profile is off, or on any failure, it starts your login shell
instead. "Install profiles" is not offered while another terminal is chosen; "Remove
profiles" still is while muxFinder's own iTerm2 file is installed. The command holds the
helper's path, so copy it again after moving muxFinder.

## Adding a terminal

A terminal is added with a definition: a small JSON file in
`~/Library/Application Support/muxFinder/terminals/` (the user folder), one per terminal. A
definition can make muxFinder run a program, so the folder and its files must pass the rules
below, and every value is checked strictly. muxFinder reads the folder when it starts: quit and
open it again after adding or changing a file. iTerm2 has no definition (it is code), and its
id `iterm2` is reserved.

### The file (schema 1)

A UTF-8 JSON object (a UTF-16 file is not JSON to muxFinder). Unknown keys are refused at
every level, so is a key given twice in one object, and the first problem found is reported.

| Key | Required | Rule |
|---|---|---|
| `schemaVersion` | yes | The whole number `1`. A larger one reads as written for a newer muxFinder; zero, a negative number, a fraction, text or `true`/`false` are refused. |
| `id` | yes | 1–32 bytes of lowercase ASCII letters, digits and `-`; never `iterm2`. Stored as your choice, and the key of an override (below). |
| `displayName` | yes | 1–64 characters, no control character. Every string uses it ("Open in …", "Set up SSH in …"). |
| `bundleIdentifier` | yes | 1–255 bytes: parts of ASCII letters, digits and `-`, joined by dots, none empty. LaunchServices finds the app by it (ignoring case), reads its version and brings it forward. |
| `minimumVersion` | yes | Dotted decimal, 1–8 parts of 1–9 digits each, at most 32 bytes (`1.3`, `2.15.1`; no suffix such as `-beta`). |
| `notes` | no | Text up to 1 KiB, no control character but line feed and tab. Kept with the definition; Settings shows its own one-line note under each plain terminal. |
| `open` | yes | How a window running the helper is opened: an `appleScript` or `exec` object (below). |
| `focus` | yes | An object with only `kind`: `tty`, `windowID` or `app` (below). |
| `keepsMinimumLifetime` | no | `true` or `false` (a number is refused), default `false`. With `true` the helper stays at least 10 s in the window, as it must in iTerm2, whose tabs warn when they end sooner; the built-ins leave it off. |

**The minimum version** is compared numerically with the app's `CFBundleShortVersionString`,
part by part, a missing part counting as zero (`1.3` is `1.3.0`). An app older than it, or
whose version cannot be read, is never used: it is not listed in Settings, and as the stored
choice it is unavailable.

### Open kinds

**`appleScript`**: `{"kind": "appleScript", "script": "<name>.applescript", "command":
"shellText" | "words"}`, those keys only.

- `script`: a file in the same folder as the definition: 1–64 bytes of ASCII letters, digits,
  `.`, `_` and `-`, not starting with `.`, ending in `.applescript` with a name before it.
  AppleScript source text, which muxFinder compiles once (the first compile reads the app's
  scripting dictionary, which may start the app).
- `command`: the form the launch is handed to the script in:
  - `shellText`: one line of shell source, for a terminal that types it into the user's shell
    (as Terminal's `do script` does): `exec '<helper>' '<mode>' '<token>'`, each word POSIX
    single-quoted (PLAN.md D3's extension). A helper path holding `'`, `\`, `!` or a control
    character is refused.
  - `words`: the helper path, the mode word and the launch id as three values, each only ASCII
    letters, digits and `/ . _ + -`, for a terminal that splits a command itself (as Ghostty
    does). A helper path with a space or any other character is refused.

The script must define three handlers. muxFinder calls them with text values in one Apple event
and reads their answers strictly:

- `on muxfinder_open(commandText, helperPath, modeWord, token)` opens a new window running the
  launch. With `shellText`, `commandText` holds the command text and the other three are
  empty; with `words`, `commandText` is empty and the other three hold the words. It returns
  `{windowID, tty}`: exactly two texts, each at most 256 bytes with no control character, the
  second empty or `/dev/` followed by letters, digits, `.`, `_` or `-`. An empty text means
  "not known". Any other answer is refused.
- `on muxfinder_focus(windowID, ttyName)` brings that window forward (one of the two is empty,
  per the focus kind) and returns nothing (a bare `return`); it raises error -1728 when the
  window is gone.
- `on muxfinder_close(windowID)` closes only that window and returns nothing; it raises -1728
  when the window is gone and 1001 when the window still runs a process (it is left open). The
  app never closes a window; only the `e2e-plain` check calls it, for windows it opened, once
  their helper has ended.

Error -1743 from any handler means the Automation permission is denied. The built-in scripts,
`Resources/Terminals/terminal.applescript` and `ghostty.applescript` in the source tree, are
worked examples of the contract.

**`exec`**: `{"kind": "exec", "executable": "<path inside the app>", "arguments": [ … ]}`, those
keys only.

- `executable`: 1–1024 bytes, a path inside the app LaunchServices finds by
  `bundleIdentifier`, such as `Contents/MacOS/<name>`: no leading `/`, no empty, `.` or `..`
  part, no control character.
- `arguments`: at most 64 texts, each at most 4096 bytes with no control character. Each one
  is taken literally or is exactly one placeholder (below).
- muxFinder starts the program with that argument list, never through a shell: in a session
  and process group of its own, with no controlling terminal, standard input, output and error
  on `/dev/null`, and muxFinder's environment. It returns at once, never signals the program,
  and reaps it when it exits. The program must open a new window that runs the helper's three
  words as its command, on that window's terminal; it may exit afterwards (handing the window
  to an app that is already running) or keep running.
- An `exec` terminal needs no Automation permission ("Not needed") and its focus kind must be
  `app`.

### Placeholders

An `exec` argument that is exactly one of these is replaced by its value, as one whole
argument. Each must appear exactly once; a placeholder or a brace inside longer text, or any
other `{…}`, is refused.

| Placeholder | Value |
|---|---|
| `{helper}` | The helper's absolute path, `muxFinder.app/Contents/MacOS/muxfinder-launch` wherever the app is installed. |
| `{mode}` | The helper's mode word: `attach-plain` to attach a session (Open, Move here, New session), `ssh-setup` for "Set up SSH in …". |
| `{token}` | The launch id, a canonical UUID. |

Here the helper path only has to be absolute without a control character, but muxFinder's own
rule for its install path applies anyway (README, "Install on each Mac").

### Focus kinds

- `tty`: the window whose tab has the launch's terminal device, as `muxfinder_open` returned
  it (`muxfinder_focus("", <tty>)`). `appleScript` only.
- `windowID`: the window by the id `muxfinder_open` returned (`muxfinder_focus(<id>, "")`).
  `appleScript` only.
- `app`: brings the app forward only, through macOS's running-application API, with no Apple
  event and never starting it. Works with either open kind.

A focus (or a check's close) goes only to a window that the same loaded definition opened in
this run of muxFinder, and never to an app that is not running: an event would start it.

### The user folder and its rules

`~/Library/Application Support/muxFinder/terminals/` does not exist until you make it, for
example with `mkdir -m 700 ~/Library/Application\ Support/muxFinder/terminals`; the app only
reads it and never creates, changes or removes anything there (`scripts/uninstall.sh` removes
muxFinder's whole folder, this one included). A missing folder is no problem.

- **The folder** is reached from `/` one component at a time without following a symbolic link:
  a link anywhere on its path makes it unusable (which is also why a check's folder under `/tmp`
  or `/var`, both links, is refused). It must be yours, mode exactly 0700, with no extended
  ACL. Otherwise it gets one problem and none of its definitions is used.
- **Files:** `*.json`, not hidden (no leading `.`), read in name order, at most 32 (the rest
  are listed as problems). Each must be a regular file (not a link), yours, not group- or
  world-writable (readable is fine), with no extended ACL, at most 64 KiB. Its script follows
  the same rules, at most 256 KiB, UTF-8 text with no NUL byte.
- **Ids:** two files of the folder with the same id are both refused. A file with a built-in's
  id overrides that built-in (its source reads `userOverride`), for example your own
  `terminal` definition with its own script.

### The problems list

An unusable file is skipped, never fatal, and listed with its file name and a plain sentence:
in Settings › General under "Terminal definitions not used", and in `terminals list` under
`problems` with a code. Some of them: `unsafeFolder.symbolicLink`,
`unsafeFolder.permissionsNotPrivate` ("Other users have access to the terminals folder. Its
mode must be 0700."), `unsafeFile.writableByOthers`, `unsafeFile.tooLarge`,
`unsafeScript.missing`, `tooManyFiles`, `notJSON`, `unknownKey` ("This file has a key muxFinder
doesn't know: …"), `duplicateKey`, `missingKey`, `wrongType`, `invalidID`, `reservedID`,
`newerSchemaVersion`, `placeholderInsideArgument` ("Its argument 1 has a placeholder or a
brace inside other text. A placeholder must be a whole argument."), `unknownPlaceholder`,
`placeholderNotOnce`, `focusNeedsAppleScript` and `duplicateID`.

### Checking a definition

From a checkout of this repository, `swift run muxfinder-probe terminals list` prints the
definitions muxFinder would load (id, name, source `builtIn`, `user` or `userOverride`, open
kind, command form, focus kind and the app's facts) and every problem. It is read-only:
it launches nothing, sends no Apple event, compiles no script and writes nothing.
`--user-directory <folder>` reads another folder under the same rules (a private one from
`mktemp -d /private/tmp/mfx.XXXXXX`, then `chmod 700`; never under `/tmp` or `/var`). Without a
checkout, quit and open muxFinder and look at Settings › General. A real run of a definition
is `swift run muxfinder-probe e2e-plain --terminal <id> --local` with the app running (and, for
`appleScript`, its permission granted); it touches only the windows it opens, and leaves an
`exec` terminal's windows to that terminal (there is no id to close them by).

### A worked example

An `exec` definition for a terminal app whose program opens a new window running the
arguments after `--`:

```json
{
  "schemaVersion": 1,
  "id": "example-term",
  "displayName": "Example term",
  "bundleIdentifier": "com.example.term",
  "minimumVersion": "1.0",
  "notes": "Opens each session in a new Example term window with plain tmux.",
  "open": {
    "kind": "exec",
    "executable": "Contents/MacOS/example-term",
    "arguments": ["start", "--", "{helper}", "{mode}", "{token}"]
  },
  "focus": {
    "kind": "app"
  },
  "keepsMinimumLifetime": false
}
```

Saved as `example-term.json` in the user folder, it adds "Example term" to Settings once the
app with that bundle identifier is installed at version 1.0 or later. An Open then runs
`<app>/Contents/MacOS/example-term start -- <helper path> attach-plain <launch id>`, with no
shell; the helper in the new window attaches the session and muxFinder confirms it as for any
plain terminal. "Show window" brings the app forward.

For a real app, take `bundleIdentifier` from its `Info.plist` (`plutil -extract
CFBundleIdentifier raw <app>/Contents/Info.plist`), `executable` from what its
`Contents/MacOS/` holds, and the arguments from the program's own documentation for opening a
window that runs a command. The arguments above follow the form WezTerm's entry below names.

This file was checked to load (Phase I-12e, `docs/TESTING.md`): in a private 0700 folder,
`terminals list --builtin-directory Resources/Terminals --user-directory <that folder>` listed
it under `definitions` with source `user` (its app not installed, permission `notNeeded`) and
no problem. It was not run: no such app exists.

## Safety rules

What muxFinder never does to another terminal app:

- **Never types into a window or tab**, and never sends one keys or pointer events: no `do
  script … in` an existing Terminal tab or window, no `do script in new tab` (it would land in
  your frontmost window), no Ghostty `input text`, `send key` or mouse commands. It only opens
  new windows that run its helper.
- **Never reads** a window's contents, history or title.
- **Never builds script or shell source from values:** a definition's AppleScript is compiled
  as the file holds it and its handlers get values as arguments; Terminal's command text is
  quoted as above; an `exec` program gets an argument list, never a shell.
- **Never changes another terminal's settings** (Terminal's profiles, Ghostty's config): the
  persistent work command is yours to paste.
- **Never closes a window to detach**, and never closes one at all in the app: a session is
  detached through tmux, bound to its client.
- **Touches only its own windows:** it focuses only a window its own open recorded, through the
  same definition, never one you opened ("Show in Terminal" only brings the app forward); its
  checks close only windows they opened, by the id they recorded, once the helper in them has
  ended.
- **Never starts an app to focus or close a window**, and reads the Automation permission
  without a prompt.
- **Never contacts iTerm2** while another terminal is chosen, except "Detach (opened in
  iTerm2)".
- **Reads process ancestry by pid only**, for "Open in … on this Mac": nothing is sent to the
  processes or their apps.
- **Loads user definitions only under the folder rules above.**

Unattended checks of this repository go further (PLAN.md *Unattended-run rules* 1 and 8): they
never launch Terminal or Ghostty, send either an Apple event only while it is already running
and its permission reads granted without a prompt, and touch only the windows they opened.

## Later candidates

Not built in yet; each could be added with a definition once its open form is settled. None
was installed when this was written, so nothing below was tried.

- **WezTerm** (`wezterm start -- …`): an `exec` definition shaped like the worked example
  (`start`, `--`, then `{helper}`, `{mode}` and `{token}`), focus `app`. Needed: the app's
  bundle identifier and the executable's path inside it; a real run showing that `start` opens
  a new window running the helper on that window's terminal, also while WezTerm already runs;
  then `e2e-plain` locally and over SSH.
- **Kitty** (`kitty @ launch` or `--single-instance`): an `exec` definition with one of the two
  forms. Needed: which of them opens a new window running the helper whatever kitty's own
  configuration says, and whether it needs a setting turned on in kitty first (which this
  page would then say); then the same real runs.
- **Alacritty** (`alacritty msg create-window`): an `exec` definition with that form. Needed:
  what it does when no Alacritty runs yet, and a form that works then too; then the same real
  runs.
- **Warp:** no open form is known yet. Needed: a way to open a new window that runs a given
  program, through AppleScript or a command, with nothing typed into a window (muxFinder never
  types); without one Warp cannot be added.

Ghostty may ship tmux control mode; revisit native mode for it then.
