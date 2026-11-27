#!/usr/bin/env bash
set -euo pipefail

# Extract URLs from current pane (and sibling panes in the current window), newest first.
# l / Enter: open in browser | y / Ctrl-y: copy URL to clipboard (wl-copy) | /: search | q: quit

src_pane="${1:-}"
if [ -z "$src_pane" ] || [[ "$src_pane" == *"#{"* ]]; then
	src_pane="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
fi

extract_pane_urls() {
	local target_pane="$1"
	tmux capture-pane -t "$target_pane" -J -p -S -1000 2>/dev/null |
		grep -oE 'https?://[^][:space:]"'\''<>()`│┃╭╮╰╯…]+' |
		sed -E 's/[.,;:!?\\]+$//' |
		awk 'length($0) > 10' |
		tac || true
}

urls="$(
	{
		if [ -n "$src_pane" ]; then
			extract_pane_urls "$src_pane"
			win_id="$(tmux display-message -p -t "$src_pane" '#{window_id}' 2>/dev/null || true)"
			if [ -n "$win_id" ]; then
				for p in $(tmux list-panes -t "$win_id" -F '#{pane_id}' 2>/dev/null || true); do
					[ "$p" = "$src_pane" ] && continue
					extract_pane_urls "$p"
				done
			fi
		else
			tmux capture-pane -J -p -S -1000 2>/dev/null |
				grep -oE 'https?://[^][:space:]"'\''<>()`│┃╭╮╰╯…]+' |
				sed -E 's/[.,;:!?\\]+$//' |
				awk 'length($0) > 10' |
				tac || true
		fi
	} | awk '!seen[$0]++'
)"

if [ -z "$urls" ]; then
	tmux display-message "No URLs found in current window"
	exit 0
fi

out="$(
	printf '%s\n' "$urls" | fzf \
		--no-height \
		--border=none \
		--margin=0 \
		--padding=0,1 \
		--layout=reverse \
		--no-scrollbar \
		--no-separator \
		--info=inline-right \
		--pointer='▌' \
		--prompt='URL > ' \
		--header='j/k: move · l/Enter: open · y/^y: copy · /: find · q: quit' \
		--expect='ctrl-y' \
		--bind='start:hide-input' \
		--bind='j:down,k:up,l:accept,q:abort' \
		--bind='y:print(ctrl-y)+accept' \
		--bind='/:show-input+unbind(j,k,l,y,q,/)' \
		--bind='esc:transform:if [ "$FZF_INPUT_STATE" = hidden ]; then echo abort; else echo "hide-input+rebind(j,k,l,y,q,/)"; fi' || true
)"

[ -n "$out" ] || exit 0

key="$(printf '%s\n' "$out" | sed -n '1p')"
selected="$(printf '%s\n' "$out" | sed -n '2p')"
[ -n "$selected" ] || exit 0

if [ "$key" = "ctrl-y" ]; then
	if command -v wl-copy >/dev/null 2>&1; then
		printf '%s' "$selected" | wl-copy
		tmux display-message "Copied URL: $selected"
	else
		tmux set-buffer -- "$selected"
		tmux display-message "Copied URL to tmux buffer: $selected"
	fi
	exit 0
fi

q_url="$(printf '%q' "$selected")"
tmux run-shell -b "nohup xdg-open ${q_url} >/dev/null 2>&1 &"
