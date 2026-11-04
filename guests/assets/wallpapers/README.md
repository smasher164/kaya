# wallpapers: the chat app's thread pictures

Three baseline JPEGs (JFIF, 4:2:0, 8-bit, 960x960) the chat app covers an
open thread with (guests/go/chat/chat.go, docs/looks-plan.md §3.5): each
conversation's own, behind its bubbles. Abstract on purpose, no faces:

- `maya.jpg`: the avatar's orange-to-rose gradient (F2994A to D9486A) moved
  72% toward white, its sun tiled six across and faint.
- `sam.jpg`: the teal gradient (2BB3A3 to 1D6F8C) the same way, its diamond.
- `alex.jpg`: the violet gradient (8E6FE0 to 4A3AA8) the same way, its peak.

Pale by construction: the bubbles over it are `filled` (accent, neutral),
which is what makes text legal over a picture (docs/styling-pass-plan.md
Y3), and the pale ground keeps a dark-mode neutral bubble readable too.

Generated here by tools/gen-wallpapers.py with the dev shell's FFmpeg (lavfi
`geq`, MJPEG at `-q:v 4`, `+bitexact`, one thread), from the same colours
and motifs as tools/gen-avatars.py, so the committed bytes are deterministic
and `tools/gen-wallpapers.py --check` regenerates into scratch and compares;
tools/check-assets.py runs that comparison.

No licence question arises: the pictures are synthetic and made by this
repository's own generator, no upstream material is in them.

To regenerate: `tools/gen-wallpapers.py` inside `nix develop` rewrites the
JPEGs in this directory (this README is kept); commit the result. A new or
renamed file moves tools/scenes/assets.steps' frozen census.
