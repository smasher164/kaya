# Replying from a notification — the design pass

Status: BUILT 2026-09-27 (R1 RULED 2026-09-25 as recommended (a)). The chat
app's C4 (docs/chat-plan.md). Researched 2026-09-25 with sources; PROBED
2026-09-27 (docs/measurements/notification-reply-2026-09-27.md); §6 is the
as-built record.

## §1 — The semantics

`show_notification(id).title(..).body(..).reply("Message")`: the
notification carries a text field with that placeholder. What the user
types reaches the app as a new occurrence, `notification_replied(id, text)`,
distinct from the tap's `activated`, at the same handler the tap reaches
(the one bound at the show, else the process-level one).

- A reply raises no window, on any platform. A process the platform starts
  for the reply handles it without opening its window.
- kaya withdraws the notification once the handler has run. Android
  requires the notification to be updated after a reply (the shade shows a
  spinner otherwise), and doing it everywhere keeps one meaning; an app that
  wants a "Replied" line posts again.
- Tapping the body still answers `activated`.
- A capability bit, `notification_reply`, says whether this process can
  show the field.

## §2 — The lowerings

| platform | route |
|---|---|
| macOS, iOS | a `UNTextInputNotificationAction` in a notification category without `.foreground`, read from `UNTextInputNotificationResponse.userText` in the delegate kaya already installs; one category per distinct placeholder, since the placeholder belongs to the category and categories are registered as a whole set |
| Android | a `RemoteInput` on a reply action whose `PendingIntent` is `FLAG_MUTABLE` and targets a broadcast receiver, so a reply does not open the Activity; the receiver runs the guest's handler in a process with no Activity, which kaya cannot do today and is this platform's main cost |
| Windows | the toast's `<input type="text">` and a button naming it (`hint-inputId`); the text arrives in the COM activator's `NOTIFICATION_USER_INPUT_DATA`, which kaya receives and ignores today, and in `ToastActivatedEventArgs.UserInput` in process (a winui-bindgen filter line). `activationType="background"` is ignored for desktop apps, so not raising a window is kaya's own decision |
| Linux | the notification portal's version 2 button purpose `im.reply-with-text`, the text arriving as `ActionInvoked`'s response; see R1 |

## §3 — R1 RULED 2026-09-25: Linux asks the portal (a)

The portal's spec has the field, and no shipping desktop draws it: GNOME's
portal backend forwards to gnome-shell, which has no text input, and KDE
Plasma's portal backend lists it as a TODO. Plasma's working inline reply is
on the older freedesktop protocol and needs a process that stays running,
which the 2026-09-07 ruling on notifications excludes.

- **(a) RULED: ask the portal.** kaya reads the portal's
  `SupportedOptions` and posts the reply button only when it lists
  `im.reply-with-text`. Otherwise `notification_reply` reads false and
  `.reply(...)` posts the notification without a field; a click answers
  `activated` and the app opens its own compose view, which is what the
  chat app does for a tap already. Today that means no field on any Linux
  desktop, and the field appears the day a desktop implements the purpose.
- **(b) refuse `.reply` on Linux** with one sentence. Honest too, but it
  makes every app branch where (a) lets the same call degrade to a tap.

## §4 — How a leg sees it

A new verb, `notification_reply <id> "text"`:

- macOS, iOS: the in-process shortcut into the delegate's own funnel, the
  existing carve-out for `notification_activate` (neither platform offers a
  programmatic tap). Measured 2026-09-27: a reply to a closed mac app
  relaunches it unactivated with the text in `didReceive`; what SwiftUI's
  WindowGroup does on that launch is checked when the lowering is built.
  Whether a provisional authorization shows the field was not probed: the
  leg drives the reply in process and does not depend on it.
- Android: the real shade, from the host (the Reply button, typed text,
  Send), as `notification_activate` taps the row today.
- Windows: the COM activator called from a helper process with a
  synthetic input, which is the shell's own call and covers a closed app.
- Linux: under (a) the lane asserts the capability reads false on its
  portal and a click still answers `activated`.

## §5 — The surface

`.reply(placeholder)` on every binding's notification builder, and the
outcome gains a `replied` case carrying the text wherever the binding's
notification handler receives an outcome.

## §6 — As built

- The wire: `show_notification` carries a `reply` Str (empty for none), and a
  reply arrives as its own occurrence, `notification_replied { id; Str text }`,
  which every binding hands to the handler `notification_result` reaches, as
  the `replied` outcome with the text. Its own record rather than a field on
  `notification_result`, so that record stays the code-answer shape every
  decoder already reads; the new "id and one value" shape is a derived family
  in tools/kaya-bindgen, counted in all eight decoders like the code answer.
  The `notification_reply` capability (16) is granted wherever notifications
  are, and on Linux only when the portal lists the reply purpose.
- The outcome in each binding: Rust `NotificationOutcome::Replied(String)`,
  Swift `.replied(String)`, OCaml `Replied of string`, Haskell
  `NotificationReplied Text`, Java and C# a sealed `Replied(text)` record, Go
  `NotificationResult{Outcome, Text}`, Python `NotificationReply(text)` beside
  `NotificationOutcome`, JS `{ replied: text }` beside the two strings.
- macOS and iOS: one category per distinct placeholder with a text-input
  action that has no `.foreground` option; the delegate's text response is the
  reply. The harness's `notification_reply` enters the delegate's own funnel,
  the tap's carve-out.
- Android: a RemoteInput on a Reply action whose MUTABLE PendingIntent is a
  broadcast into `dev.kaya.KayaNotificationReply`, in the library's manifest.
  With no kaya in the process, the receiver starts the guest through the app's
  `dev.kaya.guest_start` (each host's `GuestStart`, the window-free half of its
  onCreate) and the interpreter's pump with no Activity, then delivers the
  text and withdraws the notification. Posting, withdrawing and the badge read
  the application context, so a process a reply started posts too. The
  harness drives the real shade: the runner taps the row's Reply action, types
  and sends (tools/android/run-emulator.py, `reply_notification`).
- Windows: the toast's text box and a Reply button whose arguments carry
  `kaya-reply`; the text reaches the in-process `Activated` through
  `ToastActivatedEventArgs.UserInput` and a closed app's COM activator through
  its input data. The harness calls the activator's own `Activate` with that
  input. A result that arrives before the app thread exists is queued with its
  outcome (it used to be replayed as activated whatever it was).
- Linux: the portal's `SupportedOptions` is read at startup; the Reply button,
  with the portal's `im.reply-with-text` purpose, is added only when it is
  listed, and its text is read off `ActionInvoked`. No shipping portal lists
  it, so on the lane the capability reads false and the chat leg drops the
  reply block (tools/lib/lanes/linux.py). The button and the ActionInvoked
  arm have run on no desktop.
- The chat app replies from a message notification without opening the
  conversation and marks it read; replies take their own keys (r1, ...), and
  the peer numbers each conversation's messages separately, so the reply block
  changes no key the rest of the scene reads.
- macOS cold reply, measured 2026-09-27 on the Go chat app with a person
  replying (docs/traps.md, the cold notification reply entry): the relaunched
  app opens NO window, the reply reaches the handler, and its answer posts,
  once four faults a platform-started launch exposed were fixed (the bundle
  carries the interpreter, names its scene, asks for authorization only while
  undecided, and starts the pump when launching finishes).
- Not measured: what a cold Windows reply's process shows, and an iOS reply
  to an app that is not running.
