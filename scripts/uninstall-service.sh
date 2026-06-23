#!/usr/bin/env bash
# Stop and remove the Craig's Claude Counter LaunchAgent.
set -euo pipefail
LABEL="com.craigvg.craigs-claude-counter"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "Removed $LABEL. (Your account tokens remain in the Keychain; remove accounts from the app to clear them.)"
