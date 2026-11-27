#!/usr/bin/env python3
"""Multi-process ATK68 V2 RGB Studio panes for isolated inner tmux popup (prefix + A).

Subcommands:
  --pane-controls <run_dir> <inner_sock>   Left event-driven 4-tab control deck (0 idle redraws)
  --pane-board <run_dir>                   Right-top continuous 28fps staggered 68-key board (in-place updates)
  --pane-telemetry <run_dir>               Right-bottom event-driven sliders, USB telemetry & actions
  --help-popup                             Centered keybindings reference popup (?)
"""

from __future__ import annotations

import fcntl
import json
import math
import os
import queue
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import tty

# ── Exact ATK68 V2 68-key physical layout (atk68v2-mod/src/layout.rs) ────────
RAW_KEYS: list[tuple[str, int, int]] = [
    ("Esc", 0, 100), ("1", 0, 100), ("2", 0, 100), ("3", 0, 100), ("4", 0, 100),
    ("5", 0, 100), ("6", 0, 100), ("7", 0, 100), ("8", 0, 100), ("9", 0, 100),
    ("0", 0, 100), ("-", 0, 100), ("=", 0, 100), ("Bksp", 0, 250), ("Ins", 0, 100),
    ("Tab", 1, 150), ("Q", 1, 100), ("W", 1, 100), ("E", 1, 100), ("R", 1, 100),
    ("T", 1, 100), ("Y", 1, 100), ("U", 1, 100), ("I", 1, 100), ("O", 1, 100),
    ("P", 1, 100), ("[", 1, 100), ("]", 1, 100), ("\\", 1, 180), ("Del", 1, 100),
    ("Caps", 2, 180), ("A", 2, 100), ("S", 2, 100), ("D", 2, 100), ("F", 2, 100),
    ("G", 2, 100), ("H", 2, 100), ("J", 2, 100), ("K", 2, 100), ("L", 2, 100),
    (";", 2, 100), ("'", 2, 100), ("Enter", 2, 250), ("PgU", 2, 100),
    ("Shift", 3, 210), ("Z", 3, 100), ("X", 3, 100), ("C", 3, 100), ("V", 3, 100),
    ("B", 3, 100), ("N", 3, 100), ("M", 3, 100), (",", 3, 100), (".", 3, 100),
    ("/", 3, 100), ("Shft", 3, 190), ("↑", 3, 100), ("PgD", 3, 100),
    ("Ctrl", 4, 120), ("Win", 4, 120), ("Alt", 4, 120), ("Space", 4, 660),
    ("Alt", 4, 100), ("Fn", 4, 100), ("Ctrl", 4, 100),
    ("←", 4, 100), ("↓", 4, 100), ("→", 4, 100),
]

MODES: list[tuple[str, str, str]] = [
    ("bars", "bars", "5-row spectrum + peak"),
    ("stereo-bars", "stereo", "mirrored stereo bars"),
    ("waveform", "waveform", "oscilloscope trace"),
    ("waves", "waves", "flowing color ribbon"),
    ("bass-pulse", "bass", "radial bass + sparkle"),
    ("vu-center", "vu", "center-out stereo VU"),
    ("heatmap", "heat", "frequency heatmap"),
    ("ambient", "ambient", "soft reactive glow"),
]

PALETTES: list[tuple[str, str, list[tuple[int, int, int]]]] = [
    ("cyberpunk", "Neon cyan -> magenta", [(0x00, 0xF0, 0xFF), (0x4B, 0x3F, 0xFF), (0xB4, 0x00, 0xFF), (0xFF, 0x00, 0x99), (0xFF, 0x7A, 0xE6)]),
    ("rainbow", "Full RGB spectrum", [(0xFF, 0x00, 0x00), (0xFF, 0x7F, 0x00), (0xFF, 0xFF, 0x00), (0x00, 0xFF, 0x00), (0x00, 0xFF, 0xFF), (0x00, 0x40, 0xFF), (0xB0, 0x00, 0xFF)]),
    ("fire", "Ember -> molten gold", [(0x4A, 0x00, 0x00), (0xFF, 0x1E, 0x00), (0xFF, 0x88, 0x00), (0xFF, 0xE0, 0x00), (0xFF, 0xF8, 0xD0)]),
    ("ocean", "Deep sea -> aqua", [(0x00, 0x18, 0x60), (0x00, 0x55, 0xFF), (0x00, 0xC8, 0xFF), (0x40, 0xFF, 0xD0), (0xD8, 0xFF, 0xFF)]),
    ("matrix", "Phosphor green", [(0x00, 0x28, 0x00), (0x00, 0xA8, 0x20), (0x00, 0xFF, 0x41), (0xA8, 0xFF, 0xB8)]),
    ("vaporwave", "Synth pink -> teal", [(0x3B, 0x00, 0x88), (0xFF, 0x2A, 0x85), (0xFF, 0x7B, 0x54), (0x2D, 0xE2, 0xE6)]),
    ("mono-white", "Pure studio white", [(0xFF, 0xFF, 0xFF)]),
]

SOLID_PRESETS: list[tuple[str, tuple[int, int, int]]] = [
    ("Cyber Cyan", (0x00, 0xF0, 0xFF)),
    ("Neon Magenta", (0xFF, 0x00, 0x99)),
    ("Electric Violet", (0x9D, 0x4E, 0xDD)),
    ("Crimson Pulse", (0xFF, 0x24, 0x42)),
    ("Sunset Amber", (0xFF, 0x88, 0x00)),
    ("Emerald Glow", (0x00, 0xE6, 0x76)),
    ("Rose Pine", (0xD7, 0x82, 0x7E)),
    ("Ice Blue", (0x56, 0xCC, 0xF2)),
    ("Warm Ivory", (0xFF, 0xE4, 0xB8)),
    ("Pure White", (0xFF, 0xFF, 0xFF)),
    ("Lights Off", (0x00, 0x00, 0x00)),
]

CAVA_MODES: list[tuple[str, str]] = [
    ("auto", "best preset per mode"),
    ("standard", "balanced spectrum"),
    ("stereo", "mirrored L/R channels"),
    ("monstercat", "smooth wide peaks"),
    ("waves", "flowing wave smoothing"),
    ("waveform", "raw oscilloscope"),
    ("bass", "low-end punch focus"),
]

TABS = ["Modes", "Palettes", "Solid", "Tuning"]


def hex_to_rgb(s: str) -> tuple[int, int, int] | None:
    h = s.strip().lstrip("#")
    if len(h) != 6:
        return None
    try:
        return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))
    except ValueError:
        return None


def rgb_to_hex(rgb: tuple[int, int, int]) -> str:
    return f"#{rgb[0]:02X}{rgb[1]:02X}{rgb[2]:02X}"


def fg_rgb(rgb: tuple[int, int, int]) -> str:
    return f"\x1b[38;2;{rgb[0]};{rgb[1]};{rgb[2]}m"


def bg_rgb(rgb: tuple[int, int, int]) -> str:
    return f"\x1b[48;2;{rgb[0]};{rgb[1]};{rgb[2]}m"


def luma(rgb: tuple[int, int, int]) -> float:
    return 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]


def sample_stops(stops: list[tuple[int, int, int]], t: float) -> tuple[float, float, float]:
    if not stops:
        return (1.0, 1.0, 1.0)
    if len(stops) == 1:
        c = stops[0]
        return (c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
    t = max(0.0, min(1.0, t))
    scaled = t * (len(stops) - 1)
    idx = min(int(scaled), len(stops) - 2)
    frac = scaled - idx
    a, b = stops[idx], stops[idx + 1]
    return (
        (a[0] + (b[0] - a[0]) * frac) / 255.0,
        (a[1] + (b[1] - a[1]) * frac) / 255.0,
        (a[2] + (b[2] - a[2]) * frac) / 255.0,
    )


def parse_palette_stops(spec: str, theme_stops: list[tuple[int, int, int]] | None = None) -> list[tuple[int, int, int]]:
    low = spec.strip().lower()
    if low == "theme" and theme_stops:
        return theme_stops
    for name, _, stops in PALETTES:
        if low == name:
            return stops
    if low.startswith("custom:"):
        out = []
        for tok in spec[7:].split(","):
            c = hex_to_rgb(tok)
            if c is not None:
                out.append(c)
        if out:
            return out
    c = hex_to_rgb(spec)
    if c is not None:
        return [c]
    return PALETTES[0][2]


def swatch_bar(stops: list[tuple[int, int, int]], width: int) -> str:
    parts = []
    denom = max(1, width - 1)
    for i in range(width):
        r, g, b = sample_stops(stops, i / denom)
        parts.append(fg_rgb((int(r * 255), int(g * 255), int(b * 255))) + "█")
    return "".join(parts) + "\x1b[0m"


def slider_bar(frac: float, width: int, fill_rgb: tuple[int, int, int], empty_rgb: tuple[int, int, int]) -> str:
    frac = max(0.0, min(1.0, frac))
    filled = int(round(frac * width))
    return f"{fg_rgb(fill_rgb)}{'█' * filled}{fg_rgb(empty_rgb)}{'░' * (width - filled)}\x1b[0m"


def load_tmux_theme() -> dict[str, tuple[int, int, int]]:
    defaults = {
        "bg": (0x12, 0x12, 0x16),
        "surface": (0x2A, 0x2A, 0x34),
        "fg": (0xDC, 0xDC, 0xE4),
        "muted": (0x7E, 0x7E, 0x8F),
        "accent": (0xD7, 0x82, 0x7E),
    }
    try:
        out = subprocess.check_output(
            ["tmux", "display-message", "-p", "#{E:@theme-bg}\t#{E:@theme-surface}\t#{E:@theme-fg}\t#{E:@theme-muted}\t#{E:@theme-accent}"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=0.4,
        ).strip()
        parts = out.split("\t")
        if len(parts) == 5:
            for k, v in zip(["bg", "surface", "fg", "muted", "accent"], parts):
                c = hex_to_rgb(v)
                if c:
                    defaults[k] = c
    except Exception:
        pass
    return defaults


def notify_fifo(fifo_path: str, msg: str = "update") -> None:
    if not os.path.exists(fifo_path):
        return
    try:
        fd = os.open(fifo_path, os.O_RDWR | os.O_NONBLOCK)
        try:
            os.write(fd, (msg + "\n").encode("utf-8"))
        finally:
            os.close(fd)
    except OSError:
        pass


def write_state_atomic(run_dir: str, data: dict) -> None:
    path = os.path.join(run_dir, "state.json")
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        os.replace(tmp, path)
    except OSError:
        pass


def read_state(run_dir: str) -> dict:
    path = os.path.join(run_dir, "state.json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def build_key_coords() -> list[dict]:
    row_totals = [0] * 5
    for _, r, w in RAW_KEYS:
        row_totals[r] += w
    row_cursors = [0] * 5
    raw_x = []
    for _, r, w in RAW_KEYS:
        center = row_cursors[r] + w * 0.5
        row_cursors[r] += w
        raw_x.append(center / max(1, row_totals[r]))
    min_x, max_x = min(raw_x), max(raw_x)
    span = max(1e-6, max_x - min_x)

    keys = []
    row_cursors = [0] * 5
    for idx, (label, r, w) in enumerate(RAW_KEYS):
        x0_u = row_cursors[r] / 100.0
        row_cursors[r] += w
        x1_u = row_cursors[r] / 100.0
        keys.append({
            "idx": idx,
            "label": label,
            "row": r,
            "row_from_bottom": 4 - r,
            "w_u100": w,
            "x0_u": x0_u,
            "x1_u": x1_u,
            "row_total_u": row_totals[r] / 100.0,
            "x_norm": max(0.0, min(1.0, (raw_x[idx] - min_x) / span)),
            "y_norm": r / 4.0,
        })
    return keys


KEYS = build_key_coords()
ROWS_KEYS: list[list[dict]] = [[k for k in KEYS if k["row"] == r] for r in range(5)]


# ── PANE 2: Dedicated continuous staggered 68-key board process ──────────────
class PreviewCava:
    def __init__(self, bars: int = 16, fps: int = 30):
        self.bars = bars
        self.proc: subprocess.Popen | None = None
        self.fd: int | None = None
        self.conf_path: str | None = None
        self.buf = bytearray()
        self.bands = [0.0] * bars
        self.frame_bytes = bars * 2
        self._start(fps)

    def _start(self, fps: int) -> None:
        if not shutil.which("cava"):
            return
        try:
            fd, path = tempfile.mkstemp(prefix="tmux-atk-cava-", suffix=".conf")
            self.conf_path = path
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(
                    f"[general]\nframerate = {fps}\nbars = {self.bars}\n"
                    f"autosens = 1\nsensitivity = 100\nsleep_timer = 0\n"
                    f"[input]\nmethod = pulse\nsource = auto\n"
                    f"[output]\nmethod = raw\nraw_target = /dev/stdout\n"
                    f"data_format = binary\nbit_format = 16bit\nchannels = mono\n"
                    f"[smoothing]\nmonstercat = 1\nwaves = 0\nnoise_reduction = 58\n"
                )
            self.proc = subprocess.Popen(
                ["cava", "-p", path],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )
            assert self.proc.stdout is not None
            self.fd = self.proc.stdout.fileno()
            flags = fcntl.fcntl(self.fd, fcntl.F_GETFL)
            fcntl.fcntl(self.fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        except Exception:
            self.close()

    def poll_read(self) -> None:
        if self.fd is None:
            return
        try:
            while True:
                chunk = os.read(self.fd, 4096)
                if not chunk:
                    break
                self.buf.extend(chunk)
        except BlockingIOError:
            pass
        except OSError:
            return
        if len(self.buf) >= self.frame_bytes:
            excess = len(self.buf) % self.frame_bytes
            start = len(self.buf) - self.frame_bytes - excess
            frame = self.buf[start : start + self.frame_bytes]
            vals = struct.unpack(f"<{self.bars}H", frame)
            self.bands = [v / 65535.0 for v in vals]
            del self.buf[: start + self.frame_bytes]

    def close(self) -> None:
        if self.proc is not None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=0.4)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
            self.proc = None
        self.fd = None
        if self.conf_path and os.path.exists(self.conf_path):
            try:
                os.unlink(self.conf_path)
            except OSError:
                pass
            self.conf_path = None


class BoardSimulator:
    def __init__(self) -> None:
        self.t = 0.0
        self.peaks = [0.0] * len(KEYS)
        self.trails = [0.0] * len(KEYS)
        self.bass_env = 0.0
        self.ripple_r = 1.5
        self.ripple_s = 0.0

    def _sample_band(self, bands: list[float], x: float) -> float:
        n = len(bands)
        if n == 0:
            return 0.0
        pos = max(0.0, min(1.0, x)) * (n - 1)
        i = int(pos)
        j = min(n - 1, i + 1)
        f = pos - i
        return bands[i] * (1.0 - f) + bands[j] * f

    def render(
        self,
        mode: str,
        stops: list[tuple[int, int, int]],
        brightness: float,
        bands: list[float],
        dt: float,
        solid_rgb: tuple[int, int, int] | None = None,
    ) -> list[tuple[int, int, int]]:
        self.t += dt
        b = max(0.0, min(1.0, brightness))
        if solid_rgb is not None:
            c = (int(solid_rgb[0] * b), int(solid_rgb[1] * b), int(solid_rgb[2] * b))
            return [c] * len(KEYS)

        peak_audio = max(bands) if bands else 0.0
        if peak_audio < 0.02:
            eff_bands = [
                0.22 + 0.18 * (0.5 + 0.5 * math.sin(self.t * 2.2 + i * 0.45))
                * (0.65 + 0.35 * math.cos(self.t * 1.1 - i * 0.25))
                for i in range(16)
            ]
        else:
            eff_bands = bands

        out: list[tuple[int, int, int]] = []
        bass = sum(eff_bands[:4]) / 4.0
        mid = sum(eff_bands[4:10]) / 6.0
        treble = sum(eff_bands[10:]) / max(1, len(eff_bands) - 10)
        energy = min(1.0, bass * 0.5 + mid * 0.35 + treble * 0.15)

        if mode == "bass-pulse":
            if bass - self.bass_env > 0.12 and bass > 0.30 and self.ripple_r > 0.25:
                self.ripple_r = 0.0
                self.ripple_s = min(1.0, max(0.45, bass))
            self.bass_env += (bass - self.bass_env) * min(1.0, dt * 12.0)
            self.ripple_r += dt * (1.5 + self.bass_env * 1.4)
            self.ripple_s *= math.exp(-dt * 2.2)

        for k in KEYS:
            idx = k["idx"]
            xn = k["x_norm"]
            yn = k["y_norm"]
            rb = k["row_from_bottom"]

            if mode in ("bars", "stereo-bars"):
                sx = abs(xn - 0.5) * 2.0 if mode == "stereo-bars" else xn
                lvl = self._sample_band(eff_bands, sx)
                self.peaks[idx] = max(lvl, self.peaks[idx] - dt * 0.55)
                fill = max(0.0, min(1.0, lvl * 5.0 - rb))
                gt = max(0.0, min(1.0, (rb / 4.0) * 0.8 + xn * 0.2))
                col = sample_stops(stops, gt)
                r, g, bl = col[0] * fill, col[1] * fill, col[2] * fill
                pk = self.peaks[idx]
                if pk > 0.05 and min(4, int(pk * 4.99)) == rb:
                    cap = sample_stops(stops, 0.95)
                    cs = max(0.35, min(1.0, pk * 1.35))
                    r, g, bl = max(r, cap[0] * cs), max(g, cap[1] * cs), max(bl, cap[2] * cs)
            elif mode == "waveform":
                lvl = self._sample_band(eff_bands, xn)
                osc = math.sin(xn * math.tau * 1.5 - self.t * 7.5) * lvl * 0.48
                wy = max(0.0, min(1.0, 0.5 - osc))
                dist = abs(yn - wy)
                trace = (max(0.0, min(1.0, 1.0 - dist / 0.28)) ** 1.35)
                self.trails[idx] = max(trace, self.trails[idx] * math.exp(-dt * 8.0))
                inten = self.trails[idx]
                col = sample_stops(stops, min(1.0, xn * 0.65 + lvl * 0.35))
                r, g, bl = col[0] * inten, col[1] * inten, col[2] * inten
            elif mode == "waves":
                lvl = self._sample_band(eff_bands, xn)
                phase = self.t * (2.2 + energy * 4.0)
                amp = min(0.46, 0.14 + lvl * 0.42)
                wy = 0.5 + amp * math.sin(xn * math.tau * 1.35 - phase)
                dist = abs(yn - max(0.0, min(1.0, wy)))
                rib = (max(0.0, min(1.0, 1.0 - dist / 0.38)) ** 1.2)
                inten = rib * (0.28 + 0.72 * max(lvl, energy * 0.6))
                col = sample_stops(stops, (xn + self.t * 0.18) % 1.0)
                r, g, bl = col[0] * inten, col[1] * inten, col[2] * inten
            elif mode == "bass-pulse":
                dx = xn - 0.5
                dy = (yn - 0.55) * 0.72
                dist = math.sqrt(dx * dx + dy * dy) * 2.0
                core = self.bass_env * max(0.0, 1.0 - dist * 0.72)
                ring = max(0.0, 1.0 - abs(dist - self.ripple_r) / 0.30) * self.ripple_s
                sp = (math.sin(idx * 1.618 + self.t * 12.0) * 0.5 + 0.5) ** 3.0
                sparkle = treble * sp * (0.35 + 0.65 * min(1.0, dist))
                inten = min(1.0, core + ring * 0.9 + mid * 0.22 + sparkle * 0.75)
                col = sample_stops(stops, min(1.0, dist * 0.55 + sparkle * 0.45))
                r, g, bl = col[0] * inten, col[1] * inten, col[2] * inten
            elif mode == "vu-center":
                dist = abs(xn - 0.5) * 2.0
                lvl = min(1.0, energy * 1.35)
                fill = max(0.0, min(1.0, (lvl - dist) / 0.14 + 0.5))
                rw = 1.0 - abs(yn - 0.5) * 0.30
                inten = fill * rw
                col = sample_stops(stops, dist)
                r, g, bl = col[0] * inten, col[1] * inten, col[2] * inten
            elif mode == "heatmap":
                lvl = self._sample_band(eff_bands, xn)
                rf = 0.78 + 0.22 * (1.0 - abs(yn - 0.5) * 2.0)
                self.trails[idx] += (lvl * rf - self.trails[idx]) * min(1.0, dt * 12.0)
                heat = max(0.0, min(1.0, self.trails[idx]))
                col = sample_stops(stops, heat)
                inten = heat ** 0.78
                r, g, bl = col[0] * inten, col[1] * inten, col[2] * inten
            else:
                breath = 0.5 + 0.5 * math.sin(self.t * 1.3)
                lvl = self._sample_band(eff_bands, xn)
                inten = min(0.85, 0.26 + 0.12 * breath + bass * 0.35 + lvl * 0.15)
                col = sample_stops(stops, (xn * 0.55 + yn * 0.2 + self.t * 0.06) % 1.0)
                r, g, bl = col[0] * inten, col[1] * inten, col[2] * inten

            g_exp = 1.15
            out.append((
                int(min(255, max(0, round(((r * b) ** g_exp) * 255)))),
                int(min(255, max(0, round(((g * b) ** g_exp) * 255)))),
                int(min(255, max(0, round(((bl * b) ** g_exp) * 255)))),
            ))
        return out


def run_pane_board(run_dir: str) -> int:
    th = load_tmux_theme()
    is_light = luma(th["bg"]) > 140
    theme_stops = [th["muted"], th["fg"], th["accent"]]
    c_fg = fg_rgb(th["fg"])
    c_muted = fg_rgb(th["muted"])
    case_bg = (0x1B, 0x1A, 0x24) if is_light else (0x13, 0x13, 0x18)
    case_frame = (0x3D, 0x3A, 0x4E) if is_light else (0x2D, 0x2D, 0x38)
    key_off = (0x2A, 0x28, 0x38) if is_light else (0x20, 0x20, 0x28)

    fifo_path = os.path.join(run_dir, "board.fifo")
    fifo_fd = os.open(fifo_path, os.O_RDWR | os.O_NONBLOCK)
    cava = PreviewCava(bars=16, fps=30)
    sim = BoardSimulator()

    running = True
    need_chrome = True

    def _stop(_s: int, _f: object) -> None:
        nonlocal running
        running = False

    def _winch(_s: int, _f: object) -> None:
        nonlocal need_chrome
        need_chrome = True

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGHUP, _stop)
    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGWINCH, _winch)

    st = read_state(run_dir)
    last_dims = (0, 0)
    last_chrome_sig: tuple | None = None
    last_solid_frame: str | None = None
    last_t = time.monotonic()
    frame_interval = 1.0 / 28.0

    try:
        sys.stdout.write("\x1b[?25l\x1b[2J")
        sys.stdout.flush()
        while running and os.path.isdir(run_dir):
            now = time.monotonic()
            dt = max(0.005, min(0.1, now - last_t))
            last_t = now

            cols, rows = shutil.get_terminal_size((108, 24))
            cols = max(56, cols)
            rows = max(14, rows)
            if (cols, rows) != last_dims:
                last_dims = (cols, rows)
                need_chrome = True

            p_mode = st.get("preview_mode", st.get("mode", "bars"))
            p_pal = st.get("preview_palette", st.get("palette", "cyberpunk"))
            p_solid_raw = st.get("preview_solid_rgb")
            p_solid = tuple(p_solid_raw) if isinstance(p_solid_raw, list) and len(p_solid_raw) == 3 else None
            brightness = float(st.get("brightness", 1.0))
            stops = parse_palette_stops(p_pal, theme_stops)

            max_u = 16.5
            unit = min(6.0, max(3.2, (cols - 8) / max_u))
            board_chars = int(round(max_u * unit))
            case_w = board_chars + 4
            case_x = max(2, (cols - case_w) // 2 + 1)
            use_spacers = rows >= 20
            board_rows_h = 14 if use_spacers else 10
            case_h = board_rows_h + 2
            case_y = max(2, 2 + (rows - 3 - case_h) // 2)

            title_spec = f"Solid {rgb_to_hex(p_solid)}" if p_solid is not None else f"{p_mode} · {'custom' if p_pal.startswith('custom:') else p_pal}"
            chrome_sig = (cols, rows, title_spec, p_pal, p_solid)

            buf: list[str] = ["\x1b[?25l\x1b[?2026h"]
            if need_chrome or chrome_sig != last_chrome_sig:
                if need_chrome:
                    buf.append("\x1b[2J")
                buf.append(f"\x1b[1;2H\x1b[1m{c_fg}ATK68 V2  65% Staggered Layout\x1b[0m  {c_muted}·  {title_spec[:max(10, cols - 36)]}\x1b[K")
                # Draw CNC case border & dark deck background ONCE
                buf.append(f"\x1b[{case_y};{case_x}H{fg_rgb(case_frame)}╭" + "─" * (case_w - 2) + "╮\x1b[0m")
                for ro in range(1, case_h - 1):
                    buf.append(f"\x1b[{case_y + ro};{case_x}H{fg_rgb(case_frame)}│{bg_rgb(case_bg)}" + " " * (case_w - 2) + f"\x1b[0m{fg_rgb(case_frame)}│\x1b[0m")
                buf.append(f"\x1b[{case_y + case_h - 1};{case_x}H{fg_rgb(case_frame)}╰" + "─" * (case_w - 2) + "╯\x1b[0m")
                swatch_y = min(rows, case_y + case_h)
                if swatch_y <= rows:
                    sw_stops = [p_solid] if p_solid is not None else stops
                    buf.append(f"\x1b[{swatch_y};{case_x}H{swatch_bar(sw_stops, case_w)}")
                need_chrome = False
                last_chrome_sig = chrome_sig
                last_solid_frame = None

            # Update ONLY the 5 staggered keycap rows in-place (zero screen clear!)
            cava.poll_read()
            key_rgbs = sim.render(p_mode, stops, brightness, cava.bands, dt, p_solid)
            inner_x = case_x + 2
            rows_buf: list[str] = []
            for r_idx in range(5):
                rkeys = ROWS_KEYS[r_idx]
                row_scale = board_chars / rkeys[0]["row_total_u"]
                y_row = case_y + 1 + r_idx * (3 if use_spacers else 2)
                top_parts: list[str] = []
                bot_parts: list[str] = []
                prev_end = 0
                for ki, k in enumerate(rkeys):
                    x0 = prev_end
                    x1 = board_chars if ki == len(rkeys) - 1 else int(round(k["x1_u"] * row_scale))
                    prev_end = x1
                    kw = max(2, x1 - x0)
                    body_w = max(1, kw - 1) if ki < len(rkeys) - 1 else kw
                    led = key_rgbs[k["idx"]]
                    vis = (max(key_off[0], led[0]), max(key_off[1], led[1]), max(key_off[2], led[2]))
                    bevel = (
                        max(case_bg[0], int(vis[0] * 0.52)),
                        max(case_bg[1], int(vis[1] * 0.52)),
                        max(case_bg[2], int(vis[2] * 0.52)),
                    )
                    txt_col = (0x10, 0x10, 0x14) if luma(vis) > 135 else (0xEC, 0xEC, 0xF4)
                    lbl = k["label"][:body_w].center(body_w)
                    gap = f"{bg_rgb(case_bg)} " if ki < len(rkeys) - 1 else ""
                    top_parts.append(f"{bg_rgb(vis)}{fg_rgb(txt_col)}\x1b[1m{lbl}\x1b[0m{gap}")
                    bot_parts.append(f"{bg_rgb(case_bg)}{fg_rgb(bevel)}{'▀' * body_w}{gap}")
                rows_buf.append(f"\x1b[{y_row};{inner_x}H" + "".join(top_parts) + "\x1b[0m")
                rows_buf.append(f"\x1b[{y_row + 1};{inner_x}H" + "".join(bot_parts) + "\x1b[0m")

            key_payload = "".join(rows_buf)
            if p_solid is None or key_payload != last_solid_frame or len(buf) > 1:
                buf.append(key_payload)
                buf.append("\x1b[?2026l")
                try:
                    sys.stdout.write("".join(buf))
                    sys.stdout.flush()
                except BrokenPipeError:
                    break
                if p_solid is not None:
                    last_solid_frame = key_payload

            # If solid static color, sleep quietly on FIFO (0 CPU, 0 redraws) until state changes!
            if p_solid is not None:
                fds = [fifo_fd]
                timeout = 0.5
            else:
                fds = [fifo_fd] + ([cava.fd] if cava.fd is not None else [])
                timeout = max(0.008, frame_interval - (time.monotonic() - now))

            try:
                rlist, _, _ = select.select(fds, [], [], timeout)
            except InterruptedError:
                continue
            if fifo_fd in rlist:
                chunks = []
                while True:
                    try:
                        d = os.read(fifo_fd, 4096)
                        if not d:
                            break
                        chunks.append(d)
                    except BlockingIOError:
                        break
                msg = b"".join(chunks)
                if b"quit" in msg:
                    break
                st = read_state(run_dir)
    finally:
        cava.close()
        try:
            os.close(fifo_fd)
        except OSError:
            pass
        try:
            sys.stdout.write("\x1b[?2026l\x1b[0m\x1b[?25h")
            sys.stdout.flush()
        except Exception:
            pass
    return 0


# ── PANE 3: Event-driven Telemetry, Sliders & Actions (0 idle redraws) ───────
def run_pane_telemetry(run_dir: str) -> int:
    th = load_tmux_theme()
    c_fg = fg_rgb(th["fg"])
    c_muted = fg_rgb(th["muted"])
    c_acc = fg_rgb(th["accent"])

    fifo_path = os.path.join(run_dir, "tele.fifo")
    fifo_fd = os.open(fifo_path, os.O_RDWR | os.O_NONBLOCK)
    running = True
    resized = True

    def _stop(_s: int, _f: object) -> None:
        nonlocal running
        running = False

    def _winch(_s: int, _f: object) -> None:
        nonlocal resized
        resized = True

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGHUP, _stop)
    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGWINCH, _winch)

    last_frame: str | None = None
    try:
        sys.stdout.write("\x1b[?25l\x1b[2J")
        sys.stdout.flush()
        while running and os.path.isdir(run_dir):
            cols, rows = shutil.get_terminal_size((108, 11))
            cols = max(50, cols)
            rows = max(6, rows)
            st = read_state(run_dir)
            d_st = st.get("daemon_status") or {}
            running_daemon = bool(st.get("daemon_running", False))
            brightness = float(st.get("brightness", 1.0))
            sensitivity = int(st.get("sensitivity", 100))
            noise = int(st.get("noise_reduction", 60))
            cava_mode = st.get("cava_mode", "auto")
            eff_cava = d_st.get("effective_cava_mode", cava_mode)
            toast = st.get("toast", "") if time.time() <= float(st.get("toast_until", 0.0)) else ""

            bar_w = max(16, min(32, cols - 40))
            lines = [
                f"\x1b[1m{c_fg}Live Control & Telemetry\x1b[0m  {c_muted}·  Cava DSP: {c_acc}{cava_mode}{c_muted} ({eff_cava})",
                "",
                f"{c_muted}Brightness   {slider_bar(brightness, bar_w, th['accent'], th['surface'])}  \x1b[1m{c_fg}{int(brightness * 100):3d}%\x1b[0m  {c_muted}([ / ])",
                f"{c_muted}Sensitivity  {slider_bar((sensitivity - 10) / 490.0, bar_w, th['accent'], th['surface'])}  \x1b[1m{c_fg}{sensitivity:4d}\x1b[0m  {c_muted}(- / +)",
                f"{c_muted}Smoothing    {slider_bar(noise / 100.0, bar_w, th['accent'], th['surface'])}  \x1b[1m{c_fg}{noise:3d}%\x1b[0m",
                "",
            ]
            dev = "connected" if d_st.get("connected") else ("offline" if running_daemon else "standby")
            aud = "silent" if d_st.get("silent") else ("active" if running_daemon else "preview")
            fps = d_st.get("fps", 35)
            frames = d_st.get("frames_sent", 0)
            usb_ms = d_st.get("avg_usb_ms", 0.0)
            lines.append(
                f"{c_muted}USB HID: {c_fg}{dev}{c_muted} ({usb_ms:.1f}ms)  ·  Audio: {c_fg}{aud}{c_muted}  ·  Stream: {c_fg}{fps} fps · {frames:,}f"
            )
            lines.append(
                f"{c_acc}[Space]\x1b[0m {c_fg}{'Stop' if running_daemon else 'Start'}   "
                f"{c_acc}[x]\x1b[0m {c_fg}Pin   "
                f"{c_acc}[f]\x1b[0m {c_fg}Freeze   "
                f"{c_acc}[#]\x1b[0m {c_fg}Hex   "
                f"{c_acc}[R]\x1b[0m {c_fg}Restore   "
                f"{c_acc}[?]\x1b[0m {c_fg}Keys"
            )
            if toast:
                footer = f"{c_acc}▸ \x1b[1m{c_fg}{toast[:cols - 4]}"
            else:
                footer = f"{c_muted}j/k: move · h/l/Tab: tab/adjust · Enter: apply · n/p: mode/palette · q: quit"[:cols + 20]

            buf = ["\x1b[?25l\x1b[?2026h"]
            for r in range(rows - 1):
                ln = lines[r] if r < len(lines) else ""
                buf.append(f"\x1b[{r + 1};2H{ln}\x1b[0m\x1b[K")
            buf.append(f"\x1b[{rows};2H{footer}\x1b[0m\x1b[K")
            buf.append("\x1b[?2026l")
            frame = "".join(buf)

            if resized or frame != last_frame:
                try:
                    sys.stdout.write(frame)
                    sys.stdout.flush()
                except BrokenPipeError:
                    break
                last_frame = frame
                resized = False

            try:
                rlist, _, _ = select.select([fifo_fd], [], [], 1.0)
            except InterruptedError:
                continue
            if fifo_fd in rlist:
                chunks = []
                while True:
                    try:
                        d = os.read(fifo_fd, 4096)
                        if not d:
                            break
                        chunks.append(d)
                    except BlockingIOError:
                        break
                if b"quit" in b"".join(chunks):
                    break
    finally:
        try:
            os.close(fifo_fd)
        except OSError:
            pass
        try:
            sys.stdout.write("\x1b[?2026l\x1b[0m\x1b[?25h")
            sys.stdout.flush()
        except Exception:
            pass
    return 0


# ── PANE 1: Event-driven Left Control Deck (0 idle redraws, owns atk IPC) ────
class AtkBridge:
    def __init__(self, on_change) -> None:
        self.atk_bin = shutil.which("atk") or os.path.expanduser("~/.local/bin/atk")
        self.on_change = on_change
        self.lock = threading.Lock()
        self.status: dict = {}
        self.daemon_running = False
        self.toast = ""
        self.toast_until = 0.0
        self.cmd_q: queue.Queue[tuple[list[str], str]] = queue.Queue()
        self.stop_ev = threading.Event()
        threading.Thread(target=self._poll_loop, daemon=True).start()
        threading.Thread(target=self._cmd_loop, daemon=True).start()

    def set_toast(self, msg: str, dur: float = 2.6) -> None:
        with self.lock:
            self.toast = msg
            self.toast_until = time.time() + dur
        self.on_change()

    def refresh_now(self) -> None:
        new_running = False
        new_status: dict = {}
        try:
            p = subprocess.run(
                [self.atk_bin, "st", "--json"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=0.8,
            )
            if p.returncode == 0 and p.stdout.strip().startswith("{"):
                data = json.loads(p.stdout)
                if data.get("ok") and isinstance(data.get("status"), dict):
                    new_status = data["status"]
                    new_running = True
        except Exception:
            pass
        changed = False
        with self.lock:
            if new_running != self.daemon_running or new_status != self.status:
                self.daemon_running = new_running
                if new_running:
                    self.status = new_status
                changed = True
        if changed:
            self.on_change()

    def _poll_loop(self) -> None:
        while not self.stop_ev.is_set():
            self.refresh_now()
            self.stop_ev.wait(1.2)

    def send(self, args: list[str], toast_ok: str) -> None:
        self.cmd_q.put((args, toast_ok))

    def _cmd_loop(self) -> None:
        while not self.stop_ev.is_set():
            try:
                args, toast_ok = self.cmd_q.get(timeout=0.2)
            except queue.Empty:
                continue
            while True:
                try:
                    nxt = self.cmd_q.get_nowait()
                    if args and nxt[0] and args[0] == nxt[0][0] and args[0] in ("b", "ctl"):
                        args, toast_ok = nxt
                    else:
                        self._exec_one(args, toast_ok)
                        args, toast_ok = nxt
                except queue.Empty:
                    break
            self._exec_one(args, toast_ok)

    def _exec_one(self, args: list[str], toast_ok: str) -> None:
        try:
            p = subprocess.run(
                [self.atk_bin, *args],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=4.0,
            )
            if p.returncode == 0:
                self.set_toast(toast_ok)
            else:
                err = (p.stderr or p.stdout or "error").strip().splitlines()
                self.set_toast(f"atk err: {err[-1][:48] if err else p.returncode}", 3.5)
        except Exception as e:
            self.set_toast(f"atk err: {str(e)[:48]}", 3.5)
        self.refresh_now()

    def close(self) -> None:
        self.stop_ev.set()


class ControlsPane:
    def __init__(self, run_dir: str, inner_sock: str) -> None:
        self.run_dir = run_dir
        self.inner_sock = inner_sock
        self.self_path = os.path.realpath(__file__)
        self.theme = load_tmux_theme()
        self.theme_stops = [self.theme["muted"], self.theme["fg"], self.theme["accent"]]

        self.ctl_fifo = os.path.join(run_dir, "ctl.fifo")
        self.board_fifo = os.path.join(run_dir, "board.fifo")
        self.tele_fifo = os.path.join(run_dir, "tele.fifo")

        self.tab = 0
        self.cursor = [0, 0, 0, 0]
        self.hex_input: str | None = None

        self.mode = "bars"
        self.palette = "cyberpunk"
        self.cava_mode = "auto"
        self.brightness = 1.0
        self.sensitivity = 100
        self.noise_reduction = 60
        self.solid_rgb: tuple[int, int, int] = (0x00, 0xF0, 0xFF)
        self.preview_solid = False
        self.synced_initial = False
        self.running = True
        self.resized = True

        self.bridge = AtkBridge(on_change=lambda: notify_fifo(self.ctl_fifo, "sync"))
        t0 = time.monotonic()
        while time.monotonic() - t0 < 0.25:
            with self.bridge.lock:
                if self.bridge.status:
                    break
            time.sleep(0.02)
        self._sync_initial()
        self.publish_state()

    def _sync_initial(self) -> None:
        if self.synced_initial:
            return
        with self.bridge.lock:
            st = dict(self.bridge.status)
        if not st:
            return
        self.synced_initial = True
        self.mode = st.get("mode", self.mode)
        self.palette = st.get("palette", self.palette)
        self.cava_mode = st.get("cava_mode", self.cava_mode)
        self.brightness = float(st.get("brightness", self.brightness))
        self.sensitivity = int(st.get("sensitivity", self.sensitivity))
        self.noise_reduction = int(st.get("noise_reduction", self.noise_reduction))
        for i, (m, _, _) in enumerate(MODES):
            if m == self.mode:
                self.cursor[0] = i
                break
        for i, (p, _, _) in enumerate(PALETTES):
            if p == self.palette:
                self.cursor[1] = i
                break

    def _palette_items(self) -> list[tuple[str, str, list[tuple[int, int, int]]]]:
        items = list(PALETTES)
        items.append(("theme", "Sync tmux / Ghostty theme", self.theme_stops))
        custom_spec = f"custom:{rgb_to_hex(self.solid_rgb)},#FFFFFF"
        items.append((custom_spec, f"Custom {rgb_to_hex(self.solid_rgb)}", [self.solid_rgb, (255, 255, 255)]))
        return items

    def _solid_items(self) -> list[tuple[str, str, tuple[int, int, int] | None]]:
        items: list[tuple[str, str, tuple[int, int, int] | None]] = [
            ("slider_r", f"Red   (R): {self.solid_rgb[0]:3d}", None),
            ("slider_g", f"Green (G): {self.solid_rgb[1]:3d}", None),
            ("slider_b", f"Blue  (B): {self.solid_rgb[2]:3d}", None),
        ]
        for name, rgb in SOLID_PRESETS:
            items.append((rgb_to_hex(rgb), name, rgb))
        return items

    def _tuning_items(self) -> list[tuple[str, str]]:
        items = [
            ("brightness", "Brightness"),
            ("sensitivity", "Sensitivity"),
            ("noise", "Noise Red."),
        ]
        for cm, desc in CAVA_MODES:
            items.append((f"cava:{cm}", f"DSP: {cm} · {desc}"))
        return items

    def _tab_len(self, tab: int) -> int:
        if tab == 0:
            return len(MODES)
        if tab == 1:
            return len(self._palette_items())
        if tab == 2:
            return len(self._solid_items())
        return len(self._tuning_items())

    def publish_state(self) -> None:
        p_mode = self.mode
        p_pal = self.palette
        p_solid: tuple[int, int, int] | None = self.solid_rgb if self.preview_solid else None
        if self.tab == 0:
            p_mode = MODES[self.cursor[0] % len(MODES)][0]
            p_solid = None
        elif self.tab == 1:
            pitems = self._palette_items()
            p_pal = pitems[self.cursor[1] % len(pitems)][0]
            p_solid = None
        elif self.tab == 2:
            sitems = self._solid_items()
            sel = sitems[self.cursor[2] % len(sitems)]
            p_solid = sel[2] if sel[2] is not None else self.solid_rgb

        with self.bridge.lock:
            d_st = dict(self.bridge.status)
            d_run = self.bridge.daemon_running
            toast = self.bridge.toast
            toast_until = self.bridge.toast_until

        write_state_atomic(self.run_dir, {
            "mode": self.mode,
            "palette": self.palette,
            "cava_mode": self.cava_mode,
            "brightness": self.brightness,
            "sensitivity": self.sensitivity,
            "noise_reduction": self.noise_reduction,
            "preview_mode": p_mode,
            "preview_palette": p_pal,
            "preview_solid_rgb": list(p_solid) if p_solid is not None else None,
            "daemon_running": d_run,
            "daemon_status": d_st,
            "toast": toast,
            "toast_until": toast_until,
        })
        notify_fifo(self.board_fifo, "update")
        notify_fifo(self.tele_fifo, "update")

    def _apply_palette(self, spec: str) -> None:
        actual = "custom:" + ",".join(rgb_to_hex(c) for c in self.theme_stops) if spec == "theme" else spec
        self.palette = actual
        self.preview_solid = False
        if self.bridge.daemon_running:
            self.bridge.send(["p", actual], f"Palette -> {spec}")
        else:
            short_m = next((s for m, s, _ in MODES if m == self.mode), "bars")
            self.bridge.send([short_m, "-p", actual], f"Started {self.mode} · {spec}")

    def _apply_solid(self, rgb: tuple[int, int, int], as_palette: bool = False) -> None:
        self.solid_rgb = rgb
        hx = rgb_to_hex(rgb)
        if as_palette:
            self._apply_palette(f"custom:{hx}")
        else:
            self.preview_solid = True
            self.bridge.send(["color", hx.lstrip("#"), "-b", f"{self.brightness:.2f}"], f"Pinned solid {hx}")

    def _adjust_brightness(self, delta: float) -> None:
        self.brightness = round(max(0.05, min(1.0, self.brightness + delta)), 2)
        if self.bridge.daemon_running:
            self.bridge.send(["b", f"{self.brightness:.2f}"], f"Brightness -> {int(self.brightness * 100)}%")

    def _adjust_sensitivity(self, delta: int) -> None:
        self.sensitivity = max(10, min(500, self.sensitivity + delta))
        if self.bridge.daemon_running:
            self.bridge.send(["ctl", "sensitivity", str(self.sensitivity)], f"Sensitivity -> {self.sensitivity}")

    def _adjust_noise(self, delta: int) -> None:
        self.noise_reduction = max(0, min(100, self.noise_reduction + delta))
        if self.bridge.daemon_running:
            self.bridge.send(["ctl", "noise-reduction", str(self.noise_reduction)], f"Noise red. -> {self.noise_reduction}")

    def _open_help_popup(self) -> None:
        if not self.inner_sock:
            return
        env = os.environ.copy()
        env.pop("TMUX", None)
        outer_tmux = os.environ.get("TMUX", "")
        cmd = f"TMUX='{outer_tmux}' python3 '{self.self_path}' --help-popup"
        subprocess.run(
            ["tmux", "-L", self.inner_sock, "display-popup", "-E", "-b", "rounded", "-T", " ATK68 V2 Keybindings", "-w", "62", "-h", "19", cmd],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def _activate_current(self) -> None:
        if self.tab == 0:
            full_m, short_m, _ = MODES[self.cursor[0] % len(MODES)]
            self.mode = full_m
            self.preview_solid = False
            self.bridge.send([short_m], f"Mode -> {full_m}")
        elif self.tab == 1:
            pitems = self._palette_items()
            self._apply_palette(pitems[self.cursor[1] % len(pitems)][0])
        elif self.tab == 2:
            sitems = self._solid_items()
            sel = sitems[self.cursor[2] % len(sitems)]
            self._apply_solid(sel[2] if sel[2] is not None else self.solid_rgb, as_palette=False)
        elif self.tab == 3:
            titems = self._tuning_items()
            key_id = titems[self.cursor[3] % len(titems)][0]
            if key_id.startswith("cava:"):
                cm = key_id.split(":", 1)[1]
                self.cava_mode = cm
                if self.bridge.daemon_running:
                    self.bridge.send(["c", cm], f"Cava DSP -> {cm}")
                else:
                    short_m = next((s for m, s, _ in MODES if m == self.mode), "bars")
                    self.bridge.send([short_m, "-c", cm, "-p", self.palette], f"Started {self.mode} · DSP {cm}")

    def handle_key(self, key: str) -> None:
        if self.hex_input is not None:
            if key == "ESC":
                self.hex_input = None
            elif key == "ENTER":
                rgb = hex_to_rgb(self.hex_input)
                if rgb is not None:
                    self._apply_solid(rgb, as_palette=False)
                else:
                    self.bridge.set_toast("Invalid hex (expected 6 hex digits, e.g. FF0080)", 2.5)
                self.hex_input = None
            elif key in ("BS", "\x7f", "\x08"):
                self.hex_input = self.hex_input[:-1]
            elif len(key) == 1 and key in "0123456789abcdefABCDEF#" and len(self.hex_input) < 7:
                if key == "#" and len(self.hex_input) > 0:
                    return
                self.hex_input += key.upper()
            self.publish_state()
            return

        if key in ("q", "ESC", "CTRL_C"):
            self.running = False
            return
        if key == "?":
            self._open_help_popup()
            return
        if key == "#":
            self.hex_input = rgb_to_hex(self.solid_rgb).lstrip("#")
            return
        if key == "TAB":
            self.tab = (self.tab + 1) % len(TABS)
            self.publish_state()
            return
        if key == "BTAB":
            self.tab = (self.tab - 1) % len(TABS)
            self.publish_state()
            return
        if key in ("1", "2", "3", "4"):
            self.tab = int(key) - 1
            self.publish_state()
            return

        n = self._tab_len(self.tab)
        if key in ("j", "DOWN"):
            self.cursor[self.tab] = (self.cursor[self.tab] + 1) % n
            if self.tab == 2:
                sel = self._solid_items()[self.cursor[2]]
                if sel[2] is not None:
                    self.solid_rgb = sel[2]
            self.publish_state()
            return
        if key in ("k", "UP"):
            self.cursor[self.tab] = (self.cursor[self.tab] - 1) % n
            if self.tab == 2:
                sel = self._solid_items()[self.cursor[2]]
                if sel[2] is not None:
                    self.solid_rgb = sel[2]
            self.publish_state()
            return

        if key in ("h", "LEFT", "l", "RIGHT"):
            step = -1 if key in ("h", "LEFT") else 1
            if self.tab == 2 and self.cursor[2] < 3:
                ch = self.cursor[2]
                vals = list(self.solid_rgb)
                vals[ch] = max(0, min(255, vals[ch] + step * 15))
                self.solid_rgb = (vals[0], vals[1], vals[2])
                self.publish_state()
                return
            if self.tab == 3 and self.cursor[3] < 3:
                if self.cursor[3] == 0:
                    self._adjust_brightness(step * 0.05)
                elif self.cursor[3] == 1:
                    self._adjust_sensitivity(step * 10)
                elif self.cursor[3] == 2:
                    self._adjust_noise(step * 5)
                self.publish_state()
                return
            if key in ("l", "RIGHT") and self.tab in (0, 1):
                self._activate_current()
                self.publish_state()
                return
            self.tab = (self.tab + step) % len(TABS)
            self.publish_state()
            return

        if key == "ENTER":
            self._activate_current()
            self.publish_state()
            return

        if key == "[":
            self._adjust_brightness(-0.05)
        elif key == "]":
            self._adjust_brightness(0.05)
        elif key == "-":
            self._adjust_sensitivity(-10)
        elif key in ("+", "="):
            self._adjust_sensitivity(10)
        elif key == " ":
            if self.bridge.daemon_running:
                self.bridge.send(["stop"], "Stopped daemon (pinned palette)")
            else:
                short_m = next((s for m, s, _ in MODES if m == self.mode), "bars")
                self.bridge.send([short_m, "-p", self.palette, "-b", f"{self.brightness:.2f}"], f"Started {self.mode} · {self.palette}")
                self.preview_solid = False
        elif key == "x":
            if self.preview_solid or self.tab == 2:
                self._apply_solid(self.solid_rgb, as_palette=False)
            else:
                self.bridge.send(["pin"], "Pinned active palette to Custom mode")
        elif key == "f":
            self.bridge.send(["pin", "--freeze"], "Froze live SRAM frame to Custom mode")
        elif key == "g" and self.tab == 2:
            self._apply_solid(self.solid_rgb, as_palette=True)
        elif key == "R":
            self.bridge.send(["restore"], "Restored original backup.json")
        elif key == "n":
            self.bridge.send(["next"], "Next visualizer mode")
            idx = (next((i for i, (m, _, _) in enumerate(MODES) if m == self.mode), 0) + 1) % len(MODES)
            self.mode = MODES[idx][0]
            self.cursor[0] = idx
            self.preview_solid = False
        elif key == "p":
            idx = (next((i for i, (p, _, _) in enumerate(PALETTES) if p == self.palette), -1) + 1) % len(PALETTES)
            self.cursor[1] = idx
            self._apply_palette(PALETTES[idx][0])
        self.publish_state()

    def render(self) -> str:
        cols, rows = shutil.get_terminal_size((42, 38))
        cols = max(30, cols)
        rows = max(14, rows)
        lw = cols - 2
        th = self.theme
        c_border = fg_rgb(th["surface"])
        c_fg = fg_rgb(th["fg"])
        c_muted = fg_rgb(th["muted"])
        c_acc = fg_rgb(th["accent"])
        b_surf = bg_rgb(th["surface"])

        lines: list[str] = []
        lines.append(f"\x1b[1m{c_acc}󰌌 ATK68 V2\x1b[0m")
        lines.append(f"{c_border}" + "─" * lw)

        tab_parts = []
        for idx, name in enumerate(TABS):
            if idx == self.tab:
                tab_parts.append(f"{b_surf}\x1b[1m{c_acc} {idx + 1}:{name} \x1b[0m")
            else:
                tab_parts.append(f"{c_muted}{idx + 1}:{name}\x1b[0m")
        lines.append(" ".join(tab_parts))
        lines.append(f"{c_border}" + "─" * lw)

        list_h = max(4, rows - 6)
        cur_idx = self.cursor[self.tab]

        if self.tab == 0:
            for i, (full_m, short_m, desc) in enumerate(MODES[:list_h]):
                is_sel = i == cur_idx
                is_act = full_m == self.mode and not self.preview_solid
                mark = f"{c_acc}●" if is_act else f"{c_muted}·"
                ptr = f"{c_acc}▌" if is_sel else " "
                bg = b_surf if is_sel else ""
                d_budget = max(4, lw - 14)
                lines.append(f"{ptr}{bg} {mark} \x1b[1m{c_fg}{short_m:<9}\x1b[0m{bg}{c_muted}{desc[:d_budget]:<{d_budget}}")
        elif self.tab == 1:
            pitems = self._palette_items()
            for i, (spec, _, stops) in enumerate(pitems[:list_h]):
                is_sel = i == cur_idx
                is_act = (spec == self.palette) or (spec == "theme" and self.palette.startswith("custom:"))
                ptr = f"{c_acc}▌" if is_sel else " "
                bg = b_surf if is_sel else ""
                label = "custom" if spec.startswith("custom:") else spec
                sw = swatch_bar(stops, 10)
                act_ch = f"{c_acc}●" if is_act else " "
                lbl_w = max(8, lw - 16)
                lines.append(f"{ptr}{bg}{act_ch} \x1b[1m{c_fg}{label[:lbl_w]:<{lbl_w}}\x1b[0m{bg} {sw} ")
        elif self.tab == 2:
            sitems = self._solid_items()
            scroll = max(0, cur_idx - list_h + 2) if cur_idx >= list_h - 1 else 0
            for vis_i, item in enumerate(sitems[scroll : scroll + list_h]):
                idx = scroll + vis_i
                is_sel = idx == cur_idx
                ptr = f"{c_acc}▌" if is_sel else " "
                bg = b_surf if is_sel else ""
                key_id, label, rgb = item
                if key_id.startswith("slider_"):
                    ch = 0 if key_id == "slider_r" else (1 if key_id == "slider_g" else 2)
                    bar_col = [(255, 70, 70), (70, 235, 110), (70, 150, 255)][ch]
                    bw = max(8, lw - 18)
                    bar = slider_bar(self.solid_rgb[ch] / 255.0, bw, bar_col, th["surface"])
                    lines.append(f"{ptr}{bg} {c_fg}{label:<13} {bar} ")
                else:
                    assert rgb is not None
                    sw = f"{bg_rgb(rgb)}    \x1b[0m"
                    hx = rgb_to_hex(rgb)
                    nm_w = max(8, lw - 16)
                    lines.append(f"{ptr}{bg} {sw}{bg} {c_fg}{label[:nm_w]:<{nm_w}} {c_muted}{hx} ")
        else:
            titems = self._tuning_items()
            for i, (key_id, label) in enumerate(titems[:list_h]):
                is_sel = i == cur_idx
                ptr = f"{c_acc}▌" if is_sel else " "
                bg = b_surf if is_sel else ""
                if key_id == "brightness":
                    bw = max(8, lw - 20)
                    bar = slider_bar(self.brightness, bw, th["accent"], th["surface"])
                    lines.append(f"{ptr}{bg} {c_fg}Bright  {bar} {c_fg}{int(self.brightness * 100):3d}% ")
                elif key_id == "sensitivity":
                    bw = max(8, lw - 20)
                    bar = slider_bar((self.sensitivity - 10) / 490.0, bw, th["accent"], th["surface"])
                    lines.append(f"{ptr}{bg} {c_fg}Sens    {bar} {c_fg}{self.sensitivity:4d} ")
                elif key_id == "noise":
                    bw = max(8, lw - 20)
                    bar = slider_bar(self.noise_reduction / 100.0, bw, th["accent"], th["surface"])
                    lines.append(f"{ptr}{bg} {c_fg}Smooth  {bar} {c_fg}{self.noise_reduction:3d}% ")
                else:
                    cm = key_id.split(":", 1)[1]
                    mark = f"{c_acc}●" if cm == self.cava_mode else f"{c_muted}·"
                    desc = label.replace("DSP: ", "")
                    d_w = max(8, lw - 5)
                    lines.append(f"{ptr}{bg} {mark} {c_fg}{desc[:d_w]:<{d_w}}")

        if self.hex_input is not None:
            preview_c = hex_to_rgb(self.hex_input) or self.solid_rgb
            sw = f"{bg_rgb(preview_c)}   \x1b[0m"
            bottom_line = f"{c_acc}Hex #:\x1b[0m \x1b[1m{c_fg}#{self.hex_input:<6}\x1b[0m {sw} {c_muted}(Enter)"
        else:
            cur_spec = f"solid {rgb_to_hex(self.solid_rgb)}" if self.preview_solid else f"{self.mode} · {self.palette[:18]}"
            bottom_line = f"{c_muted}Active: {c_fg}{cur_spec[:lw - 8]}"

        buf = ["\x1b[?25l\x1b[?2026h"]
        for r in range(rows - 1):
            ln = lines[r] if r < len(lines) else ""
            buf.append(f"\x1b[{r + 1};2H{ln}\x1b[0m\x1b[K")
        buf.append(f"\x1b[{rows};2H{bottom_line}\x1b[0m\x1b[K")
        buf.append("\x1b[?2026l")
        return "".join(buf)

    def read_key(self, fd: int) -> str | None:
        try:
            b = os.read(fd, 1)
        except OSError:
            return None
        if not b:
            return None
        ch = b.decode("utf-8", errors="ignore")
        if ch == "\x03":
            return "CTRL_C"
        if ch in ("\r", "\n"):
            return "ENTER"
        if ch == "\t":
            return "TAB"
        if ch in ("\x7f", "\x08"):
            return "BS"
        if ch == "\x1b":
            r, _, _ = select.select([fd], [], [], 0.02)
            if not r:
                return "ESC"
            seq = os.read(fd, 8).decode("utf-8", errors="ignore")
            if seq.startswith("[A"):
                return "UP"
            if seq.startswith("[B"):
                return "DOWN"
            if seq.startswith("[C"):
                return "RIGHT"
            if seq.startswith("[D"):
                return "LEFT"
            if seq.startswith("[Z"):
                return "BTAB"
            return "ESC"
        return ch

    def run(self) -> int:
        stdin_fd = sys.stdin.fileno()
        old_tty = None
        if os.isatty(stdin_fd):
            old_tty = termios.tcgetattr(stdin_fd)
            tty.setraw(stdin_fd)

        ctl_fd = os.open(self.ctl_fifo, os.O_RDWR | os.O_NONBLOCK)

        def _stop(_s: int, _f: object) -> None:
            self.running = False

        def _winch(_s: int, _f: object) -> None:
            self.resized = True

        signal.signal(signal.SIGTERM, _stop)
        signal.signal(signal.SIGHUP, _stop)
        signal.signal(signal.SIGINT, _stop)
        signal.signal(signal.SIGWINCH, _winch)

        last_frame: str | None = None
        try:
            sys.stdout.write("\x1b[?25l\x1b[2J")
            sys.stdout.flush()
            while self.running and os.path.isdir(self.run_dir):
                self._sync_initial()
                frame = self.render()
                if self.resized or frame != last_frame:
                    try:
                        sys.stdout.write(frame)
                        sys.stdout.flush()
                    except BrokenPipeError:
                        break
                    last_frame = frame
                    self.resized = False

                try:
                    rlist, _, _ = select.select([stdin_fd, ctl_fd], [], [], 0.5)
                except InterruptedError:
                    continue
                if ctl_fd in rlist:
                    while True:
                        try:
                            d = os.read(ctl_fd, 4096)
                            if not d:
                                break
                        except BlockingIOError:
                            break
                    self.publish_state()
                if stdin_fd in rlist:
                    key = self.read_key(stdin_fd)
                    if key is not None:
                        self.handle_key(key)
        finally:
            self.bridge.close()
            try:
                os.close(ctl_fd)
            except OSError:
                pass
            notify_fifo(self.board_fifo, "quit")
            notify_fifo(self.tele_fifo, "quit")
            if old_tty is not None:
                try:
                    termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old_tty)
                except Exception:
                    pass
            try:
                sys.stdout.write("\x1b[?2026l\x1b[0m\x1b[?25h")
                sys.stdout.flush()
            except Exception:
                pass
            if self.inner_sock:
                env = os.environ.copy()
                env.pop("TMUX", None)
                subprocess.run(
                    ["tmux", "-L", self.inner_sock, "kill-server"],
                    env=env,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
        return 0


def run_help_popup() -> int:
    th = load_tmux_theme()
    c_fg = fg_rgb(th["fg"])
    c_acc = fg_rgb(th["accent"])
    c_muted = fg_rgb(th["muted"])
    lines = [
        f"  \x1b[1m{c_acc}j / k, Up / Down\x1b[0m      {c_fg}Move cursor",
        f"  \x1b[1m{c_acc}h / l, Left / Right\x1b[0m   {c_fg}Switch tab or adjust slider",
        f"  \x1b[1m{c_acc}Tab / 1-4\x1b[0m             {c_fg}Switch control tab",
        f"  \x1b[1m{c_acc}Enter\x1b[0m                 {c_fg}Apply mode / palette / solid color",
        f"  \x1b[1m{c_acc}n / p\x1b[0m                 {c_fg}Cycle visualizer mode / palette",
        f"  \x1b[1m{c_acc}[ / ]  and  - / +\x1b[0m     {c_fg}Adjust brightness / sensitivity",
        f"  \x1b[1m{c_acc}#\x1b[0m                     {c_fg}Enter custom #RRGGBB hex color",
        f"  \x1b[1m{c_acc}g (Solid tab)\x1b[0m         {c_fg}Use solid color as reactive palette",
        f"  \x1b[1m{c_acc}Space\x1b[0m                 {c_fg}Start / Stop live audio daemon",
        f"  \x1b[1m{c_acc}x / f\x1b[0m                 {c_fg}Pin palette / Freeze live SRAM frame",
        f"  \x1b[1m{c_acc}R\x1b[0m                     {c_fg}Restore original backup.json",
        f"  \x1b[1m{c_acc}? / q / Esc\x1b[0m           {c_fg}Close help / Quit studio",
        "",
        f"  {c_muted}Press any key to close...",
    ]
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd) if os.isatty(fd) else None
    try:
        if old is not None:
            tty.setraw(fd)
        sys.stdout.write("\x1b[?25l\x1b[2J\x1b[H\n" + "\n".join(lines) + "\x1b[0m")
        sys.stdout.flush()
        os.read(fd, 8)
    finally:
        if old is not None:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)
        sys.stdout.write("\x1b[?25h")
        sys.stdout.flush()
    return 0


def main() -> int:
    args = sys.argv[1:]
    if len(args) >= 3 and args[0] == "--pane-controls":
        return ControlsPane(args[1], args[2]).run()
    if len(args) >= 2 and args[0] == "--pane-board":
        return run_pane_board(args[1])
    if len(args) >= 2 and args[0] == "--pane-telemetry":
        return run_pane_telemetry(args[1])
    if args and args[0] == "--help-popup":
        return run_help_popup()
    sys.stderr.write("Usage: tmux-atk.py --pane-controls|--pane-board|--pane-telemetry|--help-popup\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
