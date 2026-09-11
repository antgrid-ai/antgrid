---
name: launch-app
description: "Launch the Antgrid Flutter app with Flutter Driver for UI verification, screenshots, widget interaction, and debugging. Invoke when: verifying UI changes visually, debugging layout/rendering issues, testing navigation flows, or inspecting widget state at runtime."
---

# Launch App for UI Verification & Debugging

<WHEN-TO-USE>
Invoke this skill when you need to:
- **Verify UI changes** — after editing widgets, styles, or layouts
- **Debug visual issues** — layout overflow, missing widgets, wrong colors/spacing
- **Test navigation flows** — tap through screens, verify transitions
- **Inspect runtime state** — widget tree, app logs, runtime errors

Do NOT invoke for: unit tests, static analysis, code-only changes with no visual impact.
</WHEN-TO-USE>

<HARD-RULES>
- ALWAYS navigate with the nav console when the grammar can name the destination — tapping through the tree is the fallback, not the default
- NEVER guess widget finders — always inspect the widget tree first
- ALWAYS screenshot after hot reload to confirm changes visually
- ALWAYS clean up ALL processes on exit (flutter run + app executable + relay + agent)
- Use hot_reload for UI changes, hot_restart for state/initialization changes
- Prefer `ByValueKey` > `ByText` > `ByType` for finding widgets (most stable to least)
</HARD-RULES>

## Startup Sequence

Execute steps sequentially. Each step depends on the previous.

### Step 1: Start Relay (Optional)

Run relay in background to test mobile access.

```bash
cd relay && bun run dev &    # start relay on :8080
```

Verify it started by checking output. If port 8080 is in use:
```bash
netstat -ano | grep ":8080"
taskkill //PID <pid> //F
```

### Step 2: Launch Flutter App

The dart MCP server exposes no launch tool — start the app yourself, from `app/`,
in the BACKGROUND (`flutter run` never returns), and always through the driver
entry point, which is the only thing that mounts the nav console:

```bash
flutter run -d <windows|macos|linux> -t test_driver/driver_main.dart --debug
```

Wait for `A Dart VM Service on Linux is available at: http://127.0.0.1:<port>/`
in the log — that line is the app being up. On a headless machine there is
setup to do first; see **Linux / remote container** below.

### Step 3: Connect & Verify

`flutter run` starts its own Dart Tooling Daemon; find it rather than guessing:

```
mcp__dart__dtd(command: "listDtdUris")
mcp__dart__dtd(command: "connect", uri: "<ws URI from the listing>")
mcp__dart__flutter_driver_command(command: "get_health")
```

`connect` echoes the connected apps — confirm one is `Package: antgrid` before
driving it.

Health check must return `{"status": "ok"}` before proceeding.

If a driver command answers `Timed out waiting for Flutter Driver response`
while the app is on the splash or any other screen holding an indeterminate
loading indicator, the command never ran: the driver waits for frames to settle
first, and a looping animation never settles. Turn the wait off
(`command: "set_frame_sync", enabled: "false"`) and reissue. Leave it off only
as long as you need it — with it off, a command can read the frame before the
one your last action produced.

### Step 4: Baseline Screenshot

```
mcp__dart__flutter_driver_command(command: "screenshot")
```

Always capture the initial state before making changes.

### Linux / remote container

A Claude Code web session runs Linux with no display and none of the desktop
libraries, so `flutter run -d linux` fails at CMake until this is done. Each
failure names only the package it hit, one per attempt — install the set.

```bash
apt-get install -y libgtk-3-dev libsecret-1-dev libjsoncpp-dev \
  libwebkit2gtk-4.1-dev libcurl4-openssl-dev   # gtk / secure-storage / webview / sentry
Xvfb :99 -screen 0 1600x1000x24 &               # background; export DISPLAY=:99
```

A CMake configure that failed leaves `app/build/linux` poisoned the way the
Windows one does — delete that directory after fixing the dependency, or the
next configure inherits the broken cache.

Two things then keep the app off its own home screen, and neither says so:

- **The secret service.** `flutter_secure_storage_linux` logs `KeyringLocked`,
  the stored-cookie probe never resolves, `signedInProvider` stays null, and
  `_AppHome` sits on `AuthSplash` forever. It looks like a hang and is not. Run
  the app under `dbus-run-session` with an unlocked keyring
  (`printf '\n' | gnome-keyring-daemon --unlock --components=secrets`, then
  export what it prints); `secret-tool store` proves it works before you spend
  a build on it.
- **The bridge host.** It runs from source, so a container that never ran
  `bun install` at the repo ROOT crash-loops on a missing `antgrid-wire` and
  every project shows "agent failed to start". `~/.antgrid-dev/host.log` names
  it; the app log only reports the respawn.

Opening a project needs a native file dialog the driver cannot reach, so seed
one instead: write an `AbProject` JSON into the app's SharedPreferences
(`~/.local/share/ai.radhaai.antgrid/shared_preferences.json`, key
`dev.antgrid.projects.v1` — the `dev.` prefix comes from `storage_scope.dart`)
and hot restart. `projectId` must be `computeProjectId(folder)` from
`bridge/src/project-id.ts`, and `hostDeviceUuid` the value already stored under
`dev.antgrid.local_host_uuid`, or the project reads as remote.

## Core Workflows

### Verify a UI Change

This is the most common workflow. Follow this exact loop:

1. **Screenshot before** — capture current state
2. **Edit** the Dart file(s)
3. **Hot reload** — `mcp__dart__hot_reload()`
4. **Screenshot after** — `mcp__dart__flutter_driver_command(command: "screenshot")`
5. **Compare** — visually confirm the change matches intent

If the change involves state initialization, constructor changes, or new providers, use **hot restart** instead:
```
mcp__dart__hot_restart()
```

### Navigate: name the destination (nav console)

**Do not tap your way across the app.** The driver entrypoint mounts a nav
console — a thin bar at the bottom of every screen — that takes an
`antgrid://nav/...` URI and reports where you landed. Three calls to go
anywhere, one to verify, no screenshots:

```
mcp__dart__flutter_driver_command(command: "tap",
  finderType: "ByValueKey", keyValueString: "ab.nav.command", keyValueType: "String")
mcp__dart__flutter_driver_command(command: "enter_text",
  text: "antgrid://nav/local/<projectId>?surface=workspace&view=git")
mcp__dart__flutter_driver_command(command: "send_text_input_action", action: "done")
mcp__dart__flutter_driver_command(command: "get_text",
  finderType: "ByValueKey", keyValueString: "ab.nav.state", keyValueType: "String")
```

`get_text` returns one JSON object — read it instead of screenshotting:

| Field | Meaning |
|---|---|
| `location` | Where the app is now, as a URI in the same grammar you typed. `null` before the first navigation. |
| `view` | The workspace tab actually on screen (`null` when none is). |
| `canBack` / `canForward` | Whether the app's own back/forward have history to move through. |
| `last` | `ok`, `none` (nothing submitted yet), or `error: ...` when the URI was refused. |

Check `last` before trusting `location`: a rejected URI navigates nowhere and
leaves `location` reading exactly as it did before.

`last` is never cleared, only overwritten by the next submission that actually
lands — so a stale `ok` is indistinguishable from a fresh one. A command that
misses the field entirely (see the `tap` note below) leaves the whole payload
untouched, which reads as success. `location` is the only field that proves the
navigation you just sent was the one applied.

`ok` means **parsed and applied**, not "the destination exists" and not "it is on
screen". Nothing validates a project id, so a guessed one deselects the real
project and leaves you looking at nothing while still reporting `ok`; a link
submitted before the workspace is up (sign-in, splash) writes its state and shows
nothing. Get a real id from the app rather than inventing one — read the drawer
with `mcp__dart__widget_inspector(command: "get_widget_tree", summaryOnly: true)`
— and confirm arrival from `location` and `view`, not from `last` alone.

`view` is live; `location` is history. Tapping a tab moves `view` and leaves
`location` alone, by design — only a navigation records an entry. Use `view` to
confirm which tab you are on.

The field is never autofocused (it would swallow keystrokes meant for the
terminal), so the `tap` is required — and required *every time*, because
submitting releases focus again. Skipping it does not fail: `enter_text` and
`send_text_input_action` both report success, the field keeps its old contents,
and the state payload still reads `last: ok` from the previous command.

A project with no sessions is a special case worth knowing: opening one routes
to the New Session surface no matter what `surface=` asked for, because the
workspace bootstrap sends you there to pick an agent. A `view=` on that link is
not lost — it parks until a workspace mounts for that same project and applies
then, so the tab you named appears once the first session starts.

#### The grammar

```
antgrid://nav/local/<projectId>[?query]
antgrid://nav/remote/<machineUuid>/<projectId>[?query]
antgrid://nav/agent/<agentDeviceId>[?query]
antgrid://nav/settings[?section=<section>]
antgrid://nav/devices
```

Query params (all optional, order-independent):

| Param | Values | Applies to |
|---|---|---|
| `surface` | `workspace`, `newSession`, `appSettings`, `remoteDevices` | project targets; defaults to `workspace` |
| `view` | `terminals`, `files`, `git`, `preview`, `handler` | project targets — the workspace tab to open |
| `session` | a session id | project targets — which session to activate |
| `file` | a path **relative to the session's checkout** | project targets — opens it in the explorer |
| `section` | `billing`, `appearance`, `uiSize`, `accessibility`, `privacy`, `help`, `account` | `settings`, or any target with `surface=appSettings` |

`antgrid://nav/agent/<agentDeviceId>` is the legacy registration-id form; prefer
`remote/<machineUuid>/<projectId>` for a machine you reached over the relay.

Three failure modes, all worth knowing:

- An unrecognised `view` / `section` **value** names no destination and is
  dropped — you get `last: ok` and no tab change.
- An unrecognised `surface` value is **not** dropped: it falls back to
  `workspace`, which is a real navigation. A typo there moves you somewhere you
  did not ask for, so read `location` back rather than trusting `last`.
- A malformed **structure** — a foreign scheme, a missing path segment, or a
  `file=` that is absolute or contains `..` — refuses the whole link, and
  `last` reports the error.

Run `mcp__dart__flutter_driver_command(command: "get_text", ...)` on `ab.nav.state`
whenever you want the current location; it needs no navigation first.

The console only exists under `target: "test_driver/driver_main.dart"` (it is
gated on `kDebugMode` and a flag that entrypoint sets), so an app launched any
other way has no `ab.nav.command` to tap.

### Interact: tap through the tree (fallback)

For anything the grammar cannot name — buttons, menus, dialogs, list rows —
inspect before interacting:

```
# 1. See what's on screen
mcp__dart__flutter_driver_command(command: "screenshot")

# 2. Find the widget you want to interact with
mcp__dart__widget_inspector(command: "get_widget_tree")

# 3. Interact
mcp__dart__flutter_driver_command(command: "tap", finderType: "ByText", text: "Files")

# 4. Wait for navigation to complete
mcp__dart__flutter_driver_command(command: "waitFor", finderType: "ByType", type: "FileExplorerScreen")

# 5. Verify result
mcp__dart__flutter_driver_command(command: "screenshot")
```

### Debug a Visual Issue

```
# 1. Screenshot to see the problem
mcp__dart__flutter_driver_command(command: "screenshot")

# 2. Inspect the widget tree around the problem area
mcp__dart__flutter_driver_command(
  command: "get_diagnostics_tree",
  diagnosticsType: "widget",
  finderType: "ByType",
  type: "Scaffold",
  subtreeDepth: "4",
  includeProperties: "true"
)

# 3. Check for runtime errors
mcp__dart__get_runtime_errors()

# 4. Check logs for clues — no MCP tool serves these. `print`/stdout goes to the
#    `flutter run` output you backgrounded; AbLog goes to ~/.antgrid-dev/app.log
#    (host.log beside it for the bridge).

# 5. For render issues, inspect the render tree
mcp__dart__flutter_driver_command(
  command: "get_diagnostics_tree",
  diagnosticsType: "renderObject",
  finderType: "ByType",
  type: "Scaffold",
  subtreeDepth: "3"
)
```

## Widget Finder Reference

Ordered by reliability (prefer top options):

| Finder | Params | When to Use |
|--------|--------|-------------|
| `ByValueKey` | `keyValueString`, `keyValueType` | Best — stable across text/theme changes. Requires `Key('id')` in code. |
| `ByText` | `text` | Good — for buttons, labels, nav items. Breaks if text changes. |
| `BySemanticsLabel` | `label` | Good — for accessible widgets. Use `isRegExp: "true"` for partial match. |
| `ByType` | `type` | OK — use widget's `runtimeType` string. Fails if multiple instances exist. |
| `ByTooltipMessage` | `text` | Unreliable — can timeout. Use `ByText` instead when possible. |
| `Descendant` | `of`, `matching`, `matchRoot`, `firstMatchOnly` | Advanced — find widget inside another. |
| `Ancestor` | `of`, `matching`, `matchRoot`, `firstMatchOnly` | Advanced — find parent of a widget. |

### Disambiguating Multiple Matches

When `ByText` or `ByType` matches multiple widgets, use `Descendant` to scope:

```
mcp__dart__flutter_driver_command(
  command: "tap",
  finderType: "Descendant",
  of: {"finderType": "ByType", "type": "NavigationRail"},
  matching: {"finderType": "ByText", "text": "Files"},
  matchRoot: "false",
  firstMatchOnly: "true"
)
```

## Action Reference

| Action | Command | Notes |
|--------|---------|-------|
| Screenshot | `screenshot` | Returns image. Works on Windows despite `screenshot: false` in capabilities. |
| Hot reload | `mcp__dart__hot_reload()` | UI-only changes (widgets, styles, layouts) |
| Hot restart | `mcp__dart__hot_restart()` | State changes (new fields, providers, constructors) |
| Tap | `tap` | Requires finder. Simulates user tap. |
| Enter text | `enter_text` | Types into focused text field. Tap the field first. |
| Read text | `get_text` | Requires specific finder. Never use `ByType: Text` (too many matches). |
| Wait visible | `waitFor` | Blocks until widget appears. Default 5s timeout. |
| Wait gone | `waitForAbsent` | Blocks until widget disappears. |
| Scroll | `scroll` | Params: `dx`, `dy` (direction), `duration` (microseconds), `frequency` (Hz). |
| Widget tree | `mcp__dart__widget_inspector(command: "get_widget_tree")` | Full tree via DTD — large output. Its own tool, not a driver command. |
| Subtree | `get_diagnostics_tree` | Scoped inspection. Set `subtreeDepth` and `includeProperties`. |
| App logs | — | No MCP tool. Read the backgrounded `flutter run` output, or `~/.antgrid-dev/app.log` / `host.log`. |
| Errors | `get_runtime_errors()` | Flutter framework errors (overflow, assertions, etc.) |
| Health | `get_health` | Verify driver connection is alive |

## Error Recovery

| Error | Cause | Fix |
|-------|-------|-----|
| "Too many elements" | Finder matched multiple widgets | Use a more specific finder (add Key, use Descendant) |
| "Timed out waiting" | Widget not found within timeout | Check screenshot — widget may not be on screen. Navigate first. |
| "Driver extension not enabled" | Launched without driver entrypoint | Relaunch with `target: "test_driver/driver_main.dart"` |
| "Connection lost" | App crashed or was killed | Relaunch from Step 2. Request new DTD URI — never reuse old ones. |
| Hot reload failed | Incompatible change | Use `mcp__dart__hot_restart()` instead |

## Cleanup

**IMPORTANT:** killing `flutter run` does NOT kill the app executable, and the
app spawns a bridge host that outlives both. Account for all of them:

```bash
# Windows
tasklist | grep -iE "antgrid.exe|flutter_tools"
taskkill //PID <pid> //F
netstat -ano | grep ":8080"          # relay/agent, if started

# Linux / macOS
pkill -f "bundle/antgrid"            # the app executable
pkill -f "flutter_tools.snapshot"    # the flutter run supervisor
pkill -f "bridge/src/index"          # the spawned host
```

Match `pkill -f` patterns precisely: a loose one (`pkill -f Xvfb`) also matches
the shell running the command, which kills the caller mid-cleanup.
