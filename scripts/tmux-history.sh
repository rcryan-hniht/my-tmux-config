#!/usr/bin/env bash
set -euo pipefail

# Quản lý session tmux + history tmux-resurrect.
# x: xóa (kill session đang chạy + xóa khỏi mọi snapshot resurrect) | Tab: chọn nhiều

DIR="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
self="$(realpath "${BASH_SOURCE[0]}")"

list() {
	{
		tmux list-sessions -F '#{session_name}' 2>/dev/null | sed 's/$/\tlive/' || true
		[ -d "$DIR" ] && awk -F'\t' '$1=="pane"||$1=="window"{print $2"\tsaved"}' "$DIR"/tmux_resurrect_*.txt 2>/dev/null || true
	} | awk -F'\t' '
		{ if ($2=="live") live[$1]=1; seen[$1]=1 }
		END { for (n in seen) printf "%s\t%s\n", n, (n in live) ? "\033[32m● đang chạy\033[0m" : "\033[2m○ chỉ trong lịch sử\033[0m" }' |
		sort -t$'\t' -k2,2r -k1,1
}

delete_one() {
	local n="$1" cur f tmp
	cur="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
	if [ "$n" = "$cur" ]; then
		tmux display-message "tmux-history: bỏ qua session hiện tại '$n'"
		return 0
	fi
	tmux kill-session -t "=$n" 2>/dev/null || true
	[ -d "$DIR" ] || return 0
	for f in "$DIR"/tmux_resurrect_*.txt; do
		[ -f "$f" ] || continue
		tmp="$(mktemp)"
		awk -F'\t' -v OFS='\t' -v n="$n" '
			($1=="pane"||$1=="window"||$1=="grouped_session") && ($2==n||($1=="grouped_session"&&$3==n)) { next }
			$1=="state" { if ($2==n) $2=""; if ($3==n) $3="" }
			{ print }' "$f" >"$tmp"
		cat "$tmp" >"$f"
		rm -f "$tmp"
	done
}

case "${1:-}" in
	--list) list; exit 0 ;;
	--delete) shift; for n in "$@"; do [ -n "$n" ] && delete_one "$n"; done; exit 0 ;;
esac

q="$(printf "'%s'" "$self")"
list | fzf --ansi --height=100% --border=none --margin=0 --padding=0,1 --layout=reverse \
	--no-scrollbar --no-separator --info=inline-right --pointer='▌' --multi \
	--delimiter=$'\t' --with-nth=1,2 --prompt='/ ' \
	--header='j/k: move · Tab: multi · x: delete · /: find · q: quit' \
	--bind='start:hide-input' \
	--bind='j:down,k:up,q:abort' \
	--bind="x:execute-silent($q --delete {+1})+reload-sync($q --list)" \
	--bind='/:show-input+unbind(j,k,q,x,/)' \
	--bind='esc:transform:if [ "$FZF_INPUT_STATE" = hidden ]; then echo abort; else echo "hide-input+rebind(j,k,q,x,/)"; fi' \
	>/dev/null || true
