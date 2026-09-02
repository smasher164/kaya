# Clipboard — the executable plan

Status: COMPLETE 2026-08-04 — all five backends, all eight bindings,
the Android helper, the scene on every runner. docs/deferred.md's
Clipboard entry is struck with the closing record; the fan-out map is
docs/handoff-clipboard.md.

The design below was worked out 2026-08-01. It was ratified 2026-08-02
and now lives in DESIGN.md's "Clipboard" section; this file is the
working record behind it. Sequencing followed CLAUDE.md's
depth-then-breadth rule: protocol, one backend, one binding, the scene,
green on mac, only then fan out.

Nothing here was settled except §0 when this was written, which records
the decisions already made and the reasoning that produced them.
Several of those decisions
REPLACED an earlier answer in the same conversation, and the earlier
answer is written down beside each one, because every one of them is
the answer a fresh session would reach for first.

## §0 — the decisions, and what they replaced

### The clipboard is not a string, and every host agrees

One clip, offered in several representations, consumer picks the
richest it understands. That is the model on all six targets:

- macOS/iOS: a pasteboard item is a map of UTI to data
- Windows: a `DataPackage` carries several formats
- Android: `ClipData`, with a `ClipDescription` listing MIME types
- X11: the owner advertises TARGETS, the requester converts to one
- Wayland: `wl_data_source.offer(mime)` repeatedly, the receiver picks
  one and reads an fd

X11 and Wayland are the most literal expression of it, not the odd ones
out. So a text-only surface is not a simplification of the clipboard;
it is a misstatement of it, and it would make kaya apps second class in
every cross-app paste. Copy out of a kaya editor into Pages and you
would get flat text where every other app gives formatting.

REJECTED: staging a text-only surface first and rich content later. It
is not a subset, it is a different shape, and the rich model does not
extend from it. There are no users, so staging buys nothing and costs a
rewrite of every guest.

### The representation set is CLOSED, with one escape hatch

`text`, `html`, `image`, `files`, plus `custom(id, bytes)`.

REJECTED: an open map of MIME type to bytes. The lowering per
representation is not a rename, it is real work that only kaya can
absorb, and an open map pushes all of it onto guest authors in eight
languages:

- **HTML on Windows is not `text/html` bytes.** `CF_HTML` mandates a
  header carrying byte offsets (`Version:`, `StartHTML:`, `EndHTML:`,
  `StartFragment:`, `EndFragment:`). Bytes tagged `text/html` handed
  over verbatim paste as garbage.
- **Images on Android cannot be bytes at all.** `ClipData` carries a
  `content://` URI, so the backend has to stand up a provider. macOS
  takes the bytes inline as `NSPasteboardTypePNG`.
- **Files are three unrelated encodings.** `CF_HDROP` is a `DROPFILES`
  struct with double-NUL-terminated wide strings; X11 and Wayland want
  `text/uri-list`; macOS wants file URLs.

A closed set is also what lets a gate check that all four backends
handle every case, the way check-universal-props already does for the
a11y props per widget kind.

`custom` is the honest escape hatch: apps copy their own native format
so it round-trips losslessly within the app, every platform supports
that (custom UTI, custom format id, custom MIME), and kaya's promise is
narrow — it round-trips, and kaya does nothing clever with it.

### Files on the clipboard are the file dialog's capability

`text/uri-list`, `CF_HDROP`, `public.file-url`, `ClipData.newUri` are
all "a reference to a file the receiver may open". That is exactly what
`pick_files` already returns and what `kaya_open_picked` already
redeems. Copying a file and picking a file are the same currency, so a
picked file goes straight onto the clipboard and a pasted one opens
with the call that already exists. One capability, two doors, and the
bytes never move through kaya in either.

### COPY TAKES A RECORD. PASTE RETURNS A SUM.

You offer many, you receive one, and the shapes should say so.

REPLACED: a list of representation values for copy, with a
construction-time panic on duplicates. That panic was a runtime check
standing in for a shape. A record of optional fields makes "at most one
per kind" STRUCTURAL, which is the ordering CLAUDE.md's invariant 3
already states: types over generation over runtime checks. `custom` is
the one field that holds a map, since several custom formats are
legitimate.

What the record costs is ORDER, and the wire does care (macOS type
order is preference order, X11 TARGETS order is a hint). It costs
nothing real: the ordering is a property of the KIND, not of the app's
intent. Files, then image, then html, then text. kaya defines it once,
which is more uniform than eight bindings' worth of authors each
getting it right or wrong.

The accepts declaration below is the same shape for the same reason: a
set of kinds, so you structurally cannot declare `text` twice.

### The author spells out the alternatives; kaya derives nothing

`copy` offers what the app puts in it. kaya does NOT synthesise
`text/plain` from `html`: whether list bullets survive, whether block
elements become newlines, what happens to a table, are rendering
decisions the app owns. A bad auto-derivation is worse than none,
because it silently degrades every paste into a plain-text field.

ONE EXCEPTION, where there is exactly one correct answer and the
platforms expect it: `files` also gets a text rendition of the paths.
Pasting a file into a text field and getting the path is universal
convention, and unlike html-to-text there is no judgment in it.

### Reading the clipboard is a REQUEST, not a property read

Every platform is converging on "reading is a user-authorised action":

- **iOS 16+** prompts when an app programmatically reads content FROM
  ANOTHER APP. Reading content the app itself put there does not
  prompt. The exemptions are the system paste affordances: the Paste
  menu command, the hardware shortcut, and `UIPasteControl`.
- **macOS** is heading the same way (a warning on access without user
  interaction).
- **Android 10+** returns null from `getPrimaryClip` unless the app has
  focus or is the default IME. Not an error, just empty.
- **Wayland** only delivers the offer to a client WITH KEYBOARD FOCUS,
  by design.
- **X11** paste is an async round trip to whoever owns the selection.

So the answer may be empty for four different reasons and the guest
should not have to tell them apart. Empty covers denied, absent, and
nothing-we-accept, exactly as an empty list already means cancel for a
file dialog.

### ACCEPTANCE IS PER-WIDGET, not app-global

REPLACED: an app-level signal of what the clipboard offers, which the
app would use to grey out Paste. That conflated two different facts. A
search field takes plain text; a rich editor takes images. Whether
Paste should be live is the INTERSECTION of what the clipboard offers
and what the focused target accepts.

The platforms already answer it per-target: macOS and iOS ask the
focused responder through `canPerformAction(#selector(paste:))`, and
Android's `setOnReceiveContentListener(view, mimeTypes, listener)`
takes the accepted MIME types as an argument ON THE VIEW.

So the widget declares what it accepts, and that one declaration does
three jobs: it drives enablement while the widget is focused, it
filters what can reach the widget's hook, and on Android it IS the
native registration.

kaya computes enablement itself rather than handing the app a signal to
compute it with. kaya knows what is focused, kaya knows what is
offered, the widget declared what it accepts; making the app track
focus to derive a boolean kaya already holds is busywork.

WHY THE FOCUS RESTRICTION IS NOT A PROBLEM HERE, which is worth writing
down because it looks like one: Wayland and Android only let you know
while you are focused, and you only NEED to know while you are focused,
because that is the only time your menu can be opened. The restriction
and the use case are the same shape.

### GESTURES ARE COMMANDS. CONTENT IS DATA.

The layer split, and the reason it is not sugar:

**kaya has no selection API, so an app cannot construct the payload for
"copy the selected text" itself.** Only the widget knows what is
selected. Copy of a selection is therefore necessarily a command, and
Paste is its mirror. Cut, Copy and Paste join the standard command
vocabulary, lower to the native ones, act on the focused widget, and
configure their own enablement.

The data layer is for overriding that default and for targets that have
no native behaviour.

### `paste(accepting:)` was misnamed, and the name was the harm

REPLACED: a programmatic `paste(accepting:, on_result:)` presented as
the way to paste. It was not broken — it would have worked — but an
editor author reaches for the thing called "paste", and on iOS that is
a permission prompt for content the hook would have delivered for free.

It was covering two unrelated operations:

- "Paste into the focused thing", which should DISPATCH the platform's
  paste and land in the same hook. Same callback, different trigger.
  This needs no clipboard API at all: it is invoking the standard Paste
  command. Whether kaya can invoke a standard command programmatically
  is a question for the COMMAND vocabulary, and if it cannot, that is a
  gap there rather than something to paper over here.
- Reading the clipboard outside any paste gesture: detect a URL and
  offer to open it, import-from-clipboard, a password manager. There is
  no insertion target and no paste happened.

Only the second is a genuine read. It keeps the API under an honest
name, and its documentation says plainly that it may prompt on iOS and
may be empty without focus, because it is not a paste gesture.

### Paste and drop are the same event

Android built `onReceiveContent` as a SINGLE API for content arriving
from paste, from drag and drop, and from autofill. Wayland agrees
structurally: both are `wl_data_offer`. macOS and Windows use one clip
model for both.

So `on_paste` is the same payload arriving through a third trigger when
drag and drop lands later, not a second data model. That is a good sign
about the closed sum, and a reason not to shortcut it now.

### Deliberately out

- **Lazy rendering.** Every platform lets a producer defer rendering
  until asked. The reason large data needs it is images and files, and
  file references already solve that by never moving bytes. What it
  would add is a callback the platform can block on, arriving on the
  app thread at a moment kaya does not control, with a hard interaction
  with both the persistence handoff (which forces materialisation
  anyway) and the stall watchdog. That is a lot of machinery to avoid
  materialising a PNG the app already holds.
- **Multiple items per clip.** iOS, macOS and Android support it;
  Windows, X11 and Wayland do not. So one clip, and "three files" lives
  INSIDE one representation, which is how `text/uri-list` and
  `CF_HDROP` already work and how multi-select already returns a list.
- **The X11/Wayland PRIMARY selection** (middle-click paste). No
  analogue on the other four targets, so it would be a Linux-only verb.

## §0b — the surface

- a copy record: `text`, `html`, `image`, `files`, `custom` map
- `accepts` per widget, a set of kinds; text widgets default to text
- `on_paste(clip)` — content arriving, one representation, the sum
- `on_copy() -> record` — the mirror, for targets with no native copy
- `copy(record)` — app-authored content, no gesture, never privileged
- `read_clipboard(accepting) -> sum` — the privileged read
- Cut, Copy, Paste as standard commands

A plain text editor writes NONE of this. It declares nothing, hooks
nothing, and gets working cut/copy/paste with the existing change
handler reporting the result, because kaya's text widgets already own
their text and report every edit.

## §0c — persistence, and the one honest carve-out

Three of five hosts need an explicit handoff or the content dies with
the process:

| host | who holds it | survives exit |
| --- | --- | --- |
| macOS, iOS | pasteboard server copies at once | yes |
| Android | system holds the ClipData | yes |
| Windows | the app, delayed rendering | only with `Clipboard.Flush()` |
| X11 | the app; paste is a live round trip | only via a clipboard manager |
| Wayland | the app, via `wl_data_source` | same |

Windows being in that group with X11 is the surprise. GTK4 already
handles the X11 side: `gdk_clipboard_store_async` performs the
clipboard-manager handshake and is called automatically on
`GtkApplication` shutdown, so kaya's job on Linux is mostly not to
break it.

kaya's rule: WE ALWAYS HAND OFF. The residual gap is a property of the
user's desktop, not a kaya choice — with no clipboard manager running
on X11 or Wayland nothing can make content persist, which GTK itself
exposes as `supports_clipboard_persistence`.

## §0d — the probes, before any arm is written

Measuring the platform before writing an arm overturned an assumption
on EVERY platform during file dialogs, including one where the wrong
arm had already been written. These are the four unknowns:

1. **Weston and out-of-process reads.** The linux lane runs Weston,
   which does not implement `wlr-data-control` (a wlroots protocol).
   `wl-clipboard` normally relies on it. Whether the harness can read
   the clipboard out of process on the wayland leg at all is unknown,
   and it decides how that leg is written.
2. **iOS and the paste prompt.** Does content seeded by
   `xcrun simctl pbcopy` count as "another app" and trigger the iOS 16
   prompt? If it does, the iOS paste leg needs the prompt driven, which
   means tools/ios/simdrive (gone) again.
3. **Android reads.** There is no clean shell command to read the
   clipboard, which is the same shape as the DocumentsUI problem. The
   accessibility service already built for that lane may be the answer.
4. **Focus and parallel legs.** Wayland and Android both require focus
   to read. The linux lane runs legs tiled in parallel, so at most one
   holds focus. The clipboard legs likely have to serialise between
   drains, exactly as the filedialog and menus legs already do
   (docs/traps.md).

## §0e — what the probes measured (2026-08-01)

### 1. THE WAYLAND LEG HAS NO CLIPBOARD AT ALL, and it is not about reading

tools/linux/clipprobe. The lane starts `weston --backend=headless`, and
that compositor advertises `wl_data_device_manager` but NO `wl_seat`:

    globals: wl_compositor wl_data_device_manager wl_output wl_shm
             wl_subcompositor xdg_wm_base ... (no wl_seat)

A data device is obtained FROM A SEAT. No seat, no data device, no
clipboard, for any client — including kaya's own GTK apps, not just the
harness. Weston registers no seat for the headless backend ON PURPOSE,
so this is not a misconfiguration to fix with a flag.

NOTHING IS WRONG WITH wl-copy/wl-paste; they are the right tool. The
question is which compositor the leg runs, and the property that decides
it is DATA-CONTROL — the protocol that lets a privileged client read the
selection with no surface and no focus. Without it, wl-clipboard falls
back to creating a surface and TAKING FOCUS, so the read is not passive
and disturbs whatever leg is running. Measured, all three in the lane's
own image (Debian 13):

    compositor        seat   data-control                    passive watch
    weston --headless  no    (unreachable, no seat)          -
    weston --x11      yes    none                            no
    sway (wlroots)    yes    zwlr_data_control_manager_v1    WORKS
    labwc (wlroots)   yes    zwlr_data_control_manager_v1    WORKS

and both wlroots compositors give a GTK window the size it asks for
once sway is told to float (see below).

`wlr-data-control` has since graduated to `ext-data-control-v1` in
wayland-protocols 1.39; wl-clipboard speaks both, and Debian 13's
wlroots still offers the zwlr name. Weston implements neither.

**THE WAYLAND LEG MOVES TO sway.** Headless natively, so the leg stops
being Wayland nested inside X11 and becomes an honest Wayland session;
data-control, so the harness reads PASSIVELY and the serialisation
problem below dissolves rather than being worked around.

labwc was proposed first and rejected on measurement. The objection to
sway was that it TILES, and the lane asserts window geometry
(`expect_window_size`, `resize_window`). That objection is real and
curable in one line:

    compositor          asked      got
    sway (default)      640x480    1276x693   <- forced to the output
    sway + floating     640x480    640x480
    labwc               640x480    640x480

So sway needs `for_window [app_id=".*"] floating enable` and labwc needs
nothing. Everything else favours sway: it has IPC (swaymsg over a unix
socket), and labwc has essentially no control surface at all.

D-BUS IS NOT A FACTOR EITHER WAY, though it is the first thing anyone
asks. This lane uses D-Bus for AT-SPI — the accessibility bus, which is
app-to-app and compositor-independent, and is how the GTK file dialog is
read (gtk.rs, `file_dialog_atspi`). Nothing in kaya has ever controlled
a compositor over D-Bus, so labwc not offering that costs nothing.

WHAT SWAY'S IPC BUYS BEYOND THE CONFIG. `expect_window_size` today reads
the size from GTK — our own toolkit answering a question about itself.
swaymsg lets the harness ask the COMPOSITOR what it actually gave the
window, which is an independent observer of the same fact. That is the
principle the file-dialog work settled on (read the real thing, never
our record), and it is available here for free.

The floating rule matches: kaya's GTK windows carry
`application_id("dev.kaya.Milestone2")`, so their `app_id` is set.

THE ONE RISK, and it is not a clipboard risk: roughly two hundred
existing wayland legs would run under a new compositor. GTK speaks the
same protocol to any of them, but decoration, sizing and xdg-shell
details differ in practice. Do the compositor swap FIRST, on its own,
and get a full linux lane green under sway BEFORE any clipboard code is
written — otherwise a compositor regression and a clipboard bug are
indistinguishable, which is exactly what cost a day on the Windows java
leg.

The x11 leg needs nothing: `xclip` round-trips a selection owned by
another process and lists TARGETS.

### 2. iOS PROMPTS FOR SEEDED CONTENT, AND THE READ BLOCKS

tools/ios/clipprobe, iOS 26.5. Content seeded with `simctl pbcopy` is
attributed to **CoreSimulatorBridge**, which is another app, so the
programmatic read raises the permission alert and does not return:

    "ClipProbe" would like to paste from "CoreSimulatorBridge"
    [Don't Allow Paste]  [Allow Paste]

Note the DEFAULT is Don't Allow. The read never returned; Q2 printed
nothing until the alert was answered.

THE PLAN'S TWO ASSUMPTIONS BOTH HELD:

- **The prompt-free queries really are free**, even for foreign
  content: `numberOfItems=1`, `hasStrings=true`,
  `types=[public.utf8-plain-text, public.plain-text, public.text]`, and
  `detectPatterns` all answered with the alert never shown. So the
  clipboard-offers signal that drives Paste enablement costs nothing,
  which was load-bearing for §0's per-widget acceptance design.
- **Reading our own content is free**: 9ms, value returned, no alert.

CONSEQUENCES FOR THE LEGS: a copy-then-read scene needs no prompt
driving at all. A scene that proves kaya accepts content from ANOTHER
app must drive the alert, which means tools/ios/simdrive (gone) again, exactly
as the document picker did. Its shape is known: a two-button alert
whose second button is "Allow Paste".

### 3. ANDROID HAS NO HOST-SIDE PATH

There is no `cmd clipboard`. The service exists
(`91 clipboard: [android.content.IClipboard]`) but reaching it means
`service call clipboard <n>` with a transaction number that shifts per
API level — on API 35 the guess mis-parsed its own arguments:

    Allocation of size 7209057 is above allowed limit of 1MB
      at android.os.Parcel.createStringArrayList

and even a correct number would hit the Android 10+ rule that a
non-focused reader gets nothing, which the shell always is.

So the host cannot see the Android clipboard, exactly as it could not
see DocumentsUI. tools/android/clipprobe then asked the rest from
inside an app, on API 35:

    Q0 read at onCreate (focus=false) -> null
    Q3 window has focus: true                 (at +2.5s)
    Q4 pre-existing clip: items=1 text=kaya-own-content mime=[text/plain]
    Q1 own read took 1ms -> kaya-own-content
    Q2 focus=false read -> null

**A FOCUSED READ WORKS AND IS FAST.** One millisecond, through the real
system service.

**A READ AT onCreate RETURNS NULL**, and this is the trap: the window
does not have focus yet when the activity is created, so an app that
touches the clipboard during startup gets nothing, with no error and no
way to tell it apart from an empty clipboard. kaya's harness runs after
the window is up so it is not exposed, but a guest author would be.

**CONTENT OUTLIVES THE PROCESS THAT WROTE IT.** Q4 read what a previous
run of the app had left behind after that process was force-stopped. So
a later focused reader gets content it did not write, which is the
property a copy-then-paste scene inside one process cannot show. Note
Android has no per-source gate at all, unlike iOS: the only question it
asks is whether the reader is focused.

**COPYING PUTS A SYSTEM OVERLAY ON SCREEN.** API 33+ pops a floating
clipboard preview over the app — the copied text, a dismiss button, a
share button — sitting on top of the guest for several seconds. It did
NOT steal focus and did NOT block the read (Q1 succeeded with it up),
but it is on screen and in the accessibility tree while the harness is
asserting, and it would appear in recording mode. Any clipboard leg has
to expect it; a leg that fails mysteriously after a copy should suspect
it first.

**WRITES ARE NOT FOCUS-GATED. ONLY READS ARE.** Q5 wrote from the app
while another was in front, and the next run read it back:

    Q5 wrote while focus=false
    Q4 pre-existing clip: text=written-while-unfocused   (next run)

That is the fact the Android helper's shape turns on, and it is good
news: SEEDING needs no focus, so a helper can put content on the
clipboard from the background without taking the foreground away from
the guest mid-scene. Only READING has to come to the front.

### THE ANDROID HELPER IS PART OF THIS WORK, NOT A LATER PHASE

Every other lane verifies with a FOREIGN reader and seeds with a
foreign writer: pbcopy/pbpaste, xclip, wl-copy/wl-paste, Set-Clipboard,
simctl pbcopy/pbpaste. Android has no such tool, so it needs a small
helper APK. Build it with the rest.

WHY THIS IS NOT OPTIONAL, and the argument is about the design rather
than about tidiness. The representation set is CLOSED precisely because
the lowerings are platform-specific and easy to get wrong: CF_HTML's
mandatory offset header, Android's content:// URI for images, CF_HDROP's
DROPFILES struct. A test where kaya reads what kaya wrote CANNOT CATCH
ANY OF THAT — our own reader would parse our own wrong header perfectly
happily and the leg would pass. A foreign reader is the only thing that
validates the decision the whole design rests on.

The helper therefore does both directions:
- **seed**: a background component writes, no focus taken (measured
  above), which is parity with the other four lanes' writers;
- **verify**: comes to the foreground briefly, reads, reports. Taking
  focus is unavoidable, and by then the guest has already copied — the
  same shape as DocumentsUI taking over during a file dialog.

REJECTED: an in-process ClipboardManager read as the verification, with
a foreign reader "later". It reads the real system service, so it is not
wrong, but it cannot see a malformed lowering, which is the class the
closed representation set exists to prevent. Shipping the verification
that cannot fail for the reason we care about is worse than shipping
nothing.

### 4. SERIALISATION IS AN ANDROID PROBLEM, NOT A LINUX ONE

The first answer here was "the legs will have to serialise", reasoned
from the protocol: Wayland delivers the selection offer only to the
client with keyboard focus, so parallel tiled legs would fight over it.

Finding 1 removes that for Linux. Under labwc the harness reads through
data-control, which needs neither a surface nor focus, so a clipboard
read cannot disturb a concurrent leg and the legs need no barrier. That
is a better outcome than serialising, and it came from asking which
compositor rather than how to work around Weston.

It still stands for ANDROID, where an unfocused reader gets nothing and
there is no data-control equivalent. Whatever option finding 3 settles
on has to keep the focused app focused for the length of the read.

### CORRECTION (2026-08-02): THIS FINDING ASKED THE WRONG QUESTION

The reasoning above is about READING — who may observe the selection,
and whether observing it disturbs a neighbour. That part holds. What it
missed is WRITING, and writing is what actually breaks:

THERE IS ONE SYSTEM CLIPBOARD PER SESSION. Every clipboard leg seeds
it, copies to it, and reads it back. Eight legs doing that concurrently
are eight processes assigning to one variable, on EVERY lane, whatever
the compositor does about focus and whatever data-control makes
passive.

Measured on mac the moment the scene left DEPTH_SCENES and eight
languages ran at once: six of eight failed. The failures name the
mechanism — the ocaml leg seeded "from another app", read text back,
and got "pasted by hand", which is another leg's seed; others read
"empty" where their own custom format should have been, or "" for an
image a neighbour had overwritten. The same eight, one at a time: 8/8.

So the clipboard legs are MUTUALLY EXCLUSIVE ON EVERY LANE, and the
serialisation is not a workaround for a platform quirk — it is the only
way the assertions mean anything, because a leg must read the clipboard
that leg wrote. validate-mac gives each leg its own drain. The linux
and windows runners have `clipboard` in SCENES but no leg blocks yet
(their backends still depth-stub it, which check-stubs enforces); THE
LEGS MUST BE SERIALISED THE SAME WAY WHEN THEY ARE WRITTEN, and the
Android lane needs it for finding 3's reason on top of this one.

## §1 — the protocol (landed)

The vocabulary, both directions, with nothing platform-specific in it.

### The four records

- tx `copy` (35) and `read_clipboard` (36), with apply twins `copy`
  (25) and `read_clipboard` (26). One encoder writes both channels'
  clip body, so the two cannot drift.
- occurrence `clipboard_result` (15): the read's one answer.
- occurrence `pasted` (16): the same answer arriving because the user
  pasted.

### COPY IS A RECORD, THE TWO ANSWERS ARE A SUM

`Clip` is the record of optional fields §0 argued for. `Representation`
is the sum, and both answers carry it: a read and a paste differ in
their TRIGGER, not in their payload, so a guest matches one shape
either way. `None` only exists on the read — a paste that delivered
nothing is not an occurrence, and `kaya_emit_pasted` refuses one.

### THE CANONICAL ORDER IS DESCENDING CLIP VALUE

custom (16), files (8), image (4), html (2), text (1) — which is
descending richness, and is preference order on every host that has one
(macOS pasteboard types, X11 TARGETS). A backend offers the values in
the order it reads them and is right; it needs no table of its own.

This replaces the order the §0 text stated (files, image, html, text,
with custom unplaced) and the order §1's first draft actually encoded
(text first, the reverse). Tying it to the enum's own values makes it
one rule instead of a list to get wrong in eight bindings, and it puts
an app's custom format first — the one representation that round-trips
into the same app losslessly.

### THE PASTE TAG RIDES VERBATIM

`pasted` is a click tag followed by the clip kind and its values, which
is exactly how `text_changed` carries an edit. A paste onto a stamped
row is the same event as a paste onto a live one, so it is ONE record
kind with `path_len` deciding, like every click since milestone 2.

The first draft put the clip kind in the tag's reserved slot, which
saved eight bytes and broke every existing "read a click tag" reader.
The round-trip test caught it immediately.

### THE OCCURRENCE BLOB TABLE, the third direction

An image or a custom format is bytes, and bytes never enter a record
stream. The two existing blob tables both have a boundary that retires
a handle — a submit drains the pending table, a batch replaces the out
table — and the occurrence channel has NEITHER: the guest takes records
one at a time, and the direct-ring consumers (Go, JVM, C#) move the
head themselves, so the core cannot see it advance.

So occurrence blobs are released EXPLICITLY, through
`kaya_occurrence_blob` / `kaya_occurrence_blob_release`, and the app
never sees a handle: the binding redeems it, copies into its own
language's byte type, and releases while decoding. Reusing the apply
channel's batch-local index instead would have named a slot in whatever
batch the pump happened to be serving — a pasted image arriving as some
window's icon. The round-trip test was made to fail that way on purpose
before it was believed.

### The pin that could not fail

The occurrence kinds were pinned by a list of indexed asserts covering
the first fourteen, which said nothing about a fifteenth: two new
occurrences passed it without touching it. It compares the whole list
now, and was watched failing.

## §1b — what macOS actually charges (measured 2026-08-02)

tools/mac/clipprobe, run both as a bare binary and as a bundled app.

### 1. THIS HOST DOES NOT PROMPT, and that was the assumption to check

§0 recorded macOS as "heading the same way" as iOS 16 — a permission
alert for reading another app's content. On macOS 26.5.2 there is none:
a read of content `pbcopy` had just written answered in **0-1 ms**, with
the content, bundled and unbundled alike, first read and second. So the
mac read leg needs no prompt driving, unlike the iOS one.

The cheap queries (`changeCount`, `types`, `canReadObject`) report
foreign content too, which is what the Paste-enablement answer needs.

### 2. PNG BYTES ROUND-TRIP; writeObjects(NSImage) LOSES THEM

`setData(png, forType: .png)` comes back byte-identical (3426 in, 3426
out) and the system SYNTHESIZES a `public.tiff` for consumers that want
one — plus jpeg, gif, bmp, jp2 and avif, all on demand.

`writeObjects(NSImage)` declares `public.tiff` and NOTHING ELSE. A guest
that handed over a PNG would get a re-encode back, and any consumer
asking for png would find nothing. So the arm sets raw bytes under the
type, and never wraps them in an NSImage.

### 3. SEVERAL FILES MEANS SEVERAL ITEMS

kaya's clip is one item in several types; macOS models several files as
several `NSPasteboardItem`s. Measured: item 0 carrying every
single-valued type plus the first file URL, with one item per remaining
file, satisfies both — `readObjects(NSURL)` sees every file and
`pbpaste` still sees the text.

### 4. THE LANE'S FOREIGN READER IS TWO TOOLS, not one

`pbpaste -Prefer <uti>` reads text, html and CUSTOM formats
(`{"note":1}` came back under `dev.kaya.probe.note`) — but answers
NOTHING for `public.png`; it is a text tool. `osascript -e 'clipboard
info'` lists every type with its byte count, images included, but knows
only AppleScript's own classes and never sees a custom one.

So the mac legs verify text/html/custom through pbpaste and the image
through `clipboard info`. Neither is kaya reading what kaya wrote.

### 5. WRITES DO NOT NEED THE MAIN THREAD

Measured from a global queue: the write took, the change count moved,
and the read back agreed. The apply pump can write directly.

## §2 — the data layer, green on mac (landed)

`copy` and `read_clipboard` end to end: the Rust surface, the SwiftUI
arms, two harness verbs, and a scene where EVERY ASSERTION CROSSES A
PROCESS BOUNDARY. 553 ms, thirteen observations.

### The two verbs, and why they are foreign

`clipboard_seed <kind> "<content>"` and `expect_clipboard <kind>
"<expected>"` drive the platform's OWN tools as child processes — on
mac `pbcopy`, `pbpaste`, `osascript` and `sips`. Nothing kaya wrote.

That is the whole value. The representation set is closed because the
lowerings are the hard part, and a check where kaya reads what kaya
wrote parses its own malformed header happily. A helper binary we wrote
would be foreign in name only.

ONE KIND CANNOT BE SEEDED: a custom format, because no stock tool on
any platform writes an app-defined type. That is not a hole — a custom
format's whole specification is that it round-trips within the app and
that kaya does nothing clever with the bytes, so the scene copies one
and reads it back, with `pbpaste -Prefer dev.kaya/note` confirming from
outside that the bytes really are there under that id. (The id was
`dev.kaya.note` when this slice landed; §5b finding 4 respelled it.)

### The image is a decoded size, never bytes

`expect_clipboard image "4x4"`. macOS synthesizes tiff, jpeg, gif, bmp,
jp2 and avif from one png on demand, so a byte count is a different
number on every lane for one picture. The scene reads a seeded image
and copies it straight back out, so a foreign DECODER answers.

### Files are the picker's capability, arriving through a second door

A pasted file is a `PickedFile`: the guest redeems the handle and reads
it with ordinary `std::fs`, off the app thread, because `open` blocks
either way. `expect label#0 "files pasted.txt pasted bytes"` fails
unless a real descriptor came back carrying the real file.

### An accept list is not a mask

`accepts` and `read_clipboard(accepting)` both carry a space-separated
ACCEPT LIST — the closed kinds by name plus any custom ids. A mask can
name four things and nothing else, so a custom format could be written
and never accepted: an escape hatch that only opens outward is not one.

### One gate learned an exemption

check-verbs requires every `expect_*` arm to record what it observed,
or it passes without verifying. An arm that calls the depth stub does
not RETURN, so it cannot pass vacuously — and without the exemption the
rule would push a half-built backend into faking an observation, the
exact defect it exists to catch. Watched failing both ways.

## §3 — the gesture layer, green on mac (landed)

Cut, Copy and Paste as standard-command ROLES, joining `settings` in
the closed role vocabulary. A role item lowers to the platform's own
command, acts on the FOCUSED widget, and works out its own enablement.

### The paste split is the rule everything turns on

A widget that DECLARED what it accepts takes the content itself: kaya
reads the clipboard and delivers it to `on_paste`. A widget that
declared nothing gets the platform's own insertion, and its ordinary
change handler reports the result.

So a plain text editor writes NONE of this and has working cut, copy
and paste. Declaring is how an app OVERRIDES that default. The scene
asserts both halves, and the assertion that the declared field stays
EMPTY is what proves kaya delivered the content instead of letting the
platform insert it.

### Two macOS findings, both silent failures

**Enablement is not a build-time fact.** It is the intersection of what
the clipboard offers and what the focused widget accepts, and both move
long after the bar was built. Kaya-owned menus set `autoenablesItems =
false`, so AppKit recomputes nothing — and `performActionForItem`
leaves a disabled item inert, exactly as native tracking does. Every
paste leg failed with nothing happening and nothing saying why. The fix
refreshes role items at the two moments enablement can change hands: a
menu about to display (an `NSMenuDelegate`, for real users) and a
harness activation.

**`NSApp.sendAction(to: nil)` starts at the KEY window.** A leg running
eight wide beside seven others is rarely the frontmost app, so it found
no responder, returned false, and the paste vanished. Making the app
key would have fixed it by stealing focus from every sibling leg — a
flake generator, not a fix. A window's first responder exists whether
or not the window is key, so the command starts there and
`tryToPerform` walks up.

### A seed that does not verify makes everything after it race

`osascript` writes the clipboard through AppleEvents, in another
process, and its EXIT does not mean the pasteboard has settled. The
file leg failed about one run in three, and because a seed is a silent
action the failure landed on whatever the guest asserted next. The verb
now waits until the content is really there, which is
"validation scripts verify what they ship" applied to a harness verb.

## §4 — the floor, before the seven bindings (landed)

The fan-out's first finding was not about the clipboard. Every
function-floor binding — Python, Swift, and all ten C guests — passed
`kaya_next_occurrence` a 256-byte buffer, and the core ABORTED when a
record did not fit: 208 bytes of payload was the ceiling, and the assert
sits inside an `extern "C"` frame so the panic cannot unwind. A pasted
paragraph crosses it; an `html` clip crosses it every time.

The bug predates the clipboard (`text_changed` has been unbounded since
milestone 0 and every scene's text was short). The clipboard is what
makes it routine, and writing four paste decoders against a floor that
aborts on real content would have meant writing them twice.

THE CAP IS GONE RATHER THAN LARGER. The floor hands back a borrowed
pointer to a core-owned record — the caller copies out what it keeps,
as `kaya_blob_data` already asks — so there is no buffer to be too
small. Measurement, the guard, and the WOKEN half of the lesson are in
docs/traps.md.

## §5 — the seven other bindings (landed)

All eight now copy, read, declare what they accept, and take a paste.
Each was run against the real SwiftUI interpreter on the clipboard
scene — eighteen observations apiece, not a compile check.

### The spellings, and the one rule that produced them

| binding | copy | the sum |
| --- | --- | --- |
| Rust | chain | enum |
| Go | chain | sealed interface + one struct per case |
| Swift | chain | enum with associated values |
| C# | chain | abstract record + nested records |
| Java | chain | sealed interface + nested records |
| Python | keyword arguments | nested classes under `Representation` |
| OCaml | optional labelled arguments | variant |
| Haskell | a RECORD LITERAL | data, constructors prefixed `R` |

The rule is the binding convention, not taste: AT MOST ONE PER KIND IS
STRUCTURAL IN ALL EIGHT. A chain gets it because a second `.text()`
replaces the field; keyword arguments get it because the call cannot
name `text` twice; a record gets it the same way. Haskell is the only
one that takes a record literal, and it is the only place the binding
departs from the `showAlert [attrs]` shape beside it — deliberately,
because an attribute list would let `[CText "a", CText "b"]`
typecheck, and the design says that must be impossible rather than
checked.

### THE ACCEPT VOCABULARY IS NAMED, because a bare string fails silently

`accepts` and `read_clipboard` take the closed kinds by name. Spelled
as bare strings, a typo is INVISIBLE: `"txet"` is a well-formed custom
format id, so it joins the accept list, no clipboard ever offers it,
Paste stays dead and the paste hook never fires — with nothing to see
in any log.

So the four closed kinds are named constants in every binding, spelled
exactly the way that binding already spells the MENU ROLES: a typed
enum in Rust (`Accepts::Text`, beside `MenuRole::Cut`) and a named
string constant everywhere else (`ACCEPT_TEXT`, `AcceptText`,
`acceptText`, `accept_text`). That is a ratified pattern for a closed
vocabulary riding the wire as a string, and it was followed rather
than reinvented — a typed sum in six languages was considered and
dropped for breaking it. A custom id has no constant by nature: the
app that defines it names it.

### The occurrence blob table, three ways

A blob in an occurrence is a table handle, redeemed and released while
decoding so no handle reaches an app. Where the generated decoder can
reach the library it calls it directly (Swift, C#, Go, Java through a
new `KayaRing.occurrenceBlob` native on both twins). Where it cannot —
the generated module is imported BY the runtime, never the reverse —
Python and OCaml install a redeemer into a module-level slot, and
Haskell threads it as a function argument, which is that language's
answer to the same problem and needs no global.

## §5b — what the GDK probe measured (2026-08-02, complete)

tools/linux/gdkclipprobe, run under sway in the lane's own image
against the same gtk4 crate the backend links. Six probe runs; the
foreign-reader blocker of the first run is RESOLVED (finding 3), and
resolving it surfaced one more platform charge (finding 4).

### 1. A UNION PROVIDER REALLY DOES ADVERTISE ALL FOUR

`gdk_content_provider_new_union` of text + html + image + custom leaves
the clipboard advertising, by GDK's own account:

    gchararray GdkTexture GdkPixbuf text/html image/png dev.kaya.note
    text/plain;charset=utf-8 text/plain;charset=ANSI_X3.4-1968 text/plain

So the union does not let the last provider win, an ARBITRARY custom
mime type is accepted verbatim (`dev.kaya.note` is there), and GTK adds
the text aliases and the texture/pixbuf shapes for free. That is the
copy arm's structure settled: build one provider per populated
representation, union them, set once.

### 2. AN UNSATISFIABLE READ FAILS FAST — THE ARM NEEDS NO TIMEOUT

`read_async` for a type nothing offers answered in **0ms** with
`Err("No compatible formats to transfer clipboard contents.")`. It does
not hang. So the async-to-answered-exactly-once bridge is
straightforward: Err maps to the empty answer, which is the universal
no the design already defines, and the arm needs no bound of its own.
(This was the question most likely to have forced a redesign — a
hanging read would have meant a wedged leg and a timeout in the arm.)

### 3. RESOLVED: THE FOREIGN READER SAW NOTHING BECAUSE NO CLIENT CAN HOLD A SERIAL

With wl-paste present and the same clipboard GDK had just described,
every foreign read answered `Nothing is copied`. The mechanism, named
by sway's own debug log (`sway -d`; the rejection is logged at DEBUG
and invisible at the default level):

    [wlr_data_device.c] Rejecting set_selection request,
                        serial 0 was never given to client

Wayland lets a client take the selection only by presenting a serial
from an input event that client was sent. The lane's seat EXISTS —
unlike Weston's headless, which advertises none — but with
`WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1` its capability set
is EMPTY: no keyboard, no pointer, therefore no input event, ever, for
any client. GDK sends serial 0; wlroots drops the write and tells the
client nothing; GDK's own bookkeeping still reports the content set.
The three candidates, as measured:

- **No seat**: ruled out — wl_seat is there (`seat0`, version 9),
  capabilities blank. One level below the Weston finding, same family.
- **The window never mapped**: ruled out — a mapped, settled window's
  set was rejected identically.
- **No serial**: confirmed, and dissected. A `wtype -M shift -m shift`
  tap does NOT help (a modifier change is not a key event). Keyboard
  ENTER does not help either: with a virtual keyboard held open the
  focused window receives wl_keyboard.enter, whose serial GDK does not
  spend on set_selection. ONE REAL KEY EVENT is what GDK banks: after
  `wtype -k F24`, every foreign read answered with the content.

THE RECIPE — revised twice; both revisions were bought by full lane
runs, and the second one retired a piece of the first:

- **A freshening F24 tap before EVERY step that can lead to a copy**
  (gtk.rs, freshen_wayland_serial; the stage taps on click,
  menu_activate and shortcut in scenes that armed the clipboard). The
  first tap per process takes the press-hold-release form
  (`wtype -P F24 -s 800 -p F24` — the press races GDK's late
  wl_keyboard bind and is LOST, the release at +800ms lands after the
  bind); later taps are a quick `wtype -k F24`. That is the WHOLE
  recipe.
- **NO session keyboard holder.** The obvious "make the seat real"
  move — hold a virtual keyboard open for the lane's lifetime — was
  tried and REGRESSED three unrelated legs the same day: with a
  keyboard on the seat, keyboard focus is EXCLUSIVE, and the lane
  pools eight legs in one sway session, so every leg but one lost
  `expect_focused` (measured 2026-08-03; the identical tree with the
  holder dead was ALL PASS, 426 legs). The tap's transient keyboard
  is immune because the clipboard legs run ALONE between drains —
  there is no neighbor to disturb while it exists. The anomalous seat
  must STAY anomalous while the pool runs; the tap makes it real for
  exactly the milliseconds a copy needs it. SINCE 2026-09-02 THE SEAT IS
  THE LEG'S OWN: the lane boots one sway per pool slot
  (tools/linux/run-suites.sh, the wayland pool), the clipboard legs pool,
  and the tap is unchanged — transient, on a seat with no neighbour.

RESEARCHED ESCAPES (2026-08-03), so the constraint does not calcify
into an impossibility nobody re-checks. If a future feature needs a
PERSISTENT seat keyboard (IME, key repeat, compositor-level shortcut
injection), the exclusivity conflict has one practical exit and two
theoretical ones:

- **Per-leg sway instances** — the x11 half's own design (each X11 leg
  already gets a private Xvfb). Measured: a headless sway reaches its
  socket in ~55ms, so one compositor per wayland leg costs what
  xvfb-run already costs. One session per leg dissolves exclusivity
  (one window per seat), makes a session keyboard holder safe again,
  and gives each leg a PRIVATE clipboard — the wayland clipboard legs
  could then unserialise exactly as the x11 ones could. TAKEN
  2026-09-02, for the drag-and-drop plan's pointer (docs/dnd-plan.md §5
  step 0): tools/linux/run-suites.sh boots one headless sway per pool
  slot, every wayland leg claims one, the clipboard, undo, ranges and
  editor legs pool, and a vendored `zwlr_virtual_pointer_v1` client
  (tools/linux/wlpointer) is the seat's pointer for the milliseconds a
  drag needs it — proven by a real drag at every lane start
  (tools/linux/dragprobe.py). Stock sway, run differently, as written.
- **sway multi-seat** is real and demonstrably works (per-seat focus
  and per-seat selections since sway 1.0; blinry's multi-player
  writeup shows two seats driving two windows at once). Read to the
  source, it splits cleanly into one solvable gap and one hard wall:
  - THE SOLVABLE GAP: wtype binds the first wl_seat with no seat flag
    — but the whole tool is ~560 lines and the flag is a ~20-line
    patch (collect seat names from the registry, match, bind), or a
    vendored micro-client we own. Note today's tap needs NO patch:
    the first seat IS seat0, and a serial only validates on the seat
    whose data device the copy rides (wlr_seat_client is per client
    PER SEAT), so the tap binding seat0 is correct by construction.
    Per-seat focus steering is stock swaymsg (`seat <name> cursor
    set/press`). So EXTRA seats with held keyboards, each focusing
    its own leg's window, is reachable with modest tooling — GDK
    merges focus across seats, so every leg's expect_focused could
    hold at once. A real exit from the exclusivity conflict.
  - THE HARD WALL: multi-seat can never partition GDK apps'
    CLIPBOARDS. Each GdkWaylandSeat mints its own clipboard object,
    but `gdk_display_get_clipboard` — what GTK widgets and kaya's arm
    use — is pinned to the FIRST seat's (gdkseat-wayland.c:
    `if (display->clipboard == NULL) display->clipboard =
    g_object_ref (seat->clipboard)`), and every client of a session
    sees the same first seat. All legs converge on seat0's selection
    whatever seat focuses them, so the clipboard legs stay serialised
    under multi-seat; only per-leg sessions can unserialise them
    (and did, 2026-09-02).
- **libei/EIS** (the XTEST-for-Wayland standard, built for headless
  CI input) is implemented by Mutter and KWin, NOT by wlroots/sway
  (open since 2020; wlroots' position is that the existing virtual
  device protocols suffice). A compositor swap to Mutter headless
  (`--headless --virtual-monitor`, EIS input, ext-data-control since
  49.2) is a real option some day and a whole re-proving of ~200 legs
  the day it is taken (§0e measured what the LAST swap cost).

Weston stays disqualified even at 14.0.2 (the version that gained
ext-data-control): re-measured in the lane's image, its headless
backend still advertises NO wl_seat and no data-control global — the
support tables describe its seat-ful backends. And uinput-level tools
(ydotool/dotool) are no escape: they need a privileged container plus
a libinput backend, and the kernel-level keyboard they create is
PERSISTENT — the exact exclusivity this note exists to avoid.

WHY ONE TAP IS NOT ENOUGH — the superseded-serial check, found by the
first full lane run and confirmed in wlroots 0.18.2's own source
(types/seat, wlr_seat_request_set_selection):

    if (seat->selection_source &&
            serial - seat->selection_serial > UINT32_MAX / 2) {
        wlr_log(WLR_DEBUG, "Rejecting set_selection request, serial
                indicates superseded ...");

Every data-control write (each wl-copy seed) advances the seat's
selection serial past any serial the guest already holds, so the
guest's NEXT copy is rejected — silently, at DEBUG. And the failure
COMPOUNDS, because of a GDK rule on the other side
(gdkclipboard-wayland.c): a client with a live local claim IGNORES
every incoming selection offer ("Ignoring clipboard offer for self")
and waits for a `cancelled` that never comes — its source never
became the seat selection, so nothing will ever cancel it. ONE
dropped copy leaves the guest deaf to the clipboard for the rest of
its life: reads answer from its own stale offer, pastes deliver
nothing, and the enablement intersection is computed against a ghost.
Measured end to end and then minimized: seed, tap, own-copy
(accepted, foreign-visible), seed again — the guest's formats follow
every step once the tap precedes each copy.

F24 because it is bound to nothing and types nothing; the tap lands
on the focused window, which during a serialised clipboard leg is the
leg's own. The arm itself stays ordinary GDK — holder and tap are the
LANE making a headless session deliver what any real session delivers
continuously, not the backend working around the protocol.

Note the shape of the failure, because it is the trap: GDK's own
`formats()` reported everything correctly, and there is no error
channel on which GDK could learn the compositor declined. A backend
that verified its copy by asking GDK would have passed while nothing
reached the clipboard — which is precisely why every assertion in this
scene crosses a process boundary.

A second trap, paid for by a wedged probe run: `wl-paste --list-types`
is answered by the COMPOSITOR from the offer, but reading DATA needs
the owner's main loop to serve bytes. A probe that owned the selection
and then waited synchronously on wl-paste deadlocked — reader waiting
on the pipe, owner's loop blocked by the wait. The lane never has this
shape (the foreign reader runs in the runner's process, not the
guest's), but any in-process verification of a GDK copy would.

The battery, once the selection was really held:

- **html**: a foreign reader sees raw UTF-8 under bare `text/html`.
  GDK adds NO `;charset=utf-8` alias for html (that aliasing is
  text/plain-only), so the lane's reader must ask for the bare type.
- **image**: `for_bytes("image/png")` round-trips BYTE-IDENTICAL
  through a foreign read — the raw-bytes-under-the-type rule from
  macOS (§1b finding 2) holds here too. Never GdkTexture, which
  re-encodes.
- **files**: `text/uri-list` with the RFC's CRLF separators and
  trailing terminator round-trips; the reader is unbothered either
  way.

### 4. A CUSTOM ID WITHOUT A SLASH IS ADVERTISED AND NEVER SERVED

The same battery's custom read answered EMPTY — zero bytes, exit 0, no
error — while `image/png` through the same union served perfectly. The
2x2 that isolated it ({sole, union} x {slashless, slashed}):

    provider                     advertised   served
    dev.kaya.note (sole)         yes          EMPTY
    dev.kaya.note (union)        yes          EMPTY
    application/x-kaya-note      yes          note=1
    dev.kaya/note                yes          note=1   (sole AND union)

The mechanism is GDK's, not the compositor's: the serving path interns
the requested type through `gdk_intern_mime_type`, which returns NULL
for any string without a `/` (and lowercases the rest — RFC 2048
shape), so the transfer is dropped with the fd closed while the
advertise path carries the raw string. A slashless custom id on GTK is
therefore a type every reader can SEE and no reader can GET — the
silent per-platform failure class the closed representation set exists
to absorb, one layer down.

The minimal slash satisfies it: `dev.kaya/note` — the scene's id with
one character added — serves sole and in a union. Windows'
`RegisterClipboardFormat` and Android's ClipDescription mime strings
accept a slash by construction. macOS accepts it WITH A CHARGE that a
snippet-level probe missed and the respelled lane run caught: the two
write APIs disagree. `NSPasteboardItem.setData(forType:)` VALIDATES
its type as a UTI — a slash is not legal in one — and DROPS the data
with only a console log ("not a valid UTI string"), so the leg read
the text fallback; the pasteboard-level `declareTypes` + `setData`
path takes an arbitrary string verbatim, and `pbpaste` reads it back
byte-identically. The mac arm therefore writes item 0 at BOARD level
(kayaCopyToPasteboard), and the standing rule gains a sharper edge:
probe the path THE ARM USES, not a path that answers the same
question. The iOS arm must measure UIPasteboard's own charge for a
slashed type before it is written. So the constraint remains
one-directional — GTK alone refuses the slash's absence, and every
platform has a verbatim-preserving way to serve its presence — and
the resolution is an id-grammar rule at the root, not a GTK
carve-out.

RATIFIED (2026-08-02): a custom id MUST CONTAIN A SLASH AND BE
LOWERCASE — mime-shaped, RFC 2048 — and the scene's id is respelled
`dev.kaya/note`, the minimal edit that satisfies it. Lowercase is part
of the rule because GDK canonicalizes with `g_ascii_strdown`: a
mixed-case id would surface lowercased on GTK and verbatim everywhere
else, a divergence invariant 1 forbids. The root validates the grammar
at the chokepoint every binding funnels through and rejects a bad id
naming this rule; the scene, the eight guests and DESIGN.md's custom
paragraph carry the respelled id.

### 5. THE SCENE'S EMBEDDED PNG HAD A BROKEN CRC, AND FOUR PLATFORMS NEVER NOTICED

The first full linux lane run failed every image verdict with `""`.
The 4x4 PNG every guest embeds — hand-spelled, per its own comment —
carried an IDAT chunk whose CRC did not match its data (stored
9407f98a, computed 40c116d4; the stream did not even inflate).
`sips`, the mac lane's decoder, tolerates a bad CRC; the byte-compare
probes only ever proved the bytes ROUND-TRIP; imagemagick's
`identify`, this lane's decoder and the matrix's first strict one,
rejects it. The constant is regenerated (a valid 77-byte 4x4 RGB) in
all eight guests, and the GTK reader's image verdict now names the
decoder's complaint instead of answering "" — bytes-present-but-
undecodable must never read like an empty clipboard, which is how
this hid for a full debugging round.

## §6 — what Windows actually charges (measured 2026-08-03)

tools/win/clipprobe, run in the VM's interactive session against the
same `windows` crate version the backend links, with stock Windows
PowerShell 5.1 as the foreign half of every assertion. One probe run
answered everything; the arm followed the same afternoon.

### 1. EVERY SSH CONNECTION IS ITS OWN CLIPBOARD

Not "session 0 vs the console": each ssh logon gets a fresh window
station (`Service-0x0-…$`), hence a fresh, empty clipboard — a value
written in one connection reads back null in the next. So neither the
seeds nor the reads may run over ssh. The guest runs in session 1
(deploy-win launches through `schtasks /it`), so the harness verbs
spawn PowerShell as CHILDREN OF THE GUEST and share the one real
clipboard; the probe orchestrates both halves inside one /it task for
the same reason.

### 2. CLASSIC WIN32, NOT WinRT DataTransfer

Three charges disqualify the modern API for a harness-driven app:
`Clipboard.SetContent` is documented to work "only when the
application is in the foreground", which a matrix leg cannot promise;
the WinRT→Win32 bridge for a CUSTOM format id is documented only in
the read direction (and Microsoft records the write side of that
bridge as asymmetric); and SetContent's data dies with the process
unless flushed. Classic `OpenClipboard`/`EmptyClipboard`/
`SetClipboardData` — five formats in ONE open, descending clip value —
has none of them: measured, all five representations read back
byte-exact through foreign stock tooling AFTER THE SETTER EXITED, and
`RegisterClipboardFormatW("dev.kaya/note")` registers the ratified
slashed id and reads its name back VERBATIM. Reads are synchronous
pulls, so "answered exactly once" needs no async bridge on this
backend.

### 3. CF_HTML, BOTH DIRECTIONS, AND THE DOCS ARE WRONG

Microsoft's own worked example is arithmetically broken (its fragment
offsets mix two relative bases beside two absolute ones) — construct,
never pattern-match. The arm builds the header with 10-DIGIT
FIXED-WIDTH offsets, which is what makes the header length a constant
rather than a fixpoint; the read side carries the equal and opposite
parser (StartFragment/EndFragment BYTE offsets into the payload),
because kaya's html representation is the raw fragment and a paste
must never hand the guest a header it did not write. The parser is
proven against a header we did not build: PowerShell 5.1's
`Set-Clipboard -AsHtml` — which, contrary to every web source
(they describe `Clipboard.SetText`, a different code path), emits a
CORRECT header with 9-digit space-padded offsets.

Two foreign-reader traps, measured: `Get-Clipboard -TextFormatType
Html` decodes the UTF-8 payload with the ANSI code page and corrupts
non-ASCII irreversibly — the harness reads html through
PresentationCore's `[Windows.Clipboard]::GetText(Html)` instead. And
`[Windows.Clipboard]::SetData` with a STRING rides WPF's
serialized-object path (a 16-byte GUID + BinaryFormatter blob) that
round-trips inside PowerShell while every other reader sees garbage —
a MemoryStream writes the exact bytes. Both are the false-green shape
invariant 4 exists for.

### 4. IMAGE: THE "PNG" REGISTERED FORMAT, AND A DELIBERATE CUT

Raw PNG bytes ride the `"PNG"` registered format (the Firefox/clip
convention), byte-exact both directions — the same
seed-writes-what-the-arm-reads shape wl-copy takes on linux. The
foreign verdict is a REAL decode (GDI+ `Image::FromStream` → WxH),
though a lenient one: BOTH stock decoders (GDI+ and WPF) accept the
broken-CRC png of §5b finding 5, so the strict-decoder property lives
on the linux lane alone. THE CUT: a PNG-only clip is invisible to
DIB-path consumers (`Get-Clipboard -Format Image` answers null) —
offering CF_DIB would mean DECODING the png in the arm, and the
closed set's image is encoded bytes everywhere. Recorded as
deliberate, the same closed-world choice as GTK reading only
image/png.

### 5. THE REST OF THE LEDGER

- **Files**: DROPFILES is a 20-byte struct (pFiles=20, fWide=1) +
  UTF-16 NUL-terminated paths + one extra NUL; round-trips through
  `Set-Clipboard -LiteralPath` / `-Format FileDropList` both ways. A
  pasted file registers into the SAME picked table the file dialog
  fills, so `kaya_open_picked` redeems it identically.
- **Text**: CF_UNICODETEXT, UTF-16LE + NUL. Guest strings are written
  VERBATIM (LF stays LF — measured: `Get-Clipboard -Raw` preserves
  it) and reads normalize CRLF→LF at the boundary, the same `lf`
  discipline every TextBox string already rides.
- **PowerShell is PINNED to 5.1** (`powershell.exe`), and the edition
  is ASSERTED inside every harness script: pwsh has neither
  `-Format`/`-TextFormatType` nor `-AsHtml`/`-LiteralPath`, and the
  capabilities vanish SILENTLY there. The VM has no pwsh today; the
  guard is for the day someone installs it.
- **GlobalSize may exceed the written length** (the allocator rounds
  up), so self-delimiting formats trust their own delimiters and a
  custom format's bytes are whatever the allocation says — the
  platform's own grammar for them, verbatim per the design.
- **Enablement**: the intersection is recomputed INLINE at every
  activation (menu_user_activate), plus on focus and
  WM_CLIPBOARDUPDATE listeners for the chrome — the mac finding's
  refresh rule with this platform's own change signal. AND BEFORE A
  HARNESS ACTIVATION, where it is load-bearing beyond a grayed row:
  the harness invokes through the item's automation peer, and
  `Invoke()` on a still-disabled item THROWS inside a dispatcher
  callback — a stowed exception, exit 0xC000027B, process gone. The
  focus listeners refresh on a DEFERRED tick, so a
  focus-then-activate script races it; the first full lane run lost
  exactly one leg of five to that race (rust, the fastest), and the
  refresh at the activation site is what closed it — the same fix,
  for a harder failure, than macOS's inert-item version of this
  finding.
- **The UIA field-name fallback**: a WinUI TextBox publishes an EMPTY
  Name and serves its content through ValuePattern, so the ax read
  falls back to the field's value — the macOS AXValue / GTK AT-SPI
  Text chain, spelled WinUI.

## §7 — what Android actually charges (measured 2026-08-03; arm written same day)

Two probe campaigns — tools/android/clipprobe/run2.sh (same-package)
and tools/android/cliphelper/run3.sh (cross-package, the one that
counts: same-package access needs no grant, so the first campaign's
grant cells were vacuously green and are marked so here).

### 1. THE HELPER READS WITHOUT TOUCHING THE GUEST'S FOCUS

The plan assumed the helper must come to the foreground to read
(finding 4's constraint). It does not: ClipboardService admits the
DEFAULT IME's reads before it ever checks focus, the package need
only own the selected input method (`adb shell ime enable/set`; the
service never binds or shows), and the read raises no access toast.
Measured: the helper's plain BroadcastReceiver reads the clipboard
with the guest focused throughout — the return-focus problem is
DELETED rather than solved. (The Appium pattern.) A receiver that is
not the default IME reads null — the control cell.

### 2. BYTES RIDE content:// URIS, AND THE GRANTS ARE PER-PASTE

ClipData.Item carries text, htmlText, a Uri or an Intent — no byte
array — so image and custom payloads ride a ContentProvider
(`grantUriPermissions="true"`, consumers resolve the mime with
ContentResolver.getType and read with openInputStream). Measured
cross-package: the paste-grant is AUTOMATIC (ClipboardService grants
the reading package at getPrimaryClip time), and it is REVOKED THE
MOMENT THE CLIP CHANGES — re-opening a stashed URI answers
SecurityException. The arm's rule: materialize URI payloads inside
the paste, never hold one. (The documented-nowhere
clear-the-whole-clipboard-on-ungrantable-URI failure did NOT
reproduce on API 35 with an unresolvable authority; recorded as
unconfirmed, not as safety.)

### 3. THE CLIP IS BUILT BY HAND

`newHtmlText` advertises `text/html` alone (AOSP source), so the one
clip lists every offered mime in its ClipDescription explicitly:
item 0 carries text+html inline, and one URI item per byte payload
follows — measured round-tripping all four mimes cross-package
(html verbatim; custom "dev.kaya/note" stored VERBATIM, no
validation or normalization anywhere on the path). `coerceToText`
returns "" for content URIs (contradicting its own javadoc) — never
a fallback for byte payloads.

### 4. THE LANE MECHANICS, ALL MEASURED

- **The emulator-host clipboard bridge is SEVERED on this pool**,
  both directions — EmulatorClipboardMonitor exists in the service
  but nothing crossed. No cross-lane collision with the mac lane
  under validate-all.
- **The API 33+ copy overlay is suppressible**: the
  `com.android.systemui.SUPPRESS_CLIPBOARD_OVERLAY` description
  extra (honored on emulators). Every helper seed carries it; an
  unsuppressed copy's overlay lingers for seconds over whatever the
  harness is asserting against.
- **Explicit-component broadcasts reach even a never-started
  package** (the stopped-package exclusion applies to implicit
  broadcasts) — the seed/read protocol uses `-n` and needs no
  warm-up launch.
- **Background WRITES are unrestricted** (confirmed in the service
  source across API 10..15 and on the pool), so seeding never moves
  focus. Results ride ORDERED broadcast result data — printed by
  `am broadcast` on stdout host-side, and delivered to a result
  receiver app-to-app, which is how the guest will orchestrate
  seeds without any host round-trip.

### 5. WHAT THE ARM STILL NEEDS (the map, from the recon)

KayaCompose.kt: the APPLY_COPY/APPLY_READ_CLIPBOARD arms (and
collectBlobs MUST learn APPLY_COPY — blob handles are batch-local
and the miss is silent); the guest-side ContentProvider in the kaya
android module serving its copies' byte payloads; the seed/read
verbs orchestrating the helper over ordered broadcasts; the
EditableText fallback in kayaAxName (the same field-value gap GTK
and WinUI each had, third platform running); the roles + paste
split mirroring the other arms; and the CLIP_* constants — whose
check-verbs clause LANDED with the arm (clip_mirrors: both
interpreters' private copies pinned to wire.rs, self-tested).

### 6. WHAT THE FIRST LANE RUNS CAUGHT (integration, 2026-08-03)

Two failures, both in clipboard-jvm, both invisible to every fast
gate because each needed a REAL android JVM process walking a path
nothing had walked before.

- **The shared Java guest lacked the rust guest's android
  scene_root branch.** The interpreter materializes file payloads
  under shared Documents; the Java guest wrote its expectation
  against the app cache dir, and the seed died on the disagreed
  path. The guests' platform branches must move in lockstep — a
  platform branch added to one guest is a sweep obligation across
  all eight, same as any binding surface.

- **The first pasted file on the android JVM tier hit an
  UnsatisfiedLinkError: KayaRing.openPicked had no implementation.**
  The entry sat in jvm.rs's `register_desktop_natives`
  (cfg'd off android) while the SHARED list carried a comment
  promising it was shared — and both KayaRing classes declared it.
  JNI's attach-time check runs ONE WAY: an entry the class lacks
  fails loudly at attach, but a natively-declared method no list
  registers waits SILENTLY for its first caller. filedialog has no
  jvm leg on android (the picker rides KayaPresent.openPickedUri),
  so the clipboard scene's pasted file was the first caller ever,
  months after the desktops shipped the same method.

  Fixing the registration exposed the second charge, measured
  before writing the arm's branch (tools/android/clipprobe,
  FdReceiver): ART's `java.io.FileDescriptor` is libcore's, and the
  int field is `descriptor`, not OpenJDK's `fd` — a non-SDK member,
  but hidden-API enforcement ADMITS it on the API-35 image (field
  settable, `setInt$` callable, and a hand-built descriptor reads
  real bytes end-to-end: F1/F2/F3 all ok). Poking it is what the
  platform's own jniCreateFileDescriptor does; if a future image
  blocks it, the successor is the NDK's `AFileDescriptor_create`
  (API 31+), and the failure would be a loud IOException at the
  paste, caught by this leg.

  The guard is tools/check-jni.sh (keyed, in validate-mac's gate
  block): every native/external declaration in KayaRing.kt,
  KayaPresent.kt, Kaya.kt and KayaRing.java must have a
  registration entry or a Java_dev_kaya_* export on ITS tier's
  attach path, and every registered name must be declared where its
  list targets — both directions, statically, with four negative
  self-tests each proving its perturbation applied before demanding
  red. The sweep verdict for the other seven bindings: no other
  tier HAS a hand-kept registration list — their native surfaces
  are generated from the spec and pinned by gen-bindings/gen-header
  — so the gate covers the one mechanism that can drift this way.

## §8 — what iOS actually charges (measured 2026-08-03; ClipProbe II)

The second campaign: tools/ios/clipprobe/{main2.swift,run2.sh,
spawnread.swift}, on the kaya-sim pool's iOS 26.5 image. The first
campaign (§0e finding 2) measured the prompt's existence; this one
measured everything the arm touches. Five findings, every one load-
bearing for the arm's shape.

### 1. ONE WRITE PATH, AND THE SLASHED ID SURVIVES IT

`UIPasteboard.items = [[type: value]]` with all five representations
in one item (files as a second item) preserves `dev.kaya/note`
VERBATIM in `types` — the macOS two-path dance (§5b finding 4:
NSPasteboardItem drops a slashed type, the board-level write serves
it) does NOT recur on iOS. Every representation reads back byte-exact
as own content, prompt-free. The clip SURVIVES PROCESS EXIT: the app
was terminated and the host still read every kind that crosses the
bridge. The setData fallback cell was written and never needed.

### 2. THE PROMPT IS PER-CLIP, NOT PER-PAIR, AND IT IS DRIVABLE

- The alert is an OUT-OF-PROCESS overlay (a pid other than the
  app's), which is exactly what simdrive's hit-testing finds. Its
  tree, recorded: AXStaticText `"<reader>" would like to paste from
  "<writer>"`, AXStaticText `Do you want to allow this?`, AXButton
  `Don't Allow Paste` (the DEFAULT), AXButton `Allow Paste`.
- simdrive gained a `press <label>` verb and it lands: the blocked
  read returned 2218ms after launch, i.e. the moment the button was
  pressed. THE ALERT IS SPRINGBOARD'S, AND ONLY SPRINGBOARD'S TREE IS
  ALWAYS READABLE (the first lane run's lesson, 2026-08-03): the
  hit-test route that finds a picker — and that found this same alert
  over the idle probe app — goes BLIND when the alert was raised by
  the foreground app's OWN blocked read (`describe` answered "no
  picker" for six straight seconds with the alert filling the
  screen), which is precisely the state every real paste leg is in.
  A tree walk of SpringBoard's pid answers in exactly that state, so
  `press` searches the hit-test overlay AND the invoked pid's own
  tree every attempt, the watcher drives it with SpringBoard's pid,
  and a tap is refused until the button's frame is identical across
  two reads 300ms apart (the buttons sit LOWER while the title wraps
  longer app names — the y that was 462 for a two-line title is 473
  for three, so coordinates cannot be assumed, only read).
- Allow is NOT a durable grant: a re-read of the SAME clip is free
  (3ms, no alert), but every NEW foreign clip — same source, same
  reader — prompts AGAIN (measured: the re-seeded read raised a
  second alert). The scene seeds foreign content four times, so the
  leg drives the prompt four times. Mechanical, not exceptional.
- The read blocks ONLY the calling thread: with the read on a
  background queue the main thread heartbeated through the whole
  alert (46 beats). The arm's reads go off-thread, always.
- Prompt-free queries stay free at every stage: numberOfItems,
  types (per item too), has*, changeCount — measured against foreign
  content repeatedly. The unsatisfiable read (accepts files,
  clipboard holds text) can answer "empty" from types alone, no
  alert, no data touch.

### 3. THE SYNC BRIDGE IS ASYMMETRIC, AND ONE DIRECTION HANGS

- `simctl pbcopy` seeds TEXT only (stdin, no type argument).
- `simctl pbsync host <device>` carries the rich kinds: html, png
  and — measured this campaign — `public.file-url` all arrive under
  their proper types. Every clipboard_seed kind works as: seed the
  HOST pasteboard with the mac arm's own spellings (pbcopy /
  osascript «data HTML»/«class PNGf»/POSIX file), then pbsync
  host->device.
- `simctl pbsync <device> host` DROPS app-defined types and
  file-urls (text/html/png cross, plus a synthesized image family) —
  so no stock host tool can confirm the custom representation. It
  also MAY NOT EXIT when a promised secondary type is on the board
  (rc=124 long after the content landed): bound it with `timeout`
  and poll the host pasteboard for arrival.
- `simctl pbpaste <device>` read our union clip as EMPTY. Not a
  reader for anything kaya writes.

### 4. THE FOREIGN READER IS A SPAWNED PROCESS

The android helper's iOS spelling, one size smaller: a plain CLI run
with `simctl spawn` (no app, no UI, no bundle) CAN talk to the
pasteboard service. Its type list answers prompt-free — including
`dev.kaya/note` verbatim, confirmed from a genuinely different
process — and its DATA reads are gated by the SAME per-clip prompt,
which renders on the simulator screen with correct attribution both
ways (`"spawnread" would like to paste from "ClipProbe2"`). One
press later the read returns `note=1`, 6 bytes, byte-exact. So the
lane's expect_clipboard reader for EVERY kind is a spawned reader
plus a bounded press: one mechanism, covers the kind no other tool
can, and it is foreign in the only sense that matters — the system
itself gates it as another principal.

AND THE SPAWN-PER-READ IS STRUCTURAL, NOT OVERHEAD (measured
2026-08-20, hunting the ~2-3s each spawn costs the whale legs): a
RESIDENT `UIPasteboard.general` in a spawned process is frozen at
first access — a probe printing `changeCount`/`types`/`string` once a
second for 15s reported `count=0 types=[]` on every line while two
foreign writes replaced the board under it, and a fresh spawn
immediately after read the second write back fine. Not just the
change count (which was known not to cross): the entire view — types
and data both. So a serve-mode clipctl reading verbs from stdin can
never answer a read, and the per-op spawn is the only reader shape
this platform has. Anyone re-attacking clipboard-leg latency starts
somewhere else.

### 5. WHAT THE RUNNER ALREADY SETTLED (measured during recon)

The simulator pasteboard is strictly PER-DEVICE (two sims held two
different clips at once; the host board untouched), so iOS is the
android shape: the pool's per-leg device slot lock IS the clipboard
exclusion, and a drain bracket would be a barrier that cannot fail
for the reason it exists. `simctl`'s 18 "unhandled Platform key"
warning lines go to stderr and its pbpaste output has no trailing
newline — capture with `2>/dev/null`, compare byte-exact.

**PER-DEVICE ONLY WHILE Simulator.app IS NOT RUNNING** — this
paragraph was measured in exactly that state and finding 7 below is
the correction. The exclusion argument survives it (the slot lock is
still the only exclusion this lane needs); what does not survive is
the assumption that the board is the device's to begin with.

### 6. THE SEED CANNOT TRANSIT THE HOST BOARD (from the first lane runs)

The arm's first seed shape wrote the HOST pasteboard with the mac
spellings and pushed it with `pbsync host <device>` — and the lane
failed a DIFFERENT two of the four foreign reads on every run, each
answering "empty". Two defects stacked:

- `pbsync host <device>` exits rc=0 while DELIVERY IS STILL IN
  FLIGHT. The guest's read snapshots `types` mid-replacement and
  finds nothing; whether a given read lands before, inside, or after
  the window is a per-run coin flip, files (the slowest family)
  losing most often.
- The interpreter's settle-wait was VACUOUS: it polled `types` for
  the seeded kind, but the scene's own copy leaves a union clip
  carrying EVERY kind's type, so the poll was satisfied by the stale
  board before the seed landed. The wall the mac arm's settle
  provides was not standing here — a poll that cannot fail is not a
  wait. The settle now demands the CHANGECOUNT move first, then the
  type (both prompt-free).

The durable fix removes the transit entirely: `clipboard_seed` is a
spawned WRITER on the device (tools/ios/clipctl (gone) `write`), which is
synchronous and visible to other processes before the spawn exits
(measured, 246ms), keeps every leg on its own board — and keeps the
ONE macOS pasteboard out of a lane that runs beside validate-mac's
clipboard legs under validate-all, a collision the pbsync shape had
built in. check-steps' iOS clause pins the absence: a live
pbcopy/pbpaste/pbsync/`set the clipboard` line in run-sim.sh is a
failure, self-tested with the perturbation proven applied.

### 7. THE DEVICE BOARD IS SIMULATOR.APP'S TOO (measured 2026-08-03, the matrix-only empty read)

The two iOS clipboard legs were green SOLO, run after run, and failed
ONE step per five-lane matrix run — a different step each time, always
"reads empty". The unmeasured cell was what `types` said at that
instant. It says the board was REPLACED:

    read accepting=[image] enter cc=1021 types=["public.png"]
    data(public.png) -> nil in 53ms
    empty-answer        t+0   cc=1022 types=["public.utf8-plain-text"]

Fifty-four milliseconds, and the clip is somebody else's. Not an empty
snapshot, not a pasteboardd hiccup, not a prompt that went unanswered:
another principal's clip, whole, with the changeCount moved.

**Simulator.app relays the macOS pasteboard into and out of EVERY
booted simulator** when Edit > Automatically Sync Pasteboard is on,
which is the default (`PasteboardAutomaticSync` in
com.apple.iphonesimulator). Measured, on this machine, with the lane's
own tools:

- A host `pbcopy` replaced a booted device's html clip in **260ms** —
  the first poll after the write already read the host's text.
- Two booted devices ground each other's clips down to ONE board
  through the host: device A got html, device B got text, and three
  seconds later both offered the same types and the HOST pasteboard
  held device B's content.
- Quit Simulator.app and boot the same devices headless with `simctl
  boot`: no propagation at all, in either direction, across 36
  seconds of polling — each board kept what it was given and the host
  kept its own. That is finding 5's measurement, and it is only true
  in that state. (Quitting the app SHUTS DOWN every device it is
  showing, which is worth knowing before doing it mid-session.)
- A running Simulator.app IGNORES `defaults write ...
  PasteboardAutomaticSync -bool NO`: the relay went on working with
  the pref reading 0. The pref is read at launch, so it can only be
  believed about the NEXT launch — which is why nothing here reads it
  to decide anything.

That is the whole matrix-only story. Under validate-all the mac lane
rewrites the macOS pasteboard for eight languages throughout the iOS
lane's ~90-second clipboard leg (pbcopy, and osascript for html, png
and file urls), and every one of those writes lands on the simulator
too. Whether it falls inside the window between the guest's own write
and the read that follows it is a coin flip, which is exactly why a
different step failed each run. Reproduced deterministically two ways:
two clipboard legs on two devices concurrently (5 of the first 6 legs
failed), and — the matrix's own shape — ONE leg beside a loop that
wrote the host pasteboard every two seconds (3 legs, 3 failures, with
the churn's own png and html arriving on the device board under their
own types).

The lane cannot make itself immune: a shared board with a live writer
has no read that cannot be clobbered, and the scene's whole design
needs one clipboard it owns. So `tools/ios/run-sim.sh` MEASURES the
isolation before any leg (`clip_relay_check`: two devices, two
different clips, each must keep its own; types only, which is
prompt-free, and no host pasteboard write — the mac lane is using
that board) and refuses the run with the remedy named. Five seconds
per lane run, on the path every leg already walks.
`tools/probe-env.sh` reports the same thing early, by naming the app
rather than the pref.

The guard was watched failing before it was believed: with the relay
live it names both tells (device A lost html, device B gained it) in
2s; with Simulator.app relaunched after the pref was turned off it
passes in 5s and a host `pbcopy` no longer reaches the device.

One line of the backend is the other half of this. A read that
answers nothing now says so on stderr with the offer list beside it —
`KAYA_CLIP_TRACE: read of [dev.kaya/note] answered empty; the
clipboard offered ["public.png"]` — which is the sentence that turns
"label#0 reads empty" into a diagnosis. The guest still cannot tell
empty's four causes apart (denied, unfocused, absent, unaccepted) and
still must not; the BACKEND knows what the board held, and saying it
costs nothing on the path that answers.

WHAT WAS NOT ADDED, and why. A bounded re-poll of the read ("an empty
snapshot is not an answer") was the expected shape before the
measurement and is NOT here. With the relay live, one read did show a
true un-answer — `public.file-url` on the board and `urls` answering
0, then 1 two hundred milliseconds later, with the changeCount moving
in between, i.e. the relay re-delivering the clip. With the relay off
it did not recur: 20 legs under twelve CPU hogs and a host pasteboard
rewritten every two seconds answered every read first time, and the only
`KAYA_CLIP_TRACE` line in each was the scene's own legitimate empty
(a files-accepting read while the board holds text). Retrying a
foreign read is also not free: each attempt can re-raise the per-clip
prompt, so a user who denied one paste would be asked again. If a
future run measures an un-answer with no relay in the picture, that is
the moment for the re-poll, and the trace line above is what will say
so.

The android lane makes the same claim honestly, which is worth the
contrast: §7 finding 4 measured the emulator-host clipboard bridge
severed in both directions, and that lane BOOTS its emulators
`-no-window` — the isolation is a flag it owns. This lane cannot own
whether a developer has Simulator.app open, so it measures instead.

### The arm's decisions, from the findings

Copy: `items=` union, one path. Read/paste: background queue plus a
press request over the host bridge, tolerant of no alert appearing
(own-content reads never prompt). Seeds: the spawned writer, on the
device (finding 6). expect_clipboard: the spawned reader + press. The
role-enablement intersection reads `types` live (prompt-free), so
harness activations — which resolve through the model on iOS — see
fresh enablement with no rebuild machinery. Legs: rust and swift
(the two languages with iOS guests; the other six have no iOS tier
at all — that is the sweep verdict, do×2/can't×6), phones only (the
pad is a lockless single device and the form-factor gate needs no
clipboard), one leg per device slot, no drain.

## §9 — what the MATRIX charges the mac seed (measured 2026-08-04)

The first five-lane runs with all four clipboard lanes green killed one
mac clipboard leg per run — a different guest each time (swift, then
haskell), always the same line: `clipboard_seed files never appeared on
the clipboard`, always after the settle's whole deadline, and widening
that deadline from 5s to 15s changed nothing. validate-mac alone was
232/232, repeatedly.

### 1. THE WRITE NEVER HAPPENED — `set the clipboard to` refuses in silence

The seed's exact command, against a competitor writing the board with
plain `pbcopy` every 10ms, with a 1ms poll watching for the type after
it (`seedprobe.swift`, in the session's scratch):

| competitor        | writes | landed | osascript |
|-------------------|--------|--------|-----------|
| none, heavy load  | 200    | 200    | rc=0, silent |
| `pbcopy` @ 10ms   | 12     | 0      | rc=0, silent |

The type never appeared ONCE at 1ms resolution — the write is dropped,
not overwritten. That is `badPasteboardSyncErr`'s shape (a Pasteboard
Manager write against a board another process has modified) with
AppleScript swallowing the error. `POSIX file "<missing path>"` is the
same silence for a different reason: rc=0, nothing printed, board
untouched.

So the defect needs a SECOND PRINCIPAL on the one macOS pasteboard,
which is exactly what the matrix adds. CPU load does not do it: 200/200
landed under twelve spinners plus a looping `cargo build -j 18`, and 24
clipboard legs across four languages passed under the same load.

### 2. THE SETTLE WAS VACUOUS FOR THREE OF THE FOUR SEEDS

The mac arm polled the TYPE alone. The scene's own copy leaves a union
clip carrying nearly every kind's type, so `text` (twice) and — after
osascript writes a text representation beside a file url — the second
`text` seed were satisfied by the STALE board before their write landed.
`files` is not special because file urls are fragile; it is one of the
only two seeds whose wait could ever fail. That is §8 finding 6's
vacuity, on the other platform, found from the other end: a dropped
`text` seed does not fatal, it shows up as a wrong label three steps
later.

### 3. WHO THE OTHER WRITER IS — not proven, and the fix does not depend on it

Ruled out by measurement or by the record: the mac lane itself (its
clipboard legs are drain-bracketed), the android pool (§7 finding 4,
bridge severed both ways, `-no-window`), the iOS lane (Simulator.app not
running, and run-sim.sh refuses a live relay — §8 finding 7). Left
standing: this machine's Windows VM carries `/Sharing/ClipboardSharing
= True` with the SPICE vdagent channel live on its qemu command line
(UTM 4.7.5 drives `NSPasteboard` from CocoaSpice's `CSSession`), and the
windows lane runs five clipboard legs of 10-12s each, concurrent with
the mac lane's clipboard block. Confirming it means making the guest
copy, which this session was not to touch. A promised-type probe also
showed SOMETHING reading every clip within 15ms of it being written.

### The arm's decisions, from the findings

One body for both platforms (`kayaClipBoardNow` is the only place the
two boards differ), because the two arms had already drifted into
different rules for the same verb. The settle demands the changeCount to
move AND the type to appear. A write that has not landed within a second
is MADE AGAIN, up to the 15s deadline — idempotent by construction, and
the only answer to a write that was refused rather than delayed. A file
that is not there fails by name. The tool's exit status and stderr are
carried (`KayaToolRun`) instead of discarded, the seed fails with the
tool's own words, and a read whose tool refused says so
(`KAYA_CLIP_TRACE: osascript exited 1: ...`). The fatal lists every
distinct clip the wait saw, `+Nms cc=NNN [types]`, which is what tells
"nobody ever wrote" from "somebody else is writing this board too".

Guard: `kayaRunTool` lost `@discardableResult` and the interpreter now
compiles with `-warnings-as-errors` in both build-dylib.sh and
swift-typecheck.sh, so dropping a tool's result is a build error rather
than a warning nobody reads (watched failing, perturbation proven
applied — and the first version of the guard was watched NOT failing).

Sweep, one verdict per backend: mac and iOS share the fixed body (do,
do); GTK already asserts its writer's exit status and its lane owns a
private compositor per container, so the class is unreachable there
(defer, with the shape to copy if that ever changes); WinUI writes once
and polls `Contains*` for 5s, the same shape, and its board has the same
SPICE relay on the other side of it — but that arm was settled the same
day and is out of scope here (defer, named in deferred.md's ledger if it
ever fires).

## §10 — what the MATRIX charges the mac PASTE (measured 2026-08-04)

§9 fixed the seed's write. The same matrix run then failed one leg
further down the same scene, and this is that half: not the seed, the
GESTURE.

    KAYA_HARNESS: +574ms clipboard_seed text "pasted by hand"   (settled, 12ms)
    KAYA_HARNESS: +586ms click button#5
    KAYA_HARNESS: +586ms expect_focused entry#0
    KAYA_HARNESS: +611ms menu_activate "Edit>Paste"
    KAYA_HARNESS: +611ms expect label#0 "pasted pasted by hand"
    kaya: THE APP THREAD IS STALLED — 13 occurrences ... waiting 1027ms
    KAYA_HARNESS: step-failed label#0 reads "files pasted.txt pasted bytes"

### 1. THE STALL LINE WAS NOISE, AND IT COST THE FIRST HOURS

The watchdog compared two counters and only one of them moved for a
guest that reads the occurrence ring directly, so go, csharp, ocaml,
haskell and java reported a stall on EVERY healthy run — visible only
when a leg lived long enough to cross the 1s threshold, which a failing
leg does and a passing one does not. Measured on a PASSING haskell
clipboard leg, varying only `KAYA_STALL_MS`: 1ms/50ms/100ms/400ms all
report, with the pending count tracking the running total of
occurrences. Fixed in crates/kaya/src/stall.rs (each transport asked in
its own terms) and guarded by a new `expect_no_stall` in
tools/scenes/stall.steps. Full account in docs/traps.md.

### 2. THE PASTE WAS DISABLED, AND A DISABLED COMMAND IS SILENT

The proof is a line that is NOT in the log. Since §9 every nil read
prints `KAYA_CLIP_TRACE: read of [...] answered empty; the clipboard
offered [...]`. The failing paste printed none — so the paste never
reached the read, and the only gate before it is
`kayaRoleEnabled("paste")`: something focused, something on the board it
takes. `expect_focused entry#0` had passed 25ms earlier, so the board
had lost `public.utf8-plain-text` between the seed's settle and the
activation.

Reproduced deterministically, no concurrency needed — a second seed of
an IMAGE stands in for the foreign write:

    clipboard_seed text "pasted by hand"
    click button#5
    expect_focused entry#0
    clipboard_seed image "$TMP/kaya-clip-$PID/pixel.png"
    menu_activate "Edit>Paste"
    expect label#0 "pasted pasted by hand"

`step-failed label#0 reads "ready"`, in rust and haskell alike (the
mechanism is the interpreter's, not any guest's), with no other output.
The second half of the scene reproduces the run's other line: entry#1
declares no accept list, so its gate is
`canReadObject(forClasses: [NSString.self])`, equally false for an
image-only clip, and `entry#1 reads ""`.

### 3. THE SECOND PRINCIPAL, AGAIN — and this time it is dated

§9 left the writer unproven. The timeline of the failing run pins the
opportunity: `Windows.utm/config.plist` was set to
`ClipboardSharing = False` at 08:07:29, the run built at 08:09-08:11 and
wrote its log at 08:15, and the VM process carrying the SPICE vdagent
channel was not restarted until ~08:20. UTM reads that setting when the
VM starts, so the relay was live throughout the leg — and the windows
lane was running its own five clipboard legs at the time, each copying
text, html, an image and files on the Windows side. vdagent relays text
AND images; an image clip on the macOS board is exactly this failure.

### The arm's decisions, from the findings

INERT STAYS INERT. A role command that cannot act does nothing, on every
backend, exactly as native chrome leaves a greyed item. Nothing here
changes dispatch.

BUT IT SAYS SO. `kayaRoleInertNote` (mac and iOS, one body) prints the
intersection that came up empty when a harness `menu_activate` lands on
a disabled role item: what is focused, what it accepts, what the board
offers, and at what changeCount.

AND KAYA KNOWS WHICH BOARD IS ITS OWN. `kayaClipOwned` records the
changeCount after every write kaya asked for — the app's own copy, and
any seed that settled — so `kayaClipOwnerClause` can append "AND THE
BOARD HAS MOVED SINCE KAYA WROTE IT (cc N -> M): another process is
writing this clipboard" to the inert note and to the empty-read note. A
pasteboard has no "who wrote it"; this is the nearest thing there is,
and it is the sentence that separates a kaya defect from a neighbour.

Sweep, one verdict per backend: mac and iOS share the note (do, do);
GTK defers (a private compositor per container — no second principal);
Compose defers (one board per device, bridge severed, §7 finding 4);
WinUI defers and is the likeliest to want it, its board having the same
relay on the other side — recorded in docs/deferred.md rather than
built, since that arm was settled 2026-08-03.

## §11 — the matrix — DONE

The full matrix (validate-all) once the mac seed's and paste's fixes
have ridden it. It did, 2026-08-04, and the milestone closed there;
docs/deferred.md's struck Clipboard entry carries the closing record.
