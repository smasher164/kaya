# Task manager S3 — a reminder fires as a notification (design pass, 2026-09-07)

docs/tasks-plan.md §6, stage S3: "a reminder fires as a notification;
activating it opens the task", forcing LOCAL NOTIFICATIONS, the last
unbuilt surface of the system-integration floor (docs/deferred.md's
entry of that name: file dialogs, the clipboard and drag and drop are
built; notifications the spec does not mention today). The rulings in
§2 are proposals with a recommendation each; §6 is the build order once
they are taken. S9 (reminders that fire with the app CLOSED) is a
different problem on every platform and stays where the plan put it.

## §0 — What the platforms do

A notification is a small message the SYSTEM shows on the app's behalf,
outside the app's window: a banner, then a row in a shade or centre the
user can come back to. Every platform has one model, and they are close:

| platform | the API | needs permission? | needs an app identity? | fires at a time? | activation reaches the app as |
|---|---|---|---|---|---|
| macOS | `UNUserNotificationCenter` (UserNotifications) | yes, a system prompt the app must request | YES — the process must be a BUNDLE with a `CFBundleIdentifier`; a bare executable's centre is nil and the first call aborts | yes, `UNCalendarNotificationTrigger` / time-interval trigger | the centre's delegate `didReceive(response)` with the request's identifier |
| iOS | the same `UNUserNotificationCenter` | yes, the same prompt | the bundle it already has | yes | the same delegate; the app is foregrounded first |
| GTK 4 / GNOME | `GNotification` through `GApplication` (the portal or the session's `org.freedesktop.Notifications` daemon) | no | the `GApplication` id (kaya's is `dev.kaya.Milestone2`; a `.desktop` file for the shell to attribute it) | not in the service itself; yes through the session's scheduler — a transient systemd user timer or `at` running `gapplication action` against the app, which D-Bus activation launches if it is not running | `GApplication::action` with the notification's default action and a target — D-Bus-activated when the app is closed |
| WinUI 3 | `AppNotificationManager` (Windows App SDK ≥ 1.2, UNPACKAGED apps supported) | no (the user can turn them off; the app cannot ask) | the exe registers itself (`Register()` writes the AUMID for an unpackaged app) | yes, through the older WinRT `ScheduledToastNotification` (the App SDK manager has no scheduler) | `NotificationInvoked` on the manager, with the notification's arguments |
| Android | `NotificationManager` + a `NotificationChannel` | yes since Android 13: the `POST_NOTIFICATIONS` runtime permission, a system prompt | the package it already has; the channel | yes, through `AlarmManager` firing a receiver that posts (exact alarms need a permission since 12) | a `PendingIntent` starting the activity with extras |

Two facts shape the design more than the rest. **Every platform will
schedule for you** — Apple's triggers, Android's alarms, Windows'
scheduled toasts, and on Linux the session's own scheduler (a systemd
user timer, or `at`) firing a command that asks the app to post, since
the notification service itself carries no time (N2). **macOS needs a bundle**,
and kaya's mac guests are bare executables today (tools/lib/lanes/mac.py
runs `target/rust-guests/<stem>`); the mac probes already build minimal
`.app` wrappers by hand (tools/mac/clipprobe/build.sh writes an
Info.plist with a `CFBundleIdentifier`), so the shape exists in the tree.

LINUX COVERAGE, asked by the maintainer ("what if someone is running
sway?"), read out of GLib 2.86's own backends (gio/gfdonotificationbackend.c,
ggtknotificationbackend.c, gportalnotificationbackend.c), the portal's
documentation and the daemons' manuals, 2026-09-07. A Linux desktop
notification is one D-Bus call to the session bus name
`org.freedesktop.Notifications`; whatever owns that name — the
NOTIFICATION DAEMON — draws the popup. GNOME Shell and KDE Plasma own it
themselves; on a tiling compositor the user runs one as part of the setup
(mako or swaync on sway and other wlroots compositors, dunst on X11 and
wayland), so a sway user sees kaya's notification as a mako box in the
corner of their output, as they see Firefox's. GNotification picks its
transport by priority: the PORTAL (110) only inside a Flatpak or Snap or
with `GIO_USE_PORTALS=1`; GNOME Shell's `org.gtk.Notifications` (100)
when that name has an owner; else the plain freedesktop service (0),
which "always succeeds" its support check and prints ONE warning on the
first failed send ("unable to send notifications through
org.freedesktop.Notifications: …"). THREE REGIMES FOLLOW, and they differ
in exactly one thing — what happens to a click after the posting process
has exited:

1. GNOME Shell's own interface, and the portal: the notification
   "persist[s] after the application has exited"; a click on a
   notification "while the application is not running" D-Bus-activates
   the app with the action (GLib's words), which needs the two files a
   packaged app carries — a desktop entry with `DBusActivatable=true` and
   a D-Bus `.service` file naming the id. The poster may exit at once.
   The portal offers the same persistence and activation to a HOST app
   only if it registered its id first (`org.freedesktop.host.portal.Registry`,
   "before any portal method call", one call per process) and opted into
   the portal (`GIO_USE_PORTALS=1` for GLib's backend, or kaya calling the
   portal itself) — a route a sway user with `xdg-desktop-portal-gtk` has,
   with mako's default `default-timeout 0` keeping the popup until
   dismissed.
2. The plain freedesktop service alone (mako, dunst, swaync, Plasma
   without a portal): the click is the `ActionInvoked` signal on the bus,
   delivered to whoever is listening — GLib's backend answers it by
   calling the action IN-PROCESS and holds nothing alive, so a poster that
   has exited hears nothing, and no daemon launches apps (mako and dunst
   only MATCH on the `desktop-entry` hint; dunst's manual: actions "are
   invalidated once the notification is closed"). The only way to make
   the click land here is a process alive for the popup's whole life —
   `notify-send --wait`'s reason to exist, hours on mako's default of
   "until dismissed". RULED 2026-09-07 (maintainer: "stick with option
   1"): kaya does NOT keep one. The fired command posts and exits once the
   daemon has answered; the reminder SHOWS on every daemon, and the click
   opens the task where the desktop can carry it (regime 1) and is inert
   where it cannot — the spec's own floor ("clients should not assume the
   server will generate [ActionInvoked]"), stated once as the Linux
   carve-out. It shrinks by itself: S11's Flatpak build puts GLib on the
   portal, and the click then works on every desktop that runs one, sway
   with `xdg-desktop-portal-gtk` included.
3. No daemon, or no session bus at all (a bare X session, an SSH login,
   the lane's container): the post cannot land. kaya asks the bus for the
   name's owner before posting, reports the capability false so the
   reminder UI can say so up front, and answers the post `refused` — the
   same outcome a denied permission gives on macOS, iOS and Android, so
   the app hears one thing on five platforms. No reason string and no
   log line of kaya's (RULED 2026-09-07, "not generate a signal or log
   in other cases", the outcome kept for uniformity with the permission
   platforms): GLib already warns once on its own, and the lane asserts
   the outcome, not a log.

The spec itself says "clients should not assume the server will generate
[ActionInvoked]; some servers may not support user interaction at all",
which is regime 2's floor stated by the standard: the post lands
everywhere, the click's reach is the desktop's.

What the apps people use do: Things and Reminders post at the reminder's
time with the task's title as the notification's title and the notes'
first line as its body; tapping opens the task. Both ask for permission
the first time a reminder is SET, not at launch — Apple's guidance
("ask in context") and what Slack and Discord do too.

## §1 — What kaya has, and what the feature needs

- THE REQUEST/RESULT GRAMMAR (DESIGN.md, Presentation contexts): an
  alert is `show_alert` (one atomic record: id, title, message, action
  labels) answered by ONE `alert_result` occurrence; the file dialog is
  the same shape with a list of handles. Handlers bind at the show
  (`Messages::on_alert`), the [[handlers-scope-to-their-creator]] rule.
- ONE APP IDENTITY (guests/assets/identity.toml, docs/app-identity-plan.md):
  the name and the mark, declared once, read by the build and the running
  app. No reverse-DNS id yet — Android's packages (`dev.kaya.rusthost`),
  the iOS bundle ids and GTK's application id are each spelled at their
  own site.
- THE HARNESS DRIVES SYSTEM UI ALREADY: the iOS driver presses
  SpringBoard's "Allow Paste" (tools/ios/xcuidrive/KayaDrive.swift), the
  linux legs start their own session bus (tools/linux/a11y-leg.sh), the
  android lane ships a helper APK for the clipboard.
- The task manager stores `reminder` as a time and does nothing with it
  (docs/tasks-plan.md: "Reminders are stored, not fired").

What the feature needs: one call that posts a notification with a title,
a body, a time and an id; one occurrence when the user activates it;
one permission story; the identity each platform needs to post; a
harness that reads the platform's own notification list back and drives
an activation where a test can; and the task manager posting at the
reminder's time and opening the task on activation.

## §2 — The rulings (PROPOSED; each has a recommendation)

### N1 — Shape: a request with an id, one occurrence (RECOMMEND: the alert's grammar)

`show_notification { notification: u64 (guest-chosen), title, body, at }`
is one atomic record like `show_alert`; the answer is ONE occurrence,
`notification_result { notification, outcome }`, delivered when the
user ACTIVATES it (outcome `activated`) or when the platform REFUSES to
post it (outcome `refused` — permission denied, no identity to post
under, no notification service on the session; the app learns which, if
it needs to, from the capability bit it can read beforehand). A `cancel_notification { notification }` retires a pending or
delivered one, the way a task whose reminder is cleared should stop
being announced. Dismissal is deliberately NOT an outcome: iOS and macOS
never tell the app a banner was swiped away, so a grammar with
`dismissed` would have one semantics on three platforms and silence on
two (invariant 1). Many notifications may be live per process — unlike
the alert, they are not modal — and the guest owns the ids.

### N2 — Time: `at` is a UNIX time in seconds, 0 = now, handed to the OS scheduler wherever one exists (RECOMMEND)

The app says WHEN; kaya says how — and the frameworks that ship this
today (flutter_local_notifications, Notifee, .NET's Plugin.LocalNotification,
Capacitor) all make the same choice: hand the time to the OPERATING
SYSTEM's own scheduler, never an in-app timer, because the OS fires it
whether or not the app is still running. Where that scheduler exists:
Apple's `UNCalendarNotificationTrigger`; Android's `AlarmManager` (an
exact alarm since Android 12 needs the `SCHEDULE_EXACT_ALARM` or
`USE_EXACT_ALARM` permission — a reminders app qualifies for the
latter — and Samsung caps an app at 500 alarms; Flutter and Notifee
both expose `allowWhileIdle` for it); Windows' scheduled toast
(`ScheduledToastNotification`, the older WinRT API, still the only one
that schedules, and what Flutter's Windows arm uses for one-shots —
repeats are unsupported there). LINUX HAS SCHEDULERS TOO — the
maintainer's correction, 2026-09-07: `at`, cron and systemd's timers are
all schedulers, and the classic recipe is literally
`echo "notify-send …" | at 21:30` (opensource.com's desktop-notifications
article). What Linux lacks is a scheduler INSIDE the notification service
— `org.freedesktop.Notifications` carries no time — and Flutter's "lack of
a scheduler API" is that plugin declining to reach past it, a framework
limit and not the platform's. So the GTK arm schedules through the
session's own manager: a transient systemd USER timer
(`systemd-run --user --on-calendar="<YYYY-MM-DD HH:MM:SS>" --collect
gapplication action <app-id> notify <n>`), which fires in the user's
session with its bus and asks the app to post through GApplication's
single-instance route: an action invoked on a second instance is always
delivered to the primary, and WHEN THE APP IS NOT RUNNING, D-Bus
activation launches it to post — GNOME keeps the notification in its
tray after the app exits, and clicking it D-Bus-activates the app with
the notification's action, the route GNOME's own apps take. So the app
need not stay running on Linux any more than on the other four: on GNOME
and through the portal the poster exits at once and the click
D-Bus-activates it (the two files — a desktop entry marked
`DBusActivatable=true` and a D-Bus `.service` naming the id — are S9's
Linux piece, the way the boot receiver is Android's); on a plain
freedesktop daemon the post shows and the click is inert, the ruled
carve-out (§0's regime 2). Where no user manager answers, `at` is the
second route (its command is the same). The codeless `notify-send --wait`
route is REFUSED with the resident mode it stands for.
Where no scheduler exists at all — the lane's container has no
systemd and no `atd` — an in-process timer is the last, and the lane
proves the systemd route by putting a RECORDING `systemd-run` on the
PATH that logs the unit it was asked for. Tauri and Electron post
immediately only on the desktop and leave timing to the app, which is
the alternative this ruling refuses: a clock in nine bindings, and S9
impossible without redoing every arm.

What S9 then adds is small and per-platform: Android's alarms die with a
reboot, so a `BOOT_COMPLETED` receiver re-registers them (Flutter's
`ScheduledNotificationBootReceiver` is the model); Apple's requests and
Windows' scheduled toasts persist on their own. The scene passes 0 and
asserts the posting at once; a real reminder passes the task's time.

### N3 — Permission: asked at the first post, answered through the result (RECOMMEND)

The first `show_notification` on a platform that prompts (macOS, iOS,
Android 13+) asks then, in context — the reminder the user just set is
the reason — and a denied prompt answers that post with `refused`. No
separate permission call, no prompt at launch (the pattern every guide
warns against), and the two platforms that never prompt answer nothing
extra. An app that wants to know beforehand has the capability query
(N6). Refused alternative: a `request_notification_permission` record
with its own occurrence — a second surface for a state the post already
reports.

### N4 — Identity: identity.toml gains `id`, the reverse-DNS name every platform wants (RECOMMEND)

macOS needs a bundle identifier to post at all, GNOME attributes the
notification to the `GApplication` id, Windows registers an AUMID for
an unpackaged exe, Android and iOS have theirs in their packages. One
`id = "dev.kaya.tasks"` in identity.toml, read by: the mac lane, which
wraps a notification-capable guest in a minimal `.app` the way the
probes already do (Info.plist from the declaration, the executable
inside), the GTK backend's application id, the WinUI registration, and
check-app-identity, which holds every hand-written copy (the iOS bundle
ids, the Android `applicationId`s) to it. This is the first pull of S11
(packaging) into the present; it is taken here because posting is
impossible without it, and it retires the hand-spelled
`dev.kaya.Milestone2`.

### N5 — What the harness fakes and what it drives (RECOMMEND: posting real everywhere, activation real where a test can reach the shade)

`expect_notification <id> "<title>"` reads the PLATFORM's own list of
delivered notifications — `deliveredNotifications` on Apple's centre,
the session bus's `org.freedesktop.Notifications` service on Linux
(the lane starts a small recording daemon of its own, since Xvfb has
none; a notification nobody serves is silently dropped), the
manager's `GetAllAsync` on Windows, `NotificationManager.activeNotifications`
on Android — never kaya's own record of what it posted (the
read-the-platform-back rule, S2b R4). `notification_activate <id>`
drives a REAL activation where a test can reach the shade: the linux
daemon invokes the default action over the bus, the android and iOS
drivers open the shade and tap the row by title (the iOS driver already
taps SpringBoard). macOS and Windows offer no programmatic tap; there
the verb delivers the platform's own activation callback with the
delivered notification's identifier, which is the backend's real
dispatch path one step past the tap — the carve-out is stated once,
uniformly, in DESIGN.md's harness section. The permission prompt is
answered by the driver on iOS (SpringBoard's "Allow") and pre-granted
on the emulator (`adb shell pm grant … POST_NOTIFICATIONS`) and the mac
(the lane's bundle is registered once with `tccutil`-free means: the
centre's prompt appears once per bundle id; the mac driver clicks it).

### N6 — Capability: `notifications` is a bit in `capabilities` (RECOMMEND)

The query every binding has answers whether THIS process can post: false
for a mac guest run bare (no bundle), false when the user has revoked
permission where the platform exposes that, true otherwise. An app
declares the reminder UI regardless and reads the bit to grey it or to
explain; the harness reads it to know what to assert. check-sugar-surface's
capability clause gains the bit in nine.

### N7 — The task manager: post at the reminder's time, open the task on activation (RECOMMEND)

Setting a reminder posts `show_notification` with the task's key as the
id's source (a stable mapping the app keeps), the title as the title,
the first line of the notes as the body, the reminder's time as `at`;
clearing it cancels. `notification_result { activated }` pushes the
task's Details screen in the section it belongs to. Nothing persists
(S4), nothing fires closed (S9).

## §3 — The lowering, per backend

| backend | post | time | activation | permission | identity |
|---|---|---|---|---|---|
| SwiftUI (macOS) | `UNMutableNotificationContent` + `UNNotificationRequest(identifier: kaya id)` | `UNCalendarNotificationTrigger` for `at`, nil trigger for 0 | the centre's delegate → occurrence | `requestAuthorization(.alert, .sound)` at the first post | the `.app` wrapper's `CFBundleIdentifier` = identity.toml `id` |
| SwiftUI (iOS) | the same | the same | the same; the app is foregrounded by the system first | the same prompt | the bundle's |
| GTK 4 | `gio::Notification` + `Application::send_notification(id)` | `systemd-run --user --on-calendar … gapplication action <id> notify <n>` (then `at`, then an in-process `glib::timeout_add` where neither scheduler exists) | the app's `notification-default` action with the id as target | none | `Application::builder().application_id(id)` |
| WinUI 3 | `AppNotificationBuilder` → `AppNotificationManager.Default().Show()` for `at` 0; `Register()` once at startup | `ScheduledToastNotification` through `ToastNotificationManager.CreateToastNotifier(aumid).AddToSchedule` for a future `at` (the OS fires it) | `NotificationInvoked` with the id in the arguments | none | `Register()` under the exe (unpackaged) |
| Compose | `NotificationCompat.Builder` on one channel ("Reminders") + `notify(id)` | `AlarmManager.setExactAndAllowWhileIdle` at `at` into a `BroadcastReceiver` that posts (`USE_EXACT_ALARM` declared; the OS fires it) | the content `PendingIntent` starts the activity with the id extra; the activity hands it to the core | `POST_NOTIFICATIONS` request at the first post on API ≥ 33 | the package's |

The body's first line is the app's choice; kaya truncates nothing.

## §4 — The wire

- TX records: `show_notification { notification u64, at u64 (unix seconds), title Value, body Value }` and `cancel_notification { notification u64 }`.
- Occurrence: `notification_result { notification u64, outcome u32 }` with the enum `notification_outcome { activated 0, refused 1 }`.
- Capability bit `KAYA_CAP_NOTIFICATIONS`.
- The spec hash moves; everything regenerates; the C floor gains the
  packer, the eight bindings the sugar in each idiom (`tx.notify(…)` /
  `on_notification`, the alert's spellings one surface over).
- identity.toml: `id`.

## §5 — The scene and the gates

- tasks.steps: set a reminder on a task (the time picker), read
  `expect_notification` for that task's id and title after `at 0`'s
  post, `notification_activate` it, `expect_title "<task>"` and
  `expect_entries 1` (the Details screen opened), then clear the
  reminder and `expect_no_notification`.
- The cut on the phones: none — both drive the shade.
- Gates: check-verbs (the two verbs in three harnesses, one observation
  spelling), check-sugar-surface (the two records' sugar and the
  capability bit in nine), check-app-identity (every hand-spelled id
  equals identity.toml's `id`; the mac wrapper's plist reads it),
  check-stubs (a backend that stubs `notifications` wires no legs),
  and a new clause: the delegate/handler path that turns a platform
  activation into `notification_result` exists on every backend and
  the harness's `notification_activate` on macOS and Windows calls THAT
  path, never a shortcut that emits the occurrence directly.

## §6 — Build order (after the rulings)

1. Spec + regenerate; identity.toml `id`; the ledger entry with its
   KEY line.
2. Depth on the mac: the `.app` wrapper in the mac lane for the tasks
   guest, the UNUserNotificationCenter arm, the two verbs, Rust's sugar,
   the task manager's post/cancel/open, the scene.
3. Breadth: iOS (the driver's shade tap and the permission press), GTK
   (the recording daemon in the linux image, the action), WinUI
   (`Register` + `Show` + `NotificationInvoked`), Compose (channel,
   permission, PendingIntent), the eight bindings; the gate rows.
4. The matrix.

## §7 — To be measured before the design is frozen

- macOS: a minimal `.app` wrapper around the tasks guest posts and
  receives activation under the lane (the process runs `.accessory`,
  which is not a bundle question — but the delegate must be set before
  the first post, and the prompt appears once per bundle id per user).
- Linux: a recording `org.freedesktop.Notifications` service over the
  lane's own session bus receives GNotification's post through GTK's
  portal-or-daemon fallback inside the container (no portal there) — the
  same service plays mako, dunst or Plasma, since all speak that one
  protocol; with the service stopped the post must come back `refused`
  and the capability false; the fired command exits once the daemon has
  answered the post (a process that exits before the reply never
  posted); and
  a recording `systemd-run` on the PATH logs the transient timer the
  arm asks for, since the container runs no systemd user manager.
  On a real GNOME session: `gapplication action` from the fired timer
  reaches the running primary instance and the post lands.
- Windows: `AppNotificationManager.Register()` from an unpackaged exe
  on the VM, and `NotificationInvoked` firing in-process while the app
  runs (the documented behaviour; measured, not assumed).
- Android: `NotificationManager.activeNotifications` visible to the
  app itself on API 34, and the driver's shade tap by title.
- iOS: `deliveredNotifications` for a request with a nil trigger posts
  while the app is foreground only if the delegate's
  `willPresent` returns `.banner` — otherwise the notification is
  silently delivered to nothing (the first measurement, since the
  scene runs foreground).
