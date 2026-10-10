"""One pixel of a simulator screenshot, read from `simctl io screenshot
--type=bmp` without decoding the image (docs/traps.md, the iOS
media_screen entry; held by self_test, which run-sim runs at import and
check-verbs runs against doctored copies)."""
import io
import struct

HEADER = 138
SRGB = 0x73524742
MASKS = (0xFF0000, 0xFF00, 0xFF)


def screen_pixel(f, x, y):
    """(RRGGBB, "") or (None, sentence) from an open BMP file."""
    head = f.read(HEADER)
    if len(head) < HEADER or head[:2] != b"BM":
        return None, f"the screenshot is not a V5 BMP ({len(head)} header bytes, starts {head[:2]!r})"
    off, hsize = struct.unpack("<I", head[10:14])[0], struct.unpack("<I", head[14:18])[0]
    w, h, _planes, bpp, comp = struct.unpack("<iiHHI", head[18:34])
    masks = struct.unpack("<III", head[54:66])
    space = struct.unpack("<I", head[70:74])[0]
    if hsize < 108 or space != SRGB:
        return None, (f"the screenshot's colour space is {space:#x} in a {hsize}-byte header, "
                      f"not sRGB, so its colours are in no stated space")
    if bpp != 32 or comp != 3 or masks != MASKS:
        return None, (f"the screenshot is {bpp}bpp compression {comp} masks "
                      f"{[hex(m) for m in masks]}, not 32bpp BGRA bitfields")
    rows = abs(h)
    if not (0 <= x < w and 0 <= y < rows):
        return None, f"the screenshot is {w}x{rows}, no pixel at {x},{y}"
    row = y if h < 0 else rows - 1 - y
    f.seek(off + (row * w + x) * 4)
    px = f.read(4)
    if len(px) != 4:
        return None, f"the screenshot ends before pixel {x},{y} ({w}x{rows})"
    return "%02X%02X%02X" % (px[2], px[1], px[0]), ""


def synthetic(w, h, top_down=True, space=SRGB, bpp=32, pixel=None):
    """A BMP shaped like simctl's, every pixel (x, y) -> BGRA bytes."""
    off = HEADER
    body = bytearray(w * h * 4)
    for y, x, bgra in (pixel or ()):
        row = y if top_down else h - 1 - y
        body[(row * w + x) * 4:(row * w + x) * 4 + 4] = bgra
    head = bytearray(HEADER)
    head[:2] = b"BM"
    struct.pack_into("<IHHI", head, 2, off + len(body), 0, 0, off)
    struct.pack_into("<IiiHHII", head, 14, 124, w, -h if top_down else h, 1, bpp, 3, len(body))
    struct.pack_into("<IIIII", head, 54, *MASKS, 0xFF000000, space)
    return bytes(head) + bytes(body)


class Counting(io.BytesIO):
    def __init__(self, data):
        super().__init__(data)
        self.taken = 0

    def read(self, n=-1):
        got = super().read(n)
        self.taken += len(got)
        return got


def self_test(reader=screen_pixel):
    """Findings, empty when the reader answers every shape as it must."""
    bad = []
    marks = ((1, 2, b"\x1e\x3c\xc8\xff"), (0, 0, b"\x01\x02\x03\xff"))
    for top in (True, False):
        data = synthetic(3, 2, top_down=top, pixel=marks)
        got = reader(io.BytesIO(data), 2, 1)
        if got != ("C83C1E", ""):
            bad.append(f"a {'top-down' if top else 'bottom-up'} BMP's pixel 2,1 read {got}, "
                       f"wanted C83C1E")
        got = reader(io.BytesIO(data), 0, 0)
        if got != ("030201", ""):
            bad.append(f"a {'top-down' if top else 'bottom-up'} BMP's pixel 0,0 read {got}, "
                       f"wanted 030201")
    if reader(io.BytesIO(synthetic(3, 2, space=0)), 0, 0)[0] is not None:
        bad.append("a BMP with no sRGB colour space was read")
    if reader(io.BytesIO(synthetic(3, 2, bpp=24)), 0, 0)[0] is not None:
        bad.append("a 24bpp BMP was read as 32bpp")
    if reader(io.BytesIO(synthetic(3, 2)), 3, 0)[0] is not None:
        bad.append("a pixel outside the screenshot was read")
    if reader(io.BytesIO(b"\x89PNG\r\n\x1a\n" + bytes(200)), 0, 0)[0] is not None:
        bad.append("a PNG was read as a BMP")
    big = Counting(synthetic(1206, 2622, pixel=((2000, 600, b"\x1e\x3c\xc8\xff"),)))
    got = reader(big, 600, 2000)
    if got != ("C83C1E", "") or big.taken > HEADER + 4:
        bad.append(f"a phone-sized screenshot's pixel read {got} and took {big.taken} bytes; "
                   f"the read is the header and one pixel ({HEADER + 4} bytes), never the image")
    return bad
