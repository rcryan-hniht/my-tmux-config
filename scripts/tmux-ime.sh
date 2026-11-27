#!/usr/bin/env bash
set -euo pipefail

# Reports and watches fcitx5 input method state (VI / EN) for tmux status bar.

PID_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-ime.pid"

current_label() {
	local im
	im="$(fcitx5-remote -n 2>/dev/null || true)"
	case "$im" in
		lotus* | unikey* | bamboo* | telex* | vni*) printf 'VI\n' ;;
		*) printf 'EN\n' ;;
	esac
}

sync_once() {
	local lbl
	lbl="$(current_label)"
	tmux set -gq @ime_label "$lbl" 2>/dev/null || true
	tmux refresh-client -S 2>/dev/null || true
}

watch_loop() {
	mkdir -p "$(dirname "$PID_FILE")"
	if [ -f "$PID_FILE" ]; then
		local old_pid
		old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
		if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
			exit 0
		fi
	fi
	printf '%s\n' "$$" >"$PID_FILE"
	trap 'rm -f "$PID_FILE"' EXIT INT TERM

	local prev="" cur=""
	while tmux list-sessions >/dev/null 2>&1; do
		cur="$(current_label)"
		if [ "$cur" != "$prev" ]; then
			tmux set -gq @ime_label "$cur" 2>/dev/null || true
			tmux refresh-client -S 2>/dev/null || true
			prev="$cur"
		fi
		sleep 0.25
	done
}

case "${1:-}" in
	--sync) sync_once ;;
	--watch) watch_loop ;;
	*) current_label ;;
esac
