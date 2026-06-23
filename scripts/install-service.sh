#!/usr/bin/env bash
# Install Craig's Claude Counter as a macOS LaunchAgent so it starts at login
# and restarts if it ever dies. Generates the plist from this checkout + your
# node path, so there is nothing to hand-edit.
set -euo pipefail

LABEL="com.craigvg.craigs-claude-counter"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE="$(command -v node || true)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -z "$NODE" ]; then echo "node not found on PATH. Install Node 18+ first." >&2; exit 1; fi
mkdir -p "$DIR/logs" "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$NODE</string><string>$DIR/src/server.mjs</string></array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DIR/logs/server.log</string>
  <key>StandardErrorPath</key><string>$DIR/logs/server.err.log</string>
</dict>
</plist>
PLIST

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"
sleep 2
PORT="${CLAUDE_USAGE_PORT:-4319}"
if curl -fsS -m 5 "http://127.0.0.1:$PORT/api/usage" >/dev/null 2>&1; then
  echo "Installed and running: http://127.0.0.1:$PORT"
else
  echo "Installed. Starting up — check $DIR/logs/server.log if it doesn't come up."
fi
