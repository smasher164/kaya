# TEXT-RANGES probe: the linux / GTK4 arm

Repo HEAD 6a616d6. Nothing shipped, nothing committed, no repo file changed
(verified clean at the end). Everything below is measured in the lane's own
container image `kaya-linux`, against the same crate versions the backend links.

Environment:

- GTK 4.18.6, pango 1.56.3, at-spi2-core 2.56.2-1+deb13u1 (Debian trixie)
- `gtk4` 0.11.4 with feature `v4_10`, `pango` 0.22.8, `atspi` 0.30
  (crates/kaya/Cargo.toml:66,123)
- probe sources (throwaway, outside the repo):
  scratchpad/probe.rs (gone), scratchpad/ime.rs (gone), scratchpad/reader.py (gone),
  scratchpad/run.sh (gone), scratchpad/ime-run.sh (gone)
- raw logs: scratchpad/out4.txt (gone) (in-process + AT-SPI), scratchpad/ime2.txt (gone)
  (composition), with out1..out3/ime1 kept as the earlier passes

## Verdict

GTK charges very little for HIGHLIGHT and SELECT on a textarea, and both are
readable from outside the process today with the dependency kaya already has.
REVEAL is the expensive one, and not because of the scroll API: **kaya's
textarea has no viewport at all**, so there is nothing to scroll into view.
The widget is a bare `GtkTextView` (crates/kaya/src/gtk.rs:3068) that grows to
its full content height, so a 400-line buffer produces a 6400px-tall widget in
a 6692px-tall window. `scroll_to_iter` returns `true` and moves nothing.
Shipping REVEAL on linux means wrapping the textarea in a `GtkScrolledWindow`,
which is a change to the widget's layout behaviour and to the accessibility
tree, not a new call in an existing arm.

The entry is the weak sibling on every axis: highlight is possible but rides
absolute byte offsets that do not follow edits, and neither reveal nor any
geometry is observable for it over AT-SPI at all.

Three findings that a design has to route around, all measured:

1. **`select_range` cancels an active IME composition, unconditionally**, even
   when the requested range is identical to the current one and even when it is
   a zero-length caret placement at the caret's existing position. Under a
   re-declare-after-every-edit model that costs an IME user a keystroke per
   edit. The backend must compare and skip; GTK will not.
2. **A GtkTextView reports its tag colours wrong over AT-SPI.** Each channel is
   truncated before scaling, so only fully saturated channels survive:
   `#ffe066` and `#ff0000` both read back `65535,0,0`, `#808080` reads `0,0,0`.
   The same colour on a GtkEntry reads back exactly. Assertions must key on the
   presence of the attribute, never its value.
3. **`org.a11y.atspi.Text.GetAttributeValue` SIGSEGVs the GTK app.** Reproduced
   twice. kaya's reader must never call it. `GetAttributeRun` is safe.

## The three capabilities

| | HIGHLIGHT (many ranges) | SELECT (one range) | REVEAL (scroll into view) |
|---|---|---|---|
| API (textarea) | `TextBuffer::create_tag` + `apply_tag` / `remove_all_tags` | `TextBuffer::select_range` | `TextView::scroll_to_mark` (prefer) / `scroll_to_iter` |
| API (entry) | `Entry::set_attributes(&pango::AttrList)` | `Editable::select_region` | none exists |
| Cost, textarea | 400 ranges over 19k chars: apply 530us, full re-declare cycle 570us. 3980 ranges over 195k chars: apply 2.6ms, clear 2.2ms | 570us first call, no repaint of its own | one call, completes on an idle; needs re-issuing if the line is not laid out yet |
| Fires `changed`? | no (0 signals over 20 re-declare cycles) | no | no |
| Extra frames? | none: 28 paints in 500ms of re-declaring (31 cycles) vs 29 paints in 500ms idle | none | one |
| Survives edits | yes, text-anchored, semantics sane (see 4) | n/a, re-declared | n/a |
| Entry survives edits | **no**, absolute byte indices, stale after any edit | yes (character indices) | n/a |
| IME risk | none measured | **cancels composition every time** | none measured |
| Observable out of process | yes, `GetAttributeRun(off, include_defaults=false)`, walked; value of the colour is wrong on textarea | yes, `GetNSelections` + `GetSelection`, focus not required | yes, `GetRangeExtents` inside `Component.GetExtents` |
| Observable for entry | yes, proper runs, exact colour | yes | **no**, `GetRangeExtents` and `GetCharacterExtents` both fail |
| Verdict | cheap, ship it | cheap, ship it with an idempotence guard | needs a GtkScrolledWindow around the textarea first; no entry story |

## 0. What kaya's text widgets sit on today

- `WidgetKind::Entry` builds a bare `gtk4::Entry` (gtk.rs:3095), uncontrolled,
  with `connect_changed` emitting the text occurrence and banking an undo
  episode unless `apply_quiet` is set (gtk.rs:3102-3116).
- `WidgetKind::Textarea` builds a bare `gtk4::TextView` (gtk.rs:3226) with
  `set_size_request(240, 96)` (gtk.rs:3227) and **no scrolled window**. Its
  `buffer().connect_changed` handler is the entry's contract (gtk.rs:3240-3252).
- `NativeWidget` (gtk.rs:364-379) holds one widget per kind;
  `NativeWidget::Radio(gtk4::Box)` is the precedent for a kind whose native
  widget is a container over the real control.
- Harness surface today: `set_text` (gtk.rs:5758), `read_text` (gtk.rs:5796),
  `is_focused` (gtk.rs:5830). Nothing reads selection, attributes or geometry.
- `ax` (gtk.rs:5171) resolves a widget by kaya index, ranks it among same-role
  widgets in the widget tree (`atspi_rank`, gtk.rs:6796), then reads the Nth
  same-role node's **name** off the bus (`atspi_collect`, gtk.rs:7058). Entry
  and Textarea are both AT-SPI role `Text` (gtk.rs:5187). The `Text` interface
  is already spoken, but only `character_count` + `get_text` as a name fallback
  (gtk.rs:7076-7088).

## 1. HIGHLIGHT

### Textarea: GtkTextTag, and it is cheap

One tag object, applied to N ranges. Measured on a 19199-char buffer
(400 lines), `#ffe066` background plus single underline:

```
highlight.create_tag           234us      (once, at tag creation)
highlight.apply n=1             11us
highlight.apply n=10            69us
highlight.apply n=50           368us
highlight.apply n=200          466us
highlight.apply n=400          530us
highlight.remove_all n=400     436us
highlight.redeclare x20 n=400  11.4ms total, 570us per cycle
highlight.scale 195k chars, 3980 ranges: apply 2.6ms, remove_all 2.2ms
```

The re-declare cycle (`remove_all_tags` over the whole buffer, then N
`apply_tag`) is the shape the milestone's model assumes, and it costs about
half a millisecond for 400 ranges. It is linear and stays usable an order of
magnitude past any scene.

Two properties that matter more than the numbers:

- **Tagging does not fire the buffer's `changed` signal.** 20 full re-declare
  cycles produced 0 `changed` emissions, and `is_modified()` stayed false. So
  highlighting cannot accidentally emit a text occurrence, bank an undo
  episode, or mark the window dirty through gtk.rs:3240-3252. Nothing in the
  existing machinery has to be quieted for it.
- **No extra frames.** 31 full re-declare cycles in 500ms produced 28 paints;
  500ms of doing nothing produced 29. The tag churn coalesces into frames the
  clock was already running. No flicker is observable at this granularity.

Shape notes: two ranges that touch merge into one on readback
(`[10,20)` + `[20,30)` reads back as `[(10,30)]`), so an app that declares
adjacent ranges cannot tell them apart afterwards. Two different tags may
overlap freely and each keeps its own range list.

### Entry: pango attributes, on absolute byte offsets

`Entry::set_attributes(&pango::AttrList)` with `AttrColor::new_background` and
`set_start_index`/`set_end_index`. Costs 36-57us. It works, and reads back
exactly (`"6 11 background #ffffe0e06666"`), but:

- the indices are **bytes**, while `select_region` on the same widget takes
  **characters** (measured: `select_region(6,11)` on `"héllo wörld"` selects
  `"wörld"`, i.e. characters);
- the indices are **absolute and do not move**. After `set_text` prepended
  three characters, the attribute list still read `6 11`. `pango::AttrList` has
  an `update(pos, remove, add)` method for exactly this, but GtkEntry never
  calls it. Under the re-declare model this is fine; under any other model it
  is a bug generator.

## 2. SELECT

`TextBuffer::select_range(&start, &end)` for the textarea, 570us on first call.
`Editable::select_region(start, end)` for the entry, 25-38us. Neither fires
`changed`. Neither scrolls: with the view's buffer scrolled to the top, a
`select_range` 15000 characters in left `visible_rect().y()` at 0. SELECT and
REVEAL are genuinely separate primitives here, which is the design's
assumption.

Details a spec has to pin down, all measured:

- Focus is not required. `select_region` on an unfocused entry took, and the
  selection is published on the bus for the unfocused widget too.
- A reversed range normalises: `select_range(140, 100)` reads back
  `Some((100,140))`, with the insert mark at 140. So direction is preserved in
  the marks but lost from `selection_bounds()`.
- **An empty range is a caret placement, not a selection.**
  `select_range(50, 50)` gives `selection_bounds() == None` and caret 50, and
  the bus reports `GetNSelections == 0`. A read verb must distinguish "no
  selection" from "empty selection at N" by asking for the caret separately.

## 3. REVEAL: the structural blocker

The API is not the problem. `scroll_to_iter` and `scroll_to_mark` both work
when there is something to scroll. The problem is that kaya's textarea has no
viewport.

Three shapes measured side by side with a 400-line buffer:

| shape | allocated height | vadjustment | scroll_to_mark result |
|---|---|---|---|
| A: bare `GtkTextView` (**what kaya builds**, gtk.rs:3226) | 6400px | value 0, upper 6400, **page 6400** | nothing moves, `visible_rect.y` stays 0 |
| B: `GtkTextView` as the direct child of a `GtkScrolledWindow` | 96px | value 5473, upper 6400, page 96 | scrolls, `visible_rect.y` 5473 |
| C: `GtkTextView` inside a Box inside a `GtkScrolledWindow` | 6400px | page 6400 | nothing moves |

In shape A the page size equals the content height, so the view believes all of
it is visible. `scroll_to_iter` returns `true` and moves nothing, which is the
worst kind of no-op: it looks like it worked. The window grew to 6692px to
contain the widget, which on a real display means the text is simply clipped
and unreachable, with no scrollbar and no keyboard scroll.

Shape C is what an app gets **today** if it puts a textarea inside kaya's
`scroll` kind (gtk.rs:3200): the Box hands the TextView its natural height, so
the TextView is not the scrollable child, and `scroll_to_mark` on it moves
nothing. Revealing in that arrangement would mean converting buffer
coordinates up to the outer `GtkScrolledWindow`'s adjustment by hand.

So the linux arm of REVEAL is: **wrap the textarea in a GtkScrolledWindow**
(shape B) and drive `scroll_to_mark`. That is not a one-line change:

- `NativeWidget::Textarea` (gtk.rs:378) must carry the scrolled window for
  parenting, layout and prop application while `core.textareas` (gtk.rs:442)
  keeps holding the `TextView` for every existing verb. The
  `NativeWidget::Radio(gtk4::Box)` variant is the precedent for a composite.
- The textarea stops growing to its content and starts obeying its size
  request, which changes existing scenes' layout on linux only. Any scene that
  asserts geometry around a textarea is in the blast radius.
- **The accessibility tree changes.** Measured: a `GtkScrolledWindow` publishes
  a `scroll pane` node with two `scroll bar` children, and the `text` node
  moves one level deeper. `atspi_rank` (gtk.rs:6796) counts same-role widgets,
  and `K::Scroll` maps to `Role::ScrollPane` (gtk.rs:5199), so every textarea
  would add a ScrollPane to that count and shift `scroll#N` ordinals for any
  scene holding both a scroll viewport and a textarea. This is the exact bug
  class already recorded at gtk.rs:6809-6814 (a drop-down's internal scrolled
  window shifting the scene's real one to ScrollPane#1). The `text#N` ordinals
  are unaffected: the TextView is still the only Text-role node.

Two more reveal facts worth writing into a design:

- **A reveal may need re-issuing.** `scroll_to_mark` completes on an idle once
  the line's height is known. Issued right after a `set_text`, one 200ms settle
  left the view at y=264 of a 5600 target; a second call after another settle
  landed it at 5560. A backend that issues reveal once and returns will
  intermittently not reveal. `scroll_to_iter` has the same shape (it was the
  settle time, not the API, that differed: given an equal 150ms it moved the
  view exactly as `scroll_to_mark` did). Prefer the mark form, which GTK
  documents as the one that re-tries, and give the harness a settle.
- **The entry has no reveal at all.** No scroll API, no adjustment, no scroll
  offset getter. `set_position` moves the caret and GtkText scrolls internally
  to follow it, and `position` is the only thing readable back.

## 4. Do ranges survive edits

Yes, on the textarea, and with sane semantics. GtkTextTag ranges live in the
buffer's b-tree and are anchored to the text, not to offsets. Base range
`[10,20)` on a 36-character buffer:

| edit | result |
|---|---|
| insert 3 chars at 0 | `[(13,23)]` shifted |
| insert 3 chars at 15 (inside) | `[(10,23)]` inserted text inherits the tag |
| insert 3 chars at 10 (start boundary) | `[(13,23)]` does not inherit, range shifts |
| insert 3 chars at 20 (end boundary) | `[(10,20)]` does not inherit |
| delete 0..5 (before) | `[(5,15)]` |
| delete 12..15 (inside) | `[(10,17)]` |
| delete 8..25 (covering) | `[]` gone |
| `set_text` wholesale | `[]` all tags dropped |

Offsets are characters, not bytes: a range `[6,11)` on `"héllo wörld — ünïcode"`
(28 chars, 34 bytes) selects `"wörld"`.

This matters even though the app re-declares. Between the user's keystroke and
the app's re-declaration, the highlight on screen is *shifted correctly* rather
than pointing at the wrong text, so there is no visible wrong-range flash. The
entry has the opposite behaviour, since its pango indices are absolute: between
the keystroke and the re-declaration, the entry's highlight is on the wrong
characters.

## 5. Composition and IME

The container has no ibus, so this is GTK's own `GtkIMContextSimple`. A real
preedit needs a UTF-8 locale and a layout with dead keys; measured with
`LANG=C.UTF-8` and `setxkbmap us -variant intl`, `dead_acute` then `a` produces
preedit `"´"` then commits `"á"`. `GtkTextView::preedit-changed` is the
observable. (In the default layout and the C locale, no candidate sequence
produced a preedit at all, which is worth knowing before anyone tries to write
an IME scene for this lane.)

Measured with a live preedit on the view, acting mid-composition and then
sending the committing key:

| act mid-composition | preedit after the act | what committed |
|---|---|---|
| nothing (control) | `"´"` alive | `"á"` |
| `apply_tag` | `"´"` alive | `"á"` |
| full re-declare (`remove_all_tags` + 40 `apply_tag`) | `"´"` alive | `"á"` |
| `scroll_to_mark` | `"´"` alive | `"á"` |
| `select_range(0,5)` | **dropped** | selection replaced, composition lost |
| `select_range` of the range that was **already** selected | **dropped** | composition lost |
| `select_range(caret, caret)` where the caret already is | **dropped** | plain `"a"` landed instead of `"á"` |

So HIGHLIGHT and REVEAL are safe during composition, and SELECT is not. GTK
resets the IM context on any programmatic cursor or selection move, whether or
not anything actually changed. The consequence for the design is concrete: a
backend that re-applies the declared selection on every frame or after every
edit will eat one keystroke per edit for every IME user. The GTK arm has to
compare the requested range against `selection_bounds()` (plus the caret, for
the empty-range case) and skip the call when they match.

One thing composition does **not** do: the preedit never enters the buffer.
Measured `buffer="BASE"`, `char_count=4`, preedit `"´"` live. So offsets an app
declares ranges in are never disturbed by an in-flight composition, and a
harness reading `character_count` mid-composition sees the committed text only.

## 6. Observability: how a harness leg reads this back

kaya already links `atspi` 0.30 under the `harness` feature, and the crate's
`TextProxy` already has every method needed: `get_n_selections`, `get_selection`,
`get_attribute_run`, `get_attributes`, `get_range_extents`,
`get_character_extents`, `caret_offset`. No new dependency. The probe read over
the same D-Bus interface with pygobject; the wire is identical.

### SELECT: clean

`GetNSelections` + `GetSelection(0)`, on both kinds, focus not required:

```
node #0 (textarea, focused)   SELECT n=1 [(10, 13, 'two')]     caret=10
node #3 (entry, NOT focused)  SELECT n=1 [(12, 17, 'world')]   caret=17
node #1 (textarea, no sel)    SELECT n=0 []                    caret=19199
```

An empty declared range shows up as `n=0` with the caret at the right place, so
a leg asserting "selection is empty at 12" reads the caret, not the selection.

### HIGHLIGHT: readable, with two traps

`GetAttributeRun(offset, include_defaults=false)` returns the attributes and the
bounds of the run at that offset. Parked state on the textarea:

```
[6,9)   'one'    {'bg-color': '65535,0,0', 'underline': 'single'}   (authored #ffe066 + underline)
[14,19) 'three'  {'bg-color': '0,0,65535'}                          (authored #0000ff)
[20,24) 'four'   {'weight': '700', 'bg-color': '0,65535,0'}         (authored #00ff00 + bold)
[25,29) 'five'   {'underline': 'single'}                            (underline only)
[30,33) 'six'    {'bg-color': '65535,0,0'}                          (authored #ffe066, no underline)
[34,39) 'seven'  {'bg-color': '65535,0,0'}                          (authored #ff0000)
[40,45) 'eight'  {'bg-color': '0,0,0'}                              (authored #808080)
```

Trap one: **the colour value is wrong on a GtkTextView.** `#ffe066` and
`#ff0000` are indistinguishable, and `#808080` reads as black. The pattern fits
a truncate-then-scale conversion (each channel `(int)c * 65535` rather than
`(int)(c * 65535)`), so only 0.0 and 1.0 channels survive. The identical colour
on the GtkEntry came back exact (`65535,57568,26214`), so the defect is in the
text view's arm. An assertion must key on the presence of `bg-color` (and on
`underline`, which is reported correctly), never on the value.

Trap two: **enumeration is one D-Bus call per unattributed character.** For
offsets not covered by a tag, GTK returns the empty range `(0,0)`, so a walker
cannot skip forward and has to probe every offset. Measured: a 54-char buffer
with 7 tagged ranges takes 32 calls and 4.8ms; an untagged 19199-char buffer hit
the 300-call cap at 46ms. That is fine for scene-sized text and useless for a
document. The cheaper `GetAttributes` method does not help on a text view at
all: it answers `[0, 2147483647)` with an empty attribute set, one call. On the
**entry** both methods behave properly, returning three runs
(`[0,6)`, `[6,11)` with the exact colour, `[11,17)`) in three calls.

The workable shape for a leg: assert the declared ranges by probing their
boundaries (`GetAttributeRun(start)` must return exactly `[start,end)` carrying
`bg-color`), and for "nothing else is highlighted" walk the buffer, which
scenes can afford.

Trap three, and it is a crash: **`GetAttributeValue` (the deprecated point
getter, `Atspi.Text.get_text_attribute_value`) SIGSEGVs the app.** Reproduced in
two independent runs on a GtkTextView node, once with the reader mid-scan and
once with the call isolated at the end; the app dies and every later read
answers "The application no longer exists". kaya's reader must never call it.
Worth reporting upstream along with the colour bug.

### REVEAL: readable through extents

`GetRangeExtents(start, end, WINDOW)` compared against the node's own
`Component.GetExtents(WINDOW)`. Measured on the scrolled shape B, parked with
line 350 revealed:

```
widget_extents WINDOW=(0,104,240,96)
extents(0,5)        '000 t' WINDOW=(0,-5456,8,16)  inside_widget=False
extents(16800,16805)'350 t' WINDOW=(0,144,8,16)    inside_widget=True
```

The arithmetic is consistent (`extents.y = widget.y + buffer_y - scroll_offset`),
so "the range is revealed" is exactly "its extents lie inside the widget's
extents". That is a real assertion with a positive and a negative case.

Two limits. On the unscrolled shapes the answer is vacuously true, because the
widget box IS the whole buffer (node #2: widget extents 6400px tall, every
range inside it) which is another way of saying kaya's textarea has no viewport
today. And on the **entry**, `GetRangeExtents` and `GetCharacterExtents` both
fail outright (`atspi_error: (1)`), so there is no out-of-process geometry for
an entry at all. If entry reveal ever has to be assertable on linux it will
need an in-process read, and there is nothing to read: GtkEntry publishes no
scroll offset.

### If an in-process read is preferred

Everything above is also available on the main thread without the bus:
`selection_bounds()`, `tag_ranges` via `TextIter::forward_to_tag_toggle`, and
`iter_location()` against `visible_rect()`. That is cheaper and exact, but it
reads kaya's own writes back, which is the reason gtk.rs:6843 gives for going
over the bus in the first place. The choice should match whatever the milestone
decides an assertion is FOR: if it is "the app declared it", read in-process; if
it is "a screen reader can see it", read the bus.

## 7. Cost summary for the GTK arm

- HIGHLIGHT, textarea: small. One `GtkTextTag` per declared style, created once
  and kept in the buffer's tag table; a re-declare is `remove_all_tags` plus one
  `apply_tag` per range. No interaction with the existing `changed` machinery.
- HIGHLIGHT, entry: possible via pango attributes, with a byte-offset
  conversion at the boundary and a re-declare after every edit. The
  character/byte asymmetry against `select_region` on the same widget is a trap
  worth a helper and a test.
- SELECT: small, plus a mandatory idempotence guard for IME.
- REVEAL: needs the textarea rebuilt around a `GtkScrolledWindow`, with knock-on
  effects on layout, on `NativeWidget`, and on ScrollPane ordinals in the
  accessibility tree. No entry story.
- Observability: no new dependency, and the reader shape already exists at
  gtk.rs:7058. Needs a `Text`-interface read alongside the current name read,
  and must avoid `GetAttributeValue`.

## 8. Reproducing

```
bash scratchpad/run.sh (gone)      > out.txt   # in-process battery + AT-SPI reader
bash scratchpad/ime-run.sh (gone)  > ime.txt   # composition, needs the intl layout
```

Both build a cargo example of `crates/kaya` inside the `kaya-linux` image so the
probe links the same `gtk4` the backend does. The `[[example]]` stanza is
appended to crates/kaya/Cargo.toml for the length of the run and restored by a
trap; the probe sources live outside the repo.

## 9. Cleanup, proven

- Containers: `docker ps -a` lists none. Every run used `--rm`, and both the
  Xvfb servers and the at-spi/dbus launchers lived and died inside those
  containers.
- Host processes: `ps -Ao pid,etime,pcpu,command | grep -iE
  "rangeprobe|imeprobe|xvfb|at-spi|dbus-launch"` matches nothing.
- Repo: `git status --porcelain` and `git diff --stat` are both empty. The
  temporary `[[example]]` stanzas are gone from crates/kaya/Cargo.toml
  (`grep -c "rangeprobe\|imeprobe"` is 0).
- Disk: the two probe binaries (58MB each, plus incremental and fingerprint
  state) were deleted from target-linux. `find target-linux -name "*rangeprobe*"
  -o -name "*imeprobe*"` returns 0 entries. target-linux measured 14200 MB
  before the probe, 14275 MB at its peak, and **14125 MB after cleanup**.
- Scratchpad: this arm's files total about 250 KB (probe sources, five run
  logs, this report). The `rangeprobe/` directory in the same scratchpad
  belongs to the windows arm and was left alone.
