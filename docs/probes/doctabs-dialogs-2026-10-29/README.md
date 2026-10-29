# Document tabs: the close dialog on iOS and GNOME (2026-10-29)

Two oddities on the doctabs review page's dialog captures, each measured
against the platform's own behaviour with a probe outside kaya.

## iOS: rows smeared through the alert over the documents sheet

`ios-kaya-alert-over-sheet.png` is the doctabs-swiftui leg on kaya-sim-2
(iOS 26.5), held 3 s after the alert appeared: the list's "New Document"
row, its capsule and the close buttons show through the alert's glass,
lensed. `ios-uikit-alert-over-sheet.png` is `ios-alert-probe.swift`, a
plain UIKit app with no kaya in it: a UINavigationController sheet at the
large detent holding an inset-grouped UITableView laid out like kaya's
(three rows, then "+ New Document", "a", "b", "untitled 1", blue close
images), and a UIAlertController presented once from that sheet. It
smears the same blue text and close buttons through the same glass rim.
So the smear is iOS 26's alert material over whatever sits behind it, and
kaya presents its alert once, from the topmost presented controller
(swift/KayaSwiftUI.swift, the alert arm). Nothing to fix in kaya.

Built with Xcode 26.6's `xcrun --sdk iphonesimulator swiftc -target
arm64-apple-ios16.0-simulator`, an Info.plist by hand, ad-hoc signed,
installed with simctl and screenshotted 5 s after launch.

## GNOME: the alert at the top left on the lane's X server

`gtk-alert-probe.py`, run under `xvfb-run` in the kaya-linux image, calls
`Gtk.AlertDialog.choose(parent)` with `modal=True` as the GTK backend does
(gtk.rs, `ApplyOp::PresentAlert`, `dialog.choose(Some(&parent), ...)`).
xprop on the dialog read:

    WM_TRANSIENT_FOR(WINDOW): window id # 0x600005   (the parent)
    _NET_WM_STATE(ATOM) = _NET_WM_STATE_MODAL
    _NET_WM_WINDOW_TYPE(ATOM) = _NET_WM_WINDOW_TYPE_DIALOG

and both windows sat at +0+0. GTK 4 leaves placement to the window
manager, and the lane's Xvfb runs none; under mutter a transient modal
dialog is centred on (and, with GNOME's attach-modal-dialogs, attached
to) its parent. So the top-left alert is the WM-less X server, and kaya's
alert already carries its parent and modality.
