#!/usr/bin/env bash
set -euo pipefail

# Fullscreen multi-pane ATK68 V2 RGB Studio popup (prefix + A), using an isolated
# inner tmux server (same pattern as tmux-clock.sh / tmux-agents.sh) so each pane
# runs as its own independent process with zero full-screen re-render flicker:
#   - Left pane (~28%):        Event-driven 4-tab Control Deck (0 idle redraws)
#   - Right top pane (~68%h):  Continuous 28fps Staggered 68-Key ATK68 V2 Board (in-place updates)
#   - Right bottom pane (~10): Event-driven Live Sliders, USB Telemetry & Quick Actions

SCRIPT_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
PY_SCRIPT="${SCRIPT_DIR}/tmux-atk.py"
CAVA_LAUNCH="$HOME/.config/cava/launch.sh"

OUTER_TMUX="${TMUX:-}"
STTY_SZ="$(stty size </dev/tty 2>/dev/null || true)"
if [ -n "$STTY_SZ" ]; then
	read -r INNER_H INNER_W <<<"$STTY_SZ"
else
	INNER_H="$(tput lines 2>/dev/null || echo 38)"
	INNER_W="$(tput cols 2>/dev/null || echo 154)"
fi
[ "${INNER_W:-0}" -gt 0 ] 2>/dev/null || INNER_W=154
[ "${INNER_H:-0}" -gt 0 ] 2>/dev/null || INNER_H=38

CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-atk"
mkdir -p -m 700 "$CACHE_BASE"
RUN_DIR="${CACHE_BASE}/run.$$"
mkdir -p -m 700 "$RUN_DIR"

SOCK="popup-atk-$$"
SOCK_DIR="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
TMP_CONF="${RUN_DIR}/tmux.conf"

_ATK_SOCK="$SOCK"
_ATK_SOCK_DIR="$SOCK_DIR"
_ATK_RUN_DIR="$RUN_DIR"

cleanup_atk() {
	if [ -n "${_ATK_RUN_DIR:-}" ]; then
		[ -p "${_ATK_RUN_DIR}/board.fifo" ] && printf 'quit\n' 1<>"${_ATK_RUN_DIR}/board.fifo" 2>/dev/null || true
		[ -p "${_ATK_RUN_DIR}/tele.fifo" ] && printf 'quit\n' 1<>"${_ATK_RUN_DIR}/tele.fifo" 2>/dev/null || true
		[ -p "${_ATK_RUN_DIR}/ctl.fifo" ] && printf 'quit\n' 1<>"${_ATK_RUN_DIR}/ctl.fifo" 2>/dev/null || true
	fi
	[ -n "${_ATK_SOCK:-}" ] && env -u TMUX tmux -L "$_ATK_SOCK" kill-server 2>/dev/null || true
	[ -n "${_ATK_SOCK:-}" ] && [ -n "${_ATK_SOCK_DIR:-}" ] && rm -f "${_ATK_SOCK_DIR}/${_ATK_SOCK}" 2>/dev/null || true
	[ -n "${_ATK_RUN_DIR:-}" ] && rm -rf "$_ATK_RUN_DIR" 2>/dev/null || true
}
trap cleanup_atk EXIT INT TERM HUP

mkfifo -m 600 "${RUN_DIR}/ctl.fifo" "${RUN_DIR}/board.fifo" "${RUN_DIR}/tele.fifo"

LEFT_W=$(( INNER_W * 28 / 100 ))
[ "$LEFT_W" -lt 36 ] && LEFT_W=36
[ "$LEFT_W" -gt 44 ] && LEFT_W=44
RIGHT_W=$(( INNER_W - LEFT_W - 1 ))
TELE_H=$(( INNER_H * 30 / 100 ))
[ "$TELE_H" -lt 9 ] && TELE_H=9
[ "$TELE_H" -gt 11 ] && TELE_H=11

BORDER_FG="$(tmux display-message -p '#{E:@theme-surface}' 2>/dev/null || true)"
if ! [[ "$BORDER_FG" =~ ^#[0-9a-fA-F]{6}$ ]]; then
	THEME_MODE="$("$CAVA_LAUNCH" --print-theme 2>/dev/null || echo dark)"
	if [ "$THEME_MODE" = "light" ]; then
		BORDER_FG="#c8c8c8"
	else
		BORDER_FG="#262626"
	fi
fi

cat >"$TMP_CONF" <<EOF
set -g default-shell /bin/sh
set -g default-terminal 'xterm-256color'
set -as terminal-overrides ',*:Tc'
set -s extended-keys on
set -as terminal-features ',*:extkeys'
set -g status off
set -g mouse off
set -sg escape-time 10
set -g focus-events on
set -g pane-border-style 'fg=${BORDER_FG}'
set -g pane-active-border-style 'fg=${BORDER_FG}'
set -g pane-border-lines single
bind-key -n C-q kill-server
set-hook -g pane-exited 'if-shell -F "#{==:#{hook_pane},#{@ctrl_pane}}" "kill-server" "if-shell -F \"#{m:* #{@ctrl_pane} *, #{W:#{P:#{pane_id} }} }\" \"select-pane -t #{@ctrl_pane}\" \"kill-server\""'
EOF

printf -v CMD_CTRL  'exec env TMUX=%q python3 %q --pane-controls %q %q' "$OUTER_TMUX" "$PY_SCRIPT" "$RUN_DIR" "$SOCK"
printf -v CMD_BOARD 'exec env TMUX=%q python3 %q --pane-board %q'       "$OUTER_TMUX" "$PY_SCRIPT" "$RUN_DIR"
printf -v CMD_TELE  'exec env TMUX=%q python3 %q --pane-telemetry %q'   "$OUTER_TMUX" "$PY_SCRIPT" "$RUN_DIR"

P_CTRL="$(env -u TMUX tmux -L "$SOCK" -f "$TMP_CONF" new-session -d -P -F '#{pane_id}' -x "$INNER_W" -y "$INNER_H" -s atk "$CMD_CTRL")"
P_BOARD="$(env -u TMUX tmux -L "$SOCK" split-window -d -h -l "$RIGHT_W" -t "$P_CTRL" -P -F '#{pane_id}' "$CMD_BOARD")"
P_TELE="$(env -u TMUX tmux -L "$SOCK" split-window -d -v -l "$TELE_H" -t "$P_BOARD" -P -F '#{pane_id}' "$CMD_TELE")"

env -u TMUX tmux -L "$SOCK" set-option -g @ctrl_pane "$P_CTRL"
env -u TMUX tmux -L "$SOCK" set-option -g @board_pane "$P_BOARD"
env -u TMUX tmux -L "$SOCK" set-option -g @tele_pane "$P_TELE"
env -u TMUX tmux -L "$SOCK" select-pane -t "$P_CTRL"

env -u TMUX tmux -L "$SOCK" attach-session -t atk || true

cleanup_atk
trap - EXIT INT TERM HUP
