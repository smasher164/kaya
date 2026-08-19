# Gio's single-main.go trick, and what it means for kaya

Research arm: GIO + synthesis. Started 2026-08-08.
Every claim tagged MEASURED (I ran it / read the exact bytes),
DOCUMENTED (upstream source or vendor doc, cited), or ASSUMED.
Repo claims cite `file:line`. Probes live in
`scratchpad/goentry/ (gone)` and touch no repo file.

Source under study, all fetched from the module proxy on 2026-08-08 and
therefore reproducible by version, not by path:

- `gioui.org v0.10.1` (`go get gioui.org@latest` resolved this)
- `gioui.org/cmd v0.10.0` (the `gogio` tool)
- `golang.org/x/mobile v0.0.0-20260803200217-62cee1672c8e` (gomobile)
- `fyne.io/fyne/v2 v2.8.0`

Repo citations are against the working tree at **HEAD `19cd5ef` plus the
staged scene-library refactor** — note that the tree moved under me
during this session (a concurrent session landed `0e35bd8` "Go reaches
iOS" and `19cd5ef` "Go lands on Android" and staged the
`guests/go/scenes/* (gone)` split). I wrote nothing to the repo; every line
number below was re-verified against the tree at the end of the run.

---

## §1 — The mechanism, in one sentence

**Gio does not have a single entry point. It has the same two entry
points kaya has; it hides one of them behind `//go:linkname main.main`.**

The chain, all four links read from source:

1. `app/runmain.go` (29 lines, build-tagged `android || (darwin && ios)`)
   declares a bodyless Go function and points the linker at the app's
   own `main`:

   ```go
   //go:linkname mainMain main.main
   func mainMain()

   var runMainOnce sync.Once

   func runMain() {
       runMainOnce.Do(func() {
           // Indirect call, since the linker does not know the address of main when
           // laying down this package.
           fn := mainMain
           go fn()
       })
   }
   ```
   (MEASURED, `modcache/gioui.org@v0.10.1/app/runmain.go:17-28`.) The
   file's own comment states the problem in Gio's words:
   *"Android only supports non-Java programs as c-shared libraries.
   Unfortunately, Go does not run a program's main function in library
   mode. To make Gio programs simpler and uniform, we'll link to the
   main function here and call it from Java."*
   (DOCUMENTED, same file:7-10.) That is kaya's `main_android.go`
   comment — "`-buildmode=c-shared` requires exactly one main package
   and then NEVER CALLS its main" (`guests/go/milestone2/main_android.go:18-22 (gone)`)
   — written by the other project, four years earlier.

2. `app/os_android.go:373` is a cgo `//export` JNI entry with the
   canonical `Java_<pkg>_<Class>_<method>` name:

   ```go
   //export Java_org_gioui_Gio_runGoMain
   func Java_org_gioui_Gio_runGoMain(env *C.JNIEnv, class C.jclass, jdataDir C.jbyteArray, context C.jobject) {
       initJVM(env, class, context)
       ... // decode dataDir, set XDG_CACHE_HOME / XDG_CONFIG_HOME / HOME
       runMain()
   }
   ```
   (MEASURED, `app/os_android.go:373-402`.) It captures the `JavaVM`
   and a global ref to the app `Context` and the `org.gioui.Gio` class
   (`initJVM`, `app/os_android.go:404-411`), then calls `runMain()`.

3. `app/Gio.java` is the Java side of that entry — 68 lines, package
   `org.gioui`:

   ```java
   public static synchronized void init(Context appCtx) {
       synchronized (initLock) {
           if (jniLoaded) { return; }
           String dataDir = appCtx.getFilesDir().getAbsolutePath();
           ...
           System.loadLibrary("gio");
           runGoMain(dataDirUTF8, appCtx);
           jniLoaded = true;
       }
   }
   static private native void runGoMain(byte[] dataDir, Context context);
   ```
   (MEASURED, `app/Gio.java:25-43`.)

4. `app/GioView.java:85` calls `Gio.init(context.getApplicationContext())`
   from the `GioView` constructor (MEASURED). So Go's `main` starts when
   the first Gio view is constructed, not when the process starts.

**So: the JNI attach entry still exists, the Activity still owns the
process entry, the Go `main` still runs on a goroutine that the JNI
call schedules and abandons. The only thing Gio removed is the app
author's obligation to *write* the second entry point** — `//go:linkname`
lets a library reach into `package main` and grab the symbol the
c-shared linker kept but never calls.

The counterpart on the other side of `main`: `app.Main()`
(`app/app.go:146-148`) dispatches to a per-OS `osMain()`. On Android
that is literally

```go
func osMain() {
    select {}
}
```
(MEASURED, `app/os_android.go:1327-1329`) — the goroutine parks forever
and the *Java* caller was never blocked, because `runMain` did `go fn()`
rather than `fn()`. On Linux/Wayland/X11 the same `select{}`
(`app/os_unix.go:40-42`); on iOS `osMain` branches on whether Go owns
the process (`mainModeExe` → `C.gio_applicationMain(argc, argv)`) or is
embedded as a library (`mainModeLibrary` → do nothing, then
`select{}`) (MEASURED, `app/os_ios.go:400-427`).

That last branch is the tell: **even Gio has a two-shape entry, it just
resolves the shape at run time inside the library instead of at compile
time in the app.**

---

## §1a — I reproduced the trick in 30 lines (MEASURED)

Probe at `scratchpad/goentry/linkprobe/ (gone)` (throwaway, no repo file
touched). A `lib` package does the `//go:linkname main.main` pull and
`go fn()`; `package main` has a cgo `//export Java_probe_Shim_attach`
and an ordinary `func main()`.

**Android build**, Go 1.27rc2 with the repo's own NDK clang
(`aarch64-linux-android24-clang` from `$ANDROID_NDK_ROOT`):

```
CGO_ENABLED=1 GOOS=android GOARCH=arm64 go build -buildmode=c-shared -o libprobe.so .
BUILD_RC=0
nm libprobe.so | grep ...
0000000000160fc4 T Java_probe_Shim_attach
0000000000160f00 T main.main
```
(MEASURED 2026-08-08.) So under the toolchain kaya actually ships,
`-buildmode=c-shared` **keeps `main.main` in the symbol table** and the
cross-package `//go:linkname` pull links clean. Go 1.23's linkname
tightening does not bite: that restriction is on *standard library and
runtime* symbols, not on a user package's `main.main`.

**Behaviour**, same code built as a darwin `c-shared` dylib and driven
by a 20-line C host that `dlopen`s it:

```
host: library loaded; main.main has NOT run yet
host: calling attach on thread 0x1ef4a1d80
lib: scheduling main.main as a goroutine
host: attach RETURNED (caller thread free)
main.main ran
host: still alive, exiting
```
(MEASURED.) Three facts, all of which kaya's own design already
assumes: loading the library does **not** run `main`; the attach call
**returns immediately**, freeing the caller's thread (the Looper
thread, on Android); `main` then runs on a goroutine.

**And a real Gio app builds the same way.** A single `main.go` importing
`gioui.org/app`, no build tags, no second file:

```
CGO_ENABLED=1 GOOS=android GOARCH=arm64 go build -buildmode=c-shared -o libgio.so .
BUILD_RC=0
nm libgio.so | grep -c "T Java_org_gioui"   ->  34
nm libgio.so | grep    "T main.main"        ->  000000000058a3f0 T main.main
```
(MEASURED, `scratchpad/goentry/gioapp/ (gone)`.) **34 JNI entry points ship in
that library.** The app author wrote none of them. That is the honest
size of "a single main.go": the second entry point did not disappear,
it moved into the toolkit.

---

## §2 — What is in the APK, and who owns the Activity

`gogio -target android` (`modcache/gioui.org/cmd@v0.10.0/gogio/androidbuild.go`):

- **`go build -buildmode=c-shared -o jni/<abi>/libgio.so`**, one per
  arch, in parallel, with `GOOS=android CC=<ndk clang>` and
  `-ldflags=-w -s -extldflags "-Wl,-z,max-page-size=65536"`
  (MEASURED, `androidbuild.go:219-241`).
- **`go list -f {{.Dir}} gioui.org/app/`, then glob `*.java` in that
  directory and run `javac -target 1.8 -source 1.8`** on them
  (MEASURED, `androidbuild.go:242-271`). It hard-fails if the glob is
  empty: *"the gioui.org/app package contains no .java files (gioui.org
  module too old?)"* (`androidbuild.go:251`). So the Java that becomes
  `classes.dex` is **Gio's three files and nothing the app wrote**.
  `d8` (`:365-372`), `aapt2 link` (`:426-512`), `zipalign` (`:716`),
  `apksigner` (`:638`). No Gradle anywhere.
- **The manifest is a Go text/template inside gogio**, and it names
  Gio's Activity as the launcher:
  ```xml
  <activity android:name="org.gioui.GioActivity"
      android:theme="@style/Theme.GioApp"
      android:configChanges="screenSize|screenLayout|smallestScreenSize|orientation|keyboardHidden"
      android:windowSoftInputMode="adjustResize"
      android:launchMode="singleInstance"
      android:exported="true">
  ```
  (MEASURED, `androidbuild.go:468-474`.)
- The app's only way to add Java is **precompiled**: gogio globs
  `*.jar` in the package directory and adds them to the classpath
  (`androidbuild.go:126-130`; documented in `help.go:17-18` — *"Compiled
  Java class files from jar files in the package directory are included
  in Android builds"*). It never compiles app Java sources.
- The escape hatch is `-buildmode archive`, which emits an **`.aar`**
  (`androidbuild.go:275-333`) for a Gradle project you own. That is the
  supported path to your own Activity, and it is exactly kaya's shape:
  you write Kotlin, you call in.

**Verdict on ownership: `org.gioui.GioActivity` owns the Activity, and
`GioView extends SurfaceView` owns the whole window** (MEASURED,
`app/GioView.java:61`). `GioActivity.onCreate` builds a `FrameLayout`,
puts one `GioView` in it, `setContentView(layer)`
(`GioActivity.java:18-34`). There is a `public FrameLayout layer` field
left deliberately public so you can add sibling views — that is the
entire extension point in the APK path.

### The gomobile comparison (same problem, different resolver)

`golang.org/x/mobile` at `v0.0.0-20260803200217-62cee1672c8e`:

- `GoNativeActivity extends android.app.NativeActivity`
  (`app/GoNativeActivity.java:12`), so the framework's own NDK glue
  calls **`ANativeActivity_onCreate`** in the `.so`.
- That C function does the linkname's job with **`dlsym`** instead:
  ```c
  // Call the Go main.main.
  uintptr_t mainPC = (uintptr_t)dlsym(RTLD_DEFAULT, "main.main");
  if (!mainPC) { LOG_FATAL("missing main.main"); }
  callMain(mainPC);
  ```
  (MEASURED, `app/android.c:92-97`), and `callMain` is a cgo `//export`
  that ends in `go callfn.CallFn(mainPC)` (`app/android.go:81-103`).
- `app/android.go:8-19` states the model in upstream's words:
  *"Android Apps are built with -buildmode=c-shared. They are loaded by
  a running Java process… All-Go apps built using NativeActivity enter
  at ANativeActivity_onCreate."* (DOCUMENTED.)
- **`gomobile build` refuses any Activity but its own.** `manifest.go:35-36`:
  `can only build an .apk for GoNativeActivity, not %q` (MEASURED). Gio
  is *softer* here only in that its manifest is generated rather than
  validated; neither tool lets you name your own Activity in the APK path.
- gomobile's `bind` mode is the other shape entirely: `-buildmode=c-shared`
  into `jniLibs/<abi>/libgojni.so` inside an **AAR**
  (`cmd/gomobile/bind_androidapp.go:389`), for a Gradle app that owns
  its Activity. **That is kaya's shape**, spelled by the Go project itself.

**Independent confirmation of kaya's D2 environment trap.** gomobile hit
it and works around it inline:

```go
//export callMain
func callMain(mainPC uintptr) {
    for _, name := range []string{"TMPDIR", "PATH", "LD_LIBRARY_PATH"} {
        n := C.CString(name)
        os.Setenv(name, C.GoString(C.getenv(n)))
        C.free(unsafe.Pointer(n))
    }
    ...
```
(MEASURED, `app/android.go:81-88`.) Gio does the same for three other
names (`XDG_CACHE_HOME`, `XDG_CONFIG_HOME`, `HOME`) at
`app/os_android.go:383-396`. **Both projects copy C's `getenv` into Go's
copy at attach time, for a hard-coded name list.** kaya's
`docs/go-mobile-plan.md:59-71` D2 found the same defect and chose the
other fix — expose the live `getenv` through the binding (`kaya.Env`)
and gate `os.Getenv` out of guests. Neither upstream generalizes; a
fourth variable name is silently empty in both.

For run arguments Gio does **not** solve it at run time at all: gogio
bakes them into the binary with
`-X gioui.org/app.extraArgs=<a>|<b>` (MEASURED,
`gogio/build_info.go:140-156`), read by an `init()` that appends them to
`os.Args` (`app/app.go:21-26,174-182`). A per-launch value — which is
what `KAYA_SELFTEST` is, and what the matrix legs need — has **no**
equivalent in Gio's model; you would rebuild the APK per scene.

---

## §3 — Events, threads, text input

### Threads

| | Gio | gomobile | kaya |
|---|---|---|---|
| Who calls Go first | `Gio.init` → `Java_org_gioui_Gio_runGoMain`, from the `GioView` constructor on the UI thread (`GioView.java:85`) | framework → `ANativeActivity_onCreate` on the UI thread (`android.c:72`) | shell Activity `onCreate` → `Java_dev_kaya_KayaGo_attach` on the UI thread (`bindings/go/android.go:153 (gone)`) |
| How `main`/app starts | `go fn()` where `fn = main.main` via linkname (`runmain.go:22-28`) | `go callfn.CallFn(mainPC)` via dlsym (`android.go:102`) | `go func(){ runtime.LockOSThread(); app() }()` (`bindings/go/android.go:184-193 (gone)`) |
| Is that thread locked? | **No** — a bare goroutine; it migrates across Ms | **No** | **Yes** — `runtime.LockOSThread()`, because the app thread parks inside a C call (`kaya_wait_occurrences` → a pthread condvar) and the occurrence ring is single-consumer (`bindings/go/android.go:184-192 (gone)`) |
| What ends `main` | `app.Main()` → `osMain()` → `select {}` (`os_android.go:1327-1329`) | `app.Main(f)` runs the event loop | `App.Serve()` — the dispatch loop |
| UI thread after attach | returns to the Looper | returns to the Looper | returns to the Looper |

Gio's not-locked goroutine is safe **because Gio never touches the UI
toolkit from it**: every JVM call goes through `runInJVM`, which
attaches a thread to the JVM explicitly (`os_android.go:1336-1341` and
the `jni_AttachCurrentThread` helper at `os_android.go:23-25`).

### Events

- **Gio**: 32 of the 34 JNI exports are `Java_org_gioui_GioView_*` —
  `onTouchEvent`, `onKeyEvent`, `onFrameCallback`, `onSurfaceChanged`,
  `onWindowInsets`, `onConfigurationChanged`, the a11y family, and
  twelve `ime*` entries (MEASURED, `nm libgio.so`). Java receives the
  platform callback and immediately calls native with a `long nhandle`
  identifying the view (`GioView.java:71,113`). Rendering is driven by
  `Choreographer.postFrameCallback` (`GioView.java:447-456`).
- **kaya**: occurrences ride a byte ring the guest consumes on its own
  thread; the Kotlin side registers the pump natives with
  `KayaRing.attach` and every other native in the package is *registered
  by the native side rather than resolved by name*
  (`android/kaya/src/main/kotlin/dev/kaya/Kaya.kt:15-18`).

### Text input and the soft keyboard — the documented pain

Both toolkits reimplement `InputConnection` from scratch, because a
self-drawn surface has no `EditText` for the IME to talk to.

- Gio's `GioView.onCreateInputConnection` hand-builds an `EditorInfo`
  (input type, IME options, initial selection, caps mode, surrounding
  subtext) and returns a private `GioInputConnection`
  (`GioView.java:408-421`); `showTextInput` is a raw
  `imm.showSoftInput(GioView.this, 0)` (`:431-434`). Twelve of the 34
  JNI exports exist only to keep Go's text model and the IME's snippet
  model in sync (`imeSnippet`, `imeSetComposingRegion`,
  `imeToUTF16`, `imeToRunes`, …).
- The failure mode this produces is documented upstream:
  Gio issue **#404, "Keyboard crash on Samsung when using Numeric
  Hint"** — a `StringIndexOutOfBoundsException` out of
  `getCursorCapsMode` in `GioView.java`, plus repeated warnings about
  operations on an *inactive* InputConnection
  (https://todo.sr.ht/~eliasnaur/gio/404). Gio's own newsletter records
  the fix for the sibling defect: expanding an IME snippet when a new
  range overlaps the old, *"instead of completely replacing the IME
  snippet for every update… which avoided never-ending restarts of the
  IME on Android"* (https://gioui.org/news/2022-04).
- Fyne, on gomobile's driver, has the same class of report
  (https://github.com/fyne-io/fyne/issues/1941).

**kaya pays none of this**, and the reason is structural, not diligence:
its Android text widgets ARE Compose text widgets, so `InputConnection`,
composing regions, caps mode, autofill and the IME's snippet protocol
are Google's code, not kaya's. That is the single largest hidden cost in
the Gio/gomobile column and it does not appear in any "single main.go"
comparison.

---

## §4 — Do Fyne and Gio render their own pixels? (yes, MEASURED)

- **Gio**: `GioView extends SurfaceView` (`app/GioView.java:61`); the GPU
  backends are `gpu/internal/{opengl,vulkan,metal,d3d11}`; on Android
  `app/egl_android.go` (EGL/GLES) and `app/vulkan_android.go`. Not one
  Android widget is instantiated for content.
- **Fyne**: `internal/driver/mobile/driver.go:28` imports
  `fyne.io/fyne/v2/internal/painter/gl`; its Android glue is a **fork of
  x/mobile's app package** (`internal/driver/mobile/README.txt`: *"This
  directory is a fork of the golang.org/x/mobile package"*), with the
  same `GoNativeActivity extends NativeActivity` and the same
  `dlsym("main.main")` (`internal/driver/mobile/app/android.c:125`).
- **gomobile** itself: `#cgo LDFLAGS: -landroid -llog -lEGL -lGLESv2`
  (`app/android.go:25`).
- **Qt** (the only other family with Go bindings that reaches Android —
  therecipe/qt, mappu/miqt) also draws its own widgets onto Android
  SurfaceViews (DOCUMENTED: Qt/KDAB describe a single SurfaceView for
  all raster windows, https://www.kdab.com/future-qt-android-looks-bright/).

But here is the finding that matters, and it cuts against the intuitive
story:

> **Self-rendering is not what gives Gio a single `main.go`.** The single
> `main.go` is a *Go toolchain* workaround for "`-buildmode=c-shared`
> retains `main.main` but never calls it". It lives entirely inside a Go
> library and a JNI entry. Nothing in `runmain.go`, `os_android.go`'s
> `runGoMain`, or gomobile's `ANativeActivity_onCreate` knows or cares
> what draws the pixels.

What self-rendering actually buys is something else: because Gio owns the
whole window from Go, **the toolkit can own the Activity**, so gogio can
generate the manifest and ship `GioActivity` — and the app author writes
no Java. That is a packaging consequence, not an entry-point one, and the
two get conflated because gogio delivers both in the same command.

---

## §5 — The synthesis, answering the maintainer's three questions

### 5a. Could kaya's Go guests have a single `main.go` on Android WITHOUT abandoning Compose?

**Yes. Compose is not the blocker, and the blocker that exists is not a
UI-framework blocker at all.**

Why Compose does not block it, from the tree:

- kaya's guest never runs on the UI thread on any platform
  (`DESIGN.md:2332-2334`): "exactly one UI thread runs all native-widget
  code and the core's dispatcher; app logic runs on a separate thread;
  the only bridge between them is the transport". Android "inverts the
  hosting… the core attaches its dispatcher to that thread instead of
  owning it" (`DESIGN.md:2339-2342`).
- The Compose interpreter is mounted by Kotlin — `activity.setContent {
  KayaRoot() }` (`android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt:850`)
  — before the guest is started, and does not depend on how the guest
  was started (`bindings/go/android.go:131-141` says both orders work).
- kaya's attach **already does the exact thing Gio's `runMain` does**:
  ```go
  go func() {
      runtime.LockOSThread()
      app()
  }()
  ```
  (`bindings/go/android.go:184-193 (gone)`). The only difference from Gio is
  where `app` comes from — a registration (`kaya.AndroidMain`, an
  `init()`) instead of `//go:linkname main.main`.

So the change is mechanical: add an `//go:build android` file to
`bindings/go` with the linkname pull, and have
`Java_dev_kaya_KayaGo_attach` start `mainMain` instead of `androidApp`.
**MEASURED that this links and runs under the exact toolchain kaya pins**
(§1a).

**What it would cost, itemized:**

1. **`App.Run()` becomes platform-conditional inside the binding, and
   inherits Gio's documented wart.** Today `Run()` is
   `go a.Serve(); code := Run(); return code` (`bindings/go/app.go:3213-3222`)
   and the free `Run()` is `kaya_run` (`bindings/go/runtime.go:133-136`),
   which **panics on Android**: `"Android owns the process entry; attach
   from an Activity instead of kaya_run"` (`crates/kaya/src/capi.rs:817`).
   An android arm would run `Serve()` on the calling goroutine. Gio's
   `app.Main()` states the resulting asymmetry outright: *"On most
   platforms Main blocks forever, for Android and iOS it returns
   immediately to give control of the main thread back to the system"*
   (`app/app.go:138-145`).
2. **The exit code stops being the guest's.** `os.Exit(App().Run())` is
   correct on desktop and process-killing on Android. So the one line
   the author writes has to become something the binding owns —
   `kaya.Main(build)` that exits on desktop and parks on Android. The
   author's `main` gets shorter but stops being plain Go.
3. **`runtime.LockOSThread()` moves from the guest into the binding**,
   under `//go:build !android` (Gio's precedent: a package `init()` at
   `app/os_macos.go:342-347`). On Android it must NOT be in an `init()`
   — inits run while `System.loadLibrary` is executing, on a thread Go
   made (`android/milestone2go/.../MainActivity.kt:47-51 (gone)`) — it stays
   inside the spawned goroutine as it already is. That tagged/untagged
   pair is invisible to every compiler, which is exactly the shape
   invariant 3 asks for a guard around.
4. **The scene table stops hiding behind a build tag.** `main_android.go`
   holds the 31-entry table and `tools/check-steps.sh:1617-1620` parses
   that file to learn which scenes the APK carries. With one `main` and
   no tags, the aggregate would be an ordinary package (say
   `guests/go/androidapk/main.go (gone)`) whose `main()` reads
   `kaya.Env("KAYA_SELFTEST")` and serves the chosen scene — arguably
   *simpler* (no build tags anywhere in the Go tree), but it forces one
   refactor: milestone2's scene body currently lives in a `main` package
   and so cannot be imported; it would move to `guests/go/scenes/milestone2 (gone)`
   like the other 30 (the reasoning at `main_android.go:8-16` already
   explains why the 30 are libraries).
5. **The empty-`KAYA_SELFTEST` panic relocates.** It is the *only*
   run-time wall against the D2 environment defect
   (`main_android.go:145-160`, `docs/go-mobile-plan.md:59-71`). It
   survives the move, but it moves — worth naming because it guards a
   bug that has already shipped in this exact form elsewhere (gomobile
   patches three env names by hand at `app/android.go:83-87`, Gio three
   others at `app/os_android.go:383-396`; neither generalizes).
6. **A new dependency on an undocumented linker behaviour.** `main.main`
   being (a) retained under `-buildmode=c-shared` and (b) callable as a
   plain function is not a documented Go API. Go 1.23 already narrowed
   `//go:linkname` — *"The linker now disallows using a //go:linkname
   directive to refer to internal symbols in the standard library
   (including the runtime) that are not marked with //go:linkname on
   their definitions"* (DOCUMENTED, https://go.dev/doc/go1.23) — which
   does **not** cover `main.main`, and MEASURED it still works on
   1.27rc2. gomobile hedges differently, resolving the same symbol with
   `dlsym(RTLD_DEFAULT, "main.main")` at load time (`app/android.c:93`),
   which trades a build-time failure for a run-time one. Today kaya
   depends on neither.
7. **What it does NOT cost:** nothing in the ring, the transport, the
   Compose interpreter, the a11y layer, the IME, the scene scripts, or
   the byte-compared verdicts. The guest still runs on a locked non-UI
   thread.

**The one thing that stays no matter what:** the Kotlin shell. Five lines
in `onCreate` (`android/milestone2go/.../MainActivity.kt:46-55 (gone)`). The
linkname removes the *guest's* second entry point, not the *host's*
first one. Gio has the identical five-lines-in-Java and hides them in
a shipped `GioActivity`.

### 5b. Is there a middle path — the split stays, the author never writes it?

Four separable options. Costs measured against the machinery that exists.

**M1 — a binding helper. Split visible, two lines.**
`kaya.Run(build)` beside the existing `kaya.AndroidMain(build)`:
```go
//go:build !android
func main() { kaya.Run(App) }
```
```go
//go:build android
func init() { kaya.AndroidMain(App) }
```
Cost: ~20 lines in `bindings/go`. `AndroidMain` already exists
(`bindings/go/android.go:124-129`). No generator, no gate, no new
failure mode. Does not hide the split; shrinks it to its irreducible
statement.

**M2 — generate the tails.** `tools/gen-guests.sh:31` already runs
`go generate ./guests/go/...` against `cmd/kaya-gen`, and `--check`
regenerates in place and fails on any diff. Adding an emitter is one
generator arm plus one glob in the `GENERATED=(...)` list
(`gen-guests.sh:79`). **But
generated files are checked in by design**, so the author still *sees*
`main_android.go` — it merely becomes a file they must not hand-edit,
sitting in the directory they edit daily. That is a new footgun class
in exchange for removing 10 lines of boilerplate, and 10 lines is not
obviously more expensive than the generator that writes them. (Third-party
precedent that this works: therecipe/qt's Android path generates
`cgo_main_wrapper.go` exporting `go_main_wrapper`, which fills `os.Args`
and calls `main()` —
https://github.com/therecipe/qt/blob/master/internal/cmd/deploy/build.go.)

**M3 — Gio's linkname.** One `main.go`, no build tags anywhere. Costs
1-6 above.

**M4 — the Kotlin half only, orthogonal to M1-M3.** Ship a
`dev.kaya.KayaActivity` in the existing AAR (`android/kaya` is
`com.android.library`, `android/kaya/build.gradle.kts:2`) that does the
five lines, reading the guest library's name from manifest meta-data the
way `GoNativeActivity.load()` does (`app/GoNativeActivity.java:39-60`).
The app author's Android-specific work becomes a manifest entry.
This removes MORE author-visible Android code than M3 does, and touches
no Go. Note it is a **sweep-all-bindings** change by invariant 2: a
`KayaActivity` that hardcodes a Go guest's shape is wrong; it has to
serve the Rust, JVM and Go shells (which today differ in exactly one
line each — `milestone2go/.../MainActivity.kt:11-17`).

**Cost of doing nothing (M0).** MEASURED: `main_desktop.go` is 25 lines,
**11 of them code**; `main_android.go` is 170 lines, **88 of them code**
— and 34 of those 88 are the scene table and its imports, which every
option keeps. So the split proper is roughly **11 + 5 lines of code per
guest**, wrapped in prose that is the only place in the tree stating the
c-shared entry rule and the Zygote hosting inversion
(`main_desktop.go:1-9`, `main_android.go:18-22`). Under M3 that prose has
nowhere obvious to live except the binding.

### 5c. What do other native-widget cross-platform toolkits with a Go binding do?

**There are none that reach Android.** Every Go GUI project that runs on
Android renders its own pixels (§4), and every one of them starts
`main.main` from a JNI/NDK entry by resolving the symbol:

| project | resolver | entry |
|---|---|---|
| Gio | `//go:linkname main.main` at link time | `Java_org_gioui_Gio_runGoMain` |
| gomobile | `dlsym(RTLD_DEFAULT, "main.main")` at load time | `ANativeActivity_onCreate` |
| Fyne | same as gomobile (forked) | `ANativeActivity_onCreate` |
| therecipe/qt | generated `//export go_main_wrapper` calling `main()` | Qt's `androiddeployqt` glue |

The one Go project that puts Go behind a **native** Android UI is
`gomobile bind`, and its answer is kaya's answer: *"the bind command
produces an AAR… that archives the precompiled Java API stub classes,
the compiled shared libraries"* (DOCUMENTED,
`cmd/gomobile/doc.go:45-49`), built as `-buildmode=c-shared` into
`jniLibs/<abi>/libgojni.so` (`cmd/gomobile/bind_androidapp.go:389`). The
consuming app owns its Activity; there is no `main` at all, and no
linkname. **kaya's shape is the Go project's own shape for this case.**

Note also the contrast in how far the toolkit-owns-the-Activity model
goes: `gomobile build` refuses to package any other Activity —
`can only build an .apk for GoNativeActivity, not %q`
(`cmd/gomobile/manifest.go:35-36`) — and gogio never compiles app Java
sources, only pre-built `*.jar` (`gogio/androidbuild.go:126-130`,
`help.go:17-18`). "Single `main.go`" and "you may not write Kotlin" are
the same decision seen from two sides.

---

## §6 — The comparison table

| | **Gio** | **gomobile (`build`)** | **gomobile (`bind`)** | **kaya (today)** |
|---|---|---|---|---|
| Android artifact | `-buildmode=c-shared` `libgio.so` | `-buildmode=c-shared` | `-buildmode=c-shared` `libgojni.so` in an AAR | `-buildmode=c-shared` guest `.so` + `libkaya.so` |
| How Go is entered | JNI `Gio.runGoMain` → `//go:linkname main.main` → `go fn()` | `ANativeActivity_onCreate` → `dlsym("main.main")` → `go CallFn` | generated JNI stubs per exported func; **no `main`** | JNI `KayaGo.attach` → registered `AndroidMain` func → `go` + `LockOSThread` |
| App author writes a 2nd entry? | **No** | **No** | No (no `main` exists) | **Yes** — `main_android.go` |
| Thread running app code | unlocked goroutine | unlocked goroutine | caller's JNI thread | **locked OS thread** (ring is single-consumer) |
| Who owns the Activity | `org.gioui.GioActivity` (shipped) | `org.golang.app.GoNativeActivity` (shipped; **others refused**) | **the app** | **the app** (`MainActivity.kt`, 5 lines) |
| Can the app supply Java/Kotlin? | only pre-built `*.jar`; else use `-buildmode archive` (.aar) + Gradle | no | yes — it's a normal Gradle app | yes — it *is* a normal Gradle app |
| Packaging tool | `gogio` (own javac/d8/aapt2/apksigner; no Gradle) | `gomobile` | Gradle | Gradle |
| UI | self-drawn, SurfaceView + EGL/Vulkan | self-drawn, EGL/GLES | whatever the app writes | **Jetpack Compose** |
| Events to Go | 32 `Java_org_gioui_GioView_*` JNI exports | `ANativeActivity` callbacks + JNI | direct calls | occurrence **byte ring**, consumed off-thread |
| Text input / IME | hand-built `InputConnection`, 12 `ime*` JNI exports; documented crashes (sr.ht #404) | hidden `EditText` added via `addContentView` to summon the IME (Fyne fork, `GoNativeActivity.java:412-419`) | app's own | **Compose's** `BasicTextField` — Google's IME code |
| Accessibility | hand-built `AccessibilityNodeProvider` (`GioView.java:821-849`) + JNI | minimal | app's own | **Compose semantics** |
| Env vars in library mode | patches 3 names (`XDG_CACHE_HOME`, `XDG_CONFIG_HOME`, `HOME`) at attach | patches 3 names (`TMPDIR`, `PATH`, `LD_LIBRARY_PATH`) at attach | n/a | `kaya.Env` reads C's live `getenv`; `tools/check-go-env.sh` bans `os.Getenv` in guests |
| Per-launch run arguments | **none** — baked at link time via `-X gioui.org/app.extraArgs` | n/a | n/a | per-launch: intent extras → `Os.setenv` → `kaya.Env` |
| Multiple apps in one artifact | 1 `main` per `.so` | 1 | n/a | 31 scenes, one table (`main_android.go:83-126`) |

---

## §7 — Probe hygiene (MEASURED)

**Repo:** nothing written. The 69 modified/staged paths reported by
`git status` at the end of this run belong to the concurrent session
that landed `19cd5ef` and staged the `guests/go/scenes/* (gone)` refactor; this
arm issued no Write, Edit, or shell redirect anywhere under
`/Users/akhilindurti/Projects/kaya`.

**Processes:** none started in the background. The only executable I ran
was `./host` (the `dlopen` probe), in the foreground, to completion,
exit 0. Proof rather than assertion — scanning the full process table
for this session's scratch path and probe binary names:

```
processes still running from this arm's probes: 0
```

**Disk:** the probes needed a Go module cache and build cache.

| | before cleanup | after |
|---|---|---|
| `scratchpad/goentry/ (gone)` | 675 MB | **28 MB** |
| whole `scratchpad/ (gone)` | 783 MB | **135 MB** |

Deleted: `modcache/` (508 MB), `gocache/` (127 MB), `gioapp/`,
`linkprobe/`, `probe/`, `gopath/`. **Left in place deliberately:**
`goentry/fyne/`, `goentry/x-mobile/`, `goentry/classes.dex` (28 MB) —
those were created at 11:05-11:13 by a *sibling arm of this workflow*
sharing the same scratch directory, and deleting them mid-run would have
corrupted its evidence. That 28 MB is theirs to clean, not mine.

Everything I deleted is reproducible with
`go get gioui.org@v0.10.1`, `go get gioui.org/cmd@v0.10.0`,
`go get golang.org/x/mobile@v0.0.0-20260803200217-62cee1672c8e`,
`go get fyne.io/fyne/v2@v2.8.0`; every quotation above is verbatim, so
verification does not require the cache.

