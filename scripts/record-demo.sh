#!/bin/zsh
# Records a fresh docs/aerie-demo.gif: hides every other window, drives two
# fake sessions (a Claude session on aerie, a Codex session on a webapp)
# through a real approval flow using synthetic mouse clicks, screen-records
# it, and converts the result to a GIF.
#
# Requirements:
#   - ffmpeg (brew install ffmpeg)
#   - swift (Xcode Command Line Tools)
#   - Accessibility permission granted to whatever app runs this script
#     (System Settings > Privacy & Security > Accessibility) — needed both
#     for the synthetic clicks and for hiding/restoring other app windows.
#
# Usage: scripts/record-demo.sh [path-to-aerie-binary]
#
# The click coordinates below are tuned to THIS script's specific content
# (two sessions, one approval card at a time) on a 1800x1169-point display.
# If the panel layout changes, or the demo narrative changes shape, or
# you're on a different resolution, re-measure: run the script up to the
# relevant `click`, screenshot instead of clicking, and find the button
# pill's center — screencapture -R takes logical points but outputs 2x
# physical pixels, so halve any pixel measurement before using it here.
set -e

AERIE="${1:-$HOME/.local/bin/aerie}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_GIF="$REPO_ROOT/docs/aerie-demo.gif"
RAW_MOV="/tmp/aerie-demo-raw.mov"
CLICK_SWIFT="/tmp/aerie-demo-click.swift"

# --- click coordinates (logical points, full-screen origin top-left) ---
EXPAND_XY=(900 19)
COLLAPSE_XY=(900 15)
DENY_XY=(700 145)
ALLOW_XY=(771 146)

command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)"; exit 1; }
command -v swift >/dev/null || { echo "swift not found (install Xcode Command Line Tools)"; exit 1; }

cat > "$CLICK_SWIFT" <<'EOF'
import CoreGraphics
import Foundation
let args = CommandLine.arguments
guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: click.swift <x> <y>\n".utf8))
    exit(1)
}
let point = CGPoint(x: x, y: y)
func post(_ type: CGEventType) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}
post(.mouseMoved)
usleep(200_000)
post(.leftMouseDown)
usleep(90_000)
post(.leftMouseUp)
EOF

click() { swift "$CLICK_SWIFT" "$1" "$2" >/dev/null 2>&1; }

SCREEN_DEVICE=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 \
    | grep "Capture screen" | head -1 | sed -E 's/.*\[([0-9]+)\].*/\1/')
[ -n "$SCREEN_DEVICE" ] || { echo "couldn't find an avfoundation screen-capture device"; exit 1; }

VISIBLE_APPS=$(osascript -e 'tell application "System Events" to get name of every process whose visible is true and name is not "Finder"' 2>/dev/null)
restore_windows() {
    IFS=',' read -rA apps <<< "$VISIBLE_APPS"
    for app in "${apps[@]}"; do
        trimmed=$(echo "$app" | sed 's/^ *//;s/ *$//')
        [ -n "$trimmed" ] && osascript -e "tell application \"System Events\" to set visible of process \"$trimmed\" to true" >/dev/null 2>&1
    done
}
trap restore_windows EXIT

launchctl kickstart -k gui/$(id -u)/sh.schmitt.aerie >/dev/null 2>&1; sleep 2
"$AERIE" reset >/dev/null   # clear this shell's own row; it won't re-register until its next tool call

echo "starting two sessions (claude on aerie, codex on webapp)…"
"$AERIE" send --session c1 --event SessionStart --cwd "$HOME/src/aerie" >/dev/null
"$AERIE" send --session c1 --event PreToolUse --cwd "$HOME/src/aerie" --tool Edit --file /x/Daemon.swift --model claude-fable-5 >/dev/null
"$AERIE" send --session c2 --event PreToolUse --source codex --cwd /tmp/webapp --tool bash --command "bun test" >/dev/null

echo "hiding other windows…"
osascript -e 'tell application "System Events" to set visible of every process whose visible is true and name is not "Finder" to false' >/dev/null 2>&1
sleep 1.5

echo "recording…"
rm -f "$RAW_MOV"
ffmpeg -y -f avfoundation -framerate 30 -pixel_format bgr0 -capture_cursor 1 -i "${SCREEN_DEVICE}:none" \
    -t 28 -c:v libx264rgb -preset ultrafast -crf 12 "$RAW_MOV" >/dev/null 2>&1 &
FFMPEG_PID=$!
sleep 2
click "${EXPAND_XY[@]}"
sleep 2

echo "approval #1: swift command → deny"
(echo '{"session_id":"c1","cwd":"'"$HOME"'/src/aerie","tool_name":"Bash","tool_input":{"command":"rm -rf .build && swift build -c release"}}' \
    | "$AERIE" hook PreToolUse --approve --source claude >/dev/null) &
sleep 2.5
click "${DENY_XY[@]}"
sleep 2.5

echo "approval #2: git push → allow"
(echo '{"session_id":"c1","cwd":"'"$HOME"'/src/aerie","tool_name":"Bash","tool_input":{"command":"git push origin main"}}' \
    | "$AERIE" hook PreToolUse --approve --source claude >/dev/null) &
sleep 2.5
click "${ALLOW_XY[@]}"
sleep 2
click "${COLLAPSE_XY[@]}"
sleep 1.5

"$AERIE" send --session c2 --event SessionEnd --source codex >/dev/null
"$AERIE" send --session c1 --event Stop >/dev/null      # → linger (claude badge)
sleep 7
"$AERIE" send --session c1 --event SessionEnd >/dev/null
sleep 1

wait "$FFMPEG_PID" 2>/dev/null || true
echo "converting to gif…"
ffmpeg -y -i "$RAW_MOV" \
    -vf "crop=1480:840:1060:0,scale=740:420:flags=lanczos,fps=20,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=3" \
    "$OUT_GIF"

echo "done: $OUT_GIF"
