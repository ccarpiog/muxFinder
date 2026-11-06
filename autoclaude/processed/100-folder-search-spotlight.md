# New session: search the host's folders by name (Spotlight, live over SSH)

Proposed phase, queued after the plan's remaining work. Suggested risk: **high**. It adds a
long-lived SSH channel and a new remote script (D3), a new setting, and a new section in the
directory list (D31). Creating and attaching do not change. Consider a split: (a) the core,
meaning the remote script, the query channel, query escaping, result parsing and a probe
command; (b) the UI, meaning the list section, the setting, the explanation and the galleries.

## User request (2026-11-06, verbatim)

> Alfred allows me to search for directories in a computer using a File Filter with File
> Types "public.folder". Let's say I'm in computer Sirio and I want to open a mux session in
> computer Saturno. I'd love being able to search for folders in Saturno from Sirio (the
> muxFinder instance in Saturno would need to do the work of filtering the folders by name and
> transmitting them in real time to Sirio). Do you think something like this would be
> possible?

Then, after discussing the approach below (verbatim):

> 1. Ok. Test it. Then, if needed, Just add this information somewhere in the app so that
> users may know what is happening if there is something they can't find. Maybe add a link to
> open teh Settings from muxFinder.
> 2. Ok
> 3. Ok
> 4. Ok
>
> There should be a setting allowing to select home folder only or whole disk
> Folder names only
> Yes, please.

## User decisions (2026-11-06, discussed while queuing)

- **No muxFinder needed on the remote host.** The muxFinder on this Mac runs Spotlight
  (`/usr/bin/mdfind`) on the host over the same noninteractive SSH that discovery uses (key
  authentication, BatchMode). This is what Alfred's File Filter does locally. A network
  service run by a remote muxFinder was considered and set aside: it would need its own
  authentication and the app running on the remote host, and SSH already provides both.
- **Live as you type**, through one SSH channel kept open while the form needs it (see the
  timings below). Not a new SSH connection per keystroke.
- **Folder names only**, case- and diacritic-insensitive "contains"
  (`kMDItemContentType == "public.folder" && kMDItemFSName == "*<text>*"cd`).
- **A setting: home folder only, or the whole disk.** It goes in Settings › Directories.
  Default: home folder.
- **This Mac too**, with the same search run locally.
- **Filter out noise** (point 2). Spotlight returns many folders under `~/Library`,
  `node_modules` and build folders. Leave those out by a fixed rule, decided in the phase and
  recorded.
- **Hosts without Spotlight** (point 3), such as Linux (no `mdfind`) or a Mac with
  indexing off: say so in the list, and don't search. A depth-limited `find` fallback is left
  for later.
- **Explain what can't be found** (point 1). The app tells the user why a folder may be
  missing, with a link to open the relevant Settings (below).
- **Test runs may query Spotlight on Saturno** (point 4). The user added this to the
  unattended-run rules themselves on 2026-11-06 (PLAN.md rule 3 and CLAUDE.md's safety
  rules): read-only `mdfind`, `mdutil -s` and readability tests on Saturno and this Mac,
  recording counts and timings only, never folder names or paths.

## Findings (2026-11-06; checked over SSH on Saturno from Neptuno, counts and timings only)

- Saturno, macOS 27.3: Spotlight indexing is enabled on `/`. `mdfind -count` of folders:
  home 48,849, of which `~/Library` holds 27,697 (57 %); Documents 1,863; Desktop 242;
  Downloads 539; whole disk 81,836; folders named `node_modules` in home 255.
- **Privacy over SSH.** On Saturno, `ls` of `~/Documents`, `~/Desktop` and `~/Downloads`
  over SSH succeeds, so its Remote Login already allows full disk access for remote users.
  The opposite case (those folders unreadable over SSH) could not be tried, because changing
  Saturno's settings is not allowed. It is **not known** whether `mdfind` hides results from
  those folders when the SSH session cannot read them. The app must not depend on either
  answer (see requirement 6).
- **Timings.** A name search (`*<3 letters>*`, count only) took 0.15–0.22 s inside `mdfind`,
  for home and for the whole disk. One SSH round trip with a fresh connection plus four
  queries took 1.44 s, so a fresh connection costs about 0.7 s. A query on an open channel
  should therefore answer in roughly 0.2–0.3 s over Tailscale.
- **Where it fits.**
  - The directory list's content is `DirectoryPickerContent`
    (`Sources/MuxFinderUI/Model/DirectoryPicker.swift`). Its sections are Recent, Saved and
    "Sessions on <host>" (line 252), filtered by typing (I-7).
  - The list lives in New session's window (I-9, D34: `NewSessionWindow.swift`,
    `AppModelNewSession.swift`, `AppModelDirectories.swift`).
  - The folder drop is in `FolderDrop.swift` (I-9b).
  - Discovery's noninteractive ssh is in `Sources/MuxFinderCore/Tmux/DiscoveryProbe.swift`
    and `TmuxCommands.swift`.
  - Preferences are in `Sources/MuxFinderCore/Config/PreferencesStore.swift` (D32).
  - Settings has a Directories tab (`Views/Settings/SettingsView.swift`).

## Requirements

1. **Remote script (D3).** A static script, with no runtime value inserted, run through
   `ssh` with discovery's options. It first reports the host's home folder, whether `mdfind`
   exists, the indexing state (`mdutil -s` for the searched volume), and whether
   `~/Desktop`, `~/Documents` and `~/Downloads` are readable. It then reads queries from
   stdin, one per line. Each query carries an id, the scope (home or whole disk) and the
   Spotlight predicate. For each query it runs `mdfind` with the predicate as **one quoted
   argument** (`-onlyin "$HOME"` for home), applies the noise rule, stops at a result limit
   (about 50), and writes the paths NUL-separated (`mdfind -0`), ended by a marker carrying
   the query's id. It ends when stdin closes. Escaping the typed text for Spotlight's query
   syntax (`"`, `\`, `*`, `?`, control characters) is a pure, tested Swift function on this
   Mac. Queries over a length limit are refused. Record all of this in D3 and a new decision
   (the next free D number; D34 is the window).
2. **Channel.** One channel per New session window and host. It opens on the first query and
   closes when the window closes, the host changes, after a quiet minute, or when the app
   quits. Closing it ends the remote script (stdin EOF). Keep at most one query in flight:
   wait for typing to pause (about 150 ms, at least 2 characters), send only the latest text,
   and discard answers to older ids. Every wait is bounded (connect, first byte, each
   answer), and a dead channel reopens once on the next query. This Mac runs the same script
   locally (argv, no shell string) or uses `NSMetadataQuery`. Decide which and record it.
3. **List.** A new section, "Folders on <host>", after the existing ones. It shows the
   matches for the Directory field's text, home-relative paths shortened to `~/…`, and long
   paths middle-truncated as the other rows are. While a query runs it shows "Searching…";
   with no matches, "No folders found". Picking a row fills the field like any pick (no
   reopen, I-7), and keys and pointer behave as in the other sections. If the folder is
   already in Recent, Saved or Sessions, it shows once, in its first section. Recent, Saved
   and Sessions still filter locally and appear at once. The new section must never delay
   them.
4. **Setting.** Settings › Directories gets "Search folders in: Home folder / Whole disk",
   saved through `PreferencesStore` (`preferences.json`, D32's rules; tests use a private
   folder or `InMemoryPreferencesStore`). A change applies to the next query.
5. **Hosts without Spotlight.** No `mdfind`, or indexing off: the section reads
   "Folder search isn't available on <host>" with the reason (no Spotlight, or indexing off),
   and no queries are sent. An SSH failure shows the problem in the section and never blocks
   the form.
6. **"Missing a folder?"** A short explanation reachable from the section (an info button or
   a footer link) and shown in Settings › Directories. It explains that results come from
   Spotlight, so:
   - folders whose names start with a dot, and anything excluded in Spotlight's privacy
     settings, never appear;
   - the noise rule leaves out the folders it names;
   - "Home folder" searches only the home folder (with a link to the setting);
   - on a remote host, macOS may hide Desktop, Documents and Downloads from SSH unless the
     host allows full disk access for remote users (System Settings › General › Sharing ›
     Remote Login › Allow full disk access for remote users, set on that host).

   When the script reports those folders unreadable, the section also says so directly
   ("Desktop, Documents and Downloads on <host> can't be searched over SSH"). Links: "Open
   muxFinder Settings" (Directories tab), and for This Mac "Open Spotlight settings" (macOS
   System Settings). Never open either in a check.
7. **Privacy.** Folder names are the user's data. They are never logged, never in fixtures,
   docs or screenshots (galleries use synthetic paths), and never cached on disk. Tests and
   checks record counts and timings only.
8. **Accessibility.** VoiceOver hears the section's result count when it changes, as with
   I-7's announcement, and "Searching…" is announced once, not on every keystroke.
9. Edit D3, D31, D32 (the preference) and D34, and update `README.md` (folder search, the
   setting, the limits) and `docs/ARCHITECTURE.md`.

## Acceptance

- Hermetic unit tests:
  - query escaping (quotes, backslash, `*`, `?`, diacritics, control characters, length);
  - parsing of the script's output (header, NUL-separated paths, id markers, a stale id
    discarded, a truncated answer, a path with a newline in its name);
  - the noise rule;
  - the channel state machine (debounce, one in flight, latest wins, reopen once, quiet
    close, host change), with a fake transport;
  - the list section's states (searching, results, none, unavailable with each reason, SSH
    failure, the protected-folders note), de-duplication against the other sections,
    picking;
  - the setting's store round trip and default.
- A probe command, for example `swift run muxfinder-probe folders --local | --ssh saturno-m4
  --name <text> [--scope home|disk] [--count-only]`, that prints the header, counts and
  timings by default. Paths only with an explicit flag, and never in unattended runs. Real
  runs on this Mac and Saturno with `--count-only` are recorded in `docs/TESTING.md`,
  together with the channel's per-query latency over SSH (counts and timings only).
- The New session gallery (and the switcher's and attach galleries if they show the list)
  gains states for searching, results, none, unavailable and the protected-folders note,
  plus Settings' Directories tab with the setting and the explanation. Rendered light and
  dark through `--preview-snapshot`, inspected, and saved in `docs/screenshots/`.
- `docs/MANUAL-CHECKLIST.md` gains an item:
  1. On Sirio (or this Mac with Saturno chosen), type part of a folder name on Saturno and
     see it listed within about half a second.
  2. Pick it and create a session there.
  3. Switch the setting to whole disk and find a folder outside home.
  4. Read "Missing a folder?" and open Settings from it.
  5. With This Mac, compare a search against Alfred's or Spotlight's own results.
- Shared verification (`swift build`, `swift test`, `swift format lint -r Sources Tests`),
  `scripts/build-app.sh` and `codesign --verify --deep --strict build/muxFinder.app` pass.
  Run `--selftest new-session-local` only if the creation path is touched, with the
  thread-count caution. No real `hosts.json`, `directories.json` or `preferences.json` is
  read or written by any check.
