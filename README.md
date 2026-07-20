# aerie

Agent status in the MacBook notch — an aerie is an eagle's nest built high
on a cliff face, which is where your agents now roost, watching.

![aerie demo](docs/aerie-demo.gif)

aerie watches every AI coding agent running on your machine — **Claude Code,
Codex CLI, Antigravity CLI, Cursor, opencode, and Pi** — and lives in the
notch:

- **Idle**: invisible. The widget tucks behind the physical notch; clicks
  pass through.
- **Agents working**: the notch grows wings — an overlapped badge stack of
  each running tool's logo on the left, and on the right either the solo
  session's running duration or, for a fleet, the session count.
- **Agent blocked** (permission prompt): that tool's badge pulses red and
  the right wing shows the blocked count (`1!`). Only genuine blockers
  pulse — an agent that merely *finished* never flashes at you.
- **Agent finished**: a 5-second completion linger — green check, tool
  badge, total runtime — then the notch exhales back to invisible.

Click the notch (or enable hover in settings) to expand the panel: one row
per session with tool badge, project, **model tag**, current activity
(derived from hook payloads — "editing Daemon.swift", "running: pytest"),
and age. A collapsed **RECENT** section lists what finished lately. The
gear opens settings; the first launch opens a setup wizard that installs
hooks into whichever tools you enable.

## How it works

One binary, three roles:

- `aerie app` — the GUI (LaunchAgent-managed accessory app). Also runs the
  Unix-socket listener at `~/.aerie/daemon.sock` in-process. Socket reads
  happen on a dedicated I/O queue with hard size/deadline caps, so a slow
  or buggy client can never wedge the daemon.
- `aerie hook <Event> [--source <tool>]` — invoked by each tool's hook
  system; reads the hook JSON on stdin, forwards a compact event over the
  socket (150 ms timeout, always exits 0 — a dead app never blocks an
  agent CLI).
- `aerie install | uninstall | status | doctor | send | reset | quit`.

**Per-tool integration** (all opt-in via the wizard or settings):

| tool | mechanism |
|---|---|
| Claude Code | hook entries merged into `~/.claude/settings.json` |
| Codex CLI | `~/.codex/hooks.json` (trust once via `/hooks` in codex) |
| Antigravity CLI | `~/.gemini/antigravity-cli/hooks.json` |
| Cursor (IDE + CLI) | `~/.cursor/hooks.json` (shared schema) |
| opencode | generated Bun plugin at `~/.config/opencode/plugins/aerie.js` |
| Pi | generated extension at `~/.pi/agent/extensions/aerie-status.ts` |

JSON configs are merged append-only — existing hooks are preserved, a
timestamped backup is taken first, malformed configs abort the install
rather than being overwritten, and writes go *through* symlinks so
dotfiles-managed configs stay symlinked. Model names come from hook
payloads where available (Codex, Cursor) or the transcript tail (Claude).

**State machine**: per-`session_id` rows (`idle` / `working` /
`needsInput`) driven by each tool's lifecycle events, mapped onto one
vocabulary (`SessionStart`, `UserPromptSubmit`, `PreToolUse`,
`PostToolUse`, `Notification`, `Stop`, `SessionEnd`). TTL sweeps demote or
reap sessions whose terminal died without a goodbye (working→idle 15 m,
needsInput→idle 2 h, idle→recents 1 h). Ended sessions land in a 20-entry
recents ring — summaries only, never transcripts or commands.

## Install

```sh
swift build -c release
cp .build/release/aerie ~/.local/bin/aerie
~/.local/bin/aerie install     # LaunchAgent + Claude Code hooks; wizard handles the rest
```

Restart running agent sessions to pick up the hooks. `aerie uninstall`
reverses everything. When something isn't reporting:

```sh
aerie doctor
```

prints a per-tool table — detected? hooks installed? events actually seen?
— plus the ages of the last captured hook payloads
(`~/.aerie/last-payloads/`, useful when a tool changes its schema).

## Dev

```sh
swift test                     # SessionStore / ActivityFormatter / HooksPatcher
swift run aerie app            # run UI in foreground (logs to stderr)
scripts/demo.sh                # drive 3 fake sessions through the lifecycle
aerie send --session s1 --event PreToolUse --source codex \
  --cwd /tmp/x --tool shell --command "pytest" --model gpt-5.3-codex
aerie status
```

After rebuilding while the app runs: `rm ~/.local/bin/aerie && cp ...` —
overwriting a running binary in place gets subsequent hook invocations
killed by code-signature invalidation.

## Notch geometry notes (hard-won)

- `NSPanel.isFloatingPanel`'s setter resets `level`; set `level` after it,
  or the panel sits under the menu bar and never receives clicks.
- The physical notch height is `safeAreaInsets.top` (38 pt here); the menu
  bar is 1 pt taller, and that sliver of menu bar under the notch is real —
  don't paint over it. The hardware edge can sit on a *half-point*
  boundary; the seam offset is tunable in 0.5 pt steps from settings.
- `safeAreaInsets.top` reads **0 inside fullscreen spaces** — cache the
  geometry or a mid-fullscreen reposition rebuilds you as a notchless
  pill.
- Corner radii: 8 / 12 with tight two-cubic curvature, tuned against
  photos of the hardware (screenshots can't capture the notch — the
  framebuffer extends behind it).
- Keep the interactive hit area exactly on the visible widget. Slop below
  the pill or a hit rect taller than the expanded card silently eats
  clicks meant for other apps' windows.

## Notes

- On a notchless display (clamshell + external) the widget renders as a
  small top-center pill.
- Hide-in-fullscreen is on by default (detected via the window server's
  fullscreen-backdrop window — menu-bar heuristics don't work).
- If another notch app (NotchNook, boringNotch, Peninsula, TopNotch) is
  running, aerie logs a warning and carries on — you probably want only
  one of them alive.
- `~/.aerie` is `0700`; the socket, log, and payload snapshots are `0600`.
