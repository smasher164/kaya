"""The declared picture, resized for each platform's slots.

RULED 2026-09-08, overriding docs/packaging-plan.md P2's first shape: a
packager works from THE FILE THE MANIFEST NAMES, the way a user's app
would. A renderer that knows kaya's own mark can only ever package
kaya's own app, so `resample` and `fit_on` take PNG BYTES and know
nothing about what is in them, and every arm feeds them
`identity.icon_path`.

NO UPSCALING ANYWHERE: a source smaller than the slot is refused naming
both sizes, because a blown-up icon is the defect this rule exists to
prevent. That is why the declared asset is a 1024x1024 source.

`render_png` is what remains of the description, and it has ONE
consumer: tools/regen-mark.py, which regenerates the EXAMPLE asset this
repo ships. tools/check-app-identity.py holds the committed file
byte-identical to `render_png(1024)` and refuses any other caller under
tools/. (A designed mark replaces the description with a drawn 1024
source; the arms do not change.)

Pure python — zlib and struct — because the lanes' hosts have no PIL and
the Windows guest has no python until an arm stages one.
"""

import hashlib
import operator
import struct
import zlib

# The example mark's description: four flat quadrants, top-left,
# top-right, bottom-left, bottom-right (guests/assets/icons/README.md).
QUADRANTS = ("E01B24", "33D17A", "1C71D8", "F6D32D")
# What the committed source is regenerated at. Every slot any platform
# asks for is at or below it, so no arm ever has to enlarge.
SOURCE_PX = 1024

# One process resizes the same source to the same size repeatedly (the
# mac lane wraps two bundles with one icon set each), and a box filter
# over a megapixel is seconds of python.
_CACHE = {}


def rgb(colour):
    """`#RRGGBB` or `RRGGBB` to a byte triple."""
    text = colour.lstrip("#")
    if len(text) != 6:
        raise ValueError(
            f"mark: {colour!r} is not #RRGGBB — a flat ground cannot be "
            f"guessed from a half-spelled colour")
    return tuple(int(text[i:i + 2], 16) for i in (0, 2, 4))


def _chunk(tag, body):
    data = tag + body
    return (struct.pack(">I", len(body)) + data
            + struct.pack(">I", zlib.crc32(data) & 0xFFFFFFFF))


def _png(width, height, rows, channels=3):
    """8-bit truecolour, one IDAT, no ancillary chunks — with alpha only
    when the source carried it."""
    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    return (b"\x89PNG\r\n\x1a\n"
            + _chunk(b"IHDR",
                     struct.pack(">IIBBBBB", width, height, 8,
                                 6 if channels == 4 else 2, 0, 0, 0))
            + _chunk(b"IDAT", zlib.compress(raw, 9))
            + _chunk(b"IEND", b""))


# --------------------------------------------------------------- reading


def decode_png(data):
    """(width, height, channels, rows) with every filter undone and every
    colour type widened to RGB or RGBA.

    Deliberately narrow — 8-bit, non-interlaced — because the sources a
    packaging step is handed are app icons, and one outside that is a
    finding naming what it is rather than a silently wrong picture.
    """
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("mark: the source is not a PNG (bad signature)")
    i, idat, hdr, plte, trns = 8, b"", None, b"", b""
    while i + 8 <= len(data):
        ln = struct.unpack(">I", data[i:i + 4])[0]
        typ = data[i + 4:i + 8]
        body = data[i + 8:i + 8 + ln]
        if typ == b"IHDR":
            hdr = struct.unpack(">IIBBBBB", body)
        elif typ == b"IDAT":
            idat += body
        elif typ == b"PLTE":
            plte = body
        elif typ == b"tRNS":
            trns = body
        i += 12 + ln
    if hdr is None:
        raise ValueError("mark: the source PNG has no IHDR")
    w, h, depth, colour, _comp, _filt, interlace = hdr
    if depth != 8 or interlace != 0:
        raise ValueError(
            f"mark: the source is {depth}-bit"
            f"{' interlaced' if interlace else ''} — this resizer reads "
            f"8-bit non-interlaced PNGs, and widening it is a decision "
            f"about what a source may be, not a guess made here")
    raw_channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(colour)
    if raw_channels is None:
        raise ValueError(f"mark: PNG colour type {colour}")
    raw = zlib.decompress(idat)
    stride = w * raw_channels
    rows, prev, pos = [], bytearray(stride), 0
    for _ in range(h):
        ft = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        for x in range(stride):
            a = line[x - raw_channels] if x >= raw_channels else 0
            b = prev[x]
            c = prev[x - raw_channels] if x >= raw_channels else 0
            if ft == 1:
                line[x] = (line[x] + a) & 0xFF
            elif ft == 2:
                line[x] = (line[x] + b) & 0xFF
            elif ft == 3:
                line[x] = (line[x] + (a + b) // 2) & 0xFF
            elif ft == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 0xFF
            elif ft != 0:
                raise ValueError(f"mark: PNG filter type {ft}")
        rows.append(bytes(line))
        prev = line

    # EVERY COLOUR TYPE BECOMES RGB(A) BEFORE ANYTHING IS AVERAGED: a
    # palette index is a NUMBER, and the mean of two indices is a third
    # colour nobody chose.
    channels = 4 if colour in (4, 6) or (colour == 3 and trns) else 3
    if colour == 2 and channels == 3:
        return w, h, 3, rows
    out = []
    for row in rows:
        line = bytearray()
        for x in range(w):
            if colour == 3:
                idx = row[x]
                line += plte[idx * 3:idx * 3 + 3]
                if channels == 4:
                    line.append(trns[idx] if idx < len(trns) else 255)
            elif colour in (0, 4):
                grey = row[x * raw_channels]
                line += bytes((grey, grey, grey))
                if channels == 4:
                    line.append(row[x * raw_channels + 1])
            else:
                o = x * raw_channels
                line += row[o:o + 3]
                if channels == 4:
                    line.append(row[o + 3])
        out.append(bytes(line))
    return w, h, channels, out


# --------------------------------------------------------------- resizing


def _reduce_int(rows, w, h, channels, k):
    """An exact k x k block mean — every destination pixel is one whole
    block of source pixels, and the sums run at C speed over byte
    slices. This is the fast half: the general filter below then works
    on a picture already close to the target size."""
    dw, dh, n = w // k, h // k, k * k
    out = []
    for dy in range(dh):
        acc = [[0] * dw for _ in range(channels)]
        for sy in range(dy * k, dy * k + k):
            row = rows[sy]
            for c in range(channels):
                col = row[c::channels]
                acc[c] = list(map(
                    operator.add, acc[c],
                    [sum(col[x * k:x * k + k]) for x in range(dw)]))
        line = bytearray(dw * channels)
        for c in range(channels):
            line[c::channels] = bytes((v + n // 2) // n for v in acc[c])
        out.append(bytes(line))
    return dw, dh, out


def _area(rows, w, h, channels, width, height):
    """The area-weighted box filter, for a ratio that is not an integer:
    each destination pixel is the mean of the source pixels it covers,
    edge pixels counted by the fraction they contribute."""
    spans = []
    for x in range(width):
        x0, x1 = x * w / width, (x + 1) * w / width
        first, last = int(x0), min(w - 1, int(x1 - 1e-9))
        spans.append([(sx, min(sx + 1, x1) - max(sx, x0))
                      for sx in range(first, last + 1)])
    out = []
    for y in range(height):
        y0, y1 = y * h / height, (y + 1) * h / height
        first, last = int(y0), min(h - 1, int(y1 - 1e-9))
        yspan = [(sy, min(sy + 1, y1) - max(sy, y0))
                 for sy in range(first, last + 1)]
        line = bytearray()
        for span in spans:
            acc = [0.0] * channels
            total = 0.0
            for sy, wy in yspan:
                row = rows[sy]
                for sx, wx in span:
                    area = wx * wy
                    total += area
                    o = sx * channels
                    for c in range(channels):
                        acc[c] += row[o + c] * area
            line += bytes(min(255, int(v / total + 0.5)) for v in acc)
        out.append(bytes(line))
    return out


def resample(source, width, height=None):
    """`source` PNG bytes drawn at width x height, as PNG bytes.

    A BOX FILTER: exact for an integer ratio, area-weighted otherwise. A
    point sample of a 1024px source at 16px would read sixteen pixels
    out of a million and throw every edge away.

    REFUSES TO ENLARGE, naming both sizes: no slot in this repo is
    filled by blowing a smaller picture up.
    """
    height = width if height is None else height
    key = (hashlib.sha256(source).hexdigest(), width, height)
    if key in _CACHE:
        return _CACHE[key]
    if width < 1 or height < 1:
        raise ValueError(f"mark: {width}x{height} is not a picture")
    sw, sh, channels, rows = decode_png(source)
    if width > sw or height > sh:
        raise ValueError(
            f"mark: cannot draw a {width}x{height} picture from a "
            f"{sw}x{sh} source — every size a platform wants comes DOWN "
            f"from the declared file, and enlarging one is the blurred "
            f"launcher icon this rule exists to prevent. Declare a "
            f"source at least {max(width, height)}px on its longer side")
    # THE INTEGER PREFACTOR FIRST: reduce by the largest whole block that
    # keeps the picture at or above the target, then finish with the
    # general filter on something small. A box of a box is a box, and
    # this is the difference between milliseconds and seconds per size.
    k = min(sw // width, sh // height)
    if k >= 2:
        sw, sh, rows = _reduce_int(rows, sw, sh, channels, k)
    if (sw, sh) == (width, height):
        out = _png(width, height, rows, channels)
    else:
        out = _png(width, height,
                   _area(rows, sw, sh, channels, width, height), channels)
    _CACHE[key] = out
    return out


def fit_on(source, width, height, background, inner_px=None):
    """The source centred on a flat ground — the non-square canvases (a
    Wide310x150 tile, a 620x300 splash) no square picture fills.

    `inner_px` defaults to 60% of the shorter side, rounded down to even.
    The ground is opaque, so the result is RGB whatever the source was: a
    tile is composited onto the colour the manifest declares, not onto
    whatever the shell happens to be showing.
    """
    if inner_px is None:
        inner_px = (min(width, height) * 6 // 10) & ~1
    if inner_px > min(width, height):
        raise ValueError(
            f"mark: a {inner_px}px picture does not fit a {width}x{height} "
            f"canvas")
    ground = bytes(rgb(background))
    _w, _h, channels, inner = decode_png(resample(source, inner_px))
    x0, y0 = (width - inner_px) // 2, (height - inner_px) // 2
    out = []
    for y in range(height):
        row = bytearray(ground * width)
        if y0 <= y < y0 + inner_px:
            src = inner[y - y0]
            for x in range(inner_px):
                o, base = x * channels, (x0 + x) * 3
                if channels == 4:
                    alpha = src[o + 3] / 255.0
                    for c in range(3):
                        row[base + c] = min(255, int(
                            src[o + c] * alpha
                            + row[base + c] * (1 - alpha) + 0.5))
                else:
                    row[base:base + 3] = src[o:o + 3]
        out.append(row)
    return _png(width, height, out)


# ------------------------------------------------- the example mark only


def _quadrant_rows(px):
    if px < 2:
        raise ValueError(
            f"mark: {px}px has no four quadrants to draw — the example "
            f"mark is a 2x2 division")
    tl, tr, bl, br = (rgb(c) for c in QUADRANTS)
    half = px // 2
    rows = []
    for y in range(px):
        left, right = (tl, tr) if y < half else (bl, br)
        rows.append(bytearray(bytes(left) * half
                              + bytes(right) * (px - half)))
    return rows


def render_png(px=SOURCE_PX):
    """The EXAMPLE mark from its own description.

    ONE CALLER: tools/regen-mark.py, which rewrites the committed source.
    tools/check-app-identity.py holds that file byte-identical to this
    and refuses any other caller under tools/ — an arm that rendered
    instead of resampling could only ever package this repo's own app.
    """
    return _png(px, px, _quadrant_rows(px))


def write(path, data):
    """`data` onto disk, parents made; returns the bytes written."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return data
