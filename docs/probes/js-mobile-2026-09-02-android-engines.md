# JavaScript engines embeddable in an Android app (research, 2026-09-02)

Charge: kaya's JS binding runs today only on Node (N-API addon -> Rust core `libkaya` over the C ABI).
Question: what engine can host kaya's JS guests inside an Android app, and ideally on iOS too.

Every claim below carries a URL. Size figures marked **[measured]** were produced on this machine
on 2026-09-02 by downloading the shipping artifact (or building from the release tarball with this
repo's own NDK) and reading the bytes — they are not quoted from anyone's README.

## Comparison table (arm64-v8a unless noted)

All size figures below marked **[measured]** were obtained by downloading the shipping artifact and
reading the zip directory on 2026-09-02; the command and artifact URL is given in the engine's section.

| Engine | Added `.so`, arm64-v8a (uncompressed / in-APK) | License | Alive in 2026? | Native-fn API | Bytes in/out of JS | ES modules | iOS too? | Off-UI-thread |
|---|---|---|---|---|---|---|---|---|
| **QuickJS-ng** | **760 KiB / 370 KiB** (`-Os`) [measured] | MIT | Yes — v0.16.2 on 2026-08-20, commits daily | C: `JS_NewCFunction`, `JS_NewCClosure` | zero-copy both ways: `JS_GetUint8Array`, `JS_NewUint8Array` | **yes, native** `JS_SetModuleLoaderFunc` | yes, declared supported; plain C build | yes, one `JSRuntime` per thread |
| QuickJS (Bellard) | 707 KiB / 341 KiB (`-Os`) [measured] | MIT | Yes, but 2-3 releases/yr, one maintainer, no tags | same, minus ng's extras | same | yes | yes | yes |
| **Hermes (V1)** | **2.04 MiB / 873 KiB** [measured] | MIT | Very — RN default engine, commits daily | C++ JSI `HostObject`/`HostFunction`; **+ Node-API v10 since 2026-05-12 (dev branch only)** | JSI `ArrayBuffer::data()`; or `napi_get_typedarray_info` | **no** runtime `import` — bundle first | yes, RN's iOS default since 0.70 | yes, one runtime per thread |
| JSC (jsc-android) | 9.70 MiB / 3.39 MiB; **Intl variant 19.17 MiB / 6.74 MiB** [measured] | BSD-2-Clause (WebKit LGPL/BSD) | Barely — last engine bump 2024-11-29, npm dead since 2023-02-05 | C: `JSObjectMakeFunctionWithCallback` | zero-copy `JSObjectGetTypedArrayBytesPtr` | **no from C** (modules are Obj-C-only API) | yes — free system framework | yes, `JSLock` per context group |
| Boa (Rust) | n/a (Rust rlib, no `.so` to ship) | MIT | Yes — v0.22 on 2026-08-28 | Rust native, no FFI at all | Rust-native | yes | yes — just a cargo target | yes |
| V8 (`v8-android`) | 21.97 MiB / 7.82 MiB [measured] | BSD-3-Clause | **No** — frozen at V8 11.x since 2023-08-20 | C++ `v8::FunctionTemplate`, or J2V8's Java bridge | `ArrayBuffer::GetBackingStore()->Data()` | yes | **no** — `rusty_v8` Android/iOS unsupported; JIT illegal on iOS | yes |
| Android WebView | 0 (system component) | — | system component | `@JavascriptInterface`, **Java only** | no `ArrayBuffer` handle; `WebMessageCompat` copies `byte[]` over IPC | yes | n/a | **no — pinned to its creating Looper thread** |
| androidx.javascriptengine | 0 (system, separate process) | Apache-2.0 | Yes — **1.0.0 2025-07-02, 1.1.0 2026-05-06** | **none — cannot call native code at all** | String in/out; `provideNamedData(byte[])` in | no | n/a | separate process |

**Short version:** QuickJS-ng is the recommendation — smallest, most alive, only one with a native
module loader, one-command cross-compile for Android *and* iOS, and `rquickjs` gives libkaya a
maintained Rust binding. Hermes is the serious alternative and the only one that could run kaya's
**existing N-API addon unmodified**, but that path is four months old and lives only on Hermes'
dev branch.

---

## (a) JavaScriptCore built for Android

### What the artifact actually is, in 2026

There are now **two** distributions and the old one is the dead one.

* The npm package `jsc-android` — https://www.npmjs.com/package/jsc-android — **latest is
  `250231.0.0`, published 2023-02-05**. (Measured from the registry: `curl -s
  https://registry.npmjs.org/jsc-android` → `dist-tags.latest = 250231.0.0`,
  `time["250231.0.0"] = 2023-02-05T14:42:25.034Z`.) Nothing has been published to npm since.
* The live distribution moved to Maven Central as
  `io.github.react-native-community:jsc-android` and `…:jsc-android-intl`, **latest
  `2026004.0.1`, `lastUpdated 20241129063506` = 2024-11-29** —
  https://repo1.maven.org/maven2/io/github/react-native-community/jsc-android/maven-metadata.xml
  and https://repo1.maven.org/maven2/io/github/react-native-community/jsc-android-intl/maven-metadata.xml
* The build scripts repo is https://github.com/react-native-community/jsc-android-buildscripts
  (BSD-2-Clause, not archived). Its last *substantive* commit is `dbbf3a7 "Bump 2026004.0.1"`
  dated **2024-11-28**; the only commit since is `a176055 "[ci] cleanup ubuntu runner disk"`
  dated **2025-10-19**. Its newest GitHub release is `v294992.0.0` from **2022-07-13**.
  (`gh api repos/react-native-community/jsc-android-buildscripts/commits`, `/releases`.)
* The React Native side is `@react-native-community/javascriptcore` —
  https://github.com/react-native-community/javascriptcore, MIT, created 2025-03-05, npm
  latest `0.2.0` published **2025-03-24**, last commit **2026-02-12**
  (`fix(apple): disable ASAN for JSC methods`, and `ci: fix android CI by snapping to 0.79`).
  It exists because JSC was pulled out of React Native core by the
  [Lean Core JSC RFC](https://github.com/react-native-community/discussions-and-proposals/blob/main/proposals/0836-lean-core-jsc.md);
  the RN 0.79 release post says the bundled JSC "is expected to be fully removed in a future
  release" — https://reactnative.dev/blog/2025/04/08/react-native-0.79 .

**Verdict on maintenance:** on life support. One engine bump in 2024, none in 2025 or 2026, and
the wrapper repo's own CI is pinned to RN 0.79. It is not abandoned, but nobody is shipping you a
current WebKit.

### (i) Size, arm64-v8a — **measured 2026-09-02**

Downloaded `io.github.react-native-community:jsc-android:2026004.0.1` and
`…:jsc-android-intl:2026004.0.1` AARs from Maven Central and read the zip directory:

| variant | `jni/arm64-v8a/libjsc.so` uncompressed | deflated (what the APK stores) |
|---|---|---|
| `jsc-android` (no Intl) | **10,173,344 B = 9.70 MiB** | 3,550,934 B = 3.39 MiB |
| `jsc-android-intl` | **20,100,800 B = 19.17 MiB** | 7,065,185 B = 6.74 MiB |

So **yes — the Intl variant almost exactly doubles it** (+9.47 MiB uncompressed, +3.35 MiB in the
APK). The repo README's claim that the international variant is "about 6MiB larger per
architecture" (https://github.com/react-native-community/jsc-android-buildscripts/blob/main/README.md)
is understated against the 2024 build.
Full AAR sizes for reference: `jsc-android` 28,172,306 B, `jsc-android-intl` 56,295,836 B
(4 ABIs each, plus a duplicate copy under `prefab/`).

### (ii) License

BSD-2-Clause for the build scripts and the packaging
(https://github.com/react-native-community/jsc-android-buildscripts, `license.spdx_id =
BSD-2-Clause`); JavaScriptCore itself is WebKit's LGPL-2.1/BSD mix. `@react-native-community/javascriptcore`
is MIT.

### (iv) How native code is exposed to JS — the C API

The AAR ships the full JavaScriptCore C headers under prefab
(`prefab/modules/jsc/include/JavaScriptCore/…`, verified by listing the AAR: `JSBase.h`,
`JSContextRef.h`, `JSObjectRef.h`, `JSStringRef.h`, `JSValueRef.h`, `JSTypedArray.h`, …).
The binding call is:

```c
JS_EXPORT JSObjectRef JSObjectMakeFunctionWithCallback(
    JSContextRef ctx, JSStringRef name, JSObjectCallAsFunctionCallback callback);
```

https://developer.apple.com/documentation/javascriptcore/c-javascriptcore-api and
https://developer.apple.com/documentation/javascriptcore/jsobjectcallasfunctioncallback .
Objects with native backing are made with `JSClassCreate` + `JSObjectMake` and a private
pointer (`JSObjectSetPrivate`/`JSObjectGetPrivate`), all in
https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSObjectRef.h .
This is a **pure C API** — no C++ needed, which maps cleanly onto a Rust `extern "C"` shim.

### (v) Bytes in and out — zero-copy is available

From https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSTypedArray.h
(all `JSC_API_AVAILABLE(macos(10.12), ios(10.0))`, i.e. long since present in any JSC you'd build):

```c
void*  JSObjectGetTypedArrayBytesPtr(JSContextRef, JSObjectRef, JSValueRef* exception);
size_t JSObjectGetTypedArrayLength(JSContextRef, JSObjectRef, JSValueRef* exception);
size_t JSObjectGetTypedArrayByteLength(JSContextRef, JSObjectRef, JSValueRef* exception);
size_t JSObjectGetTypedArrayByteOffset(JSContextRef, JSObjectRef, JSValueRef* exception);
void*  JSObjectGetArrayBufferBytesPtr(JSContextRef, JSObjectRef, JSValueRef* exception);
JSObjectRef JSObjectMakeTypedArrayWithBytesNoCopy(JSContextRef, JSTypedArrayType, void* bytes,
        size_t byteLength, JSTypedArrayBytesDeallocator, void* deallocatorContext, JSValueRef*);
JSObjectRef JSObjectMakeArrayBufferWithBytesNoCopy(JSContextRef, void* bytes, size_t byteLength,
        JSTypedArrayBytesDeallocator, void* deallocatorContext, JSValueRef*);
```

`JSObjectGetTypedArrayBytesPtr` is exactly the pointer+length pair you want, and the header
warns it is a *temporary* pointer (valid until the next GC/allocation), which is the usual
rule. `…WithBytesNoCopy` lets libkaya hand a buffer it owns straight to JS with a deallocator
callback. This is the best byte story of the four C-API engines.

### (vi) ES modules — **no, not from C**

The C API's only evaluation entry point is `JSEvaluateScript` (JSBase.h); there is no module
loader hook in the C API. Module support exists in JSC only through the **Objective-C** API —
`JSScript` with `kJSScriptTypeModule` and `JSContext.moduleLoaderDelegate`, both marked
`JSC_API_AVAILABLE(macos(10.15), ios(13.0))`. I confirmed this by grepping the headers actually
shipped inside the Android AAR: `JSScript.h` defines `kJSScriptTypeModule` and
`JSContextPrivate.h` declares `@protocol JSModuleLoaderDelegate` — Objective-C declarations that
no Android toolchain compiles. See
https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSScript.h and
https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSContext.h .
**On Android you feed JSC one concatenated classic script**, or implement `require` yourself.

### (vii) iOS

Free — `JavaScriptCore.framework` is a public system framework on iOS 7+ and macOS
(https://developer.apple.com/documentation/javascriptcore). Zero bytes added, and the C API is
identical, so a JSC-based kaya host would be *the* smallest iOS option. The catch is the
version skew: on Android you ship a 2024 WebKit snapshot, on iOS you get whatever the OS has.

### (viii) Threading

JSC is not thread-affine, but it is not free-threaded either. `JSContextRef.h` says verbatim:

> "When objects from the same context group are used in multiple threads, explicit
> synchronization is required."
> — https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSContextRef.h

Internally every API entry takes the per-VM `JSLock` (`JSLockHolder`,
https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/runtime/JSLock.h), so a JSC
context **can** live on a kaya app thread while the Android UI thread is elsewhere, as long as
only one thread is inside the API at a time. Note also from the same header: "A JSContextGroup
may need to run deferred tasks on a run loop … By default, calling `JSContextGroupCreate` will
use the run loop of the thread it was called on", so create the group on the thread that will
own it.

---

## (b) Hermes (Meta)

Repo https://github.com/facebook/hermes, **MIT**, 11,283 stars. `gh api repos/facebook/hermes`
reports `pushed_at = 2026-09-03T03:30:37Z` — i.e. commits landing *today*. **Its default branch
is now `static_h`, not `main`** (`gh api repos/facebook/hermes --jq .default_branch` →
`static_h`), which is the practical answer to "did Static Hermes change anything by 2026": yes,
the Static Hermes line became the mainline.

### Maintenance and versioning in 2026

* GitHub *releases* are stale (newest tag `v0.13.0`, **2024-08-16**) because Hermes stopped
  releasing that way. Versioning is now RN-style stable branches: `250829098.0.0-stable`,
  `260318099.0.0-stable`.
* **Hermes V1 is the default React Native engine on both iOS and Android since React Native
  0.84, released 2026-02-11**: "Hermes V1 is now the default JavaScript engine for React Native
  on both iOS and Android, following the initial experimental opt-in in React Native 0.82." —
  https://reactnative.dev/blog/2026/02/11/react-native-0.84
* What is coming in the next stable (260318099.0.0), per the engine's own blog post dated
  **2026-06-05**: Set operations, `Object.groupBy`, Iterator Helpers, `for await…of`,
  `Promise.withResolvers`, `FinalizationRegistry`, `TextDecoder`, Unicode 17, JIT expansion,
  a `--transform-ts` flag that strips TypeScript types in the engine's own parser, and a
  bytecode version bump 98 → 99 —
  https://github.com/facebook/hermes/blob/static_h/doc/blog/2026-06-05-new-hermes-stable-release.md

### (i) Size, arm64-v8a — **measured 2026-09-02**

Downloaded `com.facebook.react:hermes-android:0.82.1` (`-release.aar`, the newest on Maven
Central: https://repo1.maven.org/maven2/com/facebook/react/hermes-android/maven-metadata.xml,
`lastUpdated 20260205173932`) and read the zip directory:

| file | uncompressed | deflated |
|---|---|---|
| `jni/arm64-v8a/libhermesvm.so` | **2,139,952 B = 2.04 MiB** | 894,345 B = 873 KiB |
| `jni/armeabi-v7a/libhermesvm.so` | 1,481,564 B | 816,013 B |
| `jni/x86_64/libhermesvm.so` | 2,225,696 B | 919,156 B |

(The 50 MB copies under `prefab/modules/hermesvm/libs/…` in the same AAR are the unstripped
link-time copies, not what ships.) So Hermes costs about **one fifth of JSC** per ABI.

### (ii) License

MIT — https://github.com/facebook/hermes/blob/static_h/LICENSE .

### (iv) How native code is exposed — three layers, and one of them is Node-API

**1. JSI (the documented one).** C++ only.
https://github.com/facebook/hermes/blob/static_h/API/jsi/jsi/jsi.h :

```cpp
using HostFunctionType = std::function<
    Value(Runtime& rt, const Value& thisVal, const Value* args, size_t count)>;
class JSI_EXPORT HostObject { ... };   // get/set/getPropertyNames, GC-finalized
// registered via:
static Function Function::createFromHostFunction(
    Runtime& runtime, const PropNameID& name, unsigned int paramCount, HostFunctionType func);
```

This is a C++ ABI, so a Rust core reaches it only through a hand-written `extern "C"` C++ shim.

**2. `hermes_abi` — an experimental C ABI.**
https://github.com/facebook/hermes/blob/static_h/API/hermes_abi/README.md says in full:
"This directory contains ongoing work to develop a stable C-based ABI for Hermes and an
accompanying C++ JSI wrapper. **It is a work in progress and is not supported for general use.**"
Do not build on it.

**3. Node-API v10 — new, and the single most interesting fact for kaya.**
`API/napi/` exists on the default (`static_h`) branch:
https://github.com/facebook/hermes/tree/static_h/API/napi . Its README states:

> "This is an implementation of Node-API (N-API) v10 for the Hermes JavaScript engine. It allows
> native addons written against the Node-API ABI to run on Hermes without modification. The
> implementation is built directly on Hermes VM internals (not JSI), covering all
> non-experimental APIs through NAPI_VERSION 10."
> — https://github.com/facebook/hermes/blob/static_h/API/napi/README.md

The API matrix is in
https://github.com/facebook/hermes/blob/static_h/API/napi/COMPATIBILITY.md and covers
ArrayBuffer/TypedArray (all 11 types), DataView, Buffer, promises, BigInt, references,
wrapping/finalizers, type tags, thread-safe functions and async work. Its stated limitations are
that `node_api_create_external_string_*` always copies and `napi_adjust_external_memory` does not
influence GC.

**Timeline and caveat.** `gh api 'repos/facebook/hermes/commits?path=API/napi'` returns 12
commits: the first is **"Add Node-API implementation for Hermes", 2026-05-12**; the most recent
is **"napi: give hermes_napi.h public API C linkage", 2026-07-16**. It is **not** in the
`260318099.0.0-stable` branch — `gh api 'repos/facebook/hermes/contents/API?ref=260318099.0.0-stable'`
lists only `hermes`, `hermes_abi`, `hermes_sandbox`, `jsi`. So as of 2026-09-02 Hermes Node-API
is four months old, on the dev branch only, and has never shipped in a stable Hermes or in any
React Native release. Related: Tzvetan Mikov (the Static Hermes lead) announced
`hermes-node`, a Node built-in-module compatibility layer over Hermes+Node-API, in
February 2026 — https://github.com/tmikov/hermes-node .

### (v) Bytes in and out

JSI has both directions with zero copy of the payload
(https://github.com/facebook/hermes/blob/static_h/API/jsi/jsi/jsi.h):

```cpp
virtual ArrayBuffer createArrayBuffer(std::shared_ptr<MutableBuffer> buffer) = 0; // adopt native memory
virtual uint8_t* data(const ArrayBuffer&) = 0;                                    // pointer out
virtual size_t   size(const ArrayBuffer&) = 0;
virtual Uint8Array createUint8Array(const ArrayBuffer& buffer, size_t offset, size_t length) = 0;
virtual ArrayBuffer buffer(const TypedArray&) = 0;
virtual size_t byteOffset(const TypedArray&) = 0;  // + byteLength(), length()
```

Through Node-API it is the ordinary `napi_get_typedarray_info(env, value, &type, &length, &data,
&arraybuffer, &offset)` / `napi_create_external_arraybuffer` shape —
https://nodejs.org/api/n-api.html#napi_get_typedarray_info .

### (vi) ES modules — **no runtime `import`, by explicit policy**

From https://github.com/facebook/hermes/blob/static_h/doc/Features.md , under "Not supported":

> "**ES Modules (`import`/`export`):** Hermes **does not** currently provide a runtime module
> loader. While an implementation existed previously, it was removed as the React Native
> ecosystem relies heavily on bundlers (like Metro) which provide their own module systems. A
> future goal is to potentially parse module syntax to give the AOT compiler better visibility
> for cross-module optimizations, but *not* necessarily to replace bundler functionality at
> runtime."

There is a legacy CommonJS segment format described in
https://github.com/facebook/hermes/blob/static_h/doc/Modules.md (a `metadata.json` with
`segments` and a `resolutionTable`, driving a runtime-provided `require`), which is what
`hermesc -commonjs` emits — but the supported path is: **bundle first, then run one script**.

### Bytecode precompilation

Hermes compiles ahead of time to Hermes bytecode (`.hbc`) with `hermesc`; the VM can run bytecode
directly, which is why `Function.prototype.toString` cannot show source ("Hermes executes from
bytecode", https://github.com/facebook/hermes/blob/static_h/doc/Features.md). The bytecode version
is pinned per engine build — the 2026-06-05 post: "We bumped the bytecode version to 99. So if you
use prebuilt bytecode, you'll need to rebuild it with the new version of Hermes." Cross-compiling
requires the documented two-stage build (host `hermesc` first, then the target VM) —
https://github.com/facebook/hermes/blob/static_h/doc/CrossCompilation.md .

### (vii) iOS / macOS

Yes, and it is the default. React Native has shipped Hermes on iOS since 0.70
(https://reactnative.dev/blog/2022/07/08/hermes-as-the-default, 2022-07-08: "React Native 0.70
will ship with Hermes as the default engine"), and Hermes V1 is the iOS default as of RN 0.84
(https://reactnative.dev/blog/2026/02/11/react-native-0.84). The Apple build path is
`utils/build-apple-framework.sh` in the Hermes tree, named in
https://github.com/facebook/hermes/blob/static_h/doc/CrossCompilation.md ; RN consumes it as the
`hermes-engine` CocoaPod with a prebuilt `.xcframework` (RN 0.84 "now ships precompiled binaries
on iOS by default"). Standalone, you build the xcframework yourself from that script — there is
no vendor-neutral prebuilt Hermes xcframework on CocoaPods/SwiftPM. Note the npm package
`hermes-engine` is a dead 2022 artifact (latest `0.11.0`, published 2022-01-27 —
https://registry.npmjs.org/hermes-engine); don't mistake it for a distribution channel.

### (viii) Threading

One runtime, one thread at a time — the rule is written into jsi.h
(https://github.com/facebook/hermes/blob/static_h/API/jsi/jsi/jsi.h):

> "Note that this object may not be thread-aware, but cannot be used safely from multiple threads
> at once. The application is responsible for ensuring that it is used safely. This could mean
> using the Runtime from a single thread, using a mutex, doing all work on a serial queue, etc."

and, on `IRuntime`: "The APIs must not be called from multiple threads concurrently."
So a Hermes runtime on kaya's app thread while Android's UI thread runs elsewhere is exactly the
supported configuration (it is what React Native itself does). `makeThreadSafeHermesRuntime()`
exists in https://github.com/facebook/hermes/blob/static_h/API/hermes/hermes.h if you want the
lock built in. One caveat from jsi.h: a `HostObject` destructor "will be called when the GC
finalizes this object… You have no control over which thread it is called on" — so a Rust
finalizer must not touch kaya's model directly.

### Can it be used standalone, outside React Native?

Yes mechanically — it is a CMake project that builds `libhermesvm` and the `hermesc`/`shermes`
tools, and Android is a first-class cross-compile target described in
https://github.com/facebook/hermes/blob/static_h/doc/CrossCompilation.md ("For Android, this
happened in `hermes/android/build.gradle`"). But there is no vendor-published standalone
Android AAR or iOS xcframework that is not React Native's, so you either depend on
`com.facebook.react:hermes-android` (which drags an RN-shaped artifact into a non-RN app) or you
run the two-stage build yourself in CI for four ABIs plus Apple.

---

## (c) QuickJS (Bellard) and QuickJS-ng

### Maintenance status, both, as of 2026-09-02

**Bellard's QuickJS** — https://bellard.org/quickjs/ , repo https://github.com/bellard/quickjs
(10,966 stars). `gh api repos/bellard/quickjs` → `pushed_at = 2026-06-16T11:35:08Z`; the newest
commits are `2026-06-16 "run-test262: when updating errors, sort them…"` and `2026-06-13
"optimized Array.prototype.slice and Array.prototype.splice"`. **There are no GitHub releases or
tags at all** (`gh api repos/bellard/quickjs/releases` and `/tags` both return empty); releases
are tarballs on the site. Newest release **2026-06-04** ("New release … It is 42% faster than the
previous release based on the bench-v8 (aka v8-v7) score"), preceded by 2025-09-13 and
2025-04-26. So: alive, one-maintainer, ~2-3 releases a year, no issue tracker culture.
Licence **MIT** (`LICENSE`: "The MIT License (MIT) Copyright (c) 2017-2026 Fabrice Bellard").

**QuickJS-ng** — https://github.com/quickjs-ng/quickjs (3,697 stars, **MIT**). `pushed_at =
2026-09-02T23:29:04Z`; commits landing today. Releases **v0.16.2 on 2026-08-20**, v0.16.1
2026-08-04, v0.16.0 2026-07-31, v0.15.1 2026-06-04, v0.15.0 2026-05-21 — i.e. roughly monthly.
Maintainers are Ben Noordhuis and Saúl Ibarra Corretgé (both ex-Node core). Its own docs say:
"a steady cadence of releases has been maintained, with an average of a new release every 2
months… Each PR is tested in over 50 configurations" —
https://github.com/quickjs-ng/quickjs/blob/master/docs/docs/diff.md .
**This is the one to use.** Bellard's is the reference; ng is the maintained product.

### (i) Size, arm64-v8a — **measured 2026-09-02**

Upstream's own figure is x86 and for a whole hello-world program: "just a few C files, no
external dependency, **367 KiB of x86 code** for a simple hello world program"
(https://bellard.org/quickjs/, 2026-06-04 release; older copies of that sentence, still quoted in
e.g. rquickjs's README, say 210 KiB). That is not the number you want, so I built both for
Android arm64 with the NDK clang 21 in this repo's dev shell
(`$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android21-clang`,
`-shared -fPIC -Os -DNDEBUG -fvisibility=hidden`, then `llvm-strip -s`):

| build | stripped `.so` | deflated (APK-stored) |
|---|---|---|
| bellard quickjs-2026-06-04, engine only (`quickjs.c libregexp.c libunicode.c cutils.c dtoa.c`) | **724,432 B = 707 KiB** | 348,876 B |
| quickjs-ng v0.16.2, engine only (`quickjs.c libregexp.c libunicode.c dtoa.c`) | **780,432 B = 762 KiB** | 379,325 B |
| quickjs-ng v0.16.2 amalgam (engine + `quickjs-libc`), `-Os` | 778,000 B | 380,598 B |
| quickjs-ng v0.16.2 amalgam, `-O2` | 1,003,480 B | 479,938 B |

So the honest headline is **~0.75 MiB per ABI at `-Os`, ~1 MiB at `-O2`** — about **1/3 of
Hermes** and **1/13 of JSC**. Source tarballs used:
https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz and
https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.16.2.tar.gz (there is also a 568 KB
`quickjs-amalgam.zip` asset attached to every ng release).

### (iii) Conformance

Bellard's site claims "Almost complete **ES2025** support including modules, asynchronous
generators and full Annex B support… Passes nearly 100% of the ECMAScript Test Suite tests when
selecting the ES2025 features" (https://bellard.org/quickjs/). ng's docs say "QuickJS aims to
support the latest available ECMAScript features once they hit the spec" and point at
https://test262.fyi/#|qjs_ng for the live number
(https://github.com/quickjs-ng/quickjs/blob/master/docs/docs/es_features.md). ng additionally
ships Resizable ArrayBuffer, Float16Array, WeakRef, FinalizationRegistry, Iterator Helpers,
Promise.try, Error.isError, Set operations, and V8's `Error.captureStackTrace` /
`prepareStackTrace` (https://github.com/quickjs-ng/quickjs/blob/master/docs/docs/diff.md).
**Neither ships `Intl`** — ng: "Due to size constraints it is unlikely QuickJS will ever support
the Intl APIs."

### (iv) Native functions — the C API

From https://github.com/quickjs-ng/quickjs/blob/master/quickjs.h :

```c
typedef JSValue JSCFunction(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv);
JSValue JS_NewCFunction2(JSContext *ctx, JSCFunction *func, const char *name,
                         int length, JSCFunctionEnum cproto, int magic);
static inline JSValue JS_NewCFunction(JSContext *ctx, JSCFunction *func,
                                      const char *name, int length);
JSValue JS_NewCFunctionData(JSContext *ctx, JSCFunctionData *func, int length,
                            int magic, int data_len, JSValueConst *data);   // closures w/ captured data
JSValue JS_NewCClosure(JSContext *ctx, JSCClosure *func, const char *name,
                       JSCClosureFinalizerFunc *opaque_finalize,
                       int length, int magic, void *opaque);                // ng-only: void* opaque + finalizer
```

Native-backed objects use `JS_NewClassID` / `JS_NewClass` / `JS_SetOpaque` / `JS_GetOpaque` with a
class `finalizer`. `JS_NewCClosure` (an ng addition) is the nicest fit for a Rust core: an
arbitrary `void*` plus a destructor, no class plumbing.

### (v) Bytes in and out — zero-copy in both directions

```c
JSValue  JS_NewArrayBuffer(JSContext *ctx, uint8_t *buf, size_t len, size_t max_len,
                           JSReallocArrayBufferDataFunc *realloc_func, void *opaque, bool is_shared);
JSValue  JS_NewArrayBufferCopy(JSContext *ctx, const uint8_t *buf, size_t len);
uint8_t *JS_GetArrayBuffer(JSContext *ctx, size_t *psize, JSValueConst obj);
uint8_t *JS_GetUint8Array(JSContext *ctx, size_t *psize, JSValueConst obj);       // ng convenience
JSValue  JS_GetTypedArrayBuffer(JSContext *ctx, JSValueConst obj,
                                size_t *pbyte_offset, size_t *pbyte_length, size_t *pbytes_per_element);
JSValue  JS_NewUint8Array(JSContext *ctx, uint8_t *buf, size_t len,
                          JSReallocArrayBufferDataFunc *realloc_func, void *opaque, bool is_shared);
JSValue  JS_NewUint8ArrayCopy(JSContext *ctx, const uint8_t *buf, size_t len);
int      JS_GetTypedArrayType(JSValueConst obj);
void     JS_DetachArrayBuffer(JSContext *ctx, JSValueConst obj);
```
(https://github.com/quickjs-ng/quickjs/blob/master/quickjs.h, lines ~1086-1130.)
**`JS_GetUint8Array(ctx, &len, val)` is literally the pointer+length call you asked for.** For the
other direction, `JS_NewUint8Array(ctx, buf, len, realloc_func, opaque, false)` adopts memory
libkaya owns; `realloc_func = NULL` means "quickjs must not manage this memory at all", which is
what a Rust-owned buffer wants. Bellard's has the same set minus `JS_GetUint8Array` /
`JS_NewUint8ArrayCopy`.

### (vi) ES modules — **native, and the only engine here with a real loader**

```c
JS_SetModuleLoaderFunc(JSRuntime *rt, JSModuleNormalizeFunc *module_normalize,
                       JSModuleLoaderFunc *module_loader, void *opaque);
JS_SetModuleLoaderFunc2(...)   /* same, plus import attributes */
#define JS_EVAL_TYPE_MODULE (1 << 0)
```
plus `JS_GetImportMeta`, `JS_GetModuleNamespace`, `JS_SetModulePrivateValue`,
`JS_NewCModule`/`JS_AddModuleExport` for **native modules written in C** (so kaya's binding could
be `import { app } from 'kaya'` backed by Rust, with no bundler at all). Bytecode
precompilation exists too: `JS_WriteObject` / `JS_ReadObject` / `JS_EvalFunction` with
`JS_EVAL_FLAG_COMPILE_ONLY`, which is what `qjsc` uses.

### (vii) iOS and Android

Officially supported platforms, from
https://github.com/quickjs-ng/quickjs/blob/master/docs/docs/supported_platforms.md :

| System | Supported versions | Notes |
|---|---|---|
| Android | NDK >= 26.0.10792818 | Limited testing |
| iOS | * | Limited testing |

"Limited testing" is honest — but it is plain C89-ish with no dependencies beyond libm, so it
cross-compiles for both from the same source tree. My arm64-Android build above took one clang
invocation with no configuration.

### Known embedders

quickjs-ng/docs/docs/projects.md (https://github.com/quickjs-ng/quickjs/blob/master/docs/docs/projects.md)
lists txiki.js, AWS **LLRT** (https://github.com/awslabs/llrt), radare2, nx.js (Nintendo Switch),
GodotJS, CSPro, quickjs-go, and the Rust wrappers. On mobile specifically:
* **WebF** (https://github.com/openwebf/webf, GPL-3.0, 2,510 stars, last push 2026-06-24) runs
  QuickJS inside Flutter apps on Android and iOS — the strongest existence proof that QuickJS
  ships in App Store apps.
* **quickjs-wrapper** (https://github.com/HarlonWang/quickjs-wrapper, Apache-2.0, 273 stars,
  release 3.2.3 on 2025-07-01, last push 2025-07-28) is a JNI wrapper published to Maven Central
  as `wang.harlon.quickjs:wrapper-android`.
* koush/quack (https://github.com/koush/quack) is the older Android one — last push 2021-08-21,
  effectively dead.

### Rust bindings

* **rquickjs** — https://github.com/DelSkayn/rquickjs , MIT, 994 stars, `pushed_at
  2026-09-02T18:07:12Z`, crates.io `0.12.2` published **2026-07-27**, 3.9M all-time downloads
  (https://crates.io/api/v1/crates/rquickjs). Its README says: "This library is a high level
  bindings of the **QuickJS-NG** JavaScript engine" — so it tracks the maintained fork. It has
  user-defined module resolvers and loaders, bytecode bundling via an `embed!` macro, async/Promise
  integration, and Rust types as JS classes. **This is the obvious route for a Rust core like
  libkaya.**
* **quickjs-rs** (theduke) — https://github.com/theduke/quickjs-rs , last push **2023-07-31**;
  crates.io shows `0.0.0` last updated 2023-08-21. **Dead.**
* quickjs-rusty (https://github.com/Icemic/quickjs-rusty, v0.14.0 2026-08-06) and
  quickjs_es_runtime (https://github.com/HiRoFa/quickjs_es_runtime, 0.17.2 2026-03-23) are the
  live alternatives, both ng-based.

### Debugger protocol

**Not upstream.** quickjs-ng issue #119 "Debugger Support"
(https://github.com/quickjs-ng/quickjs/issues/119) has been open since 2023-11-22; its most recent
comment, **2026-04-15**, is a maintainer saying "We are looking into merging this, which is much
smaller as it leaves the transport out: https://github.com/quickjs-ng/quickjs/pull/1421". The
working art is out of tree: koush's fork and its VS Code adapter
(https://github.com/koush/vscode-quickjs-debug, protocol at
https://github.com/koush/vscode-quickjs-debug/blob/master/protocol.md) — a custom TCP protocol,
**not** the Chrome DevTools Protocol. If kaya wants step debugging of guest JS on device, QuickJS
is the weakest of the three on that axis; Hermes ships a real CDP implementation
(`API/hermes/cdp/` in the Hermes tree).

---

## (d) V8 on Android

### (i) Size, arm64-v8a — **measured 2026-09-02**

`npm pack`-style download of `v8-android@11.1000.4`
(https://registry.npmjs.org/v8-android/-/v8-android-11.1000.4.tgz, unpackedSize 34,413,269 B),
opening the AAR it carries at `dist/org/chromium/v8-android/11.1000.4/v8-android-11.1000.4.aar`:

| file | uncompressed | deflated |
|---|---|---|
| `jni/arm64-v8a/libv8android.so` | **23,040,248 B = 21.97 MiB** | 8,202,995 B = 7.82 MiB |
| `jni/armeabi-v7a/libv8android.so` | 18,007,240 B | 7,492,737 B |
| `jni/x86_64/libv8android.so` | 24,245,304 B | 8,662,518 B |

plus a per-ABI `snapshot_blob.bin` (~50 KB). So V8 is **~11× Hermes and ~29× QuickJS-ng per
ABI.** (This build is jitless with Intl; the `-nointl` and `-jit` variants trade a few MB either
way.) That is the honest "tens of MB" figure you suspected.

### (iii) Maintenance — mostly bad news

* **`v8-android` / `v8-android-jit` / `v8-android-nointl` / `v8-android-jit-nointl`** (Kudo Chien's
  builds, the ones `react-native-v8` consumes): every one of them has `dist-tags.latest =
  11.1000.4`, **published 2023-08-20** (verified against
  https://registry.npmjs.org/v8-android etc.). The build repo
  https://github.com/Kudo/v8-android-buildscripts (BSD-2-Clause, 77 stars) has `pushed_at =
  2024-01-26` and its newest release is `v11.1000.4`, **2023-08-20**. `react-native-v8` itself
  last published `2.5.1` on **2024-08-20**. **Effectively frozen on V8 11.x — three years of
  Chromium security fixes behind.**
* **J2V8** — https://github.com/eclipsesource/J2V8, 2,628 stars, no SPDX license detected by the
  API (it is EPL-1.0 in-tree). `pushed_at = 2025-11-14`; the three newest commits are all dated
  **2025-11-14** and are release-pipeline work ("Refactor README to use Maven Central for J2V8
  dependencies", "Add detailed version management documentation to PUBLISHING"). So: a
  2025 resurrection after ~8 dormant years, and nothing since. Its own issue tracker records the
  scope cut to "only support Android, non-NodeJS"
  (https://github.com/eclipsesource/J2V8/issues/441). Its API is a **Java** bridge
  (`V8.registerJavaMethod(JavaCallback, String)`), so a Rust core reaches JS only via JNI →
  Java → V8, which is the wrong shape for kaya.
* **Javet** — https://github.com/caoccao/Javet, Apache-2.0, 961 stars, release **5.0.11 on
  2026-08-24**, `pushed_at 2026-08-31`. This is the *live* V8-in-Java project: Node.js
  v24.19.0 + V8 v15.2.124.17, i18n and non-i18n, Android on x86/x86_64/arm/arm64 (its README's
  own support matrix), Chrome DevTools debugging, swc4j for TS/JSX transpilation. **But it has no
  iOS row in that matrix**, and again it is a Java API.

### (iv)/(v)/(vi) API shape

Embedding V8 directly is C++: `v8::FunctionTemplate::New(isolate, callback)` +
`v8::ObjectTemplate::SetInternalFieldCount` for native-backed objects; bytes come out via
`v8::ArrayBuffer::GetBackingStore()->Data()` and `v8::TypedArray::ByteOffset()/ByteLength()`
(https://v8.github.io/api/head/classv8_1_1ArrayBuffer.html). ES modules are supported natively
(`v8::Module`, `Module::InstantiateModule` with a resolve callback). None of that is the problem;
the problem is that nobody publishes a maintained, small, prebuilt V8 for Android that is not
Chromium's own, and **on iOS V8's JIT cannot be used at all** (no `mmap` with `PROT_EXEC` for
non-Apple-signed pages outside a debug entitlement), so you would run V8 jitless on iOS —
20+ MB of engine to get an interpreter slower than QuickJS.

### `deno_core` / `rusty_v8` as the Rust route

https://github.com/denoland/rusty_v8 (MIT, 3,941 stars) is extremely alive — `pushed_at
2026-09-02T22:15:00Z`. **Android and iOS are not supported.** The tracking issue is
https://github.com/denoland/rusty_v8/issues/1640 ("Appetite for Android & iOS Support?"), opened
2024-10-10, **still open**, last activity 2026-04-26. Its opening text: "I know Android builds
have previously been a included as a feature of Rusty V8, but were sadly short-lived. To my
knowledge iOS builds have been attempted by community members but no support has landed in Rusty
V8." The most recent comment (2026-04-26) is a community member reporting they compiled
`deno_core` for the iOS *simulator* with a personal script. There is also
https://github.com/denoland/rusty_v8/issues/419 for `aarch64-linux-android` build failures.
**Treat Android/iOS V8 from Rust as unsupported.**

**Verdict: V8 is out.** Wrong size, wrong maintenance, wrong iOS story.

---

## (e) Headless Android WebView, and androidx.javascriptengine

### WebView + `@JavascriptInterface`

**Threading is the disqualifier.** From AOSP `WebView.java`:

```java
// constructor
if (mWebViewThread == null) {
    throw new RuntimeException("WebView cannot be initialized on a thread that has no Looper.");
}
// every public method calls:
private void checkThread() {
    if (mWebViewThread != null && Looper.myLooper() != mWebViewThread) {
        Throwable throwable = new Throwable(
            "A WebView method was called on thread '" + … + "'. " +
            "All WebView methods must be called on the same thread. " + …);
        …
        if (sEnforceThreadChecking) { throw new RuntimeException(throwable); }
    }
}
```
— https://github.com/aosp-mirror/platform_frameworks_base/blob/master/core/java/android/webkit/WebView.java
(`sEnforceThreadChecking` is on for any app targeting API 18+, so this is a hard throw.)
And `evaluateJavascript`'s own javadoc: "**This method must be called on the UI thread and the
callback will be made on the UI thread.**"

So the WebView is pinned to whichever Looper thread created it — in practice the UI thread — which
is precisely the thread kaya's Android backend needs for Compose. Every kaya call from JS would be
a thread hop.

**The one nuance in kaya's favour**, from Chromium's own WebView docs
(https://chromium.googlesource.com/chromium/src/+/main/android_webview/docs/java-bridge.md):

> "methods of Java objects are invoked on a private, background thread of WebView; this
> effectively means, that the interaction originated by the page must be served entirely on the
> background thread, while the main application thread (browser UI thread) is blocked"

i.e. `@JavascriptInterface` calls land on a WebView-internal background thread while the UI thread
blocks. That is a synchronous call in, but it does not free you from the UI-thread rule for
`evaluateJavascript`, `loadUrl`, `addJavascriptInterface` and construction.

**Type marshalling** — same Chromium doc, the authoritative list:

> "Argument and return values conversions are handled after Sun Live Connect 2 spec… What can pass
> the boundary between VMs is somewhat limited. This is what is allowed:
> - primitive values;
> - single-dimentional arrays;
> - "array-like" JavaScript objects (possessing "length" property, and also typed arrays from ES6);
> - previously injected Java objects (from JS to Java);
> - new Java objects (from Java to JS)…"

and from `WebView#addJavascriptInterface`'s javadoc: "The Java object's fields are not accessible."
So typed arrays *can* cross, but element-by-element through the Live Connect converter — **no
`ArrayBuffer` handle and nothing zero-copy**. For kaya's wire records that is a per-byte
conversion on every transaction.

**`WebMessagePort` as a byte channel.** The framework `android.webkit.WebMessage` carries only a
`String` (`public WebMessage(String data)`, `public String getData()` — the whole class, see
https://github.com/aosp-mirror/platform_frameworks_base/blob/master/core/java/android/webkit/WebMessage.java).
Binary needs **androidx.webkit**: `WebMessageCompat.TYPE_ARRAY_BUFFER` / `getArrayBuffer()`, gated
on `WebViewFeature.WEB_MESSAGE_ARRAY_BUFFER`, with `WebViewCompat.addWebMessageListener` as the
recommended bridge. Android's own guide
(https://developer.android.com/develop/ui/views/layout/webapps/native-api-access-jsbridge) is
explicit about both the affordance and the cost:

> "With the `WebMessageCompat` class, you can send `byte[]` arrays directly instead of serializing
> binary data into Base64 strings… **Limitation**: Even with byte arrays, the system copies data
> across the inter-process communication (IPC) boundary between the app and the isolated process
> that WebView uses to render the web content."

and, on the listener: "Threading: The listener callback runs on the application's main (UI)
thread." The same page marks `addJavascriptInterface` "Recommended: **No**" and says "We don't
recommend using this method for modern applications unless you are targeting very old Android
versions."

**Startup cost.** Google added an async pre-warm API precisely because it is bad — from
`androidx.webkit.WebViewCompat.startUpWebView`'s javadoc
(https://github.com/androidx/androidx/blob/androidx-main/webkit/webkit/src/main/java/androidx/webkit/WebViewCompat.java):

> "WebView startup is a time-consuming process that is normally triggered during the first usage of
> WebView related APIs. WebView startup happens once per process. For example, the first call to
> `new WebView()` can take longer to complete than future calls due to WebView startup being
> triggered. **The Android UI thread remains blocked till the startup completes.**"

It is still marked `@ExperimentalAsyncStartUp`.

**Can a WebView exist unattached to a window?** Yes — it is an ordinary `View`; nothing in the API
requires `addView`, and `evaluateJavascript` works on an unattached instance. But it must still be
constructed on a Looper thread and driven from that thread, and JS timers are pausable globally
(`pauseTimers()`: "Pauses all layout, parsing, and JavaScript timers for **all WebViews**. This is
a global request…"), so a headless instance is at the mercy of anything else in the process that
pauses.

**Size:** zero — it is a system component (Android System WebView / Chrome). That is its only real
advantage, and it also means the engine version varies per device.

### androidx.javascriptengine (JavaScriptSandbox / JavaScriptIsolate)

**Status is better than you'd expect — it is stable now, not alpha.** From
https://developer.android.com/jetpack/androidx/releases/javascriptengine :
`1.0.0` released **2025-07-02** (after ~3 years of alphas from 2022), and **`1.1.0` released
2026-05-06**. `1.1.0-alpha02` (2026-03-25) added a "message ports API to provide symmetric,
flexible, and low-overhead communication with JavaScript isolates. This allows strings and
ArrayBuffers to be sent and received without embedding them inside evaluations or named data
blobs."

**API** (from the AOSP source,
https://github.com/androidx/androidx/blob/androidx-main/javascriptengine/javascriptengine/src/main/java/androidx/javascriptengine/JavaScriptIsolate.java):

```java
ListenableFuture<JavaScriptSandbox> JavaScriptSandbox.createConnectedInstanceAsync(Context);
JavaScriptIsolate JavaScriptSandbox.createIsolate(IsolateStartupParameters);
ListenableFuture<String> JavaScriptIsolate.evaluateJavaScriptAsync(String code);
ListenableFuture<String> JavaScriptIsolate.evaluateJavaScriptAsync(AssetFileDescriptor|ParcelFileDescriptor);
void JavaScriptIsolate.provideNamedData(String name, byte[] inputBytes);   // JS: android.consumeNamedDataAsArrayBuffer(name)
MessagePort JavaScriptIsolate.createMessageChannel(String name, Executor, MessagePortClient);
void JavaScriptIsolate.setConsoleCallback(...);
```

**Can it call back into native code? No — confirmed.** Two citations:

1. `JavaScriptSandbox`'s own class javadoc: "JavaScriptSandbox represents a connection to an
   **isolated process**… **Code that is run in a sandbox does not have any access to data
   belonging to the original app unless explicitly passed into it by using the methods of this
   class.** This provides a security boundary between the calling app and the Javascript execution
   environment."
   (https://github.com/androidx/androidx/blob/androidx-main/javascriptengine/javascriptengine/src/main/java/androidx/javascriptengine/JavaScriptSandbox.java)
2. `evaluateJavaScriptAsync`'s contract is String-in / String-out: "The script should return a
   JavaScript String or, alternatively, a Promise that will resolve to a String… If the JS
   expression evaluates to another data type, then the Java Future resolves to an empty Java
   String… **Do not use this method to transfer raw binary data.**"

There is no `addJavascriptInterface` analogue, no host-function registration, and no JNI reach out
of the sandbox process. Your belief is correct: **androidx.javascriptengine cannot call native
code, by design.** It is for evaluating untrusted JS and getting a string back — the opposite of
what a GUI binding needs.

---

## (f) Everything else realistic

**Boa (Rust)** — https://github.com/boa-dev/boa , MIT, 7,527 stars, `pushed_at 2026-09-01`,
**v0.22 released 2026-08-28**, `boa_engine` on crates.io. Its own README: "Boa is an
**experimental** JavaScript lexer, parser and interpreter written in Rust 🦀, it has support for
more than 90% of the latest ECMAScript specification"; conformance dashboard at
https://boajs.dev/conformance . **Why it deserves a real look for kaya:** it is pure Rust, so it
cross-compiles to `aarch64-linux-android` and `aarch64-apple-ios` with `cargo build --target` and
no C toolchain, no NDK CMake, no xcframework — which is the entire build-system problem the other
options create, gone. It has native ES module support (`-m, --module` and a root-path module
resolver in its CLI). **Why it probably loses:** "experimental" is the maintainers' own word, it
is an AST-walking/bytecode interpreter that is materially slower than QuickJS, and 90% conformance
is well below QuickJS-ng's.

**Rhino (Mozilla, JVM)** — https://github.com/mozilla/rhino , 4,623 stars, `pushed_at
2026-09-01`, release **Rhino1_9_1_Release 2026-02-15**. Genuinely alive again. Disqualifier: it is
a Java-hosted engine, so kaya's Rust core reaches JS only through JNI→Java→Rhino, its performance
is poor, and there is no iOS story at all.

**Nashorn** — https://github.com/openjdk/nashorn , GPL-2.0, `pushed_at 2025-08-21`, no releases in
the API. Removed from the JDK in JDK 15 (JEP 372) and available only as a standalone library.
Disqualifier: needs `javax.script` and `invokedynamic`, neither of which Android's runtime
provides. Not an option.

**Duktape** — https://github.com/svaarala/duktape , MIT, 6,209 stars, but **last release v2.7.0 on
2022-02-19 and `pushed_at 2024-03-22`**. ES5.1 + a few ES2015 bits. Effectively frozen and behind
the language. Note that the old `square/duktape-android` repo **is now `cashapp/zipline`
(Apache-2.0, 2,299 stars, release 1.27.0 on 2026-04-02, `pushed_at 2026-09-01`) and it replaced
Duktape with QuickJS**: "Zipline works by embedding the QuickJS JavaScript engine in your
Kotlin/JVM or **Kotlin/Native** program. It's a small and fast JavaScript engine that's
well-suited to embedding in applications."
(https://github.com/cashapp/zipline/blob/trunk/README.md). Kotlin/Native means it ships on iOS —
so Zipline is a second production existence proof for QuickJS on both mobile platforms.

**JerryScript** — https://github.com/jerryscript-project/jerryscript , Apache-2.0, 7,419 stars,
release **v3.0.0 2024-12-18**, `pushed_at 2025-10-08`. Tiny (targets <64 KB RAM MCUs), ES5.1/ES2015
subset. Too small a language for kaya's guests.

**njs (nginx)** — https://github.com/nginx/njs , BSD-2-Clause, release **1.0.1 on 2026-09-02**
(today), very alive. But it is, by its own description, "**A subset of JavaScript language** to use
in nginx" — no modules the way a guest app needs, and its embedding API is shaped around nginx.
Not a general embeddable engine.

**XS / Moddable SDK** — https://github.com/Moddable-OpenSource/moddable , release **9.0.0 on
2026-08-05**, `pushed_at 2026-08-05`, very alive. XS is a genuinely conformant ES2024-class engine
for microcontrollers and it does ship on iOS and Android through Moddable's own tooling. The
disqualifiers for kaya: the licence is a GPL/LGPL mix (the repo has no single SPDX id in the API),
the embedding model is Moddable's `xsbug`/`mcconfig` toolchain rather than a plain C library
dropped into your build, and the community around embedding it in a *host app* (rather than
building a Moddable product) is thin.

**nodejs-mobile** — https://github.com/nodejs-mobile/nodejs-mobile , "Full-fledged Node.js on
Android and iOS", 869 stars, last release **v18.20.4 on 2024-10-07** with
`nodejs-mobile-v18.20.4-android.zip` at 57.3 MB and `-ios.zip` at 51.5 MB; `pushed_at 2026-04-30`
(the newest commit, 2025-11-13, is "tools: update android builds to use 16kb page size"). This
is the *literal* answer to "run my Node addon on Android" — it is Node with N-API, on both
platforms. **Disqualifiers:** Node 18 is past end-of-life, the artifact is ~50 MB per platform
before your own code, V8 must run jitless on iOS, and the original `JaneaSystems/nodejs-mobile` is
dead (last release 2021-08-16). Worth knowing it exists; not worth shipping a GUI toolkit on.

**Kotlin/JS** — compiles Kotlin *to* JS; it is not a JS engine and cannot run kaya's guest
JavaScript. Not applicable.

**The Android runtime itself (ART)** — has no JavaScript engine. The only JS in the platform is
the one inside the WebView. Not applicable.

**GraalJS / GraalVM** — no Android or iOS target for the JS engine. Not applicable.

---
---

# The three specific questions

## Q1. Which engines serve BOTH iOS and Android from one codebase, and what is the iOS build story?

Four real candidates, ranked by how little build machinery they cost.

### QuickJS-ng — the easiest iOS story of the lot

iOS is a **declared supported platform** in
https://github.com/quickjs-ng/quickjs/blob/master/docs/docs/supported_platforms.md (row: `iOS | *
| Limited testing`). There is no framework, no xcframework, no prebuilt anything to chase: it is
five C files plus headers, so you add them to your Xcode target or (better, for kaya) let Cargo
build them — `rquickjs` depends on `rquickjs-sys`, which compiles the vendored C with the `cc`
crate, so `cargo build --target aarch64-apple-ios` and `--target aarch64-linux-android` are the
whole story and libkaya keeps one build system. Existence proofs on the App Store side:
**cashapp/zipline** embeds QuickJS in Kotlin/**Native** (i.e. iOS) —
https://github.com/cashapp/zipline/blob/trunk/README.md — and **WebF**
(https://github.com/openwebf/webf) runs it inside Flutter apps on both platforms.
I verified the Android half by hand today: one `aarch64-linux-android21-clang` invocation, 780 KB
stripped (see §c).

### Hermes — real, but you inherit React Native's build machinery

Hermes is the default JS engine for React Native on **both** iOS and Android as of RN 0.84
(2026-02-11, https://reactnative.dev/blog/2026/02/11/react-native-0.84), so "Hermes runs on iOS" is
not in doubt. The build path is documented at
https://github.com/facebook/hermes/blob/static_h/doc/CrossCompilation.md : a **two-stage build**
(host `hermesc` first, because "the VM now contains Hermes bytecode which needs to be compiled by
Hermes"), then Android via `hermes/android/build.gradle` and Apple via
`hermes/utils/build-apple-framework.sh`. React Native consumes the result as a prebuilt
`hermes-engine` CocoaPod / `.xcframework` (RN 0.84 "now ships precompiled binaries on iOS by
default"). **There is no vendor-neutral, non-React-Native prebuilt Hermes for either platform** —
no standalone AAR, no standalone xcframework on SwiftPM or CocoaPods — so kaya would run that
two-stage build in CI for four Android ABIs plus device+simulator Apple slices, or take a
dependency on `com.facebook.react:hermes-android` and RN's pod.

### JavaScriptCore — free on iOS, decaying on Android

iOS/macOS: zero bytes, a public system framework
(https://developer.apple.com/documentation/javascriptcore), same C API. Android: the AAR from §a.
The catch is that this is *not one codebase's engine* — it is two different JavaScriptCores (the
device's current one on iOS, a 2024 WebKit snapshot on Android) with different feature sets and
different bug surfaces, and neither can load ES modules from C. If you accept "the same C API on
both", it is the cheapest iOS story there is; if you want one engine, it is not one engine.

### Boa — one `cargo build --target` and nothing else

Pure Rust: `aarch64-apple-ios`, `aarch64-apple-ios-sim` and `aarch64-linux-android` are ordinary
Rust targets, so there is literally no iOS build story to write. The cost is conformance and speed
(§f).

**Not candidates:** V8 (no supported Android or iOS from `rusty_v8` —
https://github.com/denoland/rusty_v8/issues/1640 still open; and jitless on iOS), Android WebView
and androidx.javascriptengine (Android-only by construction), Rhino/Nashorn (JVM).

---

## Q2. App Store Review Guideline 2.5.2 — the actual text, and what it forbids

### The current guideline text, verbatim

From https://developer.apple.com/app-store/review/guidelines/ , **"Last Updated: June 8, 2026"**:

> **2.5.2** Apps should be self-contained in their bundles, and may not read or write data outside
> the designated container area, nor may they download, install, or execute code which introduces
> or changes features or functionality of the app, including other apps. Educational apps designed
> to teach, develop, or allow students to test executable code may, in limited circumstances,
> download code provided that such code is not used for other purposes. Such apps must make the
> source code provided by the app completely viewable and editable by the user.

**Read it carefully: every prohibited verb is attached to code that is *downloaded or installed*.**
"download, install, or execute code which introduces or changes features or functionality of the
app" is the App Review formulation of the same rule the licence agreement states precisely, and it
says nothing whatever about interpreters, about JavaScript, or about code that shipped inside the
`.ipa` and was reviewed with it.

**The "WebKit framework or JavaScriptCore" carve-out you remember is not in guideline 2.5.2 and is
not in the current guidelines at all.** I searched the full rendered text of the 2026-06-08
guidelines: **"JavaScriptCore" appears 0 times, "interpret"/"interpreted"/"interpreter" appears 0
times, and "WebKit" appears exactly twice — both on the single line of 2.5.6.** That line reads:
"Apps that browse the web must use the appropriate WebKit framework and WebKit JavaScript. You may
apply for an entitlement to use an alternative web browser engine in your app. Learn more about
these entitlements for the EU and Japan." — which is about **browser apps**, not about embedding an
engine to run your own logic. kaya is not a web browser, so 2.5.6 does not
reach it.

### Where that clause actually lives: the licence agreement, and it has been relaxed

The clause is §3.3.2 of the **Apple Developer Program License Agreement**, and its history is the
whole answer.

**Then — the iOS Developer Program License Agreement of 2014-09-09** (archived PDF:
https://web.archive.org/web/20160328015841/https://developer.apple.com/programs/terms/ios/standard/ios_program_standard_agreement_20140909.pdf),
§3.3.2, verbatim:

> "An Application may not download or install executable code. **Interpreted code may only be used
> in an Application if all scripts, code and interpreters are packaged in the Application and not
> downloaded.** The only exception to the foregoing is scripts and code downloaded and run by
> Apple's built-in WebKit framework, provided that such scripts and code do not change the primary
> purpose of the Application by providing features or functionality that are inconsistent with the
> intended and advertised purpose of the Application as submitted to the App Store."

Two things to notice. First, even in the *strictest* historical version, **packaging your own
interpreter and your own scripts inside the app was expressly permitted** — that is what the
sentence says, in so many words. The WebKit (later "WebKit framework or JavaScriptCore") exception
was a carve-out **for downloaded code only**, exactly as you suspected. Second, this 2014 version names
**WebKit alone**; the "WebKit framework **or JavaScriptCore**" phrasing you remember is from a
later revision of that same sentence, which I could not retrieve in this pass — Apple's dated
PLA PDFs between 2015 and 2020 are not in the Wayback Machine under either URL pattern I tried.
That gap does not affect the conclusion, since both versions of the sentence are an exception for
**downloaded** code and both leave bundled interpreters permitted outright.

**Now — the current Apple Developer Program License Agreement, version LYL255, dated August 18,
2026** (https://developer.apple.com/support/downloads/terms/apple-developer-program/Apple-Developer-Program-License-Agreement-English.pdf,
§3.3.1(B) "Executable Code"), verbatim:

> "Except as set forth in the next paragraph, an Application may not download or install executable
> code. **Interpreted code may be downloaded to an Application** but only so long as such code: (a)
> does not change the primary purpose of the Application by providing features or functionality
> that are inconsistent with the intended and advertised purpose of the Application (b) does not
> bypass signing, sandbox, or other security features of the OS; and (c) for Applications
> distributed on the App Store, does not create a store or storefront for other Applications."

**The engine restriction is gone entirely.** There is no mention of WebKit or JavaScriptCore in the
clause any more; downloaded *interpreted* code is now allowed under three content conditions, run
by whatever interpreter you like. I verified this is not a 2026 novelty: the identical wording is in
the PLA archived at 2025-11-12 (version **LYL 223, October 8, 2025**,
https://web.archive.org/web/20251112113644/https://developer.apple.com/support/downloads/terms/apple-developer-program/Apple-Developer-Program-License-Agreement-English.pdf)
and already in the PLA of **2021-06-07**
(https://web.archive.org/web/20210607200805/https://developer.apple.com/support/downloads/terms/apple-developer-program/Apple-Developer-Program-License-Agreement-20210607-English.pdf,
§3.3.2). So the relaxation happened somewhere between 2014 and mid-2021 and has been stable for
five years.

### The answer to your actual question

**No. Neither 2.5.2 nor §3.3.1(B) forbids bundling a JavaScript interpreter and running JavaScript
that shipped inside the app bundle.** That was already the explicitly blessed case under the
strictest wording Apple ever used, and today's wording does not even restrict *downloaded*
interpreted code to Apple's engines. The rules kaya must respect are the three in §3.3.1(B) and
guideline 2.5.2's own qualifier — do not ship an update channel that changes what the app is, do
not become an app store, do not defeat the sandbox. A GUI toolkit whose guest scripts are compiled
into the bundle and reviewed with it satisfies all of them trivially.

**Where you would get into trouble** is the thing kaya is *not* doing: shipping a runtime that
downloads new guest programs over the air to change the app's function after review. Even that is
now permitted for *interpreted* code within (a)/(b)/(c), but it is the case App Review actually
looks at, and guideline **4.7** ("Mini apps, mini games, streaming games, chatbots, plug-ins, and
game emulators") then applies with its own list of obligations — including **4.7.2: "Your app may
not extend or expose native platform APIs or technologies to the software without prior permission
from Apple."** That sentence is worth remembering, because "expose native platform APIs to guest
scripts" is a literal description of what kaya's binding does. It only bites for software "**that
is not embedded in the binary**" (4.7's own opening words); bundle the guests and 4.7 does not
apply.

### Did the rules change in 2025/2026?

* The guidelines page itself is stamped **Last Updated: June 8, 2026**.
* **2.5.6** now reads: "You may apply for an entitlement to use an alternative web browser engine
  in your app. **Learn more about these entitlements for the EU and Japan.**" The EU half is the
  DMA browser-engine entitlement; the **Japan** half is new (Japan's Mobile Software Competition
  Act), and it is the visible 2025/2026 change in this area. Note again that this is the *browser
  engine* entitlement — it governs apps whose purpose is browsing the web, and it is not the
  permission an app needs to embed QuickJS or Hermes for its own logic.
* **4.7** is the clause that absorbed the "mini apps" language; its current text begins "Apps may
  offer certain software that is not embedded in the binary, specifically HTML5 and JavaScript mini
  apps and mini games, streaming games, chatbots, and plug-ins."
* §3.3.1(B) of the PLA was **renumbered** (it used to be §3.3.2) but its substance is unchanged
  since at least 2021.

*One point I could not verify with a primary source in this pass and which you should confirm
before relying on it:* whether Hermes' **baseline JIT** is enabled on iOS. Third-party iOS apps
cannot map writable-executable memory, so a JIT would have to be off there and Hermes would run
its interpreter over AOT bytecode — which is the configuration React Native has always shipped —
but I did not find an explicit statement in Hermes' docs saying so. This affects performance
expectations on iOS, not legality.

---

## Q3. Precedent for a non-JSC JavaScript engine in an App Store app

**Yes, overwhelmingly, and the flagship case is Hermes.**

* **Hermes has been the default React Native engine on iOS since React Native 0.70**, released
  **2022-07-08**: "React Native 0.70 will ship with Hermes as the default engine. This means that
  all new projects starting on v0.70 will have Hermes enabled by default." —
  https://reactnative.dev/blog/2022/07/08/hermes-as-the-default . Before that it was opt-in on iOS
  from RN 0.64. As of **React Native 0.84 (2026-02-11)** it is Hermes **V1** that is default "for
  React Native on both iOS and Android" — https://reactnative.dev/blog/2026/02/11/react-native-0.84 .
  Every React Native app on the App Store that has not opted out is shipping a third-party JS
  engine *and* precompiled Hermes bytecode inside its bundle. That is a very large population,
  including Meta's own apps.
* **QuickJS**: `cashapp/zipline` embeds QuickJS in Kotlin/JVM **and Kotlin/Native**, i.e. iOS
  (https://github.com/cashapp/zipline/blob/trunk/README.md), and **WebF**
  (https://github.com/openwebf/webf) ships QuickJS inside Flutter apps on iOS and Android.
* **Other bundled interpreters/VMs, same principle:** Unity ships IL2CPP-compiled game code; Lua
  has been bundled inside iOS games since the App Store opened; Flutter ships the Dart runtime
  (AOT on iOS); Python ships inside Pythonista and a-Shell. None of these are JavaScriptCore, and
  all of them are interpreters or VMs executing code that shipped in the bundle — the case §3.3.2
  has always allowed.
* JavaScriptCore being a *public* framework
  (https://developer.apple.com/documentation/javascriptcore) is a red herring for this question: it
  makes JSC free, not mandatory.

**Conclusion for kaya:** shipping QuickJS-ng (or Hermes) inside a kaya iOS app, running kaya guest
JavaScript that was bundled at build time, has clear precedent and no guideline against it.

---

# Recommendation for kaya, and what each route costs the binding

kaya's JS binding today is an **N-API addon**, which is a fact about the *shape of the native
layer*, not about the guest-visible surface. The four routes differ mostly in how much of that
native layer survives.

**1. QuickJS-ng, driven from Rust via `rquickjs` — the recommendation.**
The whole engine is 760 KiB per ABI, it is the only candidate with a real module loader (so
`import { app } from 'kaya'` can be a **native C module** — `JS_NewCModule` / `JS_AddModuleExport`
— with no bundler anywhere in kaya's build), `JS_GetUint8Array` gives the exact pointer+length that
kaya's wire records want with no copy, and both Android and iOS fall out of `cargo build --target`
because `rquickjs-sys` compiles the vendored C with the `cc` crate. `rquickjs` is maintained
(0.12.2, 2026-07-27, commits today). **The cost:** the N-API addon is rewritten against the
QuickJS C API. That is real work, but it is work on the layer kaya controls, and it deletes the
Node dependency from the desktop lanes too if you want it — one engine on five platforms instead
of Node on three and something else on two.
Second-order concerns to weigh: **no `Intl` ever** (ng says so outright), and **no upstream
debugger protocol** (issue open since 2023, a maintainer said 2026-04-15 they are looking at
merging a transport-less core).

**2. Hermes — the only route that keeps the addon.**
`API/napi` implements Node-API v10 "directly on Hermes VM internals" and its README's claim is that
addons "run on Hermes **without modification**". If that holds, kaya's existing addon loads on
Android and iOS with a rebuild. That is a very large prize. **The risks are equally large:** the
code is four months old (first commit 2026-05-12), it is **not in the `260318099.0.0-stable`
branch**, no React Native release carries it, and Hermes has no runtime `import` at all, so kaya
would need a bundling step for guest modules that QuickJS does not need. Plus the two-stage
cross-compile and no vendor-neutral prebuilt artifact for either platform. Worth a spike — build
`hermesNapi` for `aarch64-linux-android` and try to `dlopen` kaya's addon against it — but not
worth betting the milestone on before that spike.

**3. JavaScriptCore — cheap on iOS, wrong on Android.**
10 MiB per ABI (20 MiB if anything wants `Intl`), an engine snapshot frozen in 2024 with no
maintainer publishing new ones, and no ES modules from C. The only reason to pick it is that iOS
costs zero bytes — and kaya would then be maintaining two different engines' quirks anyway.

**4. Rule out now:** V8 in every form (size, dead Android builds, no Rust Android/iOS support,
jitless on iOS), Android WebView (UI-thread-pinned, no zero-copy bytes, and Google's own guide
says don't use `addJavascriptInterface` for modern apps), and androidx.javascriptengine (cannot
call native code by construction).

**The App Store question is not a blocker for any of them** — see Q2. Bundled interpreter +
bundled scripts has been explicitly permitted since the strictest wording Apple ever published,
and today's licence agreement does not restrict the engine even for *downloaded* interpreted code.
