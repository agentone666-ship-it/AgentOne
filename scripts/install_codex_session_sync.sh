#!/bin/zsh
set -eu

SCRIPT_DIR="${0:A:h}"
CODEX_DATA_DIR="${CODEX_HOME:-$HOME/.codex}"
TOOLS_DIR="$CODEX_DATA_DIR/tools"
BACKUP_DIR="$CODEX_DATA_DIR/backups/session-catalog-unified-$(date +%Y%m%d-%H%M%S)"
AGENT_FILE="$HOME/Library/LaunchAgents/com.agentone.codex-session-sync.plist"

mkdir -p "$TOOLS_DIR" "$BACKUP_DIR" "${AGENT_FILE:h}"
cp "$CODEX_DATA_DIR/state_5.sqlite" "$BACKUP_DIR/state_5.sqlite"
cp "$CODEX_DATA_DIR/sqlite/codex-dev.db" "$BACKUP_DIR/codex-dev.db"
install -m 755 "$SCRIPT_DIR/sync_codex_sessions.sh" "$TOOLS_DIR/sync_codex_sessions.sh"

"$TOOLS_DIR/sync_codex_sessions.sh"

plutil -create xml1 "$AGENT_FILE"
plutil -insert Label -string 'com.agentone.codex-session-sync' "$AGENT_FILE"
plutil -insert ProgramArguments -json "[\"$TOOLS_DIR/sync_codex_sessions.sh\"]" "$AGENT_FILE"
plutil -insert RunAtLoad -bool true "$AGENT_FILE"
plutil -insert StartInterval -integer 30 "$AGENT_FILE"
plutil -insert StandardOutPath -string "$CODEX_DATA_DIR/log/session-catalog-sync.log" "$AGENT_FILE"
plutil -insert StandardErrorPath -string "$CODEX_DATA_DIR/log/session-catalog-sync.error.log" "$AGENT_FILE"

plutil -lint "$AGENT_FILE"
launchctl bootout "gui/$(id -u)/com.agentone.codex-session-sync" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_FILE"
launchctl kickstart -k "gui/$(id -u)/com.agentone.codex-session-sync"

echo "Backup: $BACKUP_DIR"
echo "Installed: $AGENT_FILE"
