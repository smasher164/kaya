# Running JavaScript on Android without an interpreter (JIT-capable engines)

Research date: 2026-09-02. Every claim below carries a URL; every status claim carries the
date the source was read (all reads are 2026-09-02 unless stated).

Constraint being tested: kaya's JS/TS guest packs binary wire records into
Uint8Array/DataView and calls a Rust C-ABI shared library (libkaya) through native
functions, on a dedicated app thread that is NOT the Android UI thread. The engine must
(a) run off the UI thread, (b) call native code, (c) exchange raw byte buffers with
zero or near-zero copying.

_(sections filled in progressively below)_

## 1. V8 embedding on Android in 2026 — what actually exists

### The Kudo prebuilts (`v8-android*` on npm, `org.chromium:v8-android` AAR inside)

Kudo Chien's `v8-android-buildscripts` publishes four flavours of a single
`libv8android.so`, wrapped in an AAR that is shipped *inside an npm tarball*
(there is no Maven Central / maven.google.com coordinate — the AAR lives at
`dist/org/chromium/v8-android/<ver>/v8-android-<ver>.aar` in the npm package, and
consumers add the node_modules path as a local Maven repo).
Repo: https://github.com/Kudo/v8-android-buildscripts (read 2026-09-02: not archived,
77 stars, BSD-2-Clause, **last commit on the default branch 2023-04-23**, `pushed_at`
2024-01-26 — i.e. no source change in over two years).

All four npm packages sit at **version 11.1000.4, last published 2023-08-20**
(npm registry metadata, read 2026-09-02, e.g.
https://registry.npmjs.org/v8-android). That is V8 11.10 — roughly Chrome 110-era.
V8 today is far past that; these prebuilts are three years stale.

Measured directly (downloaded the npm tarballs 2026-09-02, unzipped the AAR, `arm64-v8a/libv8android.so`):

| npm package | flavour | arm64-v8a .so, uncompressed | same, deflated in the AAR/APK | npm unpackedSize (all 4 ABIs) |
|---|---|---|---|---|
| `v8-android` | **lite mode = JITLESS**, Intl on | 23,040,248 B = **21.97 MiB** | 8,202,995 B = 7.82 MiB | 34.4 MB |
| `v8-android-jit` | **JIT on**, Intl on | 24,918,792 B = **23.76 MiB** | 8,950,170 B = 8.54 MiB | 37.5 MB |
| `v8-android-nointl` | lite mode = JITLESS, no Intl | (not downloaded) | — | 20.5 MB |
| `v8-android-jit-nointl` | **JIT on**, no Intl | 15,507,808 B = **14.79 MiB** | 5,456,399 B = 5.20 MiB | 23.6 MB |

**This corroborates the project's previously measured 21.97 MiB exactly** — and identifies
what was measured: 23,040,248 / 1048576 = 21.97 MiB is the **`v8-android` (lite mode,
JITLESS)** arm64 .so. The JIT build of the same V8 with Intl is 23.76 MiB (+1.79 MiB);
dropping Intl and keeping the JIT gives **14.79 MiB** (5.20 MiB compressed), which is the
cheapest JIT-capable V8 of the four. A ~50 KB `snapshot_blob.bin` ships alongside
(`v8_use_external_startup_data=true` on Android), per ABI.

Licence: BSD-2-Clause on the package metadata; the binary is V8 itself, so V8's own
BSD 3-clause plus Chromium's third-party notices apply in practice
(https://github.com/v8/v8/blob/main/LICENSE).

### `react-native-v8`

https://github.com/Kudo/react-native-v8 — read 2026-09-02: not archived, 961 stars, MIT,
**last commit 2024-08-20**, npm `react-native-v8` **latest 2.5.1, published 2024-08-20**
(https://registry.npmjs.org/react-native-v8). It is a thin RN JSI adapter over the
prebuilts above; it is not a general embedding library and it has had no release in
just over two years as of today.

### J2V8 — effectively dead upstream, alive only as a vendor fork

https://github.com/eclipsesource/J2V8 (read 2026-09-02): not archived, 2,628 stars, EPL-1.0.
Last commits are dated **2025-11-14** (a README/PUBLISHING doc refactor), and there are
**zero GitHub releases and zero git tags** on the repo (GitHub API `/releases` and `/tags`
both return `[]`, read 2026-09-02). On Maven Central, `com.eclipsesource.j2v8:j2v8`'s last
publish is **6.2.1, 2021-08-10** (https://search.maven.org/solrsearch/select?q=g:com.eclipsesource.j2v8 ,
read 2026-09-02). Treat upstream J2V8 as dead: five years without a release, bundling a V8
from the 7.x era.

The only maintained descendant is Intuit's fork, published for their "Player" product as
`com.intuit.playerui:j2v8-android`. Latest on Maven Central is **0.12.0-next.2, 2025-06-04**
(a `-next` prerelease); the last non-prerelease is **0.11.2, 2025-05-21** (Maven Central
search, read 2026-09-02). That is a product-internal artifact, versioned to Intuit's Player
release train, not a general-purpose engine distribution.

### nodejs-mobile — one release behind Node EOL

https://github.com/nodejs-mobile/nodejs-mobile (read 2026-09-02): not archived, 869 stars.
Last **release v18.20.4, published 2024-10-07**; last commit on the default branch
**2025-11-13** ("tools: update android builds to use 16kb page size"). Node.js 18 itself went
end-of-life 2025-04-30 (https://github.com/nodejs/release#release-schedule). So the shipped
artifact is a Node whose upstream is EOL and whose last binary is nearly two years old.

Sizes, read out of the release zip's central directory over HTTP range requests (2026-09-02,
https://github.com/nodejs-mobile/nodejs-mobile/releases/download/v18.20.4/nodejs-mobile-v18.20.4-android.zip ,
57,287,354 B):

| entry | uncompressed | stored in zip |
|---|---|---|
| `bin/arm64-v8a/libnode.so` | 62,475,584 B = **59.58 MiB** | 18,232,894 B = 17.39 MiB |
| `bin/armeabi-v7a/libnode.so` | 58,720,948 B = 56.00 MiB | 17,951,029 B = 17.12 MiB |
| `bin/x86_64/libnode.so` | 65,361,944 B = 62.33 MiB | 18,945,189 B = 18.07 MiB |

That is V8 with JIT plus libuv plus the whole Node standard library in one .so — about 2.5x
the arm64 cost of the bare `v8-android-jit` engine. It buys a real `require`/ESM loader and
Node's `Buffer`, which is exactly the API surface a node-targeting binding already uses.

### The `//v8:v8_monolith` route (build V8 yourself)

V8's own embedding documentation points at building `v8_monolith` and linking it statically:
https://v8.dev/docs/embed (read 2026-09-02) and the Android-specific build docs at
https://v8.dev/docs/cross-compile-arm and https://v8.dev/docs/build-gn . This is what
`v8-android-buildscripts` and J2V8 both do underneath. It is entirely viable and it is the
only route that gets a *current* V8 onto Android, but it costs a depot_tools/gn/ninja
checkout (multi-GB) and a CI job per ABI; nothing prebuilt and current exists to shortcut it
(see section 7 on rusty_v8, which is the closest thing).

## 2. Is the JIT actually on in these artifacts? And does Android permit it?

### The flags, from V8's own build files

`v8_jitless = v8_enable_lite_mode` — V8's `BUILD.gn` line 477
(https://github.com/v8/v8/blob/main/BUILD.gn , read 2026-09-02). Turning on lite mode turns
on jitless; the assert at lines 720-724 then forces "Sparkplug, Maglev, Turbofan and Wasm are
not available in jitless mode", and `gni/v8.gni` line 337 sets
`v8_enable_webassembly = !v8_enable_lite_mode`
(https://github.com/v8/v8/blob/main/gni/v8.gni , read 2026-09-02).

What `--jitless` means, in V8's own words: "V8 switches into an interpreter-only mode based on
our existing technology: all JS user code runs through the Ignition interpreter, and regular
expression pattern matching is likewise interpreted."
(https://v8.dev/blog/jitless , published 2019-03-13, read 2026-09-02). **A jitless V8 is an
interpreter by V8's own definition** — so it fails the maintainer's rule, and its cost is
published: Speedometer 2.0 about 40% slower, the Web Tooling Benchmark 80% slower, a YouTube
living-room browsing session only 6% slower. Lite mode goes further than jitless by also
dropping feedback vectors, for "a 22% reduction in typical web page heap size"
(https://v8.dev/blog/v8-lite , published 2019-09-12, read 2026-09-02).

### Which Kudo artifact is which — proven from the CI matrix, not inferred

`.github/workflows/android.yml` (read 2026-09-02,
https://github.com/Kudo/v8-android-buildscripts/blob/main/.github/workflows/android.yml):

```
variant: [intl, nointl, jit-intl, jit-nointl]
NO_INTL: ${{ contains(matrix.variant, 'nointl') }}
NO_JIT:  ${{ !contains(matrix.variant, 'jit') }}
```

and `scripts/build.sh` (same repo):

```
if [[ ${NO_JIT} = "true" ]]; then
  GN_ARGS_BASE="${GN_ARGS_BASE} v8_enable_lite_mode=true"
fi
```

So **`v8-android` and `v8-android-nointl` are built `v8_enable_lite_mode=true`, i.e. jitless
interpreters**, and only `v8-android-jit` / `v8-android-jit-nointl` carry the JIT. The npm
package naming is exactly what it looks like. `scripts/env.sh` additionally hard-sets
`NO_JIT=true` for every non-Android platform, which is why the sibling `v8-ios` package is
jitless.

I confirmed this on the shipped binaries rather than trusting the build files: string counts
in `jni/arm64-v8a/libv8android.so` (measured 2026-09-02) are `WebAssembly` 9 / `wasm` 81 /
`liftoff` 0 in `v8-android`, versus `WebAssembly` 88 / `wasm` 964 / `liftoff` 8 in
`v8-android-jit`. Liftoff is V8's WebAssembly baseline *compiler*; its total absence from the
plain build, together with the near-total absence of Wasm, is the fingerprint of
`v8_enable_lite_mode=true` (which forces `v8_enable_webassembly=false`).

**Consequence for the 21.97 MiB figure**: the number this project measured is the *jitless*
build. The JIT-capable equivalent is `v8-android-jit` at 23.76 MiB arm64 (+8%), or
`v8-android-jit-nointl` at 14.79 MiB if `Intl` can be dropped — which is *smaller* than what
was already measured, while adding the JIT.

### Android permits JIT in a normal app process — the policy line

AOSP `system/sepolicy/private/app.te`, lines 188-189 (read 2026-09-02,
https://android.googlesource.com/platform/system/sepolicy/+/refs/heads/main/private/app.te):

```
# WebView and other application-specific JIT compilers
allow appdomain self:process execmem;
```

`execmem` is SELinux's permission for anonymous executable memory (mapping `PROT_EXEC` on
memory not backed by a file, and `mprotect`-ing writable pages executable). It is granted to
the `appdomain` attribute, which every zygote-spawned app domain carries via the
`app_domain()` macro in `public/te_macros`
(https://android.googlesource.com/platform/system/sepolicy/+/refs/heads/main/public/te_macros ,
read 2026-09-02) — including `isolated_app`, whose `private/isolated_app.te` calls
`app_domain(isolated_app)`. The comment naming JIT compilers is the policy's stated intent.
This is the structural difference from iOS, and it is why "no interpreted JS" is satisfiable
on Android in a way it is not on iOS.

The Android 10 W^X change is about **files, not anonymous memory**: "Execution of files from
the writable app home directory is a W^X violation... Untrusted apps that target Android 10
cannot invoke `execve()` directly on files within the app's home directory... apps that target
Android 10 cannot in-memory modify executable code from files which have been opened with
`dlopen()`... because the library cannot have been mapped `PROT_EXEC` through a writable file
descriptor"
(https://developer.android.com/about/versions/10/behavior-changes-10 , read 2026-09-02).
A JIT that allocates anonymous RW memory, writes code, and `mprotect`s it to RX is unaffected
by that rule and is covered by `execmem`. Separately, Android 10 maps *system* libraries'
text execute-only, which only breaks apps that try to *read* their own `.text`
(https://developer.android.com/about/versions/10/behavior-changes-all , read 2026-09-02).

Memory cost of keeping the JIT: V8 measured jitless as a **1.7% median decrease** in heap size
for a representative set of websites (https://v8.dev/blog/jitless), i.e. turning the JIT off
buys almost no heap. The 22% figure belongs to *lite mode*, which pays for it by also throwing
away the type feedback vectors (https://v8.dev/blog/v8-lite). So on Android the JIT is close
to free in memory and expensive to remove in speed.

## 3. jsc-android — the JIT is ON (baseline only), and the artifact is small

Repo: https://github.com/react-native-community/jsc-android-buildscripts (read 2026-09-02:
not archived, 1,069 stars, BSD-2-Clause, last commit **2025-10-19**, `pushed_at` 2026-03-01 —
the most recently touched of the prebuilt-engine projects in this report).

**Distribution moved off npm.** The npm package `jsc-android` still says
`latest = 250231.0.0, published 2023-02-05` (https://registry.npmjs.org/jsc-android , read
2026-09-02). The live artifact is on Maven Central:
`io.github.react-native-community:jsc-android` and `...:jsc-android-intl`, **latest 2026004.0.1,
`lastUpdated` 2024-11-29**
(https://repo1.maven.org/maven2/io/github/react-native-community/jsc-android/maven-metadata.xml ,
read 2026-09-02). That is the coordinate `@react-native-community/javascriptcore` depends on
(`implementation("io.github.react-native-community:jsc-android:2026004.+")`,
https://github.com/react-native-community/javascriptcore/blob/main/android/build.gradle.kts ,
read 2026-09-02) — the RN 0.79+ opt-in JSC package, npm `@react-native-community/javascriptcore`
**0.2.0, published 2025-03-24**, repo last commit 2026-02-12.

### The JIT flags, from the build script

`scripts/compile/jsc.sh` (https://github.com/react-native-community/jsc-android-buildscripts/blob/main/scripts/compile/jsc.sh , read 2026-09-02):

```
if [[ "$ARCH_NAME" = "i686" ]]; then
    JSC_FEATURE_FLAGS=" -DENABLE_JIT=OFF -DENABLE_C_LOOP=ON "
else
    JSC_FEATURE_FLAGS=" -DENABLE_JIT=ON  -DENABLE_C_LOOP=OFF "
fi
... build-webkit --jsc-only --jit --no-webassembly ...
  -DENABLE_DFG_JIT=OFF
  -DENABLE_FTL_JIT=OFF
```

Plainly: **on arm64-v8a, armeabi-v7a and x86_64 the JIT is ON and the C-loop interpreter is
OFF; only 32-bit x86 (i686) is built jitless with `--cloop`.** But the optimizing tiers are
off — `ENABLE_DFG_JIT=OFF`, `ENABLE_FTL_JIT=OFF` — so the pipeline is the assembly LLInt plus
JSC's **baseline JIT**, and nothing above it. WebAssembly is off entirely. So jsc-android is
*not* an interpreter in the sense the ruling cares about (it emits native code at runtime),
but it is also not a top-tier optimizing engine; it is roughly "always-baseline". This has
been the shape since at least 2019-12-18 (commit `dcf1419b`); the all-JIT-off state
(commit `4399436b`, "Disable all JIT (#108)", 2019-06-03) was reverted long before the current
artifacts.

### Sizes (measured 2026-09-02 from the Maven Central AARs)

| artifact 2026004.0.1 | arm64-v8a `libjsc.so` uncompressed | stored in AAR/APK |
|---|---|---|
| `jsc-android` (no Intl) | 10,173,344 B = **9.70 MiB** | 3,550,934 B = 3.39 MiB |
| `jsc-android-intl` | 20,100,800 B = **19.17 MiB** | 7,065,185 B = 6.74 MiB |

(armeabi-v7a 7.57 MiB / x86 8.56 MiB / x86_64 10.36 MiB for the non-Intl build.)
The older npm 250231.0.0 was even smaller: 5,823,656 B = 5.55 MiB arm64 non-Intl.

**The non-Intl JIT build is 9.70 MiB against `v8-android-jit-nointl`'s 14.79 MiB** — JSC is
about a third smaller than the cheapest JIT-capable V8, and about 43% of the jitless
`v8-android` this project already measured at 21.97 MiB.

### Why this matters for kaya's byte-buffer requirement

The 2026004.0.1 AAR ships a **prefab** module (`prefab/modules/jsc/`, `abi.json`:
`api 24, ndk 27, stl c++_shared`), so an NDK CMake build consumes headers and the `.so`
directly with `find_package`. The headers include `JavaScriptCore/JSTypedArray.h`, and the
shipped arm64 `.so` exports `JSObjectMakeTypedArrayWithBytesNoCopy`,
`JSObjectMakeArrayBufferWithBytesNoCopy`, `JSObjectGetTypedArrayBytesPtr` and
`JSObjectGetArrayBufferBytesPtr` (symbol names confirmed present in the binary, 2026-09-02).
That is exactly the "hand the engine a Rust-owned buffer as a `Uint8Array` without copying"
primitive, plus `JSObjectMakeFunctionWithCallback` for calling native code — the whole surface
kaya's wire packing needs, in a plain C API with no JNI in the path.

## 4. Hermes in 2026 — there IS an arm64 JIT, and it is off by default

Repo (read 2026-09-02): https://github.com/facebook/hermes — 11,283 stars, MIT, commits on
**2026-09-02** (very active). The last GitHub *release* is v0.13.0, 2024-08-16, and npm
`hermes-engine` stopped at 0.11.0 (2022-01-27) — Hermes stopped shipping through those
channels; it ships inside React Native.

**The `main` branch has no JIT at all**: of 11,806 tree entries, **zero paths match "jit"**
(GitHub trees API, `facebook/hermes` `main`, read 2026-09-02). `doc/Design.md` describes the
classical design — bytecode plus "the VM will deserialize the bytecode from the file and
interpret it".

**But `main` is no longer what React Native ships.** React Native's repo has moved to
https://github.com/react/react-native (read 2026-09-02; `facebook/react-native` 301-redirects
there; 126,481 stars, pushed 2026-09-03), and
`packages/react-native/sdks/hermes-engine/version.properties` reads
`HERMES_VERSION_NAME=260318099.0.1`. The Hermes branch `260318099.0.0-stable` **does** contain
the JIT: `lib/VM/JIT/arm64/{JIT.cpp,JitEmitter.cpp,JitHandlers.cpp}`,
`include/hermes/VM/JIT/`, `external/asmjit`, and hermes/tools/shermes — i.e. **React Native now
ships the Static Hermes (`static_h`) lineage**, "Hermes V1", not the old `main` engine.

### Is the JIT on for Android?

The platform gate, `include/hermes/VM/JIT/Config.h` (branch `static_h`, read 2026-09-02,
https://github.com/facebook/hermes/blob/static_h/include/hermes/VM/JIT/Config.h):

```
#if !defined(HERMESVM_JIT) && (defined(__aarch64__) || defined(_M_ARM64)) && \
    (!defined(HERMESVM_COMPRESSED_POINTERS) || defined(HERMESVM_CONTIGUOUS_HEAP))
#define HERMESVM_JIT 1
```

with a preceding block that disables it on Apple platforms other than macOS/Catalyst. So
**Android arm64 is an eligible target** and iOS is deliberately not.

The build default, in both `static_h`'s and the RN branch's `CMakeLists.txt` (line 304 on
`260318099.0.0-stable`, read 2026-09-02):

```
# 0: JIT is disabled / 1: enabled if supported by the platform / 2: enabled
set(HERMESVM_ALLOW_JIT 0 CACHE STRING "JIT mode: 0 (off), 1 (auto) or 2 (force on)")
```

And React Native's Android build passes **no `-DHERMESVM_ALLOW_JIT` at all**
(https://github.com/react/react-native/blob/main/packages/react-native/ReactAndroid/hermes-engine/build.gradle.kts ,
read 2026-09-02 — the CMake argument list is `HERMES_IS_ANDROID`, `ANDROID_STL`,
`ANDROID_PIE`, `ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES`, `IMPORT_HOST_COMPILERS`, `JSI_DIR`,
`HERMES_BUILD_SHARED_JSI`, `HERMES_RELEASE_VERSION`, `CMAKE_INTERPROCEDURAL_OPTIMIZATION`,
`HERMES_ENABLE_INTL`, `HERMESVM_HEAP_HV_MODE`, target `hermesvm`).

**Conclusion: the Hermes shipped in React Native on Android in 2026 is still a pure bytecode
interpreter — the JIT source is in the tree, arm64-capable, and compiled out.** A custom build
with `-DHERMESVM_ALLOW_JIT=1` would turn it on for Android arm64 (and only arm64: there is no
armv7 or x86_64 JIT emitter — the emitter directory is `arm64/` only).

Hermes' own summary of its modes, `doc/blog/2025-11-02-hermes-compilation-runtime-modes.md`
(2025-11-02, read 2026-09-02): AOT to bytecode, AOT to native, plus runtime modes "Native
execution / Bytecode interpreter / Lazy compilation / **Baseline JIT (bytecode to native) of
frequently executed functions**". It is a baseline JIT, not an optimizing one. Development is
current: `doc/superpowers/plans/2026-08-18-jitemitter-split.md` is dated 2026-08-18, and the
260318099.0.0 release notes (2026-06-05) list "expanded JIT coverage".

### Static Hermes / `shermes` — Android specifics only

- **Targets**: `shermes` compiles JS to C and then shells out to a C compiler named by `$CC`
  (hermes/tools/shermes/compile.cpp, read 2026-09-02), with extra flags via `-Xcc`. There is no
  `--target` flag. `doc/CrossCompilation.md` documents building the *Hermes runtime* for
  Android (`-DANDROID_ABI=arm64-v8a` with the NDK toolchain file) and an ARM32 recipe, but
  there is no packaged Android cross-compilation path for `shermes` itself — you point `CC` at
  the NDK clang and link a Hermes runtime you built for the same ABI.
- **Artifact shape**: `OutputLevelKind` supports `-emit-c`, `-S` (assembly), `-c` (object
  file), **shared object** (`-fPIC -shared`, `-dynamiclib` on Apple), and executable
  (hermes/tools/shermes/compile.h and compile.cpp, read 2026-09-02). So **yes, `shermes` can
  produce a `.so`** — which is the shape an Android app can `System.loadLibrary`.
- **Does the RN Android pipeline use it?** No. `BundleHermesCTask.kt`
  (https://github.com/react/react-native/blob/main/packages/gradle-plugin/react-native-gradle-plugin/src/main/kotlin/com/facebook/react/tasks/BundleHermesCTask.kt ,
  read 2026-09-02) runs `hermesc ... -emit-binary -out <bundle>.hbc` — AOT to **bytecode**,
  interpreted at runtime. AOT-to-native has not shipped in React Native's Android build.

## 5. Android WebView as a JS engine off the UI thread — it cannot be done

The `WebView` reference (https://developer.android.com/reference/android/webkit/WebView , read
2026-09-02) attaches the same note to the constructor and to essentially every public method,
`addJavascriptInterface` included: **"This method must be called on the thread that originally
created this UI element. This is typically the main thread of your app."** The class also
exposes `getWebViewLooper()` — "Returns the Looper corresponding to the thread on which WebView
calls must be made" — which is the mechanical statement of the same rule: a WebView is pinned
to one Looper thread, and in a real app that is the UI thread (a WebView is a `View`; it has to
be attached to a window to render, and `evaluateJavascript` is documented "This method must be
called on the UI thread").

`addJavascriptInterface(Object, String)` is also unsuitable for kaya's data shape:

- Its own doc says "The Java object's fields are not accessible" and that from API 17 up only
  methods annotated `@JavascriptInterface` are exposed. The marshalling is limited to JavaScript
  primitives and strings — **there is no `ArrayBuffer`, `Uint8Array`, or `byte[]` marshalling
  across the bridge**; binary would have to be base64'd into a String, which is exactly the cost
  the wire format exists to avoid.
- Google's guidance is a hard warning, not a caveat: "Using `addJavascriptInterface` lets
  JavaScript control your Android app... don't use `addJavascriptInterface()` unless you wrote
  all of the HTML and JavaScript that appears in your `WebView`"
  (https://developer.android.com/develop/ui/views/layout/webapps/webview , read 2026-09-02).
  The docs now point at "Access native APIs with JSBridge" as the modern replacement.
- Threading is inverted from what you would want: "The object that is bound to your JavaScript
  runs in another thread and not in the thread in which it is constructed" (same page) — i.e.
  the *Java side* of the bridge is called on a private WebView background thread, while every
  call *into* the WebView must be on the UI thread.

So a WebView cannot host kaya's app thread. It fails requirement (a) outright.

## 6. `androidx.javascriptengine` — real, current, and the wrong shape for a native binding

### Version and channel

**1.1.0 stable, released 2026-05-06** (https://developer.android.com/jetpack/androidx/releases/javascriptengine ,
read 2026-09-02). 1.0.0 shipped 2025-07-02; 1.1.0-alpha01 2026-03-11, alpha02 2026-03-25,
beta01 2026-04-08, rc01 2026-04-22. So it is on the stable channel and actively developed.

### What backs it

An **out-of-process** JavaScript engine supplied by the WebView package. Chromium's
`android_webview/js_sandbox/service/js_sandbox_isolate.cc` uses **V8 directly** through
`gin::IsolateHolder`, `gin::V8Platform`, `gin::ArrayBufferAllocator`
(https://chromium.googlesource.com/chromium/src/+/refs/heads/main/android_webview/js_sandbox/service/js_sandbox_isolate.cc ,
read 2026-09-02). The service is declared in the WebView manifest as

```
<service android:name="org.chromium.android_webview.js_sandbox.service.JsSandboxService0"
    android:process=":js_sandboxed_process0"
    android:isolatedProcess="true"
    android:externalService="true" ... />
```

(https://chromium.googlesource.com/chromium/src/+/refs/heads/main/android_webview/nonembedded/java/AndroidManifest.xml ,
read 2026-09-02). It is available "on API 26 and above if the WebView implementation supports
it" and must be probed with `JavaScriptSandbox.isSupported()`.

**Is the JIT on there?** Yes. It is WebView's own V8 — the process the AOSP SELinux comment
names when granting `execmem` — and an `isolatedProcess` service still carries the `appdomain`
attribute (`app_domain(isolated_app)` in `private/isolated_app.te`), so `execmem` is granted.
The decisive API-level evidence is `JS_FEATURE_WASM_COMPILATION`, which enables
`WebAssembly.compile(ArrayBuffer)` inside the isolate: WebAssembly is compiled out of any
jitless/lite V8 (`v8_enable_webassembly = !v8_enable_lite_mode`), so its presence rules the
build out of lite mode.

### The full API surface (from the 1.1.0 reference docs, read 2026-09-02)

`JavaScriptSandbox` (https://developer.android.com/reference/androidx/javascriptengine/JavaScriptSandbox):
`isSupported()`, `createConnectedInstanceAsync(Context)`, `createIsolate()`,
`createIsolate(IsolateStartupParameters)`, `isFeatureSupported(String)`, `close()`. Feature
constants: `JS_FEATURE_CONSOLE_MESSAGING`, `JS_FEATURE_EVALUATE_FROM_FD`,
`JS_FEATURE_EVALUATE_WITHOUT_TRANSACTION_LIMIT`, `JS_FEATURE_ISOLATE_MAX_HEAP_SIZE`,
`JS_FEATURE_ISOLATE_TERMINATION`, **`JS_FEATURE_MESSAGE_PORTS` (added 1.1.0)**,
`JS_FEATURE_PROMISE_RETURN`, `JS_FEATURE_PROVIDE_CONSUME_ARRAY_BUFFER`,
`JS_FEATURE_WASM_COMPILATION`.

`JavaScriptIsolate` (https://developer.android.com/reference/androidx/javascriptengine/JavaScriptIsolate):
`evaluateJavaScriptAsync(String) -> ListenableFuture<String>`,
`evaluateJavaScriptAsync(AssetFileDescriptor|ParcelFileDescriptor) -> ListenableFuture<String>`,
`provideNamedData(String name, byte[] inputBytes)`,
**`createMessageChannel(String name, Executor, MessagePortClient) -> MessagePort` (added 1.1.0)**,
`setConsoleCallback(...)`, `clearConsoleCallback()`, `addOnTerminatedCallback(...)`,
`removeOnTerminatedCallback(...)`, `close()`. That is the entire surface — there is no
`addJavascriptInterface` analogue and no way to register a host function.

`MessagePort` (added 1.1.0): `postMessage(Message)` — "can be called from any thread" — and
`close()`. `Message` (added 1.1.0) carries `TYPE_STRING = 0` or `TYPE_ARRAY_BUFFER = 1`, built
with `createStringMessage(String)` / **`createArrayBufferMessage(byte[])`**, read back with
`getString()` / **`getArrayBuffer()`**. The 1.1.0-alpha02 release note states the intent
plainly: "Add message ports API... This allows strings and **ArrayBuffers to be sent and
received** without embedding them inside evaluations or named data blobs."

### The three questions, answered

**(a) Can code in the isolate call a native (C/JNI) function in the host process?**
**No.** The isolate is a different, *isolated* OS process inside the WebView package's sandbox.
The only channels are Binder-mediated: script text (or an fd), `provideNamedData` bytes in,
result String out, console messages, and (1.1.0) message ports. No host object, function, or
native symbol can be exposed to the isolate. There is no path by which JS in the isolate calls
`libkaya`.

**(b) Can bytes come back other than as a String?**
**Since 1.1.0, yes** — via a `MessagePort` carrying `Message.TYPE_ARRAY_BUFFER`, delivered as
`byte[]`. Before 1.1.0 the answer was no: "The response is always returned as a String... Non-string
values must be explicitly converted to a JavaScript String otherwise an empty string is returned."
Note the copies, though: `createArrayBufferMessage` "does not create a copy... Data is only
copied during message posting", so a port message is at minimum one copy into the Binder
transaction and one out — plus a process boundary. It is not zero-copy, and it cannot be,
because the two sides do not share an address space.

**(c) Size limits.**
`IsolateStartupParameters.DEFAULT_MAX_EVALUATION_RETURN_SIZE_BYTES = 20971520` (20 MiB), tunable
with `setMaxEvaluationReturnSizeBytes(int)` but only when
`JS_FEATURE_EVALUATE_WITHOUT_TRANSACTION_LIMIT` is supported; exceeding it raises
`EvaluationResultSizeLimitExceededException`. Without that feature "all data to the
JavaScriptEngine occurs through a Binder transaction. The general transaction size limit is
applicable to every call that passes in data or returns data" — and Android's own docs put a hard number on
that: "The Binder transaction buffer has a limited fixed size, currently 1MB, which is shared by
all transactions in progress for the process"
(https://developer.android.com/reference/android/os/TransactionTooLargeException , read 2026-09-02).
`provideNamedData` is explicitly *not* bound by the transaction limit, but "each byte array must
be passed using a unique identifier which cannot be re-used" — so it is a one-shot upload channel,
not a call-response channel. Heap is capped separately by `setMaxHeapSizeBytes`, and blowing it
takes down the whole sandbox, not just the isolate.

### What this costs a binding that returns wire records thousands of times per second

kaya's guest packs a record into a `Uint8Array` and hands the pointer to `libkaya` in the same
address space — today that is a pointer and a length. Through `androidx.javascriptengine` the
same operation becomes: marshal into an `ArrayBuffer`, copy into a Binder parcel, cross a
process boundary, copy out into a `byte[]` on the app side, then call into `libkaya` from Java.
Round-trip latency is a Binder IPC (tens of microseconds at best, and it is a *round trip* per
record because the isolate cannot call back into native), and the throughput ceiling is the
shared 1 MB transaction buffer unless the newer features are present. At "thousands of records
per second" you are running thousands of cross-process round trips per second for what is
currently a function call. And in the pre-1.1.0 shape — results as Strings only — every binary
record would additionally have to be base64'd or JSON-escaped, roughly a 1.33x-2x size blow-up
plus encode/decode on both sides. This library is built for "evaluate an untrusted snippet and
get an answer", not for a hot native binding, and no amount of feature flags changes the fact
that **the JS cannot call `libkaya`**.

## 7. Everything else real — and the one that changes the decision

### rusty_v8 (the `v8` crate) — very much alive, but **no Android prebuilt since 2024**

https://github.com/denoland/rusty_v8 (read 2026-09-02): 3,941 stars, MIT, commits **on
2026-09-02**. crates.io `v8` is at **152.2.0, published 2026-08-20**, 197 versions,
3.8M recent downloads (https://crates.io/api/v1/crates/v8 , read 2026-09-02) — a release every
week or two, tracking V8 head. It is by far the best-maintained V8 distribution in this report
and it gives a Rust API, which matters for a Rust core.

**But the Android prebuilts are gone.** Enumerating release assets via the GitHub API
(2026-09-02):

| release | date | `*-linux-android` assets |
|---|---|---|
| v0.38.0 | 2022-01-18 | present (first appearance) |
| v0.43.0 | 2022-05-24 | **removed** |
| v0.91.1 | 2024-05-09 | present again |
| v0.100.0 | 2024-07-24 | `librusty_v8_release_aarch64-linux-android.a.gz` = 27,780,963 B (26.5 MiB), plus x86_64 |
| **v0.102.0** | **2024-08-05** | **removed — and not restored since** |
| v152.2.0 | 2026-08-20 | 44 assets: apple-darwin, apple-ios, apple-ios-sim, linux-gnu, linux-musl, riscv64, windows-msvc. **No Android.** |

So the premise "rusty_v8 publishes Android targets" was true two years ago and is false today.
What remains is the **from-source** path, which is documented and supported: the README's
"For Android builds" section gives
`V8_FROM_SOURCE=1 cargo build -vv --target aarch64-linux-android` (and a `cross` recipe), and
`build.rs` handles it — it downloads NDK **r26c** automatically, clones Chromium's
`android_platform` and `catapult`, and sets `target_os="android"`, `target_cpu`, `use_sysroot=true`
(https://github.com/denoland/rusty_v8/blob/main/build.rs lines 596-645, read 2026-09-02).
**Critically, the Android path sets no jitless flags.** `build.rs` only forces
`v8_jitless=true`, `v8_enable_sparkplug=false`, `v8_enable_maglev=false`,
`v8_enable_turbofan=false` for the **iOS device** target (lines 647-671, with the comment "iOS
denies the JIT entitlement to non-WebKit apps, so a device build must be jitless"). An Android
build gets the full optimizing V8. The cost is that you build V8 from source in CI — a
depot_tools-class job per ABI, with the caveat that this build is the "monolith archive plus
generated Rust bindings" shape, not an `.so`.

### servo/mozjs (SpiderMonkey) — **it publishes Android prebuilts, with the JIT, right now**

This is the item that most changes the picture, and it was not on the list.

https://github.com/servo/mozjs (read 2026-09-02): commits on 2026-08-30, SpiderMonkey updated
to **153.0 ESR** on 2026-08-29. crates.io `mozjs` is at **0.25.0, published 2026-08-30**,
MPL-2.0, 154k recent downloads (https://crates.io/api/v1/crates/mozjs , read 2026-09-02).

Its CI has a dedicated `android` job building `armv7-linux-androideabi`, `aarch64-linux-android`
and `x86_64-linux-android` with **NDK r29**, and it uploads a per-target archive
(https://github.com/servo/mozjs/blob/main/.github/workflows/build.yml , read 2026-09-02). Those
archives are attached to every release. From `mozjs-sys-v153.0.0-0`, published **2026-08-29**
(https://github.com/servo/mozjs/releases/tag/mozjs-sys-v153.0.0-0 , read 2026-09-02):

| asset | compressed |
|---|---|
| `libmozjs-aarch64-linux-android.tar.gz` | 16,960,114 B = **16.2 MiB** |
| `libmozjs-armv7-linux-androideabi.tar.gz` | 16,614,218 B = 15.8 MiB |
| `libmozjs-x86_64-linux-android.tar.gz` | 17,086,827 B = 16.3 MiB |

I downloaded and inspected the arm64 one (2026-09-02). It contains
`js/src/build/libjs_static.a` (67,134,538 B = **64.0 MiB** as an unstripped static archive),
`libjsapi.a`, `libjsglue.a` and the generated `jsapi.rs` / `gluebindings.rs` bindings — 70.6 MiB
unpacked. **The JIT is in it**: `ar t` lists 20 `Unified_cpp_js_src_jit*.o` members, and the
archive's strings carry `BaselineCompiler` (393), `IonCompile` (139), `WarpBuilder` (598),
`MacroAssembler` (4,607) — SpiderMonkey's full Baseline + Ion/Warp stack, plus WebAssembly. (A
static archive is not a shipped size: the linker drops what you do not reference, so the .so
contribution will be well under 64 MiB, but I did not measure a linked artifact.) `mozjs-sys`
prefers the prebuilt archive only when the `intl` and `jit` cargo features are on and `jitspew`
is off (`should_build_from_source()` in `mozjs-sys/build.rs`, read 2026-09-02).

For kaya specifically: SpiderMonkey's JSAPI has `JS::NewArrayBufferWithUserOwnedContents` and
`JS::NewExternalArrayBuffer` for wrapping foreign memory, and the crate exposes JSAPI to Rust —
so a Rust core could own the engine directly, no JNI in the byte path. The costs are the LGPL-ish
**MPL-2.0** licence (file-level copyleft, generally fine for linking but a legal review item that
BSD/MIT V8 and JSC do not need) and a considerably larger, less familiar API than JSC's C API.

### Bun — an Android *executable*, not an embeddable library

`oven-sh/bun` v1.4.0, published **2026-08-20**, ships `bun-linux-aarch64-android.zip`
(35,184,745 B = 33.6 MiB) and x64 Android builds
(https://github.com/oven-sh/bun/releases/tag/bun-v1.4.0 , read 2026-09-02). These are Bun's
JSC-backed CLI binary cross-compiled for Android/Termux, not a `.so` with an embedding API.
Running one from inside a normal app is also fighting the Android 10 W^X rule (a binary in the
app's writable home directory cannot be `execve`'d; only files shipped in the APK's native
library directory can). Not a path for a binding.

### Boa — Rust, and an interpreter

`boa_engine` 0.22.0, updated 2026-08-28, 1.5M recent downloads; repo pushed 2026-09-01
(https://crates.io/api/v1/crates/boa_engine and https://github.com/boa-dev/boa , read
2026-09-02). Its own description: "a Javascript lexer, parser and compiler written in Rust" —
bytecode plus a VM loop, no JIT. It fails the ruling for the same reason a jitless V8 does, and
it is also not fully spec-complete.

Same category, named for completeness so nobody re-derives them: **QuickJS / rquickjs**
(interpreter), **Hermes as RN ships it** (interpreter, section 4), **`v8-android` /
`v8-android-nointl`** (interpreter, section 2), **`jsc-android` on x86 only** (C-loop, section 3).

## What this means

On Android the ruling is satisfiable, and there are three honest options, in ascending order of
work:

1. **`jsc-android` 2026004.0.1 from Maven Central** — the only *currently published, prebuilt,
   JIT-on, Android-native* engine with a plain C embedding API. 9.70 MiB arm64 (3.39 MiB in the
   APK) without Intl, 19.17 MiB with. It ships prefab headers including `JSTypedArray.h`, and the
   binary exports `JSObjectMakeTypedArrayWithBytesNoCopy` / `JSObjectGetTypedArrayBytesPtr` —
   the exact zero-copy surface kaya's wire records need — plus
   `JSObjectMakeFunctionWithCallback` for calling into `libkaya`. Caveats: baseline JIT only
   (`ENABLE_DFG_JIT=OFF`, `ENABLE_FTL_JIT=OFF`), no WebAssembly, x86 emulator images are
   C-loop-interpreted, and the last publish was 2024-11-29 (WebKitGTK-2.26-era JSC — old, though
   the buildscripts repo is still being touched).
2. **`v8-android-jit-nointl` 11.1000.4** — a genuine JIT V8 at 14.79 MiB arm64 (5.20 MiB in the
   APK), *smaller than the 21.97 MiB jitless build already measured here*. But it is V8 11.10
   from 2023-08-20 and the publisher has not touched the repo in two years, so it is a
   dependency with no upstream.
3. **Build it yourself, and the two Rust-native candidates** — `servo/mozjs` already publishes
   `aarch64-linux-android` prebuilts with the full JIT (16.2 MiB compressed, 2026-08-29,
   SpiderMonkey 153) and hands a Rust core the JSAPI directly; `rusty_v8` is the freshest V8 of
   all (152.2.0, 2026-08-20) with a documented Android cross-build that keeps the JIT, but no
   Android prebuilt since 2024-08-05, so it means owning a V8 source build per ABI.

Ruled out on mechanism, not on taste: **WebView** (pinned to a Looper/UI thread, no ArrayBuffer
across `addJavascriptInterface`), and **`androidx.javascriptengine`** (a genuinely good, current
1.1.0 library with V8 and its JIT — but the JS runs in a *different process* and can never call
`libkaya`; every record would be a Binder round trip, with the 20 MiB return cap and a shared
1 MB transaction buffer in the way).

And the fact worth carrying forward: **the 21.97 MiB V8 this project measured was the jitless
one**. Both of the JIT-capable prebuilts that matter — `v8-android-jit-nointl` at 14.79 MiB and
`jsc-android` at 9.70 MiB — are *smaller* than what was measured, while being the thing the
ruling asks for.
