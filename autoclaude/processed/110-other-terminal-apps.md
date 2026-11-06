# Other terminal apps: Terminal.app and Ghostty beside iTerm2

Proposed phase group, queued after every existing job, so there is no `priority:` line. The user
said: "Queue it after all the existing jobs". Suggested risk: **high**.

- Outside iTerm2 it changes the product's central promise: plain tmux instead of control mode.
- It adds a terminal layer above `ITerm2Integration`.
- It adds a new kind of user-editable file that can make muxFinder run a program.
- It sends AppleScript to two more apps.
- It touches attach, attachment detection, the launch helper, Settings, onboarding and most
  user-facing strings.

With iTerm2 chosen, nothing may change. A suggested split is at the end.

## User request (2026-11-06, verbatim)

> Right now this app is really iTerm2 centric. Would it be possible to generalize it and make
> it work with other terminal apps? Terminal.app, Ghostty, etc

The user was asked four questions:

1. Is plain tmux acceptable outside iTerm2, where there is no control mode?
2. Is this for them only, or for everyone?
3. Which terminals come first?
4. One "Terminal" setting in Settings › General, defaulting to iTerm2 when it is installed,
   or a per-click "Open in…" action?

The answers (verbatim):

> 1. Yes, it's acceptable.
> 2. For everyone.
> 3. Generalize as much as possible. Add Terminal.app and Ghostty as a first round, but make a
> note of adding other apps later. Maybe make it easy to have small .toml files (or anything
> you like) with specific configurations for specific apps.
> 4. I agree.

Then, on the design below (JSON instead of TOML, and the queue position):

> 1. Yes, JSON is fine.
> 2. Queue it after all the existing jobs

## User decisions (2026-11-06)

- **Plain mode is accepted outside iTerm2.**
  - No other terminal ships tmux control mode. Ghostty has internal parser work, but nothing
    user-facing was found on 2026-11-06.
  - So Terminal.app and Ghostty get ordinary `tmux attach`: one window, tmux's status bar,
    prefix keys and copy mode.
  - iTerm2 keeps native `-CC` exactly as today.
  - `docs/REQUIREMENTS.md` says "Every attachment must use iTerm2's native tmux control mode"
    and rejects plain tmux. It gets an addendum (requirement 13) instead of an edit of the
    verbatim brief.
- **For everyone.** Someone without iTerm2 must be able to install muxFinder, get through
  onboarding and use it.
- **Generalize as much as possible.** Terminal.app and Ghostty come first. Other terminals come
  later, with a written note about them.
- **Terminal definitions are small JSON files**, not TOML. TOML would need a third-party
  parser, and every other muxFinder file is already JSON.
- **One "Terminal" setting** in Settings › General, defaulting to iTerm2 when it is installed.

## Findings (2026-11-06)

- **Installed on this Mac:** iTerm2 3.7.6 and Ghostty 1.3.1. Terminal.app is always present.
- **Ghostty ≥ 1.3** has native AppleScript on macOS. It is on by default;
  `macos-applescript = false` in its config turns it off.
  - `new surface configuration` takes `command`, `initial working directory`,
    `environment variables`, `wait after command` and `initial input`.
  - `new window` and `new tab` take that configuration.
  - There are `focus` (for a terminal), `activate window` and `close`.
  - Terminals expose `id`, `name` and `working directory`. No tty, pid or title is documented.
  - The `+new-window` command-line action is Linux-only.
  - The authoritative reference is `sdef /Applications/Ghostty.app`. Read it in the proof
    phase, to learn whether `command` is one shell-parsed string and what `new window` returns.
    Docs: https://ghostty.org/docs/features/applescript
- **Terminal.app's AppleScript:**
  - `do script` opens a new window and types the text into the user's login shell, so that
    text is shell source.
  - Tabs expose `tty`, `processes`, `busy` and `selected`.
  - A window can be brought to the front.
- **Automation permission.** Both apps need macOS's Automation permission, granted per target
  app. muxFinder already has `NSAppleEventsUsageDescription` and the
  `com.apple.security.automation.apple-events` entitlement, for iTerm2's cookie.
  `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded` false reports the permission's
  state without a prompt.
- **Where it fits:**
  - `ITerm2Integration` (`Sources/MuxFinderCore/ITerm2/ITerm2Integration.swift`) is shaped
    around iTerm2's own messages, and 17 source files use it.
  - Attach: `AttachCoordinator`, `AttachCoordinatorBurial`, `AttachSeams` and `LaunchTab`;
    `AttachmentIndex` (D16); `SSHSetupLauncher` (D24).
  - The helper: `Sources/muxfinder-launch` and, in `Launch/`, `LaunchHelper.swift`,
    `LaunchHelperProfile.swift`, `ProfileLaunch.swift` and `TerminalStatusRequest.swift`.
  - Settings: `GeneralSettingsView.swift` and `ProfilesSettingsView.swift`. Onboarding:
    `OnboardingModel.swift` and `OnboardingView.swift`.
  - `MuxFinderUI` says "iTerm2" about 360 times.

## Requirements

1. **Proof first, in its own phase.**
   - Prove each step with probe commands and real runs, before building the app's layer:
     open a window running the helper, confirm the attach, focus that window, detach through
     tmux, and Move here.
   - Do it for Terminal.app and Ghostty, on This Mac and on `saturno-m4`.
   - Settle remote confirmation (requirement 5).
   - Record a new decision (the next free D number) with what was verified, and the D3
     extension for Terminal's command text (requirement 3).
2. **Terminal layer.**
   - A terminal-neutral seam above `ITerm2Integration`: open a launch, confirm it, focus it,
     detach it, and tell whether a session is open here.
   - iTerm2 implements it with today's code, behaving exactly as now (native mode, burying,
     Dynamic Profiles).
   - A plain backend implements it from a definition.
   - Everything else goes through the seam.
3. **Definitions:** JSON with a strict schema and a `schemaVersion`. Unknown keys are refused.
   - **Identity:** an id, a display name and a bundle identifier, used to find the app through
     LaunchServices, read its version and bring it forward. Also a minimum version and an
     optional `notes`.
   - **Open**, one of a fixed set of kinds:
     - `appleScript`: a static script file next to the definition. It is compiled once and
       called through a handler, with its arguments (helper path, token, …) passed in an Apple
       event. Script source is never built from values.
     - `exec`: an argv template whose placeholders (`{helper}`, `{token}`, …) must each be a
       whole argument. `ProcessRunner` spawns it, never through a shell. It is meant for
       WezTerm, Kitty and Alacritty later; one hermetic test definition exercises it.
   - **Focus:** `tty` (the launch's tty, as with Terminal's tabs), `windowID` (an id the open
     returned, such as Ghostty's terminal id) or `app` (only bring the app forward).
   - Whether the helper keeps its 10 s minimum lifetime, which only iTerm2 needs.
   - **Terminal.app's command text** is shell source, run in whatever shell the user has
     (zsh, bash, fish…).
     - It holds only the helper path and the validated token, POSIX single-quoted, run with
       `exec`.
     - A helper path is refused with a clear error if it holds `'`, `\`, a control character
       or anything fish reads differently inside quotes. This is how `profiles show` already
       refuses a helper path iTerm2 could split.
   - **Ghostty:** prefer putting the token in `environment variables` and only the helper path
     in `command`, whichever way the sdef says `command` is parsed.
   - **No typing:** never use Ghostty's `input text`, `send key` or mouse commands, and never
     type into an existing Terminal tab. Only new windows that run a command (CLAUDE.md: no
     synthesized keystrokes).
   - **Built-in definitions:** Terminal.app and Ghostty ship in the bundle, from
     `Resources/`. `scripts/build-app.sh` copies them and they are signed with the app.
   - **User definitions:** files in `~/Library/Application Support/muxFinder/terminals/` add
     terminals, or override a built-in one with the same id.
     - A definition can make muxFinder run a program, so user definitions load under D19's
       rules: owned by the user, a 0700 folder, no symbolic links, nothing group- or
       world-writable, and a size limit.
     - An unusable definition is skipped and shown in Settings with its problem. It is never
       fatal.
   - iTerm2 has no definition: it is code.
4. **Plain mode in the helper.**
   - `attach` runs `tmux -u attach-session` with no `-CC`, either locally or over `ssh -t`
     with D17's remote script.
   - No OSC 1337, no status-report wait and no bury.
   - The result file, the failure explanation and the wait for Return stay.
   - `profile` mode gains a plain variant, chosen by an explicit argument and never guessed
     from `TERM_PROGRAM`.
   - `ssh-setup` works unchanged in any terminal.
5. **Confirmation.** Only evidence counts (D15, D25).
   - **On This Mac:** confirmed when a client on that session has the helper's tty as its
     `client_tty`. The helper reports its tty and its attach child's pid early, in a file next
     to the request.
   - **Over SSH:** the local tty doesn't exist on the remote Mac. The proof phase must find a
     reliable way to identify the client. It may use only read-only commands over discovery's
     noninteractive ssh, with no remote file write. One idea: put the launch token in the
     remote tmux client's argv and read it with `ps`.
   - If nothing is reliable, the attach ends as "Opened in <app>", visibly not "confirmed",
     and the limit is documented.
6. **Detach and Move here** go through tmux itself: `detach-client` aimed at that client,
   locally or over BatchMode ssh, never by closing a window. Move here keeps D21's
   confirmation.
7. **Open on this Mac** (D16, generalized).
   - A local tmux client whose process descends from a terminal app is "open in <that app> on
     this Mac". That includes iTerm2. The process ancestry is read by pid, read-only.
   - Focus uses that terminal's focus kind.
   - Sessions muxFinder opened are remembered, in memory only.
   - A remote session attached by hand in a plain terminal shows "attached somewhere". This is
     documented.
   - Discovery's `list-clients` format gains the fields this needs (`client_pid`,
     `client_tty`). Discovery stays read-only (D6, D12).
   - When iTerm2 is not the chosen terminal, muxFinder never contacts it: no API, no
     Automation prompt.
8. **Settings › General "Terminal".**
   - It lists the installed terminals: iTerm2 when installed, Terminal.app, Ghostty when it is
     1.3 or later, and each user definition.
   - Each shows its Automation permission's state (read without a prompt) and a short note of
     what plain mode means.
   - The choice is saved in `preferences.json` through `PreferencesStore` (D32's rules).
   - Default: iTerm2 when installed, otherwise Terminal.app.
   - If the chosen terminal is gone or too old, the popover and Settings say so. It is never
     silently replaced.
9. **Strings follow the choice.**
   - Actions: "Open in Ghostty"; "Show window" in plain mode and "Show tab" in iTerm2;
     "Set up SSH in Terminal…".
   - Errors: "Ghostty's AppleScript is turned off", and "muxFinder isn't allowed to control
     Terminal" with how to allow it in System Settings › Privacy & Security › Automation.
   - The host's iTerm2 profile field applies only to iTerm2, and says so.
10. **Onboarding** works without iTerm2. It picks the terminal and explains plain mode. It asks
    to turn on iTerm2's Python API only when iTerm2 is the chosen terminal.
11. **Persistent work.**
    - iTerm2 keeps D26's generated profiles.
    - muxFinder never writes another terminal's settings. For those terminals, Settings shows,
      per host, the command to put in that terminal's own "run command" setting, with a Copy
      button. That is Settings › Profiles › Shell in Terminal, and `command` in Ghostty's
      config.
12. **No regression with iTerm2.**
    - With iTerm2 chosen, everything behaves as it does today.
    - The existing e2e runs and self-tests keep passing. Run the ones the touched code needs,
      with the thread-count caution.
13. **Docs.**
    - A dated addendum to `docs/REQUIREMENTS.md` quoting the user's decision. The brief above
      it stays verbatim.
    - `docs/TERMINALS.md`, "Adding a terminal": the schema, the kinds, the safety rules and a
      worked `exec` example.
      - It lists the **later candidates**: WezTerm (`wezterm start -- …`), Kitty
        (`kitty @ launch` or `--single-instance`), Alacritty (`alacritty msg create-window`)
        and Warp.
      - And: "Ghostty may ship tmux control mode; revisit native mode for it then."
    - Update README, ARCHITECTURE, TESTING, MANUAL-CHECKLIST and the PLAN.md decisions. Add
      CLAUDE.md commands for the new probe modes.
    - Extend the safety rules in CLAUDE.md and PLAN.md *Unattended-run rules* to Terminal and
      Ghostty windows: a test touches only what it opened. This only tightens the rules;
      nothing is relaxed.

## Acceptance

- **Hermetic tests:**
  - Definition loading: the schema, unknown keys, a placeholder that is not a whole argument,
    override by id, the minimum version, an unsafe file or folder, a symbolic link, an
    oversized file.
  - Argv expansion.
  - Terminal's command text: its quoting and its refusals.
  - The Apple event handler call, over a fake OSA runner.
  - The permission's states.
  - Local and remote confirmation: a match, none, and two candidates (which must not confirm).
  - Process ancestry to app, over a fake process table.
  - The default choice and its round trip.
  - The popover, Settings and onboarding content for each terminal.
- **Probe commands:**
  - `muxfinder-probe terminals list`, read-only: the definitions and their problems, the
    installed apps and their versions, and the permission's state, read without a prompt.
  - `attach --terminal <id> …`.
  - An `e2e-plain --terminal terminal|ghostty --local | --ssh saturno-m4` run: its own
    `muxfinder-test-*` sessions and its own windows only, cleaned up at the end.
- **Real runs** are recorded in `docs/TESTING.md` only when that terminal's permission is
  already granted. Otherwise they are owed. A run never waits on a prompt.
- **Galleries:** the Terminal picker's states in Settings, onboarding without iTerm2, and the
  popover and attach states for each terminal. Light and dark, in `docs/screenshots/`.
- **`docs/MANUAL-CHECKLIST.md`:**
  - Grant Automation for Terminal and for Ghostty.
  - In each: open, detach and Move here, locally and for a session on Saturno.
  - Paste the persistent work command into Ghostty's config.
  - Onboarding on a Mac without iTerm2, if one is available.
- **Builds and checks:** the shared verification, `scripts/build-app.sh`, and
  `codesign --verify --deep --strict build/muxFinder.app`.

## Suggested split

- (a) The proof and the decision.
- (b) Core: definitions and their loader, the terminal seam with the iTerm2 backend wrapped,
  the plain backend, and the helper's plain mode.
- (c) The coordinator: confirmation, detach, attachment detection, and `e2e-plain`.
- (d) UI: Settings, strings, onboarding, persistent work instructions, galleries.
- (e) Docs.
