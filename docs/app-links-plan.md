# App links — a URL that opens the app on the thing it names (rulings TAKEN 2026-09-09)

Rulings proposed and TAKEN the same day, two of them amended by the
maintainer's questions (L1: the scheme defaults to the declared id so the
manifest needs nothing new; L2: the app declares ROUTES on its handlers
and the core matches — "the ultimate surface is declaring the route that
corresponds to a window"); §4 holds the mechanics decided for the build. The slice after S4 (docs/tasks-s4-plan.md),
proposed when the maintainer asked how "some apps will take app links into
specific windows/activities directly" — it is S9's mechanism (a process
the platform starts, continuing a scene) with a door every platform can
push programmatically, which S9's notification door could not on two of
them.

## 0. The mechanism, from zero

An app link is a URL the platform hands to an app instead of to a browser.
Two kinds exist everywhere:

- A CUSTOM SCHEME the app owns by declaration — `kaya://task/t1`. Any app
  may claim any scheme; if two claim the same one the platform picks one
  (Apple says the choice is undefined, Android asks the user). No network,
  no domain, no verification, and it works on every lane today.
- A WEB LINK the app claims and the platform VERIFIES against the site —
  `https://example.com/tasks/t1`. The site publishes a file naming the app
  (Apple's `apple-app-site-association`, Android's
  `/.well-known/assetlinks.json`, Windows' `windows-app-web-link`), the
  app declares the domain, and the platform fetches the file to confirm.
  A verified web link opens the app with no dialog; an unverified one opens
  the browser. It needs a served HTTPS domain, which no lane has.

On a tap, the platform delivers the URL to the app: to the RUNNING process
when there is one, or it STARTS the app and delivers the URL at launch. The
app's job is to read the URL and show the thing it names. Each platform
has its own door:

| platform | declaring the scheme | how the URL arrives | starting it by hand |
|---|---|---|---|
| macOS | `CFBundleURLTypes` in Info.plist | TWO doors (built 2026-09-09, docs/traps.md): `application(_:open:)` on the delegate for a URL LAUNCH, the raw `kAEGetURL` handler installed in `applicationDidFinishLaunching` for a link into the RUNNING app; and the window is ORDERED ON SCREEN one turn after it registers, since a URL launch never composites it on its own (docs/traps.md) | `open -a <the .app> kaya://task/t1` (targeted — every kaya bundle claims the scheme) |
| iOS | the same plist key | SwiftUI's `onOpenURL`, the only door that fires (measured) | `xcrun simctl openurl <udid> kaya://task/t1`, after the device's one-time approval and with the leg's bundle the SOLE claimant on that device |
| Android | an `<intent-filter>` with `VIEW`, `BROWSABLE`, `DEFAULT` and `<data android:scheme="kaya">` | the activity's launch intent, or `onNewIntent` when the activity is `singleTask` | `am start -a android.intent.action.VIEW -d kaya://task/t1` |
| Linux | `MimeType=x-scheme-handler/kaya;` and `%u` on the desktop entry's `Exec` | GApplication's `open` signal (D-Bus `Open` on the activatable name, so the running instance gets it) | `gio open kaya://task/t1` |
| Windows | unpackaged: `ActivationRegistrationManager.RegisterForProtocolActivation` at launch (HKCU registry, per user); packaged: the manifest's `windows.protocol` extension | `AppInstance.GetCurrent().GetActivatedEventArgs()` of kind `Protocol` — in a NEW process every time | `start kaya://task/t1` (ShellExecute) |

The Windows row is the one that differs in kind: every activation starts a
new process, and a single-instance app redirects the second process's
activation to the first (`AppInstance.FindOrRegisterForKey`, then
`RedirectActivationToAsync` from the process that is not current, which
then exits) — the Windows App SDK's own shape, packaged and unpackaged
alike (measured facts in §2).

## 1. Rulings

- **L1. The declaration is in the manifest.** guests/assets/identity.toml
  grows a `[links]` table: `scheme = "kaya"` (one scheme, the app's own),
  and optionally `hosts = ["example.com"]` for web links. The BUILD reads
  it into every artifact (the plists' `CFBundleURLTypes`, the APK's intent
  filter, the desktop entry's `MimeType` and `%u`, the MSIX manifest's
  `windows.protocol`), and the RUNNING APP reads it once at startup for
  the one registration a build cannot make — the unpackaged Windows
  protocol registration beside the identity key S3 already writes. Web
  hosts are DECLARED AND GENERATED (the associated-domains entitlement,
  the `autoVerify` filter, the `windows.appUriHandler` extension) and NOT
  DRIVEN BY ANY LANE, since verification needs a served domain; §2 names
  the one-time hand measurement. RECOMMEND.
- **L2. Declared routes, matched once in the core.** TAKEN AS AMENDED by
  the maintainer ("the ultimate surface is declaring the route that
  corresponds to a window"): the app declares a pattern on the handler it
  already has — Rust `Messages::link("task/{key}", |params| Msg)` and each
  language's idiom for the other eight — and the core matches every
  incoming URL against the declared patterns ONCE, handing the handler its
  captures as the language's string map. The core, not the app, parses:
  the pattern rides the wire on a `declare_link_route` record, a malformed
  or repeated one FAULTS at apply with the whole sentence (where every
  other declaration refusal lands), and no binding parses a pattern or
  spells a reason word — one author, nine bindings, zero parsers. A link
  arrives whether the process was running or was started by it; one that
  arrives before the app thread exists waits in the early queue and is
  delivered first (S9's R3, one more occurrence kind). A URL no route took
  is delivered as route 0 and ANNOUNCED by the core on stderr naming the
  patterns it tried — the standing silent-drop rule — and no binding
  answers it in this slice (an `on_link_miss` registrar in the
  `on_notification_activation` shape is the additive way to, if ever
  wanted). The original proposal, an unparsed URL string handed to one
  process-level `on_open_link`, was withdrawn on the maintainer's question.
- **L3. A kaya app is single-instance on every platform.** A link tapped
  while the app runs reaches the RUNNING process. macOS and Linux do that
  natively (LaunchServices; GApplication's bus name, which S9's door already
  relies on); the phones are single-instance by the platform, with the
  Android activity moved to `launchMode="singleTask"` so a link re-enters
  through `onNewIntent` rather than stacking a second activity; Windows
  gets the App SDK's redirection in the WinUI backend at launch — register
  the identity as the instance key, redirect and exit when another process
  holds it, take the `Activated` event otherwise. This is a statement about
  PROCESSES; windows stay windows (aux windows are one process). The one
  observable a scene can pin is the warm delivery itself (L5). RECOMMEND.
- **L4. The tasks app routes two shapes.** `kaya://task/<key>` opens that
  task's details (the S9 handler's own screen); an unknown key opens Inbox
  and the caption says the link named nothing. `kaya://<section>` for
  inbox, today, upcoming, anytime and projects selects the section. Nothing
  else; a malformed URL is dropped with the caption's sentence, per Apple's
  validation note. RECOMMEND.
- **L5. Two verbs, one scene.** `open_link "<url>"` is a harness verb the
  interpreter answers by asking the PLATFORM to open the URL from inside
  the process (`NSWorkspace.shared.open`, `UIApplication.open`,
  `startActivity(VIEW)`, `g_app_info_launch_default_for_uri`,
  `ShellExecuteW`) — the platform routes it back to this app through the
  door a user's tap takes, so WARM delivery is measured through the real
  door with no runner involvement, and on Windows it is what proves L3 (the
  new process redirects and exits). `relaunch link "<url>"` is the COLD
  door: the runner starts the app through the platform with the URL (the
  right-hand column of §0's table, the Windows one from the console session
  through schtasks as the COM door is), so every lane pushes a real door —
  macOS and iOS included, which S9's notification door could not. One
  scene, `links.steps` under tools/scenes/, the same on all five lanes with no
  frame steps: act one opens a link warm and reads the details, goes back,
  opens a section link, then `relaunch link "kaya://task/t1"`; act two reads
  t1's details and its reference. RECOMMEND.
- **L6. What lanes prove and what they do not.** Every lane drives the
  custom scheme both warm and cold. No lane drives a web link. RECOMMEND.

## 2. Unknowns, each with the measurement that settles it

MEASURED 2026-09-09 (a probes agent, notes under the session's tmp; the
traps are docs/traps.md's five app-links entries of that date). Five of
six answered YES with the mechanisms below; web links skipped for want of
a served domain.

1. **macOS: YES.** LaunchServices delivers to an accessory, ad-hoc-signed,
   un-ranked bundle: warm 55 ms, cold 146 ms (21 ms into the process,
   before `didFinishLaunching`, `windows=0`). THE DOOR IS THE RAW APPLE
   EVENT (`kAEGetURL` in `applicationWillFinishLaunching`): SwiftUI's
   `WindowGroup` opens a NEW WINDOW per link through `.onOpenURL`, and with
   it present the delegate's `application(_:open:)` gets an empty array.
2. **Windows: YES.** `start "" "<scheme>://…"` starts a second process every
   time; `GetActivatedEventArgs().Kind()` is Protocol with the URI byte for
   byte; `RedirectActivationToAsync` reaches the owner's `Activated` in 1-9
   ms and the redirector may exit as soon as the call returns; no message
   pump needed on either side; the apartment changes only who completes
   the async action. The activated process is a child of the calling cmd
   and inherits its environment, so the lane's door can carry
   XDG_STATE_HOME itself; the URL cannot ride a `%1`.
3. **Android: YES.** `onNewIntent` on the same instance ~10 ms after
   `am start -a VIEW -d`, brought forward, URI intact, no prompt; cold on
   `onCreate`'s intent in 38 ms. `getIntent()` inside `onNewIntent` is the
   OLD intent until `setIntent`, and the activity's `KAYA_*` env mapping in
   `onCreate` never runs on a warm single-task start (both to be handled in
   the arm).
4. **Linux: YES.** Warm reaches the running instance's `open` signal over
   `org.freedesktop.Application.Open` in 2-6 ms; cold is D-Bus activation
   in 44-49 ms with `activate` firing BEFORE `open` (kaya must not use
   `--gapplication-service`; the early queue covers it). `gio open` needs
   `DBusActivatable=true` AND the `.service` file; `xdg-open` is not the
   door (absent from the image, and it blocks for the app's lifetime).
5. **iOS: YES, with one change to the lane's door.** `simctl openurl` raises
   a SpringBoard `Open in "<app>"?` alert the first time, exits 0 and
   delivers nothing; one `sb_tap Open` through the lane's XCUITest driver is
   remembered per device and survives reinstalls. Then cold ≈ 720 ms (after
   the root view appeared) and warm 101 ms; `.onOpenURL` is the ONLY door
   that fires. `UIApplication.open` of the app's own scheme is unprompted.
6. **Web links: SKIPPED** — a served HTTPS domain is needed; the generated
   entitlement, `autoVerify` filter and `windows.appUriHandler` are checked
   by shape and the ledger says so.

What the five say together: cold delivery beats the scene on macOS and
Windows and loses to it on iOS and Linux, so L2's early queue is
load-bearing; every platform is single-instance for links by a different
mechanism (macOS routes to the FIRST-launched of two direct-exec'd copies;
Windows only because the redirector asks; Linux through the bus name);
only iOS asks the user anything, once per device; and `open_link`'s
round trip is 49 ms on macOS (leaving the accessory guest frontmost),
21 ms on iOS and 2-6 ms on Linux.

The original questions, kept for the record:


1. **macOS accessory apps and `kAEGetURL`.** Kaya's guests run with the
   `.accessory` activation policy; whether LaunchServices delivers a
   scheme's Apple event to an accessory process (and to a bundle with no
   registered `LSHandlerRank`) is measured with `open kaya://…` against the
   bundled tasks guest, warm and cold, before any arm is written.
2. **Windows redirection under the lane's launcher.** `FindOrRegisterForKey`
   and `RedirectActivationToAsync` from a Rust process with the bootstrap
   initialized: the second process's lifetime, whether the redirect needs
   the caller's COM apartment, and whether `GetActivatedEventArgs` answers
   `Protocol` for a `start kaya://…` from the console session. Measured with
   a probe exe on the VM.
3. **Android `singleTask` and the Compose activity.** `am start -a VIEW -d`
   with the app in the background: `onNewIntent` on the same activity, the
   activity brought forward on the emulator, and the launch-mode change not
   breaking the notification door (S9's tap starts the same activity).
4. **Linux `gio open` in the container.** The desktop entry staged into the
   leg's own XDG home by persist-leg.py's route carrying `MimeType=` and
   `%u`; `xdg-mime` picking it; GApplication needing `HANDLES_OPEN` and the
   `open` signal on the running instance through D-Bus activation's `Open`.
5. **iOS `simctl openurl`.** Warm delivery to the running app through
   `onOpenURL` / `scene(_:openURLContexts:)`, cold through
   `connectionOptions.urlContexts`, and whether the simulator asks anything.
6. **Web links, once, by hand.** If the maintainer has a domain to serve
   the association files from, one macOS run with `open https://…` against
   a signed bundle with the entitlement; otherwise the generated artifacts
   are checked by shape only (the entitlement, the filter, the extension
   present and naming the declared hosts) and the ledger says so.

## 3. Build order

Depth first: the spec occurrence (`link_opened { url }`) and its early
queue, `Messages::on_open_link` and the announced drop in Rust, the
manifest table and its readers, the macOS door (the plist key from the
manifest, the Apple-event arm, `open_link` and `relaunch link` in the
SwiftUI interpreter and tools/lib/lanes/mac.py), the tasks app's routing,
the links scene green on the mac by hand. Then breadth on five
agents: iOS (the same interpreter, the simctl door), Android (the intent
filter from the manifest, `singleTask`, the intent arm, the `am start`
door), Linux (the desktop entry's two lines, the GApplication `open` arm,
the `gio open` door), Windows (the registration, the redirection, the
protocol arm, the schtasks door), the bindings sweep (eight registrations
and eight copies of the sentence, check-sugar-surface's clause). A lane's
`RELAUNCH_DOOR` entry and the scene's `relaunch` line are ONE change
(docs/tasks-s9-plan.md §3). One matrix, one review page with the link
opening the task on all five.

## 4. Mechanics decided for the build (2026-09-09)

- **The scheme defaults to the declared id.** A reverse-DNS string is a
  valid URL scheme (RFC 3986's `ALPHA *(ALPHA / DIGIT / "+" / "-" / ".")`)
  and unique by construction, which is what Google's own OAuth schemes
  are; so `dev.kaya.aurora.notes://task/t1` works with no declaration, and
  `[links] scheme = "kaya"` is the optional override. `[links] hosts`
  stays for web links. The tasks app declares nothing — the lanes drive the
  default. Each backend's registration is held to accepting a dotted scheme
  (the MSIX `uap:Protocol Name` pattern is the one to measure).
- **Routes are declared in the app and matched ONCE, in the core.** A
  TX record `declare_link_route { route: u64, pattern: str }` carries each
  pattern to the core; the occurrence `link_opened { route: u64, url: str,
  params: [(name, value)] }` comes back with the captures — `route` 0 and
  no params for a URL no route matched, which the core ANNOUNCES on stderr
  naming the URL and the patterns it tried, the standing silent-drop rule.
  The pattern grammar: path segments split on `/`, `{name}` captures one
  segment, a literal segment matches itself; the string matched is
  everything after `<scheme>://` for the app's own scheme and everything
  after the host for a declared web host; the query's pairs join the
  params (a capture wins a name clash), the fragment is dropped. The
  binding sugar is `Messages::link("task/{key}", |params| Msg)` in Rust
  and each language's idiom for the other eight; a duplicate pattern or a
  malformed one (an empty segment, an unclosed brace) FAULTS in the core
  when the record applies, which is where every other declaration refusal
  lands (a collection already bound to a For, a role already claimed) and
  is why no binding parses a pattern or spells a reason word — one author,
  nine bindings, zero parsers (amended 2026-09-09, after a ruling that had
  put a validator on the C floor and a copy of the prose in each binding).
  ROUTE 0 HAS NO REGISTRAR IN THIS SLICE: a URL no route took is announced
  by the core and delivered as route 0, and every binding stays silent on
  it, since `link` is the only registrar and its ids start at 1. An app
  that wants to answer an unmatched link needs `on_link_miss`, the
  `on_notification_activation` shape taking the URL — additive, no wire
  change, and out of this slice.
- **One internal door in the core.** Every backend hands a URL to
  `crate::links::opened(url: &str)` — thread-safe, queued when no app
  thread exists yet and delivered first (S9's early queue, one more kind)
  — and never parses anything itself. The platform arms: the raw
  `kAEGetURL` Apple event on macOS, `onOpenURL` on iOS, the activity's
  intent (`onCreate`'s and `onNewIntent`'s, `setIntent` first, consumed
  once) on Android, GApplication's `open` signal with `HANDLES_OPEN` on
  Linux, `GetActivatedEventArgs` of kind Protocol plus the redirected
  `Activated` event on Windows, with `FindOrRegisterForKey` on the declared
  id and the second process exiting the moment its redirect returns.
- **The harness.** `open_link "<url>"` asks the platform from inside the
  process (`NSWorkspace.shared.open`, `UIApplication.open`, `startActivity`
  with VIEW, `g_app_info_launch_default_for_uri`, `ShellExecuteW`) and
  returns once the app has answered it (the action rule of 2026-09-06);
  `relaunch link "<url>"` is the cold door per lane: `open` on macOS,
  `simctl openurl` on iOS with the simulator's one-time approval alert
  answered through the lane's driver (`sb_tap Open`, remembered per
  device), `am start -a android.intent.action.VIEW -d` on Android,
  `gio open` on Linux (the desktop entry with `DBusActivatable=true` AND
  the service file staged into the leg's XDG home), and on Windows a
  ShellExecute from the console session through schtasks with the URL
  handed in a file rather than a `%1`. The scene, `links.steps`: act one
  `open_link` on a task (details pushed, the title read), back, `open_link`
  on a section (`expect_section`), then `relaunch link` on t1; act two
  reads t1's details and its reference. No frame steps; one cut for all
  five lanes. RELAUNCH_DOOR["links"] = "link" on every lane.
- **The tasks app.** `link("task/{key}", …)` onto the Details push it
  already has, an unknown key answered by Inbox with a caption sentence;
  `link("{section}", …)` selecting the named section, an unknown name
  dropped with the caption's sentence.
- **Windows and Android details from the measurements.** The unpackaged
  registration is written beside the identity key at launch and the lane
  removes `HKCU\Software\Classes\<scheme>` itself, since the SDK's
  unregister leaves it; the activated process inherits the launching cmd's
  environment, so the link door's .cmd carries XDG_STATE_HOME; the Android
  activity is `singleTask`, and its `KAYA_*` environment mapping moves out
  of `onCreate` so a warm start still maps it.
