#!/usr/bin/env bash
set -euo pipefail

# Interactive Port & Process Killer using fzf.
# Enter: SIGTERM (kill) | Ctrl-x: SIGKILL (kill -9)

list_targets() {
	# Listening TCP/UDP sockets owned by current user
	if command -v ss >/dev/null 2>&1; then
		ss -tulpnH 2>/dev/null | awk '
			match($0, /pid=([0-9]+)/, p) {
				port = $5
				sub(/.*:/, "", port)
				proc = ""
				if (match($0, /"([^"]+)"/, n)) proc = n[1]
				printf "%-8s\t[PORT %-5s]\t%s\n", p[1], port, proc
			}
		' | sort -u
	fi

	# User processes
	ps -u "$USER" -o pid=,comm=,args= --sort=-%cpu | awk '
		{
			pid = $1
			comm = $2
			$1 = ""; $2 = ""
			sub(/^[ \t]+/, "")
			printf "%-8s\t[%-10s]\t%s\n", pid, comm, $0
		}
	'
}

out="$(
	list_targets | fzf \
		--height=100% \
		--border=none \
		--margin=0 \
		--padding=0,1 \
		--layout=reverse \
		--no-scrollbar \
		--no-separator \
		--info=inline-right \
		--multi \
		--delimiter=$'\t' \
		--prompt='Kill > ' \
		--header='j/k: chọn · Tab: multi · l/Enter: kill · ^x: kill -9 · /: tìm · q: thoát' \
		--expect='ctrl-x' \
		--bind='start:hide-input' \
		--bind='j:down,k:up,l:accept,q:abort' \
		--bind='/:show-input+unbind(j,k,l,q,/)' \
		--bind='esc:transform:if [ "$FZF_INPUT_STATE" = hidden ]; then echo abort; else echo "hide-input+rebind(j,k,l,q,/)"; fi' || true
)"

[ -n "$out" ] || exit 0

key="$(printf '%s\n' "$out" | sed -n '1p')"
sig="-TERM"
[ "$key" = "ctrl-x" ] && sig="-KILL"

pids="$(printf '%s\n' "$out" | sed '1d' | awk -F'\t' '{gsub(/ /, "", $1); if ($1 ~ /^[0-9]+$/) print $1}')"
[ -n "$pids" ] || exit 0

for pid in $pids; do
	kill "$sig" "$pid" 2>/dev/null || true
done
tmux display-message "Sent SIG${sig#-} to PID(s): $(echo "$pids" | tr '\n' ' ')"
