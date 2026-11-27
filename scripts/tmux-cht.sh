#!/usr/bin/env bash
set -euo pipefail

# Quick cheat sheet popup using cht.sh.
# Enter: open in right pane | Ctrl-p: open in popup | Ctrl-r: reopen last cached sheet in right pane.

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-cht"
LAST_FILE="${CACHE_DIR}/last.txt"
LAST_URL_FILE="${CACHE_DIR}/last.url"

src_pane="${1:-$(tmux display-message -p '#{pane_id}')}"

open_in_right_pane() {
	local target_src="$1"
	local file="$2"
	local cmd window_id cht_pane

	printf -v cmd 'less -R --save-marks %q' "$file"

	window_id="$(tmux display-message -p -t "$target_src" '#{window_id}')"
	cht_pane="$(
		tmux list-panes -t "$window_id" -F '#{pane_id} #{@cht_pane}' |
			awk '$2 == "1" { print $1; exit }'
	)"

	if [ -n "$cht_pane" ]; then
		tmux respawn-pane -k -t "$cht_pane" "$cmd"
		tmux set-option -p -t "$cht_pane" @cht_pane 1
	else
		cht_pane="$(tmux split-window -h -d -t "$target_src" -l 45% -P -F '#{pane_id}' "$cmd")"
		tmux set-option -p -t "$cht_pane" @cht_pane 1
	fi
}

langs="bash\npython\ngo\nrust\ntypescript\njavascript\nlua\nc\ncpp\ngit\ndocker\njq\nawk\nsed\nvim\ntmux\ncurl\nfind"

out="$(
	printf '%b\n' "$langs" | fzf \
		--height=100% \
		--border=none \
		--margin=0 \
		--padding=0,1 \
		--layout=reverse \
		--no-scrollbar \
		--no-separator \
		--info=inline-right \
		--print-query \
		--expect='ctrl-p,ctrl-r' \
		--prompt='Topic > ' \
		--header='l/Enter: pane phải · ^p: popup · ^r: mở lại · /: tìm · q: thoát' \
		--bind='start:hide-input' \
		--bind='j:down,k:up,l:accept,q:abort' \
		--bind='/:show-input+unbind(j,k,l,q,/)' \
		--bind='esc:transform:if [ "$FZF_INPUT_STATE" = hidden ]; then echo abort; else echo "hide-input+rebind(j,k,l,q,/)"; fi' || true
)"

[ -n "$out" ] || exit 0

query_lang="$(printf '%s\n' "$out" | sed -n '1p')"
key="$(printf '%s\n' "$out" | sed -n '2p')"
choice_lang="$(printf '%s\n' "$out" | sed -n '3p')"

if [ "$key" = "ctrl-r" ]; then
	if [ ! -s "$LAST_FILE" ]; then
		tmux display-message "cht.sh: chưa có trang nào được lưu gần đây"
		exit 0
	fi
	open_in_right_pane "$src_pane" "$LAST_FILE"
	exit 0
fi

lang="${choice_lang:-$query_lang}"
[ -n "$lang" ] || exit 0

printf 'Query for [%s] (empty: overview, "learn": full guide, or e.g. "vector sort"): ' "$lang"
read -r query || exit 0

case "$query" in
	"")
		url="https://cht.sh/${lang}"
		;;
	learn | list | help)
		url="https://cht.sh/${lang}/:${query}"
		;;
	*)
		encoded_query="${query// /+}"
		url="https://cht.sh/${lang}/${encoded_query}"
		;;
esac

mkdir -p "$CACHE_DIR"
if ! curl -fsSL "$url" -o "${LAST_FILE}.tmp"; then
	rm -f "${LAST_FILE}.tmp"
	tmux display-message "cht.sh: failed to fetch $url"
	exit 1
fi
mv -f "${LAST_FILE}.tmp" "$LAST_FILE"
printf '%s\n' "$url" >"$LAST_URL_FILE"

if [ "$key" = "ctrl-p" ]; then
	less -R --save-marks "$LAST_FILE"
else
	open_in_right_pane "$src_pane" "$LAST_FILE"
fi
