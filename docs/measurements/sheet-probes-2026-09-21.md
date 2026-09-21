# Sheet probes: the three unknowns of docs/sheet-plan.md §2

Baseline 85dc511b. Each probe is a throwaway program against the platform's
own sheet, driven the way kaya's harness drives it, with every reading
printed against its own clock. Sources under
`target/session-notes/sheet-probes-2026-09-21/` (built).

## U3, GNOME: a modal over an AdwDialog (measured first)

Container `kaya-linux:latest` (Debian trixie, libadwaita 1.7.6, GTK 4.18.6),
Xvfb 1280x800, a python GI program (`adw_probe.py`), Esc through
`xdotool key Escape` at 700 ms steps:

| Step | Reading |
| --- | --- |
| `Adw.Dialog` A presented over the window | `mode=auto can_close=True` |
| `Adw.Dialog` B presented with A as its parent | presented: the chain draws |
| Esc with A and B up | `B closed`; A stays |
| `Adw.AlertDialog` presented over A | presented |
| Esc with A and the alert up | `alert response close`; A stays |
| A `can-close=False`, Esc | `A close-attempt (vetoed)`, A still mapped |
| `A.force_close()` | `A closed` |

So: dialogs chain, Esc reaches the topmost, `can-close` off is the veto with
`close-attempt` as its occurrence, and `force_close` is the programmatic
dismiss that ignores the veto. The arm maps `intercept_dismiss` to
`can-close` and `dismiss_sheet` to `force_close`.

## U2, macOS: Esc on a SwiftUI sheet

`mac_sheet_probe.swift`, compiled with the repo's `kaya_swiftc` wrapper, an
accessory-policy NSApplication hosting a SwiftUI root with three `.sheet`
modifiers; Esc is an NSEvent (keyCode 53) through `NSApp.sendEvent`, the
harness's own `type` route. Two runs (the first dismissed the plain sheet
before its chain step could run, which was itself the first finding):

| Step | Reading |
| --- | --- |
| plain sheet, no cancel button, Esc | `onDismiss` 2 ms after the key |
| child sheet presented from inside the parent sheet | draws over it |
| Esc with both up | the CHILD's `onDismiss`; the parent stays |
| Esc again | the parent's `onDismiss` |
| sheet with a `.keyboardShortcut(.cancelAction)` button, Esc | dismissed in 24 ms (the button's own action) |
| `interactiveDismissDisabled(true)`, no cancel button, Esc | still up 1 s later |
| the same sheet, `isPresented = false` | `onDismiss` 2 ms later |

The plan's first draft said SwiftUI does not wire Esc on macOS; it does.
Nothing to add for the cancel path; `interactiveDismissDisabled` is the
veto's switch and a programmatic dismiss still lands under it.

### U2b, macOS: the arm's first red, and where the armed sheet reads Esc

The depth slice's first leg failed at its first `dismiss_sheet`: the sheet
stayed up (the bundle's verb trace, `sheets 1, wanted 0` for fifteen
seconds). The arm differed from the probe above in two ways, so two more
probes (`esc_probe.swift`, `esc_probe2.swift`, the same shape and route)
measured each alone and together:

| Sheet content | Esc | Reading |
| --- | --- | --- |
| a label, `.onExitCommand(perform: nil)` | to the key window | dismissed in 2 ms |
| a label and a `TextField` | to the key window | dismissed in 3 ms |
| a label, a `TextField`, `.onExitCommand(perform: nil)` | to the key window | still up 1 s later; a programmatic dismiss lands |
| armed (`interactiveDismissDisabled`), a label, `.onExitCommand { … }` | to the sheet window | the handler never fires; first responder is the sheet window itself |
| armed, a label, a `TextField`, `.onExitCommand { … }` | to the sheet window | the handler fires in 2 ms; first responder is the field editor |

So `onExitCommand` reaches the content only while a responder INSIDE it
has focus, and a nil handler beside a field consumes the key with nothing
done. The arm carries no `onExitCommand`: an unarmed sheet's Esc goes to
the platform's own dismissal and the `.sheet` binding's setter reports it,
and an armed sheet's Esc is read by a local `NSEvent` monitor keyed on the
topmost sheet window (or its parent chain), which sees the harness's
`NSApp.sendEvent` and a person's press alike. The sheet scene's second run
was green on every step (docs/traps.md, the sheet's Esc).

The whole mac lane then found the second red the hand run could not: a
present of the same surface id issued into the previous sheet's dismissal
left both contents alive (docs/traps.md, the sheet presented into its own
dismissal); the host presents one item per host now, the next raised from
the last one's `onDismiss`.

## U1, WinUI: a modal over a modal

`tools/win/sheetprobe/` (the undo probe's route: a module of the backend
under a temporary hook, `hook.patch`, and a throwaway guest, built with
`cargo xwin` and run on the lane's VM through a scheduled task), every step
on kaya's own UI thread over kaya's own root, 800 ms apart:

| Step | Reading |
| --- | --- |
| ContentDialog A shown | `ShowAsync ACCEPTED` |
| ContentDialog B shown with A up | `ShowAsync REFUSED — Only a single ContentDialog can be open at any time. (HRESULT(0x80000019))` |
| both hidden; a Popup with a full-root smoke Grid child, `ShouldConstrainToRootBounds`, light dismiss off | `popup open=true over a 944x504 root` |
| ContentDialog C shown with the popup up | `ShowAsync ACCEPTED` |
| a second Popup over the first, with C up | `popup open=true`; both popups read open |
| C hidden, both popups closed | clean |

The process then left with `0xC0000409` (a fail-fast) on the probe's own
`request_exit(0)`, after every reading and PROBEDONE: the throwaway keeps
its dialogs and popups in thread-locals that outlive the XAML app's
teardown, which is the probe's shape and not the arm's (the core forgets a
sheet's tree on dismiss and before exit). Recorded so the arm's teardown is
written with it in mind and the review's exit codes are read against it.

So WinUI's sheet is a modal Popup: ContentDialog cannot host a surface that
must take an alert or a child sheet, and the Popup takes both. What the arm
still owes and the scene will show: the backdrop blocking the root beneath
(the smoke Grid takes the pointer), Esc reaching the popup's own key
handler, and focus moving into the popup when it opens.
