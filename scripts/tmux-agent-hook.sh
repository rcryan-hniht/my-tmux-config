#!/usr/bin/env bash
set -euo pipefail

# Lightweight lifecycle hook & seen-marker for Claude Code, Codex CLI, and Antigravity (agy).
# Writes per-pane state into ${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agents/panes/<pane_num>.state
# Format: <state>\t<agent>\t<epoch>\t<model>
#
# Usage:
#   tmux-agent-hook.sh <claude|codex|agy> <session|working|blocked|notify|stop>
#   tmux-agent-hook.sh --mark-seen <pane_id>

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agents/panes"

pane_key() {
	printf '%s' "${1#%}"
}

write_state_atomic() {
	local pane_id="$1"
	local state="$2"
	local agent="$3"
	local model="${4:-}"
	local now key file tmp

	[ -n "$pane_id" ] || return 0
	mkdir -p "$STATE_DIR"
	key="$(pane_key "$pane_id")"
	file="${STATE_DIR}/${key}.state"
	tmp="${file}.tmp.$$"
	now="$(date +%s)"

	# Preserve previous model if current hook payload did not provide one
	if [ -z "$model" ] && [ -f "$file" ]; then
		local _old_s _old_a _old_t old_m
		IFS=$'\t' read -r _old_s _old_a _old_t old_m <"$file" 2>/dev/null || true
		[ "${_old_a:-}" = "$agent" ] && model="${old_m:-}"
	fi

	printf '%s\t%s\t%s\t%s\n' "$state" "$agent" "$now" "$model" >"$tmp"
	mv -f "$tmp" "$file"
}

mark_seen() {
	local pane_id="${1:-}"
	[ -n "$pane_id" ] || exit 0

	local key file state agent ts model tmp
	key="$(pane_key "$pane_id")"
	file="${STATE_DIR}/${key}.state"
	[ -f "$file" ] || exit 0

	IFS=$'\t' read -r state agent ts model <"$file" 2>/dev/null || exit 0
	if [ "${state:-}" = "done" ]; then
		tmp="${file}.tmp.$$"
		printf 'idle\t%s\t%s\t%s\n' "${agent:-}" "${ts:-$(date +%s)}" "${model:-}" >"$tmp"
		mv -f "$tmp" "$file"
	fi
}

is_pane_focused_now() {
	local pane_id="$1"
	local flags
	flags="$(tmux display-message -p -t "$pane_id" '#{session_attached} #{window_active} #{pane_active}' 2>/dev/null || true)"
	[ "$flags" = "1 1 1" ]
}

emit_hook_reply() {
	local agent="$1"
	local event="$2"
	if [ "$agent" = "agy" ]; then
		if [ "$event" = "stop" ]; then
			printf '{"decision":"allow"}\n'
		else
			printf '{}\n'
		fi
	fi
}

if [ "${1:-}" = "--mark-seen" ]; then
	mark_seen "${2:-}"
	exit 0
fi

agent="${1:-}"
event="${2:-}"

# Always read stdin quickly without blocking if empty, and never fail the agent hook
payload=""
if [ ! -t 0 ]; then
	payload="$(cat 2>/dev/null || true)"
fi

if [ -n "$agent" ] && [ -n "$event" ] && [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
	model=""
	if [ -n "$payload" ]; then
		# Best-effort lightweight extraction of modelName / model from JSON payload
		if [[ "$payload" =~ \"modelName\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
			model="${BASH_REMATCH[1]}"
			[ "$model" = "auto" ] && model=""
		elif [[ "$payload" =~ \"model\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
			model="${BASH_REMATCH[1]}"
		fi
	fi

	target_state=""
	case "$event" in
		session)
			target_state="idle"
			;;
		working)
			target_state="working"
			;;
		blocked)
			target_state="blocked"
			;;
		notify)
			case "$payload" in
				*permission_prompt* | *elicitation_dialog* | *approval* | *waiting_for_input*)
					target_state="blocked"
					;;
				*idle_prompt*)
					if is_pane_focused_now "$TMUX_PANE"; then
						target_state="idle"
					else
						target_state="done"
					fi
					;;
				*)
					target_state="blocked"
					;;
			esac
			;;
		stop)
			case "$payload" in
				*USER_CANCELED*)
					target_state="idle"
					;;
				*)
					if is_pane_focused_now "$TMUX_PANE"; then
						target_state="idle"
					else
						target_state="done"
					fi
					;;
			esac
			;;
	esac

	if [ -n "$target_state" ]; then
		write_state_atomic "$TMUX_PANE" "$target_state" "$agent" "$model" || true
	fi
fi

emit_hook_reply "$agent" "$event"
exit 0
