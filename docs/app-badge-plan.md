# An unread count on the app's icon — the design pass

Status: DESIGN, R1 RULED 2026-09-25. The chat app's C2
(docs/chat-plan.md). The platform facts below were researched 2026-09-25
with sources; the four read-backs in §4 are still to be measured before
any arm is built.

## §1 — The semantics

`set_badge(count)` on the APP, not a window: a whole number, 0 clears.
Last write wins. It is the W3C Badging API's shape
(`navigator.setAppBadge(n)`), and it ASKS the platform to show that count
on the app's icon wherever the platform shows app icons: the Dock, the
taskbar, the home screen, a Linux dock. It never fails: what the user sees
is the platform's decision, so no app checks the platform before keeping
its count current (R1).

A new capability bit, `badge`, says whether a NUMBER will appear on this
platform, the `notifications` bit's shape: granted before the app thread
exists and read back by the app. An app that wants to know reads it; no
app has to.

## §2 — What each platform can do

| platform | shows | route | condition |
|---|---|---|---|
| macOS | the number | `NSApp.dockTile.badgeLabel` | the app has a Dock tile (a `.regular` app, which a declared identity already is); `.badge` added to the notification authorization request, since an app registered with the notification centre without it loses its Dock badge (reported, measured in §4) |
| iOS | the number | `UNUserNotificationCenter.setBadgeCount` (iOS 16) | `.badge` authorization; provisional authorization does not badge, so the harness asks for it |
| Windows, unpackaged | the number, drawn by kaya | `ITaskbarList3::SetOverlayIcon` with a 16x16 icon kaya renders, its description the count as text | the Windows App SDK's `BadgeNotificationManager` refuses an unpackaged process in its own source ("Not applicable for unpackaged applications"); the overlay is per taskbar group and is re-applied on `TaskbarButtonCreated`, since Explorer drops it on a restart |
| Windows, packaged | the number, 1 to 99 then 99+ | `BadgeNotificationManager.SetBadgeAsCount` (Windows App SDK 1.7) | the user's "Show badges on taskbar apps" setting |
| Linux | the number on KDE Plasma, Ubuntu Dock and Dash-to-Dock; nothing on stock GNOME, sway or an X11 window manager | the `com.canonical.Unity.LauncherEntry` `Update` signal on the session bus, `count` and `count-visible`, keyed by the app's desktop id | no GTK, libadwaita, freedesktop or portal API exists (a portal was proposed in 2024 and never built) |
| Android | a DOT, and only while the app has an active notification | none | no public API sets a launcher count; Pixel's launcher shows a dot for an app with a notification and the count only in the long-press menu, taken from `setNumber` on that notification |

## §3 — R1 RULED 2026-09-25: the call never fails; Android rides the notifications

Android has no call that puts a number on the icon: the launcher decides.
Pixel's draws a dot while the app has a notification showing and the count
in the long-press menu; Samsung's can draw a number, taken from the same
notifications. The maintainer's reading: refusing the call would make every
app branch on the platform before keeping an unread count current, which is
what kaya exists to remove, and Linux already accepts the call on desktops
that draw nothing. So on Android `set_badge(n)` stamps `n` on the app's
showing kaya notifications (`setNumber`), which is what the long-press menu
and Samsung's number read, and the launcher's dot comes from the
notification itself. With no notification showing, nothing is drawn, and a
notification posted later carries the current count. `badge` reads false
on Android, since no number is guaranteed.

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
