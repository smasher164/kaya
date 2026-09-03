# The kaya mobile host contract

**Arm:** CONTRACT. Repo `/Users/akhilindurti/Projects/kaya` @ `11bde48`.
**Scope:** exactly what a guest must be and do to run under kaya on iOS and
Android, stated so a candidate-language arm can test against it.
**Evidence key:** `[M]` measured here, `[D]` documented (repo file:line or a
vendor URL), `[A]` assumed — assumptions are flagged and never a basis for a
recommendation.

---

## 1. iOS: how a guest reaches the screen today

### 1.1 The one backend

There is one iOS backend and it is the SwiftUI interpreter, compiled to a
dylib and embedded in the app bundle. `crates/kaya/src/lib.rs:135-150 (gone)` — for
`macos`/`ios`, `kaya::run` spawns the app thread and then calls
`swiftui_host::run()`, which never returns. `tools/ios/run-sim.py:1600-1604`
says it directly: "The one iOS backend is the SwiftUI interpreter: every
bundle embeds its dylib, **whatever language the guest is written in**." `[D]`

### 1.2 What is built, per flavor

| Flavor | Guest artifact | How kaya is linked | Backend |
|---|---|---|---|
| Rust (`rust-swiftui`) | full Mach-O executable from `cargo build --target aarch64-apple-ios-sim --example <scene>` (`tools/ios/run-sim.py:1886-1889`) | kaya is an **rlib inside the executable** (Rust static link) | `libkaya_swiftui.dylib` copied into bundle root (`:1384`) |
| Swift | full Mach-O executable from `xcrun -sdk iphonesimulator swiftc … -L target/… -lkaya` (`tools/ios/run-sim.py:1686-1704`) | kaya is **`libkaya.a`, the staticlib crate-type** (`crates/kaya/Cargo.toml:9-12`) | same dylib, same place (`:1366`) |

The crate declares `crate-type = ["rlib", "cdylib", "staticlib"]` with the
comment "staticlib is for iOS, where app bundles prefer static linking and the
Swift validation leg links libkaya.a directly" (`crates/kaya/Cargo.toml:10-12`). `[D]`

> #### ⚠ MEASURED CORRECTION: the Swift leg does **not** link `libkaya.a`
>
> `otool -L target/ios-bundles/milestone2swift.app/milestone2swift` names
> `/Users/akhilindurti/Projects/kaya/target/aarch64-apple-ios-sim/debug/deps/libkaya.dylib`
> — an **absolute build-machine path to a dylib outside the bundle**. The
> `.app` directory contains only `Info.plist`, `libkaya_swiftui.dylib` and the
> executable; there is no `libkaya.dylib` in it. The Rust bundle by contrast
> links only `/usr/lib/libSystem.B.dylib` — kaya really is static inside it. `[M]`
>
> Cause: `cargo build --lib` emits all three crate types side by side
> (`libkaya.a` 34.4 MB, `libkaya.dylib` 3.1 MB, `libkaya.rlib`, `[M]`), and
> `-L "$TARGET_DIR" -lkaya` (`run-sim.py:1343`) makes ld64 prefer the dylib.
> Confirmed with a standalone probe under the pinned Xcode 26.6.0: a directory
> holding both `libprobe.a` and `libprobe.dylib`, linked with `-lprobe`,
> produces a binary whose load command is `libprobe.dylib`. `[M]`
>
> Why the legs still pass: the Simulator shares the host filesystem, so dyld
> resolves that absolute path. **A device build cannot** — nothing puts
> `libkaya.dylib` in the bundle and nothing rewrites the install name.
>
> **Contract consequence:** a candidate language must copy the **Rust** leg's
> link recipe (kaya statically inside the executable), not the Swift leg's.
> Following the Swift leg reproduces a bundle that is not self-contained, and
> the simulator will not tell you.

### 1.3 Bundle layout

`make_bundle` (`tools/ios/run-sim.py:219-258`) builds the whole `.app` by hand —
no Xcode project anywhere in the lane:

```
target/ios-bundles/<name>.app/
  Info.plist          # tools/ios/Info.plist.in with @EXECUTABLE@/@BUNDLE_ID@/@NAME@ substituted
  <name>              # the guest executable, cp'd in (run-sim.py:101)
  libkaya_swiftui.dylib   # cp'd to the BUNDLE ROOT, not Frameworks/ (run-sim.py:1366, :1384)
```

The dylib is **not** linked at build time and there is no `@rpath` /
`install_name` fixing: it is `dlopen`ed at runtime.

### 1.4 How the dylib gets loaded

`crates/kaya/src/swiftui_host.rs:233-247`:

- path = `$KAYA_SWIFTUI_LIB`, defaulting to `"libkaya_swiftui.dylib"` (`:234-235`)
- `dlopen(path, RTLD_NOW)` (`:237`), asserting with the sentence "could not
  load the SwiftUI backend from …" on failure
- `dlsym(handle, "kaya_swiftui_run")` (`:243`) — the required export
- `dlsym(handle, "kaya_swiftui_open_picked")` (`:260`) — optional; only a guest
  that opens a picked file meets its absence (`:256-259`)
- builds a `KayaHostApi` vtable of **25** function pointers into `capi::*`
  (`:265-291`; 25 declared fields, 25 initializers `[M]`) and calls `run(&api)`
  (`:292-294`).

The vtable exists **because symbol-space coupling is unreliable**: hosts may
carry kaya statically (a Rust executable) or `RTLD_LOCAL` (ctypes)
(`swiftui_host.rs:5-11`). This is the single most important fact for a new
language: *the interpreter never resolves kaya symbols by name; it is handed
pointers.* `[D]`

Confirmed on the built artifact: `otool -L
target/ios-bundles/milestone2swift.app/libkaya_swiftui.dylib` lists UIKit,
SwiftUI, QuartzCore, CoreGraphics and the Swift runtime — **and no libkaya at
all**. `[M]` The interpreter is therefore guest-agnostic by construction: it
links nothing of kaya's and gets everything through the vtable. Its own
`LC_ID_DYLIB` is the absolute build path
`/Users/…/target/ios-bundles/libkaya_swiftui_ios.dylib`, which never matters
because it is only ever `dlopen`ed by explicit path. `[M]`

The lane sets the path explicitly per launch:
`SIMCTL_CHILD_KAYA_SWIFTUI_LIB="$container/libkaya_swiftui.dylib"`
(`tools/ios/run-sim.py:1333`), where `$container` is
`xcrun simctl get_app_container <udid> <bundle_id> app` (`:1021`).

### 1.5 Entry point and threads

- **Rust guest:** `fn main()` → `kaya::run(app)` (`guests/rust/milestone2.rs:171-172 (gone)`).
  `kaya::run` spawns a thread named `kaya-app` running `app_main(ctx)`
  (`lib.rs:144-147`), installs the presentation sink (`:148`), then
  `std::process::exit(swiftui_host::run())` on the calling (main) thread (`:149`).
- **Swift guest:** the guest's top-level code is `main.swift`
  (`run-sim.py:1310-1312, 1332`); it ends with `app.run()`
  (`guests/swift/milestone2.swift:108 (gone)`). `KayaApp.run()`
  (`bindings/swift/KayaApp.swift:1521-1535`) checks `kaya_spec_hash() ==
  kayaSpecHash`, starts a `Thread { self.dispatchLoop() }`, and calls
  `exit(kaya_run())` on the main thread.
- `kaya_run` on Apple is just `swiftui_host::run()` (`capi.rs:800-807`).

So: **the guest owns `main`, and the main thread is surrendered to
`kaya_run()`/`swiftui_host::run()`, which never returns.** The guest's own
logic runs on a second thread it (or the binding) starts. `[D]`

### 1.6 What the runner installs and launches

`run_swiftui_on` (`tools/ios/run-sim.py:1280-1400`):

1. `xcrun simctl install "$udid" "$app"` (`:1019`)
2. resolve the app container (`:1021`)
3. build the script text from `tools/scenes/<scene>.steps`, stripping comments
   (`:1069`), optionally cut at a verb this host cannot express (`:1024-1067`)
4. launch:
   ```
   SIMCTL_CHILD_KAYA_SELFTEST="$selftest" \
   SIMCTL_CHILD_KAYA_SELFTEST_SCRIPT="$script" \
   SIMCTL_CHILD_KAYA_SWIFTUI_LIB="$container/libkaya_swiftui.dylib" \
   timeout 120 xcrun simctl launch --console-pty "$udid" "$bundle_id"
   ```
   (`:1092-1095`)
5. verdict = `grep -q "KAYA_SELFTEST: OK"` over the captured console (`:1118`)

`SIMCTL_CHILD_*` is simctl's mechanism for setting env vars in the launched
process. `--console-pty` attaches to the process's stdout and returns only when
it **exits** (`:1110-1111`), so the run ends with the verdict on stdout and a
process exit — both performed by the *interpreter*, not the guest (§4.2).

### 1.7 What the Swift guest does differently

Only three things, all mechanical:

- one `.swift` file must be named `main.swift` for top-level code — the runner
  stages `guests/swift/<scene>.swift` as `$stage/main.swift`
  (`run-sim.py:1310-1312, 1332`)
- it compiles against `-import-objc-header crates/kaya/include/kaya.h`
  (`:1339`) plus four generated binding files
  (`bindings/swift/KayaWire.swift`, `KayaApp.swift`, `KayaRecords.swift`,
  `KayaSums.swift`, `:1340-1341`)
- it links `-lkaya` from `target/aarch64-apple-ios-sim/debug` and names the
  frameworks (`UIKit Foundation CoreFoundation CoreGraphics QuartzCore`,
  `:1343-1345`)

It does **not** differ in bundle shape, dylib loading, entry point, threading,
env vars, or verdict. `[D]`

---

## 2. Android: how a guest reaches the screen today

### 2.1 The hosting inversion

Android has no native process entry — Zygote forks the process and
`ActivityThread` owns `main` (`crates/kaya/src/android.rs:8-12`;
DESIGN.md:2339-2343). `kaya::run` **panics** there: "Android owns the process
entry; start the core from an Activity via kaya::android_main!"
(`lib.rs:164-170`), and so does `kaya_run` (`capi.rs:815-818`). The entry is
`attach`, and the anchor (the Activity) is explicit. `[D]`

### 2.2 What the APK contains — MEASURED

   ```
`unzip -l android/milestone2/build/outputs/apk/debug/milestone2-debug.apk`
   ```
(built 2026-08-07 11:00 by a previous run; not rebuilt here):

```
lib/arm64-v8a/libmilestone2_android.so   48,870,920   <- the Rust guest + kaya, one .so
lib/arm64-v8a/libmilestone0_android.so   23,753,424   <- STALE leftover, see §5.4
classes.dex  classes2..6.dex                          <- Compose interpreter + androidx
lib/arm64-v8a/libandroidx.graphics.path.so
```
`[M]`

Symbols in that `.so` (llvm-nm from the pinned NDK,
`…/ndk-bundle/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-nm --dynamic
--defined-only`): `Java_dev_kaya_Kaya_attach`,
`Java_dev_kaya_KayaRing_attach`, `KAYA_BUILD_ID_MARKER`, and **38 `kaya_*` C
entry points**. `[M]` So the guest `.so` *is* libkaya (statically linked as an
rlib) plus the guest's JNI entry — there is no separate `libkaya.so` in that
APK.

The JVM-guest APK is the mirror image: `milestone2kt` ships
`jniLibs/arm64-v8a/libkaya.so` (30,430,336 bytes, `[M]`) — kaya's own cdylib —
and the guest is Java/Kotlin classes in the dex.

### 2.3 Who calls whom at startup

**Rust guest (`compose` suite)** — `android/milestone2/src/main/kotlin/dev/kaya/milestone2/MainActivity.kt`:

| Step | Code |
|---|---|
| 1. `KAYA_*` intent extras → env vars via `android.system.Os.setenv` | `MainActivity.kt:18-25` |
| 2. `System.loadLibrary("milestone2_android")` | `MainActivity.kt:27` |
| 3. `Kaya.attach(this)` → JNI `Java_dev_kaya_Kaya_attach` | `MainActivity.kt:30`; `Kaya.kt:26-27`; macro `android.rs:848-859` |
| 4. …which runs `android::attach`: init logging, make the occurrence channel, **spawn the `kaya-app` thread running `app_main(ctx)`**, `set_presentation_sink`, `register_present_natives`, return `PRESENT_GUEST` (=1) | `android.rs:78-95` |
| 5. `KayaCompose.mount(this)` on the UI thread | `MainActivity.kt:31` |
| 6. …which checks `KayaPresent.specHash()` against its baked `SPEC_HASH`, `startPump(activity)`, `activity.setContent { KayaRoot() }`, and starts the selftest if `KAYA_SELFTEST` is set | `KayaCompose.kt:842-852` |
| 7. the pump: a `kaya-compose-pump` thread blocking in `KayaPresent.nextCommands(buffer)` (64 KiB), pre-fetching blobs, then `activity.runOnUiThread { apply(...) }` | `KayaCompose.kt:924-940` |
| 8. `dispatchKeyShortcutEvent` forwarded to `KayaCompose` | `MainActivity.kt:39-40` |

Which scene runs is chosen **inside the guest** from `KAYA_SELFTEST`
(`guests/rust/milestone2_android.rs:87-163`), and an unknown name **panics**
rather than silently running milestone2 (`:158-161`).

**Kotlin/JVM guest (`jvm` suite)** — `android/milestone2kt/…/MainActivity.kt`:

| Step | Code |
|---|---|
| 1. same env-var mapping | `MainActivity.kt:16-23` |
| 2. `System.loadLibrary("kaya")` — kaya's own cdylib, not a guest lib | `:29` |
| 3. `KayaRing.attach(this)` → `Java_dev_kaya_KayaRing_attach`, which registers the **KayaRing** natives (jvm.rs) *and* the **KayaPresent** natives, and takes no core ends | `:30`; `android.rs:105-118`; `KayaRing.kt:16` |
| 4. `KayaCompose.mount(this)` — same interpreter, same pump | `:35` |
| 5. scene selected from `System.getenv("KAYA_SELFTEST")` in a `when` | `:36-89` |
| 6. **kaya spawns the app thread**: `KayaRing.startGuest(scene)`, once per process (it was `Thread(scene, "kaya-app").start()` in the Activity when this probe was taken; ruled 2026-08-27, docs/deferred.md's mount entry) | `:97` |

So the difference between the two Android compositions is *where the guest code
lives*: the Rust path spawns the app thread inside `android::attach` from native
code; the JVM path leaves the core ends in place and `KayaRing.startGuest` starts
a plain Java thread that consumes the ring
(`android.rs:96-104` spells this out). `[D]`

### 2.4 The one asymmetry that matters for a new language

**There is no C-ABI Android attach.** `kaya_run` panics on Android
(`capi.rs:815-818`), and the two live doors are both JNI:

- `Java_dev_kaya_Kaya_attach` — generated by `kaya::android_main!`
  (`android.rs:848-859`), whose argument is a **Rust `impl FnOnce(AppCtx)`**
  (`android.rs:78-82`). Rust-only by construction.
- `Java_dev_kaya_KayaRing_attach` — registers natives only
  (`android.rs:105-118`); the guest then consumes the ring from a thread the
  JVM side starts.

Nothing in the tree is a native non-Rust guest on Android. A C-floor guest
(Go c-archive, .NET NativeAOT, GraalVM native-image, OCaml, Haskell) would
have to come in through a JNI shim that calls `KayaRing.attach` and then hand
its own thread to `kaya_next_occurrence`/`kaya_submit`. That composition is
**plausible from the code but has never been exercised in this repo** —
mark it `[A]` until an arm builds it.

---

## 3. The ABI surface a guest actually needs

### 3.1 The two halves of the C header

`crates/kaya/include/kaya.h` (1693 lines, generated by `tools/gen-header.py`)
carries **36** functions `[M]` — the same 36 `kaya_*` symbols the Android guest
`.so` exports `[M]`. They split cleanly:

**GUEST side — what a guest calls (12 functions in 11 rows):**

| Symbol | Header line | Purpose |
|---|---|---|
| `kaya_spec_hash` | 1278 | protocol fingerprint; assert at startup |
| `kaya_capabilities` | 1280 | host capability bits |
| `kaya_run` | 1287 | take the main thread, run the core; **panics on Android** |
| `kaya_submit` | 1330 | one transaction, applied atomically |
| `kaya_next_occurrence` | 1366 | block for the next occurrence (function floor) |
| `kaya_occurrence_ring` | 1409 | ring layout, for direct-access transports |
| `kaya_wait_occurrences` | 1415 | block until the ring is non-empty (direct tier) |
| `kaya_wake` | 1392 | wake the app thread — **the only entry safe from any thread**, alongside `kaya_open_picked` |
| `kaya_blob_register` | 1297 | upload bulk bytes, get a handle |
| `kaya_occurrence_blob` / `..._release` | 1314 / 1321 | read+free an occurrence's blob |
| `kaya_open_picked` | 1474 | redeem a picked-file handle; **safe from any thread** (`:1460-1461`) |

**BACKEND side — what a guest-language *interpreter* calls (the other 24):**
the `kaya_emit_*` family (16, header lines 1424-1625),
`kaya_undo_route`/`redo_route`/`undo`/`redo`/`note_native_undo` (5, 1639-1678),
plus `kaya_blob_data` (1306), `kaya_stalled_ms` (1403) and
`kaya_next_commands` (1691). 12 + 24 = 36. `[M]` A new *guest* language does
not touch these — the SwiftUI dylib and the Compose interpreter already do,
and neither is rewritten per guest.

(`kaya_stalled_ms` is dual-use: the interpreters answer `expect_stall` with
it, and "an app that wants to report its own health can poll it" —
`kaya.h:1398-1401`.)

### 3.2 The vtable, not the symbols

On Apple the backend never resolves kaya symbols by name. `swiftui_host::run`
builds a `KayaHostApi` struct of 26 function pointers and passes it to
`kaya_swiftui_run(api)` (`swiftui_host.rs:123-222, 265-294`;
`swift/KayaSwiftUIEntry.swift:60-73`). The reason is stated at
`swiftui_host.rs:5-11`: hosts may carry kaya statically (a Rust executable) or
`RTLD_LOCAL` (ctypes), so symbol-space coupling is unreliable. On Android the
equivalent is JNI `RegisterNatives` from `register_present_natives`
(`android.rs:119-…`), "so a guest cdylib's only name-based export is its
entry" (`android.rs:19-21`). `[D]`

**Consequence for a candidate language: the guest's kaya can be private.** It
does not have to export `kaya_*` publicly for the backend to work.

### 3.3 Must the guest own `main`?

| Platform | Answer |
|---|---|
| **iOS** | **Yes — the guest owns the process entry, and it must be a compiled binary.** "the OS execs the native executable named in the bundle, so the process entry must be a compiled binary … and means interpreted guests need their binding's native bootstrap as main" (DESIGN.md:2409-2415). The guest's `main` then surrenders the main thread to `kaya_run()` / `kaya::run()`, which never returns (`lib.rs:149`, `KayaApp.swift:1534`). |
| **Android** | **No — and it may not.** The OS owns `main`; the guest is entered from `Activity.onCreate` on the UI thread (`android.rs:8-12`, `MainActivity.kt:11-31`). |

### 3.4 Threading contract

Stated once in DESIGN.md:2332-2343 and enforced in the code:

1. **Exactly one UI thread** runs all native-widget code and the core's
   dispatcher; **app logic runs on a separate thread**; the transport is the
   only bridge.
2. **On macOS and iOS the UI thread must be the actual process main thread
   (thread 0)** — so the core takes over `main()` and kaya hosts the language
   runtime (DESIGN.md:2335-2337). `kaya_run`'s own doc: "Take over the calling
   thread, **which must be the process main thread**" (`kaya.h:1283-1287`).
3. **On Android the core attaches its dispatcher to the Looper thread**
   (DESIGN.md:2339-2343). `KayaCompose.mount` must be called on the UI thread
   and every apply hops back with `activity.runOnUiThread`
   (`KayaCompose.kt:937`).
4. **The app thread must be blockable** — occurrence consumption blocks by
   design (DESIGN.md:2379-2381). Either side may provide it: Rust's
   `kaya::run`/`android::attach` spawn `kaya-app`
   (`lib.rs:144-147`, `android.rs:85-89`); the Swift binding spawns its
   `dispatchLoop` thread (`KayaApp.swift:1532-1533`); the JVM tier's is
   spawned by `KayaRing.startGuest` (`KayaRing.kt:41-45`).
5. `kaya_next_occurrence` must be called **from a single app thread**, and not
   mixed with direct ring access (`kaya.h:1338-1339`).
6. Only `kaya_wake` (`kaya.h:1370`) and `kaya_open_picked` (`kaya.h:1460-1461`)
   are safe from any thread.
7. **Nothing crosses the boundary synchronously** — no callbacks into the
   guest; "the core never calls into the guest"
   (`bindings/README.md`, layer-3 contract). `[D]`

### 3.5 Runtime-boot classes (the design's own taxonomy)

DESIGN.md:2396-2416 sorts candidate languages three ways, and this is the
sentence a candidate arm should be measured against:

- **No runtime** (Rust, C, Swift): link and call the entry symbol.
- **Self-booting on load** (Go via c-archive constructors, .NET NativeAOT,
  GraalVM native-image): effectively the same.
- **Embedded interpreters** (CPython, JVM via libjvm, .NET via hostfxr): the
  VM must be created and configured when the language does not own the
  process.

And the two compositions: **guest-hosts** (the language owns the process and
calls a run entry) and **shell-hosts** (a native shell owns `main` and calls
one guest entry symbol on a blockable thread). "Which composition applies is
determined by the platform's launch model, not by the backend technology."

---

## 4. The harness requirement

### 4.1 The harness lives in the INTERPRETER, not in the guest

This is the single most load-lightening fact for a new language. On iOS and
Android the scene-script interpreter is written in Swift and Kotlin
respectively and is compiled once, per platform, not per guest:

- Swift: `kayaStartSelftest()` / `kayaRunScript(script)`
  (`swift/KayaSwiftUI.swift:3335-3346`), verdict at `:6167-6200`
- Kotlin: `startSelftest(activity)` / `runScript(activity, script)`
  (`KayaCompose.kt:1715-1724, 3552`), verdict at `:4711` and `:4736`

CLAUDE.md's ladder says the same from the other end: the Rust `harness`
feature is needed for GTK and WinUI builds, "mac/iOS do not, since the SwiftUI
interpreter carries its own harness."

### 4.2 What the *guest* must do for a leg to run

Exactly four things, and only the first is per-language work:

1. **Build the scene** — same widget tree, same handlers, same **byte-identical
   output strings** as every other language (CLAUDE.md invariant 6; scenes are
   `tools/scenes/*.steps`, shared verbatim, compared byte-for-byte).
2. **Mount a root.** A scene that builds widgets and never mounts renders an
   empty window and every assertion measures nothing — the interpreter has a
   dedicated diagnosis for it (`KayaSwiftUI.swift:6171-6197`).
3. **On Android only: select the scene from `KAYA_SELFTEST`**, and panic on an
   unknown name (`guests/rust/milestone2_android.rs:88-162`;
   `milestone2kt/MainActivity.kt:36-89`). On iOS each scene is its own bundle,
   so this is unnecessary — the runner still sets `KAYA_SELFTEST` because the
   *interpreter* gates on its presence (`KayaSwiftUI.swift:3336`).
4. **Do not read `KAYA_SELFTEST_SCRIPT`, do not print the verdict, do not
   exit.** The interpreter does all three.

### 4.3 The environment and verdict transport

| | iOS | Android |
|---|---|---|
| Script in | `SIMCTL_CHILD_KAYA_SELFTEST_SCRIPT` env (`run-sim.py:1093`) | `am start --es KAYA_SELFTEST_SCRIPT` intent extra, then `Os.setenv` in onCreate (`run-emulator.py:571`, `MainActivity.kt:18-25`) |
| Newlines | real newlines | **not possible** — scripts fold to `;`, "the intent-extra transport cannot carry newlines" (`run-emulator.py:713-715`; grammar accepts `;`, `KayaCompose.kt:1709-1710`) |
| Verdict out | stdout, read via `simctl launch --console-pty`, matched by `grep -q "KAYA_SELFTEST: OK"` (`run-sim.py:1092-1095, 1118`) | `Log.i("kaya", …)` → `adb logcat -s kaya:* -e 'KAYA_SELFTEST: (OK\|FAILED)' -m 1` (`KayaCompose.kt:4711`, `run-emulator.py:595, 622`) |
| Process end | `exit(0)`/`exit(1)` from the interpreter (`KayaSwiftUI.swift:6169, 6200`) | `finishAndRemoveTask()` + `Runtime.getRuntime().halt()` — "halt rather than exit so no teardown hook races the render threads" (`KayaCompose.kt:1712-1713, 1719-1720`) |

**None of the step table is language-specific.** The verbs, the `kind#index`
target grammar, and the expected strings are identical for the Rust and Swift
guests on iOS and for the Rust and Kotlin guests on Android — the same
`tools/scenes/*.steps` file feeds all four.

### 4.4 Where a new language's legs must be declared

`tools/check-steps.py:1684-1828` (`wired()`) demands that **every** scene have
live legs in **every** runner, including `tools/ios/run-sim.py` and
`tools/android/run-emulator.py` — name-level for the two mobile runners,
because "their legs derive mechanically from the scene list, so the name IS
the wiring" (`:406-408`). The only escape is a `depth_stub("<scene>")`
declaration in the backend, derived by `tools/lib/scene-features.py --mode
exempt` (`:436`). A new language that runs a subset of scenes has **no
sanctioned way to be partially wired** — the exemption is keyed on the
*backend*, not on the guest language.

---

## 5. The packaging machinery that exists

### 5.1 tools/ios/

| Path | What it is |
|---|---|
| `run-sim.py` (1627 lines) | the whole lane: gates, dylib build, per-guest builds, bundle assembly, simulator pool, legs |
| `Info.plist.in` | the one bundle template; `@EXECUTABLE@`/`@BUNDLE_ID@`/`@NAME@` substituted in `make_bundle` (`run-sim.py:95-100`) |
| `simdrive/{build.sh,main.swift}` | host-side driver for the document picker (built once per run, `run-sim.py:83`) |
| `clipctl/{build.sh,main.swift}` | in-simulator clipboard reader, run under `simctl spawn` (`run-sim.py:84-88`) |
| `clipprobe/`, `pickerprobe/`, `scopeprobe/`, `undoprobe/` | throwaway platform probes (each its own `build.sh` + `mainN.swift`), not part of a lane |

There is **no Xcode project, no `xcodebuild`, no code signing, no
`.xcframework`, no SwiftPM package** in the iOS lane. A bundle is a directory
with three things in it (`make_bundle`, `run-sim.py:90-103`). The only
`codesign` in `tools/ios/` is in `scopeprobe/build.sh:60, 139` — a throwaway
device probe, not a lane. `[M]`

`Info.plist.in` is shared by every guest, so a new language inherits four
non-obvious keys for free: `UIDeviceFamily [1,2]` (without it iPadOS runs the
bundle in iPhone compatibility mode and the iPad form-factor leg silently
becomes a second phone leg), `UIFileSharingEnabled` and
`LSSupportsOpeningDocumentsInPlace` (without them the document picker cannot
see the app's own files), and `UILaunchScreen`.

### 5.2 tools/android/

| Path | What it is |
|---|---|
| `run-emulator.py` (1184 lines) | the lane: `cargo ndk` builds, jniLibs copy, `gradle assembleDebug`, `adb install`, `am start`, logcat verdict |
| `cliphelper/` | a **separate APK** (own gradle build) that owns a foreign clipboard, invoked over an explicit broadcast |
| `clipprobe/`, `pickerprobe/`, `undoprobe/` | probe APKs with their own gradle projects and `run*.sh` |

The gradle side is `android/` in the repo root: `android/kaya` (the
`com.android.library` module holding the Compose interpreter + generated
`bindings/java` sources), `android/milestone2` (Rust-guest app),
`android/milestone2kt` (JVM-guest app). `android/kaya/build.gradle.kts:31-35`
shows the out-of-tree source dirs: `../../bindings/java` and `generated`.

### 5.3 Where a new language's artifact slots in

**iOS** — three insertion points, all inside `run-sim.py`:

1. a build step producing a **Mach-O executable for `arm64-apple-ios-sim`**
   whose `main` ends in `kaya_run()`, linking `libkaya.a` from
   `target/aarch64-apple-ios-sim/debug` (the Swift leg's shape,
   `run-sim.py:1337-1346`) or carrying kaya internally (the Rust leg's shape,
   `:1381`);
2. `make_bundle <name> <bundle-id> <exe>` then `cp libkaya_swiftui_ios.dylib
   "$APP/libkaya_swiftui.dylib"` — three lines, identical for every language
   (`:1363-1366`);
3. `queue_leg run_swiftui_on …` per scene (`:1368-1371`).

**Android** — the shape is per-composition:

- *native-guest shape* (Rust's): produce `lib<name>.so` for `arm64-v8a`
  exporting a JNI attach entry → `cp` into
  `android/<app>/src/main/jniLibs/arm64-v8a/` → `gradle :<app>:assembleDebug`
  → `run_apk` (`run-emulator.py:741-760`). The `.so` must be self-sufficient:
  the APK carries **no separate libkaya.so** in this shape `[M]`.
- *JVM-guest shape* (Kotlin's): `cp target/aarch64-linux-android/debug/libkaya.so`
  into jniLibs, add the guest's sources to the app module's `srcDirs`, and let
  the Activity call `KayaRing.attach` + start the guest thread
  (`run-emulator.py:1043-1052`; `milestone2kt/build.gradle.kts:31-40`).
- either way a **new gradle module** (`android/<name>/build.gradle.kts` +
  `AndroidManifest.xml` + a `MainActivity`) is required, registered in
  `android/settings.gradle.kts`.

### 5.4 Two build-hygiene facts a candidate arm will trip over

- **Every artifact carries a build id and is `--verify`'d before it runs.**
  `tools/build-id.py --verify` is applied to `libkaya.a` (`run-sim.py:1307-1308`),
  the SwiftUI dylib (`:1299-1300`), the copied `.so` (`run-emulator.py:752`),
  and the APK's dex (`:755-756`). A new language's artifact will have to carry
  one too, or be excluded deliberately.
- **`jniLibs` is a checked-in directory that accumulates.** The APK measured
  above ships `libmilestone0_android.so` (23.7 MB) beside the live
  `libmilestone2_android.so` (48.9 MB) — a leftover from a renamed example that
  nothing deletes, because the lane only ever `cp`s in
  (`run-emulator.py:741-749`). `[M]` A second language adding its own `.so` to
  the same module would be packaged into every APK.

---

## 6. THE HOST CONTRACT — the checklist

A candidate language passes the mobile contract if it can answer YES to every
line. Grouped so a candidate arm can score it.

### A. Artifact form

| # | Requirement | Evidence |
|---|---|---|
| A1 | **iOS: can produce a native Mach-O executable for `aarch64-apple-ios-sim` (and, for a device, `aarch64-apple-ios`)** — the process entry must be a compiled binary. | DESIGN.md:2409-2415 |
| A2 | iOS: that executable **carries kaya inside it** — statically linking `libkaya.a`, or (Rust) the rlib. Linking `libkaya.dylib` is a **fail**: today's Swift leg does exactly that and produces a bundle that only runs in the Simulator (§1.2). Test it with `otool -L`: nothing but system dylibs and `libkaya_swiftui.dylib` may appear. | `[M]`; `Cargo.toml:9-12`; `run-sim.py:1343` |
| A3 | iOS: the executable runs **unsigned in the Simulator** (the lane never signs anything). | `run-sim.py:40-43` |
| A4 | **Android: can produce an `arm64-v8a` ELF shared object** exporting a JNI-callable entry, **or** run as JVM bytecode in the app's dex. | `run-emulator.py:748-749, 1046-1047` |
| A5 | The artifact can be **stamped with a build id** and pass `tools/build-id.py --verify`. | `run-sim.py:1307`; `run-emulator.py:752` |

### B. ABI

| # | Requirement | Evidence |
|---|---|---|
| B1 | Can **call C functions** with `const uint8_t*`/`uintptr_t`/`uint64_t`/`double` parameters and read back `const uint8_t*` out-params. | `kaya.h:1297-1366` |
| B2 | Can **assert `kaya_spec_hash()` equals its generated constant at startup** and fail loudly. | `KayaApp.swift:1527-1531`; `KayaCompose.kt:845-848` |
| B3 | Can **pack and submit wire records** (`kaya_submit`) and **decode occurrence records** from either the function floor (`kaya_next_occurrence`) or the raw ring (`kaya_occurrence_ring` + `kaya_wait_occurrences`). | `bindings/README.md` layer 2 |
| B4 | Needs **no callback from C into the guest** — the core never calls in. | `bindings/README.md` layer 3; DESIGN.md:2430 |
| B5 | Can copy out borrowed bytes before the next call on the same thread (no ownership of core memory). | `kaya.h:1359-1361` |

### C. Hosting and threads

| # | Requirement | Evidence |
|---|---|---|
| C1 | **iOS: the language can own `main` and hand thread 0 to a C call that never returns.** | `kaya.h:1283-1287`; DESIGN.md:2335-2337 |
| C2 | iOS: the language runtime **boots without owning the process entry in a way kaya cannot reach** — i.e. it is class 1 or 2 of DESIGN.md:2396-2401, or its bootstrap can be made `main`. | DESIGN.md:2396-2416 |
| C3 | **Android: the language can be entered from `Activity.onCreate` on the UI thread** (JNI entry, or code reachable from Kotlin) and **must not** call `kaya_run`. | `android.rs:8-12`; `capi.rs:815-818` |
| C4 | The language can provide (or accept) a **blockable app thread** distinct from the UI thread. | DESIGN.md:2379-2385 |
| C5 | If the runtime requires per-thread attachment (JNI `AttachCurrentThread`, cgo, `PyGILState`), it **prefers providing its own thread** — allowed, not disqualifying. | DESIGN.md:2385-2388 |
| C6 | Calls `kaya_next_occurrence` from **one** thread only; uses `kaya_wake` (the only any-thread entry, with `kaya_open_picked`) for cross-thread work. | `kaya.h:1338-1339, 1370, 1460-1461` |

### D. Android-specific plumbing

| # | Requirement | Evidence |
|---|---|---|
| D1 | An **entry the Activity can call**: either a `Java_…_attach`-shaped JNI export (Rust's `android_main!` shape) or JVM code invoked after `KayaRing.attach`. **No C-ABI Android attach exists.** | `android.rs:848-859, 105-118`; `capi.rs:815-818` |
| D2 | Can read the process environment (`System.getenv`/`getenv`) — the runner delivers `KAYA_SELFTEST` as an intent extra converted by `Os.setenv`. | `MainActivity.kt:18-25` |
| D3 | **One APK hosts every scene**, so the guest must contain a scene switch keyed on `KAYA_SELFTEST` that **panics on an unknown name**. | `milestone2_android.rs:88-162`; `milestone2kt/MainActivity.kt:36-89` |
| D4 | Ships as a gradle module with an `AndroidManifest.xml`, a `MainActivity` doing the 4-line dance (env → loadLibrary → attach → `KayaCompose.mount`), and an entry in `android/settings.gradle.kts`. | `milestone2/MainActivity.kt:11-31` |
| D5 | Tolerates `minSdk 26`, `compileSdk 35`, `buildToolsVersion 37.0.0`, JVM target 17. | `android/kaya/build.gradle.kts:9-45` |

### E. iOS-specific plumbing

| # | Requirement | Evidence |
|---|---|---|
| E1 | The bundle is **assembled by hand**: `Info.plist` from a template, the executable, and `libkaya_swiftui.dylib` at the bundle root. No Xcode project. | `run-sim.py:90-103, 1363-1366` |
| E2 | `kaya::run`/`kaya_run` `dlopen`s the interpreter from `$KAYA_SWIFTUI_LIB`; the runner points it at the installed container. The guest does nothing here. | `swiftui_host.rs:233-247`; `run-sim.py:1094` |
| E3 | Reads env vars set by `SIMCTL_CHILD_*` at launch. | `run-sim.py:1092-1095` |
| E4 | Writes the interpreter's verdict to **stdout** and lets it `exit()` — `--console-pty` returns only when the process exits. | `run-sim.py:1110-1111, 1118` |
| E5 | **One bundle per scene** (unlike Android): the guest need not switch on `KAYA_SELFTEST`, but the runner still sets it. | `run-sim.py:1323, 1363-1372` |

### F. Harness / semantics

| # | Requirement | Evidence |
|---|---|---|
| F1 | Produces **byte-identical output strings** to every other language for the shared `tools/scenes/*.steps`. | CLAUDE.md invariant 6 |
| F2 | **Mounts a root** — an unmounted scene fails with a dedicated diagnosis. | `KayaSwiftUI.swift:6171-6197` |
| F3 | Does **not** read `KAYA_SELFTEST_SCRIPT`, print a verdict, or exit — the interpreter owns all three. | `KayaSwiftUI.swift:3335-3346`; `KayaCompose.kt:1715-1724` |
| F4 | Must eventually be wired into **both** mobile runners for **every** scene, or hold scenes off with a backend `depth_stub`. There is no per-language partial wiring. | `check-steps.py:1659-1670, 1684-1828` |
| F5 | Carries the language's own layer-2 transport and layer-3 structural core (id allocation, template scoping, occurrence dispatch); layer 1 is generated from the spec. | `bindings/README.md` |

### G. The two questions that decide a candidate fast

1. **Can it make a self-contained native binary for `aarch64-apple-ios-sim`
   that owns `main`?** If no, iOS is closed to it today — there is no
   shell-host path in the tree for a guest that cannot be `main` (the retired
   Swift-shell leg is gone; DESIGN.md:2383-2385 says the shape is equivalent
   but nothing exercises it).
2. **Can it be entered from JNI, or from JVM code, on the Android UI thread?**
   If neither, Android is closed to it today — `kaya_run` panics and no C
   attach exists (`capi.rs:815-818`).

Everything else on this list is packaging work whose shape is already written
down twice.
