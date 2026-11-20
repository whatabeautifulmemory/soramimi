#!/usr/bin/env python3
"""
Reproducible pixel-art icon generator for Soramimi.

Style: 128x128 pixel grid, palette and club-stage motifs sampled from the user's
reference image (pixel-art jazz singer: aubergine/navy walls, royal-blue dress,
ivory spotlight, warm hanging bulbs, muted wood, cream floor).

Outputs (design/icons/):
  appicon-mic-1024.png          rounded-square app icon, vintage microphone
  appicon-gramophone-1024.png   rounded-square app icon, gramophone
  appicon-singer-1024.png       rounded-square app icon, singer at the microphone
  menubar-mic-18.png / -36.png         monochrome template status-bar icon
  menubar-gramophone-18.png / -36.png  monochrome template status-bar icon
  preview-app-icons.png         contact sheet

Run:
  python3 design/generate-icons.py
"""

from pathlib import Path

from PIL import Image, ImageDraw

GRID = 128
SCALE = 8  # 128 -> 1024
OUT = Path(__file__).resolve().parent / "icons"
OUT.mkdir(parents=True, exist_ok=True)

# Palette sampled/derived from the reference image.
INK       = (0x11, 0x07, 0x1c)
INK2      = (0x1c, 0x0c, 0x28)
INK3      = (0x26, 0x15, 0x36)
NAVY      = (0x1e, 0x29, 0x56)
NAVY2     = (0x23, 0x30, 0x61)
BLUE_D    = (0x2c, 0x52, 0x8a)
BLUE      = (0x2d, 0x62, 0x9e)
BLUE_M    = (0x4a, 0x7a, 0xb0)
BLUE_L    = (0x6e, 0x87, 0xa3)
BLUE_PALE = (0xbc, 0xd6, 0xd4)
CREAM     = (0xf7, 0xe2, 0xc1)
CREAM_L   = (0xf3, 0xf4, 0xdf)
WARM      = (0xff, 0xea, 0xc6)
WARM_M    = (0xf2, 0xc2, 0x8e)
WARM_D    = (0xc9, 0x8b, 0x63)
WOOD      = (0x6b, 0x3b, 0x39)
WOOD_L    = (0x9e, 0x5b, 0x58)
WOOD_D    = (0x3a, 0x1f, 0x2a)
SILVER    = (0xc8, 0xcf, 0xcf)
SILVER_D  = (0x7d, 0x8c, 0x99)


class Canvas:
    def __init__(self):
        self.img = Image.new("RGB", (GRID, GRID), INK2)
        self.p = self.img.load()

    def put(self, x, y, c):
        if 0 <= x < GRID and 0 <= y < GRID:
            self.p[int(x), int(y)] = c

    def rect(self, x0, y0, x1, y1, c):
        for y in range(max(0, y0), min(GRID - 1, y1) + 1):
            for x in range(max(0, x0), min(GRID - 1, x1) + 1):
                self.p[x, y] = c

    def hline(self, x0, x1, y, c):
        self.rect(x0, y, x1, y, c)

    def vline(self, x, y0, y1, c):
        self.rect(x, y0, x, y1, c)

    def dither(self, x0, y0, x1, y1, c, step=2, offset=0):
        for y in range(max(0, y0), min(GRID - 1, y1) + 1):
            for x in range(max(0, x0), min(GRID - 1, x1) + 1):
                if (x + y + offset) % step == 0:
                    self.p[x, y] = c

    def disc(self, cx, cy, r, c):
        for y in range(cy - r, cy + r + 1):
            for x in range(cx - r, cx + r + 1):
                if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                    self.put(x, y, c)

    def ellipse(self, cx, cy, rx, ry, c):
        for y in range(cy - ry, cy + ry + 1):
            for x in range(cx - rx, cx + rx + 1):
                if ((x - cx) / max(rx, 1)) ** 2 + ((y - cy) / max(ry, 1)) ** 2 <= 1:
                    self.put(x, y, c)

    def ring(self, cx, cy, r, c):
        for y in range(cy - r - 1, cy + r + 2):
            for x in range(cx - r - 1, cx + r + 2):
                d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
                if r - 0.6 <= d <= r + 0.4:
                    self.put(x, y, c)

    def rounded_rect(self, x0, y0, x1, y1, r, c):
        for y in range(max(0, y0), min(GRID - 1, y1) + 1):
            for x in range(max(0, x0), min(GRID - 1, x1) + 1):
                if r > 0:
                    cx = min(max(x, x0 + r), x1 - r)
                    cy = min(max(y, y0 + r), y1 - r)
                    if (x - cx) ** 2 + (y - cy) ** 2 > r * r:
                        continue
                self.p[x, y] = c

    def line(self, x0, y0, x1, y1, c, thick=1):
        dx = abs(x1 - x0)
        dy = -abs(y1 - y0)
        sx = 1 if x0 < x1 else -1
        sy = 1 if y0 < y1 else -1
        err = dx + dy
        while True:
            for ox in range(thick):
                for oy in range(thick):
                    self.put(x0 + ox, y0 + oy, c)
            if x0 == x1 and y0 == y1:
                break
            e2 = 2 * err
            if e2 >= dy:
                err += dy
                x0 += sx
            if e2 <= dx:
                err += dx
                y0 += sy


def rounded_mask():
    mask = Image.new("L", (GRID, GRID), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, GRID - 1, GRID - 1), radius=24, fill=255)
    return mask


def save_app_icon(canvas, name):
    img = canvas.img.convert("RGBA")
    img.putalpha(rounded_mask())
    big = img.resize((GRID * SCALE, GRID * SCALE), Image.Resampling.NEAREST)
    big.save(OUT / f"{name}-1024.png")
    return big


# --------------------------------------------------------------------------
# Stage
# --------------------------------------------------------------------------
def draw_stage(c):
    c.rect(0, 0, GRID - 1, GRID - 1, INK2)
    # wallpaper: dark upper band and sparse vertical ribs
    c.rect(0, 0, GRID - 1, 16, INK3)
    for x in range(4, GRID, 9):
        c.vline(x, 17, 99, NAVY)
    c.dither(0, 17, GRID - 1, 99, INK3, 8, 1)
    # cream floor
    c.rect(0, 101, GRID - 1, GRID - 1, CREAM)
    c.rect(0, 101, GRID - 1, 104, CREAM_L)
    c.rect(0, 117, GRID - 1, GRID - 1, WARM)
    for y in (108, 113, 119, 124):
        c.hline(0, GRID - 1, y, WARM_M if y < 118 else CREAM_L)
    c.rect(0, 126, GRID - 1, GRID - 1, CREAM)
    # spotlight cone (solid, stepped edges, warm core)
    for y in range(0, 121):
        half = 7.0 + y * 0.42
        cx = 64
        for x in range(0, GRID):
            dx = abs(x - cx)
            if dx > half:
                continue
            if dx > half - 2 and (x + y) % 2 == 0:
                continue
            if dx <= half * 0.30:
                col = WARM
            elif dx <= half * 0.55:
                col = CREAM_L
            else:
                col = CREAM
            c.put(x, y, col)
    # dither the hard cone edge into the wall
    for y in range(0, 121):
        half = 7.0 + y * 0.42
        for x in (int(64 - half) - 1, int(64 + half) + 1):
            if 0 <= x < GRID and (x + y) % 3 == 0:
                c.put(x, y, CREAM)
    # dappled light on the floor
    c.dither(30, 106, 98, 124, CREAM_L, 3, 0)


def draw_lamps(c):
    for cx, cy, drop in ((15, 15, 0), (113, 18, 4), (64, 9, 0)):
        c.vline(cx, drop, cy - 4, WOOD_D)
        c.rect(cx - 1, cy - 4, cx + 1, cy - 3, WOOD_L)
        c.disc(cx, cy, 3, WARM_D)
        c.disc(cx, cy, 2, WARM)
        c.put(cx, cy, CREAM_L)
        c.dither(cx - 6, cy - 6, cx + 6, cy + 6, WARM_M, 4, 0)
        c.put(cx - 2, cy - 1, CREAM_L)
        c.put(cx + 1, cy + 1, WARM_M)


def draw_notes(c, x, y, scale=1):
    for dx, dy in ((0, 0), (11, -7)) if scale == 1 else ((0, 0),):
        c.rect(x + dx + 1, y + dy + 1, x + dx + 2, y + dy + 8, CREAM_L)
        c.rect(x + dx + 3, y + dy, x + dx + 4, y + dy + 3, CREAM_L)
        c.disc(x + dx, y + dy + 9, 2, CREAM_L)
        c.put(x + dx - 1, y + dy + 7, WARM_M)
        c.put(x + dx + 3, y + dy - 1, WARM)


def draw_floor_shadow(c, cx, cy, rx, ry):
    c.ellipse(cx, cy, rx, ry, WARM_M)
    c.dither(cx - rx, cy - ry, cx + rx, cy + ry, WARM_D, 3, 0)


# --------------------------------------------------------------------------
# A: vintage microphone
# --------------------------------------------------------------------------
def draw_mic_icon():
    c = Canvas()
    draw_stage(c)
    draw_lamps(c)
    draw_floor_shadow(c, 64, 112, 26, 4)

    # capsule head, vintage chrome grille
    c.rounded_rect(44, 28, 84, 62, 12, INK)
    c.rounded_rect(46, 30, 82, 60, 11, SILVER_D)
    c.rounded_rect(48, 32, 80, 58, 10, SILVER)
    c.rounded_rect(50, 34, 78, 56, 8, CREAM_L)
    for y in range(36, 56, 3):
        c.hline(51, 77, y, SILVER_D)
    c.rounded_rect(50, 34, 55, 56, 3, CREAM_L)       # left highlight
    c.rounded_rect(75, 34, 78, 56, 3, WARM_M)        # warm rim light
    c.hline(53, 75, 35, CREAM)
    c.hline(53, 75, 55, SILVER_D)
    c.put(64, 31, CREAM_L)

    # yoke + connector
    c.rect(58, 62, 70, 68, INK)
    c.rect(59, 62, 69, 67, SILVER_D)
    c.rect(60, 63, 68, 65, BLUE_L)
    c.rect(60, 68, 68, 74, INK)
    c.rect(61, 68, 67, 73, NAVY2)
    c.rect(62, 69, 66, 71, BLUE_L)
    # stand
    c.rect(61, 74, 67, 108, INK)
    c.rect(62, 75, 66, 107, SILVER_D)
    c.vline(63, 76, 106, CREAM_L)
    c.vline(65, 76, 106, SILVER)
    c.vline(66, 76, 106, BLUE_L)
    # tripod base
    c.ellipse(64, 111, 26, 4, INK)
    c.ellipse(64, 110, 24, 3, NAVY2)
    c.rect(44, 107, 84, 109, INK)
    c.rect(46, 106, 82, 108, NAVY2)
    c.hline(52, 76, 106, BLUE_L)
    c.line(48, 109, 40, 113, SILVER_D)
    c.line(80, 109, 88, 113, SILVER_D)
    c.rect(38, 113, 46, 115, INK)
    c.rect(82, 113, 90, 115, INK)
    # a couple of pixel notes and a warm glint
    draw_notes(c, 96, 66)
    c.put(90, 46, WARM)
    return save_app_icon(c, "appicon-mic")


# --------------------------------------------------------------------------
# B: gramophone
# --------------------------------------------------------------------------
def draw_gramophone_icon():
    c = Canvas()
    draw_stage(c)
    draw_lamps(c)
    draw_floor_shadow(c, 66, 114, 34, 4)

    # cabinet
    c.rect(24, 86, 104, 106, INK)
    c.rect(26, 87, 102, 104, WOOD)
    c.rect(26, 87, 102, 90, WOOD_L)
    c.rect(28, 91, 100, 103, WOOD)
    c.dither(30, 92, 98, 102, WOOD_D, 4, 0)
    c.rect(26, 104, 102, 106, WOOD_D)
    c.rect(30, 106, 36, 118, INK)
    c.rect(31, 106, 35, 117, WOOD_D)
    c.rect(92, 106, 98, 118, INK)
    c.rect(93, 106, 97, 117, WOOD_D)
    # turntable platter
    c.ellipse(50, 86, 20, 6, INK)
    c.ellipse(50, 85, 19, 5, NAVY)
    c.ellipse(50, 85, 16, 4, INK2)
    c.ellipse(50, 85, 9, 2, NAVY2)
    c.disc(50, 85, 1, CREAM_L)
    c.ellipse(50, 84, 19, 5, WOOD_L)
    c.ellipse(50, 84, 17, 4, NAVY)
    for r in (5, 9, 13):
        c.ellipse(50, 84, r + 4, max(1, r // 3), NAVY2)
    # tonearm
    c.line(62, 82, 74, 70, SILVER_D, 2)
    c.disc(62, 82, 2, SILVER)
    c.disc(74, 70, 2, CREAM_L)
    # horn neck
    c.line(80, 82, 86, 66, INK, 5)
    c.line(81, 82, 87, 67, WOOD_L, 3)
    c.line(82, 80, 88, 68, CREAM, 1)
    # horn bell: cream trumpet with radial ridges and a dark mouth
    import math
    cx, cy = 92, 52
    c.disc(cx, cy, 27, INK)
    c.disc(cx, cy, 26, CREAM_L)
    c.disc(cx, cy, 24, CREAM)
    # radial ridges (drawn before the mouth so they stay visible)
    for index, angle in enumerate(range(0, 360, 18)):
        rad = math.radians(angle)
        x0 = cx + int(math.cos(rad) * 10)
        y0 = cy + int(math.sin(rad) * 10)
        x1 = cx + int(math.cos(rad) * 23)
        y1 = cy + int(math.sin(rad) * 23)
        c.line(x0, y0, x1, y1, BLUE_L if index % 2 else WARM_D)
    c.disc(cx, cy, 10, WARM_M)
    c.disc(cx, cy, 8, WARM_D)
    # dark mouth, slightly offset as if the horn faces a little to the right
    c.ellipse(cx + 2, cy + 2, 8, 10, INK)
    c.ellipse(cx + 2, cy + 2, 6, 8, NAVY)
    c.put(cx + 1, cy - 1, WARM_D)
    # thin rim + highlight (rings, do not fill over the ridges)
    c.ring(cx, cy, 24, CREAM_L)
    c.ring(cx, cy, 25, WARM)
    c.ring(cx, cy, 26, WARM_D)
    c.line(cx - 14, cy - 19, cx - 4, cy - 24, CREAM_L)
    c.line(cx - 20, cy - 11, cx - 12, cy - 22, CREAM_L)
    c.dither(cx + 8, cy + 10, cx + 24, cy + 25, WARM_D, 3, 0)
    c.dither(cx - 23, cy + 10, cx - 4, cy + 25, BLUE_L, 4, 0)
    # notes
    draw_notes(c, 20, 58)
    return save_app_icon(c, "appicon-gramophone")


# --------------------------------------------------------------------------
# C: singer at the microphone
# --------------------------------------------------------------------------
def draw_singer_icon():
    c = Canvas()
    draw_stage(c)
    draw_lamps(c)
    draw_floor_shadow(c, 64, 114, 30, 4)

    # legs + shoes
    c.rect(55, 100, 60, 112, INK)
    c.rect(56, 100, 59, 111, CREAM)
    c.rect(68, 100, 73, 112, INK)
    c.rect(69, 100, 72, 111, CREAM)
    c.rect(52, 112, 61, 115, INK)
    c.rect(53, 111, 60, 113, CREAM_L)
    c.rect(67, 112, 76, 115, INK)
    c.rect(68, 111, 75, 113, CREAM_L)

    # skirt: trapezoid with vertical folds
    for i, y in enumerate(range(80, 106)):
        half = 11 + int(i * 0.60)
        c.rect(64 - half, y, 64 + half, y, INK)
        c.rect(65 - half, y, 63 + half, y, BLUE_D if i % 5 else BLUE)
    for x in (46, 53, 60, 68, 75, 82):
        c.line(x, 82, x - 5, 104, NAVY2)
    c.dither(46, 88, 82, 104, BLUE, 4, 0)
    c.hline(42, 86, 104, WARM_M)
    c.hline(43, 85, 105, BLUE_D)

    # bodice
    c.rect(52, 60, 76, 84, INK)
    c.rect(53, 61, 75, 82, BLUE)
    c.rect(55, 62, 73, 80, BLUE_M)
    c.rect(53, 61, 56, 82, BLUE_D)
    c.rect(70, 61, 75, 82, BLUE_D)
    c.dither(58, 66, 70, 80, BLUE, 4, 0)
    c.rect(52, 80, 76, 83, NAVY2)
    c.rect(63, 80, 65, 83, CREAM_L)
    # neckline
    c.hline(58, 70, 61, CREAM)
    c.hline(60, 68, 62, CREAM)
    c.put(64, 63, CREAM_L)

    # arms
    c.rect(47, 62, 52, 70, INK)
    c.rect(48, 62, 51, 69, BLUE_M)
    c.rect(38, 68, 49, 76, INK)
    c.rect(39, 68, 48, 74, BLUE_M)
    c.rect(36, 72, 41, 77, INK)
    c.rect(37, 73, 40, 76, CREAM)
    c.rect(76, 62, 81, 75, INK)
    c.rect(77, 62, 80, 74, BLUE_M)
    c.rect(78, 75, 83, 83, INK)
    c.rect(79, 75, 82, 82, BLUE)
    c.rect(78, 82, 83, 86, INK)
    c.rect(79, 82, 82, 85, CREAM)

    # neck + face
    c.rect(59, 52, 69, 62, INK)
    c.rect(60, 52, 68, 61, CREAM)
    c.rect(55, 41, 73, 57, INK)
    c.rect(56, 41, 72, 56, CREAM)
    # hair
    c.rect(51, 40, 56, 60, INK)
    c.rect(52, 40, 55, 59, WOOD)
    c.rect(72, 40, 77, 60, INK)
    c.rect(73, 40, 76, 59, WOOD)
    c.rect(56, 38, 72, 43, INK)
    c.rect(56, 39, 72, 42, WOOD)
    c.dither(56, 39, 71, 42, WOOD_L, 3, 0)
    c.put(52, 58, WOOD_L)
    c.put(75, 58, WOOD_L)
    # eyes / brows / mouth / blush
    c.rect(58, 47, 60, 51, INK)
    c.rect(59, 48, 60, 50, BLUE_D)
    c.put(59, 49, CREAM_L)
    c.rect(67, 47, 69, 51, INK)
    c.rect(67, 48, 68, 50, BLUE_D)
    c.put(68, 49, CREAM_L)
    c.hline(57, 60, 45, WOOD_D)
    c.hline(66, 69, 45, WOOD_D)
    c.hline(61, 66, 54, WOOD_L)
    c.put(60, 54, WARM_M)
    c.put(68, 53, WARM_M)
    # hat: wide curved brim + short rounded crown
    c.ellipse(64, 39, 27, 7, INK)
    c.ellipse(64, 38, 25, 5, BLUE)
    c.ellipse(64, 37, 25, 4, BLUE_D)
    c.hline(41, 87, 36, BLUE_M)
    c.rounded_rect(48, 22, 80, 36, 6, INK)
    c.rounded_rect(49, 23, 79, 35, 5, BLUE_D)
    c.rounded_rect(52, 24, 76, 30, 4, BLUE)
    c.rect(50, 32, 78, 34, NAVY2)
    c.hline(53, 75, 31, BLUE_M)
    c.vline(51, 24, 31, BLUE_M)
    # feather / flower
    c.rect(74, 24, 78, 33, CREAM_L)
    c.rect(76, 21, 81, 28, BLUE_PALE)
    c.put(78, 20, CREAM)
    c.put(80, 25, BLUE_M)
    # warm rim light on hat + dress
    c.vline(81, 34, 39, WARM_M)
    c.rect(73, 63, 75, 80, WARM_M)
    c.dither(70, 90, 80, 102, WARM_M, 5, 0)

    # microphone stand (in front, left)
    c.rect(29, 62, 36, 108, INK)
    c.rect(31, 63, 34, 107, SILVER_D)
    c.vline(32, 64, 106, SILVER)
    c.vline(33, 64, 106, CREAM_L)
    c.ellipse(32, 109, 9, 3, INK)
    c.ellipse(32, 108, 8, 2, NAVY2)
    c.rect(28, 107, 36, 109, NAVY2)
    c.hline(29, 35, 106, BLUE_L)
    # mic capsule
    c.rounded_rect(24, 49, 42, 65, 5, INK)
    c.rounded_rect(25, 50, 41, 64, 4, SILVER_D)
    c.rounded_rect(26, 51, 40, 63, 3, SILVER)
    for y in range(53, 63, 2):
        c.hline(27, 39, y, SILVER_D)
    c.vline(28, 52, 62, CREAM_L)
    c.hline(25, 41, 50, CREAM_L)
    c.hline(26, 40, 66, WARM_M)
    draw_notes(c, 12, 34)
    return save_app_icon(c, "appicon-singer")


# --------------------------------------------------------------------------
# Menu bar template icons (black + alpha, 18 px logical)
# --------------------------------------------------------------------------
def save_template(rows, name):
    h = len(rows)
    w = len(rows[0])
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    p = img.load()
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch == "#":
                p[x, y] = (0, 0, 0, 255)
    for factor in (1, 2):
        img.resize((w * factor, h * factor), Image.Resampling.NEAREST).save(
            OUT / f"{name}-{w * factor}.png")


def menubar_mic():
    return [
        "..................",
        "......######......",
        ".....########.....",
        ".....########.....",
        ".....########.....",
        ".....########.....",
        "......######......",
        ".......####.......",
        "........##........",
        "........##........",
        "........##........",
        "........##........",
        "........##........",
        ".....########.....",
        "....##########....",
        "....############..",
        "..................",
        "..................",
    ]


def menubar_gramophone():
    return [
        "..................",
        "...........####...",
        "..........######..",
        ".........########.",
        ".........########.",
        "........########..",
        "........#######...",
        ".........#####....",
        "..........###.....",
        "....##....##......",
        "....##....##......",
        "....############..",
        "....############..",
        "....##........##..",
        "....##........##..",
        "..................",
        "..................",
        "..................",
    ]


# --------------------------------------------------------------------------
def main():
    mic = draw_mic_icon()
    gram = draw_gramophone_icon()
    singer = draw_singer_icon()

    save_template(menubar_mic(), "menubar-mic")
    save_template(menubar_gramophone(), "menubar-gramophone")

    pad = 48
    sheet = Image.new("RGB", (3 * 512 + 4 * pad, 512 + 2 * pad), (0xef, 0xea, 0xe1))
    for i, img in enumerate((mic, gram, singer)):
        tile = img.resize((512, 512), Image.Resampling.LANCZOS)
        sheet.paste(tile, (pad + i * (512 + pad), pad), tile)
    sheet.save(OUT / "preview-app-icons.png")

    # menu-bar preview on dark and light backgrounds
    bar = Image.new("RGB", (2 * 560, 2 * 90), (0x1c, 0x1c, 0x1c))
    dark = Image.new("RGB", (560, 90), (0x1c, 0x1c, 0x1c))
    light = Image.new("RGB", (560, 90), (0xf2, 0xf2, 0xf2))
    for bg, icon in ((dark, "menubar-mic-18.png"), (dark, "menubar-gramophone-18.png"),
                     (light, "menubar-mic-18.png"), (light, "menubar-gramophone-18.png")):
        tile = Image.open(OUT / icon).convert("RGBA")
        tile = tile.resize((tile.width * 8, tile.height * 8), Image.Resampling.NEAREST)
        if bg is dark:
            bg.paste(tile, (120 if "mic" in icon else 340, 9), tile)
        else:
            bg.paste(tile, (120 if "mic" in icon else 340, 9), tile)
    bar.paste(dark, (0, 0))
    bar.paste(light, (0, 90))
    bar.save(OUT / "preview-menubar.png")
    print("wrote icons to", OUT)


if __name__ == "__main__":
    main()
