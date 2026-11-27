#!/usr/bin/env bash
set -euo pipefail

# Interactive search for tmux prefix keybindings (with -N notes).

selected="$(
  tmux list-keys -N -T prefix | fzf \
    --height=100% \
    --border=none \
    --margin=0 \
    --padding=0,1 \
    --layout=reverse \
    --no-scrollbar \
    --no-separator \
    --info=inline-right \
    --prompt='Keybind > ' \
    --header='j/k: move · l/Enter: choose · /: find · q: exit' \
    --bind='start:hide-input' \
    --bind='j:down,k:up,l:accept,q:abort' \
    --bind='/:show-input+unbind(j,k,l,q,/)' \
    --bind='esc:transform:if [ "$FZF_INPUT_STATE" = hidden ]; then echo abort; else echo "hide-input+rebind(j,k,l,q,/)"; fi' || true
)"

[ -n "$selected" ] || exit 0

tmux display-message "Keybind: Ctrl+Space -> $selected"
