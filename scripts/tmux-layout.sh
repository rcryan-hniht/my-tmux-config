#!/usr/bin/env bash
set -euo pipefail

# Window pane layout presets using fzf.
# Applies to current window if it has 1 pane; otherwise opens a new window at current path.

presets="ide\tLeft 65% + Right top/bottom (3 panes)
2-cols\tTwo equal columns (50/50)
3-cols\tThree equal columns
main-top\tTop 70% + Bottom 30%
grid-2x2\t2x2 tiled grid (4 panes)"

choice="$(
	printf '%b\n' "$presets" | fzf \
		--height=100% \
		--border=none \
		--margin=0 \
		--padding=0,1 \
		--layout=reverse \
		--no-scrollbar \
		--no-separator \
		--info=inline-right \
		--delimiter=$'\t' \
		--with-nth=1,2 \
		--prompt='Layout > ' \
		--header='j/k: move · l/Enter: apply · /: find · q: quit' \
		--bind='start:hide-input' \
		--bind='j:down,k:up,l:accept,q:abort' \
		--bind='/:show-input+unbind(j,k,l,q,/)' \
		--bind='esc:transform:if [ "$FZF_INPUT_STATE" = hidden ]; then echo abort; else echo "hide-input+rebind(j,k,l,q,/)"; fi' || true
)"

[ -n "$choice" ] || exit 0

preset="${choice%%$'\t'*}"
cwd="$(tmux display-message -p '#{pane_current_path}')"
panes="$(tmux display-message -p '#{window_panes}')"

if [ "$panes" -gt 1 ]; then
	tmux new-window -c "$cwd"
fi

case "$preset" in
	ide)
		tmux split-window -h -p 35 -c "$cwd"
		tmux split-window -v -p 50 -c "$cwd"
		tmux select-pane -t '{left}'
		;;
	2-cols)
		tmux split-window -h -p 50 -c "$cwd"
		tmux select-pane -t '{left}'
		;;
	3-cols)
		tmux split-window -h -c "$cwd"
		tmux split-window -h -c "$cwd"
		tmux select-layout even-horizontal
		tmux select-pane -t 1
		;;
	main-top)
		tmux split-window -v -p 30 -c "$cwd"
		tmux select-pane -t '{top}'
		;;
	grid-2x2)
		tmux split-window -h -c "$cwd"
		tmux split-window -v -c "$cwd"
		tmux select-pane -t '{left}'
		tmux split-window -v -c "$cwd"
		tmux select-layout tiled
		tmux select-pane -t 1
		;;
esac
