# Attaching a photo and showing it inline — the design pass

Status: BUILT 2026-09-26 on all five platforms and in all nine bindings, R1-R3
RULED 2026-09-25 as recommended. The chat app's C6
(docs/chat-plan.md). Researched 2026-09-25 with sources. The chat plan's
"nothing new for display" was wrong: see §2.

## §1 — Picking

The open-file dialog gains a `content: images` choice in its reserved
field. On the phones it opens the photo library's own picker; on the
desktops it opens the ordinary open dialog filtered to images. The result
is the same picked handle any open dialog answers, redeemed read-only
through `kaya_open_picked`, and a cancel is still an empty list.

| platform | lowering |
|---|---|
| iOS | `PHPickerViewController` with `filter = .images`: no permission prompt, and the file it hands over is deleted when its completion handler returns, so the backend copies it inside the handler (today an image filter opens the Files browser, `UIDocumentPickerViewController`) |
| Android | the photo picker, `ActivityResultContracts.PickVisualMedia(ImageOnly)`, built in on API 30 and later and falling back to `ACTION_OPEN_DOCUMENT` by itself; its read-only `content://` answer fits the handle table as it is (today the document picker opens) |
| macOS | `NSOpenPanel` with `allowedContentTypes = [.image]`; the panel's sidebar already lists the Photos library |
| Linux | the file dialog with an `image/*` filter; there is no photo library |
| Windows | the open dialog filtered to the image extensions; there is no photo library |

## §2 — Showing

An image draws at its picture's natural size today (no widget has a size
prop), so a 12-megapixel photo would lay out 4032 by 3024. C6 needs one new
image prop: a bounded fit that scales the picture down inside a box with
its shape kept, and never up. Lowered to `.resizable().scaledToFit()` in a
frame, `ContentScale.Fit`, `GtkPicture`'s contain fit, and
`Stretch.Uniform`, with an `expect_image_size` verb in all three harnesses.

The chat app adds a `Photo` message case whose row shows the image under
that bound.

## §3 — Rulings (RULED 2026-09-25 as recommended: one dialog, `max_width`/`max_height`, JPEG from iOS)

- **R1 — one dialog or two.** RULED: one open dialog with a
  `content: images` choice (the same grammar, handle and one-dialog-at-a-
  time rule), rather than a separate photo request that differs only in
  its lowering.
- **R2 — the size prop's shape.** RULED: `max_width` and
  `max_height` in points, scaling down only. The alternative is a `fit`
  enum working with the layout's own sizes, which is more general and
  larger.
- **R3 — HEIC.** iPhone photos are HEIC by default, and GTK and Windows may
  not decode it. RULED: iOS hands over a JPEG
  (`preferredAssetRepresentationMode = .compatible`), so a photo sent from
  a phone opens everywhere.

## §4 — How a leg sees it

The iOS simulator takes photos with `xcrun simctl addmedia`, and the XCUITest
driver taps the picker's grid. The Android emulator has none: a pushed file
must be registered with the media store, and the picker runs in a different
package than the document picker, so the lane's accessibility reader learns
its name (both measured before building). The desktops reuse the open
dialog's existing drives.

## §5 — As built: the shape and the order

- The request's reserved word becomes `content`, a `file_content` enum:
  `any` 0, `images` 1. Both records carry it (`show_file_dialog`, and its
  apply twin `present_file_dialog`). The answer is unchanged.
- `max_width` (42) and `max_height` (43) are image props in points, in both
  zones, a positive number each; the picture scales down to fit inside both
  with its shape kept and never scales up.
- `expect_image_size image@x WxH` reads the DRAWN box in points, rounded,
  beside `expect image@x WxH`, which reads the decoded picture.
- The scene's photo is a kaya asset, `images/photo.jpg`. The desktops place
  it with a harness verb, `copy_asset <name> <path>`, through the core's
  one resolver, and pick it by name as the open dialog's scene does. The
  phones put it in the photo library from the lane before the leg (`simctl
  addmedia`, the media store) and `file_choose` there picks the newest photo,
  since a photo grid shows no names. Either way the leg then reads the
  picture's decoded size, so a wrong photo fails.
- The chat app adds an attach button (the `attach` symbol) inside the
  composer and a `Photo` message case showing the picture under a
  240-point bound. A photo is not sent over the scripted peer's text wire;
  the peer answers the text it is sent.

Order: the spec and core, then SwiftUI on the mac with the Go binding and
the chat app and scene, then the other four backends and eight bindings,
then the phones' pickers and their lane staging.

## §6 — As built: the drives and the guards

- iOS: the photo picker is `PHPickerViewController`; the XCUITest driver reads
  it as a navigation bar named Photos over images identified
  `PXGGridLayout-Info` and labelled "Photo, <date>", newest first, and taps the
  newest at its centre (XCUITest calls the grid's images not hittable). Its
  verbs are `photostate`, `photochoose` and `photocancel`.
- Android: the contract's `ACTION_PICK_IMAGES` opens the media provider's
  picker; the harness service reads its grid (`picker_tab_recyclerview`) and
  clicks the newest item described "Photo taken on <date>". The lane pushes
  the photo to shared storage and waits for the media library to list it.
- Linux: the chat leg runs through both the notification desktop and the
  accessibility bus, with `GDK_DEBUG=no-portals` so GTK's own chooser opens
  where the harness reads it (tools/linux/Dockerfile's portal note).
- Guards: check-sugar-surface demands the images option and both bounds in
  all nine bindings; check-steps now holds the file-dialog verbs to the
  accessibility-bus wrapper on Linux (the chat leg lacked it); the Go and C#
  generated row surfaces are held to forwarding the bounds by their own
  existing censuses; scene unit tests hold the bound's walls.
