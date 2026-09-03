# How Fyne / gomobile get one `main.go` to run on Android

Research arm: FYNE and the gomobile lineage. RESEARCH ONLY — no repo file
was changed; probes live in
`/private/tmp/claude-501/-Users-akhilindurti-Projects-kaya/24aa5ebf-e439-4206-9ba0-de67540e4b06/scratchpad/goentry/ (gone)`.

Sources read at these exact revisions (both cloned into that directory):

- `golang.org/x/mobile` @ `62cee1672c8eb8502c4718ec93e6ae321d1e40e5`
  (2026-08-03) — https://github.com/golang/mobile
- `fyne.io/fyne/v2` @ `57f5b07179b833e781522f8a32c160312d94ede1`
  (2026-08-07) — https://github.com/fyne-io/fyne

Tags: **MEASURED** = I ran it or decoded the bytes. **DOCUMENTED** =
upstream source/vendor doc says it, cited by file:line or URL.
**ASSUMED** = inference; may not support a conclusion.

I did **not** build an APK (no NDK in this shell). Everything about APK
*contents* is DOCUMENTED from `build_androidapp.go`, except the
`classes.dex` inventory, which is MEASURED by decoding the base64 blob
that gets written verbatim into the APK.

---

## 1. The mechanism, exactly

### 1.1 The chain

x/mobile states it in its own package header, `app/android.go:7-20`
(https://github.com/golang/mobile/blob/62cee167/app/android.go#L7-L20) —
DOCUMENTED:

> Android Apps are built with `-buildmode=c-shared`. They are loaded by a
> running Java process.
>
> Before any entry point is reached, a global constructor initializes the
> Go runtime, calling all Go init functions. All cgo calls will block
> until this is complete. Next `JNI_OnLoad` is called. When that is
> complete, one of two entry points is called.
>
> All-Go apps built using NativeActivity enter at `ANativeActivity_onCreate`.

Link by link, all DOCUMENTED from source:

1. **Zygote forks; ActivityThread owns the process main thread and its
   Looper.** Unchanged. Nothing Go does touches this.
2. **The manifest declares `org.golang.app.GoNativeActivity`**, a class
   that `extends android.app.NativeActivity`
   (`app/GoNativeActivity.java:12`). `NativeActivity` is a stock
   framework class — Android's own "this app is all native code" host
   (https://developer.android.com/reference/android/app/NativeActivity).
3. **`GoNativeActivity.onCreate` calls `load()` *before*
   `super.onCreate()`** (`app/GoNativeActivity.java:61-66`), and `load()`
   is `System.loadLibrary(libName)` with `libName` read from the
   manifest's `android.app.lib_name` metadata
   (`app/GoNativeActivity.java:39-59`). Its comment says why the subclass
   exists at all:

   > Interestingly, NativeActivity uses a different method to find native
   > code to execute, avoiding `System.loadLibrary`. The result is Java
   > methods implemented in C with JNIEXPORT (and `JNI_OnLoad`) are not
   > available unless an explicit call to `System.loadLibrary` is done.

   That `System.loadLibrary` is what boots Go: the .so's ELF
   constructors run, every Go `init()` runs, then `JNI_OnLoad`
   (`app/android.c:53-60`).
4. **`super.onCreate()` → framework → `ANativeActivity_onCreate`**, the
   well-known symbol `NativeActivity` looks up in the loaded library.
   x/mobile defines it at `app/android.c:72`.
5. **`ANativeActivity_onCreate` finds Go's `main.main` BY SYMBOL NAME
   and calls it through a raw PC** (`app/android.c:92-98`):

   ```c
   // Call the Go main.main.
   uintptr_t mainPC = (uintptr_t)dlsym(RTLD_DEFAULT, "main.main");
   if (!mainPC) {
       LOG_FATAL("missing main.main");
   }
   callMain(mainPC);
   main_running = 1;
   ```

   **This `dlsym` is the entire trick.** Under `-buildmode=c-shared` Go
   compiles `main.main` into the library and nothing ever calls it;
   gomobile reaches in and calls it as an address.
6. **`callMain` is a cgo `//export` on the Go side**
   (`app/android.go:80-102`). It repairs three environment variables
   from C's `getenv` (`TMPDIR`, `PATH`, `LD_LIBRARY_PATH`), fixes
   `time.Local`, and then the load-bearing line, `app/android.go:101`:

   ```go
   go callfn.CallFn(mainPC)
   ```

   `callfn.CallFn` is four instructions of hand-written assembly per
   architecture, with an honest doc comment
   (`app/internal/callfn/callfn.go:13-16`):

   > CallFn calls a zero-argument function by its program counter. It is
   > only intended for calling `main.main`. Using it for anything else
   > will not end well.

   (`callfn_arm64.s` is `MOVD fn+0(FP), R0; BL (R0); RET` in the same
   shape as the 386 file I read.)

**No `android_native_app_glue` is involved.** gomobile does not use
`android_main` at all; it implements the `ANativeActivity` callback
struct itself (`app/android.c:106-119`, thirteen assignments) and drives
the input queue with its own `ALooper` (§1.2).

There is also a `JNI_OnLoad` (`app/android.c:53-60`), but in current
x/mobile it does nothing except return `JNI_VERSION_1_6` — the real work
is in `ANativeActivity_onCreate`.

### 1.2 Which thread Go's `main` runs on — the answer to the maintainer's question

**Go's `main.main` does NOT run on the Android UI thread**, and the
`ANativeActivity_onCreate` that starts it returns immediately. DOCUMENTED
from `app/android.go:101` (`go callfn.CallFn(mainPC)`) — the `go` keyword
puts `main.main` on a fresh goroutine. `callMain` returns, `onCreate`
finishes wiring `activity->callbacks` (`app/android.c:106-119`) and
returns, and the UI thread goes straight back to the Looper, exactly like
any NativeActivity.

Then inside Go, the user's `main()` calls `app.Main(f)`
(`app/app.go:20-22`) → android `main(f)` (`app/android.go:266-280`),
which claims two more OS threads of its own:

```go
func main(f func(App)) {
	mainUserFn = f
	// TODO: merge the runInputQueue and mainUI functions?
	go func() {
		if err := mobileinit.RunOnJVM(runInputQueue); err != nil { ... }
	}()
	// Preserve this OS thread for:
	//	1. the attached JNI thread
	//	2. the GL context
	if err := mobileinit.RunOnJVM(mainUI); err != nil { ... }
}
```

`RunOnJVM` (`internal/mobileinit/ctx_android.go:94-124`) is the piece that
makes a Go-owned thread usable from JNI: it spawns a goroutine, calls
`runtime.LockOSThread()`, and `AttachCurrentThread`s it to the JavaVM
(`lockJNI`, `ctx_android.go:11-36`), detaching on the way out. The JavaVM
pointer it uses is stashed by `setCurrentContext`, called from
`ANativeActivity_onCreate` with a `NewGlobalRef` of the Activity
(`app/android.c:81`, `app/android.go:76-78`).

Thread inventory of a running gomobile/Fyne app — DOCUMENTED:

| thread | owner | what runs there |
|---|---|---|
| process main / UI | ActivityThread + Looper | `System.loadLibrary`, `ANativeActivity_onCreate`, every activity callback, every `runOnUiThread` block in Fyne's Java |
| goroutine started by `callMain` | Go runtime | **`main.main` — the user's `main()`** |
| `RunOnJVM(mainUI)`, LockOSThread'd + JNI-attached | Go | the EGL context and the event pump (`app/android.go:284-350`) |
| `RunOnJVM(runInputQueue)`, LockOSThread'd + JNI-attached | Go | a **second** `ALooper` polling the `AInputQueue` (`app/android.go:352-387`) |

Fyne's fork is line-for-line the same mechanism: MEASURED by grep,
`internal/driver/mobile/app/android.c:125` is the identical
`dlsym(RTLD_DEFAULT, "main.main")`, `:129` the identical `callMain`, and
`internal/driver/mobile/app/android.go:129` the identical
`go callfn.CallFn(mainPC)`. Fyne's `driver.Run()` is what calls
`app.Main` (`internal/driver/mobile/driver.go:176-182`), so the user's
`w.ShowAndRun()` bottoms out in the chain above.

### 1.3 So what is the "single main.go" actually doing?

It is **not** that the app has one entry point. It is that **gomobile
moved the second entry point out of the app and into a fixed, prebuilt
Activity that every gomobile app is required to use.** The JNI attach
still exists — it is `ANativeActivity_onCreate` in `app/android.c`,
compiled into every app, written once by the toolchain. The app author
does not see it because the app author is not allowed to replace it.

That is the mechanism, and everything in §3 and §4 is the bill for it.

---

## 2. What the APK actually contains

`gomobile build` (and Fyne's clone of it) assembles the APK zip by hand —
no aapt/aapt2, no Gradle, no AGP, no `javac` at build time. DOCUMENTED
from `cmd/gomobile/build_androidapp.go`:

| entry | where it comes from | line |
|---|---|---|
| `classes.dex` | a **base64 string constant compiled into the gomobile binary** (`dexStr` in `cmd/gomobile/dex.go`) | `build_androidapp.go:151-161` |
| `lib/<abi>/lib<name>.so` | `go build -buildmode=c-shared`, one per target ABI | `build_androidapp.go:70-91` |
| `lib/<abi>/libopenal.so` | only if the binary references `x/mobile/exp/audio/al` | `build_androidapp.go:169-181` |
| `assets/…` | verbatim copy of the package's `assets/` dir | `build_androidapp.go:199-231` |
| `resources.arsc` + one mipmap icon | only if `assets/icon.png` exists; built by gomobile's own `internal/binres` | `build_androidapp.go:233-259` |
| `AndroidManifest.xml` | binary XML encoded by `internal/binres`, gomobile's hand-rolled aapt-compatible encoder | `build_androidapp.go:261-271` |
| `META-INF/…` | signed with a hardcoded debug cert baked into the tool | `build_androidapp.go:93-100`, `cmd/gomobile/build_androidapp.go` `debugCert` |

Fyne does the same, from its partial clone (`cmd/fyne/internal/mobile/`,
declared as such in its `README.txt:1`): `classes.dex` from `dexStr` at
`cmd/fyne/internal/mobile/build_androidapp.go:278-288`, .so per ABI at
`:86-111`, and for `-release` it re-packs into an `.aab` by shelling out
to `zip` and `bundletool` (`:409-427`).

### 2.1 What is in that `classes.dex` — MEASURED

I decoded the base64 `dexStr` out of both trees and listed every class
descriptor in the dex string pool.

**x/mobile** — 2,192 bytes. Exactly **one** non-framework class:

```
Lorg/golang/app/GoNativeActivity;
```

Everything else is a reference: `Landroid/app/NativeActivity;`,
`Landroid/view/KeyCharacterMap;`, `Ljava/lang/String;`, etc.

**Fyne** — 11,716 bytes. Exactly **one** non-framework class plus its
anonymous inner classes:

```
Lorg/golang/app/GoNativeActivity;
Lorg/golang/app/GoNativeActivity$1;  $1$1;  $2;  $3;  $4;  $4$1;  $5;
```

That is the whole Java/Kotlin layer of a Fyne Android app. **The APK
contains no app-authored JVM bytecode and there is no step in the build
that could produce any** — no `javac`, no `kotlinc`, no `d8`, no AAR
resolution anywhere in `build_androidapp.go`.

The dex is regenerated only by a manual `go:generate` on a maintainer's
machine (`cmd/fyne/internal/mobile/build.go:5`:
`//go:generate go run gendex/gendex.go -o dex.go`; the generator globs
`../../../../internal/driver/mobile/app/*.java`, runs `javac` and the
**deprecated `dx`**, and re-emits `dex.go` —
`cmd/fyne/internal/mobile/gendex/gendex.go:61,73,90`).

### 2.2 The declared activity — and a live consequence of the baked dex

**The manifest's activity is fixed by name.** MEASURED-equivalent
(source, both trees, identical code):

```go
if manifest.Activity.Name != "org.golang.app.GoNativeActivity" {
    return "", fmt.Errorf("can only build an .apk for GoNativeActivity, not %q", manifest.Activity.Name)
}
```

— `cmd/gomobile/manifest.go:35-37` and
`cmd/fyne/internal/mobile/manifest.go:34-36`, byte-identical.

The generated manifest (used when the package has no
`AndroidManifest.xml`) declares that one activity with
`MAIN`/`LAUNCHER`, plus `android.app.lib_name` metadata:
`cmd/gomobile/manifest.go:57-75`;
`cmd/fyne/internal/templates/data/AndroidManifest.xml:1-25` (Fyne's adds
`android:exported="true"`, `windowSoftInputMode="adjustResize"`, a wider
`configChanges` set, and three hardcoded permissions —
`WRITE_EXTERNAL_STORAGE`, `READ_EXTERNAL_STORAGE`, `INTERNET`).

**A concrete instance of the fragility this design creates** — MEASURED.
I checked which method names the shipped Fyne dex actually contains
against the methods its own `GoNativeActivity.java` defines:

| Java method in `GoNativeActivity.java` | present in shipped `dex.go`? |
|---|---|
| `showKeyboard`, `hideKeyboard` | PRESENT |
| `showFileOpen`, `showFileSave` | PRESENT |
| `backPressed`, `insetsChanged`, `setDarkMode` | PRESENT |
| `scheduleNotification` (java:274) | **absent** |
| `setupAccessibility` (java:515) | **absent** |
| `addAccessibilityNode` (java:553) | **absent** |
| `updateSystemBarsAppearance` (java:479) | **absent** |
| class `FyneNotificationReceiver` | **absent** |

The C side looks these up by name and string-matches at runtime, then
degrades quietly (`internal/driver/mobile/accessibility_android.c:53-58`):

```c
setup_access_method = (*env)->GetStaticMethodID(env, activity_class,
    "setupAccessibility", "()V");
if (setup_access_method == 0) {
    LOG_WARN("accessibility: setupAccessibility not found");
    (*env)->ExceptionClear(env);
}
```

ASSUMED (from those two measurements, not from running a device): at this
revision, an APK packaged by this `fyne` CLI ships Android accessibility
that no-ops with a logcat warning, because the Java it calls is not in the
dex the packager writes. I did not run it on a device, so this is an
inference and I am not resting any recommendation on it. What it *does*
support, and what IS measured, is the structural point: **the Java layer
is a checked-in binary regenerated by a command someone has to remember
to run, and the Go↔Java join is string-matched at runtime with a
soft-failure path.** That is precisely the failure class kaya's
`CLAUDE.md` invariant 3 exists for ("a guard you have to remember to run
is barely a guard"), and the same "string-matched rather than
compile-checked" hazard CLAUDE.md already names for the interpreter
backends.

---

## 3. What it costs

### 3.1 Fyne draws its own pixels — say it plainly

The Activity's whole window is **one EGL surface**. `createEGLSurface`
(`app/android.c:147-183`) makes an `EGLSurface` over the
`ANativeWindow`, and the pump does `eglSwapBuffers`
(`app/android.go:339`). Fyne renders into it with its own OpenGL painter
(`internal/painter/gl`, imported at
`internal/driver/mobile/driver.go:29`).

**Therefore Fyne does not need the Java UI framework for drawing at all.**
Every button, list and text field in a Fyne app is Fyne's own geometry
rasterized by Fyne's own GL code. That is exactly what makes the fixed
`GoNativeActivity` tolerable for Fyne: an app whose entire visual surface
is one GL quad genuinely does not care which Activity subclass hosts it,
as long as it hosts a native window.

The corollary is the important half: **the moment you want anything the
platform draws — a soft keyboard, a system file picker, a notification,
an accessibility node, a WebView, a Compose tree — you are outside the
GL surface and you need Java, and you cannot add Java.** So the framework
must add it, once, for everyone, inside the one Activity it controls.

### 3.2 What Fyne had to hand-build inside that one Activity

MEASURED: x/mobile's `GoNativeActivity.java` is **67 lines**. Fyne's fork
is **663 lines** plus a 52-line `FyneNotificationReceiver.java`. The
delta is the price list. All DOCUMENTED from
`internal/driver/mobile/app/GoNativeActivity.java`:

- **Soft keyboard / text input.** There is no text input in a GL surface.
  Fyne creates a hidden `EditText`, adds it to the Activity's content
  view, seeds it with one space "so all keyboards can send backspace",
  and watches it (`setupEntry`, `:408-428`; `showKeyboard`, `:150-202`).
  Typed characters go back to Go through hand-declared natives
  `keyboardTyped(String)` / `keyboardDelete()` (`:54-55`).
- **File open/save.** `showFileOpen` builds an `ACTION_OPEN_DOCUMENT`
  intent (or `ACTION_OPEN_DOCUMENT_TREE` for directories),
  `startActivityForResult`s it, and returns the URI to Go through the
  native `filePickerReturned(String)` (`:222-240`, `:431-446`, `:52`).
- **Back button, insets, dark mode.** Natives `backPressed()`,
  `insetsChanged(int,int,int,int)`, `setDarkMode(boolean)` (`:53-57`),
  with layout-change listeners to feed them (`:399-405`).
- **Notifications.** `scheduleNotification` / `cancelScheduledNotification`
  (`:274`, `:321`) plus a separate `BroadcastReceiver` class.
- **Accessibility.** This one is the sharpest illustration. TalkBack
  reads a `View` tree, and a GL surface has no views, so Fyne
  **synthesizes** one: `rebuildA11yViews` (`:609-662`) allocates a
  transparent, non-clickable `View` per widget, positions it by pixel
  margins in a `FrameLayout`, sets a `contentDescription`, and installs
  an `AccessibilityDelegate` that lies about `className`
  (`"android.widget.Button"` / `"android.widget.TextView"`) so TalkBack
  announces a plausible role. Comments note the traps —
  "Non-interactive so touch events fall through to the GL surface",
  "setAlpha is deliberately NOT called: alpha=0 causes TalkBack to mark
  the view as not visible".

### 3.3 What an app author can NOT do

DOCUMENTED, each with the line that forbids it:

| want | verdict | why |
|---|---|---|
| add any Java/Kotlin class | **no** | `classes.dex` is a constant; no `javac`/`kotlinc`/`d8` in the build (`build_androidapp.go:151-161`) |
| use an AndroidX / Play Services / Firebase AAR | **no** | same — nothing resolves or dexes dependencies; there is no Gradle in the pipeline at all |
| put a real Android `View` or a Compose tree in the UI | **no** (only the framework can, inside its own Activity) | the window is one EGL surface (`app/android.c:147-183`) |
| call an arbitrary Java API from Go | **only via `RunOnJVM` + hand-written JNI**, and only against classes that exist in the fixed dex or the framework | `RunOnJVM` (`ctx_android.go:94`) hands you a `JNIEnv`; you still cannot ship a class to call |
| soft keyboard, file picker, notification, a11y | **only what the framework already added** | §3.2 |
| declare a permission | yes, by writing your own `AndroidManifest.xml` (read at `build_androidapp.go:38-65`) — but you inherit the activity-name check |
| declare a `<service>`, `<receiver>`, `<provider>` | **effectively no** | you may write the XML, but the class it names cannot exist in the APK |

x/mobile states the ceiling itself, `app/doc.go:15-19` — DOCUMENTED:

> The second way is to write an app entirely in Go. **The APIs are
> limited to those that are portable between both Android and iOS**, in
> particular OpenGL, audio, and other Android NDK-like APIs.

---

## 4. Does the app get an Activity of its own? No.

**It gets a fixed one it does not control**, and the toolchain enforces
that by name (`cmd/gomobile/manifest.go:35`;
`cmd/fyne/internal/mobile/manifest.go:34`). What happens in each case:

- **Custom Activity.** Refused. `fyne package -os android` /
  `gomobile build` exits with
  `can only build an .apk for GoNativeActivity, not "com.example.MyOwnActivity"`.
  And even if it did not: your class has no path into `classes.dex`.
- **A second activity, or an extra intent filter on one.** MEASURED, by
  running Go's `encoding/xml` against gomobile's exact struct
  (`/private/tmp/.../goentry/probe/main.go`): the parser binds
  `Activity` to a **single** struct, so with two `<activity>` elements
  the name that gets checked is the **last** one, while `MetaData`
  accumulates from both. So a manifest listing your activity second is
  rejected outright; a manifest listing it *first* passes the check by
  accident — and then ships a manifest naming a class the APK does not
  contain. Either way there is no second activity you can implement.
  (Extra `<intent-filter>` blocks *inside* the `GoNativeActivity`
  element are fine — that XML is passed through to `binres` — but every
  intent lands in the same fixed Activity, and the only way to react to
  it from Go is JNI against a class you cannot extend.)
- **A library that expects an Activity of a particular type** (anything
  wanting `AppCompatActivity`, `ComponentActivity`, a Fragment host, an
  `ActivityResultLauncher`, Play Billing, Maps, a Compose `setContent`).
  Impossible. `GoNativeActivity extends NativeActivity`
  (`GoNativeActivity.java:12`), which extends `Activity`, not
  `ComponentActivity` — and you cannot ship the library's bytecode
  regardless.

**The escape hatch upstream provides is a different tool, not a flag.**
`gomobile bind` produces an AAR of "precompiled Java API stub classes,
the compiled shared libraries, and all asset files" for import into an
Android Studio project (`cmd/gomobile/doc.go:44-56`, DOCUMENTED). That is
the "you write the Activity, Go is a library" model — i.e. **the model
kaya already has** — and it is deliberately *not* the model
`gomobile build` / `fyne package` use.

---

## 5. What this means for kaya

I verified kaya's side against the tree rather than the brief.

Confirmed:

- Android backend is Jetpack Compose in Kotlin, hosted by a Kotlin
  `ComponentActivity`:
  `/Users/akhilindurti/Projects/kaya/android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt`,
  `/Users/akhilindurti/Projects/kaya/android/gohost/src/main/kotlin/dev/kaya/gohost/MainActivity.kt:24`
  (`class MainActivity : ComponentActivity()`).
- The guest never runs on the UI thread on any platform:
  `/Users/akhilindurti/Projects/kaya/DESIGN.md:2332-2334`.
- `kaya_run` is a hard panic on Android:
  `/Users/akhilindurti/Projects/kaya/crates/kaya/src/capi.rs:815-818`.
- The Go attach starts the guest and returns the UI thread to the Looper:
  `/Users/akhilindurti/Projects/kaya/bindings/go/android.go:170-194`
  (`go func(){ runtime.LockOSThread(); app() }()`, then `return presentGuest`).
- The guest split is per-tail, not per-scene:
  `guests/go/milestone2/main_desktop.go:1 (gone)` (`//go:build !android`) and
  `main_android.go:1` (`//go:build android`); MEASURED, `milestone2` is
  the only Go guest carrying an `main_android.go` — every other scene is
  a library under `guests/go/scenes (gone)/` with a `!android` desktop tail.

### 5.1 The comparison

| | gomobile / Fyne (`gomobile build`, `fyne package -os android`) | kaya today |
|---|---|---|
| Android entry symbol | `ANativeActivity_onCreate` in `app/android.c:72`, in the app's own .so | `Java_dev_kaya_KayaGo_attach`, `bindings/go/android.go:138 (gone)` |
| who calls Go's app code | `dlsym(RTLD_DEFAULT, "main.main")` → `callMain` → `go callfn.CallFn(mainPC)` (`android.c:93-97`, `android.go:101`) | `KayaGo.attach(this)` from `onCreate` → `go func(){…app()}()` |
| Go guest code thread | a goroutine; **not** the UI thread | a `LockOSThread`'d goroutine; **not** the UI thread |
| who owns the Looper | ActivityThread; `onCreate` returns to it immediately | ActivityThread; `attach` returns to it immediately |
| **entry points in app source** | **one** (`func main`) | **two** (`main` under `!android`, `init()+AndroidMain` under `android`) |
| why the second entry is invisible | it exists, prebuilt, in `GoNativeActivity` + `android.c` — the toolchain writes it and forbids replacing it | kaya's guest declares it, because kaya's Activity is the app's |
| declared Activity | fixed `org.golang.app.GoNativeActivity`, enforced (`manifest.go:35`) | the app's own Kotlin `ComponentActivity` |
| APK Java layer | one baked `classes.dex`; 1 app class (x/mobile), 1 + inner classes (Fyne) — MEASURED | a real Gradle module; `dev.kaya.*` Kotlin, Compose, a `ContentProvider` (`android/kaya/src/main/AndroidManifest.xml`) |
| UI | one EGL surface, framework draws every pixel itself | Jetpack Compose widgets |
| soft keyboard / file picker / a11y | framework hand-writes Java into its fixed Activity (663 lines) and calls it by JNI name with soft failure | Compose and the platform provide them |
| custom Activity / intent filter / Android library | not possible; escape hatch is a *different* tool, `gomobile bind` (`doc.go:44-56`) | already how it works |
| env vars at startup | gomobile patches `TMPDIR`/`PATH`/`LD_LIBRARY_PATH` from C `getenv` in `callMain` (`android.go:81-85`) — same underlying problem | `kaya.Env` reads C `getenv`; guarded by `tools/check-go-env.py` and a runtime panic (`guests/go/milestone2/main_android.go (gone)`) |

### 5.2 The conclusion I would defend

**The single-`main.go` shape is not a technique kaya is missing. It is a
consequence of a decision kaya has already made the other way, and made
deliberately.** gomobile gets one `main` by owning the Activity and
forbidding the app to have one; kaya's Android backend *is* Compose in a
Kotlin Activity, so kaya cannot own the Activity without deleting its
Android backend and replacing it with a self-drawn GL surface — which
would break the ratified one-backend-per-platform roster and the
"language idiom decides spelling, never semantics" invariant, since the
Go guest would then get a different renderer from every other guest.

The narrower question — *could kaya hide its second entry point without
changing anything else?* — is worth separating out, and gomobile does
suggest the shape of an answer, though I have not measured it:

ASSUMED (needs a probe before anyone acts on it): the two Go tails differ
in three ways — `runtime.LockOSThread()` in an `init`, `os.Exit(App.Run())`
in `main`, versus `kaya.AndroidMain(app)` in an `init` and an empty `main`.
A binding-level `kaya.Start(func())` that is `App.Run` + `os.Exit` under
`!android` and `AndroidMain` under `android` would collapse those to one
spelling in the guest, leaving the build-tag split inside
`bindings/go/`. That is cosmetic relief, not gomobile's mechanism: it
does not remove the second entry, it moves it one file down, and it does
**not** remove the real Android-specific facts a Go guest still has to
know — `kaya.Env` instead of `os.Getenv` (a whole milestone, and the
reason `tools/check-go-env.py` exists), the one-APK-many-scenes library
split that forced 30 scenes out of `main` packages
(`guests/go/milestone2/main_android.go (gone)`), and the re-attach panic on
configuration change (`bindings/go/android.go:118-128 (gone)`). gomobile pays
those same costs — its `callMain` patches three env vars by hand for
exactly the reason kaya's `kaya.Env` exists — it just pays them inside the
toolchain instead of in the guest.

One thing gomobile does that kaya's Go binding does *not*, and which is
cheap and worth considering on its own merits: gomobile's guard against a
second entry is `static int main_running` in C (`app/android.c:62,73,98`),
which makes re-`onCreate` **idempotent** — the Activity may be recreated
and Go's `main` is simply not started again. kaya's equivalent
(`bindings/go/android.go:118-128 (gone)`) **panics**, on the stated reasoning
that the shell must survive rotation itself. Both are defensible; they are
not the same choice, and gomobile's is evidence that the idempotent one is
survivable in practice. (kaya's comment already anticipates this and
argues for the loud version — no change recommended, just noting the
divergence exists and is a choice, not an oversight.)

---

## Appendix: probe inventory (all disposable)

```
/private/tmp/claude-501/-Users-akhilindurti-Projects-kaya/24aa5ebf-e439-4206-9ba0-de67540e4b06/scratchpad/goentry/ (gone)
  x-mobile/      shallow clone of github.com/golang/mobile @ 62cee167
  fyne/          shallow clone of github.com/fyne-io/fyne  @ 57f5b071
  classes.dex    x/mobile's dexStr decoded (2192 bytes)
  probe/main.go  encoding/xml two-activity manifest probe
```

No processes started, no load generated, nothing left running. Total
size measured at the end of the run.
