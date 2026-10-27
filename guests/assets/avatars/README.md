# avatars: the chat app's conversation pictures

Three baseline JPEGs (JFIF, 4:2:0, 8-bit, 160x160) the chat app shows as
each conversation's round picture (guests/go/chat/chat.go). Abstract on
purpose, no faces:

- `maya.jpg`: orange to rose gradient F2994A to D9486A, a cream sun.
- `sam.jpg`: teal gradient 2BB3A3 to 1D6F8C, a pale diamond.
- `alex.jpg`: violet gradient 8E6FE0 to 4A3AA8, a pale peak.

Every motif sits inside the inscribed circle, since kaya clips the picture
to it (docs/styling-pass-plan.md Y6).

Generated here by tools/gen-avatars.py with the dev shell's FFmpeg (lavfi
`geq`, MJPEG at `-q:v 3`, `+bitexact`, one thread), so the committed bytes
are deterministic and `tools/gen-avatars.py --check` regenerates into
scratch and compares; tools/check-assets.py runs that comparison.

No licence question arises: the pictures are synthetic and made by this
repository's own generator, no upstream material is in them.

To regenerate: `tools/gen-avatars.py` inside `nix develop` rewrites the
JPEGs in this directory (this README is kept); commit the result. A new or
renamed file moves tools/scenes/assets.steps' frozen census.
