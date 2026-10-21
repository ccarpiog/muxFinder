# muxFinder requirements (product brief)

This is the user's original brief, kept verbatim as the source of truth for scope and acceptance.
Where the brief says **"Orbit"**, read **muxFinder**: "Orbit" was an earlier working name.
`PLAN.md` turns this brief into phases; when the two disagree, this file wins on *what* and
`PLAN.md` wins on *how*.

---

Build a small native macOS app that lets me discover and reconnect to tmux sessions across my computers, while continuing to work entirely in iTerm2.

Use **muxFinder** as a working project name.
https://github.com/ccarpiog/muxFinder

Please implement a working app, not just a design document or mockup. Begin by inspecting the project and available development environment, make reasonable implementation decisions, and work through building and testing it. Ask questions only when a missing detail genuinely blocks progress.

## My situation and the outcome I want

I use three Macs:

- **Saturno** — Mac Mini.
- **Neptuno** — Mac Mini.
- **Sirio** — MacBook Air.

They are all accessible from each other via ssh keys and Tailnet.

I frequently start terminal work on one computer and want to continue it from another. I use iTerm2 and want to keep its native windows, tabs, split panes, scrolling, selection, and keyboard behavior.

I also frequently forget to start tmux. The app should make persistent sessions easy to start and resume without remembering terminal commands.

My ideal experience is:

1. Click a menu bar icon.
2. See my computers and their running tmux sessions.
3. Click a session.
4. iTerm2 opens or comes forward with that session attached through native tmux integration.
5. Continue working.

The session and its processes stay on the original computer. The app provides discovery and access; it does not migrate running processes.

All three computers should be supported as work hosts. Do not require one designated central server.

## Requirements that define the product

Build a native macOS menu bar app, preferably using SwiftUI with AppKit where needed.

The primary interface must be graphical. I do not want a terminal-based session picker or a replacement terminal emulator.

Every attachment must use **iTerm2's native tmux control mode**, through `tmux -CC`. Ordinary tmux running inside a single terminal pane does not satisfy this requirement.

The app must discover sessions independently of whether they are already open in the local iTerm2 instance. That includes detached sessions and sessions created outside Orbit.

Use the existing system SSH client and tmux installation. Do not require a custom daemon or server installation on the remote Macs.

Keep the product lightweight: no cloud account, central backend, Electron shell, or embedded terminal.

## Menu bar interface

Create a clean, compact popover with sessions grouped by computer.

An illustrative layout:

```
Saturno                         Reachable
work                          4 windows · 1 client
experiments                   2 windows · Detached

Neptuno                         Unreachable
Last checked 2 minutes ago

Sirio                           This Mac
notes                         1 window · Detached

[New Session] [Refresh] [Settings]
```

Treat this as a behavioral sketch, not a rigid visual specification.

Include:

- Search by host or session name.
- A clear empty state when a host has no sessions.
- Last successful refresh information.
- A visible progress state during connection.
- Useful errors with a retry action.
- Keyboard navigation, readable light/dark appearances, and accessibility labels.

Distinguish "attached somewhere" from "open in iTerm2 on this Mac." A tmux client count alone cannot tell us which computer is connected.

Do not imply a session is idle or doing useful work based solely on whether it has attached clients.

If a host becomes unreachable, retain its last known sessions only if they are clearly marked stale. Do not display cached information as live.

## Host setup and discovery

Provide settings to add, edit, disable, and remove hosts.

Each host needs:

- A display name.
- A connection mode: local or SSH.
- An SSH alias or destination for remote hosts.
- An optional explicit tmux executable path.
- An optional iTerm2 profile selection.

Use Saturno, Neptuno, and Sirio as onboarding examples. Do not assume their SSH usernames, addresses, or network reachability.

Provide an explicit "This Mac" selection rather than relying only on hostname matching. Local discovery and attachment should work without SSHing into localhost.

Reuse the user's SSH configuration, keys, and agent. Support manually entering aliases even if automatic SSH configuration discovery is incomplete. Let OpenSSH resolve its own configuration semantics.

Background discovery must be noninteractive, bounded by timeouts, and read-only. It must not open terminal windows, ask for passwords repeatedly, or create sessions.

Distinguish these situations wherever practical:

- Host unreachable or connection timed out.
- SSH authentication required or failed.
- Host key verification issue.
- tmux not installed or not found.
- tmux available with no running server or sessions.
- Successful discovery.

Do not weaken SSH host verification. When interactive setup is required, provide a deliberate action that opens iTerm2 so the user can complete it normally.

Handle the environment differences between GUI applications, interactive shells, and noninteractive SSH commands. Detect common Homebrew tmux locations and allow an override; do not assume the executable is on every process's PATH.

Discover the current user's default tmux server initially. State this scope clearly. Support for additional named sockets can be a later enhancement.

## Session refresh and identity

Poll hosts concurrently with a small concurrency limit so an unavailable computer does not delay the others.

Refresh immediately when the popover opens, then periodically while it is visible. Use slower background refresh, backoff for failures, and sensible handling of sleep, wake, and network changes.

Avoid overlapping refreshes, leaked subprocesses, and stale results overwriting newer state. Keep network and process work off the main thread.

Use explicit tmux output formats rather than parsing its human-readable default listing.

Track session identity using the configured host, socket identity, and tmux session ID. Account for IDs being reused after a server restart, and revalidate before acting. Names are display data and can change.

The same session name on Saturno and Neptuno must remain two separate entries.

## Opening and reconnecting in iTerm2

Clicking a session should:

- Launch iTerm2 if necessary.
- Establish a local or SSH connection inside an iTerm2 terminal.
- Attach to the selected session using `tmux -CC`.
- Bring the resulting native tmux window or tab forward.

The control-mode process must run in an iTerm2-owned terminal. Capturing its output inside Orbit and opening an unrelated iTerm2 window will not work.

Conceptually, attachment is:

```
Local: tmux -CC attach-session -t SESSION_ID

Remote: ssh -t HOST 'TMUX_PATH -CC attach-session -t SESSION_ID'
```

These are illustrations, not safe command-construction templates. Implement quoting and argument handling correctly.

A normal click must preserve other attached clients. Provide a separate, clearly named "Move here" action if implementing attachment that detaches other clients. Explain its effect in the interface.

If Orbit can reliably identify an existing local iTerm2 attachment, focus it instead of creating a duplicate. At minimum, prevent duplicate launches from repeated clicks while a connection is pending.

Never identify an attachment solely by a matching window title. If reliable matching is unavailable, document the limitation rather than guessing.

Do not inject commands into whichever terminal pane happens to be focused. Create a dedicated launch session through an appropriate iTerm2 API.

Separate "launch requested" from "attachment confirmed." Surface failures instead of reporting success just because iTerm2 opened.

If a selected session disappears between discovery and attachment, refresh and explain what happened. Do not silently create an empty replacement.

## Choose and validate the iTerm2 integration early

Before building the full interface, prove the central workflow end to end:

1. Discover an actual local tmux session.
2. Open it through iTerm2 in `-CC` mode.
3. Verify that tmux windows and panes appear as native iTerm2 tabs and splits.
4. Detach and reconnect successfully.
5. Repeat over SSH when an authorized test host is available.

Consult the installed iTerm2 version and current official documentation before choosing the automation method.

iTerm2 documents its Python API as the replacement for the older AppleScript API. Prefer the supported API when practical. A small Python helper is acceptable if its runtime, dependencies, authorization, and installation are handled cleanly. Do not assume macOS includes a suitable Python runtime.

If AppleScript is the most practical supported approach for the installed version, isolate it behind an adapter and explain the compatibility tradeoff. Do not assume it supports every capability we need.

Avoid UI scripting and simulated typing when a documented API can perform the action.

Keep the integration replaceable so the rest of the app does not depend on its implementation details.

Relevant official references:

- [iTerm2 tmux integration](https://iterm2.com/documentation-tmux-integration.html)
- [iTerm2 Python API introduction](https://iterm2.com/python-api/tutorial/index.html)
- [iTerm2 window creation API](https://iterm2.com/python-api/window.html)
- [iTerm2 tmux API](https://iterm2.com/python-api/tmux.html)

## Creating persistent work and preventing forgotten tmux

Provide a "New Session" action with:

- Target computer.
- Session name.
- Optional working directory on that computer.

Create the session and immediately attach through native iTerm2 integration. Validate names and handle collisions explicitly without replacing existing work.

Make it possible to create and reconnect to sessions without typing shell commands during normal use.

Also provide an optional setup flow for dedicated iTerm2 "Persistent Work" profiles. These should make it easy to start iTerm2 directly in a persistent session, including a chosen default session per host.

Use supported profile mechanisms, such as [iTerm2 Dynamic Profiles](https://iterm2.com/documentation-dynamic-profiles.html), after verifying the required settings.

Preserve existing profiles and use stable, app-owned identifiers. Explain how the user can make a generated profile their default. Avoid broad shell startup-file modifications or changes to unrelated profiles.

Prevent recursion or nested control-mode launches caused by generated profiles.

Be accurate about the scope: arbitrary shells started outside the configured workflow do not automatically become persistent, and existing ordinary terminal processes are not retroactively adopted into tmux.

## Session lifecycle and user expectations

Quitting Orbit must leave tmux sessions and iTerm2 connections running.

Provide a safe way to detach an Orbit-managed local attachment, or a clear route to iTerm2's detach command. Detach must preserve the session and its processes.

Do not implement detachment by closing arbitrary tmux tabs: iTerm2 distinguishes detaching from closing a tmux window, and the latter can terminate work.

Session deletion is not necessary for the first version. If added later, keep it separate from detachment and require explicit confirmation.

Explain briefly in onboarding:

- The original host must remain powered on and reachable.
- A disconnected client does not end the tmux session.
- A host reboot ends running processes.
- Orbit does not synchronize files or move execution between computers.

## Implementation quality

Keep the architecture small and understandable, with clear boundaries for:

- Host configuration and persistence.
- SSH/local process execution.
- tmux discovery and operations.
- iTerm2 integration.
- UI state and presentation.

Use structured subprocess arguments whenever possible. Remember that SSH remote commands still cross a shell-parsing boundary even when the local SSH process uses an argument array.

Treat host values, session names, executable paths, and working directories as data. Account for spaces, quotes, Unicode, leading hyphens, and shell metacharacters. Do not construct executable shell or AppleScript source by inserting unchecked values.

Validate or safely encode discovery output. A session name must not be able to corrupt the parser or execute a command.

Store app configuration under the normal macOS Application Support location. Do not copy private keys into app storage or logs.

Provide useful diagnostics without collecting terminal contents. Log operation outcomes and timing rather than private command histories.

Offer an opt-in launch-at-login setting through an appropriate macOS mechanism. Choose and document a reasonable minimum macOS version and supported CPU architectures based on the available environment.

## Verification and acceptance criteria

Write focused tests for the failure-prone parts: discovery parsing, command construction, session identity, refresh races, and error classification.

Use fixtures or mocks for predictable UI states, but do not present a mocked attachment as a successful real integration test.

The app is acceptable when:

- A local session appears and opens through native iTerm2 tmux integration.
- A session on an accessible remote host can be discovered and attached.
- Native tabs and split panes are preserved.
- Work survives detachment and can be resumed.
- Sessions created outside Orbit are discovered.
- Two hosts with identically named sessions remain distinct.
- An unreachable host does not freeze the UI.
- Authentication failure is distinguishable from an empty host.
- A disappeared session is handled without silently recreating it.
- Repeated clicks do not launch a burst of duplicate connections.
- New Session creates persistent work on the selected host.
- Quitting Orbit leaves the work running.
- Generated persistent profiles work without modifying unrelated settings.

Test locally first. Use remote machines only when access is already configured and authorized. If a required host or permission is unavailable, complete the independent work and clearly identify what remains unverified.

## Delivery and scope

Deliver:

- The app's source code.
- A reproducible build process.
- A locally runnable `.app` if the environment supports building it.
- Setup instructions for installing it on my Macs.
- Clear dependency and permission instructions.
- A short architecture explanation.
- Test results and known limitations.
- Instructions for removing app-owned helpers or profiles.

Separate what was tested from what is expected to work. Do not claim signing or notarization unless actually completed.

Prioritize a dependable first version: host setup, discovery, native iTerm2 attachment, session creation, and the persistent-profile setup flow.

Defer cloud synchronization, terminal previews, AI features, process migration, reboot resurrection, and elaborate workspace management.

Start with the iTerm2 integration proof, then build the smallest polished app that meets these requirements. Continue through implementation and verification rather than stopping after proposing a plan.
