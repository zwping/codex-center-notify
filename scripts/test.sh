#!/bin/sh
set -eu

CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
APP="$CODEX_HOME_DIR/CodexCenterNotify.app"
EXPECTED_SECONDS="${CODEX_CENTER_NOTIFY_EXPECTED_SECONDS:-5}"
LOG=$(mktemp "${TMPDIR:-/tmp}/codex-center-notify-test.XXXXXX")
trap 'rm -f "$LOG"' EXIT HUP INT TERM

if [ ! -x "$APP/Contents/MacOS/CodexCenterNotify" ]; then
  printf 'Notifier app not found: %s\n' "$APP" >&2
  exit 1
fi

rm -f "$LOG"
/usr/bin/open -g -W -n -a "$APP" --args --test "$LOG"
if [ ! -f "$LOG" ]; then
  printf 'FAIL: the test app did not write its result log.\n' >&2
  exit 1
fi
output=$(cat "$LOG")
printf '%s\n' "$output"

shown_pid=$(printf '%s\n' "$output" | awk '/^TEST_SHOWN / { for (i = 1; i <= NF; i++) if ($i ~ /^frontmost_pid=/) { sub("frontmost_pid=", "", $i); print $i; exit } }')
sound_started=$(printf '%s\n' "$output" | awk '/^TEST_SOUND / { for (i = 1; i <= NF; i++) if ($i ~ /^started=/) { sub("started=", "", $i); print $i; exit } }')
summary_line=$(printf '%s\n' "$output" | awk '/^TEST_SUMMARY / { print; exit }')
title_line=$(printf '%s\n' "$output" | awk '/^TEST_TITLE / { print; exit }')
source_line=$(printf '%s\n' "$output" | awk '/^TEST_SOURCE / { print; exit }')
source_rendered=$(printf '%s\n' "$source_line" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^rendered=/) { sub("rendered=", "", $i); print $i; exit } }')
title_chars=$(printf '%s\n' "$title_line" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^chars=/) { sub("chars=", "", $i); print $i; exit } }')
title_uses_reply=$(printf '%s\n' "$title_line" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^uses_reply=/) { sub("uses_reply=", "", $i); print $i; exit } }')
project_line=$(printf '%s\n' "$output" | awk '/^TEST_PROJECT / { print; exit }')
project_rendered=$(printf '%s\n' "$project_line" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^rendered=/) { sub("rendered=", "", $i); print $i; exit } }')
summary_chars=$(printf '%s\n' "$summary_line" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^chars=/) { sub("chars=", "", $i); print $i; exit } }')
summary_rendered=$(printf '%s\n' "$summary_line" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^rendered=/) { sub("rendered=", "", $i); print $i; exit } }')
focus_line=$(printf '%s\n' "$output" | awk '/^TEST_FOCUS / { print; exit }')
app_active=$(printf '%s\n' "$focus_line" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^active=/) { sub("active=", "", $i); print $i; exit } }')
panel_key=$(printf '%s\n' "$focus_line" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^panel_key=/) { sub("panel_key=", "", $i); print $i; exit } }')
window_visible=$(printf '%s\n' "$output" | awk '/^TEST_WINDOW / { for (i = 1; i <= NF; i++) if ($i ~ /^visible=/) { sub("visible=", "", $i); print $i; exit } }')
window_server_listed=$(printf '%s\n' "$output" | awk '/^TEST_WINDOW / { for (i = 1; i <= NF; i++) if ($i ~ /^server_listed=/) { sub("server_listed=", "", $i); print $i; exit } }')
policy_line=$(printf '%s\n' "$output" | awk '/^TEST_POLICY / { print; exit }')
closed_line=$(printf '%s\n' "$output" | awk '/^TEST_CLOSED / { print; exit }')
closed_pid=$(printf '%s\n' "$closed_line" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^frontmost_pid=/) { sub("frontmost_pid=", "", $i); print $i; exit } }')
elapsed=$(printf '%s\n' "$closed_line" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^elapsed=/) { sub("elapsed=", "", $i); print $i; exit } }')

if [ -z "$shown_pid" ] || [ -z "$closed_line" ] || [ -z "$elapsed" ]; then
  printf 'FAIL: test did not report both display and close events.\n' >&2
  exit 1
fi

if [ "$sound_started" != "1" ]; then
  printf 'FAIL: macOS did not start the Glass sound.\n' >&2
  exit 1
fi

if [ "$summary_chars" != "60" ] || [ "$summary_rendered" != "true" ]; then
  printf 'FAIL: expected a rendered 60-character summary; got %s.\n' "$summary_line" >&2
  exit 1
fi

if [ "$title_uses_reply" != "true" ] || [ "$title_chars" != "24" ]; then
  printf 'FAIL: expected the reply opening as a 24-character title; got %s.\n' "$title_line" >&2
  exit 1
fi

if [ "$source_rendered" != "true" ]; then
  printf 'FAIL: expected the Antigravity · Codex source label; got %s.\n' "$source_line" >&2
  exit 1
fi

if [ "$project_rendered" != "true" ]; then
  printf 'FAIL: project name was not rendered below the title.\n' >&2
  exit 1
fi

if [ "$window_visible" != "true" ]; then
  printf 'FAIL: AppKit did not report a visible panel.\n' >&2
  exit 1
fi

case "$policy_line" in
  *"raw=1"*"bundle=local.codex.center-notify"*) ;;
  *) printf 'FAIL: expected a registered accessory app; got %s.\n' "$policy_line" >&2; exit 1 ;;
esac

if [ "$window_server_listed" != "true" ]; then
  printf 'FAIL: WindowServer did not list the notifier window.\n' >&2
  exit 1
fi

if ! awk -v seconds="$elapsed" -v expected="$EXPECTED_SECONDS" 'BEGIN { exit !(seconds >= expected - 0.5 && seconds <= expected + 1.5) }'; then
  printf 'FAIL: expected about %s seconds, got %s seconds.\n' "$EXPECTED_SECONDS" "$elapsed" >&2
  exit 1
fi

if [ "$app_active" != "false" ] || [ "$panel_key" != "false" ]; then
  printf 'FAIL: notifier activated or made its panel key (active=%s, panel_key=%s).\n' "$app_active" "$panel_key" >&2
  exit 1
fi

if [ "$shown_pid" = "$closed_pid" ]; then
  printf 'PASS: panel was listed; duration %s seconds; Glass started; notifier stayed inactive and frontmost PID remained %s.\n' "$elapsed" "$shown_pid"
else
  printf 'PASS: panel was listed; duration %s seconds; Glass started; notifier stayed inactive and non-key (other app PID changed %s -> %s).\n' "$elapsed" "$shown_pid" "$closed_pid"
fi
