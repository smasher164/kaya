# Task manager S4 — what survives a relaunch (rulings TAKEN 2026-09-09)

The tasks plan's S4 row: "tasks survive a relaunch; settings persist — app
data directory, the preferences store, window memory". S2b left the
appearance choice living for the process with the note that S4 is where it
survives; S9 built the thing that makes any of this testable, the harness's
second act. The rulings below were proposed 2026-09-09 and TAKEN the same day ("go for
it", after the data store moved to SQLite on the maintainer's question and
the platform-store question was answered in plain words); §4 records the
mechanics decided for the build.

## §0 — What this is, in one paragraph

Three things a user expects and the app cannot do today: its data is
there when it comes back, its settings hold, and on a desktop the window
opens where it was left. Each is a different mechanism on every platform
and none of them belongs in a guest, so kaya gives the app one place to
write its own document, one small typed store for settings, and remembers
the window itself. The proof is S9's second act: write, relaunch, read
back through the platform's own record.

## §1 — Rulings proposed

- **P1. Two stores, drawn the way the tasks plan drew the line.** The app
  owns its model, so its DATA is the app's own document in a directory
  kaya answers: `app_data_dir()` is the platform's per-app writable place
  (Application Support/<id> on macOS, the Documents directory on iOS, the
  files directory on Android — handed in at attach the way the state root
  is — `$XDG_DATA_HOME/<id>` on Linux, `%LOCALAPPDATA%\<id>` on Windows),
  and the guest keeps its data there THE STANDARD WAY: a SQLite database,
  through the language's own binding (rusqlite, Python's sqlite3,
  database/sql, Microsoft.Data.Sqlite, sqlite-jdbc, GRDB, the OCaml and
  Haskell bindings, better-sqlite3) — the maintainer's question, 2026-09-09:
  SQLite is what every platform ships and every cross-platform framework
  reaches for, and a kaya database API in nine bindings would be a worse SQL
  than any of them, so kaya answers the directory and nothing else.
  SETTINGS are small and typed, so they go in kaya's PREFERENCES STORE: a
  key-value record of strings, integers, floats and booleans under the
  app's id, one API in nine bindings. RECOMMEND. (The alternative, one
  store for everything, would make kaya own a document format it has no
  business in.)
- **P2. The preferences store is the platform's own where the platform
  has one.** Apple's UserDefaults and Android's SharedPreferences are what
  users, backups and platform tools expect a settings store to be; Linux
  and Windows have no single canonical one, so there it is a keyfile
  (`$XDG_CONFIG_HOME/<id>/preferences` and `%LOCALAPPDATA%\<id>\preferences`,
  the GLib key-file shape, which GTK apps already read). One API, five
  backings, and the harness's read-back goes through the PLATFORM's store
  (`defaults read`, SharedPreferences through the app, the keyfile's own
  bytes), never kaya's memory of what it wrote — S2b R4's rule.
  RECOMMEND. The alternative is one kaya keyfile everywhere, uniform and
  simpler, but a Mac app whose settings are not in `defaults` and an
  Android app whose settings are not backed up read as broken to their
  platforms.
- **P3. The API is a pull, spelled once.** `prefs().get_bool(key,
  default)`, `get_string`, `get_int`, `get_float`, the four `set_*` and
  `remove`, on a `Prefs` handle the app takes at startup — not signals,
  since a setting is read when the app builds and written when the user
  changes it, and binding a pref to a signal is a two-line sugar later if
  a scene wants it. Writes are synchronous and durable before the call
  returns (a crash a millisecond later loses nothing), reads are cheap.
  Each binding spells the handle in its own idiom; the sweep names all
  nine. RECOMMEND.
- **P4. Window memory is kaya's, automatic, opt-out.** A desktop window's
  size and position are saved under a reserved key in the preferences
  store when they change (debounced) and restored at creation, keyed by
  the window's id, with a `remember_frame(false)` window prop for a window
  that should not; the phones have no window frame and the prop is inert
  there. macOS already offers frame autosave and the arm may use it as the
  backing, but the OBSERVATION is one rule everywhere: the window opens at
  the frame the previous process left. RECOMMEND. (The alternative, a
  prop the app must set, is one more thing every app forgets.)
- **P5. The second act needs a door that is not a notification.** S9's
  `relaunch` pushes the platform's notification door. S4's scenes relaunch
  the app with nothing pending, so the verb takes an argument: `relaunch`
  stays the notification door and `relaunch launch` means "start the app
  again the way a user would" — the runner launches the same bundle,
  package, desktop entry or exe with no marker beyond the act-two one.
  check-steps' shape clause admits the one argument; every runner names
  its plain door beside its notification door in `RELAUNCH_DOOR`.
  RECOMMEND.
- **P6. Recording mode films act two, and the five bindings' proofs ride
  along.** validate-mac's `run_recorded` returns at the first process's
  exit today, so a filmed two-act scene records act one alone (the S9
  ledger); it waits for the join now, and the relaunched process gets its
  tile. And C#, Java, Swift, OCaml and Haskell gain the runnable
  three-case proof of `on_notification_activation`'s dispatch order beside
  their exercisers, since S4's binding sweep is in those files anyway.
  RECOMMEND.
- **P7. The tasks app.** The model becomes a SQLite database under
  `app_data_dir()` through rusqlite with the engine compiled in (so every
  lane and both phones carry the same one), one table for tasks with the
  fields the seed has and one for projects, written on every mutation after
  the transaction commits and read at startup before the seed — the seed
  only when the database does not exist yet; the three settings and the appearance
  choice go in the preferences store and are read at startup; the primary
  window's frame is remembered by P4. The scene: add a task, change a
  setting, choose Dark, resize the window, `relaunch launch`, then read
  the task back in Inbox, the setting from the settings label,
  `expect_appearance "dark"`, and `expect_window_size` on the desktops.

## §2 — Unknowns to measure before the arms are called done

1. Whether a write that returned is on disk when the process is killed a
   moment later, per backing (UserDefaults synchronizes lazily; the
   keyfile arm must fsync; SharedPreferences `commit` versus `apply`).
2. What each platform's store read-back looks like from the harness
   (`defaults read <id>` on the mac, the simulator's container plist on
   iOS, `run-as` on Android, the keyfile bytes on Linux and Windows).
3. Whether restoring a frame across a display change (a smaller screen,
   a display that left) keeps the window on screen — the platform's own
   rule where it has one, kaya's clamp where it does not.
4. The Android files directory at attach versus a `Context` read later:
   the state root is handed in already; the data directory rides the same
   parameter or a second one.
5. The compiled-in SQLite (rusqlite's `bundled`) under the Windows
   cross-build (cargo-xwin, a C compile through clang-cl) and the Android
   NDK build, and its cost to the linux container's core build; the
   fallback is the platform's own libsqlite3 where it exists.
   ANSWERED 2026-09-09 on all five lanes, no fallback needed: the linux
   image builds it with its own clang in 9s cold with no Dockerfile change
   (examples/tasks +2.37 MiB, 289 sqlite3_* symbols in the example and
   ZERO in libkaya.so — the dev-dependency keeps the engine out of the
   shipped library); cargo-ndk exports the CC the cc crate reads, 5s cold,
   librusthost.so +5.1% (libkaya.so unchanged); cargo-xwin needed ONE
   shell addition, `llvm-lib` (flake.nix's xwinLib — the shell shipped the
   compiler and none of LLVM's binutils because nothing C had ever joined
   the target), 14.5s cold, tasks.exe +1.77 MiB; the iOS simulator target
   needed the C compile routed through `xcrun -sdk iphonesimulator -f
   clang` because nix's cc-wrapper injects `-mmacos-version-min` beside
   `-mios-simulator-version-min` (docs/traps.md); the mac needed nothing.

## §3 — Build order

1. The core: `app_data_dir()` and the preferences store with the five
   backings, the wire records for get/set (or a floor call, since a pref
   read is synchronous — decide with the unknowns), the Rust sugar, the
   harness's `expect_pref` read-back per backend and `relaunch launch`.
2. The bindings sweep (nine), the window-memory arms (four desktops), the
   recording-mode join, the five bindings' dispatch proofs.
3. The tasks app's document, settings and frame; the scene's second act
   with the plain door on all five lanes; the matrix; a review page
   showing each platform's app after a relaunch with its data, setting,
   appearance and frame intact.

## §4 — Mechanics decided for the build (2026-09-09)

- **The store is a C-floor API, no wire change.** A pref read is
  synchronous and wanted at build time, so `kaya_pref_get_*` /
  `kaya_pref_set_*` / `kaya_pref_remove` and `kaya_app_data_dir` are floor
  functions every binding wraps; the spec hash does not move. The BACKING is
  per platform behind them: the core's own keyfile writer on Linux and
  Windows (fsync'd, the GLib key-file shape); on macOS and iOS the core reaches
  `NSUserDefaults(suiteName:)` ITSELF through objc2-foundation, not through
  a host entry the Swift side answers (amended in the build: act one's clear
  runs inside `act2::arm` before the app thread and long before the
  interpreter dylib is loaded, and a hosted guest builds its whole scene
  before it calls `kaya_run` — so a bare python or java process round-trips
  with no host anywhere; the harness read-back is still Swift's own
  re-opened suite); on Android the core reaches
  `SharedPreferences` through JNI on the context it already remembers (or a
  native pair the Kotlin side registers, the agent's call, stated). Values
  are string, i64, f64, bool; a missing key answers the caller's default.
- **`app_data_dir()`** answers Application Support/<id> (macOS), the
  Documents directory (iOS), the files directory handed in at attach
  (Android — the state root already is it), `$XDG_DATA_HOME/<id>` (Linux),
  `%LOCALAPPDATA%\<id>` (Windows, packaged and not: LocalAppData is not
  redirected here, measured); created on first ask.
- **Under KAYA_SELFTEST the stores are scratch and act one clears them.**
  The app's real defaults domain and data must not be polluted by lanes, so
  under the harness the pref domain is `<id>.selftest` (the UserDefaults
  suite, the SharedPreferences file name, the keyfile name) and the data
  directory is `<state>/selftest/<id>/data`; a process that starts act one
  (KAYA_SELFTEST set, no marker) EMPTIES both, and a process adopted from a
  marker keeps them — which is what makes a relaunch scene measure
  persistence. AND THE SCRATCH IS PER LEG (found by the first S4 matrix,
  docs/traps.md 2026-09-09): every guest on a lane declares one identity,
  so a pooled lane's legs would share one scratch tree and any act one
  would empty it under another leg's open database — a runner gives every
  leg its own state home (`XDG_STATE_HOME`, honored by act2.rs on the
  three desktops; the linux leg scripts already did, the phones isolate
  per device), the data dir and the marker live under it, and the
  preference domain carries a tag derived from it (`<id>.selftest.<fnv64>`)
  because a UserDefaults suite has no directory to live under; a plain
  relaunch inherits the leg's environment and lands in the same suite.
  The harness's `expect_pref <key> "<value>"` reads back
  through the PLATFORM's store for that domain (the suite re-opened on
  Apple, the preferences file re-read on Android, the keyfile's bytes on
  the desktops), never the core's memory.
- **`relaunch launch` is the plain door.** The runner starts the same
  artifact the way a user would — the bundle again on macOS and iOS,
  `am start` with no extras on Android, the desktop entry through
  `gio launch` (or the leg's launcher when the lane has no gio) on Linux,
  the exe or the packaged app on Windows — with no notification pending;
  every runner names it in `RELAUNCH_DOOR` beside the notification door,
  and check-steps' shape clause admits the one argument. ONE `relaunch` per
  scene stays the rule, so S4 gets its own scene, `taskspersist.steps`,
  running the tasks guest (rusthost maps the scene name to tasks::app).
- **Window memory** saves the primary window's frame under the reserved
  pref keys `kaya.window.<id>.frame` on the four desktops' own resize and
  move signals, COALESCED ONTO THE TOOLKIT'S IDLE and deduplicated against
  what the store holds — never a timer: a 250ms debounce was built on GTK
  and watched LOSE the scene's own resize, since the declaration's set-size
  arms the timer, the resize lands inside its window, and the process
  leaves through `_exit` with the trailing write unrun (measured
  2026-09-09; a real app has the same hole on a crash). One write per
  window per loop turn, none when the frame did not move; a durable
  keyfile write is 0.7ms median, 2ms p95. AND THE IDLE MUST BE THE HOPS'
  OWN QUEUE: WinUI's Low-priority enqueue lost the same resize, because
  the relaunch step's Normal-priority hop ran first and left — the write
  is enqueued at the ordinary priority, FIFO behind the resize and ahead of
  the step that exits (measured on the VM 2026-09-09); on the mac that is
  DispatchQueue.main.async, never a run-loop idle observer.
  AND MEMORY BEATS THE DECLARATION BY VALUE, NOT BY ORDER (the core agent's
  rule, taken on all three desktops 2026-09-09): a window's create always
  precedes its own prop applies, but a launch build may span two
  transactions, so a drain boundary cannot tell the declaration from the
  app's first runtime resize. One function decides per window: no memory
  means every write applies; the first value a restored window is asked
  for is its declaration and is refused; the same value again is the
  same declaration; the first DIFFERENT value is the app resizing itself,
  applies, and ends the memory on both axes. Unit tests drive all six
  cases on GTK and WinUI (and the mac's), since no scene can see it. GTK4 has no window position at
  all, so it writes `- - <w> <h>` and restores the size alone. It restores
  at creation before the first frame, clamped onto a screen that still has
  it; `remember_frame(false)` is
  the opt-out window prop, inert on the phones; the scene asserts the size
  with `expect_window_size` after `relaunch launch`.
- **The tasks app** opens `app_data_dir()/tasks.sqlite` through rusqlite
  (`bundled`), one table for tasks with the seed's fields and one for
  projects, seeds only when the file is new, writes on every mutation after
  the transaction commits, and reads at startup before its first build;
  the three settings and the appearance choice are prefs read at startup.
- **The scene** (`taskspersist.steps`): add a task through quick-add, set
  a setting (Week starts Sunday), choose Dark, resize the primary window,
  `relaunch launch`, then read the task in Inbox, the settings label,
  `expect_appearance "dark"`, `expect_pref week_start "1"` (the platform's
  own store), and `expect_window_size` on the desktops. The phone cut
  ends before the resize.
