# Task manager S9 — the closed-app click

Ruled 2026-09-08 (the maintainer: "go for it", after the Windows door was
ruled the COM activator in conversation). S3 posts a reminder at its time;
S9 makes the tap on that reminder work when the app is no longer running:
the platform relaunches the app and the app opens that task's details.

## §0 — What this is, in one paragraph

A notification the platform delivers after the app has exited carries an
id kaya chose (the task's). The tap goes to the platform, the platform
starts the app through its own door, and the freshly started process must
learn which notification started it and hand that to the app as the same
`notification_result` it would have received while running. Every
platform has a door; four of them work today and Windows' needs the COM
activator the maintainer ruled. The harness needs one new thing: a scene
that continues in the process the platform relaunches.

## §1 — The rulings

- **R1. One occurrence, one new registration.** The relaunched process
  receives the tap as `notification_result { notification, activated }`,
  exactly S3's occurrence. S3's handler is one-shot and bound at the show,
  and a relaunched process never called show, so the app registers a
  PROCESS-LEVEL handler beside it: `msgs.on_notification_activation(f)` in
  Rust, spelled in each binding as its alert-registration idiom (the
  bindings sweep names all nine). Dispatch: the per-id one-shot handler
  when one is registered, else the process-level one, else dropped with
  the diagnostic below. Uniform in nine.
- **R1a. The spelling, decided 2026-09-08 13:40.** The process-level handler
  receives the id AND the outcome in all nine (the one-shot receives the
  outcome alone, as today); a second registration replaces the first and it
  never retires; the announced drop is ONE sentence in nine, the binding's own
  registrar name in the parentheses: `kaya: notification <id> outcome
  <activated|refused> reached no handler — none was bound at the show and no
  process-level handler is registered (<registrar>)`. Rust's registrar is
  `Messages::on_notification_activation(f)` with `f: Fn(NotificationId,
  NotificationOutcome) -> M`; tools/check-sugar-surface.py holds the
  registrar in nine, the dispatch ORDER read out of each arm, and the
  sentence.
- **R2. The id is the app's, so the app can map it back.** The relaunched
  process has none of the old process's memory, so the tasks guest derives
  the notification id from the task's key (t2 → 2) instead of a counter,
  and a re-post under the same task replaces under the same id;
  tools/scenes/tasks.steps' S3 block moves to those ids. S4's preferences
  store is the general answer for app state across relaunch; S9 needs only
  the id to be stable, which it now is by construction.
- **R3. The platform hands the core the launch activation, the core hands
  the app the occurrence.** Each backend's launch path calls
  `kaya_emit_notification_result(id, activated)` the moment it learns the
  process was started by a tap — before or after the app thread exists; the
  core queues an occurrence that arrives before the app thread's first read
  when it is early, and as an ordinary occurrence when it is late. No new
  wire, no new spec kind.
- **R4. The doors.** macOS and iOS: `UNUserNotificationCenter` relaunches
  the app for a tap and the delegate's `didReceive` carries the identifier
  (standard; measured in this slice with tools/mac/notifyprobe and
  tools/ios/notifyprobe for the record). Android: the notification's
  content intent starts the activity with the id extra — proven under S3
  (an alarm fired into an exited process). Linux: the portal D-Bus-activates
  the app and calls `org.freedesktop.Application.ActivateAction` with the
  notification's default action and its target — MEASURED 2026-09-08 on the
  lane's image (xdg-desktop-portal 1.20.3 + gtk backend 1.15.3, dbus-monitor
  on a private bus, a poster that exits): the backend splits on the action's
  NAMESPACE. A bare `notify-activated` is a portal-scope action: the app is
  relaunched through `Activate([])` carrying nothing and the frontend's
  `ActionInvoked` is unicast to the dead posting connection, which is
  exactly what S3 saw (its ledger sentence blamed the listening arm; it was
  kaya's own spelling). `app.notify-activated` makes the backend call
  `ActivateAction("notify-activated", [<'kaya-1'>], {})` on the relaunched
  process and emit nothing else; GNOME's `org.gtk.Notifications` route sends
  the identical call, so one door serves both. The arm's change is the
  namespace on the portal route's default action plus the GAction registered
  ahead of the app's activate handler; the parameter is `kaya-<id>`, read
  back by `notification_id_of` unchanged. Windows: THE COM
  ACTIVATOR — the exe implements `INotificationActivationCallback`,
  registers its class id under HKCU beside the identity key when
  unpackaged, and the packaging arm declares it in the manifest's
  `windows.toastNotificationActivation` extension when packaged; a toast
  carries the id in its arguments (`kaya=<id>`, the shipped launch-argument
  spelling with its `;`-separated parser; the tag stays `kaya-<id>`); COM
  starts the exe and calls `Activate`. THE CLASS ID IS DERIVED, never typed:
  RFC 4122 version 5 over the AUMID the process posts under — the declared id
  unpackaged, `<id>!<Application Id>` packaged — because one MSIX carries N
  entry points while a CLSID names one server, and HKCU's registration would
  shadow the package's if the two situations shared an id (decided
  2026-09-08 with the Windows agent's measurements).
- **R5. The silent-drop rule, applied.** Until every door is built, a
  backend that posts a notification it cannot relaunch for prints
  `KAYA_DIAG notification <id> posted with no relaunch door: a tap after
  exit lands nowhere` at the post, and that sentence is in
  tools/check-diagnostics.py's census. A drop nobody announced is the
  defect class.
- **R6. THE SECOND ACT — the harness continues in the relaunched process.**
  A scene may contain one `relaunch` line. Act one runs to it in the
  first process, which then (a) writes the ACT-TWO MARKER — the scene name
  and the steps after `relaunch` — into the app's own state directory
  (the platform's: `~/.local/state/kaya/act2/<id>` on the desktops' unix
  side, `%LOCALAPPDATA%\kaya\act2\<id>` on Windows, the files directory on
  Android, Documents on iOS), (b) prints act one's verdict as
  `KAYA_SELFTEST: ACT 1 OK (…)`, and (c) exits cleanly. The RUNNER then
  pushes the platform's door from outside — the runner's own shade tap on
  Android, the recording daemon's ActionInvoked on Linux, `CoCreateInstance`
  of the activator's class id on Windows (the OS's own door, one step past
  the tap), and on macOS and iOS, where no programmatic tap exists, the
  runner launches the bundle with `KAYA_LAUNCH_NOTIFICATION=<id>` and the
  interpreter delivers it exactly as the centre's delegate would (the S3
  carve-out one step further; stated in DESIGN.md's Notifications section).
  The second process finds the marker with no environment at all, runs the
  steps after `relaunch`, writes its verdict beside the marker as
  `act2.verdict` and to stdout, and exits; the runner polls the file and
  joins both verdicts as ONE leg. The marker is consumed on read, so a
  stale one cannot serve a later run. check-steps holds: at most one
  `relaunch` per scene, an act two that is non-empty, and every runner's
  door named for every scene that has one.
- **R6a. The spellings, decided 2026-09-08 13:20 so the five arms agree.**
  The verb is bare `relaunch`, no arguments, at most one per scene, ALONE ON
  ITS LINE (all three harnesses split the script at that line; one folded
  into a `;` statement parses as a verb and splits nothing), act two
  non-empty; tools/check-steps.py holds the shape, the five doors (mac and
  ios `launch-notification`, android `notify_tap`, win `com-activator`,
  linux `portal-action`) and the one-path rule over comment-stripped code,
  with a census refusal when no scene carries a `relaunch` and seven watched
  negatives. ONE layout everywhere: the directory `<state>/act2/<id>`, `<id>`
  the manifest's reverse-DNS id, `<state>` = `~/.local/state/kaya` on macOS
  and Linux, `%LOCALAPPDATA%\kaya` on Windows (so `%LOCALAPPDATA%\kaya\act2\<id>`), the
  app's files directory on Android, Documents on iOS; inside it `marker` (line 1 the scene name, the
  remaining lines the act-two steps verbatim; the second process deletes it
  the moment it reads it) and `act2.verdict` (one line). Act one prints
  exactly `KAYA_SELFTEST: ACT 1 OK (…)` or `KAYA_SELFTEST: ACT 1 FAILED (…)`,
  distinct from the ordinary verdict by construction; act two prints the
  ordinary `KAYA_SELFTEST: OK (…)` / `FAILED (…)` to stdout and writes that
  same one line as the file's whole content; a leg is PASS iff act one's line
  is ACT 1 OK and the file reads OK. The arms: `Step::Relaunch` in
  harness.rs, `case "relaunch":` in SwiftUI, `"relaunch" ->` in Compose. The
  door census: each python lane module exports `RELAUNCH_DOOR = {"tasks":
  "<door>"}` (mac and ios: `launch-notification`; android: `notify_tap`;
  win: the COM door's name) and tools/linux/run-suites.sh carries a
  `RELAUNCH_DOOR_TASKS=<door>` line; check-steps reads both shapes. The
  second process has no environment: the harness sets KAYA_SELFTEST (the
  scene) and KAYA_SELFTEST_SCRIPT (the act-two steps) in-process from the
  marker before the app thread starts, since guests pick their scene from
  KAYA_SELFTEST; the lane's launcher (the desktop entry's Exec on Linux, the
  staged exe's neighbours on Windows) supplies the library and the asset
  root the way an installed app has them.
- **R6b. The core consumes the marker (ruled 2026-09-08 14:20, on the Android
  agent's ordering).** On Android the guest reads KAYA_SELFTEST on the app
  thread that `attach` itself spawns, so anything done after attach returns
  races the scene read. So `act2::arm(state_root)` in crates/kaya/src/act2.rs
  runs inside attach/run BEFORE the spawn: it computes `<root>/act2/<id>`,
  exports KAYA_ACT2_DIR, and if `marker` exists deletes it and sets
  KAYA_SELFTEST (line 1), KAYA_SELFTEST_SCRIPT (the rest) and KAYA_ACT2_VERDICT;
  the three harnesses run act two as an ordinary scene and write their verdict
  to KAYA_ACT2_VERDICT's path as well as stdout. No interpreter copies the
  path or the format. Android's attach entries take the state root
  (`Kaya.attach(activity, stateRoot)`, `KayaRing.attach(activity, stateRoot)`,
  the host passing `filesDir.absolutePath`); iOS and Windows roots are
  computed. MEASURED with it: `am force-stop` cancels the app's own
  notifications and takes the door with it, so act one's CLEAN EXIT is
  required and a process still alive after its verdict is that failure,
  never force-stopped.
  THE MODULE'S GATE: act2.rs is compiled under `feature = "harness"` OR
  macOS/iOS/Android, because those three platforms' guests build WITHOUT the
  feature while their interpreter carries the harness, whereas a shipped GTK
  or WinUI app has no harness at all — no `relaunch` verb to have run, no act
  one to have written a marker — so act2's absence there is correct rather
  than a hole; a missing state root on Android prints one refusal naming
  both attach entries.
- **R7. What the lanes prove, and what stays a carve-out.** Android, Linux
  and Windows exercise the platform's real relaunch door; macOS and iOS
  exercise the app's handling of a launch-time activation through the
  carve-out, and the OS's own relaunch is measured once by the probes and
  recorded, not driven by a leg.

## §2 — Unknowns to measure before the arms are called done

1. MEASURED 2026-09-08 on macOS with tools/mac/notifyprobe's S9 mode, the
   host idle (HIDIdleTime 404s at the start) and every press through the
   accessibility API on the element: the probe posted and exited, 151s
   passed with no process of its bundle alive, the tap on the delivered
   notification relaunched the ad-hoc, LSUIElement, accessory-policy bundle
   outside /Applications, and `didReceive` carried the identifier 31ms after
   launch (`ACTIVATED kaya-task-12 action=…DefaultActionIdentifier`). And on
   the iOS SIMULATOR, measured the same day with tools/ios/notifyprobe and
   the driver: a notification scheduled 25s out with the app TERMINATED
   (`launchctl list` counting 0 processes of the bundle) fires, shows a real
   BANNER over SpringBoard, and a tap on it relaunches the app and delivers
   the identifier (`ACTIVATED kaya-12 …DefaultActionIdentifier` in a process
   that did not exist a moment before) — the banner's button is labelled
   `now, <title>, <body>`, not the title, and reports `hittable=false` while
   the tap lands anyway, so S3's reading of that flag as a refusal was wrong
   on this route: THE SHADE ACTIVATES NOTHING, A BANNER DOES, including for
   an app that has exited. The lanes still take the KAYA_LAUNCH_NOTIFICATION
   door, since a banner is a five-second window a leg cannot depend on. So the
   mac arm prints no R5 sentence; the sentence is the Windows arm's alone and
   only on a real miss (the activator's registration absent or failed). The
   draft's question was:
   macOS and iOS: that a terminated app is relaunched for a tap and
   `didReceive` carries the identifier (notifyprobe, both platforms; the
   probe posts, exits, and the centre's tap — by hand on the mac, by the
   driver on the simulator if the shade tap works for a BANNER over another
   app, which S3 found it does — relaunches it).
2. Linux: that xdg-desktop-portal 1.20's notification portal calls
   `ActivateAction` with the target on a D-Bus-activated app, and what GNOME's
   `org.gtk.Notifications` route sends on relaunch.
3. MEASURED 2026-09-08 on the VM: both two-act legs are green on the COM
   door — `tasks_rust` through the HKCU registration and `taskspkg_rust`
   through the packaged class id and the package's own `com:ExeServer`, act
   two answering in 502ms and 600ms with the tap's arguments intact; R5's
   sentence printed on both of its branches by watched negatives (the
   registration withheld; an empty asset root naming identity.toml) and on
   no green run; and the packaged act two answered from the PLAIN
   `%LOCALAPPDATA%\kaya\act2\<id>` path, so a full-trust MSIX's LocalAppData
   is not redirected on this build. The draft's question was:
   Windows: that COM starts the exe and calls `Activate` with the toast's
   arguments for an unpackaged HKCU registration and for the packaged
   manifest extension; whether the started process gets a window station
   from the lane's session (it should, since COM starts it in the caller's
   session).
4. All: the marker's directory is writable by the relaunched process on
   every platform, and the act-two verdict reaches the runner within the
   leg's ceiling.

## §3 — Build order

A lane's `RELAUNCH_DOOR` entry and the scene's `relaunch` line are ONE change:
the door census refuses a door named for a scene with no `relaunch` (it fired
on the Android lane's first real run, with the scene block not yet landed —
the watched negative for free), so the scene lands with or before the door.

1. The core and harness: R1's registration in Rust, R3's queue, R6's
   `relaunch` verb and marker in all three harnesses, the runners' act-two
   join, check-steps' clauses; the mac and iOS arms with the carve-out
   door; the tasks guest on stable ids; the scene's second act
   (`relaunch` → `expect_entries 1` → `expect_href label@reference
   "https://example.com/tasks/t1"`).
2. In parallel once the contract is on disk: the bindings sweep (R1 in
   nine, check-sugar-surface), the Android door (runner tap after force-stop),
   the Linux door (GAction + the daemon's tap after exit), the Windows door
   (the COM activator, registration, manifest extension, the runner's
   CoCreateInstance).
3. The matrix, and a review page: each platform's relaunched app on the
   task, and the probes' readings.
