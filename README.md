# aerie

Agent status in the MacBook notch — an aerie is an eagle's nest built high
on a cliff face, which is where your agents now roost, watching.

While any Claude Code session is working, a slim black widget hugs the notch:
a status dot (amber = working, pulsing red = needs input), the session count,
and a one-liner for the top-priority session (`vibelight: editing Daemon.swift`).
Click it to unfold a panel listing every live session — project, state, current
activity, time since last event. Click anywhere else (or Esc) to collapse.
When nothing is running the widget fades out entirely and clicks pass through.

## How it works

One binary, three roles:

- `aerie app` — the GUI (LaunchAgent-managed accessory app). Also runs the
  Unix-socket listener at `~/.aerie/daemon.sock` in-process.
- `aerie hook <Event>` — invoked by Claude Code hooks; reads the hook JSON on
  stdin, forwards a compact event over the socket (150 ms timeout, always
  exits 0 — a dead app never blocks Claude Code).
- `aerie install|uninstall|status|send|reset|quit` — control commands.

State machine: per-`session_id` rows (`idle`/`working`/`needsInput`) driven by
`SessionStart`, `UserPromptSubmit`, `PreToolUse` (the "doing X right now"
signal), `PostToolUse`, `Notification` (permission prompts → needsInput),
`Stop`, `SessionEnd`. TTL sweeps demote/reap sessions whose terminal died
without a `SessionEnd` (working→idle 15 m, needsInput→idle 2 h, idle→gone 1 h).
The collapsed summary always shows the most urgent session: blocked beats busy,
newer beats older.

Activity lines are derived purely from hook payloads (`tool_name` +
`tool_input`) — no transcript parsing, no API calls.

## Install

```sh
swift build -c release
cp .build/release/aerie ~/.local/bin/aerie
~/.local/bin/aerie install     # hooks into ~/.claude/settings.json (backup taken) + LaunchAgent
```

Hook entries are appended alongside any existing hooks (claude-rpc, vibelight,
…) — nothing is replaced. Restart running Claude Code sessions to pick up the
hooks. `aerie uninstall` reverses everything.

## Dev

```sh
swift test                     # SessionStore / ActivityFormatter / HooksPatcher
swift run aerie app            # run UI in foreground (logs to stderr)
scripts/demo.sh                # drive 3 fake sessions through the lifecycle
aerie send --session s1 --event PreToolUse --cwd /tmp/x --tool Edit --file /tmp/x/a.swift
aerie status
```

## Notes

- Sessions restarted in the same terminal get a fresh `session_id`; the stale
  row disappears on `SessionEnd` or via TTL.
- On a notchless display (clamshell + external) the widget renders as a small
  pill at the top-center of the main screen.
- If another notch app (NotchNook, boringNotch, Peninsula, TopNotch) is
  running, aerie logs a warning to `~/.aerie/aerie.log` and carries on — you
  probably want only one of them alive.
- Gotcha for future reference: `NSPanel.isFloatingPanel`'s setter resets
  `level`; set `level` after it or the panel sits under the menu bar and never
  receives clicks.
