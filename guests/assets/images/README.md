# Scene stand-in pictures

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
