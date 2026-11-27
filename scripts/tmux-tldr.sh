#!/usr/bin/env bash
set -euo pipefail

# Quick CLI examples popup: uses local tldr if installed, otherwise cht.sh (or man fallback).

cmds="tar\nrsync\nfind\ngrep\nrg\nsed\nawk\njq\ncurl\nssh\nscp\nss\nlsof\nsystemctl\njournalctl\ndocker\ngit\nchmod\nchown\nffmpeg\ntmux\nip\nnc"

out="$(
	printf '%b\n' "$cmds" | fzf \
		--height=100% \
		--border=none \
		--margin=0 \
		--padding=0,1 \
		--layout=reverse \
		--no-scrollbar \
		--no-separator \
		--info=inline-right \
		--print-query \
		--prompt='CLI > ' \
		--header='j/k: chọn · l/Enter: mở · /: tìm hoặc nhập lệnh · q: thoát' \
		--bind='start:hide-input' \
		--bind='j:down,k:up,l:accept,q:abort' \
		--bind='/:show-input+unbind(j,k,l,q,/)' \
		--bind='esc:transform:if [ "$FZF_INPUT_STATE" = hidden ]; then echo abort; else echo "hide-input+rebind(j,k,l,q,/)"; fi' || true
)"

[ -n "$out" ] || exit 0

query_cmd="$(printf '%s\n' "$out" | sed -n '1p')"
choice_cmd="$(printf '%s\n' "$out" | sed -n '2p')"
cmd="${choice_cmd:-$query_cmd}"
[ -n "$cmd" ] || exit 0

if command -v tldr >/dev/null 2>&1; then
	tldr "$cmd" | less -R
else
	content="$(curl -fsSL "https://cht.sh/${cmd}" 2>/dev/null || true)"
	if [ -n "$content" ]; then
		printf '%s\n' "$content" | less -R
	else
		man "$cmd"
	fi
fi
