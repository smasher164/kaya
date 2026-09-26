# An unread count on the app's icon — the design pass

Status: DESIGN, one ruling wanted (R1, Android). The chat app's C2
(docs/chat-plan.md). The platform facts below were researched 2026-09-25
with sources; the four read-backs in §4 are still to be measured before
any arm is built.

## §1 — The semantics

`set_badge(count)` on the APP, not a window: a whole number, 0 clears.
Last write wins. It is the W3C Badging API's shape
(`navigator.setAppBadge(n)`), and it asks the platform to show that count
on the app's icon wherever the platform shows app icons: the Dock, the
taskbar, the home screen, a Linux dock.

A new capability bit, `badge`, says whether this process can show one, the
`notifications` bit's shape: granted before the app thread exists, read
back by the app, and on the platform where it is false the call is refused
in one sentence rather than ignored.

## §2 — What each platform can do

| platform | shows | route | condition |
|---|---|---|---|
| macOS | the number | `NSApp.dockTile.badgeLabel` | the app has a Dock tile (a `.regular` app, which a declared identity already is); `.badge` added to the notification authorization request, since an app registered with the notification centre without it loses its Dock badge (reported, measured in §4) |
| iOS | the number | `UNUserNotificationCenter.setBadgeCount` (iOS 16) | `.badge` authorization; provisional authorization does not badge, so the harness asks for it |
| Windows, unpackaged | the number, drawn by kaya | `ITaskbarList3::SetOverlayIcon` with a 16x16 icon kaya renders, its description the count as text | the Windows App SDK's `BadgeNotificationManager` refuses an unpackaged process in its own source ("Not applicable for unpackaged applications"); the overlay is per taskbar group and is re-applied on `TaskbarButtonCreated`, since Explorer drops it on a restart |
| Windows, packaged | the number, 1 to 99 then 99+ | `BadgeNotificationManager.SetBadgeAsCount` (Windows App SDK 1.7) | the user's "Show badges on taskbar apps" setting |
| Linux | the number on KDE Plasma, Ubuntu Dock and Dash-to-Dock; nothing on stock GNOME, sway or an X11 window manager | the `com.canonical.Unity.LauncherEntry` `Update` signal on the session bus, `count` and `count-visible`, keyed by the app's desktop id | no GTK, libadwaita, freedesktop or portal API exists (a portal was proposed in 2024 and never built) |
| Android | a DOT, and only while the app has an active notification | none | no public API sets a launcher count; Pixel's launcher shows a dot for an app with a notification and the count only in the long-press menu, taken from `setNumber` on that notification |

## §3 — R1, the ruling wanted: Android

Android has no call that puts a number on the icon. The launcher draws a
dot when the app has a notification showing, by itself, and the chat app's
notifications (C3) already give it that dot. The two honest answers:

- **(a) RECOMMENDED: refuse.** `badge` is false on Android, and
  `set_badge` there fails in one sentence naming the platform. An app that
  checks the bit skips the call; the dot still appears from its
  notifications, which is what every Android chat app shows.
- **(b) ride the newest notification.** On Android `set_badge(n)` stamps
  `n` on the app's newest showing notification (`setNumber`), shown in the
  long-press menu, and does nothing when none is showing. This makes the
  call mean something different on one platform, which invariant 1 allows
  only by your ruling.

## §4 — How a leg sees it (to measure before building)

The observation is the platform's own record, never kaya's copy of the
number:

- macOS: `lsappinfo info -only StatusLabel` for the leg's process, the
  label LaunchServices publishes for the Dock.
- iOS: whether SpringBoard's accessibility tree carries the badge on the
  app's icon, read by the xcui driver.
- Windows: whether the taskbar button's UI Automation name carries the
  overlay's description; if not, a picture of the button.
- Linux: the `Update` signal itself, read off the leg's own session bus
  (notify-leg.sh already builds one).

## §5 — The surface

A transaction record, since it is a write the app makes alongside its UI
(the unread labels and the badge move in one transaction):
`tx.set_badge(3)` in Rust, `tx.SetBadge(3)` in Go, `kaya.set_badge(3)`
inside a Python handler, and so on per binding.
