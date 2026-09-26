# Scene stand-in pictures

`photo.jpg` — 800x600 JPEG, a sunset over the sea. The chat scene's photo
attachment (docs/photo-attach-plan.md §5): the harness copies it into the
open dialog's directory on the desktops and the phone lanes put it in the
photo library, and the leg reads its 800x600 back, so a wrong photo fails.
Written by this repo, no upstream and no licence. Regenerate with
ImageMagick:

    magick -size 800x360 gradient:'#7fb6e6'-'#f6d9a8' \( -size 800x240 \
      gradient:'#2f6f9a'-'#123b5a' \) -append -fill '#ffd36b' \
      -draw 'circle 560,330 560,275' -fill '#2f6f9a' \
      -draw 'rectangle 0,360 800,600' -strip -sampling-factor 4:2:0 \
      -quality 82 photo.jpg

`a11y-logo.png` — 2x2, 8-bit RGB, 75 bytes. Written by this repo, for
this repo — where it came from is the a11y guests' own inline TEST_PNG
byte array, extracted verbatim on 2026-08-19 when those guests moved to
`asset(name)` — so there is no upstream and no licence to carry, which
is the one hygiene question a vendored binary asks.

A SEPARATE FAMILY FROM icons/ BECAUSE THE GATE SAYS SO, correctly:
tools/check-app-identity.py reads any `icons/...` asset open as a
reference to the DECLARED mark and refuses a name that is not it — a
mistyped mark name fails silently otherwise. This file is not the app's
mark; it is the a11y scene's image-widget stand-in, where the LABEL is
the subject and the picture is scenery.

And it is tiny BY MEASUREMENT, not modesty: pointing the a11y guests at
the 64x64 mark grew the scene's column ~62px, pushed its last three
widgets past the 320x640 emulator viewport, and the a11y provider
answers an offscreen node with 20 seconds of silence per read before
the semantics fallback serves it — three silent reads blew the lane's
60s leg budget with the scene SUBSTANTIVELY GREEN. Swap this file for
anything taller and that cliff is where you land.

## How to regenerate it

The bytes are frozen history (the guests' original array), but the
equivalent picture is: 2x2, 8-bit truecolour, red/green over blue/white
— the icons README's generator two directories over, with W = H = 2 and
Q = [(255,0,0), (0,255,0), (0,0,255), (255,255,255)].
