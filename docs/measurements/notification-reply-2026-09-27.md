# Replying from a notification: the feasibility probes (2026-09-27)

For docs/notification-reply-plan.md, before building C4. Both probes were
throwaway code, removed afterwards; the logs are summarized here.

## Android: the guest runs a reply with no Activity

A probe receiver in the Go shell (android/gohost) did what a reply's
BroadcastReceiver will: `KayaRing.attach` and `KayaGo.attach` with the
receiver's Context in place of an Activity, the Compose interpreter's command
pump started without `mount` or `setContent`, then a notification result
delivered through `KayaPresent.emitNotificationResult`. The chat app was the
guest (KAYA_SELFTEST=chat), on the lane's API 35 emulator.

- Cold (the app force-stopped, `am broadcast` to the receiver): the process
  started, the ring attached at 55ms and the guest at 58ms, the guest's first
  build (3,856 bytes) was applied to the scene model with no Activity, and the
  delivered event ran the chat app's handler, whose 4,144-byte batch was
  applied 1ms later. No Activity was created and nothing crashed; the process
  stayed alive after `goAsync().finish()` until the system reclaimed it.
- Warm (the app running behind the home screen): the event reached the same
  process, the handler ran, and the Activity stayed in the background.
- Cold, then opened: after a cold reply, `am start` on the Activity attached
  the composition to the process the receiver had started, and the screen
  showed the conversation the handler had opened.

What the probe had to change, which is the build's list: the two attach
entries take a Context (the native side only asks it for the application
context and the permission check), the pump starts without `mount`, and
`kayaPostNotification`, `kayaCancelNotification` and the activation's
withdrawal read the application context instead of the mounted Activity
(with none mounted they refused the post).

## macOS: a reply to a closed app

tools/mac/notifyprobe, given a category with a `UNTextInputNotificationAction`
and no `.foreground` option, posted under full authorization and exited. The
maintainer replied from the banner twice.

- macOS relaunched the terminated bundle for each reply, and
  `didReceive` carried `UNTextInputNotificationResponse.userText` ("hi") and
  the action's identifier, 10-20ms after launch.
- The relaunched app was not activated (`NSApp.isActive` false) and had no
  window; the probe is plain AppKit, so what a SwiftUI WindowGroup does on such
  a launch is still to be seen when kaya's own lowering is built. Seen
  2026-09-27 with kaya's own: no window either, and the pump has to start
  without one (docs/traps.md, the cold notification reply entry).
- The banner showed the Reply field under full authorization. Whether a
  provisional authorization (the harness's) shows it was not probed: the leg
  drives the reply in process (plan §4), so it does not depend on it.
