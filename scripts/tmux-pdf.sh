#!/usr/bin/env bash
set -euo pipefail

# Minimal popup PDF picker using fzf + fd + pdftoppm + tdf.
# Files are grouped by directory; right panel previews the PDF cover page via Kitty graphics.
# Enter: open in new window | ?: keymap finder

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-pdf"
COVERS_DIR="${CACHE_DIR}/covers"
STATE_FILE="${CACHE_DIR}/active-session"
KITTY_PREVIEW_ID=9942

require_cmd() {
	local cmd
	for cmd in "$@"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			tmux display-message "tmux-pdf: missing required command '$cmd'"
			exit 1
		fi
	done
}

shell_quote() {
	printf "'%s'" "${1//\'/\'\\\'\'}"
}

resolve_path() {
	local cwd="$1"
	local p="$2"
	case "$p" in
		"~/"*) printf '%s\n' "${HOME}/${p#\~/}" ;;
		"~") printf '%s\n' "$HOME" ;;
		/*) printf '%s\n' "$p" ;;
		*) printf '%s\n' "${cwd%/}/${p}" ;;
	esac
}

# Groups files by directory (cwd first, then directory path, then filename)
# and dims the directory prefix so filenames stand out cleanly.
format_grouped_entries() {
	local cwd="${1:-$PWD}"
	awk -v home="${HOME%/}" -v cwd="${cwd%/}" '
		!seen[$0]++ {
			raw = $0
			prio = 1
			if (cwd != "" && cwd != home && substr(raw, 1, length(cwd) + 1) == cwd "/") {
				rel = substr(raw, length(cwd) + 2)
				prio = 0
			} else if (substr(raw, 1, length(home) + 1) == home "/") {
				rel = "~/" substr(raw, length(home) + 2)
			} else {
				rel = raw
			}
			idx = match(rel, /\/[^\/]+$/)
			if (idx > 0) {
				dir = substr(rel, 1, idx - 1)
				base = substr(rel, idx + 1)
			} else {
				dir = "."
				base = rel
			}
			printf "%d\t%s\t%s\t%s\n", prio, dir, base, rel
		}
	' | LC_ALL=C sort -t $'\t' -k1,1n -k2,2f -k3,3f | awk -F '\t' '
		{
			dir = $2
			base = $3
			if (dir == ".") {
				printf "%s\n", base
			} else {
				printf "\033[2m%s/\033[0m%s\n", dir, base
			}
		}
	'
}

format_recent_entries() {
	local cwd="${1:-$PWD}"
	awk -v home="${HOME%/}" -v cwd="${cwd%/}" '
		!seen[$0]++ {
			raw = $0
			if (cwd != "" && cwd != home && substr(raw, 1, length(cwd) + 1) == cwd "/") {
				rel = substr(raw, length(cwd) + 2)
			} else if (substr(raw, 1, length(home) + 1) == home "/") {
				rel = "~/" substr(raw, length(home) + 2)
			} else {
				rel = raw
			}
			idx = match(rel, /\/[^\/]+$/)
			if (idx > 0) {
				dir = substr(rel, 1, idx - 1)
				base = substr(rel, idx + 1)
				printf "\033[2m%s/\033[0m%s\n", dir, base
			} else {
				printf "%s\n", rel
			}
		}
	'
}

list_pdfs() {
	local cwd="${1:-$PWD}"
	local roots=()

	{
		if command -v fd >/dev/null 2>&1; then
			if [ -d "$cwd" ] && [ "$cwd" != "$HOME" ]; then
				fd --type f --extension pdf --absolute-path . "$cwd" 2>/dev/null || true
			fi
			fd --max-depth 1 --type f --extension pdf --absolute-path . "$HOME" 2>/dev/null || true
			for d in "$HOME/Documents" "$HOME/Downloads" "$HOME/Projects" "$HOME/ryan" "$HOME/dalabs"; do
				[ -d "$d" ] && roots+=("$d")
			done
			if [ "${#roots[@]}" -gt 0 ]; then
				fd --type f --extension pdf --absolute-path . "${roots[@]}" 2>/dev/null || true
			fi
		else
			if [ -d "$cwd" ] && [ "$cwd" != "$HOME" ]; then
				find "$cwd" -type f -iname '*.pdf' 2>/dev/null || true
			fi
			find "$HOME" -maxdepth 1 -type f -iname '*.pdf' 2>/dev/null || true
			for d in "$HOME/Documents" "$HOME/Downloads" "$HOME/Projects" "$HOME/ryan" "$HOME/dalabs"; do
				[ -d "$d" ] && roots+=("$d")
			done
			if [ "${#roots[@]}" -gt 0 ]; then
				find "${roots[@]}" -type f -iname '*.pdf' 2>/dev/null || true
			fi
		fi
	} | format_grouped_entries "$cwd"
}

list_recent_pdfs() {
	local cwd="${1:-$PWD}"
	local state_file="${XDG_DATA_HOME:-$HOME/.local/share}/tdf/state.tsv"
	[ -f "$state_file" ] || return 0

	awk -F '\t' '
		{
			p = $1
			gsub(/\\t/, "\t", p)
			gsub(/\\n/, "\n", p)
			gsub(/\\p/, "|", p)
			gsub(/\\c/, ",", p)
			gsub(/\\d/, ":", p)
			gsub(/\\\\/, "\\", p)
			if (p ~ /\.[Pp][Dd][Ff]$/) print p
		}
	' "$state_file" | tac | while IFS= read -r p; do
		[ -f "$p" ] && printf '%s\n' "$p"
	done | format_recent_entries "$cwd"
}

clear_cover_image() {
	local client_tty="${1:-}"
	if [ -z "$client_tty" ] && [ -f "$STATE_FILE" ]; then
		read -r client_tty _ <"$STATE_FILE" 2>/dev/null || true
	fi
	if [ -z "$client_tty" ]; then
		client_tty="$(tmux display-message -p '#{client_tty}' 2>/dev/null || true)"
	fi
	if [ -n "$client_tty" ] && [ -w "$client_tty" ]; then
		printf '\033_Ga=d,q=2,d=I,i=%d\033\\' "$KITTY_PREVIEW_ID" >"$client_tty" 2>/dev/null || true
	fi
}

ensure_cover_png() {
	local pdf_path="$1"
	mkdir -p "$COVERS_DIR"
	local mtime key png_base png_file tmp_base
	mtime="$(stat -c '%Y' "$pdf_path" 2>/dev/null || echo 0)"
	key="$(printf '%s:%s' "$pdf_path" "$mtime" | sha1sum | awk '{print $1}')"
	png_base="${COVERS_DIR}/${key}"
	png_file="${png_base}.png"

	if [ ! -s "$png_file" ]; then
		command -v pdftoppm >/dev/null 2>&1 || return 1
		tmp_base="${png_base}.tmp.$$"
		if pdftoppm -png -f 1 -l 1 -scale-to 720 -singlefile "$pdf_path" "$tmp_base" >/dev/null 2>&1 && [ -s "${tmp_base}.png" ]; then
			mv -f "${tmp_base}.png" "$png_file"
		else
			rm -f "${tmp_base}.png"
			return 1
		fi
	fi
	printf '%s\n' "$png_file"
}

preview_pdf() {
	local cwd="$1"
	local raw="$2"
	local path
	path="$(resolve_path "$cwd" "$raw")"
	if [ ! -f "$path" ]; then
		clear_cover_image
		printf 'File not found: %s\n' "$path"
		exit 0
	fi

	local pages="" file_sz="" meta=""
	if command -v pdfinfo >/dev/null 2>&1; then
		pages="$(pdfinfo "$path" 2>/dev/null | awk -F': *' '/^Pages:/ {print $2; exit}')"
	fi
	file_sz="$(du -h "$path" 2>/dev/null | awk '{print $1}')"
	[ -n "$pages" ] && meta="${pages} trang"
	[ -n "$file_sz" ] && meta="${meta:+$meta  ·  }${file_sz}"
	[ -n "$meta" ] && printf ' \033[2m%s\033[0m\n' "$meta"

	local png_file
	if ! png_file="$(ensure_cover_png "$path")"; then
		clear_cover_image
		if command -v pdftotext >/dev/null 2>&1; then
			pdftotext -f 1 -l 2 "$path" - 2>/dev/null | tr -d '\f' | awk 'NF' | head -n 20 || true
		fi
		exit 0
	fi

	local prev_cols="${FZF_PREVIEW_COLUMNS:-40}"
	local prev_lines="${FZF_PREVIEW_LINES:-22}"
	local prev_top="${FZF_PREVIEW_TOP:-0}"
	local prev_left="${FZF_PREVIEW_LEFT:-0}"
	local avail_cols=$(( prev_cols > 2 ? prev_cols - 2 : 1 ))
	local avail_rows=$(( prev_lines > 2 ? prev_lines - 2 : 1 ))

	if [ -f "$STATE_FILE" ]; then
		local client_tty pop_row0 pop_col0 cell_w cell_h
		if read -r client_tty pop_row0 pop_col0 cell_w cell_h <"$STATE_FILE" 2>/dev/null && [ -w "$client_tty" ]; then
			local dims img_w img_h
			dims="$(file -b "$png_file" 2>/dev/null | awk 'match($0, /([0-9]+) x ([0-9]+)/, m) { print m[1], m[2] }')"
			read -r img_w img_h <<<"${dims:-720 1000}"
			[ "${img_w:-0}" -gt 0 ] 2>/dev/null || img_w=720
			[ "${img_h:-0}" -gt 0 ] 2>/dev/null || img_h=1000
			[ "${cell_w:-0}" -gt 0 ] 2>/dev/null || cell_w=12
			[ "${cell_h:-0}" -gt 0 ] 2>/dev/null || cell_h=25

			local disp_cols disp_rows
			read -r disp_cols disp_rows < <(
				awk -v ac="$avail_cols" -v ar="$avail_rows" -v cw="$cell_w" -v ch="$cell_h" -v iw="$img_w" -v ih="$img_h" '
					BEGIN {
						box_w = ac * cw
						box_h = ar * ch
						if (iw / ih > box_w / box_h) {
							dc = ac
							dr = int(((ac * cw * ih / iw) / ch) + 0.5)
						} else {
							dr = ar
							dc = int(((ar * ch * iw / ih) / cw) + 0.5)
						}
						if (dc < 1) dc = 1
						if (dr < 1) dr = 1
						if (dc > ac) dc = ac
						if (dr > ar) dr = ar
						printf "%d %d\n", dc, dr
					}
				'
			)

			local pad_cols=$(( (prev_cols - disp_cols) / 2 ))
			[ "$pad_cols" -ge 0 ] || pad_cols=0
			local img_row=$(( pop_row0 + prev_top + 1 ))
			local img_col=$(( pop_col0 + prev_left + pad_cols ))
			local b64_path
			b64_path="$(printf '%s' "$png_file" | base64 -w0)"

			if [ -f "$STATE_FILE" ]; then
				printf '\0337\033[%d;%dH\033_Ga=T,q=2,f=100,t=f,i=%d,p=1,C=1,c=%d,r=%d,z=10;%s\033\\\0338' \
					"$img_row" "$img_col" "$KITTY_PREVIEW_ID" "$disp_cols" "$disp_rows" "$b64_path" >"$client_tty" 2>/dev/null || true
				exit 0
			fi
		fi
	fi

	if command -v chafa >/dev/null 2>&1; then
		chafa -f symbols --size="${avail_cols}x${avail_rows}" "$png_file" 2>/dev/null || true
	fi
}

list_keymaps() {
	{
		cat <<'EOF'
[Popup]	j / k	Move cursor down / up
[Popup]	l / Enter	Open PDF in a new window (tdf)
[Popup]	/	Open search input (Esc returns to j/k)
[Popup]	q / Esc	Close popup
[Popup]	Ctrl-s	Open PDF in right horizontal split
[Popup]	Ctrl-v	Open PDF in bottom vertical split
[Popup]	Ctrl-w	Open PDF in a new window
[Popup]	Ctrl-r	Show recently opened PDFs
[Popup]	Ctrl-a	Show all PDFs
[Popup]	Ctrl-/	Toggle cover preview
[Popup]	?	Open keymap finder
[tdf]	J / K, PgDn / PgUp	Next / previous page
[tdf]	h / j / k / l	Pan left / down / up / right
[tdf]	Ctrl-d / Ctrl-u	Scroll half-page down / up
[tdf]	Ctrl-f / Ctrl-b / Space	Scroll full screen down / up
[tdf]	H / L / P	Top of page / bottom of page / fit page
[tdf]	gg / G / [N]gg	First page / last page / jump to page N
[tdf]	a / s	Fit whole page (a) / fit width (s)
[tdf]	zi / zo / z0 / + / - / =	Zoom in / zoom out / reset zoom
[tdf]	Tab	Toggle table of contents (Index)
[tdf]	f / F / c	Open link / show links / copy link
[tdf]	v / V / gv / y / Y	Visual select text / copy / copy file path
[tdf]	m<char> / '<char>	Set quickmark / jump to quickmark
[tdf]	Ctrl-o / Ctrl-i	Jump backward / forward (Jumplist)
[tdf]	Ctrl-j / Ctrl-k	Bisect forward / backward
[tdf]	/ / ? / n / N / Esc	Search / next-prev match / clear highlight
[tdf]	d / D / w	Two-page / toggle cover spread / single-page
[tdf]	r / R / Ctrl-r	Rotate 90° / reload / invert colors
[tdf]	F5 / F11 / Ctrl-n	Fullscreen / toggle status bar
[tdf]	:	Command line (:bmark, :bjump, :blist, :bdel, :offset, :info, :help, :q)
[tdf]	q	Quit tdf
EOF
		if tmux list-keys -N -T prefix >/dev/null 2>&1; then
			tmux list-keys -N -T prefix | awk '{
				key = $1
				$1 = ""
				sub(/^[ \t]+/, "")
				printf "[tmux]	Ctrl+Space %s	%s\n", key, $0
			}'
		fi
	} | awk -F '\t' '{
		scope = $1
		key = $2
		desc = $3
		color = "\033[36m"
		if (scope == "[tdf]") color = "\033[33m"
		else if (scope == "[tmux]") color = "\033[32m"
		printf "%s%-8s\033[0m  \033[1m%-24s\033[0m  %s\n", color, scope, key, desc
	}'
}

run_keymaps_finder() {
	local saved_state=""
	if [ -f "$STATE_FILE" ]; then
		saved_state="$(cat "$STATE_FILE" 2>/dev/null || true)"
		clear_cover_image
		rm -f "$STATE_FILE"
	fi

	list_keymaps | fzf \
		--ansi \
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
		--header='j/k: move · /: find · q/l/Enter/Esc: back' \
		--bind='start:hide-input' \
		--bind='j:down,k:up,l:abort,q:abort,enter:abort,?:abort' \
		--bind='/:show-input+unbind(j,k,l,q,/,?)' \
		--bind='esc:transform:if [ "$FZF_INPUT_STATE" = hidden ]; then echo abort; else echo "hide-input+rebind(j,k,l,q,/,?)"; fi' || true

	if [ -n "$saved_state" ]; then
		printf '%s\n' "$saved_state" >"$STATE_FILE"
	fi
}

open_pdf() {
	local key="$1"
	local pdf_path="$2"
	local src_pane="$3"
	local pdf_dir pdf_name quoted_path tdf_bin cmd window_id tdf_pane

	pdf_dir="$(dirname "$pdf_path")"
	pdf_name="$(basename "$pdf_path")"
	pdf_name="${pdf_name%.[Pp][Dd][Ff]}"
	quoted_path="$(shell_quote "$pdf_path")"
	tdf_bin="$(command -v tdf)"
	# Ignore SIGUSR1 during startup (tmux hooks send pkill -USR1 -x tdf on layout change)
	# and wait briefly so display-popup closes before tdf queries terminal graphics.
	cmd="trap '' USR1; sleep 0.08; exec $(shell_quote "$tdf_bin") ${quoted_path}"

	case "$key" in
		ctrl-v)
			tdf_pane="$(tmux split-window -d -v -t "$src_pane" -l 50% -c "$pdf_dir" -P -F '#{pane_id}' "$cmd")"
			tmux set-option -p -t "$tdf_pane" @tdf_pane 1
			tmux select-pane -t "$tdf_pane"
			;;
		ctrl-s)
			tdf_pane="$(tmux split-window -d -h -t "$src_pane" -l 50% -c "$pdf_dir" -P -F '#{pane_id}' "$cmd")"
			tmux set-option -p -t "$tdf_pane" @tdf_pane 1
			tmux select-pane -t "$tdf_pane"
			;;
		*)
			tdf_pane="$(tmux new-window -d -c "$pdf_dir" -n "pdf:${pdf_name:0:18}" -P -F '#{pane_id}' "$cmd")"
			tmux set-option -p -t "$tdf_pane" @tdf_pane 1
			tmux select-window -t "$tdf_pane"
			;;
	esac
}

init_popup_session() {
	mkdir -p "$CACHE_DIR"
	local client_info client_w client_h client_tty cell_w cell_h term_name
	client_info="$(tmux display-message -p '#{client_width} #{client_height} #{client_tty} #{client_cell_width} #{client_cell_height} #{client_termname}' 2>/dev/null || true)"
	read -r client_w client_h client_tty cell_w cell_h term_name <<<"$client_info"

	case "${term_name:-}" in
		*ghostty* | *kitty*) ;;
		*) return 0 ;;
	esac

	local stty_sz inner_h inner_w
	stty_sz="$(stty size </dev/tty 2>/dev/null || true)"
	read -r inner_h inner_w <<<"${stty_sz:-0 0}"
	if [ "${client_w:-0}" -gt 0 ] && [ "${client_h:-0}" -gt 0 ] && [ "${inner_w:-0}" -gt 0 ] && [ "${inner_h:-0}" -gt 0 ] && [ -n "${client_tty:-}" ]; then
		local pop_col0=$(( (client_w - inner_w) / 2 + 1 ))
		local pop_row0=$(( (client_h + 1 + inner_h) / 2 - inner_h ))
		printf '%s %d %d %d %d\n' "$client_tty" "$pop_row0" "$pop_col0" "${cell_w:-12}" "${cell_h:-25}" >"$STATE_FILE"
	fi
}

popup_picker() {
	require_cmd fzf tdf

	local cwd="${1:-}"
	if [ -z "$cwd" ] || [[ "$cwd" == *"#{"* ]]; then
		cwd="$(tmux display-message -p '#{pane_current_path}' 2>/dev/null || pwd)"
	fi
	local src_pane="${2:-}"
	if [ -z "$src_pane" ] || [[ "$src_pane" == *"#{"* ]]; then
		src_pane="$(tmux display-message -p '#{pane_id}')"
	fi
	local self_path
	self_path="$(realpath "${BASH_SOURCE[0]}")"

	local initial_list
	initial_list="$(list_pdfs "$cwd")"
	if [ -z "$initial_list" ]; then
		initial_list="$(list_recent_pdfs "$cwd")"
	fi
	if [ -z "$initial_list" ]; then
		tmux display-message "tmux-pdf: không tìm thấy file PDF nào"
		exit 0
	fi

	init_popup_session
	cleanup() {
		local tty=""
		if [ -f "$STATE_FILE" ]; then
			read -r tty _ <"$STATE_FILE" 2>/dev/null || true
			rm -f "$STATE_FILE"
		fi
		clear_cover_image "$tty"
	}
	trap cleanup EXIT INT TERM

	local q_self q_cwd
	q_self="$(shell_quote "$self_path")"
	q_cwd="$(shell_quote "$cwd")"

	local out
	out="$(
		printf '%s\n' "$initial_list" | fzf \
			--ansi \
			--height=100% \
			--border=none \
			--margin=0 \
			--padding=0,1 \
			--layout=reverse \
			--no-scrollbar \
			--no-separator \
			--info=inline-right \
			--pointer='▌' \
			--prompt='PDF > ' \
			--header='l/Enter: open · /: find · ^r: recent · ?: keys' \
			--expect='ctrl-s,ctrl-v,ctrl-w' \
			--bind="start:hide-input" \
			--bind="j:down,k:up,l:accept,q:abort" \
			--bind="/:show-input+unbind(j,k,l,q,/,?)" \
			--bind='esc:transform:if [ "$FZF_INPUT_STATE" = hidden ]; then echo abort; else echo "hide-input+rebind(j,k,l,q,/,?)"; fi' \
			--bind="ctrl-r:reload(${q_self} --recent ${q_cwd})+change-prompt(Recent > )" \
			--bind="ctrl-a:reload(${q_self} --list ${q_cwd})+change-prompt(PDF > )" \
			--bind="ctrl-/:execute-silent(${q_self} --clear-preview)+toggle-preview" \
			--bind="?:execute(${q_self} --keymaps)+refresh-preview" \
			--preview="${q_self} --preview ${q_cwd} {}" \
			--preview-window='right,36%,border-left' || true
	)"

	cleanup
	trap - EXIT INT TERM

	[ -n "$out" ] || exit 0

	local key choice pdf_path
	key="$(printf '%s\n' "$out" | sed -n '1p')"
	choice="$(printf '%s\n' "$out" | sed -n '2p')"
	[ -n "$choice" ] || exit 0

	pdf_path="$(resolve_path "$cwd" "$choice")"
	if [ ! -f "$pdf_path" ]; then
		tmux display-message "tmux-pdf: không tìm thấy file $pdf_path"
		exit 1
	fi

	open_pdf "$key" "$pdf_path" "$src_pane"
}

case "${1:-}" in
	--list)
		list_pdfs "${2:-$PWD}"
		;;
	--recent)
		list_recent_pdfs "${2:-$PWD}"
		;;
	--preview)
		preview_pdf "${2:-$PWD}" "${3:-}"
		;;
	--clear-preview)
		clear_cover_image
		;;
	--keymaps)
		run_keymaps_finder
		;;
	--list-keymaps)
		list_keymaps
		;;
	*)
		popup_picker "${1:-$PWD}" "${2:-}"
		;;
esac
