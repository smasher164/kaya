# The toast: the design pass (2026-10-08)

Status: RULED (T1-T16); the DEPTH is BUILT (2026-10-08): the spec, the core,
Rust, and the SwiftUI arm on macOS and iOS; the breadth is docs/deferred.md's
toast BUILD entry. The maintainer picked the toast next after the segmented
control (the 2026-10-06 shortlist). Its roadmap card (docs/roadmap/features.toml,
`toast`) calls it "the undo surface": kaya's core-owned undo has no place to
offer "Deleted. Undo?" today. The segmented control's and the reveal toggle's
plans (docs/segmented-plan.md, docs/reveal-plan.md) are the shape of this one;
the alert (DESIGN.md, Modal presentations) and the local notification
(docs/tasks-s3-plan.md) are the two surfaces it sits between.
RULED 2026-10-08 (the maintainer: "sounds good"): T1-T16 as recommended, T8 AMENDED to the platform's own placement: on iOS a capsule dropping from the top, as the system's own transient messages do; on macOS a capsule at the top of the window under its toolbar; on Android, GTK and WinUI the bottom of the window, as their own toasts sit.

A TOAST, in this file, is a short message the app shows inside its own window,
over the content, for a few seconds, optionally with one button ("Undo"), which
goes away on its own. Material calls it a snackbar, libadwaita a toast. It is
not a NOTIFICATION, which the system shows outside the app (kaya's
`show_notification`; Windows calls those toasts, see T2), and not an ALERT,
which is modal and must be answered.

## §0 — What the platforms offer

Rows marked MEASURED were measured for this pass (§7). The rest comes from the
vendors' documentation, cited at the end of the section; "to measure" is the
depth's or the breadth's.

| | the control | placement | duration | one action | dismissal | several at once | assistive technology | focus | across a window change |
|---|---|---|---|---|---|---|---|---|---|
| Android, Compose | Material 3 `Snackbar` shown by `SnackbarHost` from a `SnackbarHostState`, usually the `snackbarHost` slot of a `Scaffold` | the bottom of the Scaffold, above its bottom bar and floating action button | MEASURED (material3 1.3.1): `Short` 4000 ms, `Long` 10000 ms, `Indefinite`; the default is `Short` without an action and `Indefinite` with one; the host passes the duration through `AccessibilityManager.calculateRecommendedTimeoutMillis`, which lengthens it under the user's "time to take action" setting | `actionLabel`; `showSnackbar` returns `ActionPerformed` or `Dismissed` (a timeout and a user dismissal are both `Dismissed`) | `withDismissAction` draws an X; MEASURED: the host publishes a `dismiss` accessibility action; no swipe in the composable (an app wraps it in `SwipeToDismissBox`) | MEASURED: `showSnackbar` holds a Mutex, so a second call WAITS until the first is gone (a FIFO queue) | MEASURED: the shown snackbar is a `LiveRegionMode.Polite` live region, so TalkBack reads it when it appears without moving focus | none taken; the action is a focusable button | lives as long as the host's composition; a host at the Scaffold survives navigation inside it |
| Android, the old `Toast` | `Toast.makeText`, a SYSTEM window | bottom of the screen, outside the app's window | `LENGTH_SHORT` and `LENGTH_LONG` (about 2 s and 3.5 s, constants of the system service) | none | none; it times out | the system queues them across apps | announced by TalkBack | never | survives the activity and even the app going to the background |
| Android, View `Snackbar` (MDC) | `com.google.android.material.snackbar.Snackbar` | bottom, or `setAnchorView` above a FAB or bottom bar | `LENGTH_SHORT`, `LENGTH_LONG`, `LENGTH_INDEFINITE` | `setAction`; the snackbar closes when it is pressed | swipe, inside a CoordinatorLayout | "Only one snackbar will be shown at a time. Showing a new snackbar will dismiss any previous ones first." | "readable by most screen readers" | none | bound to its parent view |
| iOS | NONE. The HIG has no toast; its Feedback page says to put status "near the items it describes" and to "use alerts to deliver critical, and ideally actionable, information"; undo is "shaking their iPhone" or a toolbar button, and the shake alert names what will be undone | — | — | — | — | — | `UIAccessibility.post(notification: .announcement, argument:)` (iOS 4) speaks a string; the SwiftUI `AccessibilityNotification.Announcement` is iOS 17, above kaya's iOS 16 floor | — | — |
| macOS | NONE. Same HIG pages; the Mac's undo is the Edit menu and Command-Z, whose item the HIG asks to name ("Undo Typing"). NSUserNotification (deprecated) and UNUserNotificationCenter are system notifications, and the HIG says an app's notifications "don't appear when your app is in the front" | — | — | — | — | — | `NSAccessibility.post(element:notification: .announcementRequested, userInfo:)` (macOS 10.7) with `.announcement` and a `.priority`; "If VoiceOver is enabled, it's presented via speech and/or braille. Otherwise, it does nothing." | — | — |
| GTK 4 / libadwaita | `AdwToast` in an `AdwToastOverlay` that wraps the content | overlaid at the bottom centre of the overlay's child | `timeout` in seconds, default 5; 0 stays until dismissed; "Toasts cannot disappear while being hovered, pressed (on touchscreen), or have keyboard focus inside them" | one button: `button-label` with a GAction, and `button-clicked` (1.2) | a close button on every toast; `dismissed` is emitted whenever it goes, without a reason; `adw_toast_dismiss` and `adw_toast_overlay_dismiss_all` (1.7) | `priority` NORMAL: "queued if another toast is already displayed"; HIGH: "displayed immediately, pushing the previous toast into the queue"; re-adding a shown toast restarts its timeout | the overlay is role GROUP; the GTK project reported in 2025 that libadwaita toasts are now announced to assistive technology (to measure on 1.9.2); `gtk_accessible_announce` (GTK 4.14) is the fallback | not taken; its button is reachable in the Tab order (to measure) | bound to the overlay's widget, so a toast survives anything inside the overlay's child |
| WinUI 3 | NO toast control in the Windows App SDK. MEASURED in the pinned WinUI 2.2.1 metadata: `InfoBar` and `TeachingTip` (with their automation peers and close reasons) and `AutomationPeer.RaiseNotificationEvent`; nothing named Snackbar or Toast. The Community Toolkit 8 replaced its `InAppNotification` with `StackedNotificationsBehavior`, a queue with a duration attached to an InfoBar; it is a managed .NET assembly, out of reach of kaya's native backend | InfoBar: INLINE, "will take up space in your layout ... It will not cover up other content"; TeachingTip: a popup, targeted at an element or placed relative to the window | InfoBar: none ("By default the notification will remain in the content area until closed"); TeachingTip: none | InfoBar `ActionButton` (a Button or HyperlinkButton); TeachingTip `ActionButtonContent` | InfoBar's close X (`IsClosable`), `Closing`/`Closed` with `InfoBarCloseReason` CloseButton or Programmatic; TeachingTip light dismiss | none; the Toolkit's behaviour adds a queue | InfoBar raises a UIA notification event when it OPENS ("any changes made ... will not raise a notification event ... close and re-open the control to trigger the event"); `RaiseNotificationEvent` on any peer otherwise | InfoBar: an inline control, no focus taken; TeachingTip: to measure | inline: lives where it is placed |

The Windows guidance says what each of its two candidates is for: InfoBar for
"app-wide status messages", not "to confirm or respond directly to a user
action"; TeachingTip for "a transient teaching moment". Neither is a snackbar,
and the Toolkit's own answer is an InfoBar with a timer, which is T10.

Five facts decide the design:

1. **Three platforms have the control (Compose, libadwaita, and Android's
   View toolkit); two have nothing (iOS, macOS); one has the parts (WinUI's
   InfoBar).** Everywhere it exists it is the same thing: a message, at most
   ONE action, a timeout, a close, one shown at a time.
2. **It is a request to the WINDOW, not a widget in a tree.** No platform's
   app declares a snackbar where it lays out its buttons: Compose calls
   `showSnackbar` on a host the Scaffold owns, GTK calls `add_toast` on an
   overlay around the content, and the answer comes back as a result. That is
   kaya's alert grammar (DESIGN.md, Presentation contexts), not a kind.
3. **No platform tells "it timed out" from "the user closed it" in every
   case.** Compose answers `Dismissed` for both, GTK's `dismissed` carries no
   reason. What every platform can say is "the action was pressed" and "it is
   gone".
4. **Queueing disagrees.** Compose and libadwaita queue first-in first-out;
   Android's View snackbar replaces the old one with the new.
5. **Every platform that has the control announces it to the screen reader
   without moving focus** (Compose's polite live region, InfoBar's
   notification event, libadwaita's announcement), and both Apple platforms
   offer an announcement API at kaya's floors.

Sources: Android Developers, Snackbar
(developer.android.com/develop/ui/compose/components/snackbar) and Toasts
overview (developer.android.com/guide/topics/ui/notifiers/toasts); Material
Components for Android, Snackbar.md
(github.com/material-components/material-components-android/blob/master/docs/components/Snackbar.md);
libadwaita, Adw.Toast, Adw.Toast:timeout, Adw.ToastPriority, Adw.ToastOverlay
(gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.Toast.html,
property.Toast.timeout.html, enum.ToastPriority.html, class.ToastOverlay.html);
GTK, Gtk.Accessible.announce (docs.gtk.org/gtk4/method.Accessible.announce.html)
and the GTK blog's May 2025 accessibility update (blog.gtk.org/2025/05/);
Microsoft Learn, InfoBar (learn.microsoft.com/windows/apps/design/controls/infobar)
and Teaching tip (learn.microsoft.com/windows/apps/design/controls/dialogs-and-flyouts/teaching-tip);
Community Toolkit, StackedNotificationsBehavior
(learn.microsoft.com/dotnet/communitytoolkit/windows/behaviors/stackednotificationsbehavior)
and the v7 to v8 migration guide (github.com/CommunityToolkit/Windows/wiki/Migration-Guide-from-v7-to-v8);
Apple HIG, Feedback, Undo and redo, Notifications
(developer.apple.com/design/human-interface-guidelines/feedback, undo-and-redo,
notifications); AppKit, NSAccessibility.Notification.announcementRequested;
UIKit, UIAccessibility.Notification.announcement; Accessibility,
AccessibilityNotification.Announcement (developer.apple.com/documentation/...).

## §1 — What kaya has

- **The alert** (`show_alert`, record 21; DESIGN.md, Modal presentations): a
  window-scoped request with a binding-allocated id, title, message, up to
  two actions and a required cancel label; ONE answer, `alert_result`, bound
  at the show call and retired with it. One alert per process. The async
  tier awaits it in Rust, Swift, C#, Java and JS; Python, Go, OCaml and
  Haskell take a callback (DESIGN.md, Async dialogs use explicit transaction
  scopes).
- **The notification** (`show_notification`, record 52;
  docs/tasks-s3-plan.md): the alert grammar without a window, shown by the
  SYSTEM outside the app, with a guest-chosen id, `cancel_notification` that
  retires an id with no answer, and `notification_result` (`activated`,
  `refused`, `replied`). Dismissal is not an outcome there either.
- **The core's undo ledger** (docs/undo-plan.md): a transaction named with
  `tx.undoable(label)` is one step (`undo_group`, head of batch); Edit > Undo
  is a menu ROLE whose activation the backend routes through
  `kaya_undo_route` and `kaya_undo`, and the app learns of the undo from one
  occurrence, `undone`, carrying the label and the restored state. THERE IS NO
  APP-CALLABLE UNDO: `kaya_undo` is reached only from a backend's role item,
  so an app that drew its own "Undo" button has nothing to call (MEASURED,
  capi.rs). The tasks app's delete is already an undo group
  (guests/rust/tasks.rs, `undo-delete`), and it already resyncs on `undone`.
- **The echo rule** (DESIGN.md, Only the user's act emits): an app's write is
  configuration and never echoes; the user's act emits.
- **Sections, navigation, sheets**: the window's content can change under a
  toast (a push, a section switch, a sheet over the window).

## §2 — The rulings (RECOMMENDED 2026-10-08)

### T1 — A window-level request, `show_toast`, not a widget kind (RULED 2026-10-08)

`show_toast` is a request on the transaction, aimed at a window (0 = the
primary), with the alert's grammar: a binding-allocated id, one answer
(T5), the handler bound at the show call and retired with its answer. It is
not a kind: no platform lays a snackbar out among the content (§0 fact 2), a
kind would need a place in the tree and a visibility prop that the app
toggles and the timer toggles back, and that is two owners for one bool. It
needs no capability bit, as the alert needs none: every backend can show
one (T9, T10).

The alternative, a `toast` kind the app mounts and shows with a prop, is
refused for the two-owners reason and because it would put a timed,
self-closing surface in the template zone's census for no use (T14).

### T2 — The word is `toast` (RULED 2026-10-08)

The API says `toast`: libadwaita's word, Android's original word, the roadmap
card's slug, and short. The cost is a collision inside one backend: Windows
calls its SYSTEM notifications toasts, and crates/kaya/src/winui and
tools/guest already say "toast" for those (the toast-moment section, the
foreground wait). kaya's own vocabulary has no collision, because it spells
those `notification` everywhere. RECOMMEND the WinUI arm names its in-app
pieces after the control that draws them (`info_bar_*`), never bare
`toast_*`, so a grep for the system toast's traps does not land in the new
arm. `snackbar` is the other choice: unambiguous, but Material's word alone.

### T3 — Text and at most one action (RULED 2026-10-08)

A toast carries one TEXT (a non-empty Str, plain, no title; the platform
wraps or truncates it at its own line limit, Material's two lines) and zero
or one ACTION with a non-empty label the app supplies (no hidden English,
the alert's rule). One action because every platform has exactly one slot
(Snackbar's `actionLabel`, AdwToast's button, InfoBar's `ActionButton`). The
root refuses an empty text, an empty action label, and a second action.

### T4 — An action may be the window's UNDO, bound to the step it offers (RULED 2026-10-08)

This is the ruling the feature exists for, and it needs some explaining.

Today an app cannot undo from code: the core's ledger is reached only by
Edit > Undo, a menu item whose ROLE the backend routes to the core. A toast's
"Undo" button that only told the app "the button was pressed" would leave
the app with nothing to call. Two ways out:

- (a) give apps a programmatic `undo()` call; or
- (b) let the toast's action carry the undo ROLE, the way a menu item does,
  so pressing it IS the user's undo and the core performs it.

RECOMMEND (b). A press of "Undo" is the user's act, exactly like Edit > Undo
or Command-Z, so it goes the same way and the app hears the same `undone`
occurrence it already handles. (a) would put a second, app-driven route into
a ledger whose rules (docs/undo-plan.md D3, D6) assume undo comes from the
user.

Binding the toast to its step is what keeps it honest. An undo toast must be
shown IN the undoable transaction it offers to undo (the core refuses it
anywhere else, naming the rule), and the core remembers that ledger entry.
The toast's Undo then means "undo THAT step", and it stays offered only while
that step is the newest one in the window's ledger:

- the user presses Undo: the core undoes that entry through the same body as
  `kaya_undo`, `undone` reaches the app, and the toast answers `action`;
- the user undoes that step another way (Command-Z, Edit > Undo): the toast
  closes and answers `closed`, since there is nothing left for it to offer;
- a NEWER undoable step lands in that window (the user deletes a second
  task): the old toast closes and answers `closed` (and T7's replacement
  usually shows the new step's toast anyway).

So the button never undoes something other than what its text names. On the
wire the action is an enum, `none`, `app` or `undo` (§4); an `app` action
answers `action` to the app and does nothing else.

### T5 — One answer: `action` or `closed`; `dismiss_toast` retires with no answer (RULED 2026-10-08)

The toast's one answer is `toast_result { toast, outcome }`, outcome
`action` (the user pressed the action) or `closed` (it went away any other
way: timed out, the user closed it, it was replaced, its window closed, an
undo toast lost its step). Two outcomes because those are the two facts every
platform can report (§0 fact 3), and the one an app needs: did the user take
the offer. "Timed out" against "closed by the user" is unreachable on Compose
and GTK, and an app that behaved differently on the two would behave
differently per platform.

`dismiss_toast(id)` withdraws a shown or queued toast. Like
`cancel_notification`, it retires the id with NO answer: the app caused it,
and the app's own write never echoes. An unknown or retired id is ignored.

The result handler is spelled as each binding spells the alert's (T15).

### T6 — Two durations, `short` and `long`, in the platform's own seconds (RULED 2026-10-08)

The app picks `short` (the default) or `long`, never a number of seconds.
Each backend maps them to its platform's own values and keeps its platform's
accessibility lengthening:

| | short | long | the platform's own lengthening |
|---|---|---|---|
| Compose | `SnackbarDuration.Short` (4 s) | `Long` (10 s) | `calculateRecommendedTimeoutMillis` (built into the host) |
| GTK | 5 s (AdwToast's default) | 10 s | paused while hovered, pressed or focused (built in) |
| WinUI | 5 s | 10 s | `UISettings.MessageDuration`, the "dismiss notifications after" setting, as a floor (to measure in the bindings) |
| SwiftUI, both | 4 s | 10 s | paused while the pointer is over it (macOS) or VoiceOver's cursor is inside it (both) |

Named durations because the platforms disagree on the numbers and each
user's setting moves them anyway, so a number in the app would be a promise
no backend keeps. No `indefinite`: a message that stays until closed is a
status banner (InfoBar's own job), which is a different feature with its
own entry (§2 end). Compose's default for a snackbar with an action is
Indefinite (MEASURED); kaya passes the duration explicitly so that default
never applies.

### T7 — One toast per window; a new one REPLACES the shown one (RULED 2026-10-08)

At most one toast is on screen in a window. A second `show_toast` to the same
window closes the shown toast (it answers `closed`) and shows the new one at
once. Toasts in different windows are independent.

The other choice is a first-in first-out queue (Compose's and libadwaita's
default). RECOMMEND replacement because:

- the undo case needs it: delete task A, then task B; a queue would show B's
  undo only after A's had timed out, and by T4 A's has already closed, so the
  queue would hold nothing useful while the newest news waited;
- a stale message is worse than a missed one, and Android's View snackbar,
  the platform's older first-party rule, says so ("Showing a new snackbar
  will dismiss any previous ones first");
- a queue holds messages the user never sees while the app thinks they were
  shown, which is the "queues and never shows" failure §5 guards against.

Each backend spells it with its own calls: Compose dismisses the current
`SnackbarData` before `showSnackbar`, GTK dismisses the shown AdwToast and
adds the new one (HIGH priority, so nothing waits behind it), WinUI and the
kaya-drawn arms swap the content.

### T8 — Bottom of the window, above its content and its bottom bars, below its modals (RULED 2026-10-08)

A toast belongs to a WINDOW, not to a screen in it: it stays through a
navigation push or pop and a section switch, and it never moves the
content's layout (it overlays, which is why WinUI's inline InfoBar is hosted
in an overlay, T10). It sits at the bottom centre, above a bottom section bar
on the phones (Material's placement, Scaffold's slot) and above the home
indicator's safe area on iOS. Closing its window closes it (`closed`).

A modal over the window (an alert, a sheet, a file dialog) covers it on
every platform that layers modals over content (Compose's sheet is its own
window, an iOS sheet a presented controller). RECOMMEND kaya does not
reorder that: an app that wants a toast about something done in a sheet
shows it after the sheet closes, and the docs say so. Whether a toast's
timer runs while covered is the platform's (GTK's and Compose's do; the
kaya-drawn arms pause it while the window is not key, to measure).

### T9 — On iOS and macOS kaya draws the toast from Apple's own materials (RULED 2026-10-08)

Apple ships no toast, and the maintainer accepts kaya drawing a control where
the platform lacks one if it looks native. The alternatives are worse:

- mapping it to a one-action ALERT makes a passing message modal, which the
  HIG reserves for "critical, and ideally actionable" information, and breaks
  T5's timeout;
- mapping it to a NOTIFICATION shows nothing while the app is in front (the
  HIG, Notifications), needs permission, and lands in Notification Center;
- refusing it leaves the undo surface (T4) missing on two of five lanes.

The kaya-drawn toast, one SwiftUI view in the interpreter for both platforms:

- **iOS**: a capsule above the bottom safe area (and above a tab bar), on
  `.regularMaterial` with the system's shadow, the text in the subheadline
  style, the action as a borderless button in the app's tint; it slides up
  and fades out, a cross-fade under Reduce Motion; a downward swipe closes
  it. This is the HUD shape Apple's own apps use for "Added to Library" and
  Mail's "Undo Send" bar, drawn from public materials (to compare on the
  review page against those).
- **macOS**: a rounded rectangle at the bottom centre of the window's
  content, on `.regularMaterial`, the body text, a small borderless button
  for the action and a close button, like a notification banner's; it
  pauses while the pointer is over it, as GTK's does.
- **Both**: the text scales with Dynamic Type (the interpreter's
  `kayaPlatformFont`), mirrors in right-to-left locales, and is one
  accessibility container holding a static text and a button (T12).

The review page puts these beside a Material snackbar and an AdwToast; if
the maintainer finds either Apple arm foreign, the fallback is the
inline-status route the HIG describes, ledgered as a ruling.

### T10 — On WinUI an InfoBar in an overlay, with kaya's timer (RULED 2026-10-08)

The arm hosts one `InfoBar` per window in an overlay layer at the bottom of
the window's root (a Grid cell spanning the content, aligned bottom-centre,
with a maximum width), never inline, so it covers rather than shifts the
content (T8): `Severity` Informational, `IsIconVisible` false, `Message` the
text, `ActionButton` a Button with the action label, `IsClosable` true, and
kaya's own `DispatcherQueueTimer` for T6's duration, paused while the pointer
or keyboard focus is inside it. InfoBar raises its UIA notification event on
opening, which is the announcement (T12); a replacement (T7) closes and
re-opens it so the event fires again, as Microsoft's guidance says.

This is the Community Toolkit's own answer (InfoBar plus a queue and a
duration) built in the arm, since the Toolkit is managed code. TeachingTip
is refused: Microsoft frames it as teaching, it draws a title and a tail, and
its light dismiss would close it on the user's next click anywhere. InfoBar,
its peer and its event-args types join tools/winui-bindgen's filter and the
bindings regenerate (check-winui-bindings holds them).

### T11 — The user can always close it, by the platform's own gesture (RULED 2026-10-08)

GTK's close button and InfoBar's X are the platforms' own; Compose gets a
swipe (`SwipeToDismissBox`) plus the host's built-in `dismiss` accessibility
action; iOS the downward swipe plus VoiceOver's escape gesture
(`accessibilityPerformEscape`); macOS the close button. All answer `closed`.
Compose's `withDismissAction` X is not drawn, since Material keeps it for
long-lived snackbars and kaya has none (T6).

### T12 — Announced on every platform, never focused, the action reachable the platform's way (RULED 2026-10-08)

When a toast appears, the screen reader hears its text, then the action's
label, and focus does not move. Per backend:

- Compose: the host's polite live region (MEASURED), nothing to add;
- GTK: libadwaita's own announcement if 1.9.2 makes one (to measure);
  otherwise the arm calls `gtk_accessible_announce` on the overlay (GTK 4.14,
  within kaya's `v4_14`);
- WinUI: InfoBar's notification event on open (T10); if its text is not the
  text and the action, the arm calls `RaiseNotificationEvent` itself (to
  measure);
- macOS: `NSAccessibility.post(element:notification: .announcementRequested,
  userInfo: [.announcement: …, .priority: .high])`;
- iOS: `UIAccessibility.post(notification: .announcement, argument: …)`.

No backend moves keyboard or accessibility focus to the toast: a passing
message must not take the user's place in a form. The ACTION is reachable
the platform's way: in GTK's and Compose's Tab order as their controls put
it, on WinUI the InfoBar's button in the Tab order; on the Apple arms the
button follows Apple's keyboard convention (the reveal plan's V10 ruling,
one control over). An undo toast's action is ALSO always on Command-Z or
Ctrl+Z, since by T4 it is the same step Edit > Undo would take.

### T13 — The harness reads the platform's toast and drives the platform's button (RULED 2026-10-08)

Three new verbs, all off the platform's own surface, never the model:

- `expect_toast "<text>|<action>"` (an observation; `"<text>|"` for no
  action) reads the shown toast's text and action label off the platform:
  the AX tree under the kaya-drawn view on the Apple arms, the AdwToast's
  widgets under the overlay on GTK, the InfoBar's peer and its ActionButton's
  name through UIA on WinUI, the snackbar's merged semantics node on Compose.
  `expect_no_toast` is its opposite; both retry within the expect deadline.
- `toast_action` and `toast_close` (action verbs, both waits) press the
  action or the close through the platform's own activation: AXPress, the
  button's `activate`, the peer's Invoke, the semantics click or the
  `dismiss` action.
- `expect_toast_announced "<text>|<action>"` reads the announcement where
  the platform publishes it to a listener the harness can hold: the
  in-process AX observer on macOS (`AXAnnouncementRequested`), the AT-SPI
  `announcement` event on GTK (to measure on the bus), the UIA notification
  event on WinUI, the live-region change on Compose (to measure). iOS posts
  to VoiceOver and to nothing a process can observe without it, so the iOS
  arm's post is held by the route gate instead, a carve-out stated once here.

THE GUARD FOR A BACKEND THAT QUEUES AND NEVER SHOWS. The failure is real on
two platforms out of the box: Compose's `showSnackbar` waits on a Mutex
behind any snackbar nobody dismissed, and libadwaita queues NORMAL toasts, so
an arm that forgot T7's replacement passes "the call was made" while the
user sees the old message for ten seconds or forever. Three walls:

1. The scene shows two toasts in a row and reads the SECOND one off the
   platform within the expect deadline, which a queueing arm misses, and
   reads that the first answered `closed`.
2. A `toast_routes.py` beside tools/lib/segmented_routes.py, a check-verbs
   clause: each arm's show is inside its one door and preceded by its
   replace (the dismiss of the shown one), the GTK priority is HIGH, the
   reads name the platform's API and never the model, the timer starts
   only in the platform's shown callback, every exit path emits exactly one
   `toast_result`; a backend whose `depth_stub("toast")` goes owes a row.
   Watched negatives per clause, counts printed.
3. A watched leg negative per backend: the replace cut (1 substitution),
   the leg seen red, restored from a saved copy with its sha256 compared.

### T14 — No template zone (RULED 2026-10-08)

A toast is not a widget, so it has no place in a row template. A stamped
row's handler shows one through the transaction like any other request
(DESIGN.md, A stamped handler receives its row), which is how the tasks
app's row delete will do it.

### T15 — All nine bindings and the C floor, spelled as each spells its alert (RULED 2026-10-08)

Per invariant 2, every language does, and none has a reason to defer:

| binding | the show | the answer |
|---|---|---|
| Rust | `tx.show_toast("text").action("Undo").undo().long()` | awaited in the scoped task, or `msgs.on_toast(id, …)` |
| Swift, C#, Java, JS | the alert's builder or keyword shape | awaited (the async tier), or a callback |
| Python | `show_toast(text, action=…, undo=…, duration=…, on_result=…)` | callback |
| Go | the alert's builder, `.OnResult(…)` | callback (the ruled carve-out) |
| OCaml, Haskell | the alert's shape | `'a ask` with `let*`, and `Ask` (the ruled spelling) |
| C floor | `kaya_tx_show_toast` with every field explicit | the ring's `toast_result` |

A toast does NOT take the async dialogs' live slot: that slot exists because
ContentDialog throws on a second dialog, while a second toast replaces the
first (T7). An awaited toast simply resolves `closed` when replaced.

### T16 — Its first home: the task manager's delete (RULED 2026-10-08)

Deleting a task shows `Deleted "<title>"` with an Undo action bound to the
delete's undo step (T4): the archetype the roadmap card names, the shape
Gmail and Files use, and a step the tasks app already declares
(`undo-delete`) and already resyncs from (`on_undone`). The media player's
"Added to playlist" is refused for the first home: the tree has no playlist
(MEASURED), so the demo would be built for the toast. The tasks scene gains
the block; the media player can take a plain `app` toast once it has one.

### Deferred, for the ledger at the depth

- A persistent status banner (InfoBar's own job, "connection lost") with
  its admission trigger: an app that must show a state until it resolves.
- A toast anchored above a specific control (Android's `setAnchorView`), with
  its trigger: a floating action button in a kaya app.

## §3 — The lowering, per backend

| backend | the surface | show and replace | the timer | the action and the close | the reads |
|---|---|---|---|---|---|
| SwiftUI, macOS | a kaya-drawn view on `.regularMaterial` in an overlay on the window's root, bottom centre | one `@Published` slot per window; a new show swaps it with a transition | a `Task` sleeping the duration, paused on hover and while the window is not key | a borderless Button (the action) and a close button; the action's press calls `kaya_toast_action` | AX: the overlay's static text and button names; `toast_action` AXPress on the button; announcement observed through the app element |
| SwiftUI, iOS | the same view, a capsule above the bottom safe area and any tab bar | as macOS | as macOS, paused while VoiceOver's cursor is inside | the button; a downward drag and `accessibilityPerformEscape` close | the element tree; `UIAccessibility.post(.announcement)` held by the gate |
| GTK 4 | the window's content root wrapped once in an `AdwToastOverlay` (inside or outside the split view and dialog hosts, to measure) | dismiss the shown `AdwToast`, `add_toast` the new one at HIGH priority | AdwToast's `timeout` in seconds | `button-label` and `button-clicked` (no GAction needed); `dismissed` emits `closed` unless `button-clicked` came first | the toast widget's label and button under the overlay; `toast_action` activates the button; AT-SPI announcement |
| WinUI 3 | one InfoBar per window in an overlay Grid cell at the bottom of the root | close, set the text and action, re-open (so the notification event fires) | a `DispatcherQueueTimer`, paused while pointer or focus is inside | `ActionButton` Click and `Closed` (CloseButton reason) | the InfoBar's peer and its ActionButton's name through UIA; the UIA notification event |
| Compose | `SnackbarHost` in the root Scaffold's `snackbarHost` slot (kaya's Compose root already composes a Scaffold), the snackbar wrapped in `SwipeToDismissBox` | `currentSnackbarData?.dismiss()` then `showSnackbar(message, actionLabel, duration = Short or Long)` | the host's own, through `calculateRecommendedTimeoutMillis` | the returned `SnackbarResult` maps to `action` or `closed` | the merged semantics node's text and action; `toast_action` the semantics click; `toast_close` the `dismiss` action |

Every arm reports one result per toast through one function, and an undo
toast's press goes through the core (`kaya_toast_action`), which decides
whether the step is still the newest and runs the undo body (T4).

## §4 — The wire

- Transaction records: `show_toast { window, toast, duration, action,
  text: Value, action_label: Value }` and `dismiss_toast { toast }`.
  `duration` is a new enum `toast_duration` (`short`, `long`); `action` a new
  enum `toast_action` (`none`, `app`, `undo`).
- The core's refusals at apply: an empty text; an action label that is empty
  when `action` is not `none`, or present when it is; an `undo` toast in a
  transaction that is not an undo group; a window that does not exist.
- The core keeps, per window, the shown toast and, for an undo toast, its
  ledger entry; a new ledger entry in that window, an undo of that entry,
  or the window's close makes the core withdraw it and emit `closed`.
- Apply records: `present_toast` (the validated toast) and `withdraw_toast`.
- Occurrence: `toast_result { toast, outcome }`, outcome a new enum
  `toast_outcome` (`action`, `closed`). The id retires on it. A toast whose
  action is `undo` also produces the existing `undone`, before its result.
- C API: `kaya_emit_toast_result` and `kaya_toast_action`, each backend's one
  door into the core.
- The spec hash moves; the nine wire files, kaya.h and the two
  interpreters' hand-copied hashes and constants move with it (check-verbs).
- Harness (not on the wire): `expect_toast`, `expect_no_toast`,
  `expect_toast_announced` (observations), `toast_action` and `toast_close`
  (action verbs, both waits).

## §5 — The scene and the sweep

A new scene, `toast.steps`, one guest (`toast` in each language) with a list
and buttons:

1. `click button#show`: `expect_toast "Saved|"`, `expect_toast_announced
   "Saved|"` (cut on iOS), then `expect_no_toast` after it times out (the
   scene's one timeout check, on `short`).
2. Two shows in a row (`click button#a`, `click button#b`): `expect_toast
   "Second|Open"` and the app's label `first: closed` (T7, the guard's first
   wall).
3. `toast_action`: the app's label `second: action`.
4. A delete with an undo toast: `expect_toast "Deleted Milk|Undo"`,
   `toast_action`, the row back and the label `undone: delete`; then a
   delete followed by a press of Edit > Undo (or `shortcut cmd+z`), which
   closes the toast (`expect_no_toast`, `toast: closed`); then two deletes,
   where the first toast answers `closed` (T4).
5. `toast_close` on a shown toast: `closed`.
6. `dismiss_toast` from the app: `expect_no_toast` and no answer counted.

The tasks scene gains the delete-and-undo block (T16).

Gates that grow: check-verbs (toast_routes.py, T13; the constants in both
interpreters), check-sugar-surface (the show, the action, the undo binding,
the duration and the result in all nine; fake-name and rename-in-a-copy
negatives), check-stubs (`depth_stub("toast")` on GTK, WinUI and Compose until
the breadth), check-steps, scene-features (`expect_toast` keys the feature),
check-diagnostics (the core's refusal sentences each interpolate what they
measured), check-winui-bindings (InfoBar in the filter), check-gtk, check-c-ids
(the C guest), check-l10n (the tasks app's new message in every catalog).
check-sugar-surface is red by design between the depth and the breadth.

## §6 — Build order

1. The depth: spec (two records, three enums, the occurrence), the core's
   refusals and the ledger binding with unit tests (each refusal and each
   `closed` path watched), `kaya_toast_action`, the harness verbs, the
   SwiftUI arm on both Apple platforms (iOS compiled, not run), the Rust
   binding, the Rust `toast` guest, toast.steps green on the mac. GTK, WinUI
   and Compose depth stubs; the BUILD and DEFERRED ledger entries with KEY
   lines.
2. The breadth: GTK, WinUI and Compose per §3, each replacing its stub and
   taking its toast_routes row and its watched leg negative; the iOS legs;
   the eight other bindings and the C floor, a `toast` guest each.
3. The tasks app's delete (T16) and its scene block.
4. The matrix once, then the review page: every lane's capture of a toast
   with and without an action, the undo toast in the tasks app, and the two
   kaya-drawn Apple toasts beside Material's and libadwaita's (T9).

## §7 — Measured, and to be measured

- MEASURED 2026-10-08 (material3 1.3.1 from the gradle cache, bytecode):
  `SnackbarHostState` serializes `showSnackbar` through a kotlinx Mutex;
  `showSnackbar`'s default duration is `Short` with no action label and
  `Indefinite` with one; the host's durations are 4000 ms, 10000 ms and
  Long.MAX_VALUE, passed through
  `AccessibilityManager.calculateRecommendedTimeoutMillis`; the shown
  snackbar sets `LiveRegionMode.Polite` and a `dismiss` semantics action.
- MEASURED 2026-10-08 (Windows App SDK WinUI 2.2.1 under third_party):
  `InfoBar`, `InfoBarAutomationPeer`, `InfoBarClosedEventArgs`,
  `InfoBarCloseReason`, `TeachingTip` and its placement and close-reason
  enums, and `RaiseNotificationEvent` are in Microsoft.UI.Xaml.winmd; no
  Snackbar or toast control; crates/kaya/src/winui/bindings.rs names no
  InfoBar or TeachingTip yet.
- MEASURED 2026-10-08 (the crates): libadwaita 0.9.2's `Toast` has
  `set_timeout`, `set_priority`, `set_button_label`, `connect_button_clicked`
  (v1_2), `connect_dismissed` and `dismiss`, all within kaya's `v1_7`; gtk4
  0.11.4's `Accessible::announce` is under `v4_14`, which kaya enables.
- MEASURED 2026-10-08 (tools/check-symbols.py): kaya's floors are macOS 13
  and iOS 16, so the SwiftUI `AccessibilityNotification.Announcement` (macOS
  14, iOS 17) is out and the AppKit and UIKit posts are in.
- MEASURED 2026-10-08 (the tree): no app-callable undo exists (`kaya_undo`
  is reached from backends' role items alone); the tasks app's delete is an
  undo group; no media guest has a playlist.
- To measure at the depth: the kaya-drawn view's AX shape on macOS and iOS
  (a container holding a static text and a button), whether the in-process
  AX observer sees `AXAnnouncementRequested`, whether VoiceOver reads the
  text before the action, and whether a toast's timer should pause while the
  window is not key.
- MEASURED at the depth (2026-10-08, macOS 26.5): an in-process AXObserver on
  the application element hears `AXAnnouncementRequested` posted on NSApp or
  on a window, carrying `AXAnnouncementKey` and `AXPriorityKey` 90; that is
  the mac's `expect_toast_announced`. What VoiceOver itself speaks was not
  run (it takes the host's keyboard and audio); the announcement it is handed
  is the text, then ", " and the action's label. The short toast closed about
  4.1 s after it showed.
- Built at the depth, departures from the text above: T8 as amended, so the
  iOS dismissing swipe is UPWARD, and the macOS toast is the same capsule
  as iOS's (with the close button) rather than a rounded rectangle; the
  timer is NOT paused while the window is not key, so it behaves as GTK's
  and Compose's do while covered; the Apple close button is an `xmark`
  image whose accessible name is the system's.
- To measure at the breadth: whether libadwaita 1.9.2 announces a toast
  itself and what the AT-SPI event carries; where the AdwToastOverlay sits
  relative to the split view and AdwDialog hosts; whether InfoBar's open
  event carries the action's label; `UISettings.MessageDuration` in the
  generated bindings; whether a Compose live-region change is observable to
  the runner; Compose's snackbar placement above kaya's bottom section bar;
  what each platform's timer does while the app is in the background.
