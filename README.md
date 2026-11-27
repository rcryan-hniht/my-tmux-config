# tmux-config

Personal `tmux` configuration with Vi-modal `fzf` popups, adaptive light/dark theming, and a live AI coding agent monitor (`agy`, `claude`, `codex`, `opencode`).

## Highlights

- **Prefix**: `Ctrl+Space` (`base-index 1`, `renumber-windows on`, Wayland clipboard via `wl-paste`, `extended-keys on`, `allow-passthrough all` for Kitty graphics / Ghostty).
- **AI Agents Monitor (`prefix + a`)**: Fullscreen `fzf` popup with live 180ms Braille spinner animations (zero-flicker Unix socket `reload-sync`), live conversation tail + compact `agy` Swarm Roster, full roster (`s`) and quota/credits (`u`) views, and active-agent quota footer (`agy`, `codex`, `claude`).
- **Multi-app Colorscheme Switcher (`prefix + C`)**: Syncs Light/Dark palettes across Ghostty (`SIGUSR2`), `tmux`, Neovim (live RPC), `sigye`, `cava`, and `agy`.
- **Vi-modal Popups**: Consistent `j`/`k` navigation, `l`/`Enter` open, `/` search, `q`/`Esc` quit across every picker.
- **Session Persistence with 48h TTL**: `tmux-resurrect` + `tmux-continuum` with automatic save on detach, 48h history cleanup, and interactive session/history deletion (`prefix + X`).
- **IME Indicator**: Live `EN` / `VI` status indicator (`fcitx5`) in the status bar.

## Keybindings (`prefix = Ctrl+Space`)

| Binding | Action |
| :--- | :--- |
| `prefix + \` or `\|` / `-` | Split pane horizontal / vertical (current path) |
| `prefix + h/j/k/l` | Resize pane (repeatable) |
| `prefix + m` | Toggle pane zoom |
| `Ctrl + Alt + h/j/k/l` | Swap pane with adjacent pane |
| `prefix + Left/Right` or `H/L` | Previous / next window |
| `prefix + b` | Break pane into its own window |
| `prefix + Alt + h/l` | Join pane horizontally into previous / next window |
| `prefix + Alt + k/j` | Join pane vertically into previous / next window |
| `prefix + a` | AI Agents Monitor (`agy` / `claude` / `codex`) |
| `prefix + C` | Colorscheme Switcher |
| `prefix + C-c` | Cheat sheet (`cht.sh`) |
| `prefix + c` | Clock popup (`sigye` / `cava`) |
| `prefix + v` | PDF Picker with Kitty cover preview (`tdf`) |
| `prefix + C-t` | TeX → PDF compiler (`tectonic` + `tdf`) |
| `prefix + P` | Project Sessionizer |
| `prefix + X` | Session & Resurrect History Manager (`x` to delete) |
| `prefix + K` | Port & Process Killer |
| `prefix + u` | URL Picker (`y` copy, `l`/`Enter` open) |
| `prefix + F` | Interactive Keybind Finder |
| `prefix + W` | Window Layout Presets |
| `prefix + S` | SSH Host Picker |
| `prefix + g` / `G` / `B` | LazyGit / LazyDocker / btop |

## Installation

### Requirements

- `tmux` ≥ 3.4 (tested on 3.6)
- `fzf` ≥ 0.62 (for `--footer`, `hide-input`, and `--listen-unsafe`)
- `python3`, `awk`, `curl`
- Optional: `fd`, `tdf`, `pdftoppm`, `tectonic`, `lazygit`, `lazydocker`, `btop`, `wl-clipboard`, `fcitx5`

### Setup

```bash
git clone https://github.com/rcryan-hniht/tmux-config ~/.config/tmux
git clone https://github.com/tmux-plugins/tpm ~/.config/tmux/plugins/tpm
```

Start `tmux` and press `Ctrl+Space` then `Shift+I` (`I`) to install TPM plugins (`vim-tmux-navigator`, `tmux-resurrect`, `tmux-continuum`, `tmux-yank`).
