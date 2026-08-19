# Save probe — Linux / GTK4 arm

Repo: /Users/akhilindurti/Projects/kaya @ aeb135a (MEASURED: `git log -1`).
No repo file changed. Probes: `/private/tmp/claude-501/-Users-akhilindurti-Projects-kaya/24aa5ebf-e439-4206-9ba0-de67540e4b06/scratchpad/saveprobe/ (gone)`
Every claim tagged MEASURED / DOCUMENTED / ASSUMED.

Platform under test: the repo's own linux lane — the `kaya-linux` image
(tools/linux/Dockerfile), GTK **4.18.6**, X11 under Xvfb, per-leg AT-SPI bus via
tools/linux/a11y-leg.sh. MEASURED in the image: `pkg-config --modversion gtk4` =
4.18.6, and **no xdg-desktop-portal installed** (`dpkg -l | grep -i portal`
empty) — which is the condition crates/kaya/src/gtk.rs:4573-4578 already states
and the reason GTK presents its own chooser in-process.

---

# VERDICT A — WRITE MODE TODAY = **WORKS**

Not unimplemented, not partial, not silently wrong. It works on Linux/GTK, in
both write modes, from both the Python and the Go tiers, with the correct
truncation semantics and a faithful errno. What it CANNOT do is create a file
that does not exist — and that, not write mode, is what blocks an editor.

## A.1 Why FILE_MODE_WRITE appears zero times in gtk.rs

Because the GTK arm never sees a mode. MEASURED, reading end to end:

- capi.rs:1403 `kaya_open_picked(handle, mode, out_handle, out_seekable)`; the
  mode is decoded at capi.rs:1419-1424 into `protocol::FileMode`, and an
  unknown mode returns EINVAL(22) (capi.rs:1423, `libc_einval` capi.rs:1439).
- capi.rs:1425 `source.open(mode)` — dispatch to the backend-registered
  `PickedSource` (protocol.rs:111-142).
- gtk.rs:4568-4680 `ApplyOp::PresentFileDialog` builds a `gtk4::FileDialog`,
  calls `open()`/`open_multiple()` on the parent window, and in the completion
  registers `protocol::PathSource { name, path }` (gtk.rs:4621-4626) built from
  `gio::File::path()` / `basename()` (gtk.rs:4641-4645). The pasted-file door
  registers the identical source (gtk.rs:3405-3410).
- protocol.rs:230-244 is where the three modes become real:

      Read      -> OpenOptions.read(true)
      Write     -> OpenOptions.write(true).truncate(true)
      ReadWrite -> OpenOptions.read(true).write(true)
      ...       -> opts.open(&self.path)?;  seekable = metadata().is_file()

  **No arm carries `.create(true)`.** That single omission is verdict B's real
  problem (A.4).

The GTK backend's whole contribution is "register a path". The mode travels
from the guest through the C ABI into `std::fs`. So the absence of the string
FILE_MODE_WRITE in gtk.rs is correct, not a gap.

## A.2 Driven for real — probe A

Throwaway Python guest `saveprobe/probe_write.py` and Go guest
`saveprobe/goprobe/main.go`, run as real legs against the already-built
`target-linux/debug/libkaya.so`, with the harness script in
`KAYA_SELFTEST_SCRIPT`, inside `tools/linux/a11y-leg.sh` under `xvfb-run`. The
GTK chooser is presented for real and driven over AT-SPI by the harness's own
`file_choose`, exactly as tools/scenes/filedialog.steps drives it. All legs
ended `KAYA_SELFTEST: OK`.

MEASURED (python tier):

| leg | mode | result |
|---|---|---|
| `target.txt`, 12 bytes | `FILE_MODE_WRITE` | open ok, `seekable=True`, python `mode='wb'`; **size after the open and before any write = 0** (O_TRUNC really applied); wrote 5 -> disk `b'WROTE'`, 5 bytes |
| `rwtarget.txt`, 12 bytes | `FILE_MODE_READ_WRITE` | open ok, `seekable=True`, `mode='rb+'`; size after open = 12 (**no truncation**); wrote 2 at offset 0 -> `b'RWBBBBBBBBBB'`, 12 bytes |
| `ro.txt`, mode 0444, **run as uid 1500** | `FILE_MODE_WRITE` | `code 13` = EACCES; file untouched |

MEASURED (Go tier — the editor's language, same lane, `go build` against
`dev.kaya/bindings/go` with a scratch `replace`):

    GO-W    open ok seekable=true size-after-open-before-write=0 -> "WROTE" (5)
    GO-RW   open ok seekable=true size-after-open-before-write=12 -> "RWBBBBBBBBBB" (12)

The read-only leg had to be re-run unprivileged: the container is root, and root
bypasses 0444 — the first run cheerfully wrote a read-only file. MEASURED both
ways; the uid-1500 run is the honest one and matches what DESIGN.md:1211-1218
ratifies ("kaya surfaces the platform's answer... opening a read-only document
for writing FAILS, in the guest's ordinary error idiom").

The errno crosses intact (13 EACCES, 2 ENOENT): capi.rs:1433 returns
`e.raw_os_error()`, and the bindings re-raise it (python
bindings/python/kaya/runtime.py:190-191; go bindings/go/runtime.go:320-322).

## A.3 What the existing unit test misses

MEASURED capi.rs:1480-1486 — the one write-ish assertion redeems a second time
with `FILE_MODE_READ_WRITE`, checks `rc == 0`, and drops the file immediately.
It never writes a byte and never asks for `FILE_MODE_WRITE` at all. So before
this probe the truncation semantics and the fact that a write lands were
untested everywhere. They now hold on Linux. ASSUMED: nothing follows for
mac / iOS / Android / Windows.

## A.4 The finding that matters: a picked handle cannot CREATE

MEASURED (`gone.steps`, both tiers): pick `target.txt` through the real chooser,
`unlink` it, then redeem the same live handle.

    FILE_MODE_WRITE       -> code 2 (ENOENT)
    FILE_MODE_READ_WRITE  -> code 2 (ENOENT)
    FILE_MODE_READ        -> code 2 (ENOENT)

and nothing is created. This is `PathSource::open` with no `.create(true)`,
measured rather than inferred.

That is exactly the state a save destination is in — B.2 measures GTK's save
panel answering with a path that does not exist. So today's machinery can save
BACK over a file the user already opened (DESIGN.md:1163-1164's flow, now
demonstrably working) and cannot save to a NEW file at all, whatever dialog
produced the name.

## A.5 Binding sweep (the mode is expressible everywhere)

MEASURED by reading each binding: all 8 expose the mode on the redemption call
— rust `PickedFile::open(FileMode)` (protocol.rs:83), python `open(mode=...)`
(`__init__.py`:1359, mode->`"rb"/"wb"/"r+b"` at runtime.py:198), go
`Open(mode uint32)` (runtime.go:316), c# `Open(uint mode = 0)` (Kaya.cs:33),
java/swift/ocaml/haskell constants + pass-through (KayaWire.java:88-90,
KayaApp.swift:716, kaya_wire.ml:90-92, KayaRuntime.hs:409). MEASURED at runtime
for python and go only.

---

# VERDICT B — SAVE DIALOG

**The API kaya would call: `gtk4::FileDialog::save()`** — the same object the
open path already builds at gtk.rs:4581, with `set_initial_name()` and
optionally `set_accept_label()` added. MEASURED present in the pinned crate:
`gtk4` 0.11.4 with feature `v4_10` (crates/kaya/Cargo.toml:134), `pub fn save`
at `~/.cargo/registry/src/.../gtk4-0.11.4/src/auto/file_dialog.rs:410`,
`set_initial_name` at :769. DOCUMENTED: `Gtk.FileDialog` since GTK 4.10,
`save_finish()` "returns the file that was selected" and sets
`GTK_DIALOG_ERROR_DISMISSED` on cancel
(https://docs.gtk.org/gtk4/class.FileDialog.html,
https://docs.gtk.org/gtk4/method.FileDialog.save_finish.html).

## B.1 It presents exactly like the open picker

Probe B: `saveprobe/gtk_save_app.py` (plain GTK4 via GI, no kaya) presents
`Gtk.FileDialog.save()` on a real window; `saveprobe/drive_save.py` walks and
drives it over AT-SPI from a second process on the same bus;
`saveprobe/run_b.sh` builds the a11y session the way a11y-leg.sh does.

MEASURED — the save panel's AT-SPI tree is the open chooser's tree plus one
control:

- one `role='dialog'` node, in **our process**, on the same bus (same condition
  as the open picker; no portal in the image);
- path-bar toggle buttons `['/', 'tmp', 'saveprobe-dir', 'Create Folder',
  'Text']` with **`saveprobe-dir` PRESSED** — so gtk.rs's existing directory
  read (gtk.rs:7718-7724: in-dialog ToggleButton with `Pressed`, combo
  excluded) works on the save panel **unchanged**;
- rows in the same one-name-per-line format, `'existing.txt 12 bytes Text
  03:09'`, under a `list` inside a `tree table`, header row included — so
  gtk.rs:7726-7731 works unchanged;
- buttons `['Grid View', 'Create Folder', 'Cancel', 'Save']` — the accept button
  is **"Save"**, not "Open";
- **new**: `role='text' name='Name:'`, `states=[editable, focusable, focused,
  ...]`, `ifaces=[..., EditableText, Text]`, prefilled with `initial_name`.
  MEASURED drivable: `Atspi.EditableText.set_text_contents` returned True and
  the text read back changed `'untitled.txt' -> 'brandnew.txt'`.

## B.2 What it answers with

MEASURED, three cases:

| case | answer |
|---|---|
| type `brandnew.txt`, press Save | `GLocalFile`, `path='/tmp/saveprobe-dir/brandnew.txt'`, `uri='file:///tmp/saveprobe-dir/brandnew.txt'`, and **`exists-when-dialog-answers: False`** — GTK does not create it; the app does |
| type `existing.txt` (already on disk), press Save | GTK raises a SECOND modal: buttons become `['Grid View','Create Folder','Cancel','Save','Cancel','Replace']`. Pressing **`Replace`** completes; the callback gets the existing path, `exists=True` |
| press Cancel | `GLib.Error domain=gtk-dialog-error-quark code=2 message='Dismissed by user'` — the same DISMISSED shape the open arm already maps to the empty list (gtk.rs:4612-4615) |

So the save panel hands back a **name**, exactly like the open panel hands back
a name; the difference is that the name usually points at nothing yet. Combined
with A.4, a save destination registered as today's `PathSource` would refuse to
open in all three modes with ENOENT. **The core needs a create-capable source
before any save dialog is useful** — that is the real work, and it is invisible
from the dialog side.

DOCUMENTED, the portal case (not measurable in this image): under a sandbox, or
with GTK routed to the portal, the panel is another process and the answer comes
from `org.freedesktop.portal.FileChooser.SaveFile`, whose response carries
`uris` — "exactly one element. All URIs have the `file://` scheme" — with
`current_name`/`current_folder`/`current_file`/`filters` as request options
(https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.FileChooser.html).
GTK's own docs say a sandboxed app's native chooser goes through the portal
(https://docs.gtk.org/gtk4/class.FileChooserNative.html). ASSUMED, and flagged
as a real hole: nobody in this repo has ever run a leg against a portal-hosted
chooser — gtk.rs:7654-7657 and docs/traps.md:1898-1902 say the AT-SPI walk
starts at the desktop so it "would still find it", which is reasoning, not a
measurement. Whatever else the save milestone does, it does not close that hole
either.

## B.3 The harness story

- **The existing `file_choose` verb cannot drive a save panel, and fails
  loudly** rather than silently. MEASURED by reading harness.rs:2114-2135: it
  first requires the named row to be present in `file_dialog_state()`, then
  calls `choose_file`, then POLLS until the dialog is gone and reports if the
  press did not take. On a save panel `choose_file` presses "Open"
  (gtk.rs:7198), no such button exists (B.1), the dialog stays live, and the
  poll fails. Good failure, wrong verb.
- **What a save leg needs**: a verb along the lines of `file_save_as <name>` —
  set the `Name:` entry's text (AT-SPI `EditableText`, measured working), press
  `Save`, and handle the `Replace` confirmation when the name exists. Plus a
  read verb, or an extension of `expect_file_dialog`, that asserts the entry's
  current contents — because the one thing unique to a save panel is that the
  suggested name is right.
- **What it would assert, end to end** (the filedialog scene's own standard —
  all the way to the bytes): destination did not exist before; the guest wrote
  N bytes through the handle it was given; the file now exists with exactly
  those bytes; and a second save over the SAME name goes through the Replace
  path and truncates rather than appending.
- **Where the cost multiplies**: `Stage` (harness.rs:596) would gain a method,
  which means GtkStage (gtk.rs:5730), WinUiStage (winui/mod.rs:7520) and three
  mock stages in harness.rs; and tools/check-verbs.sh requires every harness
  verb to appear in BOTH interpreter files (swift/KayaSwiftUI.swift and
  android/.../KayaCompose.kt (gone)), where the save panel has to be driven again in
  Swift and in Kotlin.

## B.4 Honest size, in this repo's units: **a MILESTONE, not a depth slice**

The GTK arm itself is the cheap part — perhaps 15 lines, because everything
around it already exists and was MEASURED to work unchanged on the save panel:
the one-live-dialog slot (capi.rs:1531), the retire path
(`file_dialog_retire`), the result occurrence, the DISMISSED-to-empty mapping,
the directory read, the row read, and the filter list. What makes it a
milestone is everything the invariants make mandatory:

1. **Spec change** (crates/kaya/src/spec.rs:827-850). Either a new record or a
   kind field on `show_file_dialog` — which conveniently already carries a
   `reserved: U32` at spec.rs:834 (MEASURED). The spec hash moves; every
   generated surface regenerates in lockstep (invariant 7).
2. **Core semantics change, the load-bearing one**: a create-capable picked
   source. `PathSource::open` gains a create arm, or a distinct
   `SaveDestination` source, and the choice has to be made for all five
   platforms at once — Android's `CreateDocument` contract hands back a
   `content://` URI whose PROVIDER creates the file, so the mode strings
   (protocol.rs:217-223) are in scope too.
3. **Four backends**: GTK `FileDialog::save`, SwiftUI (`NSSavePanel` /
   `.fileExporter`), WinUI (`FileSavePicker`), Compose
   (`ActivityResultContracts.CreateDocument`). Each answers a different object;
   each has to register a source the core can redeem.
4. **Eight bindings plus the C floor**, with sugar in all of them
   (check-sugar-surface.sh) — invariant 2 forbids scoping this to Go.
5. **Both interpreters** carry the new verb and constants (check-verbs.sh), so
   the save panel is driven a third and fourth time in Swift and Kotlin.
6. **One new shared scene** (tools/scenes/*.steps, byte-identical strings
   across languages — invariant 6), run on five lanes.

The nearest precedent in the ledger is the clipboard, which is exactly this
shape. docs/deferred.md:944-949 already books it: "file dialogs — ... Open comes
first, save second."

## B.5 The useful consequence for the editor

MEASURED: an editor on Linux can ship **Open -> edit -> Save** today, with no
protocol change, no new backend arm and no new binding surface — pick with the
existing picker, redeem with `FILE_MODE_READ_WRITE` (or `FILE_MODE_WRITE` to
truncate), write through the descriptor. The Go tier does it in this repo's own
image. Only **Save As / New file** needs the milestone above, and it needs the
create-capable source (A.4) at least as much as it needs the dialog.

---

## Cleanup

Probes ran only inside `docker run --rm` containers (`--rm`, so no container
survives) and one `go build` inside that container. Nothing was started on the
host; no window opened on the user's machine (Docker's Linux VM + Xvfb). No
GUI lock was taken because nothing touched the host GUI session.
