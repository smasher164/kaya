# The vendored app mark

`kaya-mark.png` — 64x64, 8-bit RGB, no alpha, 156 bytes. Written by this
repo, for this repo: there is no upstream and no licence to carry, which
is the one hygiene question a vendored binary asks and the reason it is
answered here rather than left to be looked up.

THIS FAMILY IS THE MARK'S ALONE: tools/check-app-identity.sh reads any
`icons/...` asset open as a reference to the declared mark and refuses
a name that is not it. A picture that is not the mark lives in
guests/assets/images/ (its README carries the a11y stand-in's story and
the measured viewport cliff behind its size).

It is four quadrants in four flat colours:

| quadrant | colour |
|---|---|
| top-left | `E01B24` |
| top-right | `33D17A` |
| bottom-left | `1C71D8` |
| bottom-right | `F6D32D` |

Why it exists, and why it looks like this. The identity scene declares
this file's BYTES over the wire's blob channel
(`set_app_identity`, docs/app-identity-plan.md), every backend hands
them to its own platform's image decoder, and `expect_app_icon` reads
the four quadrant CENTRES back off the picture that platform ended up
holding. So the mark is built to make that read impossible to fake:

- **Four colours rather than a hash.** One PNG goes in and each platform
  converts it — an HICON on Windows, an NSImage on macOS, a GdkTexture
  on Linux — so a hash of the converted bytes could never be one frozen
  string across platforms. Four unmistakable colours can be, and they
  prove the conversion happened rather than merely that a call returned.
- **Centres rather than corners.** Whatever rescale a platform applies
  between this file and the size it rasterizes an icon at blurs the
  quadrant BOUNDARIES. The centre of a large flat region survives every
  resampling filter exactly.
- **Nothing a default could equal.** A platform's own fallback icon —
  the generic executable, the host process's mark, a monochrome
  placeholder — cannot land on these four values, so a lowering that
  never applied reads as a real mismatch and never as a lucky pass. That
  is the vendored typeface's argument (guests/assets/fonts/README.md)
  one asset over: the expectation must be unreachable by fallback, by
  construction.

NOTHING NAMES THIS FILE'S PATH ANY MORE. The guests ask for
`asset("icons/kaya-mark.png")` and the core resolves it
(crates/kaya/src/assets.rs); a runner whose guest cannot see the repo
stages the whole asset ROOT and names it once in `KAYA_ASSET_DIR` — the
Windows lane copies the root into the VM's repo mirror, the emulator
lane pushes it, and the iOS lane copies it into the app bundle, where
the core finds it with no variable at all. Android has a fourth route
and it is the packaging one: the APK carries the root under
`assets/kaya/` and the AssetManager serves it, which is what the legs
that arrive with no `KAYA_ASSET_DIR` exercise.

## How to regenerate it

`kaya-mark.png` is written by this repo, so unlike the vendored typeface
beside it there is something to run. Four flat quadrants, 64x64, 8-bit
truecolour, no alpha, no ancillary chunks:

    python3 - <<'PY'
    import struct, zlib
    W = H = 64
    Q = [(0xE0,0x1B,0x24), (0x33,0xD1,0x7A), (0x1C,0x71,0xD8), (0xF6,0xD3,0x2D)]
    rows = []
    for y in range(H):
        row = bytearray([0])
        for x in range(W):
            row += bytes(Q[(y >= H // 2) * 2 + (x >= W // 2)])
        rows.append(bytes(row))
    def chunk(t, p):
        return struct.pack(">I", len(p)) + t + p + struct.pack(">I", zlib.crc32(t + p))
    open("kaya-mark.png", "wb").write(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
        + chunk(b"IEND", b""))
    PY

Regenerating changes the file's BYTES if zlib's output differs, and the
byte-equality rule (tools/check-app-identity.sh) holds every packaged
copy identical to this one — so a regeneration is a tree-wide change and
the gate will say so. The four colours themselves are frozen: they are
`expect_app_icon`'s expectation in tools/scenes/identity.steps.
