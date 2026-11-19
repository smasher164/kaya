# Session restoration and durable file references (design pass, 2026-11-17)

Status: BUILT 2026-11-18: every ruling on all five platforms, the nine bindings and the C floor, with the editor, chat and the music player as its first consumers; what the build settled beyond the rulings, for the maintainer's review, is §9. Review page
claude.ai/artifact/DxTd4WDaWRcBnQMRBqBQYK. The maintainer, 2026-11-17:
"let's design session restoration now". This plan is the design pass for
docs/deferred.md's session restoration entry (headed "core-owned, and
cheap only here") and its sibling "No bookmark/persistence machinery: a picked file cannot be
reopened across restarts", and for the roadmap entry "Session restoration and
durable file references" (docs/roadmap/editorial.toml). The rulings are §6,
SR1 to SR18; each repeats its mechanism so it reads on its own. The four the
maintainer most needs to look at are SR1, SR3, SR6 and SR11; the rest follow
from them.

Platform facts are CITED from documentation and toolkit sources (§1, with
links). One was MEASURED for this pass: the GTK the linux lane runs (§1.5).
Nothing ran on a device pool. §5's step 0 names the facts the build measures
before it builds on them.

KEY: session restoration, restore, session store, durable reference,
bookmark, persistable URI, recent files, reopen across restarts,
restoration-plan

## §0. The mechanism, from zero

**What restoration is.** An app is RESTORED when, after its process ends and
starts again, it comes back the way the user left it: the same windows at the
same sizes, the same tab or page selected, lists scrolled to the same place,
the caret where it was, half-typed text still there, the same documents open.
Two different things have to come back, and the whole design turns on telling
them apart:

1. **The app's own state**, its MODEL: which conversation is open, which
   documents, the playing track and its position, a draft. kaya never holds
   this. The app is the transition function (DESIGN.md, the reactive
   surface): it keeps a model in its own language and writes SIGNALS (the
   core-held values widgets bind to) derived from it.
2. **Presentation state**: how far a list is scrolled, where the caret sits in
   a text view, a window's frame. The app never models these; the native
   widget holds them, and in most cases no occurrence (an event record kaya
   sends the app) ever reports them. The one exception is a `rich`
   textarea's selection, which occurrence kind 61 `text_selected` reports so
   the app can light a format toolbar (spec.rs; docs/phone-format-plan.md
   §3); the app reads that report and still does not model the caret.

**What kaya's core actually holds.** The charge's premise is that the core
owns the interface's state. That is half true, and the half that is not true
decides the design. The core holds every signal's current value, every
collection's records, the selected section of each window, each navigation
stack, each window's documents and its active one, sheets and fullscreen
(crates/kaya/src/scene.rs, `struct Scene`). It does NOT hold the text a user
typed, the caret, any selection, any scroll offset, focus, or a window's frame
after the user resized it: those are WIDGET-OWNED by doctrine (a rich
textarea's selection is reported through `text_selected`, but the core keeps
no copy of it). kaya's text
widgets are UNCONTROLLED toward the app (the widget owns its text and the app
folds `text_changed` into its own model, spec.rs `text_changed`), and "there
are no widget mirror reads" (DESIGN.md, Templates). The undo recon found the
same list (docs/probes/undo-recon-surface.md, gap 6: "Core holds no focus, no
scroll offset, no user-typed entry text, no post-resize window geometry, and
no selection ... 'Serialize the core scene' is a partial answer for session
restoration").

So "serialize the core scene" (the ledger entry's 2026-07-24 framing) would
save the wrong things. The signals it holds are DERIVED values (a formatted
label, a title), and restoring a derived value without its source leaves the
app's model saying one thing and the screen another; the app's next write
overwrites it anyway. And the things the user would notice most (the scroll,
the caret, the typed text) are exactly what the core does not hold.

**What kaya already restores.** WINDOW MEMORY (docs/tasks-s4-plan.md P4, built
2026-09-09): the four desktops save each window's frame under the reserved
preference key `kaya.window.<id>.frame`, coalesced onto the toolkit's idle,
and restore it before the first frame; `remember_frame(false)` opts a window
out; the phones are inert. Beside it, P8's SIDEBAR MEMORY (the same plan,
built on the Mac 2026-10-25): the sidebar width the user dragged is saved
under the permanent reserved key `kaya.window.<id>.sidebar` and restored at
launch as the column's ideal width. Both are permanent preferences, and
restoration leaves both as they are. Its conflict rule is the precedent for SR4: the
remembered frame beats the declaration BY VALUE, and the first different value
the app asks for is the app resizing itself, which applies and ends the
memory.

**What a durable file reference is.** When the user picks a file, kaya hands
the guest a HANDLE (DESIGN.md, File dialogs): a token kaya can redeem for an
open descriptor for the life of the process. It dies with the process. A
DURABLE REFERENCE is a token that survives the process: the app stores it
(in its database, its preferences, or the session store below) and redeems it
at the next launch for a fresh handle, without showing a picker. Every
platform has the machinery, each spelled differently (§1.6): a security-scoped
or plain BOOKMARK on Apple platforms (an opaque blob the OS resolves back to a
URL, following moves and renames), a PERSISTABLE URI PERMISSION on Android (a
grant the system keeps across reboots, counted per app), and on GTK and
Windows the path itself.

## §1. What the platforms and toolkits do (the research)

### §1.1 Android

- Saved instance state. The system calls the activity to save a `Bundle`
  when it stops; the Bundle survives configuration changes and
  SYSTEM-INITIATED process death, and is DISCARDED when the user dismisses the
  app completely: "Swiping the app off of the Overview (Recents) screen.
  Killing or force-quitting the app from the Settings screen. Rebooting the
  device. Completing some sort of 'finishing' action" (developer.android.com/
  topic/libraries/architecture/saving-states). It is for "only primitive types
  and simple, small objects such as String", serialized on the main thread,
  and "Saved state APIs only save data written to it when the Activity is
  stopped".
- Views. A View's state (EditText's text, a ScrollView's position, a
  checkbox) is saved only when the view has an `android:id`, and a view
  without one is skipped (View.dispatchSaveInstanceState checks `mID !=
  NO_ID`). Identity is an authored id.
- Compose. `rememberSaveable` saves into the same Bundle under a key that
  defaults to the composable's POSITION in the composition
  (`currentCompositeKeyHash`), which is why moving a composable resets it;
  `rememberScrollState`, `rememberLazyListState` and `rememberTextFieldState`
  are saveable by default (the `rememberSaveable` API reference,
  developer.android.com/reference/kotlin/androidx/compose/runtime/saveable/
  package-summary, and its source in androidx's
  compose/runtime/runtime-saveable; the state-saving guide names only
  `rememberLazyListState` and says nothing about keys). Identity is tree
  position unless a key is given.
- kaya on Android today. The scene model lives in the process; a later
  `onCreate` (rotation, night mode, locale) re-attaches the presentation and
  re-projects the model, invisible to guests (DESIGN.md, Platform backends,
  the Android row). Process death is a cold start with nothing restored: no
  kaya activity overrides `onSaveInstanceState` (the four hosts' MainActivity
  call `super.onCreate(savedInstanceState)` and read nothing).
- Persistable URI permissions. `takePersistableUriPermission` keeps a
  document grant across process death and reboot; an app may hold 128 such
  grants before Android 11 and 512 from Android 11 (issuetracker.google.com/
  149315521; commonsware.com/blog/2020/06/13/count-your-saf-uri-permission-
  grants.html; one forum report says 14, not 11), and a grant past the limit
  fails. `getPersistedUriPermissions` counts them and
  `releasePersistableUriPermission` frees one. kaya's minSdk is 26, so the
  floor across the roster is 128. kaya's safe save already takes one for its
  own crash path and releases it "unless the app already held one"
  (docs/rich-document-plan.md §4.1).

### §1.2 iOS

- Scene-based restoration: "For scene-based apps, UIKit asks each scene to
  save its state information using an NSUserActivity object"
  (`stateRestorationActivity(for:)`), and the scene reads it back in
  `scene(_:willConnectTo:options:)` (developer.apple.com/documentation/uikit/
  restoring-your-app-s-state). The page frames the lifetime as debugging
  advice: "When debugging the sample project, the system automatically
  deletes its preserved state when the user force quits the app ... In
  addition, the system deletes the preserved state if the app crashes at
  launch time." The behavior is the system's; the guarantee is no stronger
  than that sentence, and SR6 adopts the rule uniformly on its own account.
- SwiftUI `@SceneStorage`: per scene, keyed by a string the app names, "its
  initial value is restored by the system if it was previously saved"; "The
  system makes no guarantees as to when and how often the data will be
  persisted"; "Ensure that the data you use with SceneStorage is
  lightweight"; "If the Scene is explicitly destroyed (e.g. the switcher
  snapshot is destroyed on iPadOS or the window is closed on macOS), the data
  is also destroyed. Do not use SceneStorage with sensitive data"
  (developer.apple.com/documentation/swiftui/scenestorage).
- Bookmarks: iOS has no security-scoped bookmark option (the flag is
  `API_UNAVAILABLE(ios)`, docs/file-dialogs-plan.md); a plain bookmark made
  while the picked URL's scope is held resolves to a URL that can start its
  scope again. DESIGN.md's measurement 5 (a held URL re-acquires its scope)
  is the in-process half of the same fact.

### §1.3 macOS

- AppKit window restoration: `NSWindow.isRestorable` defaults to true for a
  titled window, "During subsequent launch cycles, the system tries to
  recreate the window and restore its configuration", with a
  `restorationClass` that rebuilds it (developer.apple.com/documentation/
  appkit/nswindow/isrestorable). Responders add their own state through
  `encodeRestorableState(with:)`; "the NSTabView class uses this method to
  save information about the currently selected tab"
  (.../nsresponder/encoderestorablestate(with:)).
- Whether restoration happens is the USER'S setting, "Close windows when
  quitting an application" (System Settings, Desktop & Dock), stored as the
  global default `NSQuitAlwaysKeepsWindows`; Option-Command-Q is said to
  invert it for one quit ("Quit and Close All Windows" / "Quit and Keep
  Windows"), which no Apple page fetched for this pass states, so §5 step 0
  (a) measures whether AppKit exposes that choice to an app at all. Chromium
  reads the same key and treats an absent value as Lion's intrinsic default,
  YES (chromium .../chrome/browser/ui/cocoa/window_restore_utils.mm). On this
  host the key is absent (`defaults read -g NSQuitAlwaysKeepsWindows`, read
  2026-11-17), so the default a fresh account sees is a step-0 measurement
  (§5), not a citation.
- kaya on macOS today. The windows are SwiftUI `WindowGroup` windows; kaya
  drops AppKit's own `NSWindow Frame` keys at launch and clears each window's
  autosave name (`kayaForgetAppKitFrames`, docs/traps.md, the shared-domain
  frame entry), because its own window memory is the only one. The aux
  windows are `WindowGroup(for: UInt64.self)` (swift/KayaSwiftUIEntry.swift),
  and Apple's `WindowGroup.init(for:content:)` says "SwiftUI automatically
  persists and restores the value of this binding as part of the state
  restoration process"; `Scene.restorationBehavior(_:)` defaults to
  `automatic` and its `.disabled` is macOS 15+. Nothing in swift/ turned
  this off before the build, so a clean quit could bring an aux window back
  under an id the guest had not allocated (§5 step 0 (a), SR6). kaya's mac
  apps are not sandboxed (docs/probes/save-probe-mac.md), so a path reopens;
  a bookmark still earns its place because it follows a rename or a move.

### §1.4 Windows

- No UI restoration API in WinUI 3 or the Windows App SDK. The nearest thing
  is `RegisterApplicationRestart`: Windows restarts a registered process after
  an update (automatically) or after a crash or hang (with the user's
  consent), "only ... if it has been running for a minimum of 60 seconds",
  passing a command line the app chose (learn.microsoft.com/windows/win32/
  api/winbase/nf-winbase-registerapplicationrestart).
- Files: an unpackaged or full-trust packaged app reopens by path.
  `FutureAccessList` (up to 1000 items, learn.microsoft.com/uwp/api/
  windows.storage.accesscache.storageitemaccesslist) matters only to an
  AppContainer app, which no kaya lane builds.

### §1.5 Linux (GTK)

- X11's session management (XSMP) did not carry over to Wayland. The
  `xdg-session-management` protocol, which lets a compositor put a client's
  windows back where they were, has been merged into wayland-protocols after
  six years; KWin implements it and GNOME's was still pending at GNOME 50
  (itsfoss.com/news/wayland-session-management; KDE forum, "Session management
  with Qt"). GTK's merge requests add `gtk_application_set_session_id` and
  per-window ids (gitlab.gnome.org/GNOME/gtk/-/merge_requests/7370, 7682) and
  an application-level save and restore through a portal.
- MEASURED 2026-11-17 on the lane's own image (`docker run --rm kaya-linux`,
  GTK 4.24.0, Debian forky): libgtk-4 exports none of
  `gtk_application_save`, `gtk_restore_reason_get_type`,
  `gtk_window_set_session_id`, `gtk_application_set_session_id`, and the
  installed `Gtk-4.0.gir` names neither `restore-state` nor `support-save`.
  The gtk4-rs 0.11.4 crate in the tree DOES bind them under its `v4_24`
  feature (`Application::save`, `support-save`, `autosave-interval`, the
  `restore-state` and `restore-window` signals, `RestoreReason` with
  PRISTINE, LAUNCH, RECOVER, RESTORE): it was generated from a pre-release
  gir, and the API moved to a later GTK (reported as 4.26). So GTK gives kaya
  nothing to build on today; kaya does its own on GTK, and the `RestoreReason`
  vocabulary is worth borrowing (SR6).
- Files: a path. Under Flatpak a picked file is a document-portal path
  (`/run/user/<uid>/doc/<id>/<name>`) the portal's document store keeps across
  restarts; no kaya lane builds a Flatpak, so this is a note, not a ruling.

### §1.6 The cross-platform toolkits

- **Flutter**: `RestorationMixin` stores `RestorableProperty` values in a
  bucket named by the widget's `restorationId`; "must be unique in the
  surrounding RestorationScope", and a null id turns restoration off for that
  widget (api.flutter.dev/flutter/widgets/RestorationMixin-mixin.html). Data
  is pushed to the platform "at the end of a frame in which the data ... has
  changed" because the platform thread cannot block to ask for it, and "Some
  platforms restrict the size of the restoration data"
  (.../services/RestorationManager-class.html). It rides Android's Bundle and
  iOS's restoration; Flutter desktop has none.
- **Qt**: no automatic restoration; `QWidget::saveGeometry`,
  `QMainWindow::saveState` (toolbars and docks) as blobs the app writes to
  `QSettings` itself, and `QSessionManager` for X11 sessions. Everything
  explicit.
- **Avalonia**: nothing built in; apps save their own.
- **Compose Multiplatform**: `rememberSaveable` compiles on desktop but
  "nothing writes it to disk on desktop, so a relaunch starts fresh"
  (docs/probes/roadmap-framework-parity-2026-09-05.md, row B8).

### §1.7 What the survey says, in one paragraph

Every toolkit that restores automatically restores PRESENTATION state (scroll,
caret, a view's own text) keyed by an AUTHORED id (Android's `android:id`,
UIKit's `restorationIdentifier`, Flutter's `restorationId`) or by tree
position (Compose), and skips a widget with no identity. Every one makes the
app restore its MODEL explicitly (SceneStorage, rememberSaveable with a
custom value, SavedStateHandle, NSUserActivity). Every mobile platform ties
the LIFETIME of restored state to a user rule: a deliberate dismissal (swipe
from Recents, force quit from the switcher, closing the window on macOS)
discards it. And every one keeps the data small and tells the app not to put
secrets in it. The desktops without a platform mechanism (GTK, Windows) have
apps that do it themselves.

## §2. What kaya has today, and what restoration must fit

- **The preferences store** (DESIGN.md, App data and preferences): typed
  string, i64, f64 and bool, durable when the set returns, reserved `kaya.`
  keys, `UserDefaults`, `SharedPreferences` and kaya's keyfile. It is
  permanent: it survives every kind of quit, and on Android Auto Backup
  restores it onto a new device. That lifetime is right for settings and
  wrong for a session (SR3).
- **The harness's persistence doors**: `relaunch launch` starts the same
  artifact the way a user would and `expect_pref` reads the platform's own
  store; under the harness both stores are scratch, emptied at a scene's
  first act and kept by the act a relaunch marker adopts
  (tools/scenes/taskspersist.steps). `expect_window_size`,
  `expect_scrolled_to`, `expect_selection`, `expect_section`,
  `expect_documents` already read the observables restoration moves.
- **Identity**: `a11y_id` is spec prop 12, lowered to
  `accessibilityIdentifier`, `Modifier.testTag`, the GTK widget name and
  WinUI's `AutomationId`; the harness addresses `kind@id` and a stamped copy
  as `kind@id[key.path]` (docs/deferred.md, the authored-key entry). Nothing
  enforces uniqueness.
- **Scrolling**: `scroll_to_row` lands a For container's row by KEY, before or
  after the first layout (docs/scroll-to-plan.md S1 to S4). A scroll position
  can therefore be restored as a row key, which survives a list that loaded
  differently, rather than as pixels.
- **Picked handles and the safe save**: `local_path` is empty unless reopening
  the name works (the three desktops); `save(bytes)` is safe on every
  platform; Android's arm takes a persistable grant and keeps a note in
  `kaya-safesave/grants/` (docs/rich-document-plan.md §4.1).

## §3. The proposal, in brief

1. kaya restores PRESENTATION STATE automatically for every widget that has an
   `a11y_id`: scroll position and caret and selection, beside the window frame
   and the sidebar width it already remembers. The app writes no code for
   these.
2. The app restores its MODEL through a SESSION STORE: a typed key-value store
   like `prefs()`, with a session's lifetime instead of a setting's, scoped to
   the app, a window or a document, read synchronously before the first build
   and written whenever the value changes. The app then builds from its model
   as it does today, so field text, the selected tab, the open conversation
   and the open documents come back because the app put them back.
3. Whether a launch restores follows the platform's own rule (a deliberate
   dismissal discards), and the app can ask which kind of launch it is.
4. A picked file mints a DURABLE REFERENCE, a bounded text token in a
   kaya-owned envelope the app stores anywhere; redeeming it at a later launch
   yields an ordinary picked handle, or a refusal whose sentence says why.

```
             app thread                       core                    backend
 launch ─▶  read session store ◀──── session file (SR14) ──────────┐
            build from model ───── transactions ───▶ mount ───────▶ native widgets
                                    after the first build:          │
                                    restore presentation facets ───▶ scroll, caret
 running    session.set(k, v) ───▶ in-memory store ─┐               │
                                    facet reports ◀──────────────── settle (scroll end, caret)
                                    coalesced on idle ─▶ session file
```

## §4. The guards (invariant 3), each on a path a session walks into

- **A facet table in spec.rs** naming, per kind, the presentation facets kaya
  restores (§6 SR1's table; no divider row, F2);
  a new gate in the sweep, `check-restore.py`, holds every backend to saving and restoring each facet
  or calling `depth_stub` naming it, the check-universal-props shape (kinds
  read from the generated wire file). A new restorable kind without its arms
  fails the sweep naming the backend and the facet. Its watched negatives: a
  facet row cut from the table, and one backend's arm cut, each seen red.
- **The session store's walls at the floor**: an empty key, a key under
  `kaya.`, and a value past the size bound (SR14) are refused by name in the
  binding's idiom before the floor call and again at the floor, the prefs
  shape; a unit test drives each and check-sugar-surface holds the sentence
  in nine bindings. Under `restoration(false)` a set is NOT a wall: it
  succeeds into memory and nothing is written (SR7), and a unit test shows the
  file absent.
- **A restore never runs before the first build**: the core applies restored
  facets only after the transaction that mounts the widget, and a unit test
  with a fake backend shows an app's own `scroll_to_row` or `select_range` in
  its first build winning over the restored facet (SR4), and a For whose rows
  arrive in transaction two landing the restored key when it arrives (F7).
- **The session file's own sweep**: a unit test over a corrupt file, a file
  from another app id, an older format, an app restore version that moved, a
  crash-at-launch marker, a platform token naming another session id (SR6),
  and a live writer (SR14), each discarding or standing aside with its own
  sentence, every branch made to print.
- **References' why-not** (SR12): each branch forced on the lane that can
  reach it, the sentence read back by the scene; check-diagnostics holds the
  shape. A deleted file on every lane; a foreign token on every lane by a
  hand-written string, since the envelope (SR11) makes foreign decidable
  everywhere; the cap on every lane, ACROSS LAUNCHES (mint up to the cap in
  act one, relaunch, mint one more, read the cap sentence: with SR13's durable
  count this cannot pass vacuously); a revoked grant on Android through the
  guest's own `releasePersistableUriPermission` under a fault knob, stated as
  such (`pm revoke` does not touch URI grants), and by the unit test where no
  lane can revoke.
- **Secure fields**: the facet table carries no facet for `secure_field`, and
  check-restore refuses one; a unit test shows a secure field's caret and a
  `restorable(false)` subtree absent from the file (SR7).
- **The doors**: every runner names `relaunch resume` and `relaunch fresh`
  beside its existing doors in `RELAUNCH_DOOR`; check-steps' shape clause
  admits them, and a runner without them refuses the scene at launch naming
  the door (the precedent: every host refuses a scene it does not carry).
- **The Mac's own restoration stays off**: a clean-quit relaunch leg on the
  mac lane opens an aux window, quits through AppKit's terminate (not
  `_exit`), relaunches and reads that no window came back that the guest did
  not create (SR6, F5).

## §5. The build, depth then breadth

0. **Measure first** (each a step-0 probe, recorded in docs/traps.md if it
   surprises): (a) what `NSQuitAlwaysKeepsWindows` means for a fresh account;
   whether a kaya aux `WindowGroup` window is reopened by SwiftUI after a
   clean quit today (the build turns it off either way, SR6); and whether
   AppKit exposes the Option-Command-Q inversion to the app (SR6's macOS row
   says what was found);
   (b) on the Android pool, that `am kill` of a backgrounded kaya app followed
   by a launch from Recents delivers a non-null `savedInstanceState`, and that
   `am force-stop` or a task removal delivers null (the two doors of SR15);
   (c) on the iOS pool, that `simctl terminate` of a backgrounded app keeps
   the scene's restoration activity and that a crash at launch drops it;
   (d) on Android, that a persistable grant survives a `force-stop` of the
   app (it should: the grant belongs to the package, not the process), and
   the count `getPersistedUriPermissions` answers on the API 35 pool image.
1. **Core**: the session store, the session file (SR14), the launch kind
   (SR6) and the facet model, with the unit tests of §4. Rust binding.
2. **SwiftUI on the Mac**: every kaya window non-restorable (SR6), scroll and
   caret facets, the flush points, the restore after the first build; the
   `restore` scene (SR15) green in Rust on the mac lane.
3. **References on the Mac** (SR11, SR12), then the editor's first cut
   (SR17): its open tabs come back, Open Recent lists what it redeemed.
4. **Fan out**: Compose (the Bundle token and process death), iOS (the
   scene's activity), GTK and WinUI (kaya's own rule), the eight other
   bindings and the C floor, references on every platform.
5. **Consumers**: the rich document, the music player, chat (SR17).

## §6. The rulings

### SR1. What kaya restores on its own, and what the app restores

**Mechanism.** Three kinds of state are on the screen at any moment:

- (a) the app's MODEL, which the app holds and kaya sees only as signals
  derived from it;
- (b) WIDGET-OWNED values the app folds into its model as they change: the
  text in a field (`text_changed`), a checkbox (`toggled`), a slider, an
  expander, a picked date, the selected section, the active document;
- (c) PRESENTATION state that no app models: a scroll offset, the caret and
  selection inside a text view, a window's frame. No occurrence reports these
  but one: a `rich` textarea's selection, which `text_selected` reports so a
  toolbar can follow it; the app reads the report and does not model the
  caret, so it stays (c).

**Options.**

- **A. Everything explicit**, SceneStorage's shape: the app names every value
  it wants back, including scroll and caret. Simple and uniform, and every
  app has to remember the scroll, which no app does.
- **B. Everything automatic for widgets with an identity**, Android Views'
  shape: kaya saves (b) and (c), and on relaunch puts (b) back into the widget
  and REPLAYS it to the app as the ordinary occurrences (`text_changed` with
  the restored text) so the model follows. Zero app code. But a replayed
  occurrence is a user act nobody made: the editor's `text_changed` marks the
  document dirty, a search field's runs a network query, and the order
  against the app's first build is a race the app cannot see. The undo plan
  refused replay for exactly this (docs/undo-plan.md D3: a programmatic write
  never echoes). And restoring (b) behind the model's back, without a replay,
  leaves the model and the screen disagreeing.
- **C. Automatic for (c), explicit for (a) and (b).** kaya restores
  presentation state on its own; the app restores what it models through the
  session store (SR3) and builds from it, so (b) comes back through the
  ordinary build: the app restores the draft into its model and the field's
  `text` prop carries it, the app restores the section and selects it.

**Recommendation: C.** It is the only option that keeps the model the single
source (the no-widget-mirror doctrine) and never invents a user act, and it is
the line every surveyed toolkit draws in practice (§1.7). The cost is one
store call per modelled value, which SR3's sugar makes one line. The facet
table (§4, spec.rs) for the first build:

| kind | facet restored | form |
|---|---|---|
| scroll, and a For's container | position | the top row's key and the offset into it for a For; points for a plain scroll |
| textarea, entry, search, number_field | caret and selection | UTF-8 offsets, clamped to the text the app restored |
| textarea | its own scroll | as a scroll |
| a window with a sidebar | its width | unchanged: P8's sidebar memory, `kaya.window.<id>.sidebar`, permanent |
| window | frame | unchanged: window memory, `kaya.window.<id>.frame`, permanent |
| secure_field | nothing, ever | SR7 |

Selected tabs, sections, documents and navigation stacks are (b): the app
restores them (SR9). The window frame and the sidebar width keep their own
permanent lifetime, because a desktop app opens at its last frame and its
last divider even after a deliberate quit (AppKit's frame autosave does the
same); one store per value, so the session file carries neither (F2).

### SR2. What identifies a widget across launches

**Mechanism.** Widget ids are guest-allocated counters (DESIGN.md, Core object
model), so the same widget gets a different id whenever the build order
changes. Restoration needs a name that means "this list" in both processes.

**Options.** A. tree position (Compose's default key): free, and any update
that adds a row above the list silently moves its scroll onto another widget.
B. `a11y_id`, plus the key path for a stamped copy (the harness's
`kind@id[key.path]`). C. a new `restore_id` prop.

**Recommendation: B.** The `a11y_id` is already the authored, stable name the
platforms and the harness use, so one name serves all three. A widget without
one is not restored (Android's and Flutter's rule). Two live widgets sharing
an id in one window are both left unrestored, and the core prints once,
naming the id and both kinds; a saved facet whose id now names a different
kind is dropped. A stamped copy is restored by its row key, so a list that
loaded differently restores the rows it still holds.

### SR3. The app's own values: the session store

**Mechanism.** The app needs a place to put "the open conversation is 42" so
that the next process can read it before building. Three shapes exist: a SAVE
HOOK kaya calls at save time (Android's `onSaveInstanceState`, AppKit's
`encodeRestorableState`), a KEYED STORE the app writes whenever a value
changes (SceneStorage, `SavedStateHandle`, Flutter's push at the end of a
frame), or a SIGNAL MARKED RESTORABLE whose value kaya keeps.

**Options.**

- **A. A save hook.** The platforms ask on their own main thread with a
  deadline; kaya's app thread is a different thread, so every save becomes a
  round trip into the guest inside a lifecycle callback, and a busy guest
  loses the save. Flutter pushes for this exact reason.
- **B. A keyed store, written through.** `session().set_string("draft", s)`
  whenever the value changes; kaya holds it in memory and flushes it at the
  save points (SR5). Read synchronously, with a default, before the first
  build.
- **C. A restorable signal.** Signals are core-held, so kaya could keep one's
  value. But signals carry DERIVED values (a formatted label), not the model
  values they came from, and the app would still have to read the restored
  value back into its model.
- **D. The preferences store.** Already built, same types. But a preference
  is permanent: it survives a deliberate dismissal (which must discard a
  session, SR6), Android's Auto Backup carries it to a new device (a session
  restored onto another phone is wrong), and it has no window or document
  scope.

**Recommendation: B**, as `prefs()`'s twin: exactly prefs' four types
(string, i64, f64, bool) and nothing else; a durable reference (SR11) is a
string, and there are no bytes (a large or binary value goes to the app's
data directory with its key in the scope, SR17), a get that takes a
default and answers it when the key is absent or holds another type, a set
that cannot fail but for the walls of §4, `remove`, and reserved `kaya.` keys.
Scoped three ways: the app (`session()`), a window (`window.session()`) and a
document (`document.session()`), each scope's values discarded with it (SR9).
Spellings follow prefs exactly (Haskell's prefixed record fields, OCaml's
record of closures). Sweep: DO in Rust, Python, Go, C#, Java, Swift, OCaml,
Haskell and JS, and the C floor (`kaya_session_get_*`, `kaya_session_set_*`,
with a scope id); no language lacks a key-value read. The sugar tier
(invariant 5) adds one helper per binding that reads the value and registers
the write in one line, `let draft = session.string("draft", "")` returning the
restored value, with the app's model writing back through the same handle.

### SR4. When kaya's restored state and the app's build disagree

**Mechanism.** The app builds its first tree from its model; kaya then has a
saved scroll position for a list whose rows may have loaded differently, and
a caret for a text the app may not have restored.

**Options.** A. kaya's saved state wins. B. The app's build wins, and kaya
fills only what the build left at its default. C. kaya asks the app per
value.

**Recommendation: B**, window memory's rule turned around for state the app
does command: kaya applies a restored facet after the transaction that mounts
the widget, and only if the app's first build did not command it itself (an
app's `scroll_to_row`, `select_range` or `focus` wins). A caret past the
restored text clamps to its end. A restored selection on a rich textarea is
reported through `text_selected` like any app-made selection, so the
restored editor's format toolbar agrees with its caret (F1).

A For's restored position is HELD, not dropped, when its row key is not in
the list at mount: the hold ends at the first of (1) the key arriving (it
then lands by scroll_to's S2 rule), (2) the app's own `scroll_to_row` on that
container, (3) the user's first scroll on it, or (4) the end of the first
transaction after the mount that inserts into that collection without the
key, at which point the position is discarded and the list stays where the
app's build put it (scroll_to S3's silent no-op). An app that loads its rows
after the first build (chat, the music library) therefore gets its scroll
back on the transaction that delivers them (F7).

The app learns nothing it has to act on for (c). For its own values it reads
the store, so the conflict is in its own code, where it belongs: a restored
conversation id that no longer exists is the app's fallback to make. One read
answers the launch: `restored()` is `fresh`, `resumed` or `recovered` (SR6),
final before the first build in every binding. Where it becomes final, per
platform (F9): Android at `onCreate`, from the Bundle in hand before
`Kaya.attach`; iOS at `scene(_:willConnectTo:options:)`, from the connection
options' activity; macOS, GTK and WinUI at process start, from kaya's own
file and (on the Mac) `NSQuitAlwaysKeepsWindows`, with no AppKit restoration
to wait for (SR6). The app thread's first build waits for that point; on the
three desktops it is already past when the app thread starts, and on the
phones the core holds the first build until the platform callback has
answered.

### SR5. When state is saved

**Mechanism.** A process can die at any moment (a crash, Android's process
death, iOS terminating a suspended app), so state saved only "on quit" is
lost exactly when it matters.

**Options.** A. on every change; B. at the platform's save points only
(onStop, sceneDidEnterBackground, willTerminate); C. both: changes coalesced
in memory, written on the toolkit's idle, and flushed at the save points.

**Recommendation: C.** The store's sets and the backends' facet reports land
in core memory at once; the file is rewritten at most once per loop turn on
the toolkit's own idle, never a timer (window memory's measured rule: a 250 ms
debounce lost the scene's own resize, docs/tasks-s4-plan.md), and flushed
synchronously at the save points: Android `onStop`, iOS
`sceneDidEnterBackground`, macOS `applicationWillTerminate` and window close,
GTK and WinUI window close and `_exit`. A scroll reports when it settles, not
per frame, and a caret when it stops moving. No save point waits on the app
thread.

### SR6. Whether a launch restores: the platforms' lifetimes

**Mechanism.** Every mobile platform discards restored state on a DELIBERATE
dismissal: Android on a swipe from Recents, a force stop, a reboot or a
finish; iOS on a force quit from the switcher or a crash at launch; macOS
when "Close windows when quitting" is on or the user chose Quit and Close All
Windows. GTK and Windows have no rule at all.

**Options.** A. kaya always restores, with its own file and no platform
signal: uniform, and wrong on every platform with a rule (a user who swiped
the app away gets yesterday's half-typed text back). B. kaya follows each
platform's rule, and on GTK and WinUI always restores. C. B, with an app
switch for "always restore", the browser exception Android's own guide names.

**Recommendation: B, and C's switch as an app declaration.** The session file
stays kaya's (SR14); what the platform contributes is a yes or no.

The token is a SESSION ID, minted once when the process starts, written into
the file's header on every flush, and handed to the platform's vehicle
whenever the platform asks to save; it never changes within a process, so no
ordering between the platform's save callback and kaya's flush can make the
two disagree (F6: on a device running API 26 or 27 `onSaveInstanceState` runs
before `onStop` whatever the app targets). At launch: no token is `fresh`; a
token naming the file's session id is `resumed`; a token naming another id is
`recovered`, with a sentence naming both ids (the file is from a launch the
platform's copy never saw).

- **Android**: the Bundle carries the session id (a few bytes, so the
  Bundle's size limit never applies); a launch with a null Bundle is fresh.
- **iOS**: the scene's restoration activity carries the session id, read in
  `scene(_:willConnectTo:options:)`.
- **macOS** (F5): kaya owns the state and defeats AppKit's copy, as it already
  does for frames. Every kaya window is NON-RESTORABLE: `isRestorable = false`
  where `kayaForgetAppKitFrames` already reaches the NSWindow, or
  `.restorationBehavior(.disabled)` on macOS 15+, so neither AppKit nor
  SwiftUI reopens a window, and SR9's `restored_windows()` is the only party
  that recreates an aux window. The yes or no is read from
  `NSQuitAlwaysKeepsWindows` at launch, before kaya overrides it for AppKit:
  true keeps (the launch after a quit resumes), false or ABSENT closes (the
  launch after is fresh). Step 0 (a) measured absent as "close" on macOS
  26.6, not the Lion "keep" Chromium assumes (docs/traps.md, SwiftUI reopens
  an aux window after a quit). AppKit offers no public API that tells an
  app a quit was Option-Command-Q's inverted one, so kaya follows the
  setting and that one-quit inversion is not honored.
- **GTK and WinUI**: a clean exit leaves the token in place and a launch
  always resumes.

Everywhere, a launch that dies before its first idle marks the file, and the
next launch discards it as `recovered` (iOS's crash-at-launch rule, made
uniform), so a state that crashes the app cannot crash it twice. The
carve-out, stated the same way in every binding: "kaya restores when the
platform says this launch continues the last one; where a platform has no
such rule, every launch continues." `restore_always()` (an app declaration,
pre-mount, the brand's walls) ignores the platform's no, for apps like a
browser or an editor whose users expect their documents back after any quit.

### SR7. What is never saved, and turning it off

**Recommendation.** A `secure_field` saves nothing, not even its caret, with
no override. A `restorable(false)` universal prop excludes a subtree's facets
(a password reveal, a one-time code, a chat composer an app wants cleared).
`restoration(false)` is an app declaration that turns the whole thing off:
no file is written, the store's sets succeed into memory and are never
written (so shared code that calls `session.string("draft", "")` works in
such an app, and the next launch reads its defaults; prefs' walls refuse
only MALFORMED writes, and a set the app chose to discard is not one, F11),
and window memory keeps its own `remember_frame` switch. The file is stored unencrypted in the
app's private storage, and every binding's doc for the store says "do not
put secrets in it", SceneStorage's own warning.

### SR8. The app changes between launches

**Mechanism.** An update renames a widget's `a11y_id`, removes a page, or
changes what a stored value means.

**Options.** A. discard everything on any version change; B. keep it and
drop what no longer matches; C. B, plus a number the app bumps to discard its
own values.

**Recommendation: C.** Facets are dropped per entry when their id is gone or
names another kind (SR2), so an update loses only what it changed. The app's
values are discarded whole when the app's declared `restore_version(n)`
differs from the file's, since only the app knows when "42" stopped meaning a
conversation id. A file from another app id or an unknown format is discarded
with one line on stderr naming why.

### SR9. Windows, documents, sections and navigation

**Mechanism.** kaya cannot recreate a window or a document by itself: the app
fills every surface, and only the app knows what document 3 was.

**Recommendation.** kaya saves the SHAPE (which windows, each window's
documents in order and its active one, each window's selected section and its
navigation depth) beside each surface's own session scope, and hands the app
the shape at launch: `restored_windows()`, each with its documents and their
scopes. The app recreates each surface from its scope's values (the editor's
document scope holds the file's reference) and passes the scope back on
creation, which is how kaya knows which saved facets and frame belong to it:

- the PRIMARY window's scope is adopted without a call, since the primary has
  no creation moment (DESIGN.md, Windows: the process owns it);
- an aux window's scope is handed back through the window construct,
  `create_window(id).restore(scope)`;
- a document's through `add_document(id).restore(scope)`.

Window ids are the app's own (guest-allocated, as window memory's
`kaya.window.<id>.frame` already assumes), and the shape records them as the
app chose them: an app that allocates its window ids deterministically gets
its frames and facets back, and one whose id moved loses that window's state
with one line on stderr naming the id, as SR2 does for widgets (F10).

A scope the app does not take back is discarded at the first idle after the
first build. The selected section and the active document are the app's to
select (SR1 (b)), from the shape. Phones have one window; the shape there is
its documents and section.

### SR10. The undo stack

**Recommendation: not restored.** The core's stack holds inverse transactions
over ids that do not exist in the next process, and the native text stacks
(docs/undo-plan.md D1) cannot be serialized on three platforms. No surveyed
toolkit restores undo; a restored app starts with an empty stack, and the
restore itself is not an undoable step.

### SR11. Durable file references

**Mechanism.** §0. The question is the shape of the token and where kaya
stands between the app and the platform.

**Options.** A. kaya keeps a recent-files list itself (WinUI's
`MostRecentlyUsedList` shape); B. a picked file mints an opaque token the app
stores wherever it likes, and kaya redeems it; C. hand the app the platform's
own bytes (a bookmark blob, a URI) and let it redeem them itself.

**Recommendation: B.** `picked.reference()` answers a TEXT token, bounded at
8 KiB (so it fits a preference, a database row or the session store; a macOS
bookmark is hundreds of bytes to several KiB before base64), in an envelope
kaya owns: `kaya-ref1:<platform-tag>:<payload>:<check>`, where the tag names
the platform that minted it (`mac`, `ios`, `android`, `gtk`, `win`), the
payload is base64url of the platform's bytes, and the check is a short
checksum over the rest. "Foreign" is then decidable on every platform (a
wrong prefix, an unknown or other platform's tag, a bad checksum), a token
synced from another platform is refused by name instead of being opened as a
local path, and the `1` lets the format move later (F4). `redeem(token)`
answers an ordinary picked handle, with `open`, `save` and `local_path`
exactly as a dialog's, or a refusal (SR12); `forget(token)` releases what the
platform counts. A list of recent files is app data, not kaya's. Lowering:

| platform | minted | redeemed |
|---|---|---|
| macOS | a bookmark (`bookmarkData`), security-scoped when the process is sandboxed | `URL(resolvingBookmarkData:)`; a stale bookmark is re-minted and the new token handed back with the handle |
| iOS | a plain bookmark, made while the picked URL's scope is held | resolve, then start the scope on each open as today |
| Android | `takePersistableUriPermission` with the flags the pick granted; the URI is the payload | open through the resolver as today; `forget` releases the grant |
| GTK | the path is the payload | the path |
| WinUI | the path is the payload | the path |

The safe save keeps its rule: Android's arm releases its grant at step 5
"unless the app already held one", and a minted reference is that grant.
`forget` means the same durable thing everywhere: it removes the token from
the durable count (SR13), and on Android also releases the grant.

### SR12. A reference that no longer resolves

**Mechanism.** The file was moved off a volume, deleted, or the user revoked
access (Android's Settings, an uninstalled document provider, a cloud
provider that is offline).

**Recommendation.** `redeem` fails in the binding's error idiom with one of
these sentences, each of which a scene forces (invariant 3's why-not rule):
the file no longer exists (the path or the bookmark's file id is gone); the
grant is gone (Android has no persisted permission for the URI, or iOS
answers EPERM after the bookmark resolved); the provider does not answer (the
resolver threw for an authority with no installed provider); the token is not
a kaya reference for this platform (no `kaya-ref1:` prefix, a bad checksum,
or another platform's tag, which the sentence names); and, at mint time, the
cap (SR13). Where kaya cannot tell two of these apart (a revoked grant and a
deleted document can look the same to Android's resolver) the sentence says
so and prints what it saw. A failed redeem does not forget the token; the app
decides whether to drop it from its list.

### SR13. How many references an app may hold

**Mechanism.** Android counts persisted grants: 128 on API 26 to 29, 512 from
30, and a grant past the limit fails. The other platforms have no limit kaya
meets.

**Options.** A. a uniform cap of 128, the roster's floor; B. each platform's
own limit, answered by `reference_limit()`; C. no cap, and the 129th mint
fails on old Android only.

**Recommendation: A, counted over the DURABLE set** (F3). One semantics: an
app holds at most 128 live references on every platform, ACROSS LAUNCHES,
and the 129th mint fails naming the cap and `forget`. A per-process count
cannot deliver that: Android's limit is on persisted grants, which belong to
the package and outlive the process, so an app that mints 100 per launch
would hold 0 by a process count and 200 by Android's.

- **Android**: the OS is the ledger. The count is
  `getPersistedUriPermissions().size` at mint time; a re-mint of a URI that
  is already persisted is free (Android counts a URI once, and taking it
  again only touches its persisted time); and while a safe save holds its own
  temporary grant (safesave.rs `Grant::Taken`), that grant is not counted
  against the app, so the cap test is `size - temporary < 128`.
- **The other four**: kaya keeps a small ledger of minted tokens beside the
  safe save's own notes (`kaya-safesave/grants/` is its precedent, a
  cross-launch note of the same kind), one entry per distinct target; a
  re-mint of the same target is free, `forget` removes the entry, and the cap
  reads the ledger.

128 is far past an Open Recent menu (10 to 20) and an editor's tabs. B
(`reference_limit()`) is the honest fallback if a ledger were judged too
much, as a platform carve-out stated in every binding; C is the divergence
the invariants forbid.

### SR14. Where it lives, its format, its size

**Recommendation.** One file per app, `session.v1`, written atomically
(temporary file, fsync, rename; safesave.rs's desktop arm):

| platform | directory |
|---|---|
| macOS | `~/Library/Application Support/<id>/kaya-session/` |
| iOS | `Library/Application Support/kaya-session/`, excluded from backup (not Documents, which the Files app shows) |
| Android | `noBackupFilesDir/kaya-session/` (not Auto Backup's) |
| Linux | `$XDG_STATE_HOME/<id>/kaya-session/` (the XDG directory meant for state that survives a restart) |
| Windows | `%LOCALAPPDATA%\<id>\kaya-session\` |

Under the harness it is scratch like the other two stores. The format is
JSON: a header (format, app id, the app's restore version, the session id
(SR6), the writer's pid and start time, the first-idle mark), the shape
(SR9), the facets by scope and id, and the app's values by scope and key,
readable by a person debugging a restore. Bound: 256 KiB for the file; a
store set that would pass it is refused by name, and facets are trimmed
oldest scope first. A durable reference stored as a value counts at its full
envelope length (SR11's 8 KiB bound), so at most about 30 maximal tokens fit
one file; an app holding more keeps them in its own data. Android's Bundle
limit does not apply, since only the session id rides the Bundle.

Two processes of one app (F12): a launch that finds a file whose writer pid
is alive with the recorded start time does not resume it and writes nothing
for its whole life; it starts fresh, `restored()` answers `fresh`, and one
line on stderr names the live writer. This is the file sweep's live-writer
branch (§4).

### SR15. The scene, the doors and the reads

**Recommendation.** A new `restore` scene in every language, two acts. Act
one: type into a field the guest restores through the store, scroll a list to
a row, put the caret mid-text, select a section, open a second document,
pick a file and mint its reference. Then `relaunch resume`. Act two:
`expect_restored resumed`, `expect_text`, `expect_scrolled_to` the row,
`expect_selection` the caret, `expect_section`, `expect_documents`, and a
redeem of the reference read back by contents. A second scene,
`restorefresh`, ends act one with `relaunch fresh` and reads `expect_restored
fresh` and every default; it also forces SR12's branches.

The doors, named per runner in `RELAUNCH_DOOR`:

- `relaunch resume`: the platform's continuation. Android: home, `am kill` of
  the backgrounded package (process death), then a launch from Recents. iOS:
  background, `simctl terminate`, launch. macOS: a clean quit through
  AppKit's terminate, both acts started with `-NSQuitAlwaysKeepsWindows YES`
  in the argument domain (the user keeps windows; the mac lane's `auxquit`
  leg is its first user). GTK and WinUI: a clean close and the plain launch.
- `relaunch fresh`: the user's dismissal. Android: `am force-stop` or a task
  removal. iOS: the switcher's force quit if the driver can reach it, else a
  token-clearing knob stated as such. macOS: the same clean quit with
  `-NSQuitAlwaysKeepsWindows NO`, which is the user's own setting doing what
  it does (F5, F15). GTK and
  WinUI: kaya's own `restoration` knob for the act, since no dismissal exists
  to drive.

New verbs, in both interpreters (check-verbs): `expect_restored
<fresh|resumed|recovered>`, `expect_reference <name> <ok|missing|revoked|
foreign|cap>`. The other reads exist.

### SR16. The guards

§4, as a ruling: the facet table and check-restore; the store's walls; the
after-the-first-build order as a unit test; the file's discard branches;
the why-not branches forced on the lanes; secure fields absent; the doors
refused at launch by a runner that lacks them.

### SR17. The first consumers, and the order

- **The text editor** (Go): the open documents (each document scope holds its
  file's reference, its zoom and its line-numbers switch), the active tab,
  and an untitled tab's unsaved text in its scope (bounded by SR14; a large
  unsaved buffer goes to the app's data directory with its key in the
  scope). Automatic: each buffer's caret and scroll. Open Recent: references
  in the app's preferences, redeemed when the menu opens.
- **The rich document**: the .kdoc's reference; caret and scroll automatic.
- **The music player** (Python): the selected section, the selected album or
  playlist's key, the playing track and position, the queue's keys (app
  store); the library list's scroll automatic.
- **Chat** (Go): the open conversation and its composer draft (app store);
  the thread's scroll automatic, where follow-end decides whether the restored
  position or the end wins (follow-end's rule stands: at the end before, at
  the end after).

Order: §5. The editor goes first because it needs both halves.

### SR18. Beyond these, for the maintainer

- **iPad multi-scene and Android multi-window**: kaya has one window on the
  phones (DESIGN.md, Windows); a second scene's restoration waits for the aux
  window capability on iPad.
- **Windows' restart after an update** (`RegisterApplicationRestart`): a
  door, not restoration; deferred until an app asks to come back after an
  update, and then it reuses SR6's token.
- **GTK's session API**: when the lane's GTK exports it (§1.5), the GTK arm
  may answer SR6's yes or no from `RestoreReason` instead of always resuming;
  the semantics do not move.
- **Flatpak's document portal**: a note (§1.5); no lane builds one.

## §7. Measured, and to be measured

Measured for this pass: §1.5 (GTK 4.24.0 on the lane exports no session API),
§1.3 (`NSQuitAlwaysKeepsWindows` absent on this host). Everything else in §1
is cited. To be measured before the build relies on it: §5 step 0 (a) to (d).

## §8. What the independent review changed (2026-11-17)

An independent review (findings F1 to F15) checked the plan's citations and
code claims; the maintainer accepted every recommendation with its fold-ins.
Each fold-in sits at the ruling it changes:

- F1: a rich textarea's selection IS reported (`text_selected`); §0, SR1 (c),
  and SR4's line that a restored selection is reported the same way.
- F2: no divider facet; P8's permanent sidebar memory stands (§0, SR1's table).
- F3: SR13's cap counts the durable set, across launches; §4's cap test.
- F4: SR11's `kaya-ref1:` envelope, bounded at 8 KiB; SR12's foreign branch;
  SR14 counts it.
- F5: every kaya window non-restorable on the Mac, SR6's answer read from
  `NSQuitAlwaysKeepsWindows`, SR9 the only party that recreates aux windows;
  §5 step 0 (a) and SR15's Mac doors.
- F6: the platform token is a session id stable for the process (SR6).
- F7: a For's restored position is held until its key arrives (SR4).
- F8: the store's types are prefs' four (SR3).
- F9: where `restored()` becomes final, per platform (SR4).
- F10: the primary's scope adopted without a call, an aux window's through
  `create_window(id).restore(scope)`, window ids the app's (SR9).
- F11: under `restoration(false)` a set succeeds into memory (SR7).
- F12: the file carries its writer's pid and start time (SR14).
- F13, F14: §1.1's and §1.2's citations.
- F15: §4's guards.

## §9. What the build settled (2026-11-17 to 2026-11-18), for review

Each line is a question the rulings did not answer, the answer the build
took, and where it lives. The maintainer reviews them; none moved a
binding-level semantics.

- **macOS, SR6 measured.** With `NSQuitAlwaysKeepsWindows` absent, macOS
  26.6 closes windows at quit and restores nothing, so the Mac rule reads
  true = resumed, false or absent = fresh (the plan had "absent = keep").
  The Option-Command-Q inversion is not honoured: AppKit exposes no public
  way to read it.
- **macOS, F5.** `isRestorable = false` relaunched the app with no window
  at all, so kaya instead sets `ApplePersistenceIgnoreState` in the argument
  domain at launch (`kayaTakeRestorationFromAppKit`): SwiftUI reopened an
  aux window for an id the guest never allocated after a clean quit
  (docs/traps.md, "SwiftUI reopens an aux window after a quit"); the
  auxquit leg and the interpreter's stray-window verdict hold it. AppKit's
  frame autosave is refused for kaya's window names, since it wrote the
  app's real domain at every launch.
- **F12, the second live process.** An advisory lock on
  `kaya-session/session.lock`, held for the process's life, rather than the
  pid and start time (a pid is reused; the lock dies with its process). The
  header still records the pid. On Android, std's `File::try_lock` answers
  "not supported", so the lock is `flock(2)` there.
- **SR14, F11, the knobs.** `restoration`, `restore_version` and
  `restore_always` are keys in the app's identity manifest, not
  transaction ops: the store is read before the first build, and a
  manifest key needs no binding surface, so it is uniform in all nine by
  construction. Android's store is `no_backup` (`noBackupFilesDir`).
- **F9, iOS.** The token rides SwiftUI's `@SceneStorage("kaya.session")`,
  which is the scene's restoration activity, rather than a UIScene delegate
  of kaya's own (SwiftUI's scene delegate owns `stateRestorationActivity`).
  A store read waits for the token (5 s, printed) and never on the main
  thread; a timeout or a main-thread read is HEADLESS: fresh, and nothing is
  written, so a background launch cannot wipe the file. Measured (step 0
  (c)): background, `simctl terminate`, launch keeps the SceneStorage. On
  iOS a Go guest reads its session inside `app.Post` (the binding panics
  before Run there, naming it): Go's first Build runs on the main thread.
- **Android.** A restored activity maps every launch extra but the act's
  own pair, KAYA_SELFTEST and KAYA_SELFTEST_SCRIPT
  (`KayaEnv.fromIntent(intent, savedInstanceState)`): the platform recreates
  it with the original intent, and the Mac's act two keeps the same set. The resume door ends act one with `am kill`,
  then SIGKILL after 5 s (the low-memory killer's shape) when `am kill`
  leaves the process alive after a file pick. The reply receiver's process
  hands the headless token.
- **SR15, the fresh door.** Real on the Mac (`-NSQuitAlwaysKeepsWindows NO`)
  and on Android (a null Bundle); on iOS, GTK and WinUI, which have no
  dismissal a runner can drive, the session knob `KAYA_SESSION_TOKEN=absent`
  in act two's environment, read only in a scene run. restorefresh runs in
  Rust only: the door is the runner's, not a binding surface. On GTK and
  WinUI `relaunch resume` is the plain launch; the Windows non-Rust legs
  relaunch through a generated act-two launcher.
- **SR4, F7, facets.** Facets are scoped to the WINDOW (a section's or a
  document's widgets share it). Live widgets only; a stamped copy's facet by
  row key is not built. The caret restores on a textarea only, since
  `select_range` is a textarea surface; entry, search and number-field
  carets wait for it. F7's "the user's first scroll ends the hold" is not
  built: while a container's restore is pending the core ignores its row
  reports, because no backend can yet tell the first layout's report from a
  user's scroll above kaya's floors (SwiftUI's `onScrollPhaseChange` is
  macOS 15 / iOS 18); the hold ends at the key's arrival, the app's own
  `scroll_to_row`, or a later batch that grows the collection without it.
  A plain scroll's points, a textarea's own scroll and `restorable(false)`
  are not built (each needs a new apply op or universal prop on every
  backend).
- **SR9.** `.restore(saved)` takes the saved window or document id, not an
  opaque scope object, since window ids are the app's and the scope is named
  by its id. A section and the navigation depth are recorded and handed
  back; the app selects or re-pushes them.
- **SR11 to SR13, references.** The Mac payload is a plain NSURL bookmark,
  not security-scoped (kaya's Mac apps are unsandboxed). A lane scene reads
  each refusal from a label the guest writes, rather than a new
  `expect_reference` verb, since the redeem happens in the guest. The
  across-launches cap is held by the ledger's unit test, which re-reads the
  file as a later launch would; a lane leg would need 128 distinct picks.
- **Spellings.** Python and JS spell the app scope `app_session()`, since
  `session` is their media session (docs/media-plan.md §5); Java spells the
  handle `SessionHandle`; JS's error is `KayaReferenceError`, since
  `ReferenceError` shadows the builtin. Rust and the others keep
  `session()`.
- **SR17, consumers.** The rich document's consumer is the editor's rich
  tab (the only app that opens a .kdoc). A file-backed tab's unsaved edits
  are kept too, not only an untitled tab's: a resume that dropped them would
  lose typing. Open Recent dedupes by display name and only grows (no menu
  removal exists). A restored chat thread commands no scroll, so kaya's
  facet places it. The music player keeps, besides what SR17 names, the
  queue's track records (so a restored queue can play a track no page has
  loaded) and its shuffle and repeat, and takes the phones' section from
  `restored_windows()` rather than its own store; the Liked Songs and
  Search destinations come back as pages. On the phones music_restore does
  not assert the position, since the scrubber sits in the full player's
  sheet.
- **Recorder.** The session load line names every facet the file brought,
  each changed facet report and each restored caret prints under a scene
  run, and `act one emptied <dir>` prints at each act one.
- **The real stores on the Mac: RULED A (the maintainer, 2026-11-18).** The
  chat leg's real NSOpenPanel writes `NSOSPLastRootDirectory` into the app's
  real preferences domain out of process (docs/traps.md, "The open panel's
  last directory in the real domain"). Every bundle the mac lane builds now
  carries the scratch identity `<id>.lane` (tools/lib/packaging/mac.py
  `LANE_SUFFIX`, passed by the lane's three bundle calls), so AppKit's keys,
  saved state and the notification grant land in that domain; the real-store
  wall treats it as scratch, and `leg_argv` refuses a bundled leg under a
  real identity, naming the leg. Only tools/package.py's shipped bundle keeps
  the declared id; no leg is about the shipped identity (kaya's own stores and
  the link scheme follow the manifest, not the bundle). Guards: check-app-
  identity's C17 (a lane bundle call without the flag, leg_argv without the
  refusal); chat-go with the real identity put back refused by run-leg naming
  the leg, and the gate sweep refused it first. The scratch suites
  `<id>.selftest.<hash>` and the unbundled legs' per-executable domains are
  docs/deferred.md's entry.
