# Replying from a notification — the design pass

Status: DESIGN, one ruling wanted (R1, Linux). The chat app's C4
(docs/chat-plan.md). Researched 2026-09-25 with sources; two macOS points in
§4 are unmeasured.

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

## §3 — R1, the ruling wanted: Linux

The portal's spec has the field, and no shipping desktop draws it: GNOME's
portal backend forwards to gnome-shell, which has no text input, and KDE
Plasma's portal backend lists it as a TODO. Plasma's working inline reply is
on the older freedesktop protocol and needs a process that stays running,
which the 2026-09-07 ruling on notifications excludes.

- **(a) RECOMMENDED: ask the portal.** kaya reads the portal's
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
  programmatic tap). Unmeasured: whether a provisional authorization (the
  harness's) shows action buttons, and what a reply does to a closed
  accessory app on the mac. Both are probed before building.
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
