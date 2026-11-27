#!/usr/bin/env bash
set -euo pipefail

# Delete tmux-resurrect history older than 48 hours (172800 seconds)
# and optionally kill detached sessions idle for more than 48 hours.

TTL_SECONDS=$((48 * 3600))
RESURRECT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
LAST_FILE="$RESURRECT_DIR/last"
NOW="$(date +%s)"

cleanup_saved_history() {
	[ -d "$RESURRECT_DIR" ] || return 0

	if [ -e "$LAST_FILE" ]; then
		local mtime age
		mtime="$(stat -L -c %Y "$LAST_FILE" 2>/dev/null || echo 0)"
		age=$((NOW - mtime))
		if [ "$age" -gt "$TTL_SECONDS" ]; then
			rm -f "$RESURRECT_DIR"/tmux_resurrect_*.txt \
				"$LAST_FILE" \
				"$RESURRECT_DIR/pane_contents.tar.gz"
			rm -rf "$RESURRECT_DIR/save" "$RESURRECT_DIR/restore"
			return 0
		fi
	fi

	# Prune individual backup snapshots older than 48h (2880 minutes),
	# excluding whatever `last` currently points to.
	local last_target=""
	if [ -L "$LAST_FILE" ]; then
		last_target="$(readlink -f "$LAST_FILE" 2>/dev/null || true)"
	fi
	while IFS= read -r -d '' file; do
		if [ -n "$last_target" ] && [ "$(readlink -f "$file" 2>/dev/null || true)" = "$last_target" ]; then
			continue
		fi
		rm -f "$file"
	done < <(find "$RESURRECT_DIR" -maxdepth 1 -type f -name 'tmux_resurrect_*.txt' -mmin +2880 -print0 2>/dev/null)
}

prune_detached_sessions() {
	tmux list-sessions -F '#{session_name}|#{session_attached}|#{session_activity}' 2>/dev/null |
		while IFS='|' read -r name attached activity; do
			[ -n "$name" ] || continue
			[ "${attached:-0}" -eq 0 ] 2>/dev/null || continue
			[ -n "$activity" ] || continue
			local idle=$((NOW - activity))
			if [ "$idle" -gt "$TTL_SECONDS" ]; then
				tmux kill-session -t "$name" 2>/dev/null || true
			fi
		done
}

cleanup_saved_history

if [ "${1:-}" = "--prune-sessions" ]; then
	prune_detached_sessions
fi
