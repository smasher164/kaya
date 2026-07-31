# Handoff — file dialogs, what is left after Compose

Written at the end of the session that landed the Compose picker arm.
Delete this file once §6 is done; it is a continuation note, not
doctrine. Everything durable here is already in DESIGN.md,
docs/traps.md, or docs/file-dialogs-plan.md — this only says where the
work stopped.

## State

- **The last eight commits are LOCAL ONLY**; `origin/main` is still at
  `28bec96`. Nothing has been pushed since the background-scene comment
  fix.
- Last full matrix: ALL PASS, 813 legs (mac 209, linux 386, windows 131,
  ios 41, android 46).
- 209 unit tests, every fast gate green, check-gtk green.

## What §6 has landed

- **GTK** (`b447f23`), **WinUI** (`116b8c9`), the one-`i64` picked
  handle (`5e1695d`), and Android's harness accessibility service
  (`1057cb2`, `50f2391`).
- **Compose**, this session: `ACTION_OPEN_DOCUMENT` through
  `activityResultRegistry`, driven over the accessibility service, and
  an Android source that holds the `content://` URI and opens it through
  the ContentResolver on every redemption. The re-openability the design
  chose that shape for is now measured, not assumed
  (docs/file-dialogs-plan.md §6d).

The scene is still rust-only and reads the picked file OFF the app
thread, parking between read and post.

## Next: §6e, iOS

`UIDocumentPickerViewController`. The iOS half of
`swift/KayaSwiftUI.swift` still declares `kayaDepthStub("filedialog",
on: "ios")`, so check-steps will demand the leg the moment that goes —
that is the gate holding the work open, not a regression.

`tools/ios/scopeprobe/` already measured ON HARDWARE that the open
picker grants write, and that the simulator cannot answer sandbox
questions at all (docs/traps.md). MEASURE FIRST anyway: this milestone
is five for five on probes overturning an assumption per platform, and
the Android one overturned four.

The iOS source holds the security-scoped URL rather than a path
(measurement 4 in DESIGN.md: the path EPERMs once the scope drops), so
it is the same shape as Android's `UriSource` — a token kaya can still
redeem — and `kaya_emit_file_dialog_result` already dispatches per
platform for exactly this.

## After that

- **§6f** the seven remaining guest languages, with an explicit
  do/can't/defer verdict each (CLAUDE.md, invariant 2). No binding
  except Rust has the picker surface yet.
- **§6g** the full matrix.

## Things that cost time, so they do not cost it twice

All in docs/traps.md with more detail. The Android ones from this
session: DocumentsUI has two package names, the temp directory is
invisible to it, a bad `EXTRA_INITIAL_URI` lands on Recent silently,
there is no Open button and no Cancel button, one BACK is not enough,
the drive must not run on the main thread, and `w` does not truncate.
Plus three ways an Android rerun silently measures the run before it.

And one that had nothing to do with this work: a Windows notification
toast holds the foreground and kills all ten shortcut-injection legs,
invisibly. Take a screenshot of the console session first when a windows
failure implicates the desktop.
