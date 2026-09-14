# The heading-return probe — the GTK lane (2026-09-14)

What a Return keystroke does to a heading paragraph, measured three ways on
the linux lane: (A) through kaya's own arm, (B) through a bare GtkTextView
with no kaya rule in the way, (C) against the platform's reference editor.
The question being ruled: at the END of a heading paragraph, should Return
open a paragraph that is still a heading (kaya's one inheritance rule today)
or a normal one (what editors do)?

Everything below ran in the lane's own container (`kaya-linux:latest`,
`docker run --rm`) on BOTH protocols, x11 under Xvfb and wayland under
headless sway — the lane's own two sessions.

## 0. The runner's Return key (the part of the charge that was a code change)

`crates/kaya/src/gtk.rs`, `Stage::type_text`. Contract point 6 now admits
`\n`, and this lane had to deliver it as a real Return keystroke.

MEASURED FIRST, on the unmodified arm, with `type "\nx"`:

| protocol | what landed |
| --- | --- |
| x11 (`xdotool type --delay 0 "\nx"`) | **only the `x`** |
| wayland (`wtype -d 1 "\nx"`) | a newline AND the `x`, but as TEXT |

The x11 miss printed itself, through contract point 4's own landing check —
the guard that was already there, and the reason this was a measurement and
not a guess:

```
KAYA_UNDO_TRACE: type "\nx" never landed: the field holds "Héllo world\nSecond linex",
  expected "Héllo world\nSecond line\nx" after xdotool reported success;
  toplevels: ["richtext"(visible=true active=true focus=GtkTextView)];
  x focus window: "richtext"; this pid's visible x windows: [6291460]
```

The wayland half was not a Return either: `wtype` maps a codepoint to a
keysym with `xkb_utf32_to_keysym`, and U+000A comes back as `Linefeed`
(0xff0a), which GTK inserts as a character. A `GtkTextView` cannot tell the
two apart; a `GtkEntry` or any `activate` handler can.

THE CHANGE: the text is cut at every newline, and each tool's own key
command carries the Return inside the ONE invocation the letters ride —
`xdotool … key Return type --args 1 --delay 0 <line>` and
`wtype … -k Return -s 10 -d 1 <line>`. Two details are measured, not
assumed:

- **`--args 1` or the chain ends there.** A bare `xdotool type` swallows
  every remaining argument. Proven in the image: `xdotool type --delay 0 abc
  getdisplaygeometry` prints nothing, `xdotool type --args 1 --delay 0 abc
  getdisplaygeometry` prints `1280 1024`. Without it a following
  `key Return` would be typed as the words "key Return".
- **Every line is checked for a leading `-`**, not just the first: the assert
  that stops a payload being read as an option now runs per line.

PROOF THAT IT IS THE RETURN KEY, not a newline character: the B probe below
logs every key-press it receives, and both protocols report
`keyval='Return' (0xff0d)`.

GUARD (CLAUDE.md's "every change names its guard"): contract point 4's
landing check is the wall, and it is on the path nobody can avoid — every
`type` on this backend compares the field against `before + text` and prints
`KAYA_UNDO_TRACE: type … never landed: the field holds …`. It is what caught
the dropped newline above on the first run, and it is what would catch a
chain that started typing the word "key". No shared scene types a newline
yet, so the scene is not a wall here until the ruling lands one.

Gates after the change: `nix develop -c tools/check-gtk.py` **rc 0** (both
feature configurations compile in the container, 609 unit tests, the layout
census and its watched negatives); the shared `tools/scenes/richtext.steps`
**PASS on x11 and on wayland**; the whole linux lane re-run (§4).

## 1. A — kaya's arm today

The guest is `guests/rust/richtext.rs` (`KAYA_SELFTEST=richtext`), driven by
hand with `KAYA_SELFTEST_SCRIPT`. The document is
`"Héllo world\nSecond line"`; byte 12 is the newline, so the second
paragraph is bytes 13..24.

### A1 — Return at the END of the heading, then a letter

```
click button#0
expect_runs textarea#0 "0:6 bold|7:12 link=https://kaya.dev|13:24 block=heading2"
format textarea#0 13:24 block=heading1
expect_runs textarea#0 "0:6 bold|7:12 link=https://kaya.dev|13:24 block=heading1"
click button#5
expect_focused textarea#0
type "\nx"
expect_runs textarea#0 "?"
```

The deliberately wrong expectation, on BOTH protocols, byte for byte:

```
KAYA_SELFTEST: FAILED (runs "0:6 bold|7:12 link=https://kaya.dev|13:26 block=heading1", wanted "?")
KAYA_HARNESS: step-failed runs "0:6 bold|7:12 link=https://kaya.dev|13:26 block=heading1", wanted "?"
```

**The heading run grew from 13:24 to 13:26** — it swallowed the newline and
the new paragraph's only character. THE NEW PARAGRAPH IS A HEADING.

THE WIDGET AGREES WITH THE CORE. `Stage::rich_runs` reads the GtkTextView's
own tags beside the core's mirror and would have answered
`runs "<core>" — but the widget holds "<widget>"`. It did not, on any
reading in this record: every sentence here is one string, so GTK's buffer
carries `kaya-rich-block-heading1` over exactly the same 13..26.

AND THAT AGREEMENT IS KAYA'S DOING, not the toolkit's. B below shows a bare
GtkTextView dropping the tag at exactly this position; the arm's
`inherit_rich_tags` re-states it over the inserted range. So on GTK the
"new paragraph is a heading" behaviour is a line of kaya's, and the proposed
exception is that line not running for `block` at a paragraph's end.

### A2 — the Return's own edit record

Same script with `type "\n"` and `expect_edit textarea#0 "?"`:

```
KAYA_SELFTEST: FAILED (edit "24:24 <\n> user [0:1 block=heading1]", wanted "?")
```

### A3 — the letter's edit record, after the Return

Same script with `type "\nx"` and `expect_edit textarea#0 "?"`:

```
KAYA_SELFTEST: FAILED (edit "25:25 <x> user [0:1 block=heading1]", wanted "?")
```

So both the newline and the first character of the new paragraph are
published to the app carrying `block=heading1`. Identical on x11 and
wayland.

### A4 — the mid-paragraph case, as the charge spells it

```
format textarea#0 16:16 bold
type "\n"
```

```
KAYA_SELFTEST: FAILED (runs "0:6 bold|7:12 link=https://kaya.dev|13:25 block=heading1|24:25 bold", wanted "?")
```

READ THIS ONE CAREFULLY: it is NOT a mid-paragraph split. `type`'s contract
point 3 says the verb APPENDS — this backend sends `Ctrl+End` down the same
input stream ahead of the characters — so the caret the collapsed format put
at byte 16 is back at the end before the Return arrives. The `24:25 bold` is
the pending attribute that collapsed format armed, riding the typed newline.
The harness `type` verb cannot drive a mid-paragraph keystroke on ANY
backend as the contract stands.

### A5/A6/A7 — the mid-paragraph split, driven for real

To reach it the Return is injected from OUTSIDE the process while the scene
sits in `settle`, so nothing moves the caret: the guest runs
`format textarea#0 16:16 bold` (the caret to byte 16), then
`format textarea#0 16:16 bold off` (so no pending attribute rides the
keystroke), then `settle 6000`, and the session's own injector sends one
Return (`xdotool key Return` / `wtype -k Return`).

```
A6  KAYA_SELFTEST: FAILED (runs "0:6 bold|7:12 link=https://kaya.dev|13:25 block=heading1", wanted "?")
A7  KAYA_SELFTEST: FAILED (edit "16:16 <\n> user [0:1 block=heading1]", wanted "?")
A5 (the pending bold left armed, for comparison)
    KAYA_SELFTEST: FAILED (runs "0:6 bold|7:12 link=https://kaya.dev|13:25 block=heading1|16:17 bold", wanted "?")
```

**BOTH HALVES STAY HEADINGS**, as ONE run: 13:24 became 13:25, one
`block=heading1` covering `"Sec\nond line"`. Identical on x11 and wayland.

## 2. B — the platform's own control, without kaya's rules

`tmp/richtext/return-probe/gtk/b_textview.py`: a bare `Gtk.TextView` over a
`Gtk.TextBuffer` holding the same two paragraphs, the second one under ONE
tag created with the display properties kaya's arm gives `block=heading1`
(`scale=1.6, weight=700` — gtk.rs `rich_tag`). python-gi in the lane image,
the way the 2026-09-11 GTK probe was written
(docs/measurements/richtext-gtk-2026-09-11/). The keystrokes come from the
SAME injection the arm uses, and every key-press the view receives is
printed.

### B1 — Return at the END of the tagged paragraph, then `x`

x11:

```
probe: BEFORE runs 0:12 (none) | 12:23 heading1
probe: xdotool key ctrl+End key Return type --args 1 --delay 0 x
probe: key-pressed keyval='Control_L' (0xffe3) keycode=37
probe: key-pressed keyval='<Control>End' (0xff57) keycode=115
probe: key-pressed keyval='Return' (0xff0d) keycode=36
probe: key-pressed keyval='x' (0x78) keycode=53
probe: AFTER text='Héllo world\nSecond line\nx'
probe: AFTER runs 0:12 (none) | 12:23 heading1 | 23:25 (none)
probe: line 2 first char 'x' tags=(none)
```

wayland, the same reading:

```
probe: wtype -P F24 -s 800 -p F24 -s 20 -M ctrl -k End -m ctrl -s 10 -k Return -s 10 -d 1 x
probe: key-pressed keyval='<Control>End' (0xff57) keycode=10
probe: key-pressed keyval='Return' (0xff0d) keycode=11
probe: key-pressed keyval='x' (0x78) keycode=12
probe: AFTER runs 0:12 (none) | 12:23 heading1 | 23:25 (none)
probe: line 2 first char 'x' tags=(none)
```

**THE BARE CONTROL DROPS THE TAG.** The new paragraph's first character
carries NO tags — and so does the newline before it. The tag ends at the
old end of the buffer and GTK does not extend a tag across its own end
toggle (the same mechanism the arm's `inherit_rich_tags` exists to work
around; docs/measurements/richtext-gtk-2026-09-11 P1.7).

So on GTK the proposed exception — Return at the end of a heading opens a
BODY paragraph — would work **WITH** the control: the arm would stop
re-stating the block tag over the inserted range, not strip something the
toolkit insisted on.

### B2 — Return in the MIDDLE of the tagged paragraph, then `x`

x11 and wayland, identical:

```
probe: AFTER text='Héllo world\nSec\nxond line'
probe: AFTER runs 0:12 (none) | 12:25 heading1
probe: line 1 first char 'S' tags=['heading1']
probe: line 2 first char 'x' tags=['heading1']
```

**THE BARE CONTROL KEEPS THE TAG ON BOTH HALVES** — the insertion point is
surrounded by the tag, so the newline and the letter inherit it. That is the
same answer kaya's arm gives (A6), and it is what every editor does too: a
split inside a heading leaves two headings.

The platform and kaya therefore disagree in exactly one place — the END of
the paragraph — which is precisely the position the ruling is about.

(One probe note worth keeping: the injector must NOT be run with a blocking
`subprocess.run` from a GLib timeout. Holding the main loop through wtype's
warm-up made every wayland key reach nothing, with the window focused and
the virtual keyboard present in `swaymsg -t get_seats`. `Popen` and let the
loop run.)

## 3. C — the reference editor on the platform: THERE IS NONE

The lane image carries no rich text editor. Measured, not recalled — inside
`kaya-linux:latest`:

```
for p in libreoffice lowriter abiword gedit gnome-text-editor kate \
         calligrawords pluma ted gtk4-demo gtk4-widget-factory; do
    command -v $p
done
(nothing)

dpkg -l | grep -iE 'gedit|libreoffice|abiword|gtk-4-examples|gnome-text'
(nothing)

ls /usr/share/applications
display-im7.q16.desktop  ocaml.desktop  python3.13.desktop
xdg-desktop-portal-gtk.desktop
```

The only editor binary in the image is `weston-editor`, Weston's demo text
client, which is PLAIN — it has no styling of any kind (`--help` offers
`--click-to-show` and `--preferred-language`), so it cannot answer the
question. GNOME's own Text Editor is plain too and would not have answered
it either; the platform's flagship rich editor is LibreOffice Writer, which
is not installed and is not in the Dockerfile
(`tools/linux/Dockerfile`). Adding one is a lane-image change outside this
charge.

**So the linux lane has no C reading.** What it does have is B, which is the
toolkit's own answer at the same position, and B says the toolkit drops the
style.

## 4. What was run, and what it cost

| run | result |
| --- | --- |
| `tools/check-gtk.py` (after the change) | **rc 0** — `check-gtk: OK` |
| `richtext.steps` on x11, the shared scene | `KAYA_SELFTEST: OK`, rc 0 |
| `richtext.steps` on wayland, the shared scene | `KAYA_SELFTEST: OK`, rc 0 |
| `tools/check-verbs.py` | rc 0 (104 verbs) |
| `tools/check-steps.py` | rc 0 |
| `tools/check-diagnostics.py` | rc 0 |
| `tools/check-doc-refs.py` | rc 0 |
| `tools/validate-linux.py`, the whole lane | **rc 0 — `run-suites: ALL PASS`**, 767 leg records, legs 284s |

The lane re-run matters because `type_text` is not the richtext scene's
alone: `editor`, `ranges`, `search` and `undo` are the other four scenes
that type, across every language suite. All of them are green on both
protocols in that run (`undo-rust`, `ranges-*` in eight languages,
`editor-go`, `search-*`, `richtext-rust`).

A last check on the chaining itself, since the x11 arm now issues TWO
`type` commands with a `key Return` between them — `type "p\nq"` on the
same heading:

```
x11      step-failed runs "0:6 bold|7:12 link=https://kaya.dev|13:27 block=heading1", wanted "?"
wayland  step-failed runs "0:6 bold|7:12 link=https://kaya.dev|13:27 block=heading1", wanted "?"
```

13:24 -> 13:27, three bytes, no landing complaint on either protocol.

## 5. The answer, in one line each

- **A (kaya today).** Return at the END of a heading opens a paragraph that
  IS the heading — `13:24 block=heading1` becomes `13:26`, and the app is
  told `edit "25:25 <x> user [0:1 block=heading1]"`; a mid-paragraph Return
  leaves both halves under one heading run, which is what an editor does.
- **B (the bare GtkTextView).** The toolkit DROPS the tag at the end
  (`23:25 (none)`) and KEEPS it mid-paragraph (`12:25 heading1`), so the
  proposed exception runs with the platform, not against it.
- **C (the reference editor).** None exists in the lane image; the only
  editor there is Weston's plain-text demo client.
