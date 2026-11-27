#!/usr/bin/env bash
set -euo pipefail

# Fullscreen tmux popup dashboard running sigye + dual cava (mirror + wave)
# in an isolated tmux socket. Tab / Shift+Tab cycle 4 layouts cleanly without
# restarting panes, Comma (,) toggles fullscreen <-> active pane popup size,
# ] / [ dock to the bottom / top half outer split pane (and back with ,),
# and the last selected preset persists across openings.

SELF_PATH="$(readlink -f "$0")"
CAVA_LAUNCH="$HOME/.config/cava/launch.sh"
STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/tmux/clock-layout"

read_saved_layout() {
	if [[ -f "$STATE_FILE" ]]; then
		local saved
		saved="$(tr -d '[:space:]' < "$STATE_FILE" 2>/dev/null || true)"
		if [[ "$saved" =~ ^[0-6]$ ]]; then
			printf '%s\n' "$saved"
			return
		fi
	fi
	printf '0\n'
}

save_layout() {
	local idx="$1"
	mkdir -p "$(dirname "$STATE_FILE")"
	printf '%s\n' "$idx" > "${STATE_FILE}.tmp.$$"
	mv -f "${STATE_FILE}.tmp.$$" "$STATE_FILE"
}

apply_layout() {
	local sock="$1" idx="$2" p_sigye="$3" p_mirror="$4" p_wave="$5" p_native="$6"
	local cur_win
	cur_win="$(env -u TMUX tmux -L "$sock" display-message -p -t "$p_sigye" '#{window_id}')"

	if [[ "$(env -u TMUX tmux -L "$sock" display-message -p -t "$p_mirror" '#{window_id}')" == "$cur_win" ]]; then
		env -u TMUX tmux -L "$sock" break-pane -d -s "$p_mirror" -n "_hold_m"
	fi
	if [[ "$(env -u TMUX tmux -L "$sock" display-message -p -t "$p_wave" '#{window_id}')" == "$cur_win" ]]; then
		env -u TMUX tmux -L "$sock" break-pane -d -s "$p_wave" -n "_hold_w"
	fi
	if [[ -n "$p_native" && "$(env -u TMUX tmux -L "$sock" display-message -p -t "$p_native" '#{window_id}')" == "$cur_win" ]]; then
		env -u TMUX tmux -L "$sock" break-pane -d -s "$p_native" -n "_hold_n"
	fi

	case "$idx" in
		0) # A. Symmetric Sandwich: C top 22%, sigye middle ~52%, B bottom 26%
			env -u TMUX tmux -L "$sock" join-pane -d -b -v -t "$p_sigye" -l 22% -s "$p_wave"
			env -u TMUX tmux -L "$sock" join-pane -d -v -t "$p_sigye" -l 33% -s "$p_mirror"
			;;
		1) # B. Studio Cockpit: sigye left 56%, right 44% (B top 50% / C bottom 50%)
			env -u TMUX tmux -L "$sock" join-pane -d -h -t "$p_sigye" -l 44% -s "$p_mirror"
			env -u TMUX tmux -L "$sock" join-pane -d -v -t "$p_mirror" -l 50% -s "$p_wave"
			;;
		2) # C. Bento Bottom Ribbon: top 72% (sigye 62% | B 38%), bottom 28% full C
			env -u TMUX tmux -L "$sock" join-pane -d -v -t "$p_sigye" -l 28% -s "$p_wave"
			env -u TMUX tmux -L "$sock" join-pane -d -h -t "$p_sigye" -l 38% -s "$p_mirror"
			;;
		3) # D. Tall Energy Sidebar: left 64% (sigye 66% / C 34%), right 36% full B
			env -u TMUX tmux -L "$sock" join-pane -d -h -t "$p_sigye" -l 36% -s "$p_mirror"
			env -u TMUX tmux -L "$sock" join-pane -d -v -t "$p_sigye" -l 34% -s "$p_wave"
			;;
		4) # E. Native Stage: wave top 18%, sigye middle 52%, native bottom 30%
			env -u TMUX tmux -L "$sock" join-pane -d -b -v -t "$p_sigye" -l 18% -s "$p_wave"
			env -u TMUX tmux -L "$sock" join-pane -d -v -t "$p_sigye" -l 36% -s "$p_native"
			;;
		5) # F. Cockpit 3-Vis: left 58% (sigye 70% / wave 30%), right 42% (mirror 50% / native 50%)
			env -u TMUX tmux -L "$sock" join-pane -d -h -t "$p_sigye" -l 42% -s "$p_mirror"
			env -u TMUX tmux -L "$sock" join-pane -d -v -t "$p_sigye" -l 30% -s "$p_wave"
			env -u TMUX tmux -L "$sock" join-pane -d -v -t "$p_mirror" -l 50% -s "$p_native"
			;;
		6) # G. Minimal Native: sigye top 64%, native bottom 36%
			env -u TMUX tmux -L "$sock" join-pane -d -v -t "$p_sigye" -l 36% -s "$p_native"
			;;
	esac

	env -u TMUX tmux -L "$sock" select-pane -t "$p_sigye"
}

if [[ "${1:-}" == "--step-layout" || "${1:-}" == "--next-layout" ]]; then
	SOCK="$2"
	DELTA="${3:-1}"
	exec 9>"/tmp/${SOCK}.lock"
	flock -w 1 9

	idx="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @layout_idx)"
	p_sigye="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @sigye_pane)"
	p_mirror="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @mirror_pane)"
	p_wave="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @wave_pane)"
	p_native="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @native_pane)"

	next=$(( (${idx:-0} + DELTA + 7) % 7 ))
	env -u TMUX tmux -L "$SOCK" set-option -g @layout_idx "$next"
	save_layout "$next"
	apply_layout "$SOCK" "$next" "$p_sigye" "$p_mirror" "$p_wave" "$p_native"
	exit 0
fi

if [[ "${1:-}" == "--pick-theme" ]]; then
	SOCK="$2"
	THEME_SCRIPT="$HOME/.config/tmux/scripts/tmux-theme.sh"
	[[ -x "$THEME_SCRIPT" ]] || exit 0
	outer_tmux="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @outer_tmux 2>/dev/null || true)"
	p_native="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @native_pane 2>/dev/null || true)"
	env -u TMUX tmux -L "$SOCK" display-popup -E -w 78% -h 74% "TMUX='${outer_tmux}' '${THEME_SCRIPT}'" || true
	if [[ -n "$p_native" ]]; then
		new_theme="$("$CAVA_LAUNCH" --print-theme)"
		env -u TMUX tmux -L "$SOCK" respawn-pane -k -t "$p_native" "'${CAVA_LAUNCH}' --mode default --theme '${new_theme}'" 2>/dev/null || true
	fi
	exit 0
fi

find_sibling_pane() {
	local outer_tmux="$1" ref_pane="$2" exclude_pane="$3" preferred="${4:-}"
	local win_id pane_id fallback=""
	win_id="$(env TMUX="$outer_tmux" tmux display-message -p -t "$ref_pane" '#{window_id}' 2>/dev/null || true)"
	[[ -n "$win_id" ]] || return 0
	while IFS= read -r pane_id; do
		[[ -n "$pane_id" && "$pane_id" != "$exclude_pane" ]] || continue
		if [[ "$pane_id" == "$preferred" ]]; then
			printf '%s\n' "$pane_id"
			return 0
		fi
		[[ -n "$fallback" ]] || fallback="$pane_id"
	done < <(env TMUX="$outer_tmux" tmux list-panes -t "$win_id" -F '#{pane_id}' 2>/dev/null || true)
	[[ -n "$fallback" ]] && printf '%s\n' "$fallback" || true
}

close_other_docks() {
	local outer_tmux="$1" ref_pane="$2" keep1="$3" keep2="${4:-}"
	local win_id pane_id tag
	win_id="$(env TMUX="$outer_tmux" tmux display-message -p -t "$ref_pane" '#{window_id}' 2>/dev/null || true)"
	[[ -n "$win_id" ]] || return 0
	while read -r pane_id tag; do
		[[ "$tag" == "1" && -n "$pane_id" ]] || continue
		[[ "$pane_id" == "$keep1" || "$pane_id" == "$keep2" ]] && continue
		env TMUX="$outer_tmux" tmux kill-pane -t "$pane_id" 2>/dev/null || true
	done < <(env TMUX="$outer_tmux" tmux list-panes -t "$win_id" -F '#{pane_id} #{@clock_cava}' 2>/dev/null || true)
}

if [[ "${1:-}" == "--toggle-size" ]]; then
	SOCK="$2"
	SOCK_DIR="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
	exec 9>"/tmp/${SOCK}.lock"
	flock -w 1 9

	outer_tmux="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @outer_tmux 2>/dev/null || true)"
	[[ -n "$outer_tmux" ]] || exit 0

	outer_client="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @outer_client 2>/dev/null || true)"
	outer_pane="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @outer_pane 2>/dev/null || true)"
	cur_dock_pane="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @dock_pane 2>/dev/null || true)"
	tmp_conf="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @tmp_conf 2>/dev/null || true)"
	size_mode="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @size_mode 2>/dev/null || true)"
	cur_gen="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @attach_gen 2>/dev/null || true)"
	fallback_w="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @outer_pane_w 2>/dev/null || true)"
	fallback_h="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @outer_pane_h 2>/dev/null || true)"

	next_gen=$(( ${cur_gen:-1} + 1 ))
	if [[ "$size_mode" == dock-* ]]; then
		surviving_pane="$(find_sibling_pane "$outer_tmux" "$cur_dock_pane" "$cur_dock_pane" "$outer_pane")"
		if [[ -z "$surviving_pane" ]]; then
			env -u TMUX tmux -L "$SOCK" display-message "No other pane to return to popup" 2>/dev/null || true
			exit 0
		fi
		next_mode="full"
		outer_pane="$surviving_pane"
		env -u TMUX tmux -L "$SOCK" set-option -g @outer_pane "$surviving_pane"
	elif [[ "$size_mode" == "pane" ]]; then
		next_mode="full"
	else
		next_mode="pane"
	fi

	pw="" ph=""
	if [[ "$next_mode" == "pane" ]]; then
		pane_dims="$(env TMUX="$outer_tmux" tmux display-message -p ${outer_pane:+-t "$outer_pane"} '#{pane_width} #{pane_height}' 2>/dev/null || true)"
		read -r pw ph <<< "$pane_dims"
		pw="${pw:-${fallback_w:-}}"
		ph="${ph:-${fallback_h:-}}"
		[[ "$pw" =~ ^[0-9]+$ && "$ph" =~ ^[0-9]+$ ]] || exit 0
	fi

	# Advance @attach_gen synchronously before closing the current client so its
	# cleanup trap sees it was superseded and leaves the $SOCK server running.
	env -u TMUX tmux -L "$SOCK" set-option -g @attach_gen "$next_gen"
	env -u TMUX tmux -L "$SOCK" set-option -g @size_mode "$next_mode"
	env -u TMUX tmux -L "$SOCK" set-option -g @dock_pane ""
	exec 9>&-

	printf -v reattach_cmd '%q --reattach %q %q' "$SELF_PATH" "$SOCK" "$next_gen"
	popup_rc=0
	if [[ "$size_mode" == dock-* && -n "$cur_dock_pane" ]]; then
		env TMUX="$outer_tmux" tmux kill-pane -t "$cur_dock_pane" 2>/dev/null || true
	fi
	if [[ "$next_mode" == "pane" ]]; then
		env TMUX="$outer_tmux" tmux \
			display-popup ${outer_client:+-c "$outer_client"} -C \; \
			display-popup ${outer_client:+-c "$outer_client"} ${outer_pane:+-t "$outer_pane"} \
			-E -b none -x P -y P -w "$pw" -h "$ph" "$reattach_cmd" || popup_rc=$?
	else
		env TMUX="$outer_tmux" tmux \
			display-popup ${outer_client:+-c "$outer_client"} -C \; \
			display-popup ${outer_client:+-c "$outer_client"} \
			-E -b none -w 100% -h 100% "$reattach_cmd" || popup_rc=$?
	fi

	if (( popup_rc != 0 )); then
		cleanup_session "$SOCK" "$next_gen" "$tmp_conf" "$SOCK_DIR"
	fi
	exit 0
fi

if [[ "${1:-}" == "--dock-pane" ]]; then
	SOCK="$2"
	POS="${3:-bottom}"
	SOCK_DIR="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
	exec 9>"/tmp/${SOCK}.lock"
	flock -w 1 9

	outer_tmux="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @outer_tmux 2>/dev/null || true)"
	[[ -n "$outer_tmux" ]] || exit 0

	outer_client="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @outer_client 2>/dev/null || true)"
	outer_pane="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @outer_pane 2>/dev/null || true)"
	cur_dock_pane="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @dock_pane 2>/dev/null || true)"
	tmp_conf="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @tmp_conf 2>/dev/null || true)"
	size_mode="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @size_mode 2>/dev/null || true)"
	cur_gen="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @attach_gen 2>/dev/null || true)"

	next_mode="dock-${POS}"
	[[ "$size_mode" == "$next_mode" ]] && exit 0

	target_pane="$outer_pane"
	if [[ -n "$cur_dock_pane" ]]; then
		target_pane="$(find_sibling_pane "$outer_tmux" "$cur_dock_pane" "$cur_dock_pane" "$outer_pane")"
		if [[ -z "$target_pane" ]]; then
			env -u TMUX tmux -L "$SOCK" display-message "Need another pane in window to move ${POS}" 2>/dev/null || true
			exit 0
		fi
	fi

	next_gen=$(( ${cur_gen:-1} + 1 ))
	env -u TMUX tmux -L "$SOCK" set-option -g @attach_gen "$next_gen"
	env -u TMUX tmux -L "$SOCK" set-option -g @size_mode "$next_mode"
	env -u TMUX tmux -L "$SOCK" set-option -g @outer_pane "$target_pane"
	exec 9>&-

	close_other_docks "$outer_tmux" "$target_pane" "$target_pane" "$cur_dock_pane"

	split_flag="-fv"
	[[ "$POS" == "top" ]] && split_flag="-fbv"
	printf -v pane_cmd 'exec %q --reattach %q %q' "$SELF_PATH" "$SOCK" "$next_gen"

	new_pane=""
	if [[ -n "$cur_dock_pane" ]]; then
		env TMUX="$outer_tmux" tmux kill-pane -t "$cur_dock_pane" 2>/dev/null || true
		new_pane="$(
			env TMUX="$outer_tmux" tmux \
				split-window -d "$split_flag" -l 50% -t "$target_pane" -P -F '#{pane_id}' "$pane_cmd" \
			2>/dev/null || true
		)"
	else
		new_pane="$(
			env TMUX="$outer_tmux" tmux \
				display-popup ${outer_client:+-c "$outer_client"} -C \; \
				split-window -d "$split_flag" -l 50% -t "$target_pane" -P -F '#{pane_id}' "$pane_cmd" \
			2>/dev/null || true
		)"
	fi

	if [[ -n "$new_pane" ]]; then
		env TMUX="$outer_tmux" tmux set-option -p -t "$new_pane" @clock_cava 1 2>/dev/null || true
		env -u TMUX tmux -L "$SOCK" set-option -g @dock_pane "$new_pane" 2>/dev/null || true
	else
		cleanup_session "$SOCK" "$next_gen" "$tmp_conf" "$SOCK_DIR"
	fi
	exit 0
fi

cleanup_session() {
	local sock="$1" my_gen="$2" tmp_conf="$3" sock_dir="$4"
	local cur_gen=""
	cur_gen="$(env -u TMUX tmux -L "$sock" show-options -gqv @attach_gen 2>/dev/null || true)"
	if [[ -n "$cur_gen" && "$cur_gen" != "$my_gen" ]]; then
		return 0
	fi
	env -u TMUX tmux -L "$sock" kill-server 2>/dev/null || true
	rm -f "$tmp_conf" "/tmp/${sock}.lock" "${sock_dir}/${sock}"
}

if [[ "${1:-}" == "--reattach" ]]; then
	SOCK="$2"
	MY_GEN="$3"
	SOCK_DIR="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
	TMP_CONF="$(env -u TMUX tmux -L "$SOCK" show-options -gqv @tmp_conf 2>/dev/null || true)"
	trap 'cleanup_session "$SOCK" "$MY_GEN" "$TMP_CONF" "$SOCK_DIR"' EXIT INT TERM HUP
	env -u TMUX tmux -L "$SOCK" attach-session -t vibe || true
	exit 0
fi

OUTER_TMUX="${TMUX:-}"
OUTER_PANE="${TMUX_PANE:-}"
OUTER_CLIENT=""
OUTER_PANE_W=""
OUTER_PANE_H=""
if [[ -n "$OUTER_TMUX" ]]; then
	OUTER_CLIENT="$(tmux display-message -p '#{client_name}' 2>/dev/null || true)"
	pane_info="$(tmux display-message -p ${OUTER_PANE:+-t "$OUTER_PANE"} '#{pane_id} #{pane_width} #{pane_height}' 2>/dev/null || true)"
	read -r OUTER_PANE OUTER_PANE_W OUTER_PANE_H <<< "$pane_info"
fi

THEME_MODE="$("$CAVA_LAUNCH" --print-theme)"
if [[ "$THEME_MODE" == "light" ]]; then
	BORDER_FG="#c8c8c8"
else
	BORDER_FG="#262626"
fi

INIT_IDX="$(read_saved_layout)"
SOCK="popup-clock-$$"
SOCK_DIR="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
TMP_CONF="$(mktemp /tmp/tmux-clock-XXXXXX.conf)"

trap 'cleanup_session "$SOCK" "1" "$TMP_CONF" "$SOCK_DIR"' EXIT INT TERM HUP

cat >"$TMP_CONF" <<EOF
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
bind-key -n Tab   run-shell -b "'${SELF_PATH}' --step-layout '${SOCK}' 1"
bind-key -n BTab  run-shell -b "'${SELF_PATH}' --step-layout '${SOCK}' -1"
bind-key -n ,     run-shell -b "'${SELF_PATH}' --toggle-size '${SOCK}'"
bind-key -n ]     run-shell -b "'${SELF_PATH}' --dock-pane '${SOCK}' bottom"
bind-key -n [     run-shell -b "'${SELF_PATH}' --dock-pane '${SOCK}' top"
bind-key -n c     run-shell -b "'${SELF_PATH}' --pick-theme '${SOCK}'"
bind-key -n C-q kill-server
set-hook -g pane-exited 'kill-server'
EOF

COLS="$(tput cols 2>/dev/null || echo 140)"
LINES="$(tput lines 2>/dev/null || echo 42)"

P_SIGYE="$(env -u TMUX tmux -L "$SOCK" -f "$TMP_CONF" new-session -d -P -F '#{pane_id}' -x "$COLS" -y "$LINES" -s vibe "$HOME/.cargo/bin/sigye")"
P_MIRROR="$(env -u TMUX tmux -L "$SOCK" new-window -d -P -F '#{pane_id}' -n "_hold_m" "'${CAVA_LAUNCH}' --mode mirror --theme '${THEME_MODE}'")"
P_WAVE="$(env -u TMUX tmux -L "$SOCK" new-window -d -P -F '#{pane_id}' -n "_hold_w" "'${CAVA_LAUNCH}' --mode wave --theme '${THEME_MODE}'")"
P_NATIVE="$(env -u TMUX tmux -L "$SOCK" new-window -d -P -F '#{pane_id}' -n "_hold_n" "'${CAVA_LAUNCH}' --mode default --theme '${THEME_MODE}'")"

env -u TMUX tmux -L "$SOCK" set-option -g @layout_idx "$INIT_IDX"
env -u TMUX tmux -L "$SOCK" set-option -g @sigye_pane "$P_SIGYE"
env -u TMUX tmux -L "$SOCK" set-option -g @mirror_pane "$P_MIRROR"
env -u TMUX tmux -L "$SOCK" set-option -g @wave_pane "$P_WAVE"
env -u TMUX tmux -L "$SOCK" set-option -g @native_pane "$P_NATIVE"
env -u TMUX tmux -L "$SOCK" set-option -g @attach_gen "1"
env -u TMUX tmux -L "$SOCK" set-option -g @size_mode "full"
env -u TMUX tmux -L "$SOCK" set-option -g @dock_pane ""
env -u TMUX tmux -L "$SOCK" set-option -g @tmp_conf "$TMP_CONF"
env -u TMUX tmux -L "$SOCK" set-option -g @outer_tmux "$OUTER_TMUX"
env -u TMUX tmux -L "$SOCK" set-option -g @outer_client "$OUTER_CLIENT"
env -u TMUX tmux -L "$SOCK" set-option -g @outer_pane "$OUTER_PANE"
env -u TMUX tmux -L "$SOCK" set-option -g @outer_pane_w "$OUTER_PANE_W"
env -u TMUX tmux -L "$SOCK" set-option -g @outer_pane_h "$OUTER_PANE_H"

apply_layout "$SOCK" "$INIT_IDX" "$P_SIGYE" "$P_MIRROR" "$P_WAVE" "$P_NATIVE"

env -u TMUX tmux -L "$SOCK" attach-session -t vibe || true
