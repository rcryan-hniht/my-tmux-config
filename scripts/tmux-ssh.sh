#!/usr/bin/env bash
set -euo pipefail

# Interactive SSH host picker popup using fzf, reading ~/.ssh/config.
# Opens the selected host in a new tmux window.

ssh_hosts() {
	[ -f "$HOME/.ssh/config" ] || return 0
	awk '
		tolower($1) == "host" {
			for (i = 2; i <= NF; i++) {
				if ($i !~ /[*?!]/) print $i
			}
		}
	' "$HOME/.ssh/config" | sort -u
}

out="$(
	ssh_hosts | fzf \
		--height=100% \
		--border=none \
		--margin=0 \
		--padding=0,1 \
		--layout=reverse \
		--no-scrollbar \
		--no-separator \
		--info=inline-right \
		--print-query \
		--prompt='SSH > ' \
		--header='j/k: chọn · l/Enter: kết nối · /: tìm hoặc nhập user@host · q: thoát' \
		--bind='start:hide-input' \
		--bind='j:down,k:up,l:accept,q:abort' \
		--bind='/:show-input+unbind(j,k,l,q,/)' \
		--bind='esc:transform:if [ "$FZF_INPUT_STATE" = hidden ]; then echo abort; else echo "hide-input+rebind(j,k,l,q,/)"; fi' || true
)"

[ -n "$out" ] || exit 0

query="$(printf '%s\n' "$out" | sed -n '1p')"
choice="$(printf '%s\n' "$out" | sed -n '2p')"
host="${choice:-$query}"

[ -n "$host" ] || exit 0

tmux new-window -n "ssh:$host" "ssh $host"
