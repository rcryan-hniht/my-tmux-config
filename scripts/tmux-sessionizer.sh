#!/usr/bin/env bash
set -euo pipefail

# Project sessionizer: pick a project directory with fzf and switch/create a tmux session.

search_dirs=()
for d in "$HOME/Projects" "$HOME/ryan" "$HOME/dalabs"; do
	[ -d "$d" ] && search_dirs+=("$d")
done

candidates() {
	[ -d "$HOME/dotfiles" ] && echo "$HOME/dotfiles"
	[ -d "$HOME/anki-linux" ] && echo "$HOME/anki-linux"
	[ -d "$HOME/walker" ] && echo "$HOME/walker"
	if [ "${#search_dirs[@]}" -gt 0 ]; then
		find "${search_dirs[@]}" -mindepth 1 -maxdepth 2 -type d 2>/dev/null
	fi
}

selected="$(
	candidates | sort -u | fzf \
		--height=100% \
		--border=none \
		--margin=0 \
		--padding=0,1 \
		--layout=reverse \
		--no-scrollbar \
		--no-separator \
		--info=inline-right \
		--prompt='Project > ' \
		--header='j/k: chọn · l/Enter: mở · /: tìm · q: thoát' \
		--bind='start:hide-input' \
		--bind='j:down,k:up,l:accept,q:abort' \
		--bind='/:show-input+unbind(j,k,l,q,/)' \
		--bind='esc:transform:if [ "$FZF_INPUT_STATE" = hidden ]; then echo abort; else echo "hide-input+rebind(j,k,l,q,/)"; fi' || true
)"

[ -n "$selected" ] || exit 0

session_name="$(basename "$selected" | tr '.:' '__')"

if ! tmux has-session -t "=$session_name" 2>/dev/null; then
	tmux new-session -ds "$session_name" -c "$selected"
fi

tmux switch-client -t "=$session_name"
