#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
APP="$CODEX_HOME_DIR/CodexCenterNotify.app"
APP_CONTENTS="$APP/Contents"
CONFIG="$CODEX_HOME_DIR/config.toml"
BACKUP="$CODEX_HOME_DIR/config.toml.codex-center-notify.backup"
MODULE_CACHE="${TMPDIR:-/tmp}/codex-center-notify-module-cache"

if ! command -v swiftc >/dev/null 2>&1; then
  printf 'swiftc not found. Install Xcode Command Line Tools first.\n' >&2
  exit 1
fi

mkdir -p "$APP_CONTENTS/MacOS" "$CODEX_HOME_DIR/bin"
if [ -f "$CONFIG" ] && [ ! -e "$BACKUP" ]; then
  cp "$CONFIG" "$BACKUP"
fi

cp "$REPO_ROOT/Sources/Info.plist" "$APP_CONTENTS/Info.plist"
cp "$REPO_ROOT/Sources/CodexCenterNotifyApp.swift" "$CODEX_HOME_DIR/codex-center-notify-app.swift"
cp "$REPO_ROOT/Sources/CodexCenterNotifyLauncher.swift" "$CODEX_HOME_DIR/codex-center-notify-launcher.swift"
cp "$REPO_ROOT/scripts/test.sh" "$CODEX_HOME_DIR/test-codex-center-notify.sh"
cp "$REPO_ROOT/scripts/uninstall.sh" "$CODEX_HOME_DIR/uninstall-codex-center-notify.sh"

swiftc -module-cache-path "$MODULE_CACHE" \
  "$REPO_ROOT/Sources/CodexCenterNotifyApp.swift" \
  -o "$APP_CONTENTS/MacOS/CodexCenterNotify"
swiftc -module-cache-path "$MODULE_CACHE" \
  "$REPO_ROOT/Sources/CodexCenterNotifyLauncher.swift" \
  -o "$CODEX_HOME_DIR/bin/codex-center-notify"
chmod 755 "$APP_CONTENTS/MacOS/CodexCenterNotify" \
  "$CODEX_HOME_DIR/bin/codex-center-notify" \
  "$CODEX_HOME_DIR/test-codex-center-notify.sh" \
  "$CODEX_HOME_DIR/uninstall-codex-center-notify.sh"

printf 'Installed files under %s. config.toml was not changed.\n' "$CODEX_HOME_DIR"
printf 'Merge this into the user-level notify setting, preserving any existing callback:\n\n'
printf 'notify = ["%s/bin/codex-center-notify", "--app", "%s"]\n' "$CODEX_HOME_DIR" "$APP"
