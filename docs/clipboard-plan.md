# Clipboard — the executable plan

The design below was worked out 2026-08-01 and is not yet in DESIGN.md;
move it there when it is ratified. Sequencing follows CLAUDE.md's
depth-then-breadth rule: protocol, one backend, one binding, the scene,
green on mac, only then fan out.

Nothing here is settled except §0, which records the decisions already
made and the reasoning that produced them. Several of those decisions
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
   means tools/ios/simdrive again.
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
app must drive the alert, which means tools/ios/simdrive again, exactly
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
and reads it back, with `pbpaste -Prefer dev.kaya.note` confirming from
outside that the bytes really are there under that id.

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

## §5 onwards — to be written

The fan-out: seven more bindings, three more backends, and the Android
helper APK, then the matrix.

Next: the SwiftUI arms on mac (NSPasteboard), the `accepts` lowering
and the paste hook, Cut/Copy/Paste as standard commands (the gesture
layer §0 argued the data layer cannot replace), the Rust binding, the
scene. Then the fan-out — seven more bindings, three more backends, the
Android helper APK — and the matrix.
