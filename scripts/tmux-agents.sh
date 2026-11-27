#!/usr/bin/env bash
set -euo pipefail

# Minimalist popup monitor & controller for AI coding agents (agy, claude, codex, opencode).
# Features live 180ms state icon animations (Braille spinner for working, pulse for blocked/done)
# via fzf's Unix socket + reload-sync (zero flicker, preserves selection & search query).
# j/k: move | l/Enter: jump | /: search | s: roster | u: quota | q: quit | ^y: approve | ^s: mark seen | Tab: agents/all | ?: keymap

CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-agents"
STATE_DIR="${CACHE_BASE}/panes"
QUOTA_CACHE="${CACHE_BASE}/agy-quota.json"
CREDITS_CACHE="${CACHE_BASE}/agy-credits.json"
CODEX_QUOTA_CACHE="${CACHE_BASE}/codex-quota.json"
CLAUDE_QUOTA_CACHE="${CACHE_BASE}/claude-quota.json"
QUOTA_ERR="${CACHE_BASE}/agy-quota.err"
QUOTA_LOCK="${CACHE_BASE}/agy-quota.lock"
QUOTA_TTL=90

shell_quote() {
	printf "'%s'" "${1//\'/\'\\\'\'}"
}

pane_key() {
	printf '%s' "${1#%}"
}

short_path() {
	local p="$1"
	local home="${HOME%/}"
	if [ "$p" = "$home" ]; then
		printf '~'
	elif [ "${p#"$home/"}" != "$p" ]; then
		printf '~/%s' "${p#"$home/"}"
	else
		printf '%s' "$p"
	fi
}

format_age() {
	local ts="${1:-0}"
	local now="${2:-$(date +%s)}"
	if ! [[ "$ts" =~ ^[0-9]+$ ]] || [ "$ts" -le 0 ]; then
		printf ''
		return 0
	fi
	local diff=$((now - ts))
	[ "$diff" -lt 0 ] && diff=0
	if [ "$diff" -lt 15 ]; then
		printf 'now'
	elif [ "$diff" -lt 60 ]; then
		printf '%ds' "$diff"
	elif [ "$diff" -lt 3600 ]; then
		printf '%dm' $((diff / 60))
	elif [ "$diff" -lt 86400 ]; then
		printf '%dh' $((diff / 3600))
	else
		printf '%dd' $((diff / 86400))
	fi
}

truncate_str() {
	local s="$1"
	local max="$2"
	if [ "${#s}" -gt "$max" ]; then
		printf '%s..' "${s:0:$((max - 2))}"
	else
		printf '%s' "$s"
	fi
}

write_state_atomic() {
	local pane_id="$1"
	local state="$2"
	local agent="$3"
	local ts="$4"
	local model="$5"
	mkdir -p "$STATE_DIR"
	local key file tmp
	key="$(pane_key "$pane_id")"
	file="${STATE_DIR}/${key}.state"
	tmp="${file}.tmp.$$"
	printf '%s\t%s\t%s\t%s\n' "$state" "$agent" "$ts" "$model" >"$tmp"
	mv -f "$tmp" "$file"
}

mark_seen_pane() {
	local pane_id="${1:-}"
	[ -n "$pane_id" ] || return 0
	local hook_script
	hook_script="$(dirname "$(realpath "${BASH_SOURCE[0]}")")/tmux-agent-hook.sh"
	if [ -x "$hook_script" ]; then
		"$hook_script" --mark-seen "$pane_id" 2>/dev/null || true
	fi
}

approve_pane() {
	local pane_id="${1:-}"
	[ -n "$pane_id" ] || return 0
	tmux send-keys -t "$pane_id" Enter 2>/dev/null || true
	mark_seen_pane "$pane_id"
	sleep 0.12
}

interrupt_pane() {
	local pane_id="${1:-}"
	[ -n "$pane_id" ] || return 0
	tmux send-keys -t "$pane_id" Escape 2>/dev/null || true
	sleep 0.12
}

# Detect running agents per tty in a single `ps` invocation.
# Outputs: "<short_tty>\t<agent>"
scan_tty_agents() {
	ps -eo tty=,stat=,comm=,args= 2>/dev/null | awk '
		function basename(p,    n, a) {
			n = split(p, a, "/")
			return a[n]
		}
		function is_known(name) {
			return (name == "agy" || name == "claude" || name == "codex" || name == "opencode")
		}
		function match_row(comm,    i, tok, b) {
			if (is_known(comm)) return comm
			b = basename($4)
			sub(/\.js$/, "", b)
			if (is_known(b)) return b
			if (comm == "node" || comm == "bun" || comm == "MainThread" || comm ~ /^[0-9]+\.[0-9]+\.[0-9]+/) {
				for (i = 4; i <= NF; i++) {
					tok = $i
					if (tok ~ /^-/) continue
					b = basename(tok)
					sub(/\.js$/, "", b)
					if (is_known(b)) return b
				}
			}
			return ""
		}
		function prio(ag) {
			if (ag == "agy") return 1
			if (ag == "claude") return 2
			if (ag == "codex") return 3
			if (ag == "opencode") return 4
			return 9
		}
		{
			tty = $1
			stat = $2
			comm = $3
			if (tty == "?" || tty == "") next
			ag = match_row(comm)
			if (ag == "") next
			is_fg = (index(stat, "+") > 0) ? 1 : 0
			p = prio(ag)
			if (!(tty in best) || (is_fg > best_fg[tty]) || (is_fg == best_fg[tty] && p < best_prio[tty])) {
				best[tty] = ag
				best_fg[tty] = is_fg
				best_prio[tty] = p
			}
		}
		END {
			for (tty in best) {
				printf "%s\t%s\n", tty, best[tty]
			}
		}
	'
}

# Inspect visible screen of an agent pane in a single capture-pane + awk pass.
# Prints "<live_state>\t<model>" where live_state is blocked|working|waiting|unknown.
inspect_agent_pane() {
	local pane_id="$1"
	local agent="$2"

	tmux capture-pane -p -t "$pane_id" -S -28 2>/dev/null | awk -v agent="$agent" '
		NF { lines[++n] = $0 }
		END {
			if (n == 0) {
				printf "unknown\t\n"
				exit
			}
			s12 = (n > 12 ? n - 11 : 1)
			s6  = (n > 6  ? n - 5  : s12)
			s3  = (n > 3  ? n - 2  : s12)

			bottom6 = ""
			for (i = s6; i <= n; i++) bottom6 = bottom6 lines[i] "\n"
			footer = ""
			for (i = s3; i <= n; i++) footer = footer lines[i] "\n"

			spin = "(⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏)"
			live = "waiting"
			model = ""

			if (agent == "agy") {
				for (i = s3; i <= n; i++) {
					line = lines[i]
					if (line ~ /esc to cancel|\? for shortcuts|·[[:space:]]+\/tasks|subagent\(s\)/) {
						sub(/^[[:space:]]*(esc to cancel|\? for shortcuts)[[:space:]]+/, "", line)
						sub(/^[[:space:]]+/, "", line)
						sub(/[[:space:]]+·[[:space:]]+\/tasks[[:space:]]*$/, "", line)
						sub(/[[:space:]]+$/, "", line)
						if (line != "" && length(line) <= 48 && line !~ /^[─━]+$/) model = line
					}
				}
				if (bottom6 ~ (spin "|timer running|[1-9][0-9]* subagent\\(s\\)|[1-9][0-9]* task\\(s\\)")) {
					live = "working"
				} else if (bottom6 ~ /Allow once|Always allow|Yes, allow|Select an option|Enter to submit|↑\/↓ to navigate|Proceed\?|❯[[:space:]]+[0-9]+\./) {
					live = "blocked"
				} else if (footer ~ /esc to cancel/) {
					live = "working"
				}
			} else if (agent == "claude") {
				if (bottom6 ~ ("…[[:space:]]*\\([0-9]|" spin)) {
					live = "working"
				} else if (bottom6 ~ /❯[[:space:]]+[0-9]+\.|Do you want to proceed|Allow once|Allow for this session|Yes, allow/) {
					live = "blocked"
				} else if (bottom6 ~ /esc to interrupt/) {
					live = "working"
				}
			} else if (agent == "codex") {
				if (bottom6 ~ ("Working[[:space:]]*\\(|" spin)) {
					live = "working"
				} else if (bottom6 ~ /›[[:space:]]+1\.|❯[[:space:]]+1\.|Yes, proceed|Would you like to run|Press enter to confirm|Approve/) {
					live = "blocked"
				} else if (bottom6 ~ /esc to interrupt/) {
					live = "working"
				}
			} else if (agent == "opencode") {
				if (bottom6 ~ /Allow once|Always allow|Permission required/) {
					live = "blocked"
				} else if (bottom6 ~ ("esc to interrupt|" spin)) {
					live = "working"
				}
			} else {
				live = "unknown"
			}

			printf "%s\t%s\n", live, model
		}
	'
}

# Animated 9-char state badge for a given frame tick (0..N).
# - working: 10-frame Braille orbit spinner (⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
# - blocked: pulsing alert icon & color (crimson ▲ ↔ amber ◈)
# - done:    gentle completion beacon (blue ● ↔ cyan ◉)
# - idle:    calm static dim ring (◌)
badge_for_state() {
	local state="$1"
	local tick="${2:-0}"
	case "$state" in
		blocked)
			if [ $(( (tick / 2) % 2 )) -eq 0 ]; then
				printf '\033[1;31m▲ blocked\033[0m'
			else
				printf '\033[1;33m◈ blocked\033[0m'
			fi
			;;
		done)
			if [ $(( (tick / 3) % 2 )) -eq 0 ]; then
				printf '\033[1;34m● done   \033[0m'
			else
				printf '\033[1;36m◉ done   \033[0m'
			fi
			;;
		working)
			local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
			local g="${frames[$((tick % 10))]}"
			printf '\033[1;33m%s working\033[0m' "$g"
			;;
		idle)
			printf '\033[2m◌ idle   \033[0m'
			;;
		*)
			printf '\033[2m· pane   \033[0m'
			;;
	esac
}

state_priority() {
	case "$1" in
		blocked) printf '0' ;;
		done)    printf '1' ;;
		working) printf '2' ;;
		idle)    printf '3' ;;
		*)       printf '4' ;;
	esac
}

prune_stale_state_files() {
	local live_keys="$1"
	[ -d "$STATE_DIR" ] || return 0
	local f base key
	for f in "$STATE_DIR"/*.state; do
		[ -e "$f" ] || break
		base="${f##*/}"
		key="${base%.state}"
		case " $live_keys " in
			*" $key "*) ;;
			*) rm -f "$f" ;;
		esac
	done
}

# Render sorted raw cache rows with animated badges for frame `tick`.
# Input format per line:
#   1:prio  2:rev_ts  3:pane_id  4:loc_col  5:agent_pad  6:age_pad  7:label_name  8:state  9:target  10:spath  11:model
render_cached_rows() {
	local cache_file="$1"
	local tick="${2:-0}"
	[ -s "$cache_file" ] || return 0

	local b_blocked b_done b_working b_idle b_pane
	local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
	if [ $(( (tick / 2) % 2 )) -eq 0 ]; then
		b_blocked=$'\033[1;31m▲ blocked\033[0m'
	else
		b_blocked=$'\033[1;33m◈ blocked\033[0m'
	fi
	if [ $(( (tick / 3) % 2 )) -eq 0 ]; then
		b_done=$'\033[1;34m● done   \033[0m'
	else
		b_done=$'\033[1;36m◉ done   \033[0m'
	fi
	printf -v b_working '\033[1;33m%s working\033[0m' "${frames[$((tick % 10))]}"
	b_idle=$'\033[2m◌ idle   \033[0m'
	b_pane=$'\033[2m· pane   \033[0m'

	awk -F '\t' \
		-v bb="$b_blocked" \
		-v bd="$b_done" \
		-v bw="$b_working" \
		-v bi="$b_idle" \
		-v bp="$b_pane" '
		{
			pane_id = $3
			loc_col = $4
			ag_pad  = $5
			age_pad = $6
			label   = $7
			state   = $8
			target  = $9
			spath   = $10
			model   = $11

			badge = bp
			if (state == "blocked") badge = bb
			else if (state == "done") badge = bd
			else if (state == "working") badge = bw
			else if (state == "idle") badge = bi

			display = sprintf("%s  %s  \033[2m%s  %s\033[0m", badge, loc_col, ag_pad, age_pad)
			printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", pane_id, display, label, state, target, spath, model
		}
	' "$cache_file"
}

# List entries for fzf.
# Args: <mode: agents|all> <src_pane> <left_text_w> <tick> <use_cache> <rows_cache_file>
list_entries() {
	local mode="${1:-agents}"
	local src_pane="${2:-}"
	local left_text_w="${3:-42}"
	local tick="${4:-0}"
	local use_cache="${5:-0}"
	local rows_cache="${6:-}"

	if [ "$use_cache" = "1" ] && [ -n "$rows_cache" ] && [ -s "$rows_cache" ]; then
		render_cached_rows "$rows_cache" "$tick"
		return 0
	fi

	local now home="${HOME%/}"
	printf -v now '%(%s)T' -1

	# Fixed columns: badge(9) + gap(2) + loc(loc_w) + gap(2) + agent(7) + gap(2) + age(3) = loc_w + 25
	local loc_w=$(( left_text_w - 25 ))
	[ "$loc_w" -lt 14 ] && loc_w=14
	[ "$loc_w" -gt 26 ] && loc_w=26
	local sess_max=$(( loc_w - 3 ))

	declare -A tty_agent=()
	local stty sag
	while IFS=$'\t' read -r stty sag; do
		[ -n "$stty" ] && tty_agent["$stty"]="$sag"
	done < <(scan_tty_agents)

	local live_keys=""
	local rows=""
	local pane_id sess win_idx win_name pane_idx pane_tty pane_cmd pane_path win_act pane_act sess_att pane_act_ts

	while IFS=$'\t' read -r pane_id sess win_idx win_name pane_idx pane_tty pane_cmd pane_path win_act pane_act sess_att pane_act_ts; do
		[ -n "$pane_id" ] || continue
		local pkey="${pane_id#%}"
		live_keys+=" $pkey"

		local short_tty="${pane_tty#/dev/}"
		local agent="${tty_agent[$short_tty]:-}"
		if [ -z "$agent" ]; then
			case "$pane_cmd" in
				agy | claude | codex | opencode) agent="$pane_cmd" ;;
			esac
		fi

		if [ "$mode" = "agents" ] && [ -z "$agent" ]; then
			continue
		fi

		local state="pane"
		local model=""
		local ts="${pane_act_ts:-0}"
		local label_name="$pane_cmd"
		local is_current=0
		if [ "$pane_id" = "$src_pane" ] || { [ "${sess_att:-0}" = "1" ] && [ "${win_act:-0}" = "1" ] && [ "${pane_act:-0}" = "1" ]; }; then
			is_current=1
		fi

		if [ -n "$agent" ]; then
			label_name="$agent"
			local cache_file="${STATE_DIR}/${pkey}.state"
			local c_state="" c_agent="" c_ts="" c_model=""
			if [ -f "$cache_file" ]; then
				IFS=$'\t' read -r c_state c_agent c_ts c_model <"$cache_file" 2>/dev/null || true
				if [ "$c_agent" != "$agent" ]; then
					c_state=""; c_ts=""; c_model=""
				fi
			fi

			local live_state="" live_model=""
			IFS=$'\t' read -r live_state live_model < <(inspect_agent_pane "$pane_id" "$agent")
			model="${live_model:-$c_model}"
			[ -n "$c_ts" ] && ts="$c_ts"

			case "$live_state" in
				blocked)
					state="blocked"
					if [ "$c_state" != "blocked" ]; then
						ts="$now"
						write_state_atomic "$pane_id" "blocked" "$agent" "$ts" "$model"
					fi
					;;
				working)
					state="working"
					if [ "$c_state" != "working" ]; then
						ts="$now"
						write_state_atomic "$pane_id" "working" "$agent" "$ts" "$model"
					fi
					;;
				waiting)
					if [ "$c_state" = "done" ] || [ "$c_state" = "working" ]; then
						if [ "$is_current" -eq 1 ]; then
							state="idle"
							write_state_atomic "$pane_id" "idle" "$agent" "${ts:-$now}" "$model"
						else
							state="done"
							if [ "$c_state" = "working" ]; then
								ts="$now"
								write_state_atomic "$pane_id" "done" "$agent" "$ts" "$model"
							fi
						fi
					else
						state="idle"
					fi
					;;
				*)
					state="${c_state:-idle}"
					;;
			esac
		fi

		local prio age_str diff sess_t loc_raw loc_disp loc_pad loc_col ag_t ag_pad age_pad spath target row_line
		case "$state" in
			blocked) prio=0 ;;
			done)    prio=1 ;;
			working) prio=2 ;;
			idle)    prio=3 ;;
			*)       prio=4 ;;
		esac
		if [[ "$ts" =~ ^[0-9]+$ ]] && [ "$ts" -gt 0 ]; then
			diff=$((now - ts))
			[ "$diff" -lt 0 ] && diff=0
			if [ "$diff" -lt 15 ]; then
				age_str='now'
			elif [ "$diff" -lt 60 ]; then
				age_str="${diff}s"
			elif [ "$diff" -lt 3600 ]; then
				age_str="$((diff / 60))m"
			elif [ "$diff" -lt 86400 ]; then
				age_str="$((diff / 3600))h"
			else
				age_str="$((diff / 86400))d"
			fi
		else
			age_str=''
		fi

		if [ "${#sess}" -gt "$sess_max" ]; then
			sess_t="${sess:0:$((sess_max - 2))}.."
		else
			sess_t="$sess"
		fi
		loc_raw="${sess_t}:${win_idx}"
		if [ "${#loc_raw}" -gt "$loc_w" ]; then
			loc_disp="${loc_raw:0:$((loc_w - 2))}.."
		else
			loc_disp="$loc_raw"
		fi
		printf -v loc_pad "%-${loc_w}s" "$loc_disp"
		if [ "$pane_id" = "$src_pane" ]; then
			loc_col=$'\033[1;36m'"${loc_pad}"$'\033[0m'
		else
			loc_col="$loc_pad"
		fi

		if [ "${#label_name}" -gt 7 ]; then
			ag_t="${label_name:0:5}.."
		else
			ag_t="$label_name"
		fi
		printf -v ag_pad '%-7s' "$ag_t"
		printf -v age_pad '%3s' "$age_str"

		if [ "$pane_path" = "$home" ]; then
			spath='~'
		elif [ "${pane_path#"$home/"}" != "$pane_path" ]; then
			spath="~/${pane_path#"$home/"}"
		else
			spath="$pane_path"
		fi
		target="${sess}:${win_idx}.${pane_idx}"

		printf -v row_line '%s\t%012d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
			"$prio" "$((999999999999 - ${ts:-0}))" "$pane_id" "$loc_col" "$ag_pad" "$age_pad" "$label_name" "$state" "$target" "$spath" "$model"
		rows+="${row_line}"$'\n'
	done < <(
		tmux list-panes -a -F $'#{pane_id}\t#{session_name}\t#{window_index}\t#{window_name}\t#{pane_index}\t#{pane_tty}\t#{pane_current_command}\t#{pane_current_path}\t#{window_active}\t#{pane_active}\t#{session_attached}\t#{window_activity}' 2>/dev/null || true
	)

	prune_stale_state_files "$live_keys"

	if [ -z "$rows" ]; then
		[ -n "$rows_cache" ] && rm -f "$rows_cache"
		return 0
	fi

	local sorted_raw
	sorted_raw="$(printf '%s' "$rows" | LC_ALL=C sort -t $'\t' -k1,1n -k2,2n -k9,9)"

	if [ -n "$rows_cache" ]; then
		local tmp_c="${rows_cache}.tmp.$$"
		printf '%s\n' "$sorted_raw" >"$tmp_c"
		mv -f "$tmp_c" "$rows_cache"
		render_cached_rows "$rows_cache" "$tick"
	else
		local tmp_c
		tmp_c="$(mktemp "${TMPDIR:-/tmp}/tmux-agents-rows.XXXXXX")"
		printf '%s\n' "$sorted_raw" >"$tmp_c"
		render_cached_rows "$tmp_c" "$tick"
		rm -f "$tmp_c"
	fi
}

# Fast local-only badge for agy panes in sticky line 2 (~15ms, never calls agy).
# Prints compact info like "🐝 2/3 · Q:20%" if available.
agy_line2_badge() {
	local spath="${1:-}"
	command -v python3 >/dev/null 2>&1 || return 0
	python3 - "$spath" "$QUOTA_CACHE" 2>/dev/null <<'PY' || true
import json, os, sys

spath = sys.argv[1] if len(sys.argv) > 1 else ""
quota_path = sys.argv[2] if len(sys.argv) > 2 else ""
parts = []

# 1. Active swarm working/alive count for this pane's path
try:
    if spath:
        expanded = os.path.expanduser(spath)
        real_target = os.path.realpath(expanded)
        lc_path = os.path.expanduser("~/.gemini/antigravity-cli/cache/last_conversations.json")
        conv_id = None
        if os.path.isfile(lc_path):
            with open(lc_path, "r", encoding="utf-8") as f:
                lc = json.load(f)
            if expanded in lc:
                conv_id = lc[expanded]
            else:
                for k, v in lc.items():
                    if os.path.realpath(os.path.expanduser(k)) == real_target:
                        conv_id = v
                        break
        if conv_id:
            mpath = os.path.expanduser(f"~/.gemini/antigravity-cli/brain/{conv_id}/.system_generated/swarm/members.json")
            if os.path.isfile(mpath):
                with open(mpath, "r", encoding="utf-8") as f:
                    mdata = json.load(f)
                members = mdata.get("members") or {}
                alive = 0
                working = 0
                for m in members.values():
                    if m.get("killed") or m.get("phase") == "KILLED":
                        continue
                    alive += 1
                    cid = m.get("conversation_id", "")
                    tpath = os.path.expanduser(f"~/.gemini/antigravity-cli/brain/{cid}/.system_generated/logs/transcript.jsonl")
                    is_wait = False
                    if cid and os.path.isfile(tpath):
                        try:
                            with open(tpath, "rb") as tf:
                                tf.seek(0, os.SEEK_END)
                                sz = tf.tell()
                                tf.seek(max(0, sz - 16384))
                                tail = tf.read().decode("utf-8", errors="ignore").splitlines()
                            objs = []
                            for ln in tail[-6:]:
                                ln = ln.strip()
                                if ln.startswith("{"):
                                    try:
                                        objs.append(json.loads(ln))
                                    except Exception:
                                        pass
                            if objs:
                                last = objs[-1]
                                if last.get("type") == "PLANNER_RESPONSE" and last.get("status") == "DONE" and not last.get("tool_calls"):
                                    is_wait = True
                                elif last.get("type") == "GENERIC" and last.get("status") == "DONE":
                                    if "Waiting for a message" in (last.get("content") or ""):
                                        is_wait = True
                                    elif len(objs) >= 2 and objs[-2].get("type") == "PLANNER_RESPONSE":
                                        tcs = objs[-2].get("tool_calls") or []
                                        if any(tc.get("name") == "swarm_wait" for tc in tcs):
                                            is_wait = True
                        except Exception:
                            is_wait = (m.get("wake_mode") != "working")
                    else:
                        is_wait = (m.get("wake_mode") != "working")
                    if not is_wait:
                        working += 1
                if alive > 0:
                    parts.append(f"swarm {working}/{alive}")
except Exception:
    pass

# 2. Lowest cached 5h quota %
try:
    if quota_path and os.path.isfile(quota_path):
        with open(quota_path, "r", encoding="utf-8") as f:
            qdata = json.load(f)
        groups = ((qdata.get("command") or {}).get("data") or {}).get("groups") or []
        pcts = []
        for g in groups:
            for b in g.get("buckets") or []:
                if b.get("window") == "5h" and isinstance(b.get("remaining_fraction"), (int, float)):
                    pcts.append(int(round(b["remaining_fraction"] * 100)))
        if pcts:
            parts.append(f"Q:{min(pcts)}%")
except Exception:
    pass

if parts:
    print(" · ".join(parts))
PY
}

# Renders 2 sticky metadata lines (pinned via fzf `--preview-window=~2,follow`)
# followed by the full 120-line ANSI scrollback of the target pane.
preview_pane() {
	local pane_id="${1:-}"
	local label="${2:-}"
	local state="${3:-}"
	local target="${4:-}"
	local spath="${5:-}"
	local model="${6:-}"

	[ -n "$pane_id" ] || exit 0

	local prev_cols="${FZF_PREVIEW_COLUMNS:-76}"
	local rule_max=$(( prev_cols > 2 ? prev_cols - 1 : 40 ))
	tmux capture-pane -e -p -t "$pane_id" -S -120 2>/dev/null | awk -v rmax="$rule_max" '
		BEGIN {
			rule = ""
			for (i = 0; i < rmax; i++) rule = rule "─"
		}
		{
			plain = $0
			gsub(/\033\[[0-9;?]*[ -\/]*[@-~]/, "", plain)
			if (plain ~ /^[[:space:]]*[─━═-]{15,}[[:space:]]*$/) {
				lines[++n] = "\033[2m" rule "\033[0m"
			} else {
				lines[++n] = $0
			}
			if (plain ~ /[^[:space:]]/) last = n
		}
		END {
			for (i = 1; i <= last; i++) print lines[i]
		}
	'

	# agy panes: append compact swarm roster at the bottom (visible with follow).
	if [ "$label" = "agy" ]; then
		ROSTER_COMPACT=1 preview_roster "$spath"
	fi
}

# Render agy Swarm Roster + recent board messages (exact 2-line sticky header + body).
# Reads local JSON only (~20ms, zero network).
preview_roster() {
	local spath="${1:-}"
	local cols="${FZF_PREVIEW_COLUMNS:-76}"
	if ! command -v python3 >/dev/null 2>&1; then
		printf '\033[1;36mSwarm Roster\033[0m\n\033[2mThiếu python3 để đọc dữ liệu swarm\033[0m\n'
		return 0
	fi

	python3 - "$spath" "$cols" <<'PY'
import glob, json, os, sys, time
from datetime import datetime

SPIN = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
spin_ch = SPIN[int(time.time() / 0.18) % len(SPIN)]

spath = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    cols = max(40, int(sys.argv[2]))
except Exception:
    cols = 76
max_w = max(36, cols - 2)

def trunc(s, n):
    s = (s or "").replace("\r", " ").replace("\n", " ").strip()
    if len(s) <= n:
        return s
    return (s[: max(1, n - 2)] + "..") if n > 2 else s[:n]

def short_model(m):
    if not m:
        return "—"
    m = m.replace("gemini-", "g-").replace("-medium", "-med").replace("-high", "-hi").replace("-low", "-lo")
    return m

def detect_state(member):
    if member.get("killed") or member.get("phase") == "KILLED":
        return "killed"
    cid = member.get("conversation_id", "")
    tpath = os.path.expanduser(f"~/.gemini/antigravity-cli/brain/{cid}/.system_generated/logs/transcript.jsonl")
    if cid and os.path.isfile(tpath):
        try:
            with open(tpath, "rb") as f:
                f.seek(0, os.SEEK_END)
                sz = f.tell()
                f.seek(max(0, sz - 16384))
                tail = f.read().decode("utf-8", errors="ignore").splitlines()
            objs = []
            for ln in tail[-8:]:
                ln = ln.strip()
                if ln.startswith("{"):
                    try:
                        objs.append(json.loads(ln))
                    except Exception:
                        pass
            if objs:
                last = objs[-1]
                if last.get("type") == "PLANNER_RESPONSE" and last.get("status") == "DONE" and not last.get("tool_calls"):
                    return "waiting"
                if last.get("type") == "GENERIC" and last.get("status") == "DONE":
                    if "Waiting for a message" in (last.get("content") or ""):
                        return "waiting"
                    if len(objs) >= 2 and objs[-2].get("type") == "PLANNER_RESPONSE":
                        tcs = objs[-2].get("tool_calls") or []
                        if any(tc.get("name") == "swarm_wait" for tc in tcs):
                            return "waiting"
                return "working"
        except Exception:
            pass
    return "working" if member.get("wake_mode") == "working" else "waiting"

def load_swarm(conv_id):
    sdir = os.path.expanduser(f"~/.gemini/antigravity-cli/brain/{conv_id}/.system_generated/swarm")
    mpath = os.path.join(sdir, "members.json")
    if not os.path.isfile(mpath):
        return None
    try:
        with open(mpath, "r", encoding="utf-8") as f:
            mdata = json.load(f)
    except Exception:
        return None
    plan = {}
    ppath = os.path.join(sdir, "plan.json")
    if os.path.isfile(ppath):
        try:
            with open(ppath, "r", encoding="utf-8") as f:
                plan = json.load(f)
        except Exception:
            plan = {}
    board = []
    head_seq = 0
    bpath = os.path.join(sdir, "board.jsonl")
    if os.path.isfile(bpath):
        try:
            with open(bpath, "r", encoding="utf-8", errors="ignore") as f:
                for ln in f:
                    ln = ln.strip()
                    if not ln:
                        continue
                    try:
                        obj = json.loads(ln)
                        board.append(obj)
                        seq = obj.get("seq", 0)
                        if isinstance(seq, int) and seq > head_seq:
                            head_seq = seq
                    except Exception:
                        pass
        except Exception:
            pass
    mtime = os.path.getmtime(mpath)
    members_raw = mdata.get("members") or {}
    members = []
    for name, m in members_raw.items():
        st = detect_state(m)
        last_read = m.get("last_read_seq", 0) or 0
        unread = max(0, head_seq - last_read) if st != "killed" else 0
        members.append({
            "name": name,
            "role": m.get("role", "worker"),
            "model": m.get("applied_model") or m.get("model") or m.get("desired_model") or "",
            "state": st,
            "unread": unread,
        })
    state_ord = {"working": 0, "waiting": 1, "killed": 2}
    role_ord = {"coordinator": 0, "worker": 1}
    members.sort(key=lambda x: (state_ord.get(x["state"], 9), role_ord.get(x["role"], 9), x["name"]))
    return {
        "conv_id": conv_id,
        "title": mdata.get("title") or conv_id[:8],
        "plan": plan,
        "members": members,
        "board": board,
        "head_seq": head_seq,
        "mtime": mtime,
    }

# Match pane path -> conversation_id
matched_conv = None
if spath:
    expanded = os.path.expanduser(spath)
    real_target = os.path.realpath(expanded)
    lc_path = os.path.expanduser("~/.gemini/antigravity-cli/cache/last_conversations.json")
    if os.path.isfile(lc_path):
        try:
            with open(lc_path, "r", encoding="utf-8") as f:
                lc = json.load(f)
            if expanded in lc:
                matched_conv = lc[expanded]
            else:
                for k, v in lc.items():
                    if os.path.realpath(os.path.expanduser(k)) == real_target:
                        matched_conv = v
                        break
        except Exception:
            pass

# Discover all swarms sorted by mtime desc
swarm_files = sorted(
    glob.glob(os.path.expanduser("~/.gemini/antigravity-cli/brain/*/.system_generated/swarm/members.json")),
    key=lambda p: os.path.getmtime(p) if os.path.exists(p) else 0,
    reverse=True,
)
all_conv_ids = []
for sf in swarm_files:
    parts = sf.split(os.sep)
    if "brain" in parts:
        idx = parts.index("brain")
        if idx + 1 < len(parts):
            all_conv_ids.append(parts[idx + 1])

primary = load_swarm(matched_conv) if matched_conv else None
is_fallback = False

if os.environ.get("ROSTER_COMPACT") == "1":
    rule_c = "\033[2m" + ("─" * max_w) + "\033[0m"
    print()
    print(rule_c)
    if primary is None:
        print("\033[1;36mSwarm\033[0m \033[2m· không có swarm cho pane này · [s] xem tất cả\033[0m")
        sys.exit(0)
    alive_c = [m for m in primary["members"] if m["state"] != "killed"]
    work_c = [m for m in alive_c if m["state"] == "working"]
    stats_c = f"{len(work_c)}/{len(alive_c)} working · #{primary['head_seq']}"
    print(f"\033[1;36mSwarm\033[0m \033[1m{trunc(primary['title'], max(10, max_w - len(stats_c) - 9))}\033[0m \033[2m· {stats_c}\033[0m")
    name_w = min(15, max(8, max((len(m["name"]) for m in alive_c), default=8)))
    model_w = max(8, max_w - (9 + 2 + name_w + 2 + 6 + 2))
    for m in alive_c:
        st = m["state"]
        st_fmt = f"\033[1;33m{spin_ch} working\033[0m" if st == "working" else "\033[36m◌ waiting\033[0m"
        ur = f"+{m['unread']}" if m["unread"] > 0 else ""
        print(f"{st_fmt}  \033[1m{trunc(m['name'], name_w):<{name_w}}\033[0m  \033[2m{trunc(short_model(m['model']), model_w):<{model_w}}\033[0m  \033[33m{ur:>6}\033[0m")
    for msg in primary["board"][-3:]:
        txt = (msg.get("text") or "").strip()
        first = " ".join(txt.splitlines()[0].split()) if txt else ""
        pre = f"#{msg.get('seq', '?')} {msg.get('agent', '?')}: "
        print(f"\033[2m{pre}{trunc(first, max(10, max_w - len(pre)))}\033[0m")
    sys.exit(0)

if primary is None and all_conv_ids:
    primary = load_swarm(all_conv_ids[0])
    is_fallback = True

if primary is None:
    print(f"\033[1;36mSwarm Roster\033[0m  \033[2m· [s] quay lại\033[0m")
    print(f"\033[2m{trunc(spath or '—', max_w)}\033[0m")
    print()
    print("\033[2mKhông có swarm nào đang hoạt động.\033[0m")
    sys.exit(0)

alive = [m for m in primary["members"] if m["state"] != "killed"]
working = [m for m in alive if m["state"] == "working"]
rule = "\033[2m" + ("─" * max_w) + "\033[0m"

# Exact 2-line sticky header (~2)
tag = "gần nhất" if is_fallback else "pane này"
title_budget = max(10, max_w - (6 + len(tag) + 19))
hdr_title = trunc(primary["title"], title_budget)
print(f"\033[1;36mSwarm\033[0m \033[1m{hdr_title}\033[0m \033[2m({tag}) · [s] quay lại\033[0m")

goal = (primary["plan"].get("goal") or {})
goal_line = goal.get("line") or goal.get("title") or spath or primary["conv_id"][:8]
stats = f"{len(working)}/{len(alive)} working · #{primary['head_seq']}"
line2 = trunc(f"{stats}  ·  {goal_line}", max_w)
print(f"\033[2m{line2}\033[0m")

if is_fallback and spath:
    notice_path = trunc(spath, max(8, max_w - 53))
    notice = trunc(f"Pane ({notice_path}) không có swarm — hiển thị swarm mới nhất.", max_w - 2)
    print(f"\033[33m!\033[0m \033[2m{notice}\033[0m")

print(rule)
if goal.get("title"):
    print(f"\033[1mGoal:\033[0m {trunc(goal.get('title'), max_w - 6)}")
    if goal.get("line") and goal.get("line") != goal.get("title"):
        print(f"      \033[2m{trunc(goal.get('line'), max_w - 6)}\033[0m")
    print()

# Member table
# Columns: STATE(9) NAME(14) ROLE(5) MODEL(flex) UNREAD(5)
name_w = min(15, max(10, max(len(m["name"]) for m in primary["members"]) if primary["members"] else 10))
model_w = max(10, max_w - (9 + 2 + name_w + 2 + 5 + 2 + 6 + 2))
print(f"\033[2m{'STATE':<9}  {'NAME':<{name_w}}  {'ROLE':<5}  {'MODEL':<{model_w}}  {'UNREAD':>6}\033[0m")

for m in primary["members"]:
    st = m["state"]
    if st == "working":
        st_fmt = f"\033[1;33m{spin_ch} working\033[0m"
    elif st == "waiting":
        st_fmt = "\033[36m◌ waiting\033[0m"
    else:
        st_fmt = "\033[2;31m✕ killed \033[0m"
    nm = trunc(m["name"], name_w)
    rl = "coord" if m["role"] == "coordinator" else "work "
    md = trunc(short_model(m["model"]), model_w)
    ur = f"+{m['unread']}" if m["unread"] > 0 else "0"
    if st == "killed":
        print(f"{st_fmt}  \033[2m{nm:<{name_w}}  {rl:<5}  {md:<{model_w}}  {'—':>6}\033[0m")
    else:
        ur_fmt = f"\033[1;33m{ur:>6}\033[0m" if m["unread"] > 0 else f"\033[2m{ur:>6}\033[0m"
        print(f"{st_fmt}  \033[1m{nm:<{name_w}}\033[0m  \033[2m{rl:<5}  {md:<{model_w}}\033[0m  {ur_fmt}")

# Recent board messages
board = primary["board"]
print()
print(f"\033[1mBoard\033[0m \033[2m({len(board)} tin nhắn, mới nhất bên dưới)\033[0m")
print(rule)
if not board:
    print("\033[2mChưa có tin nhắn nào trên board.\033[0m")
else:
    for msg in board[-10:]:
        seq = msg.get("seq", "?")
        ag = msg.get("agent", "?")
        tm = (msg.get("time") or "")
        hhmm = tm[11:16] if len(tm) >= 16 else ""
        txt = (msg.get("text") or "").replace("\r", " ").strip()
        first_line = " ".join(txt.splitlines()[0].split()) if txt else ""
        prefix = f"#{seq} {ag}" + (f" ({hhmm})" if hhmm else "") + ": "
        body_budget = max(12, max_w - len(prefix))
        print(f"\033[36m#{seq}\033[0m \033[1m{ag}\033[0m\033[2m{(' ' + hhmm) if hhmm else ''}\033[0m: {trunc(first_line, body_budget)}")

# Other active swarms summary
others = [cid for cid in all_conv_ids if cid != primary["conv_id"]][:4]
if others:
    print()
    print(f"\033[1mSwarm khác\033[0m")
    print(rule)
    for cid in others:
        sw = load_swarm(cid)
        if not sw:
            continue
        o_alive = [m for m in sw["members"] if m["state"] != "killed"]
        o_work = [m for m in o_alive if m["state"] == "working"]
        ts_str = datetime.fromtimestamp(sw["mtime"]).strftime("%m-%d %H:%M")
        suffix = f"({len(o_work)}/{len(o_alive)} working · #{sw['head_seq']})"
        otitle = trunc(sw["title"], max(8, max_w - len(ts_str) - len(suffix) - 4))
        print(f"\033[2m{ts_str}\033[0m  {otitle}  \033[2m{suffix}\033[0m")
PY
}

# Spawn detached background refresh for agy /quota and /credits (never blocks UI).
# Args: <force: 0|1> [sock_file]
spawn_quota_refresh() {
	local force="${1:-0}"
	local sock_file="${2:-}"
	local ttl="${3:-$QUOTA_TTL}"
	local rows_cache="${4:-}"
	mkdir -p -m 700 "$CACHE_BASE"

	local want_agy=1 want_codex=1 want_claude=1
	if [ -n "$rows_cache" ] && [ -s "$rows_cache" ]; then
		want_agy=0; want_codex=0; want_claude=0
		local active_list
		active_list="$(awk -F'\t' '$8 != "pane" { a[$7]=1 } END { for (k in a) printf " %s ", k }' "$rows_cache" 2>/dev/null || true)"
		[[ "$active_list" == *" agy "* ]] && want_agy=1
		[[ "$active_list" == *" codex "* ]] && want_codex=1
		[[ "$active_list" == *" claude "* ]] && want_claude=1
		if [ "$want_agy" -eq 0 ] && [ "$want_codex" -eq 0 ] && [ "$want_claude" -eq 0 ]; then
			return 0
		fi
	fi

	local now mtime age ref_cache="$QUOTA_CACHE"
	printf -v now '%(%s)T' -1
	if [ "$want_agy" -eq 0 ]; then
		if [ "$want_codex" -eq 1 ]; then ref_cache="$CODEX_QUOTA_CACHE"
		elif [ "$want_claude" -eq 1 ]; then ref_cache="$CLAUDE_QUOTA_CACHE"
		fi
	fi
	if [ "$force" != "1" ] && [ -s "$ref_cache" ]; then
		mtime="$(stat -c %Y "$ref_cache" 2>/dev/null || echo 0)"
		age=$((now - mtime))
		if [ "$age" -lt "$ttl" ]; then
			return 0
		fi
	fi

	# Clean up stale lock (> 30s)
	if [ -d "$QUOTA_LOCK" ]; then
		local lock_m
		lock_m="$(stat -c %Y "$QUOTA_LOCK" 2>/dev/null || echo 0)"
		if [ $((now - lock_m)) -gt 30 ]; then
			rm -rf "$QUOTA_LOCK" 2>/dev/null || true
		fi
	fi

	(
		if ! mkdir "$QUOTA_LOCK" 2>/dev/null; then
			exit 0
		fi
		trap 'rm -rf "$QUOTA_LOCK" 2>/dev/null || true' EXIT

		local q_tmp="${QUOTA_CACHE}.tmp.$$"
		local c_tmp="${CREDITS_CACHE}.tmp.$$"
		local cx_tmp="${CODEX_QUOTA_CACHE}.tmp.$$"
		local cl_tmp="${CLAUDE_QUOTA_CACHE}.tmp.$$"
		local e_tmp="${QUOTA_ERR}.tmp.$$"
		local q_rc=0 c_rc=0 cx_rc=0 cl_rc=0 p_q="" p_c="" p_cx="" p_cl=""

		if [ "$want_agy" -eq 1 ] && command -v agy >/dev/null 2>&1; then
			timeout 10 agy -p "/quota" --output-format json >"$q_tmp" 2>/dev/null &
			p_q=$!
			timeout 10 agy -p "/credits" --output-format json >"$c_tmp" 2>/dev/null &
			p_c=$!
		fi

		local codex_bin=""
		if [ "$want_codex" -eq 1 ]; then
			codex_bin="$(command -v codex 2>/dev/null || ls -d "$HOME"/.local/share/fnm/node-versions/*/installation/bin/codex 2>/dev/null | tail -n1 || true)"
		fi
		if [ -n "$codex_bin" ] && command -v python3 >/dev/null 2>&1; then
			python3 - "$codex_bin" "$cx_tmp" <<'PY' 2>/dev/null &
import json, os, select, subprocess, sys, time
cbin, out_path = sys.argv[1], sys.argv[2]
try:
    p = subprocess.Popen([cbin, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    for r in (
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"clientInfo": {"name": "tmux-agents", "version": "1.0"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": {}},
    ):
        p.stdin.write(json.dumps(r) + "\n")
    p.stdin.flush()
    t0 = time.time()
    res = None
    while time.time() - t0 < 5.5:
        rd, _, _ = select.select([p.stdout], [], [], 0.2)
        if rd:
            ln = p.stdout.readline()
            if not ln:
                break
            try:
                obj = json.loads(ln)
                if obj.get("id") == 2:
                    res = obj
                    break
            except Exception:
                pass
    p.terminate()
    try:
        p.wait(timeout=1)
    except Exception:
        p.kill()
    if res and "result" in res:
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(res["result"], f)
except Exception:
    pass
PY
			p_cx=$!
		fi

		if [ "$want_claude" -eq 1 ] && command -v python3 >/dev/null 2>&1; then
			python3 - "$cl_tmp" <<'PY' 2>/dev/null &
import json, os, sys, urllib.error, urllib.request
out_path = sys.argv[1]
home = os.path.expanduser("~")
settings_path = os.path.join(home, ".claude", "settings.json")
creds_path = os.path.join(home, ".claude", ".credentials.json")
stats_path = os.path.join(home, ".claude", "stats-cache.json")
res = {"source": "none", "status": "unavailable"}

env = {}
try:
    env = json.load(open(settings_path, encoding="utf-8")).get("env") or {}
except Exception:
    pass
base = (env.get("ANTHROPIC_BASE_URL") or "").rstrip("/")
tok = env.get("ANTHROPIC_AUTH_TOKEN") or env.get("ANTHROPIC_API_KEY") or ""

if tok and "openrouter.ai" in base:
    res["source"] = "openrouter"
    try:
        req = urllib.request.Request("https://openrouter.ai/api/v1/auth/key", headers={"Authorization": f"Bearer {tok}"})
        with urllib.request.urlopen(req, timeout=4) as resp:
            res["status"] = "ok"
            res["data"] = (json.load(resp) or {}).get("data") or {}
    except urllib.error.HTTPError as e:
        res["status"] = f"http_{e.code}"
    except Exception:
        res["status"] = "error"
elif os.path.isfile(creds_path):
    try:
        creds = json.load(open(creds_path, encoding="utf-8"))
        if "claudeAiOauth" in creds:
            res["source"] = "oauth"
            res["status"] = "oauth_present"
        else:
            res["source"] = "local"
            res["status"] = "no_oauth"
    except Exception:
        pass

if os.path.isfile(stats_path):
    try:
        st = json.load(open(stats_path, encoding="utf-8"))
        mu = st.get("modelUsage") or {}
        tot_in = sum((v or {}).get("inputTokens", 0) for v in mu.values())
        tot_out = sum((v or {}).get("outputTokens", 0) for v in mu.values())
        res["local_tokens"] = tot_in + tot_out
        res["last_date"] = st.get("lastComputedDate") or ""
    except Exception:
        pass

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(res, f)
PY
			p_cl=$!
		fi

		[ -n "$p_q" ] && { wait "$p_q" || q_rc=$?; }
		[ -n "$p_c" ] && { wait "$p_c" || c_rc=$?; }
		[ -n "$p_cx" ] && { wait "$p_cx" || cx_rc=$?; }
		[ -n "$p_cl" ] && { wait "$p_cl" || cl_rc=$?; }

		if [ -n "$p_q" ]; then
			if [ "$q_rc" -eq 0 ] && [ -s "$q_tmp" ] && head -c 1 "$q_tmp" | grep -q '{'; then
				mv -f "$q_tmp" "$QUOTA_CACHE"
				rm -f "$QUOTA_ERR" "$e_tmp"
			else
				rm -f "$q_tmp"
				if [ "$q_rc" -eq 2 ]; then
					printf 'api_key\tChế độ GEMINI_API_KEY không có account quota (exit 2)\n' >"$e_tmp"
				elif [ "$q_rc" -eq 124 ]; then
					printf 'timeout\tHết thời gian chờ agy /quota (timeout 10s)\n' >"$e_tmp"
				else
					printf 'error\tKhông lấy được quota từ agy (exit %d)\n' "$q_rc" >"$e_tmp"
				fi
				mv -f "$e_tmp" "$QUOTA_ERR"
			fi
		fi

		if [ -n "$p_c" ] && [ "$c_rc" -eq 0 ] && [ -s "$c_tmp" ] && head -c 1 "$c_tmp" | grep -q '{'; then
			mv -f "$c_tmp" "$CREDITS_CACHE"
		else
			rm -f "$c_tmp"
		fi

		if [ -s "$cx_tmp" ] && head -c 1 "$cx_tmp" | grep -q '{'; then
			mv -f "$cx_tmp" "$CODEX_QUOTA_CACHE"
		else
			rm -f "$cx_tmp"
		fi

		if [ -s "$cl_tmp" ] && head -c 1 "$cl_tmp" | grep -q '{'; then
			mv -f "$cl_tmp" "$CLAUDE_QUOTA_CACHE"
		else
			rm -f "$cl_tmp"
		fi

		if [ -n "$sock_file" ] && [ -S "$sock_file" ] && command -v curl >/dev/null 2>&1; then
			curl -fsS --max-time 1 --unix-socket "$sock_file" http://localhost -d 'refresh-preview' >/dev/null 2>&1 || true
		fi
	) </dev/null >/dev/null 2>&1 &
}

# Trigger async quota refresh from Ctrl-r: force if currently in quota mode, else only if stale.
refresh_quota_smart() {
	local pmode_file="${1:-}"
	local sock_file="${2:-}"
	local pm="pane"
	[ -n "$pmode_file" ] && [ -f "$pmode_file" ] && pm="$(cat "$pmode_file" 2>/dev/null || echo pane)"
	if [ "$pm" = "quota" ]; then
		spawn_quota_refresh 1 "$sock_file"
	else
		spawn_quota_refresh 0 "$sock_file"
	fi
}

# Render agy Model Quota & Credits from local cache (exact 2-line sticky header + body).
preview_quota() {
	local cols="${FZF_PREVIEW_COLUMNS:-76}"
	if ! command -v python3 >/dev/null 2>&1; then
		printf '\033[1;35magy Quota & Credits\033[0m\n\033[2mThiếu python3 để hiển thị quota\033[0m\n'
		return 0
	fi

	python3 - "$QUOTA_CACHE" "$CREDITS_CACHE" "$QUOTA_ERR" "$QUOTA_LOCK" "$cols" <<'PY'
import json, os, sys, time
from datetime import datetime, timezone

qpath, cpath, epath, lpath = sys.argv[1:5]
try:
    cols = max(40, int(sys.argv[5]))
except Exception:
    cols = 76
max_w = max(36, cols - 2)
rule = "\033[2m" + ("─" * max_w) + "\033[0m"

def trunc(s, n):
    s = (s or "").replace("\r", " ").replace("\n", " ").strip()
    if len(s) <= n:
        return s
    return (s[: max(1, n - 2)] + "..") if n > 2 else s[:n]

def fmt_age(sec):
    sec = max(0, int(sec))
    if sec < 15:
        return "vừa xong"
    if sec < 60:
        return f"{sec}s trước"
    if sec < 3600:
        return f"{sec // 60}m trước"
    return f"{sec // 3600}h trước"

def fmt_reset(iso_str):
    if not iso_str or iso_str.startswith("1970-01-01"):
        return "full · —"
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        now = datetime.now(timezone.utc)
        local_dt = dt.astimezone()
        diff = int((dt - now).total_seconds())
        if diff <= 0:
            cd = "sắp reset"
        elif diff < 3600:
            cd = f"{diff // 60}m"
        elif diff < 86400:
            h, rem = divmod(diff, 3600)
            cd = f"{h}h {rem // 60}m"
        else:
            d, rem = divmod(diff, 86400)
            h = rem // 3600
            cd = f"{d}d {h}h"
        if diff < 86400:
            ts = local_dt.strftime("%H:%M")
        else:
            ts = local_dt.strftime("%d/%m %H:%M")
        return f"reset {ts} ({cd})"
    except Exception:
        return iso_str

def render_bar(pct, width=16):
    pct = max(0, min(100, int(pct)))
    filled = int(round(pct * width / 100.0))
    empty = width - filled
    if pct >= 50:
        col = "\033[32m"
    elif pct >= 20:
        col = "\033[33m"
    else:
        col = "\033[31m"
    return f"{col}{'█' * filled}\033[2m{'░' * empty}\033[0m"

is_fetching = os.path.isdir(lpath)
qdata = None
q_age = None
if os.path.isfile(qpath):
    try:
        with open(qpath, "r", encoding="utf-8") as f:
            qdata = json.load(f)
        q_age = time.time() - os.path.getmtime(qpath)
    except Exception:
        qdata = None
        q_age = None

cdata = None
if os.path.isfile(cpath):
    try:
        with open(cpath, "r", encoding="utf-8") as f:
            cdata = json.load(f)
    except Exception:
        cdata = None

err_msg = None
if os.path.isfile(epath):
    try:
        raw = open(epath, "r", encoding="utf-8").read().strip()
        err_msg = raw.split("\t", 1)[1] if "\t" in raw else raw
    except Exception:
        err_msg = None

credits_val = None
upgrade_uri = None
if cdata:
    cd = (cdata.get("command") or {}).get("data") or {}
    if "remaining_credits" in cd:
        credits_val = cd.get("remaining_credits")
    upgrade_uri = cd.get("upgrade_uri")

# Exact 2-line sticky header (~2)
if max_w >= 62:
    print(f"\033[1;35magy Quota & Credits\033[0m  \033[2m· [u] quay lại · auto 2s\033[0m")
elif max_w >= 46:
    print(f"\033[1;35magy Quota & Credits\033[0m \033[2m· [u] · 2s\033[0m")
else:
    print(f"\033[1;35magy Quota\033[0m \033[2m· [u] · 2s\033[0m")
status_parts = []
if q_age is not None:
    status_parts.append(f"cập nhật {fmt_age(q_age)}")
elif is_fetching:
    status_parts.append("đang tải dữ liệu...")
else:
    status_parts.append("chưa có cache")
if is_fetching and q_age is not None:
    status_parts.append("đang làm mới...")
if credits_val is not None:
    status_parts.append(f"AI Credits: {credits_val}")
print(f"\033[2m{trunc('  ·  '.join(status_parts), max_w)}\033[0m")

print(rule)

if err_msg:
    print(f"\033[1;33m!\033[0m \033[33m{trunc(err_msg, max_w - 2)}\033[0m")
    if qdata:
        print("\033[2mHiển thị dữ liệu cache gần nhất:\033[0m")
    print()

if qdata is None:
    if is_fetching:
        print("\033[33m⠋ Đang tải quota từ agy (/quota & /credits)...\033[0m")
        print("\033[2mMàn hình sẽ tự động cập nhật sau ~3–4 giây.\033[0m")
    elif not err_msg:
        print("\033[2mChưa có dữ liệu quota. Nhấn Ctrl-r để tải.\033[0m")
    sys.exit(0)

groups = ((qdata.get("command") or {}).get("data") or {}).get("groups") or []
bar_w = 18 if max_w >= 64 else 12

for g in groups:
    gname = g.get("name") or "Models"
    gdesc = g.get("description") or ""
    if gdesc.startswith("Models within this group: "):
        gdesc = gdesc[len("Models within this group: "):]
    print(f"\033[1m{gname}\033[0m")
    if gdesc:
        print(f"\033[2m{trunc(gdesc, max_w)}\033[0m")
    buckets = g.get("buckets") or []
    # Sort weekly first, then 5h underneath
    buckets = sorted(buckets, key=lambda b: 0 if b.get("window") == "weekly" else (1 if b.get("window") == "5h" else 2))
    for b in buckets:
        win = b.get("window") or b.get("name") or ""
        wlabel = "5h    " if win == "5h" else ("weekly" if win == "weekly" else f"{win:<6}")
        frac = b.get("remaining_fraction")
        pct = int(round(frac * 100)) if isinstance(frac, (int, float)) else 0
        bar = render_bar(pct, bar_w)
        rtxt = fmt_reset(b.get("reset_time") or "")
        pct_col = "\033[1;32m" if pct >= 50 else ("\033[1;33m" if pct >= 20 else "\033[1;31m")
        print(f"  \033[2m{wlabel}\033[0m  {bar}  {pct_col}{pct:>3}%\033[0m  \033[2m{trunc(rtxt, max(12, max_w - bar_w - 18))}\033[0m")
    print()

# Credits footer
print(f"\033[1mAI Credits\033[0m")
print(rule)
if credits_val is not None:
    c_col = "\033[1;32m" if credits_val > 0 else "\033[2m"
    print(f"  Remaining: {c_col}{credits_val}\033[0m")
    if upgrade_uri and credits_val == 0:
        print(f"  \033[2mUpgrade: {trunc(upgrade_uri, max_w - 11)}\033[0m")
else:
    print("  \033[2mĐang tải hoặc không khả dụng.\033[0m")
PY
}

# Compact quota block for fzf footer (left column, under agents list). Local cache only.
# Shows quota only for agents currently running in tmux panes.
# Args: <width> [rows_cache]
footer_quota() {
	local w="${1:-40}"
	local rows_cache="${2:-}"
	local active_agents=""
	if [ -n "$rows_cache" ] && [ -f "$rows_cache" ]; then
		active_agents="$(awk -F'\t' '$8 != "pane" { a[$7]=1 } END { for (k in a) printf "%s ", k }' "$rows_cache" 2>/dev/null || true)"
	else
		active_agents="$(scan_tty_agents | awk -F'\t' '{ a[$2]=1 } END { for (k in a) printf "%s ", k }' 2>/dev/null || true)"
	fi
	command -v python3 >/dev/null 2>&1 || return 0
	python3 - "$QUOTA_CACHE" "$CREDITS_CACHE" "$CODEX_QUOTA_CACHE" "$CLAUDE_QUOTA_CACHE" "$QUOTA_LOCK" "$w" "$active_agents" <<'PY'
import json, os, sys, time
from datetime import datetime, timezone

qp, cp, cxp, clp, lp, w = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6])
active = set(sys.argv[7].split())

def cd_ts(ts):
    if not ts:
        return ""
    d = int(ts - time.time())
    if d <= 0: return "now"
    if d < 3600: return f"{d // 60}m"
    if d < 86400: return f"{d // 3600}h{(d % 3600) // 60:02d}m"
    return f"{d // 86400}d{(d % 86400) // 3600}h"

def cd(iso):
    if not iso or iso.startswith("1970-01-01"):
        return "full"
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return cd_ts(dt.timestamp())
    except Exception:
        return ""

def win_label(mins):
    if not mins: return "win"
    if mins <= 360: return f"{mins // 60}h"
    if mins <= 1440: return "1d"
    if mins == 10080: return "wk"
    return f"{mins // 1440}d"

def bar(p, n):
    p = max(0, min(100, int(p)))
    f = int(round(p * n / 100.0))
    c = "\033[32m" if p >= 50 else ("\033[33m" if p >= 20 else "\033[31m")
    return f"{c}{'█' * f}\033[2m{'░' * (n - f)}\033[0m"

def load_json(p):
    try:
        return json.load(open(p, encoding="utf-8")), int(time.time() - os.path.getmtime(p))
    except Exception:
        return None, None

q, q_age = load_json(qp)
c, _ = load_json(cp)
cx, cx_age = load_json(cxp)
cl, _ = load_json(clp)

cred = ((c or {}).get("command") or {}).get("data", {}).get("remaining_credits") if c else None
fetching = os.path.isdir(lp)
age = q_age if q_age is not None else cx_age
info = []
if age is not None: info.append(f"{age}s" if age < 60 else f"{age // 60}m")
if fetching: info.append("⟳")
if cred is not None: info.append(f"credits {cred}")
print("\033[1;35mQuota:\033[0m" + ("\033[2m · " + " · ".join(info) + "\033[0m" if info else ""))

bw = max(6, min(11, w - 30))

if not (active & {"agy", "codex", "claude"}):
    print("  \033[2mKhông có agent đang chạy\033[0m")
    sys.exit(0)

# 1. agy
if "agy" in active:
    print("\033[1;36m󱓞 agy\033[0m")
    if q is None:
        print("  \033[2m" + ("đang tải..." if fetching else "chưa có dữ liệu") + "\033[0m")
    else:
        for g in ((q.get("command") or {}).get("data") or {}).get("groups") or []:
            name = ((g.get("name") or "?").split() or ["?"])[0][:6]
            bs = sorted(g.get("buckets") or [], key=lambda b: 0 if b.get("window") == "weekly" else 1)
            for i, b in enumerate(bs):
                win = b.get("window") or "?"
                lab = "wk" if win == "weekly" else win
                fr = b.get("remaining_fraction")
                p = int(round(fr * 100)) if isinstance(fr, (int, float)) else 0
                pc = "\033[32m" if p >= 50 else ("\033[33m" if p >= 20 else "\033[31m")
                nm = f"\033[1m{name:<6}\033[0m" if i == 0 else " " * 6
                print(f"  {nm} \033[2m{lab:<3}\033[0m {bar(p, bw)} {pc}{p:>3}%\033[0m \033[2m{cd(b.get('reset_time') or '')}\033[0m")

# 2. codex
if "codex" in active:
    cx_rl = (cx or {}).get("rateLimits") or {}
    cx_plan = cx_rl.get("planType") or ""
    print("\033[1;32m󰚩 codex\033[0m" + (f" \033[2m· {cx_plan}\033[0m" if cx_plan else ""))
    if cx is None:
        print("  \033[2m" + ("đang tải..." if fetching else "chưa có dữ liệu") + "\033[0m")
    else:
        wins = [x for x in (cx_rl.get("secondary"), cx_rl.get("primary")) if isinstance(x, dict)]
        if not wins:
            print("  \033[2mkhông giới hạn / chưa có rate limit\033[0m")
        for x in wins:
            used = x.get("usedPercent") or 0
            rem = max(0, min(100, int(round(100 - used))))
            lab = win_label(x.get("windowDurationMins"))
            pc = "\033[32m" if rem >= 50 else ("\033[33m" if rem >= 20 else "\033[31m")
            print(f"         \033[2m{lab:<3}\033[0m {bar(rem, bw)} {pc}{rem:>3}%\033[0m \033[2m{cd_ts(x.get('resetsAt'))}\033[0m")

# 3. claude
if "claude" in active:
    print("\033[1;33m󰜡 claude\033[0m")
    if cl is None:
        print("  \033[2m" + ("đang tải..." if fetching else "chưa có dữ liệu") + "\033[0m")
    elif cl.get("status") == "ok" and isinstance(cl.get("data"), dict):
        d = cl["data"]
        lim = d.get("limit")
        rem_usd = d.get("limit_remaining")
        usg = d.get("usage")
        if isinstance(lim, (int, float)) and lim > 0 and isinstance(rem_usd, (int, float)):
            pct = max(0, min(100, int(round(rem_usd * 100 / lim))))
            pc = "\033[32m" if pct >= 50 else ("\033[33m" if pct >= 20 else "\033[31m")
            print(f"      \033[2mkey\033[0m {bar(pct, bw)} {pc}{pct:>3}%\033[0m \033[2m${rem_usd:.2f}\033[0m")
        elif isinstance(usg, (int, float)):
            print(f"  \033[2mOpenRouter used ${usg:.2f}\033[0m")
        else:
            print("  \033[2mOpenRouter unlimited\033[0m")
    elif cl.get("source") == "openrouter":
        st = cl.get("status", "err")
        msg = "key hết hạn/401" if st == "http_401" else st
        print(f"  \033[2mOpenRouter · {msg}\033[0m")
    else:
        print("  \033[2mchưa đăng nhập OAuth\033[0m")
PY
}

# Toggle preview mode between target (roster|quota) and pane; outputs fzf actions for transform().
toggle_pmode() {
	local target="${1:-roster}"
	local pmode_file="${2:-}"
	local sock_file="${3:-}"
	local pm="pane"
	[ -n "$pmode_file" ] && [ -f "$pmode_file" ] && pm="$(cat "$pmode_file" 2>/dev/null || echo pane)"
	if [ "$pm" = "$target" ]; then
		[ -n "$pmode_file" ] && printf 'pane\n' >"$pmode_file"
		printf 'change-preview-window(right,62%%,border-left,wrap,follow)+refresh-preview'
	else
		[ -n "$pmode_file" ] && printf '%s\n' "$target" >"$pmode_file"
		if [ "$target" = "quota" ]; then
			spawn_quota_refresh 0 "$sock_file" 2
		fi
		printf 'change-preview-window(right,62%%,border-left,wrap,~2,nofollow)+refresh-preview'
	fi
}

# Dispatch preview according to per-popup preview_mode file (pane|roster|quota).
preview_dispatch() {
	local first="${1:-}"
	local pmode="pane"
	if [ -n "$first" ] && [[ "$first" != %* ]]; then
		if [ -f "$first" ]; then
			pmode="$(cat "$first" 2>/dev/null || echo pane)"
		elif [ "$first" = "pane" ] || [ "$first" = "roster" ] || [ "$first" = "quota" ]; then
			pmode="$first"
		fi
		shift
	fi

	case "$pmode" in
		roster)
			preview_roster "${5:-}"
			;;
		quota)
			preview_quota
			;;
		*)
			preview_pane "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"
			;;
	esac
}

list_keymaps() {
	cat <<'EOF' | awk -F '\t' '{
		scope = $1
		key = $2
		desc = $3
		color = "\033[36m"
		if (scope == "[State]") color = "\033[33m"
		printf "%s%-8s\033[0m  \033[1m%-18s\033[0m  %s\n", color, scope, key, desc
	}'
[Popup]	j / k	Di chuyển con trỏ xuống / lên
[Popup]	l / Enter	Mở / nhảy tới pane đang chọn (tự đánh dấu đã xem)
[Popup]	/	Mở ô tìm kiếm (trong ô tìm kiếm: Esc để quay lại j/k)
[Popup]	s	Bật / tắt khung xem agy Swarm Roster & Board
[Popup]	u	Bật / tắt khung xem agy Model Quota & AI Credits
[Popup]	q / Esc	Thoát popup
[Popup]	Ctrl-y	Duyệt nhanh / gửi phím Enter vào pane đang chọn
[Popup]	Alt-e	Gửi phím Esc (hủy / dừng tác vụ) vào pane đang chọn
[Popup]	Ctrl-s / Alt-d	Đánh dấu đã xem (done → idle) ngay tại chỗ
[Popup]	Tab / Ctrl-a	Chuyển giữa chế độ chỉ Agent / tất cả pane tmux
[Popup]	Ctrl-u / Ctrl-d	Cuộn nội dung preview lên / xuống nửa trang
[Popup]	PgUp / PgDn	Cuộn nội dung preview lên / xuống nửa trang
[Popup]	Alt-k / Alt-j	Cuộn nội dung preview lên / xuống 1 dòng
[Popup]	Ctrl-r	Làm mới trạng thái, preview (và tải lại quota ở chế độ u)
[Popup]	Alt-x / Ctrl-x	Đóng (kill) pane đang chọn
[Popup]	Ctrl-/	Ẩn / hiện khung preview bên phải
[Popup]	? / F1	Mở bảng phím tắt & chú thích trạng thái
[State]	▲/◈ blocked	Nhấp nháy đỏ/vàng — chờ bạn duyệt quyền hoặc chọn đáp án (#1)
[State]	●/◉ done	Nhịp thở xanh — vừa hoàn thành ở pane khác, chưa xem (#2)
[State]	⠋..⠏ working	Vòng xoay Braille — đang suy nghĩ / chạy tool hoặc subagent (#3)
[State]	◌ idle	Tĩnh — đang chờ lệnh tại prompt (#4)
EOF
}

fzf_theme_args() {
	local vals bg surf fg muted acc
	vals="$(tmux display-message -p '#{E:@theme-bg} #{E:@theme-surface} #{E:@theme-fg} #{E:@theme-muted} #{E:@theme-accent}' 2>/dev/null || true)"
	read -r bg surf fg muted acc <<<"$vals"
	if [[ "$surf" =~ ^#[0-9a-fA-F]{6}$ ]] && [[ "$fg" =~ ^#[0-9a-fA-F]{6}$ ]] && [[ "$muted" =~ ^#[0-9a-fA-F]{6}$ ]] && [[ "$acc" =~ ^#[0-9a-fA-F]{6}$ ]]; then
		printf -- '--color=bg+:%s,fg+:%s,hl:%s,hl+:%s,info:%s,prompt:%s,pointer:%s,marker:%s,spinner:%s,header:%s,border:%s,gutter:-1' \
			"$surf" "$fg" "$acc" "$acc" "$muted" "$acc" "$acc" "$acc" "$acc" "$muted" "$surf"
	fi
}

run_keymaps_finder() {
	local color_arg
	color_arg="$(fzf_theme_args || true)"
	list_keymaps | fzf \
		--ansi \
		${color_arg:+"$color_arg"} \
		--height=100% \
		--border=none \
		--margin=0 \
		--padding=0,1 \
		--layout=reverse \
		--no-scrollbar \
		--no-separator \
		--info=inline-right \
		--pointer='▌' \
		--prompt='/ ' \
		--header='j/k: di chuyển · /: tìm · q/l/Enter/Esc: quay lại' \
		--bind='start:hide-input' \
		--bind='j:down,k:up,l:abort,q:abort,enter:abort,?:abort,f1:abort' \
		--bind='/:show-input+unbind(j,k,l,q,/,?)' \
		--bind='esc:transform:if [ "$FZF_INPUT_STATE" = hidden ]; then echo abort; else echo "hide-input+rebind(j,k,l,q,/,?)"; fi' || true
}

jump_to_pane() {
	local pane_id="$1"
	local target
	target="$(tmux display-message -p -t "$pane_id" '#{session_name}:#{window_id}' 2>/dev/null || true)"
	[ -n "$target" ] || return 0
	local sess="${target%%:*}"
	local win="${target#*:}"

	mark_seen_pane "$pane_id"
	tmux switch-client -t "=$sess" 2>/dev/null || true
	tmux select-window -t "$win" 2>/dev/null || true
	tmux select-pane -t "$pane_id" 2>/dev/null || true
}

popup_monitor() {
	if ! command -v fzf >/dev/null 2>&1; then
		tmux display-message "tmux-agents: missing required command 'fzf'"
		exit 1
	fi

	local src_pane="${1:-}"
	if [ -z "$src_pane" ] || [[ "$src_pane" == *"#{"* ]]; then
		src_pane="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
	fi

	local self_path q_self q_src
	self_path="$(realpath "${BASH_SOURCE[0]}")"
	q_self="$(shell_quote "$self_path")"
	q_src="$(shell_quote "$src_pane")"

	mkdir -p -m 700 "$CACHE_BASE"
	local mode_file="${CACHE_BASE}/mode.$$"
	local pmode_file="${CACHE_BASE}/pmode.$$"
	local rows_cache="${CACHE_BASE}/rows.$$"
	local sock_file="${CACHE_BASE}/anim.$$.sock"
	local anim_pid=""

	cleanup() {
		if [ -n "$anim_pid" ]; then
			kill "$anim_pid" 2>/dev/null || true
		fi
		rm -f "$mode_file" "$pmode_file" "$rows_cache" "$sock_file"
	}
	trap cleanup EXIT INT TERM

	local q_mode_file q_pmode_file q_rows_cache q_sock_file
	q_mode_file="$(shell_quote "$mode_file")"
	q_pmode_file="$(shell_quote "$pmode_file")"
	q_rows_cache="$(shell_quote "$rows_cache")"
	q_sock_file="$(shell_quote "$sock_file")"
	printf 'pane\n' >"$pmode_file"

	local stty_sz inner_h inner_w left_text_w
	stty_sz="$(stty size </dev/tty 2>/dev/null || echo '30 124')"
	read -r inner_h inner_w <<<"$stty_sz"
	[ "${inner_w:-0}" -gt 0 ] 2>/dev/null || inner_w=124
	left_text_w=$(( (inner_w - 2) * 38 / 100 - 3 ))
	[ "$left_text_w" -lt 39 ] && left_text_w=39

	local mode="agents"
	local prompt="Agents > "
	local initial_list
	initial_list="$(list_entries "agents" "$src_pane" "$left_text_w" 0 0 "$rows_cache")"
	if [ -z "$initial_list" ]; then
		mode="all"
		prompt="All > "
		initial_list="$(list_entries "all" "$src_pane" "$left_text_w" 0 0 "$rows_cache")"
	fi
	printf '%s\n' "$mode" >"$mode_file"

	if [ -z "$initial_list" ]; then
		tmux display-message "tmux-agents: không có pane nào"
		exit 0
	fi

	# Background animator: ticks every 180ms via fzf's Unix socket + reload-sync (zero flicker).
	# Fast frames (use_cache=1) take <2ms and only fire when an animated state (working/blocked/done) is present.
	# Full live scans (use_cache=0) fire every 8th tick (~1.44s).
	if command -v curl >/dev/null 2>&1; then
		(
			local tick=0
			while [ ! -S "$sock_file" ] && [ "$tick" -lt 20 ]; do
				sleep 0.05
				tick=$((tick + 1))
			done
			tick=1
			while [ -S "$sock_file" ]; do
				sleep 0.18 || break
				[ -S "$sock_file" ] || break
				local cur_m="agents"
				[ -f "$mode_file" ] && cur_m="$(cat "$mode_file" 2>/dev/null || echo agents)"
				if [ $((tick % 8)) -eq 0 ]; then
					curl -fsS --max-time 1 --unix-socket "$sock_file" http://localhost \
						-d "reload-sync(${q_self} --list ${cur_m} ${q_src} ${left_text_w} ${tick} 0 ${q_rows_cache})" >/dev/null 2>&1 || true
				elif [ -s "$rows_cache" ] && grep -qE $'\t(working|blocked|done)\t' "$rows_cache" 2>/dev/null; then
					curl -fsS --max-time 1 --unix-socket "$sock_file" http://localhost \
						-d "reload-sync(${q_self} --list ${cur_m} ${q_src} ${left_text_w} ${tick} 1 ${q_rows_cache})" >/dev/null 2>&1 || true
				fi
				# Animate roster view (180ms) and pane+compact-roster view (360ms).
				local cur_pm="pane"
				[ -f "$pmode_file" ] && cur_pm="$(cat "$pmode_file" 2>/dev/null || echo pane)"
				if [ "$cur_pm" = "roster" ] || { [ "$cur_pm" = "pane" ] && [ $((tick % 2)) -eq 0 ]; }; then
					curl -fsS --max-time 1 --unix-socket "$sock_file" http://localhost -d 'refresh-preview' >/dev/null 2>&1 || true
				fi
				# Auto-refresh active agents' quota every ~2s (11 * 180ms = 1.98s); footer always visible on the left.
				if [ $((tick % 11)) -eq 0 ]; then
					if [ "$cur_pm" = "quota" ]; then
						spawn_quota_refresh 0 "$sock_file" 2
					else
						spawn_quota_refresh 0 "$sock_file" 2 "$rows_cache"
					fi
					curl -fsS --max-time 1 --unix-socket "$sock_file" http://localhost \
						-d "transform-footer(${q_self} --footer-quota ${left_text_w} ${q_rows_cache})" >/dev/null 2>&1 || true
					if [ "$cur_pm" = "quota" ]; then
						curl -fsS --max-time 1 --unix-socket "$sock_file" http://localhost -d 'refresh-preview' >/dev/null 2>&1 || true
					fi
				fi
				tick=$((tick + 1))
			done
		) &
		anim_pid=$!
	fi

	# Warm quota/credits cache asynchronously for running agents if missing or stale (never blocks popup).
	spawn_quota_refresh 0 "$sock_file" "$QUOTA_TTL" "$rows_cache"

	local reload_cmd="m=\$(cat ${q_mode_file} 2>/dev/null || echo agents); ${q_self} --list \"\$m\" ${q_src} ${left_text_w} 0 0 ${q_rows_cache}"
	local toggle_cmd="m=\$(cat ${q_mode_file} 2>/dev/null || echo agents); if [ \"\$m\" = agents ]; then echo all > ${q_mode_file}; echo 'change-prompt(All > )+reload-sync(${q_self} --list all ${q_src} ${left_text_w} 0 0 ${q_rows_cache})'; else echo agents > ${q_mode_file}; echo 'change-prompt(Agents > )+reload-sync(${q_self} --list agents ${q_src} ${left_text_w} 0 0 ${q_rows_cache})'; fi"

	local color_arg
	color_arg="$(fzf_theme_args || true)"

	local selected
	selected="$(
		printf '%s\n' "$initial_list" | fzf \
			--ansi \
			${color_arg:+"$color_arg"} \
			--height=100% \
			--border=none \
			--margin=0 \
			--padding=0,1 \
			--layout=reverse \
			--no-scrollbar \
			--no-separator \
			--info=inline-right \
			--pointer='▌' \
			--listen-unsafe="$sock_file" \
			--footer="$(footer_quota "$left_text_w" "$rows_cache")" \
			--footer-border=line \
			--delimiter=$'\t' \
			--with-nth=2 \
			--prompt="$prompt" \
			--header='l:mở /:tìm s:roster u:quota ?:help' \
			--bind="start:hide-input" \
			--bind="j:down,k:up,l:accept,q:abort" \
			--bind="s:transform(${q_self} --toggle-pmode roster ${q_pmode_file} ${q_sock_file})" \
			--bind="u:transform(${q_self} --toggle-pmode quota ${q_pmode_file} ${q_sock_file})" \
			--bind="/:show-input+unbind(j,k,l,q,/,?,s,u)" \
			--bind='esc:transform:if [ "$FZF_INPUT_STATE" = hidden ]; then echo abort; else echo "hide-input+rebind(j,k,l,q,/,?,s,u)"; fi' \
			--bind="ctrl-r:execute-silent(${q_self} --refresh-quota-smart ${q_pmode_file} ${q_sock_file})+reload-sync(${reload_cmd})+refresh-preview" \
			--bind="tab:transform(${toggle_cmd})" \
			--bind="ctrl-a:transform(${toggle_cmd})" \
			--bind="ctrl-y:execute-silent(${q_self} --approve {1})+reload-sync(${reload_cmd})+refresh-preview" \
			--bind="alt-e:execute-silent(${q_self} --interrupt {1})+reload-sync(${reload_cmd})+refresh-preview" \
			--bind="ctrl-s:execute-silent(${q_self} --mark-seen {1})+reload-sync(${reload_cmd})" \
			--bind="alt-d:execute-silent(${q_self} --mark-seen {1})+reload-sync(${reload_cmd})" \
			--bind="ctrl-d:preview-half-page-down" \
			--bind="ctrl-u:preview-half-page-up" \
			--bind="pgdn:preview-half-page-down" \
			--bind="pgup:preview-half-page-up" \
			--bind="alt-j:preview-down" \
			--bind="alt-k:preview-up" \
			--bind="alt-x:execute-silent(tmux kill-pane -t {1} 2>/dev/null || true)+reload-sync(${reload_cmd})" \
			--bind="ctrl-x:execute-silent(tmux kill-pane -t {1} 2>/dev/null || true)+reload-sync(${reload_cmd})" \
			--bind="ctrl-/:toggle-preview" \
			--bind="?:execute(${q_self} --keymaps)" \
			--bind="f1:execute(${q_self} --keymaps)" \
			--preview="${q_self} --preview ${q_pmode_file} {1} {3} {4} {5} {6} {7}" \
			--preview-window='right,62%,border-left,wrap,follow' || true
	)"

	cleanup
	trap - EXIT INT TERM

	[ -n "$selected" ] || exit 0
	local target_pane
	target_pane="$(printf '%s\n' "$selected" | cut -f1)"
	[ -n "$target_pane" ] || exit 0

	jump_to_pane "$target_pane"
}

case "${1:-}" in
	--list)
		list_entries "${2:-agents}" "${3:-}" "${4:-42}" "${5:-0}" "${6:-0}" "${7:-}"
		;;
	--preview)
		shift
		preview_dispatch "$@"
		;;
	--preview-roster)
		preview_roster "${2:-}"
		;;
	--footer-quota)
		footer_quota "${2:-40}" "${3:-}"
		;;
	--preview-quota)
		preview_quota
		;;
	--refresh-quota)
		spawn_quota_refresh "${2:-0}" "${3:-}"
		;;
	--refresh-quota-smart)
		refresh_quota_smart "${2:-}" "${3:-}"
		;;
	--toggle-pmode)
		toggle_pmode "${2:-roster}" "${3:-}" "${4:-}"
		;;
	--mark-seen)
		mark_seen_pane "${2:-}"
		;;
	--approve)
		approve_pane "${2:-}"
		;;
	--interrupt)
		interrupt_pane "${2:-}"
		;;
	--keymaps)
		run_keymaps_finder
		;;
	*)
		popup_monitor "${1:-}"
		;;
esac
