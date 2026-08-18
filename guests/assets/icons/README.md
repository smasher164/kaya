# The vendored app mark

`kaya-mark.png` — 64x64, 8-bit RGB, no alpha, 156 bytes. Written by this
repo, for this repo: there is no upstream and no licence to carry, which
is the one hygiene question a vendored binary asks and the reason it is
answered here rather than left to be looked up.

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

`KAYA_ICON_FILE` overrides the repo-relative default for a runner whose
guest cannot see the repo, exactly as `KAYA_FONT_FILE` does for the
typeface — the Windows lane copies this file to the mirrored path on the
VM (tools/deploy-win.sh) and points the variable at it.
