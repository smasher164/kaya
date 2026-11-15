#!/usr/bin/env python3
"""The commonest colour and the glyph colour (the pixel farthest from it) in a
box of a screencap PNG, and their WCAG contrast. usage: pixels.py <png> l t r b"""
import struct, sys, zlib
from collections import Counter


def png_rgb(path):
    data = open(path, "rb").read()
    pos, chunks, w = 8, [], 0
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
            assert depth == 8 and ctype in (2, 6), (depth, ctype)
            bpp = 4 if ctype == 6 else 3
        elif kind == b"IDAT":
            chunks.append(body)
        pos += 12 + n
    raw, stride, rows, prev = zlib.decompress(b"".join(chunks)), w * bpp, [], bytearray(w * bpp)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], prev[i - bpp] if i >= bpp else 0
            line[i] = (line[i] + (0, a, b, (a + b) // 2, (a if abs(b - c) <= abs(a - c) and abs(a + b - 2 * c) >= abs(a - c) else 0))[f]) & 0xFF if f != 4 else (line[i] + paeth(a, b, c)) & 0xFF
        rows.append([tuple(line[x * bpp:x * bpp + 3]) for x in range(w)])
        prev = line
    return rows


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)


def lum(rgb):
    def ch(v):
        v /= 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = map(ch, rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


rows = png_rgb(sys.argv[1])
l, t, r, b = map(int, sys.argv[2:6])
px = [rows[y][x] for y in range(t, b) for x in range(l, r)]
ground = Counter(px).most_common(1)[0][0]
glyph = max(px, key=lambda p: sum((p[i] - ground[i]) ** 2 for i in range(3)))
hexs = lambda p: "%02X%02X%02X" % p
print(f"ground {hexs(ground)}  glyph {hexs(glyph)}  contrast {contrast(ground, glyph):.2f}:1")
