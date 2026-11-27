#!/usr/bin/env bash
set -euo pipefail

# Runs tmux-resurrect save.sh and backfills `state` when triggered on client-detached
# (where #{client_session} is empty because no client is attached anymore).

RESURRECT_SAVE="${HOME}/.config/tmux/plugins/tmux-resurrect/scripts/save.sh"
RESURRECT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
LAST_FILE="${RESURRECT_DIR}/last"

latest_session=""
prev_session=""
while IFS='|' read -r _ name; do
	[ -n "$name" ] || continue
	if [ -z "$latest_session" ]; then
		latest_session="$name"
	elif [ -z "$prev_session" ]; then
		prev_session="$name"
		break
	fi
done < <(tmux list-sessions -F '#{session_last_attached}|#{session_name}' 2>/dev/null | sort -t'|' -k1,1nr)

"$RESURRECT_SAVE" quiet

[ -e "$LAST_FILE" ] || exit 0
target="$(readlink -f "$LAST_FILE" 2>/dev/null || printf '%s\n' "$LAST_FILE")"
[ -f "$target" ] || exit 0

if [ -n "$latest_session" ] && grep -qE '^state[[:space:]]*$' "$target"; then
	tmp_file="${target}.tmp.$$"
	awk -v cur="$latest_session" -v prev="$prev_session" '
		/^state[[:space:]]*$/ {
			printf "state\t%s\t%s\n", cur, prev
			next
		}
		{ print }
	' "$target" >"$tmp_file"
	mv -f "$tmp_file" "$target"
fi
