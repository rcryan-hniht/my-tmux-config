#!/usr/bin/env bash
set -euo pipefail

# Multi-app Colorscheme Switcher (Ghostty + tmux + Neovim + Sigye).
# Syncs dark/light pairs across apps and live-reloads running instances.

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-theme"
ACTIVE_FILE="${CACHE_DIR}/current"
SIGYE_PALETTE="${CACHE_DIR}/sigye-palette"

GHOSTTY_CONF="${HOME}/.config/ghostty/config"
TMUX_THEME_CONF="${HOME}/.config/tmux/themes.conf"
NVIM_CS_FILE="${HOME}/.config/nvim/lua/plugins/colorscheme.lua"
SIGYE_CONF="${HOME}/.config/sigye/config.toml"
AGY_SETTINGS="${HOME}/.gemini/antigravity-cli/settings.json"

# Preset table:
# id|label|ghostty_theme|nvim_cs|sigye_theme|L_bg,L_surf,L_fg,L_muted,L_acc,L_sel_bg,L_sel_fg|D_bg,D_surf,D_fg,D_muted,D_acc,D_sel_bg,D_sel_fg
PRESETS=(
	"oasis-abyss|Oasis Abyss|dark: oasis-abyss-dark, light: oasis-abyss-light|oasis-abyss|White|#ffffff,#ededed,#181811,#5e5b4e,#9e1010,#d4d4d4,#181811|#000000,#1c1c1c,#f5f5dc,#605c4d,#e26e6e,#1c1c1c,#f5f5dc"
	"oasis-starlight|Oasis Starlight|dark: oasis-starlight-dark, light: oasis-starlight-light|oasis-starlight|White|#f5f2ea,#e1d8c1,#181811,#50463e,#2877c6,#e1d8c1,#181811|#000000,#1c2028,#f5f5dc,#4f5b6b,#5badff,#4d4528,#f5f5dc"
	"black-metal|Black Metal|dark: Black Metal, light: sequoia-monochrome-light|oasis|White|#edeef2,#d4d5dc,#282930,#5f6370,#525666,#b8d8f8,#1f242d|#000000,#404040,#c1c1c1,#888888,#dd9999,#c1c1c1,#000000"
	"sequoia|Sequoia Monochrome|dark: sequoia-monochrome-dark, light: sequoia-monochrome-light|oasis|White|#edeef2,#d4d5dc,#282930,#5f6370,#525666,#d4d5dc,#282930|#0f1014,#575861,#868690,#575861,#999eb2,#575861,#edeef2"
	"catppuccin-mocha|Catppuccin Mocha|Catppuccin Mocha|catppuccin|Cyan|#181825,#313244,#cdd6f4,#6c7086,#cba6f7,#45475a,#cdd6f4|#181825,#313244,#cdd6f4,#6c7086,#cba6f7,#45475a,#cdd6f4"
	"catppuccin-latte|Catppuccin Latte|Catppuccin Latte|catppuccin|Cyan|#e6e9ef,#ccd0da,#4c4f69,#6c6f85,#1e66f5,#bcc0cc,#4c4f69|#e6e9ef,#ccd0da,#4c4f69,#6c6f85,#1e66f5,#bcc0cc,#4c4f69"
	"tokyonight|TokyoNight Night|TokyoNight Night|tokyonight|Blue|#16161e,#292e42,#c0caf5,#565f89,#7aa2f7,#283457,#c0caf5|#16161e,#292e42,#c0caf5,#565f89,#7aa2f7,#283457,#c0caf5"
	"tokyonight-moon|TokyoNight Moon|TokyoNight Moon|tokyonight-moon|Blue|#1e2030,#2f334d,#c8d3f5,#636da6,#82aaff,#2d3f76,#c8d3f5|#1e2030,#2f334d,#c8d3f5,#636da6,#82aaff,#2d3f76,#c8d3f5"
	"tokyonight-day|TokyoNight Day|TokyoNight Day|tokyonight|Blue|#e1e2e7,#c4c8da,#3760bf,#848cb5,#2e7de9,#b7c1e3,#3760bf|#e1e2e7,#c4c8da,#3760bf,#848cb5,#2e7de9,#b7c1e3,#3760bf"
	"gruvbox-dark|Gruvbox Dark Hard|Gruvbox Dark Hard|habamax|Yellow|#1d2021,#3c3836,#ebdbb2,#928374,#fe8019,#504945,#ebdbb2|#1d2021,#3c3836,#ebdbb2,#928374,#fe8019,#504945,#ebdbb2"
	"gruvbox-light|Gruvbox Light Hard|Gruvbox Light Hard|habamax|Yellow|#ebdbb2,#d5c4a1,#3c3836,#7c6f64,#af3a03,#d5c4a1,#3c3836|#ebdbb2,#d5c4a1,#3c3836,#7c6f64,#af3a03,#d5c4a1,#3c3836"
	"rose-pine|Rose Pine|Rose Pine|oasis|Magenta|#191724,#26233a,#e0def4,#6e6a86,#ebbcba,#403d52,#e0def4|#191724,#26233a,#e0def4,#6e6a86,#ebbcba,#403d52,#e0def4"
	"rose-pine-dawn|Rose Pine Dawn|Rose Pine Dawn|oasis|Magenta|#faf4ed,#dfdad9,#575279,#9893a5,#d7827e,#dfdad9,#575279|#faf4ed,#dfdad9,#575279,#9893a5,#d7827e,#dfdad9,#575279"
	"kanagawa-wave|Kanagawa Wave|Kanagawa Wave|oasis|Cyan|#16161d,#2a2a37,#dcd7ba,#727169,#7e9cd8,#2d4f67,#dcd7ba|#16161d,#2a2a37,#dcd7ba,#727169,#7e9cd8,#2d4f67,#dcd7ba"
	"kanagawa-lotus|Kanagawa Lotus|Kanagawa Lotus|oasis|Cyan|#f2ecbc,#e7dba0,#545464,#8a8980,#4d699b,#c9cbd1,#545464|#f2ecbc,#e7dba0,#545464,#8a8980,#4d699b,#c9cbd1,#545464"
	"everforest|Everforest|dark: Everforest Dark Hard, light: Everforest Light Hard|oasis|Green|#f2efdf,#e5dfc5,#5c6a72,#829181,#8da101,#e5dfc5,#5c6a72|#272e33,#374145,#d3c6aa,#859289,#a7c080,#4c3743,#d3c6aa"
	"nord|Nord|dark: Nord, light: Nord Light|tokyonight|Cyan|#eceff4,#d8dee9,#2e3440,#4c566a,#5e81ac,#d8dee9,#2e3440|#2e3440,#3b4252,#eceff4,#616e88,#88c0d0,#4c566a,#eceff4"
	"dankcolors|DankColors|dankcolors|oasis|White|#f9f9f9,#e5e5e5,#1b1b1b,#6f6f6f,#2f5f21,#d4d4d4,#1b1b1b|#1b1b1b,#2e2e2e,#f9f9f9,#888888,#4f8c3f,#404040,#f9f9f9"
)

hex_swatch_into() {
	local var="$1"
	local hex="${2#\#}"
	printf -v "$var" '\033[48;2;%d;%d;%dm   \033[0m' "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}"
}

hex_swatch() {
	local out
	hex_swatch_into out "$1"
	printf '%s' "$out"
}

detect_current_id() {
	if [ -f "$ACTIVE_FILE" ]; then
		cat "$ACTIVE_FILE" 2>/dev/null || true
		return
	fi
	if [ -f "$GHOSTTY_CONF" ]; then
		local gtheme
		gtheme="$(grep -E '^[[:space:]]*theme[[:space:]]*=' "$GHOSTTY_CONF" 2>/dev/null | tail -n1 | sed 's/^[^=]*=[[:space:]]*//')"
		case "$gtheme" in
			*oasis-abyss*) echo "oasis-abyss" ;;
			*oasis-starlight*) echo "oasis-starlight" ;;
			*"Black Metal"*) echo "black-metal" ;;
			*sequoia-monochrome-dark*) echo "sequoia" ;;
			*"Catppuccin Latte"*) echo "catppuccin-latte" ;;
			*Catppuccin*) echo "catppuccin-mocha" ;;
			*"TokyoNight Moon"*) echo "tokyonight-moon" ;;
			*"TokyoNight Day"*) echo "tokyonight-day" ;;
			*TokyoNight*) echo "tokyonight" ;;
			*"Gruvbox Light"*) echo "gruvbox-light" ;;
			*Gruvbox*) echo "gruvbox-dark" ;;
			*"Rose Pine Dawn"*) echo "rose-pine-dawn" ;;
			*"Rose Pine"*) echo "rose-pine" ;;
			*"Kanagawa Lotus"*) echo "kanagawa-lotus" ;;
			*Kanagawa*) echo "kanagawa-wave" ;;
			*Everforest*) echo "everforest" ;;
			*Nord*) echo "nord" ;;
			*dankcolors*) echo "dankcolors" ;;
		esac
	fi
}

list_entries() {
	local cur
	cur="$(detect_current_id)"
	local row id label ghostty nvim sigye light dark
	for row in "${PRESETS[@]}"; do
		IFS='|' read -r id label ghostty nvim sigye light dark <<<"$row"
		IFS=',' read -r d_bg d_surf d_fg d_muted d_acc _ _ <<<"$dark"
		local sw_bg sw_acc mark
		hex_swatch_into sw_bg "$d_bg"
		hex_swatch_into sw_acc "$d_acc"
		if [ "$id" = "$cur" ]; then
			mark=$'\033[32m●\033[0m'
		else
			mark=$'\033[2m○\033[0m'
		fi
		printf '%s\t%s %s%s  %-32s \033[2m(%s)\033[0m\n' "$id" "$mark" "$sw_bg" "$sw_acc" "$label" "$nvim"
	done
}

find_preset() {
	local target="$1"
	local row id
	for row in "${PRESETS[@]}"; do
		id="${row%%|*}"
		if [ "$id" = "$target" ]; then
			printf '%s\n' "$row"
			return 0
		fi
	done
	return 1
}

preview_theme() {
	local id="${1:-}"
	local row
	row="$(find_preset "$id" || true)"
	[ -n "$row" ] || exit 0

	local _id label ghostty nvim sigye light dark
	IFS='|' read -r _id label ghostty nvim sigye light dark <<<"$row"
	IFS=',' read -r l_bg l_surf l_fg l_muted l_acc l_sbg l_sfg <<<"$light"
	IFS=',' read -r d_bg d_surf d_fg d_muted d_acc d_sbg d_sfg <<<"$dark"

	printf '\033[1m%s\033[0m\n' "$label"
	printf '\033[2m──────────────────────────────────────────────\033[0m\n'
	printf '  \033[36mGhostty:\033[0m %s\n' "$ghostty"
	printf '  \033[36mNeovim: \033[0m %s\n' "$nvim"
	printf '  \033[36mSigye:  \033[0m %s\n' "$sigye"
	printf '  \033[36mCava:   \033[0m auto (theo client_theme)\n\n'

	printf '\033[1mDark Palette (tmux)\033[0m\n'
	printf '  %s bg       %s\n' "$(hex_swatch "$d_bg")" "$d_bg"
	printf '  %s surface  %s\n' "$(hex_swatch "$d_surf")" "$d_surf"
	printf '  %s fg       %s\n' "$(hex_swatch "$d_fg")" "$d_fg"
	printf '  %s muted    %s\n' "$(hex_swatch "$d_muted")" "$d_muted"
	printf '  %s accent   %s\n\n' "$(hex_swatch "$d_acc")" "$d_acc"

	printf '\033[1mLight Palette (tmux)\033[0m\n'
	printf '  %s bg       %s\n' "$(hex_swatch "$l_bg")" "$l_bg"
	printf '  %s surface  %s\n' "$(hex_swatch "$l_surf")" "$l_surf"
	printf '  %s fg       %s\n' "$(hex_swatch "$l_fg")" "$l_fg"
	printf '  %s muted    %s\n' "$(hex_swatch "$l_muted")" "$l_muted"
	printf '  %s accent   %s\n' "$(hex_swatch "$l_acc")" "$l_acc"
}

write_sigye_palette() {
	local vals acc fg muted surf bg
	vals="$(tmux display-message -p '#{E:@theme-accent} #{E:@theme-fg} #{E:@theme-muted} #{E:@theme-surface} #{E:@theme-bg}' 2>/dev/null || true)"
	read -r acc fg muted surf bg <<<"$vals"
	if [[ "$acc" =~ ^#[0-9a-fA-F]{6}$ ]] && [[ "$fg" =~ ^#[0-9a-fA-F]{6}$ ]] && [[ "$muted" =~ ^#[0-9a-fA-F]{6}$ ]]; then
		mkdir -p "$CACHE_DIR"
		local tmp="${SIGYE_PALETTE}.tmp.$$"
		printf 'accent=%s\nfg=%s\nmuted=%s\nsurface=%s\nbg=%s\n' "$acc" "$fg" "$muted" "${surf:-$muted}" "${bg:-#000000}" >"$tmp"
		mv -f "$tmp" "$SIGYE_PALETTE"
	fi
}

sync_agy_theme() {
	write_sigye_palette || true
	local mode="${1:-}"
	if [ "$mode" != "light" ] && [ "$mode" != "dark" ]; then
		mode="$(tmux display-message -p '#{client_theme}' 2>/dev/null || true)"
		if [ "$mode" != "light" ] && [ "$mode" != "dark" ]; then
			mode="$(tmux list-clients -F '#{client_theme}' 2>/dev/null | grep -m1 -E '^(light|dark)$' || true)"
		fi
	fi
	[ "$mode" = "light" ] || [ "$mode" = "dark" ] || return 0
	[ -f "$AGY_SETTINGS" ] || return 0

	python3 - "$AGY_SETTINGS" "$mode" <<'PY'
import json, os, sys
path, mode = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
if data.get("colorScheme") == mode:
    sys.exit(0)
data["colorScheme"] = mode
tmp = f"{path}.tmp.{os.getpid()}"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PY
}

apply_theme() {
	local id="${1:-}"
	local row
	row="$(find_preset "$id" || true)"
	[ -n "$row" ] || {
		tmux display-message "tmux-theme: không tìm thấy theme '$id'"
		exit 1
	}

	local _id label ghostty nvim sigye light dark
	IFS='|' read -r _id label ghostty nvim sigye light dark <<<"$row"
	IFS=',' read -r l_bg l_surf l_fg l_muted l_acc l_sbg l_sfg <<<"$light"
	IFS=',' read -r d_bg d_surf d_fg d_muted d_acc d_sbg d_sfg <<<"$dark"

	mkdir -p "$CACHE_DIR"
	printf '%s\n' "$id" >"$ACTIVE_FILE"

	# 1. Ghostty config + SIGUSR2 live reload
	if [ -f "$GHOSTTY_CONF" ]; then
		python3 - "$GHOSTTY_CONF" "$ghostty" <<'PY'
import re, sys
path, theme_val = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    lines = f.read().splitlines(keepends=True)
out = []
replaced = False
for ln in lines:
    if re.match(r"^\s*theme\s*=", ln):
        if not replaced:
            out.append(f"theme = {theme_val}\n")
            replaced = True
    else:
        out.append(ln)
if not replaced:
    if out and not out[-1].endswith("\n"):
        out[-1] += "\n"
    out.append(f"theme = {theme_val}\n")
with open(path, "w", encoding="utf-8") as f:
    f.writelines(out)
PY
		pkill -USR2 -x ghostty 2>/dev/null || true
	fi

	# 2. Tmux themes.conf + live reload
	if [ -f "$TMUX_THEME_CONF" ]; then
		python3 - "$TMUX_THEME_CONF" "$label" \
			"$l_bg" "$l_surf" "$l_fg" "$l_muted" "$l_acc" "$l_sbg" "$l_sfg" \
			"$d_bg" "$d_surf" "$d_fg" "$d_muted" "$d_acc" "$d_sbg" "$d_sfg" <<'PY'
import re, sys
(path, label,
 l_bg, l_surf, l_fg, l_muted, l_acc, l_sbg, l_sfg,
 d_bg, d_surf, d_fg, d_muted, d_acc, d_sbg, d_sfg) = sys.argv[1:]

with open(path, "r", encoding="utf-8") as f:
    text = f.read()

replacements = {
    "@theme-bg":      f"set -g @theme-bg '#{{? #{{==:#{{client_theme}},light}},{l_bg},{d_bg}}}'".replace("#{? #{", "#{?#{", 1),
    "@theme-surface": f"set -g @theme-surface '#{{? #{{==:#{{client_theme}},light}},{l_surf},{d_surf}}}'".replace("#{? #{", "#{?#{", 1),
    "@theme-fg":      f"set -g @theme-fg '#{{? #{{==:#{{client_theme}},light}},{l_fg},{d_fg}}}'".replace("#{? #{", "#{?#{", 1),
    "@theme-muted":   f"set -g @theme-muted '#{{? #{{==:#{{client_theme}},light}},{l_muted},{d_muted}}}'".replace("#{? #{", "#{?#{", 1),
    "@theme-accent":  f"set -g @theme-accent '#{{? #{{==:#{{client_theme}},light}},{l_acc},{d_acc}}}'".replace("#{? #{", "#{?#{", 1),
}

lines = text.splitlines(keepends=True)
out = []
for ln in lines:
    matched = False
    for key, val in replacements.items():
        if re.match(rf"^set -g {re.escape(key)}\s+", ln):
            out.append(val + "\n")
            matched = True
            break
    if matched:
        continue
    if re.match(r"^set-hook -g client-light-theme\s+", ln):
        out.append(f"set-hook -g client-light-theme 'set -g mode-style \"bg={l_sbg},fg={l_sfg},bold\"'\n")
    elif re.match(r"^set-hook -g client-dark-theme\s+", ln):
        out.append(f"set-hook -g client-dark-theme 'set -g mode-style \"bg={d_sbg},fg={d_sfg},bold\"'\n")
    elif re.match(r"^\s*'set -g mode-style ", ln):
        # Update the 2-line if-shell block for initial load
        if out and "if-shell" in out[-1]:
            out.append(f"  'set -g mode-style \"bg={l_sbg},fg={l_sfg},bold\"' \\\n")
        else:
            out.append(f"  'set -g mode-style \"bg={d_sbg},fg={d_sfg},bold\"'\n")
    else:
        out.append(ln)

with open(path, "w", encoding="utf-8") as f:
    f.writelines(out)
PY
		tmux source-file "$TMUX_THEME_CONF" 2>/dev/null || true
	fi

	# 3. Neovim colorscheme.lua + live RPC to open nvim servers
	if [ -f "$NVIM_CS_FILE" ]; then
		python3 - "$NVIM_CS_FILE" "$nvim" <<'PY'
import re, sys
path, cs = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    text = f.read()
new_text = re.sub(r'(colorscheme\s*=\s*")[^"]*(")', rf'\g<1>{cs}\2', text, count=1)
with open(path, "w", encoding="utf-8") as f:
    f.write(new_text)
PY
		if command -v nvim >/dev/null 2>&1; then
			local sock
			for sock in "/run/user/$(id -u)"/nvim.*.0; do
				[ -S "$sock" ] || continue
				timeout 0.5 nvim --server "$sock" --remote-expr "v:lua.pcall(vim.cmd, 'colorscheme ${nvim}')" >/dev/null 2>&1 &
			done
		fi
	fi

	# 4. Sigye config.toml -> Tmux live-synced colorscheme
	if [ -f "$SIGYE_CONF" ]; then
		python3 - "$SIGYE_CONF" "Tmux" <<'PY'
import re, sys
path, st = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    text = f.read()
new_text = re.sub(r'^(color_theme\s*=\s*")[^"]*(")', rf'\g<1>{st}\2', text, count=1, flags=re.MULTILINE)
with open(path, "w", encoding="utf-8") as f:
    f.write(new_text)
PY
	fi

	# 5. agy colorScheme (light/dark theo client_theme của tmux)
	sync_agy_theme

	tmux display-message "${id}"
}

case "${1:-}" in
	--list)
		list_entries
		exit 0
		;;
	--preview)
		preview_theme "${2:-}"
		exit 0
		;;
	--apply)
		apply_theme "${2:-}"
		exit 0
		;;
	--sync-agy)
		sync_agy_theme "${2:-}"
		exit 0
		;;
esac

if ! command -v fzf >/dev/null 2>&1; then
	tmux display-message "tmux-theme: missing required command 'fzf'"
	exit 1
fi

self_path="$(realpath "${BASH_SOURCE[0]}")"
q_self="$(printf "'%s'" "${self_path//\'/\'\\\'\'}")"

selected="$(
	list_entries | fzf \
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
		--delimiter=$'\t' \
		--with-nth=2 \
		--prompt='Theme > ' \
		--header='j/k: move · l/Enter: apply · /: find · q: quit' \
		--bind='start:hide-input' \
		--bind='j:down,k:up,l:accept,q:abort' \
		--bind='/:show-input+unbind(j,k,l,q,/)' \
		--bind='esc:transform:if [ "$FZF_INPUT_STATE" = hidden ]; then echo abort; else echo "hide-input+rebind(j,k,l,q,/)"; fi' \
		--preview="${q_self} --preview {1}" \
		--preview-window='right,46%,border-left,wrap' || true
)"

[ -n "$selected" ] || exit 0
chosen_id="$(printf '%s\n' "$selected" | cut -f1)"
[ -n "$chosen_id" ] || exit 0

q_id="$(printf "'%s'" "${chosen_id//\'/\'\\\'\'}")"
tmux run-shell -b "${q_self} --apply ${q_id}"
