# GTK4 rich-text probes — measured 2026-09-11

Five probes for `docs/rich-text-plan.md` §3 (the unknowns), feeding **R6** (the
native-undo off switch), **R9** (the AX words a rich run may assert), **R4** (the
delta channel and `source`) and **R3** (links as a synthesized tier on GTK).

**Environment.** The linux lane's own container image, `kaya-linux`
(Debian trixie), run ephemerally:

```
docker run --rm -v <repo>:/work -v <probedir>:/probe -v <probedir>/out:/out kaya-linux bash -c '...'
Xvfb :79 -screen 0 1600x1000x24 &   export DISPLAY=:79 GDK_BACKEND=x11
eval "$(dbus-launch --sh-syntax)"
/usr/libexec/at-spi-bus-launcher --launch-immediately &   /usr/libexec/at-spi2-registryd &
export GTK_A11Y=atspi NO_AT_BRIDGE=0
```

| thing | version |
| --- | --- |
| GTK | **4.18.6** |
| libadwaita | 1.7.6 |
| PyGObject | 3.50.0 |
| Atspi typelib | 2.0 (at-spi2-core, bus launcher + registryd both present) |
| xdotool (apt-installed in the ephemeral container) | 3.20160805.1 |

Every probe builds kaya's textarea shape: an **editable `GtkTextView` inside a
`GtkScrolledWindow`**. Real input goes through **XTEST** (xdotool) against the
Xvfb server, so typing, pasting and clicking take the platform's own path.

Probe programs (all under the probe directory, outputs under `out/`):

| program | output | what it measures |
| --- | --- | --- |
| `p1b_undo_scope.py` | `out/p1b_undo_scope.txt` | 1 + 2 — undo scope and suppression |
| `p3_app.py` / `p3_reader.py` | `out/p3_atspi.txt`, `out/p3_inproc.txt` | 3 — AT-SPI attribute names per tag |
| `p3b_app.py` / `p3b_reader.py` | `out/p3b_atspi.txt` | 3 — colour/size units, custom names, boundaries |
| `p3c_app.py` / `p3c_reader.py` | `out/p3c_atspi.txt` | 3 — colour matrix + attribute-change events **with a positive control** |
| `p45_edits_links.py` | `out/p45.txt` | 4 + 5 — edit signals, byte offsets, links |
| `p4b_source.py` | `out/p4b.txt` | 4 — the `source` discriminator |
| `p6_final.py`, `p6b_margin.py` | `out/p6.txt`, `out/p6b.txt` | loose ends |

`p1_undo_scope.py` is the **discarded first draft** of probe 1, kept because its
defect is the finding: it measured the undo *depth* by undoing to the bottom and
redoing back, and that round trip is itself destructive to tags — so every tag
reading taken after it was an artefact of the instrument. `p1b` never undoes
except as the thing under test.

---

## 1. GTK's undo scope — does the history record `apply-tag` / `remove-tag`?

**No. Attribute changes are completely outside `GtkTextBuffer`'s undo history.**

Method: seed the buffer inside `begin_irreversible_action()`/`end_irreversible_action()`
so `can-undo` is **False** at the start. Then any transition to True is
unambiguous evidence that an entry was pushed.

```
P1.0  enable-undo default = True   max-undo-levels default = 200

P1.1  CONTROL — a plain insert, from an empty history
  seeded                 text='hello world'    bold=[]        can-undo=False can-redo=False
  after insert '!!'      text='hello world!!'  bold=[]        can-undo=True  can-redo=False
  after undo()           text='hello world'    bold=[]        can-undo=False can-redo=True
  after redo()           text='hello world!!'  bold=[]        can-undo=True  can-redo=False

P1.2  THE QUESTION — apply_tag inside a user action, from an EMPTY history
  seeded                 text='hello world'    bold=[]        can-undo=False can-redo=False
  after apply_tag 0-5    text='hello world'    bold=[(0, 5)]  can-undo=False can-redo=False
  >>> did apply-tag push an undo entry?  NO  (can-undo is still False)
  after undo()           text='hello world'    bold=[(0, 5)]  can-undo=False can-redo=False
  >>> is the tag gone after undo()?      NO — the tag SURVIVED; undo() had nothing to undo

P1.3  remove_tag, from an empty history
  after remove_tag       text='hello world'    bold=[]        can-undo=False
  >>> remove-tag pushed an entry? NO
```

`begin_user_action()`/`end_user_action()` around the tag change makes no
difference: the bracket groups *text* edits, and there is no text edit in it.

**The worse half — a tag is LOST across an undo/redo round trip.** A mixed user
action that inserts text *and* tags it undoes correctly (the run vanishes with
the text it covered) but **redo brings the text back plain**:

```
P1.4  MIXED — one user action that INSERTS text and tags it
  after mixed action     text='hello worldBOLD' bold=[(11, 15)]  can-undo=True
  after undo()           text='hello world'     bold=[]          can-redo=True
  after redo()           text='hello worldBOLD' bold=[]          <- the tag did NOT come back

P1.5  insert_with_tags — the tag rides the insert call itself
  after insert_with_tags text='hello worldXY'   bold=[(11, 13)]
  after undo()           text='hello world'     bold=[]
  after redo()           text='hello worldXY'   bold=[]          <- same
```

So GTK's native undo does not merely *ignore* formatting; used on a rich buffer
it **silently destroys it**. `GtkTextHistory` records the inserted string, not
the tags over it.

Two neighbouring facts the same probe measured, both load-bearing elsewhere:

- **Coalescing.** Consecutive single-character inserts collapse into **one** undo
  entry, and wrapping each character in its own `begin_user_action`/`end_user_action`
  **does not** split them (`P1.6`: after typing `abc`, the first `undo()` removes
  all three). A backend that assumed one bracket = one undo step would be wrong.
- **Tag gravity** (`P1.7`), which R1's "runs cover `inserted` only" has to state
  explicitly on GTK: an insert *inside* a run inherits the tag; an insert at
  **either** toggle — start or end — does not.

```
  bold run before: [(0, 5)]  text='hello world'
  insert at 2 (INSIDE the run):      bold=[(0, 7)] text='heZZllo world'
  insert at the run's END toggle:    bold=[(0, 7)] text='heZZlloE world'
  insert at the run's START toggle:  bold=[(1, 8)] text='SheZZlloE world'
```

---

## 2. Undo suppression — R6's off switch on Linux

**`enable-undo = FALSE` is a complete and clean off switch, and it is togglable
per widget at runtime without touching the buffer's content.**

```
P2 (p1b + p6.2)
  enable-undo FALSE: insert 'hello world'  -> can-undo=False can-redo=False
  enable-undo FALSE: apply_tag 0-5         -> bold=[(0,5)] can-undo=False
  enable-undo FALSE: buf.undo()            -> text unchanged, tag unchanged (a no-op)
  enable-undo FALSE: view.activate_action("text.undo") returned True, text unchanged
  enable-undo FALSE: REAL Ctrl+Z through XTEST:
      typed 'AB' -> text='AB' can-undo=False
      Ctrl+Z     -> text='AB'  events=[]          <- INERT, no signal at all
      tag applied, Ctrl+Z -> tag still there? True
```

The three routes — the programmatic `undo()`, the widget's own `text.undo`
action, and a real Ctrl+Z keystroke — are all inert. Note the action still
*returns True*; inertness is in the buffer, not in the action's enabled state, so
a backend must not read the action's return as a verdict.

**Runtime toggling** (`P2.1`):

```
  before toggle: text='keep me' bold=[(0, 4)] can-undo=True
  undo OFF:      text='keep me' bold=[(0, 4)] can-undo=False
  undo ON again: text='keep me' bold=[(0, 4)] can-undo=False
  >>> buffer content survives the toggle: YES ; history cleared by it: YES
  new edit after re-enable -> can-undo=True ; undo() reaches only that new edit
```

The buffer's text **and its tags** survive; only the history is discarded. That
is exactly the semantics `own_undo()` wants: flip it at any time, lose no
document.

Two adjacent knobs, for the record:

- `max-undo-levels` default is **200**, and **0 means unlimited, not off**
  (`P2.2`: with it set to 0, an insert still leaves `can-undo=True`). It is not
  an off switch — do not reach for GTK's analogue of WinUI's `UndoLimit 0`.
- `begin_irreversible_action()`/`end_irreversible_action()` **clears the whole
  history** (`P2.3`), which is what D7 already uses it for and is the right tool
  for `set_rich_text`.

---

## 3. AT-SPI text attributes — what a screen reader actually receives

Read over the real accessibility bus by a separate process (`p3_reader.py`),
exactly as a screen reader would. The in-process route is **not available**:
`GtkAccessibleText`'s getters are interface *vfuncs* with no public C wrapper, so
GI exposes nothing (`AttributeError: type object 'AccessibleText' has no
attribute 'get_attributes'`). The AT-SPI bus is the only read-back there is.

The accessible tree, and the interfaces on the text node:

```
  application  name='python3'            ifaces=Accessible
    frame        name='kaya-richtext-probe'  ifaces=Accessible,Action,Component
      scroll pane                             ifaces=Accessible,Action,Component
        text                                  ifaces=Accessible,Action,Component,EditableText,Text
```

The reader's call is `Atspi.Text.get_attribute_run(acc, offset, include_defaults)`.
(`get_attributes` does not exist under that name in this typelib; the surface is
`get_attribute_run`, `get_text_attributes`, `get_text_attribute_value`,
`get_default_attributes`, `get_string_at_offset`, …) With
`include_defaults=False` it answers **only what differs from the default**, plus
the run's own character range — which is precisely the shape a read-back check
wants.

### The vocabulary, tag by tag (offsets are AT-SPI **character** offsets)

| kaya run | GtkTextTag property set | AT-SPI attribute published |
| --- | --- | --- |
| `bold` | `weight=PANGO_WEIGHT_BOLD` | **`weight=700`** |
| `italic` | `style=PANGO_STYLE_ITALIC` | **`style=italic`** |
| `underline` | `underline=PANGO_UNDERLINE_SINGLE` | **`underline=single`** |
| `strike` | `strikethrough=True` | **`strikethrough=true`** |
| `code` (mono) | `family="Monospace"` | **`family-name=Monospace`** |
| heading, by scale | `scale=1.5, weight=BOLD` | **`scale=1.5, weight=700`** |
| heading, by points | `size-points=24.0, weight=BOLD` | **`size=24576, weight=700`** |
| `link` (synthesized) | `underline=SINGLE, foreground=…` | **`underline=single, fg-color=…`** — *no link attribute, no link role* |
| custom tag **name** only | `create_tag("kaya-link-7")`, no properties | **nothing — `[0,0) {}`** |
| `quote` (indent) | `left-margin=40, indent=0` | **`left-margin=40, indent=0`** |
| background | `background="#ffff00"` | **`bg-color=65535,65535,0`** |
| rise / justification / wrap / language | as named | `rise=5000`, `justification=center`, `wrap-mode=none`, `language=fr` |

The default set, for contrast (`get_default_attributes`):

```
bg-color=65535,65535,65535, bg-full-height=false, direction=ltr, editable=true,
family-name=IBM Plex Sans, fg-color=0,0,0, indent=0, invisible=false,
justification=left, language=c, left-margin=0, pixels-above-lines=0,
pixels-below-lines=0, pixels-inside-wrap=0, right-margin=0, rise=0, scale=1,
size=14, stretch=normal, strikethrough=false, style=normal, underline=none,
variant=normal, weight=400, wrap-mode=word
```

Ranges are reported correctly and adjacent runs are separated exactly at the
toggle (`p3b`, the BOUNDARY case, two abutting runs with no gap):

```
  BOUNDARY_A offset 101 -> [101,104) {fg-color=65535,0,0}
  BOUNDARY_A offset 103 -> [101,104) {fg-color=65535,0,0}
  BOUNDARY_A offset 104 -> [104,107) {style=italic, weight=700}
  BOUNDARY_B offset 107 -> [0,0) {}          <- past the run: the degenerate answer
```

An offset carrying nothing non-default answers the degenerate range `[0,0)` with
an empty set (with `include_defaults=True` it answers the whole buffer `[0,97)`
with the default set). A reader must not mistake `[0,0)` for "the run starts at 0".

### Three defects and one absence, all measured

**(a) There is no link and no heading anywhere.** `Hypertext` is **not** among
the text node's interfaces, `get_n_links` is unreachable, and no accessible in
the tree has a role containing `link`. AT-SPI's text attribute vocabulary has no
heading attribute either: a heading is `scale=1.5` or `size=24576` plus
`weight=700` and nothing more. **A custom tag name crosses as nothing at all** —
`kaya-link-7`, a tag whose only content is its name, produced an empty attribute
set, and the same tag applied *on top of* a visual link tag added nothing to that
run's attributes. So on Linux a screen reader cannot be told "this is a link" or
"this is a heading" through the text interface; only the visual consequences
cross.

**(b) `size` is published in two different units.** The default set says
`size=14` (points, from "IBM Plex Sans 14"), while a tag-set size is published
raw in **Pango units**: both `size_points=24.0` and `size=24*PANGO_SCALE`
answered **`size=24576`** (= 24 × 1024). A reader comparing a run's `size`
against the default's `size` is comparing points against Pango units.

**(c) Colour serialization is lossy — every non-pure channel is published as 0.**
The matrix (`p3c`), for both `fg-color` and `bg-color`:

```
  fg #ff0000   expected 65535,0,0            got {fg-color=65535,0,0}        OK
  fg #00ff00   expected 0,65535,0            got {fg-color=0,65535,0}        OK
  fg #0000ff   expected 0,0,65535            got {fg-color=0,0,65535}        OK
  fg #ffffff   expected 65535,65535,65535    got {fg-color=65535,65535,65535} OK
  fg #808080   expected 32896,32896,32896    got {fg-color=0,0,0}            WRONG
  fg #0066cc   expected 0,26214,52428        got {fg-color=0,0,0}            WRONG
  fg #123456   expected 4626,13364,22102     got {fg-color=0,0,0}            WRONG
  (bg-color behaves identically, same seven rows)
```

Only 0x00 and 0xff survive per channel. The pattern is integer truncation of a
float channel before scaling (0.5 → 0, 1.0 → 1 → 65535). Every realistic link
blue, every mid-grey, every brand tint is published to a screen reader as
**black**. GTK 4.18.6.

**(d) An attribute change emits no AT-SPI event.** Measured with a **positive
control**, because a listener nobody has seen fire proves nothing: the app
inserted text at t≈8s, applied a bold tag at t≈12s and deleted text at t≈16s,
while the reader listened on `object:text-attributes-changed`,
`object:attributes-changed`, `object:text-changed` and `object:property-change`.

```
    EVENT object:text-changed:insert   d1=138 d2=9 data='-INSERTED'
    EVENT object:text-changed:delete   d1=127 d2=3 data='CON'
  total events: 2
  object:text-changed*           seen (POSITIVE CONTROL): YES
  object:text-attributes-changed seen (THE TEST):         NO
```

The listener works. Applying a tag emits nothing: a screen reader is never told
that a range became bold, and only learns it by re-reading.

---

## 4. Edit reporting — corroboration for R4

**GTK hands over a complete, correctly addressed delta on every path, and the
payload is already in kaya's unit.**

**The conversion.** `GtkTextIter` offsets count **characters** (Unicode code
points). kaya's unit is **UTF-8 bytes**. The probe converts by encoding the
prefix:

```python
def byte_off(buf, it):
    return len(buf.get_text(buf.get_start_iter(), it, True).encode("utf-8"))
```

GTK also offers `GtkTextIter.get_line_index()` — bytes **within the line** —
directly; on a single-line buffer the two agree exactly, which the probe prints
side by side as a check. `insert-text`'s `len` argument is **already the UTF-8
byte length** of the inserted text, so only the *position* ever needs converting.

Multi-byte, programmatic (`4.2`):

```
insert-text  char_off=5 BYTE_off=5 line=0 line_index(bytes)=5
             text=' héllo 👋' len_arg=12 utf8_len=12 chars=8
insert-text(after) iter now at char_off=13 BYTE_off=17
text='Hello héllo 👋'   char_count=13 (GtkTextIter unit)   utf8_bytes=17 (kaya unit)
per-char widths: [(' ',1),('h',1),('é',2),('l',1),('l',1),('o',1),(' ',1),('👋',4)]
end iter: get_offset()=13  byte_off()=17  get_line_index()=17
```

`👋` is **one** GtkTextIter character and **four** UTF-8 bytes — the 13-vs-17
divergence is the whole conversion story.

Delete carries the removed text, readable in a *before* handler (`4.3`):

```
delete-range  chars[11,13) BYTES[12,17) removed=' 👋' utf8_len=5
delete-range(after) chars[11,11) (deleted text NOT readable here)
```

Real typing through XTEST, one bracketed event per character (`4.4`):

```
begin-user-action
insert-text  char_off=11 BYTE_off=12 text='a' len_arg=1 utf8_len=1
end-user-action        (×3 for 'abc')
```

Real BackSpace (`4.6`) gives `delete-range chars[13,14) BYTES[14,15) removed='c'`.

**Paste** through a real Ctrl+V, with a multi-byte payload, arrives as **one**
bracketed `insert-text` carrying every byte (`4.7`):

```
clipboard payload='PASTE-é👋-END' (16 bytes)
begin-user-action
insert-text  char_off=13 BYTE_off=14 text='PASTE-é👋-END' len_arg=16 utf8_len=16 chars=12
end-user-action
```

### `apply-tag` fires for a programmatic tag, and for nothing else

```
(a) PROGRAMMATIC apply_tag [0,5)   -> signals: ['apply-tag']            (and NO 'changed')
(b) PROGRAMMATIC insert INSIDE the bold run
                                   -> signals: ['insert-text','changed','insert-text(after)']
                                   -> the text inherited bold with NO apply-tag signal
(c) REAL TYPING inside the bold run
                                   -> signals: ['begin-user-action','insert-text','changed',
                                                'insert-text(after)','end-user-action']
                                   -> typed char has bold? True     (again, no apply-tag)
(d) remove_tag                     -> signals: ['remove-tag']
(e) does 'changed' fire for a tag change? NO
```

So `apply-tag`/`remove-tag` report **explicit** tag calls only. Text that
*inherits* formatting by being typed inside a run produces no attribute signal at
all — the run simply grows. A backend that derived the document's runs from
`apply-tag` alone would lose every inherited character. (This is another face of
the R1 rule: the runs travelling with `text_edited` must be computed from the
buffer's state after the insert, not from the tag signals.)

Also note `changed` fires for text edits but **not** for tag edits, so it cannot
serve as the rich-text "something moved" notification.

### `source`: what distinguishes a native undo from typing

Measured as its own table (`p4b`), because R4's `source` and `docs/undo-plan.md`
A6 turn on it:

```
  SOURCE DISCRIMINATION TABLE (does the edit arrive inside begin/end-user-action?)
    real typing (XTEST)              BRACKETED
    real BackSpace (XTEST)           BRACKETED
    real paste Ctrl+V (XTEST)        BRACKETED
    programmatic buffer.insert       bare
    programmatic buffer.delete       bare
    NATIVE UNDO Ctrl+Z (XTEST)       bare
    NATIVE REDO Ctrl+Shift+Z         bare
    buffer.undo() programmatic       bare
    buffer.redo() programmatic       bare
```

A native undo arrives as an **ordinary `delete-range` / `insert-text`** with no
marker of its own:

```
  text before='HeZQZllo hélloab…'   text after='HeZZllo hélloab…'
  signals seen: ['delete-range','changed','delete-range(after)']
```

The `begin-user-action` bracket is the only discriminator, and it separates
**direct user input** from everything else — it does *not* separate an undo from
a backend's own programmatic write. A backend that knows when it is writing can
therefore derive `source=native_undo` (bare edit, and kaya did not cause it), but
**nothing distinguishes undo from redo** in the signal stream.

---

## 5. Links as a synthesized tier

**Measured working end to end**: a tag, a side table keyed by tag, a
`GtkGestureClick` on the view, and a real XTEST click.

The transform, each step printed with its numbers (`p45` §5):

```
text='plain words CLICKME and plain tail'
link tag covers chars [12,19) = BYTES [12,19); side table holds 'https://example.invalid/kaya'
get_iter_location(char 15)               = buffer rect x=102 y=0 w=9 h=19
buffer_to_window_coords(WIDGET, ...)     = widget (106,9)
view.compute_point(window)               = ok=True (106,9)   [widget->toplevel offset]

--- 5.1 REAL CLICK on the link ---
   hover cursor now: 'pointer'
   CLICK widget(106,9) -> buffer(106,9) -> over_text=True char_off=15 BYTE_off=15 tags=['kaya-link-0']
   >>> LINK ACTIVATED: tag='kaya-link-0' url=https://example.invalid/kaya

--- 5.2 REAL CLICK on plain text (must NOT activate) ---
   hover cursor now: 'text'
   CLICK widget(16,9) -> buffer(16,9) -> over_text=True char_off=2 BYTE_off=2 tags=[]
   >>> not a link (no activation)
```

**The gesture and the coordinate transform, stated:**

1. `GtkGestureClick` (`set_button(1)`, `released`) added to the **GtkTextView**
   with `add_controller`. Its `(x, y)` arrive in the **widget's** coordinate
   space — the view's, not the scrolled window's and not the toplevel's.
2. `gtk_text_view_window_to_buffer_coords(view, GTK_TEXT_WINDOW_WIDGET, x, y)`
   → **buffer** coordinates. This is the step that absorbs the scroll offset and
   the view's border/margin windows; it is not optional even when the numbers
   happen to match at scroll 0 (they did here: widget (106,9) → buffer (106,9)).
3. `gtk_text_view_get_iter_at_location(view, &iter, bx, by)` → `(over_text, iter)`.
4. `gtk_text_iter_has_tag(iter, link_tag)` — or `get_tags()` and a lookup in the
   **side table** `tag → url`, which is where the URL lives since GtkTextTag has
   no link property.

Hover is the same transform on a `GtkEventControllerMotion`, ending in
`gtk_widget_set_cursor_from_name(view, "pointer" | "text")` — measured switching
correctly on and off the link.

**The right-margin case, measured** (and it contradicted the inference this probe
was first written with):

```
text='go to LINKEND'  link covers chars [6,13) — the line's LAST word
  buffer x=2    -> over_text=True  char_off=0   has_link=False
  buffer x=60   -> over_text=True  char_off=9   has_link=True
  buffer x=100  -> over_text=False char_off=13  has_link=False
  buffer x=800  -> over_text=False char_off=13  has_link=False
```

A click past the end of a line answers `over_text=False` and returns the
**line-end** iter — which does **not** carry the link tag even when the link ends
the line, because a tag's end toggle is **exclusive** (the same right gravity
probe 1.7 measured). So on GTK the right margin cannot activate a link by
accident. Honour `over_text` for caret placement; it is not a safety check.

---

## The reading, one paragraph per point

**1 — Undo scope.** GTK's undo history is a text history and nothing else:
`apply-tag` and `remove-tag` push no entry at all (`can-undo` stays False across
both, from a provably empty history), and a tag change is therefore not merely
un-undoable but invisible to the stack. Worse for a rich document, a tag is
*destroyed* by an undo/redo round trip — undoing an insert removes the text and
its runs, and redoing brings the text back plain, so a user who types a bold
word, undoes and redoes has silently lost the bold. That settles §3.1 the way the
survey guessed but harder than it guessed: the native tier is not just incomplete
for rich text on Linux, it is actively lossy, and **R6's off switch is the only
honest state for a rich textarea on GTK** — a split where typing stays native and
attributes go core-tier would still lose runs on every undo of a mixed edit.

**2 — Undo suppression.** `enable-undo = FALSE` is a complete off switch on all
three routes measured — the programmatic `undo()`, the widget's own `text.undo`
action, and a real Ctrl+Z keystroke — and it suppresses nothing else: the text
and its tags are untouched. It is togglable per widget at runtime with the
document intact; the price is that the flip **clears the history** in both
directions, so `own_undo()` must be a declaration-time decision if the app cares
about the existing stack, not a toggle a toolbar flips. Two nearby knobs are
traps: `max-undo-levels = 0` means *unlimited*, not off, and the `text.undo`
action returns True whether or not it did anything. `enable-undo` is the right
and only lever, and R6's spelling holds on Linux exactly as written.

**3 — AT-SPI attributes.** The five inline traits all cross cleanly and with
stable, readable names — `weight=700`, `style=italic`, `underline=single`,
`strikethrough=true`, `family-name=Monospace` — each with the run's own character
range, so a per-backend read-back check in `check-verbs`' shape is
straightforward. Everything above the inline vocabulary does not cross: there is
no `Hypertext` interface, no `link` role, no heading attribute, and **a custom
tag name crosses as literally nothing**, so a heading reaches a screen reader as
`scale=1.5, weight=700` and a link as `underline=single` plus a colour. This is
the decisive constraint for **R9**: GTK cannot answer the words `heading` or
`link`, so those two cannot join the closed AX word set on the strength of Linux
— either they are minted only where all three harnesses can answer them, or GTK's
arm answers them from **kaya's own document** rather than from the platform, which
is what R9's "the harness reads the CORE's document" already says and is the
reading I would take. Three GTK 4.18.6 defects ride along: `size` is published in
points in the default set and in Pango units (24576 for 24pt) in a tag's,
non-pure colour channels are published as **0** (every link blue and mid-grey
reads as black), and an attribute change emits **no AT-SPI event** at all —
measured against a positive control that did fire, so the listener is known good.

**4 — Edit reporting.** GTK corroborates R4 completely and is the easiest of the
five platforms: `insert-text` carries the position and the text with `len`
**already in UTF-8 bytes**, `delete-range` carries both ends with the removed
text readable in a before-handler, and both are correct for multi-byte content
(`héllo 👋` is 8 characters and 12 bytes; the only conversion needed is the
*position*, `len(prefix.encode())`, with `get_line_index()` as GTK's own
byte-valued cross-check). Typing, BackSpace and a real Ctrl+V paste all arrive
through the same signals, the paste as a single event carrying all 16 bytes of a
multi-byte payload. `apply-tag` fires **only** for explicit tag calls and never
for text that inherits a run by being typed inside it, so runs must be read back
from the buffer rather than accumulated from tag signals. For `source`, the
`begin-user-action` bracket separates direct user input from everything else: a
native undo is a bare `delete-range`/`insert-text` with no marker, so a backend
that tracks its own writes can derive `native_undo`, but nothing tells undo from
redo.

**5 — Links.** The synthesized tier works exactly as the survey supposed, and the
whole mechanism is four calls: a `GtkGestureClick` on the view gives widget
coordinates, `window_to_buffer_coords(GTK_TEXT_WINDOW_WIDGET, …)` converts them
to buffer coordinates (absorbing scroll, which is why the step is mandatory even
when the numbers coincide at scroll 0), `get_iter_at_location` gives
`(over_text, iter)`, and `iter.has_tag(link)` plus a side table keyed by tag
yields the URL. A real XTEST click on the tagged word activated with the right
URL and a click on plain text did not; the hover cursor flips between `pointer`
and `text` through the same transform on a motion controller. The right-margin
case is safe by construction rather than by care — the line-end iter never
carries a link tag because a tag's end toggle is exclusive — so `over_text`
matters for caret placement, not for avoiding spurious activation.

---

## The two most important caveats

**1. GTK's native undo is lossy for rich text, not merely incomplete — so R6's
off switch is mandatory on Linux, not optional.** The plan's §3.1 asked whether
the history records tag changes; it does not, but the finding that actually
decides the arm is P1.4/P1.5: a tag applied in the *same user action* as the
insert it covers is gone after undo→redo, and the text returns plain with no
error anywhere. Any design that leaves the native tier on for a rich GTK textarea
therefore ships a silent formatting-loss bug on a keystroke every user presses.
Two adjacent traps make it worse: GTK **coalesces** consecutive character inserts
into one undo entry and a per-character `begin_user_action` bracket does *not*
split them, so one Ctrl+Z can revert a whole typed word's worth of runs; and
`max-undo-levels = 0` means unlimited, so reaching for it as an off switch leaves
undo fully on.

**2. Linux cannot say `heading` or `link` to a screen reader, and its colours are
wrong on the way out.** A custom tag name crosses AT-SPI as nothing at all, there
is no `Hypertext` interface and no heading attribute, so the words `heading` and
`link` must not be added to kaya's closed AX set on the strength of a GTK
measurement — the visual consequences (`scale`, `weight`, `underline`, a colour)
are all Linux exposes. And the colour it exposes is frequently wrong: in GTK
4.18.6 any channel that is not 0x00 or 0xff is published as 0 for both
`fg-color` and `bg-color`, so the ordinary link blue `#0066cc` reaches a screen
reader as `0,0,0` — do not build any assertion, on any lane, on an AT-SPI colour
value. A third, smaller one in the same family: a tag's `size` is published in
Pango units while the default `size` is in points, so the two are not comparable,
and no attribute change emits an AT-SPI event at all (measured against a control
that did fire), so a reader learns of a formatting change only by re-reading.

---

## Environment hygiene

- Every container was `docker run --rm`; all Xvfb, dbus, at-spi-bus-launcher and
  at-spi2-registryd processes lived **inside** those containers and exited with
  them. Nothing was started on the host.
- `apt-get install xdotool` (and `x11-xserver-utils` once) ran **inside the
  ephemeral containers only**; the `kaya-linux` image was not modified.
- No file in the kaya repository was read-write mounted for writing, edited or
  created. The repo was mounted at `/work` and only read.

## What this probe did NOT establish

- **IME / preedit.** The survey's claim that GTK's preedit is drawn by the view
  and never enters the buffer (so a composition commits as one `insert-text`) was
  not measured — the container has no input method engine.
- **Real non-ASCII typing.** XTEST delivered non-ASCII keystrokes to GDK as
  `keyval=0` on a scratch keycode (`p6.1`: the key event arrives, the keysym does
  not), an Xvfb keymap-propagation limitation rather than a GTK one. The
  multi-byte user-path evidence is therefore the **paste** in 4.7, which is a real
  user path and carried all 16 bytes correctly.
- **A real screen reader.** Orca was not run; the measurements are of what the
  AT-SPI bus publishes, which is what Orca reads, but not of what Orca *says*.
  §3.4 of the plan still wants that.
- **libadwaita.** Nothing in 1.7.6 changes any of the above; it adds no text
  view.
