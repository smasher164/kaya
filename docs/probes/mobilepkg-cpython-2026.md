# Embedding CPython on iOS and Android — state of the art, August 2026

Research date: 2026-08-28. All claims traced to a live source; URLs inline.

Baseline facts established first (they reframe everything below):

- Latest stable CPython: **3.14.7** (2026-08-05). Latest pre-release: **3.15.0rc1**
  (2026-08-04); 3.15.0 final is scheduled **2026-10-01**.
  (https://www.python.org/downloads/)
- **python.org now publishes official mobile binaries.** Android embeddable
  packages have shipped since 3.14; the iOS XCframework appears first in the
  3.15 pre-release series. This is the single biggest change versus the
  "build it yourself with Python-Apple-support" era.

---

## 1. CPython official iOS support (PEP 730)

### Tier and versions

- PEP 730 added iOS; the platform reached **Tier 3** in **Python 3.13**.
  PEP 11's Tier 3 table lists, verbatim:
  - `arm64-apple-ios | iOS on device | Russell Keith-Magee, Ned Deily`
  - `arm64-apple-ios-simulator | iOS on M1 macOS simulator | Russell Keith-Magee, Ned Deily`
  (https://peps.python.org/pep-0011/)
  Tier 3 means: failures do not block a release, no response SLA, but the
  platform is built and tested in CPython CI.
- Minimum deployment target: **iOS 13.0** (settable at compile time via the
  `--host` triple). (https://docs.python.org/3/using/ios.html)
- Python on iOS is **embedded-only** by definition: no system Python, no
  standalone `python` executable, no REPL. Distribution is via an App Store
  app that carries its own interpreter.

### Official binary artifacts — YES, as of 3.15

The iOS downloads index (https://www.python.org/downloads/ios/) lists an
"iOS XCframework" tarball for every 3.15 pre-release:

| Release | Date | Artifact |
|---|---|---|
| 3.15.0rc1 | 2026-08-04 | iOS XCframework |
| 3.15.0b4 | 2026-07-18 | iOS XCframework |
| 3.15.0b3 | 2026-06-23 | iOS XCframework |
| 3.15.0b2 | 2026-06-02 | iOS XCframework |
| 3.15.0b1 | 2026-05-07 | iOS XCframework |

The stable-release section of that page is empty, and the 3.14.7 files table
(https://www.python.org/downloads/release/python-3147/) has **no iOS row** —
only Android, macOS, Windows and source. So: **for 3.14 you must build the
XCframework yourself; for 3.15 (final due 2026-10-01) python.org ships one.**

Size, measured from the 3.15.0rc1 release page
(https://www.python.org/downloads/release/python-3150rc1/):

- `python-3.15.0rc1-iOS-XCframework.tar.gz` — **80.2 MB compressed**.
  That is a fat multi-slice bundle (device arm64 + simulator arm64/x86_64),
  so the per-app cost after slicing is far smaller; see §Size below.

### What the build produces

A `Python.xcframework` covering at minimum `arm64-apple-ios` (device) and one
of `arm64-apple-ios-simulator` / `x86_64-apple-ios-simulator`, plus a
`build/build_utils.sh` helper and the stdlib tree that the
"Process Python libraries" build phase installs into the app bundle. Build
instructions live in `Apple/iOS/README.md` in the CPython source tree
(the 3.15-era layout; 3.14 used `iOS/README.md`).
(https://docs.python.org/3/using/ios.html)

---

## 2. CPython official Android support (PEP 738)

### Tier and versions

- PEP 738 added Android at **Tier 3** in **Python 3.13**. PEP 11 Tier 3 rows:
  - `aarch64-linux-android | Russell Keith-Magee, Petr Viktorin`
  - `x86_64-linux-android | Russell Keith-Magee, Petr Viktorin`
  (https://peps.python.org/pep-0011/)
- 64-bit only by design: **arm64-v8a and x86_64**. There is no 32-bit
  (armeabi-v7a / x86) tier-3 target.
- Minimum: **Android 5.1 / API 21+** per PEP 738 (see §7 for the current
  minimum as built).
- Same embedded-only model as iOS: no system Python, no REPL, each app
  bundles its own interpreter.
  (https://docs.python.org/3/using/android.html)

### Official binary artifacts — YES, stable since 3.14

Both stable and pre-release lines carry them
(https://www.python.org/downloads/android/), named
`python-<version>-<arch>-linux-android.tar.gz`:

| Release | aarch64 | x86_64 |
|---|---|---|
| 3.14.7 (stable, 2026-08-05) | 21.4 MB | 21.8 MB |
| 3.15.0rc1 | 22.7 MB | 23.0 MB |

(sizes from https://www.python.org/downloads/release/python-3147/ and
https://www.python.org/downloads/release/python-3150rc1/)

One tarball per ABI — there is no fat Android artifact, which matches how
Android packaging works (`jniLibs/<abi>/`).

### Package layout

Root contains a `prefix` directory. Under `prefix/lib`:

- JNI libraries: `libpython3.X.so`, plus `lib*_python.so` for external
  dependencies (OpenSSL etc.) — these go to `app/src/main/jniLibs/<abi>/`.
- Assets: `python3.X/` (the standard library) and
  `python3.X/site-packages/` — these go to `app/src/main/assets/`.

The docs point at CPython's own Android testbed `build.gradle.kts` as the
copy recipe.
(https://docs.python.org/3/using/android.html)

### Measured sizes (I downloaded and unpacked both artifacts)

`python-3.15.0rc1-iOS-XCframework.tar.gz` = 84,086,507 bytes on disk; unpacked:

```
Python.xcframework/Info.plist
Python.xcframework/build/                       (build_utils.sh + dylib Info.plist template)
Python.xcframework/lib/python3.15/       233 MB  <- shared pure-Python stdlib
Python.xcframework/ios-arm64/             30 MB  <- device slice
    Python.framework/Python                5.9 MB  (Mach-O arm64 dylib)
    lib-arm64/python3.15/lib-dynload      21 MB  (68 extension .so)
Python.xcframework/ios-arm64_x86_64-simulator/  54 MB  <- fat simulator slice
```

Of the 233 MB shared stdlib, **172 MB is `test/`** and 17 MB is `__pycache__`.
Pure-Python stdlib excluding test/idlelib/tkinter/pycache: **13.8 MB**.
Largest extension modules on iOS: `_ssl` 4.6 MB and `_hashlib` 3.6 MB (OpenSSL
is statically linked into them on Apple), `_zstd` 2.1 MB.

`python-3.14.7-aarch64-linux-android.tar.gz` = 22,477,276 bytes; unpacked
`prefix/lib` = 78 MB:

```
libpython3.14.so          5.83 MB   -> jniLibs
libcrypto_python.so       4.54 MB   -> jniLibs (OpenSSL, renamed to avoid the system soname)
libssl_python.so          0.96 MB   -> jniLibs
libsqlite3_python.so      0.89 MB   -> jniLibs
python3.14/               60   MB   -> assets  (37 MB of that is test/)
    lib-dynload            7.5 MB   (67 extension .so)
```

Pure-Python stdlib excluding test/idlelib/tkinter/pycache: **~13 MB**.

Realistic per-app payload after dropping `test/`:

- iOS: ~5.9 MB `Python.framework` + ~13.8 MB stdlib + up to 21 MB of
  extension modules (much less if you prune `_ssl`/`_hashlib`/`_zstd`/
  `_testcapi`/`_remote_debugging`). Device slice only — Xcode thins the
  XCframework at build time, so the 80 MB tarball is not app size.
- Android: ~6 MB `libpython.so` + ~13 MB stdlib + 7.5 MB extensions, **per ABI**,
  plus ~6.4 MB of OpenSSL/sqlite if you keep them.

---

## 3. Embedding specifics: iOS

### Starting the interpreter from Swift/ObjC

The pattern is the same in CPython's own testbed
(`Platforms/Apple/testbed/TestbedTests/TestbedTests.m`) and in Briefcase's
template (`briefcase-iOS-Xcode-template/.../main.m`). Verbatim from the
CPython testbed:

```objc
PyPreConfig_InitIsolatedConfig(&preconfig);
PyConfig_InitIsolatedConfig(&config);
preconfig.utf8_mode = 1;          // UTF-8 for stdio, FS encoding and locale
config.use_system_logger = 1;     // stdout/stderr -> os_log
config.buffered_stdio = 0;
config.write_bytecode = 0;        // the bundle is signed; no .pyc writing
config.install_signal_handlers = 1;
status = Py_PreInitialize(&preconfig);
PyConfig_SetString(&config, &config.home, L"<bundle>/python");
PyConfig_Read(&config);
PyConfig_SetBytesArgv(&config, argc, argv);
status = Py_InitializeFromConfig(&config);
```

The docs restate this as the required minimum set
(https://docs.python.org/3/using/ios.html):

- `PyPreConfig.utf8_mode = 1`
- `PyConfig.buffered_stdio = 0`
- `PyConfig.write_bytecode = 0`
- `PyConfig.install_signal_handlers = 1`
- `PyConfig.use_system_logger = 1` (recommended; routes `sys.stdout`/`sys.stderr`
  through `_apple_support.py` into the Apple system log)
- `PYTHONHOME = <bundle>/python`
- `PYTHONPATH = <bundle>/python/lib/python3.X`,
  `<bundle>/python/lib/python3.X/lib-dynload`, `<bundle>/app`

`Py_RunMain()` is what the testbed calls afterwards, but nothing forces that —
you can equally call `PyRun_SimpleString`, import a module and call into it, or
just leave the interpreter initialized and drive it from callbacks. Briefcase
sets `config.run_module` and hands control to Python, which then starts the UI;
kaya wants the inverse and simply does not call `Py_RunMain`.

Note `PyConfig_InitIsolatedConfig` sets `install_signal_handlers = 0` by
default ("no signal handler is registered" —
https://docs.python.org/3/c-api/init_config.html); the testbed re-enables it
explicitly. For kaya on a secondary thread you want it left at 0 (see §7).

### stdlib shipping format: a directory, not a zip

`install_stdlib()` in `Python.xcframework/build/build_utils.sh` rsyncs
`Python.xcframework/lib/` (shared pure Python) plus
`Python.xcframework/<slice>/lib-<arch>/` (arch-specific: `lib-dynload`,
`_sysconfigdata`) into `$CODESIGNING_FOLDER_PATH/python/lib/`. It excludes
`libpython*.dylib` explicitly ("that can't be included at runtime"). The
result in the bundle is a plain directory tree. There is no zipimport step,
and `write_bytecode = 0` means no `.pyc` is ever produced at runtime — startup
pays full source compilation unless you pre-build `__pycache__` and ship it.

### App Store rules on dynamic loading — the `.fwork` mechanism

This is the one genuinely iOS-shaped constraint. From
https://docs.python.org/3/using/ios.html:

> The App Store requires that *all* binary modules in an iOS app must be
> dynamic libraries, contained in a framework with appropriate metadata, stored
> in the `Frameworks` folder of the packaged app. There can be only a single
> binary per framework, and there can be no executable binary material outside
> the `Frameworks` folder.

So every `lib-dynload/*.so` is *moved* out of the stdlib tree into
`Frameworks/<dotted.module.name>.framework/<dotted.module.name>`, a text
`.fwork` file is left where the `.so` was containing the framework-relative
path, an `.origin` file inside the framework points back, and each framework is
`codesign`ed. `install_dylib()` in `build_utils.sh` does exactly that:

```sh
mv "$FULL_EXT" "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/$FULL_MODULE_NAME"
echo "$FRAMEWORK_FOLDER/$FULL_MODULE_NAME" > ${FULL_EXT%.so}.fwork
echo "${RELATIVE_EXT%.so}.fwork" > "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER/$FULL_MODULE_NAME.origin"
/usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ... -o runtime --timestamp=none \
    --preserve-metadata=identifier,entitlements,flags --generate-entitlement-der "$CODESIGNING_FOLDER_PATH/$FRAMEWORK_FOLDER"
```

At runtime an `AppleFrameworkLoader` (installed automatically by the iOS build)
reads `.fwork` files and imports from the framework binary. `__file__` reports
the `.fwork` path; `ModuleSpec.origin` reports the framework binary.

`dlopen` itself is not forbidden on iOS — what is forbidden is loading code
that is not part of the OS or shipped and signed inside your app bundle
(Apple developer forums: "you can only use it to load a library that's part of
the OS or embedded within your app (and correctly signed)",
https://developer.apple.com/forums/thread/711730). The framework layout is how
you satisfy "shipped and signed".

### Signing the Python framework

`Python.xcframework` is added to the app target's "Frameworks, Libraries and
Embedded Content" with **Embed & Sign**. Xcode re-signs it with the app's
identity. The build settings the docs require alongside it: User Script
Sandboxing = No (the install script writes into the app bundle), Framework
Search Paths = `$(PROJECT_DIR)`, Header Search Paths =
`"$(BUILT_PRODUCTS_DIR)/Python.framework/Headers"`, "Quoted Include In
Framework Header" = No. The "Process Python libraries" run-script phase must
sit **after** Copy Bundle Resources and **before** Embed Frameworks.

Privacy manifests: modules that use affected APIs ship a `<module>.xcprivacy`
next to the `.so`, which `install_dylib` moves into the framework as
`PrivacyInfo.xcprivacy`. In the artifact I unpacked, `_hashlib.xcprivacy` is
present in `lib-dynload`.

### ctypes on iOS — works, and `CDLL(None)` reaches the main executable

`_ctypes.cpython-315-iphoneos.so` is present in the shipped `lib-dynload`, and
the iOS README says LibFFI is required precisely because "many parts of the
standard library (including the `platform`, `sysconfig` and `webbrowser`
modules) require the use of the `ctypes` module at runtime". So ctypes is not
optional on iOS — it is load-bearing for the stdlib itself.

Two facts from the shipped stdlib source (`ctypes/__init__.py`,
`ctypes/util.py` in the 3.15.0rc1 XCframework):

- `pythonapi = PyDLL(None)` on every platform except Windows, Android and
  Cygwin. iOS falls in the `PyDLL(None)` branch, i.e. **CPython itself relies on
  `dlopen(NULL)` working on iOS**.
- `find_library` on `{"darwin", "ios", "tvos", "watchos"}` searches
  `lib<name>.dylib`, `<name>.dylib`, `<name>.framework/<name>` through
  `ctypes.macholib.dyld.dyld_find`.

**Measured here (macOS host, same Mach-O/dyld semantics as iOS):** a symbol
compiled into a static archive and linked into the main executable is reachable
through `dlopen(NULL)` + `dlsym` *only if the archive member is actually pulled
in*. With a plain `-lfoo` and no undefined reference, the member is never
linked and `dlsym` returns NULL; with `-Wl,-force_load,libfoo.a` the symbol
appears as a global `T` in the executable's symbol table and both `dlsym` and a
call through it succeed. Separately, `ctypes.CDLL(None).Py_GetVersion()`
returned `b'3.14.7 ...'` under a `python3` whose only `otool -L` entry is
`libSystem.B.dylib` — i.e. libpython was statically linked into that
executable and `CDLL(None)` found it. This is the exact shape kaya has: the
repo builds `libkaya.a` (`crate-type = ["rlib", "cdylib", "staticlib"]`) and
`tools/ios/run-sim.sh` links it into the app executable. **`ctypes.CDLL(None)`
will reach libkaya's `#[no_mangle] extern "C"` symbols provided the app links
the archive with `-force_load` (or `-all_load`), so unreferenced symbols are
not dropped.** Without that, only the symbols Swift already calls survive.

---

## 4. Embedding specifics: Android

### Hosting from Kotlin/JNI

The official path (https://docs.python.org/3/using/android.html and CPython's
`Platforms/Android/testbed`) is: Kotlin extracts assets, loads a small JNI
shim, and the shim starts Python. From `MainActivity.kt`:

```kotlin
Os.setenv("TMPDIR", context.cacheDir.toString(), false)   // Android only sets TMPDIR from API 33
val pythonHome = extractAssets()                          // assets/python -> filesDir/python
System.loadLibrary("main_activity")
redirectStdioToLogcat()
return runPython(pythonHome.toString(), argsStringArray)  // external fun -> JNI
```

and from `main_activity.c`:

```c
PyConfig config;
PyConfig_InitPythonConfig(&config);
PyConfig_SetBytesArgv(&config, argc, (char**)argv);       // must come first
PyConfig_SetBytesString(&config, &config.home, home_utf8);
Py_InitializeFromConfig(&config);
return Py_RunMain();
```

Note the Android testbed uses `PyConfig_InitPythonConfig` (not isolated) and
sets only `home` + `argv`; `argv[0]` is a placeholder empty string "for the
executable name in embedded mode". Android's stdout/stderr go to logcat
automatically via `_android_support.py` — the C-level pipe redirection in
`main_activity.c` is explicitly labelled as testbed-only debugging ("Most apps
won't need this, because the Python-level `sys.stdout` and `sys.stderr` are
redirected to the Android logcat by Python itself").

There is also a `init_signals()` step that unblocks `SIGUSR1`, which Android
blocks by default so the ART "Signal Catcher" thread can `sigwait` on it. That
matters only for the CPython test suite.

### Where the stdlib and .py files live: assets, extracted at first run

From `Platforms/Android/testbed/app/build.gradle.kts`, the split is exact:

- **jniLibs** gets `libpython*.*.so` and `lib*_python.so` only.
- **assets** gets `python/lib/python3.X/` (the whole stdlib **including
  `lib-dynload/*.so`**), `python/include/python3.X/`, `site-packages/` (from
  `src/main/python` plus an optional `python.sitePackages` property), and a
  `cwd/` directory.

`MainActivity.extractAssets()` copies `assets/python` into
`context.filesDir/python` on every launch (it deletes and re-extracts), then
sets that as `PYTHONHOME`. So **extension modules are dlopened out of the app's
files dir, not out of jniLibs.** That is the officially blessed layout.

Gotcha worth stealing: AAPT auto-decompresses assets whose name ends in `.gz`,
so the gradle task renames `*.gz` -> `*.gz-` and `MainActivity` undoes it:

```kotlin
rename(""".*(\.gz|-)""", "$0-")          // build.gradle.kts
val outputName = name.replace(Regex("""(.*)-"""), "$1")   // MainActivity.kt
```

Second gotcha: the `_python` suffix on `libcrypto_python.so`,
`libssl_python.so`, `libsqlite3_python.so`. Android has system libraries with
those sonames; renaming avoids the linker resolving to the platform's copy.

### dlopen / ctypes on Android

- `_ctypes.cpython-3XX-aarch64-linux-android.so` ships in `lib-dynload`; ctypes
  works.
- `ctypes/__init__.py` special-cases Android: `pythonapi =
  PyDLL(sysconfig.get_config_var("LDLIBRARY"))` — i.e. **CPython does NOT use
  `CDLL(None)` on Android**, it loads `libpython3.X.so` by soname. Treat
  `CDLL(None)` as unreliable there and load by soname.
- `ctypes.util.find_library` on Android only looks in `/system/lib64` —
  it will never find your app's library. Pass the soname to `CDLL` directly:
  `ctypes.CDLL("libkaya.so")`.
- Namespace rules (https://android.googlesource.com/platform/bionic/+/master/android-changes-for-ndk-developers.md):
  apps may only link against public NDK libraries (enforced for API 24+); the
  app's own classloader namespace covers its `nativeLibraryDir` (jniLibs) and
  its data dir, which is why the official layout can dlopen `lib-dynload` out
  of `filesDir`. Since API 23 `RTLD_LOCAL` is honoured and is the default, so a
  library loaded by `System.loadLibrary` does **not** automatically expose its
  symbols to a later `dlopen`; each consumer should dlopen the library it needs
  by name rather than relying on the global scope.
- W^X (API 26+ for segment flags, tightened messaging in API 29): the rule is
  that a mapping must not be both writable and executable, and that untrusted
  apps targeting Android 10 cannot `execve()` files in their home directory.
  `dlopen()` of a file in the app's data dir is still permitted — which is what
  the official CPython Android layout depends on. Shipping `libkaya.so` in
  `jniLibs` sidesteps the question entirely.
- With `android:extractNativeLibs="false"` (the AGP default since AGP 4.2 /
  API 23+), jniLibs are loaded straight from the APK and must be uncompressed
  and 4096-byte aligned; `System.loadLibrary` and `dlopen("libkaya.so")` both
  work in that mode.

### Minimum API level — measured, not 21

PEP 738 originally proposed API 21. The **shipped** builds are compiled at
API 24: `android-env.sh` in the release package has
`: "${ANDROID_API_LEVEL:=24}"`, and the testbed's `minSdk` is read out of that
same file. Briefcase's Android template also pins `minSdkVersion` at 24 for its
own reasons ("Briefcase currently requires API Level 24 for the `pidof`
command, and the `--pid` argument to `adb logcat`").


---

## 5. Reference implementations

### BeeWare Briefcase — iOS

- Runtime: **BeeWare's own `Python-Apple-support` XCframework**, not (yet) the
  python.org one. That project's README says it builds Python 3.14 on `main`
  with 3.10-3.13 on branches, and that for iOS/tvOS/watchOS/visionOS it
  "compiles custom packages using official PEP 730 code, with additional
  patches backported and applied" (https://github.com/beeware/Python-Apple-support).
  macOS is a re-bundling of the official installer.
- Start-up: `main.m` from `briefcase-iOS-Xcode-template`. Same
  `PyPreConfig_InitIsolatedConfig` / `PyConfig_InitIsolatedConfig` shape as
  CPython's testbed, plus:
  - `setenv("LANG", "<locale>.UTF-8")` because iOS exports no `LANG`;
  - `preconfig.configure_locale = 1` (isolated config otherwise won't);
  - `config.module_search_paths_set = 1` and three explicit
    `PyWideStringList_Append` entries: `<home>/lib/python3.X`,
    `<home>/lib/python3.X/lib-dynload`, `<Resources>/app`;
  - `config.run_module` taken from the `MainModule` Info.plist key;
  - after init, `site.addsitedir(<Resources>/app_packages)` so `.pth` files in
    the third-party directory execute;
  - a `crash_dialog()` that formats the Python traceback into a UIAlertView,
    which is the practically useful bit — an uncaught Python exception on iOS
    is otherwise invisible.
- Layout: `app/` (your code), `app_packages.iphoneos/` and
  `app_packages.iphonesimulator/` (wheels, per-ABI), `Support/` (the
  XCframework). Third-party binary wheels must be iOS wheels; Briefcase runs
  the same `.so` -> `.framework` conversion over `app_packages`.

### BeeWare Briefcase — Android

Briefcase does **not** use the python.org Android package. Its generated
`app/build.gradle` applies `com.chaquo.python`, and `MainActivity.java` imports
`com.chaquo.python.Python` / `AndroidPlatform` and calls:

```java
Python.start(new AndroidPlatform(this));
Python py = Python.getInstance();
```

with the Python version and pip requirements declared in the gradle `python {}`
block. So on Android, Briefcase = **Chaquopy**. Its wheel index is
`https://chaquo.com/pypi-13.1/`. `minSdkVersion` is 24; ABIs are
`arm64-v8a, x86_64` for Python 3.12+ (plus `armeabi-v7a` for 3.11 and older).

### Chaquopy (the actual Android runtime under Briefcase)

- Current release 17.0.0 (2025-12-01); supports Python 3.10-3.14; `minSdk` 24;
  ABIs `armeabi-v7a, arm64-v8a, x86, x86_64` with 64-bit-only from Python 3.12.
  (https://chaquo.com/chaquopy/doc/current/android.html)
- The distinguishing mechanism: **Python modules are imported straight out of
  the APK** ("Python modules are usually loaded directly from the APK, and
  don't exist as separate files") through a custom importer; only data files
  and packages listed in `extractPackages` are written to the filesystem. That
  avoids the CPython-testbed pattern of copying the whole stdlib into
  `filesDir` on every launch.
- CPython and its supporting libraries are downloaded as Maven artifacts by the
  gradle plugin; a JNI bridge layer connects Java/Kotlin and Python objects.

### Kivy / python-for-android

- `PythonActivity` unpacks a `private.tar` (historically `private.mp3`, to dodge
  asset compression) from `assets/` into the app's files dir on first launch,
  sets `ANDROID_*` environment variables, `System.loadLibrary`s `libpython3.X.so`
  and friends (`PythonUtil.loadLibraries`), then **spawns a thread and runs the
  native entry point on it**.
- `bootstraps/common/build/jni/application/src/start.c` does
  `PyConfig_InitPythonConfig`, sets `module_search_paths_set = 1` with the
  zipped stdlib path plus the modules path, calls `Py_InitializeFromConfig`,
  and runs `bootstrap.py` via runpy. It also carries the comment
  `/* Do not issue an exit or the whole application will terminate instead of
  just the SDL thread */` — direct evidence that the interpreter is *not* on
  the Android main thread there.
- Third-party native packages need a "recipe" (a cross-compile shim); pure
  Python works unaided.

**What to crib for kaya:** CPython's own testbeds for the PyConfig sequence and
the iOS `.fwork` build phase; python-for-android for "Python on a worker
thread, host owns the main thread"; Chaquopy for the import-from-APK trick if
extraction latency ever matters.

---

## 6. Simulator and emulator support

Both are first-class, and this is verified against the artifacts, not just docs.

**iOS simulator: yes.** The 3.15.0rc1 XCframework I unpacked contains exactly
two slices:

```
Python.xcframework/ios-arm64/                     (device)
Python.xcframework/ios-arm64_x86_64-simulator/    (simulator, fat: arm64 + x86_64)
```

`build_utils.sh` selects the slice from `$EFFECTIVE_PLATFORM_NAME`
(`-iphonesimulator` vs device) and the per-arch stdlib from `$ARCHS`, so an
Xcode build for the simulator picks up the simulator lib-dynload automatically.
PEP 11 names `arm64-apple-ios-simulator` as the tier-3 simulator target;
CPython's own iOS CI runs the test suite on a simulator
(`python Platforms/Apple test iOS`, which picks an "SE-class" simulator).
The build system also supports `x86_64-apple-ios-simulator` as a `--host`
triple for Intel Macs.

**Android emulator: yes.** `x86_64-linux-android` is a tier-3 target with its
own official tarball at every release (21.8 MB for 3.14.7). CPython's Android
test script runs on an emulator by default, with a `--managed` mode that
provisions `aosp_atd` system images for `minVersion` and `maxVersion` devices.
Briefcase's SDK integration picks the emulator ABI from the host
(`x86_64` on Intel, `arm64-v8a` on Apple Silicon) and installs
`system-images;android-31;default;<abi>`.

Practical note for a kaya lane: an Apple Silicon host runs an `arm64-v8a`
emulator image, so the `x86_64` Android tarball is only needed if a lane runs
on an Intel host or deliberately tests the x86_64 ABI. Ship both in the APK's
`jniLibs` anyway — it costs ~26 MB and removes a whole class of "works on my
emulator" failure.

---

## 7. Known gotchas

### Threading — the important one for kaya

- **Nothing requires Python to own the process main thread.** The C-API docs
  make no such statement; CPython's only main-thread rule at the C level is
  that `Py_FinalizeEx()` "should be called in the same thread with the same
  interpreter active" as `Py_Initialize()`
  (https://docs.python.org/3/c-api/interp-lifecycle.html). python-for-android
  ships this shape in production: interpreter on the SDL worker thread, Java UI
  thread untouched.
- **Python's "main thread" becomes whichever thread called
  `Py_InitializeFromConfig`.** Everything the `signal` module calls the main
  thread refers to that: "this function can only be called from the main thread
  of the main interpreter; attempting to call it from other threads will cause
  a `ValueError`" (`signal.signal`, `signal.set_wakeup_fd`), and "Python signal
  handlers are always executed in the main Python thread of the main
  interpreter, even if the signal was received in another thread"
  (https://docs.python.org/3/library/signal.html).
- **Therefore: set `install_signal_handlers = 0`** when initializing on a
  secondary thread. The OS delivers process signals to an arbitrary thread; a
  Python-level handler installed from a non-main OS thread is at best useless
  and at worst racy. `PyConfig_InitIsolatedConfig` already defaults it to 0
  ("no signal handler is registered",
  https://docs.python.org/3/c-api/init_config.html) — it is the *testbeds* that
  turn it back on because they run test suites that need `SIGINT`.
- **GIL discipline.** The thread that ran `Py_InitializeFromConfig` holds the
  GIL when it returns. Any *other* thread (the UI thread, a Rust callback
  thread) that wants to touch Python objects must bracket with
  `PyGILState_Ensure()` / `PyGILState_Release()`. Any Python -> Rust call that
  blocks — and kaya's desktop shape has the guest's main thread blocked inside
  a C function running the UI loop — must release the GIL around the blocking
  region (`Py_BEGIN_ALLOW_THREADS` / `Py_END_ALLOW_THREADS`), or the interpreter
  is frozen for its whole duration. ctypes does this for you: a `CDLL` (as
  opposed to `PyDLL`) **releases the GIL around every foreign call**, which is
  exactly what kaya wants for calls into libkaya, and `PyDLL` is the variant
  that does not.
- **Callbacks are the sharp edge.** A `ctypes.CFUNCTYPE` callback invoked from
  a native thread reacquires the GIL automatically, but if that callback then
  needs to touch UI it must hop to the platform main thread
  (`DispatchQueue.main` / `Handler(Looper.getMainLooper())`), and if the
  calling native thread was never attached to the JVM on Android it must
  `AttachCurrentThread` first.
- **Free-threaded builds:** the official mobile artifacts are the GIL builds.
  There is no `t` (free-threaded) variant among the iOS/Android downloads.

### Process model

- **No fork, no subprocess, no multiprocessing** on either platform.
  `multiprocessing` is documented unavailable on both (iOS: "does not support
  any form of subprocessing, multiprocessing, or inter-process communication";
  Android: "does not support System V IPC API"). Subprocess creation is
  "either unsupported (Android) or cause[s] the process to lock up or crash
  (iOS)". Untrusted Android apps targeting API 29+ additionally cannot
  `execve()` files in their home directory.
- **No `curses`, no `readline`** on either platform (no usable `stdin`).
- **No REPL, no `python` binary, no `pip` at runtime** — embedded mode only.
  (all: https://docs.python.org/3/library/intro.html mobile availability)

### iOS-specific

- The App Store forbids executable binaries outside `Frameworks/`; every
  extension module must be converted to a framework and codesigned (§3).
- `write_bytecode = 0` is mandatory in practice: the bundle is signed and
  read-only, so `.pyc` writing would fail on every import. Pre-compile and ship
  `__pycache__` if startup time matters.
- No `LANG` in the environment; set it before `Py_PreInitialize` or the locale
  is wrong.
- The stdlib carries code that trips App Store automated review; CPython's iOS
  build auto-applies `Mac/Resources/app-store-compliance.patch`. Using the
  official XCframework means this is already done for you.
- Privacy manifests (`.xcprivacy`) are required for modules touching affected
  APIs; `_hashlib.xcprivacy` ships in the artifact.
- Console output is only visible via the Apple system log
  (`use_system_logger = 1`), i.e. Xcode / `log stream`, not stdout.

### Android-specific

- Min API 24 as built (`ANDROID_API_LEVEL:=24` in `android-env.sh`), despite
  PEP 738's original API 21 proposal.
- `TMPDIR` is not set by Android below API 33; Python needs it. Set it from
  Kotlin (`Os.setenv("TMPDIR", context.cacheDir.toString(), false)`).
- AAPT decompresses `*.gz` assets; rename around it (§4).
- Sonames collide with system libraries; the official package renames OpenSSL
  and sqlite to `*_python.so`.
- `ctypes.util.find_library` searches only `/system/lib[64]` — useless for app
  libraries. Load by soname.
- `RTLD_LOCAL` is the default and is honoured from API 23 on, so do not assume
  a library loaded by `System.loadLibrary` exposes its symbols to a later
  `dlopen`; and `ctypes.CDLL(None)` is not the Android idiom — CPython itself
  loads `libpython` by name there.
- `SIGUSR1` is blocked by default (ART's Signal Catcher thread `sigwait`s on
  it). Only matters if you use it.

### Version-specific bug worth knowing

`ctypes.CDLL(..., handle=...)` was silently ignored on POSIX in 3.13.10+ and
3.14.1+ (a refactor added a `_load_library()` that accepted `handle` and then
called `_dlopen()` anyway); fixed by PRs 143318 / 145172 / 145173
(https://github.com/python/cpython/issues/143304). Only affects code that
passes a pre-obtained handle — `CDLL(path)` and `CDLL(None)` are unaffected.

---

## 8. Recommended shape for kaya

Both platforms already have the app host and the Rust core built. The minimal
addition is: an interpreter, a stdlib tree, the guest `.py` files, and one
thread.

### Common decisions

1. **Target Python 3.15** and take the official artifacts. On Android they
   already exist for 3.14 stable, so Android could start today; on iOS the
   XCframework only exists in the 3.15 pre-release line, so pin 3.15 for both
   and keep one version across platforms (kaya's invariant 6 argues for it too
   — byte-identical guest output across lanes is easier with one interpreter
   version). Falling back to 3.14 on iOS means building the XCframework
   yourself or vendoring BeeWare's `Python-Apple-support`.
2. **Python runs on a worker thread; the UI host keeps the main thread.**
   Initialize with `install_signal_handlers = 0`. This is python-for-android's
   shape and nothing in CPython forbids it.
3. **The guest reaches libkaya through ctypes**, which is what the desktop
   binding already does — so the pure-Python binding is unchanged except for
   how it *finds* the library. Make that one function platform-dispatched:
   `CDLL(None)` on iOS, `CDLL("libkaya.so")` on Android, existing path logic
   elsewhere. `CDLL` (not `PyDLL`) releases the GIL per call, which is what you
   want for calls into the core.
4. **Strip `test/`, `idlelib`, `tkinter`, `turtledemo`** from the stdlib you
   ship — that is 172 MB of 233 MB on iOS and 37 MB of 60 MB on Android.
5. **Ship a pre-built `__pycache__`** for the stdlib and the guest code.
   `write_bytecode = 0` on iOS means every import compiles from source
   otherwise, on a phone CPU, at every launch.

### (a) iOS bundle

- Add `Python.xcframework` (from
  `https://www.python.org/ftp/python/3.15.0/python-3.15.0rc1-iOS-XCframework.tar.gz`,
  or the 3.15.0 final URL once it lands) to the Xcode project, "Embed & Sign".
- Add the "Process Python libraries" run-script phase after Copy Bundle
  Resources and before Embed Frameworks:
  `source $PROJECT_DIR/Python.xcframework/build/build_utils.sh; install_python Python.xcframework app`
  where `app/` holds the kaya Python binding plus the guest scene files. This
  is what performs the `.so` -> `.framework` + `.fwork` conversion and the
  per-module codesign; do not hand-roll it.
- Build settings: User Script Sandboxing = No, Framework Search Paths =
  `$(PROJECT_DIR)`, Header Search Paths =
  `"$(BUILT_PRODUCTS_DIR)/Python.framework/Headers"`, Quoted Include In
  Framework Header = No.
- **Link `libkaya.a` with `-Wl,-force_load`.** kaya's iOS lane already links
  the staticlib into the app executable; without `-force_load` (or
  `-all_load`), archive members whose symbols Swift never references are never
  pulled in, and `ctypes.CDLL(None)` finds nothing. Measured above: plain
  `-lkaya` gives `dlsym -> NULL`; `-Wl,-force_load` gives a callable symbol.
  Add a gate that greps the built executable with `nm -gU` for a known kaya
  export — this is exactly the class of failure kaya's invariant 3 wants a wall
  for, and it fails on the path nobody can avoid (the app won't start).
- From Swift/ObjC at launch, on a `Thread`/`DispatchQueue` that is not main:
  `PyPreConfig_InitIsolatedConfig` + `utf8_mode=1` + `configure_locale=1`,
  `PyConfig_InitIsolatedConfig` + `use_system_logger=1`, `buffered_stdio=0`,
  `write_bytecode=0`, `install_signal_handlers=0`, `home =
  <Resources>/python`, `module_search_paths_set=1` with
  `<home>/lib/python3.15`, `<home>/lib/python3.15/lib-dynload`,
  `<Resources>/app`. `setenv("LANG", ...)` before pre-init. Then import the
  scene module rather than calling `Py_RunMain`.
- Keep BeeWare's `crash_dialog` idea in some form: an uncaught Python exception
  on iOS otherwise leaves no trace a lane can read. Route the formatted
  traceback into whatever the harness already reads.

### (b) Android APK

- Take `python-3.15.0-<abi>-linux-android.tar.gz` for **both** `arm64-v8a` and
  `x86_64` (the emulator lane needs whichever matches the host image; shipping
  both is ~26 MB and removes the question).
- Gradle, copying CPython's testbed split exactly:
  - `prefix/lib/libpython3.15.so` and `lib*_python.so` -> `jniLibs/<abi>/`
  - `prefix/lib/python3.15/**` (minus `test`, `idlelib`, `tkinter`) ->
    `assets/python/lib/python3.15/`
  - kaya's Python binding + guest scenes -> `assets/python/lib/python3.15/site-packages/`
  - rename `*.gz` -> `*.gz-` on the way in.
  - `libkaya.so` is already in `jniLibs/<abi>/` for the JNI tier; nothing new.
- Kotlin, off the main thread: extract `assets/python` to
  `filesDir/python` (guard on a version stamp instead of the testbed's
  delete-and-re-extract, which pays the full copy every launch), set
  `TMPDIR`, `System.loadLibrary("python3.15")` — or let the JNI shim's
  `DT_NEEDED` do it — then call a tiny JNI shim that does
  `PyConfig_InitPythonConfig`, `home = filesDir/python`,
  `install_signal_handlers = 0`, `Py_InitializeFromConfig`, and imports the
  scene module.
- The JNI shim is the only new native code: a handful of lines, built by the
  existing NDK/CMake or added to the existing Rust cdylib as another
  `#[no_mangle]` JNI export if you would rather not add a CMake target.
- In Python, `ctypes.CDLL("libkaya.so")` — by soname, never through
  `ctypes.util.find_library`.

### What this does NOT need

No Briefcase, no Chaquopy, no buildozer, no scaffolding tool. Everything above
is either an official python.org artifact plus its own `build_utils.sh`, or
about 40 lines of glue per platform modelled on CPython's testbeds. The one
piece with no upstream equivalent is the `-force_load` requirement on iOS,
because kaya links its core statically where every reference implementation
ships a dylib.

### Open risks to measure, not assume

1. `ctypes.CDLL(None)` reaching `libkaya.a` symbols has been proven on macOS
   here, not yet on a real iOS simulator run. Prove it on the simulator lane
   before building anything on top of it.
2. Startup cost of extracting ~15 MB of stdlib into `filesDir` on the Android
   emulator, and of source-compiling the stdlib on iOS if `__pycache__` is not
   pre-shipped. Both are lane-duration risks (kaya's invariant 8).
3. Whether the guest's blocking "run the UI loop" entry point can be replaced
   cleanly on mobile without diverging the Python binding's observable
   semantics from the other seven languages (invariant 1). That is a design
   question for the binding, not a CPython question.

---

## Sources

Official:
- https://peps.python.org/pep-0011/ (tiers; raw text checked at
  https://raw.githubusercontent.com/python/peps/main/peps/pep-0011.rst)
- https://peps.python.org/pep-0730/ (iOS)
- https://peps.python.org/pep-0738/ (Android)
- https://docs.python.org/3/using/ios.html
- https://docs.python.org/3/using/android.html
- https://docs.python.org/3/library/intro.html (mobile availability)
- https://docs.python.org/3/c-api/init_config.html
- https://docs.python.org/3/c-api/interp-lifecycle.html
- https://docs.python.org/3/library/signal.html
- https://www.python.org/downloads/ , /downloads/ios/ , /downloads/android/
- https://www.python.org/downloads/release/python-3147/
- https://www.python.org/downloads/release/python-3150rc1/
- https://www.python.org/ftp/python/3.14.7/ (directory listing: no iOS artifact)

CPython source tree (paths as of 2026-08; mobile support moved under
`Platforms/` in the 3.15 cycle — it was `iOS/` and `Android/` at the repo root
in 3.14):
- `Platforms/Apple/iOS/README.md`
- `Platforms/Apple/testbed/TestbedTests/TestbedTests.m`
- `Platforms/Apple/testbed/Python.xcframework/build/utils.sh`
- `Platforms/Android/README.md`
- `Platforms/Android/testbed/app/build.gradle.kts`
- `Platforms/Android/testbed/app/src/main/c/main_activity.c`
- `Platforms/Android/testbed/app/src/main/java/org/python/testbed/MainActivity.kt`
- `android-env.sh` from the 3.14.7 aarch64 release package (`ANDROID_API_LEVEL:=24`)
- `ctypes/__init__.py`, `ctypes/util.py`, `_apple_support.py` from the
  3.15.0rc1 iOS XCframework

Reference implementations:
- https://github.com/beeware/Python-Apple-support
- https://github.com/beeware/briefcase (its iOS xcode and android gradle platform modules)
- https://github.com/beeware/briefcase-iOS-Xcode-template (`main.m`)
- https://github.com/beeware/briefcase-android-gradle-template (`app/build.gradle`, `MainActivity.java`)
- https://chaquo.com/chaquopy/doc/current/android.html
- https://github.com/kivy/python-for-android (`bootstraps/common/build/jni/application/src/start.c`, `PythonUtil.java`)

Platform:
- https://android.googlesource.com/platform/bionic/+/master/android-changes-for-ndk-developers.md
- https://developer.android.com/about/versions/10/behavior-changes-10
- https://developer.apple.com/forums/thread/711730 (iOS dlopen scope)
- https://github.com/python/cpython/issues/143304 (CDLL handle regression)

Measured locally on this machine, 2026-08-28 (macOS, Apple Silicon):
- unpacked `python-3.15.0rc1-iOS-XCframework.tar.gz` and
  `python-3.14.7-aarch64-linux-android.tar.gz`; all sizes in §2 are `du`/`ls`
  output, not doc claims.
- `dlopen(NULL)` + `dlsym` against a symbol from a static archive: NULL with a
  plain `-lfoo` link, callable with `-Wl,-force_load`.
- `ctypes.CDLL(None).Py_GetVersion()` returned `b'3.14.7 ...'` under a `python3`
  whose only `otool -L` entry is `libSystem.B.dylib`.
