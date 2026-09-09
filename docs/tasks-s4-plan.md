# Task manager S4 — what survives a relaunch (design pass, 2026-09-09)

The tasks plan's S4 row: "tasks survive a relaunch; settings persist — app
data directory, the preferences store, window memory". S2b left the
appearance choice living for the process with the note that S4 is where it
survives; S9 built the thing that makes any of this testable, the harness's
second act. This is the design pass; nothing here is built. Rulings are
marked RECOMMEND for the maintainer.

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
  and the guest reads and writes what it likes there in its own format.
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
- **P7. The tasks app.** The model becomes the app's document under
  `app_data_dir()` in a line-oriented text the guest owns (one task per
  line, the fields the seed already has), written on every mutation after
  the transaction commits and read at startup before the seed — the seed
  only when no document exists; the three settings and the appearance
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
