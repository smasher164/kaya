# The highlight mark on GTK: two background tags, priority and AT-SPI — measured 2026-11-15

For docs/highlight-plan.md §3 (H2's GTK item): whether two `background-rgba`
tags over one range paint by priority, and what the accessibility bus says of
a mark tag that sets `background-full-height` FALSE, against find's
`kaya-highlight` tag (full height TRUE).

**Environment.** The linux lane's image `kaya-linux` (GTK **4.24.0**), run
ephemerally under Xvfb with a session bus and the a11y bus, the shape of
docs/measurements/richtext-gtk-2026-09-11.md. `highlight-gtk-2026-11-15/run.sh`
starts `app.py` (one editable `GtkTextView`, six words, each carrying a case)
and `reader.py` (AT-SPI `get_attribute_run` at each word's middle). The app
renders itself through `Gtk.WidgetPaintable` and the native's renderer and
reads the commonest pixel inside each word's glyph box.

Tags, in the order added: `kaya-rich-code` (`#c8c8c8`), `kaya-highlight`
(find, `#ffe066`, full height), `kaya-rich-v-highlight=yellow` (`#F7E8AF`, full
height false) then moved to find's priority with `set_priority`, and a control
`kaya-rich-v-highlight=blue` (`#D5EBFF`) left where it was minted, above find.
Final priorities code 0, mark 1, find 2, late mark 3.

| word | tags | drawn | AT-SPI run |
|---|---|---|---|
| MARKONLY | mark | `F7E8AF` | `bg-color 0,0,0`, `bg-full-height false` |
| FINDONLY | find | `FFE066` | `bg-color 65535,0,0`, `bg-full-height true` |
| FINDOVERMARK | mark (1) + find (2) | `FFE066` | `bg-color 65535,0,0`, `bg-full-height true` |
| MARKOVERCODE | code (0) + mark (1) | `F7E8AF` | `bg-color 0,0,0`, `bg-full-height false` |
| LATEMARK | find (2) + late mark (3) | `D5EBFF` | `bg-color 0,0,65535`, `bg-full-height false` |
| CODEONLY | code | `C8C8C8` | `bg-color 0,0,0` (no full-height key) |

**What it settles.**
- Two background tags over one range paint by PRIORITY, the higher one
  winning outright (no blend), for the colour AND for `bg-full-height`.
- A tag minted after find's sits above it by default (LATEMARK): the mark
  then hides find's yellow AND turns the run's `bg-full-height` to false, so
  the highlights read (gtk.rs, keyed on `bg-full-height == "true"`) MISSES the
  match. The priority call is load-bearing, and it is not enough once at the
  mark's mint: a tag minted later (a second mark name, or a code tag minted
  after a mark) lands above. The arm must keep the order code < mark < find
  whenever any of the three is minted.
- A mark tag that SETS full height to false publishes `bg-full-height:
  false`, which the highlights read already ignores; a code tag publishes no
  full-height key.
- The colour on the bus is still unreadable (each channel truncated to 0 or 1
  before scaling, docs/probes/range-probe-linux.md), so a scene asserts the
  mark's colour by pixels (`expect_text_ground`), never through AT-SPI.
- The gap the view's `pixels-above-lines` adds is unpainted by both the mark
  and find's full-height tag (`FFFFFF` three pixels above each glyph box).
