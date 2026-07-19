#!/bin/zsh
# Drive three fake sessions through the full lifecycle to eyeball the UI.
# Usage: scripts/demo.sh [path-to-eaves-binary]
set -e
EAVES="${1:-$HOME/.local/bin/eaves}"

send() { "$EAVES" send "$@" >/dev/null; }

echo "starting three sessions…"
send --session demo1 --event SessionStart --cwd "$HOME/src/vibelight"
send --session demo2 --event SessionStart --cwd "$HOME/src/eaves"
send --session demo3 --event SessionStart --cwd /tmp/scratch
sleep 1

echo "all working…"
send --session demo1 --event PreToolUse --cwd "$HOME/src/vibelight" --tool Edit --file /x/Daemon.swift
send --session demo2 --event PreToolUse --cwd "$HOME/src/eaves" --tool Bash --command "swift test" --description "Run the tests"
send --session demo3 --event PreToolUse --cwd /tmp/scratch --tool Grep --pattern "TODO"
sleep 2

echo "demo3 hits a permission prompt (dot should pulse red, summary flips)…"
send --session demo3 --event Notification --cwd /tmp/scratch \
    --notification-type permission_prompt --message "Claude needs your permission to use Bash"
sleep 3

echo "demo3 resumes, demo1 finishes…"
send --session demo3 --event PostToolUse --cwd /tmp/scratch
send --session demo1 --event Stop --cwd "$HOME/src/vibelight"
sleep 2

"$EAVES" status
echo "ending all sessions (widget should fade out)…"
send --session demo1 --event SessionEnd
send --session demo2 --event SessionEnd
send --session demo3 --event SessionEnd
echo "done"
