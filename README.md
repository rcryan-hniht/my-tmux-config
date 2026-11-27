# tmux-config

Personal tmux configuration (`prefix = Ctrl+Space`) with Vi-modal `fzf` popups, adaptive light/dark themes, and custom utility scripts.

## Structure

- `tmux.conf` - Core settings, navigation, hooks, popup bindings, and TPM plugins.
- `themes.conf` - Adaptive `@theme-*` palette (`#{client_theme}` light/dark), status bar, and copy-mode styles.
- `scripts/` - Standalone popup pickers, monitors, and lifecycle hooks.

## Core tmux Keybindings

Prefix is `Ctrl+Space`.

| Key | Action |
| :--- | :--- |
| `prefix + n` / `t` | New window / new session (current path) |
| `prefix + x` | Kill current pane without confirmation |
| `prefix + Space` | Switch to last window |
| `prefix + Left` / `Right` or `H` / `L` | Previous / next window (repeatable) |
| `prefix + \` or `\|` / `-` | Split pane horizontally / vertically (current path) |
| `prefix + h/j/k/l` | Resize pane (repeatable) |
| `prefix + m` | Toggle pane zoom |
| `Ctrl+Alt + h/j/k/l` | Swap pane with adjacent pane (no prefix) |
| `prefix + b` | Break pane into a new window |
| `prefix + Alt + h` / `l` | Join pane horizontally into previous / next window |
| `prefix + Alt + k` / `j` | Join pane vertically into previous / next window |
| `prefix + p` | Paste from Wayland clipboard (`wl-paste`) |
| `prefix + r` | Reload `tmux.conf` |
| `prefix + g` / `G` / `B` / `T` | Popup: `lazygit` / `lazydocker` / `btop` / `todo.md` |

## Shared Popup Navigation

All `fzf` popups start in Vi-modal navigation mode (input hidden):

| Key | Action |
| :--- | :--- |
| `j` / `k` | Move selection down / up |
| `l` / `Enter` | Open / apply selected item |
| `/` | Show search input |
| `Esc` | Hide search input (or close popup if already hidden) |
| `q` | Close popup |

## Scripts

### `scripts/tmux-agents.sh` (`prefix + a`)
Fullscreen monitor and controller for AI coding agents (`agy`, `claude`, `codex`, `opencode`). Displays live animated states (180ms Unix socket `reload-sync`), active-agent quota footer (`agy`, `codex`, `claude`), live conversation preview with compact `agy` swarm roster, and dedicated roster/quota views.

| Key | Action |
| :--- | :--- |
| `l` / `Enter` | Jump to selected pane and mark as seen |
| `s` | Toggle full `agy` Swarm Roster and board view |
| `u` | Toggle detailed quota and AI credits view |
| `Ctrl-y` | Approve prompt (send `Enter` to pane) |
| `Alt-e` | Interrupt task (send `Esc` to pane) |
| `Ctrl-s` / `Alt-d` | Mark pane as seen (`done` -> `idle`) |
| `Tab` / `Ctrl-a` | Toggle agent panes only / all tmux panes |
| `Ctrl-u` / `Ctrl-d` or `PgUp` / `PgDn` | Scroll preview half-page up / down |
| `Alt-k` / `Alt-j` | Scroll preview one line up / down |
| `Ctrl-r` | Refresh pane list, preview, and quota cache |
| `Alt-x` / `Ctrl-x` | Kill selected pane |
| `Ctrl-/` | Toggle preview pane |
| `?` / `F1` | Open in-popup keymap help |

### `scripts/tmux-agent-hook.sh` (hook)
Lifecycle hook invoked by `agy`, `claude`, `codex`, and tmux focus hooks (`after-select-pane`, `after-select-window`, `client-session-changed`). Persists per-pane agent state (`working`, `blocked`, `done`, `idle`) and clears unseen status when focused. No interactive keybinds.

### `scripts/tmux-theme.sh` (`prefix + C`)
Colorscheme switcher syncing dark/light palettes across Ghostty (`SIGUSR2`), tmux (`themes.conf`), Neovim (live RPC to open sockets), `sigye`, `cava`, and `agy` (`settings.json`).

| Key | Action |
| :--- | :--- |
| `l` / `Enter` | Apply selected theme across all apps |

### `scripts/tmux-clock.sh` (`prefix + c`)
Fullscreen isolated-socket dashboard running `sigye` and dual `cava` visualizers (`mirror` + `wave`) with persistent layout presets and live docking.

| Key | Action |
| :--- | :--- |
| `Tab` / `Shift-Tab` | Cycle through 4 layouts without restarting panes |
| `,` | Toggle fullscreen <-> active-pane popup size (or undock) |
| `]` / `[` | Dock dashboard into bottom / top half outer split pane |
| `c` | Pick colorscheme inside dashboard |
| `Ctrl-q` | Close dashboard |

### `scripts/tmux-pdf.sh` (`prefix + v`)
PDF picker grouped by directory with Kitty graphics cover preview (`pdftoppm`) and `tdf` viewer integration.

| Key | Action |
| :--- | :--- |
| `l` / `Enter` or `Ctrl-w` | Open PDF in a new window (`tdf`) |
| `Ctrl-s` | Open PDF in a horizontal split pane |
| `Ctrl-v` | Open PDF in a vertical split pane |
| `Ctrl-r` | Switch to recently opened PDFs |
| `Ctrl-a` | Switch back to all PDFs |
| `Ctrl-/` | Toggle cover preview |
| `?` | Open keymap help |

### `scripts/tmux-tex.sh` (`prefix + Ctrl-t`)
LaTeX file picker that compiles with `tectonic` and previews output in `tdf`.

| Key | Action |
| :--- | :--- |
| `l` / `Enter` | Start watch mode (compile on save + preview) |
| `Ctrl-r` | Compile once |
| `Ctrl-l` | Open build log |

### `scripts/tmux-history.sh` (`prefix + X`)
Interactive manager for running tmux sessions and saved `tmux-resurrect` history snapshots.

| Key | Action |
| :--- | :--- |
| `Tab` | Multi-select sessions |
| `x` | Kill selected session and purge it from all resurrect snapshots (skips current session) |

### `scripts/tmux-kill.sh` (`prefix + K`)
Interactive listener port (`ss`) and user process (`ps`) killer.

| Key | Action |
| :--- | :--- |
| `Tab` | Multi-select targets |
| `l` / `Enter` | Send `SIGTERM` |
| `Ctrl-x` | Send `SIGKILL` (`kill -9`) |

### `scripts/tmux-url.sh` (`prefix + u`)
Extracts URLs from the current pane and sibling panes in the active window (newest first).

| Key | Action |
| :--- | :--- |
| `l` / `Enter` | Open URL in default browser (`xdg-open`) |
| `y` / `Ctrl-y` | Copy URL to Wayland clipboard (`wl-copy`) or tmux buffer |

### `scripts/tmux-cht.sh` (`prefix + Ctrl-c`)
Quick cheat sheet lookup via `cht.sh` with local last-query caching.

| Key | Action |
| :--- | :--- |
| `l` / `Enter` | Query topic and open in a right split pane |
| `Ctrl-p` | Query topic and open inside the popup |
| `Ctrl-r` | Reopen last cached cheat sheet in right pane |

### `scripts/tmux-tldr.sh` (`prefix + e`)
Quick CLI examples lookup via local `tldr`, falling back to `cht.sh` or `man`.

| Key | Action |
| :--- | :--- |
| `l` / `Enter` | Open examples for selected or typed command |

### `scripts/tmux-sessionizer.sh` (`prefix + P`)
Project directory picker that switches to an existing tmux session or creates a new one.

| Key | Action |
| :--- | :--- |
| `l` / `Enter` | Switch to or create session for selected directory |

### `scripts/tmux-ssh.sh` (`prefix + S`)
SSH host picker parsed from `~/.ssh/config` (also accepts arbitrary `user@host` input).

| Key | Action |
| :--- | :--- |
| `l` / `Enter` | Connect in a new tmux window |

### `scripts/tmux-layout.sh` (`prefix + W`)
Applies predefined pane layouts (`main-top`, `main-left`, `grid`, `tri-col`, `dev-ide`) to the current window if single-pane, or to a new window.

| Key | Action |
| :--- | :--- |
| `l` / `Enter` | Apply selected layout preset |

### `scripts/tmux-keys.sh` (`prefix + F`)
Fuzzy finder over all annotated prefix keybindings (`tmux list-keys -N -T prefix`).

| Key | Action |
| :--- | :--- |
| `l` / `Enter` | Display selected keybind in status line |

### `scripts/tmux-ime.sh` (background watcher)
Monitors `fcitx5` (`fcitx5-remote -n`) every 250ms and updates `@ime_label` (`EN` / `VI`) in the right status bar only when the input method changes. No interactive keybinds.

### `scripts/resurrect-save.sh` (hook)
Runs `tmux-resurrect`'s `save.sh` on `client-detached` and backfills the `state` line from `#{session_last_attached}` so auto-restore reattaches to the last active session. No interactive keybinds.

### `scripts/resurrect-ttl.sh` (startup + attach hook)
Deletes `tmux-resurrect` snapshots older than 48 hours and prunes detached sessions idle for more than 48 hours on `client-attached`. No interactive keybinds.

## Installation

### Requirements

- `tmux` >= 3.4, `fzf` >= 0.62, `python3`, `awk`, `curl`
- Optional: `fd`, `tdf`, `pdftoppm`, `tectonic`, `sigye`, `cava`, `lazygit`, `lazydocker`, `btop`, `wl-clipboard`, `fcitx5`

### Setup

```bash
git clone https://github.com/rcryan-hniht/tmux-config ~/.config/tmux
git clone https://github.com/tmux-plugins/tpm ~/.config/tmux/plugins/tpm
```

Launch `tmux` and press `Ctrl+Space` then `Shift+I` to install TPM plugins (`vim-tmux-navigator`, `tmux-resurrect`, `tmux-continuum`, `tmux-yank`).
