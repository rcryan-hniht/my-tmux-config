#!/usr/bin/env bash
set -euo pipefail

# TeX -> PDF popup picker using fzf, compiling via tectonic and previewing with tdf in a right pane.

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-tex"
LOG_FILE="${CACHE_DIR}/last.log"

require_cmd() {
	local cmd
	for cmd in "$@"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			tmux display-message "tmux-tex: missing required command '$cmd'"
			exit 1
		fi
	done
}

list_tex_files() {
	local dir="$1"
	if command -v fd >/dev/null 2>&1; then
		fd --type f --extension tex --base-directory "$dir" . 2>/dev/null | sort || true
	else
		(cd "$dir" && find . -type f -name '*.tex' 2>/dev/null | sed 's|^\./||' | sort) || true
	fi
}

dir_stamp() {
	local dir="$1"
	find "$dir" -maxdepth 3 \
		\( -path '*/.git' -o -path '*/node_modules' \) -prune -o \
		-type f \( -name '*.tex' -o -name '*.bib' -o -name '*.sty' -o -name '*.cls' \) \
		-printf '%T@ %p\n' 2>/dev/null | sort | sha1sum | awk '{print $1}' || true
}

compile_tex() {
	local tex_dir="$1"
	local tex_name="$2"
	local build_dir="$3"
	local pdf_path="$4"
	local pdf_name="${tex_name%.tex}.pdf"
	local tmp_pdf="${tex_dir}/.${pdf_name}.tmp.$$"

	mkdir -p "$build_dir" "$CACHE_DIR"
	if (cd "$tex_dir" && tectonic --outdir "$build_dir" "$tex_name") >"$LOG_FILE" 2>&1; then
		if [ -f "${build_dir}/${pdf_name}" ]; then
			# Stage in build_dir and swap atomically so tdf never reads a half-written PDF.
			cp -f "${build_dir}/${pdf_name}" "$tmp_pdf" && mv -f "$tmp_pdf" "$pdf_path"
			return 0
		fi
	fi

	rm -f "$tmp_pdf"
	return 1
}

run_pane() {
	local mode="$1"
	local tex_path="$2"

	if [ ! -f "$tex_path" ]; then
		printf 'File not found: %s\n' "$tex_path"
		read -r -p 'Press Enter to close...' _
		exit 1
	fi

	local tex_dir tex_name pdf_name pdf_path key_hash build_dir
	tex_dir="$(dirname "$tex_path")"
	tex_name="$(basename "$tex_path")"
	pdf_name="${tex_name%.tex}.pdf"
	pdf_path="${tex_dir}/${pdf_name}"
	key_hash="$(printf '%s' "$tex_path" | sha1sum | awk '{print $1}')"
	build_dir="${CACHE_DIR}/build/${key_hash}"

	local watcher_pid=""
	cleanup() {
		if [ -n "$watcher_pid" ]; then
			pkill -P "$watcher_pid" 2>/dev/null || true
			kill "$watcher_pid" 2>/dev/null || true
		fi
		rm -f "${tex_dir}/.${pdf_name}.tmp."*
	}
	trap cleanup EXIT INT TERM

	while true; do
		clear
		printf 'Compiling %s with tectonic...\n' "$tex_name"
		if compile_tex "$tex_dir" "$tex_name" "$build_dir" "$pdf_path"; then
			break
		fi

		clear
		printf '=== tectonic failed: %s ===\n\n' "$tex_name"
		cat "$LOG_FILE"
		printf '\n'

		if [ "$mode" = "once" ]; then
			read -r -p 'Press Enter to close...' _
			exit 1
		fi

		printf '[watch] Fix & save to retry (r: retry now, q: quit)...\n'
		local err_stamp cur_stamp key=""
		err_stamp="$(dir_stamp "$tex_dir")"
		while true; do
			if read -r -t 0.8 -n 1 key 2>/dev/null; then
				case "$key" in
					q | Q) exit 0 ;;
					r | R) break ;;
				esac
			fi
			cur_stamp="$(dir_stamp "$tex_dir")"
			if [ "$cur_stamp" != "$err_stamp" ]; then
				break
			fi
		done
	done

	if [ "$mode" = "once" ]; then
		exec tdf "$pdf_path"
	fi

	# Poll .tex/.bib/.sty/.cls mtimes instead of `tectonic -X watch` (which loops on PDF output).
	(
		last_stamp="$(dir_stamp "$tex_dir")"
		while true; do
			sleep 0.8
			new_stamp="$(dir_stamp "$tex_dir")"
			if [ "$new_stamp" != "$last_stamp" ]; then
				last_stamp="$new_stamp"
				if compile_tex "$tex_dir" "$tex_name" "$build_dir" "$pdf_path"; then
					tmux display-message "tectonic: rebuilt $pdf_name" >/dev/null 2>&1 || true
				else
					tmux display-message "tectonic: build error (Prefix+Ctrl-t -> Ctrl-l)" >/dev/null 2>&1 || true
				fi
			fi
		done
	) &
	watcher_pid=$!

	clear
	tdf --reload-delay 100 "$pdf_path"
}

popup_picker() {
	require_cmd tectonic tdf fzf

	local cwd="${1:-$(pwd)}"
	local src_pane="${2:-$(tmux display-message -p '#{pane_id}')}"

	local files
	files="$(list_tex_files "$cwd")"
	if [ -z "$files" ]; then
		tmux display-message "tmux-tex: no .tex files found in $cwd"
		exit 0
	fi

	local preview_cmd='head -n 60 {} 2>/dev/null'
	if command -v bat >/dev/null 2>&1; then
		preview_cmd='bat --style=plain --color=always --line-range=:60 {} 2>/dev/null'
	fi

	local out
	out="$(
		cd "$cwd" && printf '%s\n' "$files" | fzf \
			--height=100% \
			--border=none \
			--margin=0 \
			--padding=0,1 \
			--layout=reverse \
			--no-scrollbar \
			--no-separator \
			--info=inline-right \
			--prompt='TeX > ' \
			--header='l/Enter: watch · /: find · ^r: build once · ^l: log · q: quit' \
			--expect='ctrl-r,ctrl-l' \
			--bind='start:hide-input' \
			--bind='j:down,k:up,l:accept,q:abort' \
			--bind='/:show-input+unbind(j,k,l,q,/)' \
			--bind='esc:transform:if [ "$FZF_INPUT_STATE" = hidden ]; then echo abort; else echo "hide-input+rebind(j,k,l,q,/)"; fi' \
			--preview="$preview_cmd" \
			--preview-window='right:50%:wrap:border-left' || true
	)"

	[ -n "$out" ] || exit 0

	local key choice
	key="$(printf '%s\n' "$out" | sed -n '1p')"
	choice="$(printf '%s\n' "$out" | sed -n '2p')"

	if [ "$key" = "ctrl-l" ]; then
		if [ -f "$LOG_FILE" ]; then
			less +G "$LOG_FILE"
		else
			tmux display-message "tmux-tex: no build log yet"
		fi
		exit 0
	fi

	[ -n "$choice" ] || exit 0

	local mode="watch"
	[ "$key" = "ctrl-r" ] && mode="once"

	local tex_path tex_dir script_path cmd window_id preview_pane
	tex_path="$(realpath "${cwd}/${choice}")"
	tex_dir="$(dirname "$tex_path")"
	script_path="$(realpath "${BASH_SOURCE[0]}")"

	printf -v cmd '%q --pane %q %q' "$script_path" "$mode" "$tex_path"

	window_id="$(tmux display-message -p -t "$src_pane" '#{window_id}')"
	preview_pane="$(
		tmux list-panes -t "$window_id" -F '#{pane_id} #{@tex_preview}' |
			awk '$2 == "1" { print $1; exit }'
	)"

	if [ -n "$preview_pane" ]; then
		tmux respawn-pane -k -t "$preview_pane" -c "$tex_dir" "$cmd"
		tmux set-option -p -t "$preview_pane" @tex_preview 1
	else
		preview_pane="$(tmux split-window -h -d -t "$src_pane" -l 48% -c "$tex_dir" -P -F '#{pane_id}' "$cmd")"
		tmux set-option -p -t "$preview_pane" @tex_preview 1
	fi
}

case "${1:-}" in
	--pane)
		shift
		run_pane "${1:?missing mode}" "${2:?missing tex path}"
		;;
	*)
		popup_picker "${1:-}" "${2:-}"
		;;
esac
