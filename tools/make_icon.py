#!/usr/bin/env python3
"""Вариант Б: узнаваемая птица (ласточка) в полёте — вид сверху."""
import sys
from PIL import Image, ImageDraw

S = 1024
SS = 4
W = S * SS
img = Image.new("RGB", (W, W), (0, 0, 0))
px = img.load()
top = (18, 36, 86)
bot = (50, 130, 205)
for y in range(W):
    t = y / W
    row = (int(top[0] + (bot[0] - top[0]) * t),
           int(top[1] + (bot[1] - top[1]) * t),
           int(top[2] + (bot[2] - top[2]) * t))
    for x in range(W):
        px[x, y] = row

d = ImageDraw.Draw(img, "RGBA")
white = (255, 255, 255, 255)
cx, cy = W * 0.5, W * 0.5


def bezier(p, n=80):
    out = []
    for i in range(n + 1):
        t = i / n
        mt = 1 - t
        x = (mt**3 * p[0][0] + 3 * mt**2 * t * p[1][0]
             + 3 * mt * t**2 * p[2][0] + t**3 * p[3][0])
        y = (mt**3 * p[0][1] + 3 * mt**2 * t * p[1][1]
             + 3 * mt * t**2 * p[2][1] + t**3 * p[3][1])
        out.append((x, y))
    return out


def U(dx, dy):
    return (cx + dx * W, cy + dy * W)


def half(mirror=False):
    s = -1 if mirror else 1
    # верхняя кромка крыла: от головы к кончику крыла
    top_edge = bezier([
        U(s * 0.02, -0.085),    # у головы (верх тела)
        U(s * 0.14, -0.20),
        U(s * 0.30, -0.235),
        U(s * 0.43, -0.135),    # острый кончик крыла
    ])
    # нижняя кромка крыла: от кончика к хвосту
    bot_edge = bezier([
        U(s * 0.43, -0.135),
        U(s * 0.26, -0.085),
        U(s * 0.14, -0.045),
        U(s * 0.055, 0.085),    # переход к хвосту
    ])
    # хвост (раздвоенный) к центру
    tail = bezier([
        U(s * 0.055, 0.085),
        U(s * 0.045, 0.16),
        U(s * 0.02, 0.20),
        U(0, 0.165),            # центр выреза хвоста
    ])
    return top_edge + bot_edge + tail


poly = half(False) + list(reversed(half(True)))
d.polygon(poly, fill=white)

# голова — небольшой круг сверху по центру
hr = W * 0.052
d.ellipse([cx - hr, cy - 0.115 * W - hr, cx + hr, cy - 0.115 * W + hr], fill=white)

out = img.resize((S, S), Image.LANCZOS)
dest = sys.argv[1] if len(sys.argv) > 1 else "tools/icon-b.png"
out.save(dest)
print("saved", dest)
