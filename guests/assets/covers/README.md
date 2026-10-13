# covers — stand-in album art (docs/network-images-plan.md §5)

Three baseline JPEGs (JFIF, 4:2:0, 8-bit) the network-images scenes fetch
from the lane's media server (tools/media-server.py serves them under
`/covers/`). Each size is its own picture, so art landing on the wrong row
reads as a wrong size in a scene and a wrong colour in a capture:

- `cover-600.jpg`: 600x600, red gradient C8462E to 7A1E14, a cream circle.
- `cover-320.jpg`: 320x320, blue gradient 2E6FC8 to 142F7A, a cream square.
- `cover-1000.jpg`: 1000x1000, green gradient 2EA05A to 0F4A2A, a cream
  diamond.

Generated here by tools/gen-covers.py with the dev shell's FFmpeg (lavfi
`geq`, MJPEG at `-q:v 3`, `+bitexact`, one thread), so the committed bytes
are deterministic and `tools/gen-covers.py --check` regenerates into scratch
and compares; tools/check-assets.py runs that comparison.

No licence question arises: the pictures are synthetic and made by this
repository's own generator, no upstream material is in them.

To regenerate: `tools/gen-covers.py` inside `nix develop` rewrites the
JPEGs in this directory (this README is kept); commit the result. A new or
renamed file moves tools/scenes/assets.steps' frozen census.
