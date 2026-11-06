#!/bin/sh
set -eu

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
LAUNCHER="$CODEX_HOME_DIR/bin/codex-center-notify"
CONFIG="$CODEX_HOME_DIR/config.toml"

if [ -f "$CONFIG" ] && grep -Fq "$LAUNCHER" "$CONFIG"; then
  printf 'config.toml still references the notifier. Restore/remove that notify entry first.\n' >&2
  printf 'Backup: %s\n' "$CODEX_HOME_DIR/config.toml.codex-center-notify.backup" >&2
  exit 1
fi

rm -rf "$CODEX_HOME_DIR/CodexCenterNotify.app"
rm -f "$LAUNCHER" \
  "$CODEX_HOME_DIR/codex-center-notify-app.swift" \
  "$CODEX_HOME_DIR/codex-center-notify-launcher.swift" \
  "$CODEX_HOME_DIR/test-codex-center-notify.sh" \
  "$CODEX_HOME_DIR/uninstall-codex-center-notify.sh"
rmdir "$CODEX_HOME_DIR/bin" 2>/dev/null || true

printf 'Notifier binaries and sources removed. Config and backup were left untouched.\n'
