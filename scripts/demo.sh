#!/bin/zsh
# Drive three fake sessions through the full lifecycle to eyeball the UI.
# Usage: scripts/demo.sh [path-to-aerie-binary]
set -e
AERIE="${1:-$HOME/.local/bin/aerie}"

send() { "$AERIE" send "$@" >/dev/null; }

echo "starting three sessions…"
send --session demo1 --event SessionStart --cwd "$HOME/src/vibelight"
send --session demo2 --event SessionStart --cwd "$HOME/src/aerie"
send --session demo3 --event SessionStart --cwd /tmp/scratch
sleep 1

echo "all working…"
send --session demo1 --event PreToolUse --cwd "$HOME/src/vibelight" --tool Edit --file /x/Daemon.swift
send --session demo2 --event PreToolUse --cwd "$HOME/src/aerie" --tool Bash --command "swift test" --description "Run the tests"
send --session demo3 --event PreToolUse --cwd /tmp/scratch --tool Grep --pattern "TODO"
sleep 2

echo "demo3 hits a real approval prompt (Deny/Allow card, dot pulses red)…"
printf '%s' '{"session_id":"demo3","cwd":"/tmp/scratch","tool_name":"Bash","tool_input":{"command":"rm -rf old-logs/"},"permission_mode":"default"}' \
    | "$AERIE" hook PreToolUse --approve --source claude >/dev/null &
sleep 4

echo "approving…"
"$AERIE" approve >/dev/null
sleep 1

echo "demo3 resumes, demo1 finishes…"
send --session demo3 --event PostToolUse --cwd /tmp/scratch
send --session demo1 --event Stop --cwd "$HOME/src/vibelight"
sleep 2

"$AERIE" status
echo "ending all sessions (widget should fade out)…"
send --session demo1 --event SessionEnd
send --session demo2 --event SessionEnd
send --session demo3 --event SessionEnd
echo "done"
