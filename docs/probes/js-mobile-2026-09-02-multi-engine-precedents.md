# One JS API, several engines — precedents

Research file, started 2026-09-02. Every claim carries a URL inline.
Charge: kaya's JS binding is Node-only today (libkaya IS the N-API addon,
resolving Node's API via dlsym out of the host process; guest runs in a
worker_thread; native pump thread hands occurrences to JS via a napi
threadsafe function). Goal: same JS API on iOS (JavaScriptCore, ruled)
and Android (engine TBD) plus the three desktops.

STATUS: complete, 2026-09-02. All seven charge items covered.

## The short version

1. **Bun implements Node-API on JavaScriptCore, completely (v10), in production,
   MIT-licensed.** `src/jsc/bindings/napi.cpp` + `src/runtime/napi/napi_body.rs`.
   That settles "can N-API run on JSC" — yes, and there are four more
   implementations besides (Node/V8, Deno/V8, Hermes, emnapi/wasm).
2. **Hermes has a first-party Node-API v10 implementation whose entire
   "Node half" is a struct of function pointers, `hermes_napi_host`, and the
   only one kaya needs is `post_task`.** That is the abstraction to copy.
3. **Every threadsafe-function implementation surveyed is the same algorithm**
   — mutex + condvar + FIFO + "wake the JS loop". Five codebases, three engines,
   five different wakes. Porting it is supplying one function.
4. **On iOS, JSC lets a native thread call JS directly** (the public C API takes
   `JSLock` on every entry point), so kaya's blocking-receive semantics are
   *simpler* there than on Node. The open problem is the run loop, not the call.
5. **JSI is the wrong abstraction for kaya** (unstable C++ ABI, no Node on
   desktop, you supply the engine anyway) — but RN's `JSCRuntime.cpp` is the
   best MIT worked example of the JSC-public-API object model kaya must write.
6. **Nobody has implemented N-API over the *public* JSC C API.** kaya's iOS
   value/handle layer is new work; the TSFN is not.

Sections were appended as each was finished, so they are NOT in charge order.
Order on disk: 5, 1, 7, 2, 6, Appendix A, §5 addendum, 4, 3.
Reading order for kaya: **5 (N-API as a portable ABI) first**, then 5.7 and the
§5 addendum, then 7 (blocking receive), then Appendix A, then 1 (JSI), then
2/6, then 3/4 (the WebView projects — mostly a catalogue of costs kaya avoids).

---

# 5. Node-API (N-API) as a portable ABI beyond Node — THE HEADLINE

## 5.1 The answer up front: yes, Bun implements Node-API on JavaScriptCore

Bun's own docs: "Bun implements [Node-API] from scratch, so most existing
Node-API extensions work with Bun out of the box."
<https://bun.com/docs/runtime/node-api>. Bun's engine is JavaScriptCore, not
V8 — stated in Bun's LICENSE.md ("Bun statically links JavaScriptCore (and
WebKit) which is LGPL-2 licensed", <https://github.com/oven-sh/bun/blob/main/LICENSE.md>).
So the whole of Node-API is running on JSC in a shipping, widely used runtime.
This is the single most direct precedent for kaya's charge.

### Where the code is (verified against `main`, 2026-09-02)

Bun has moved the implementation around; as of today it is split in three:

| path | lines | what it is |
|---|---|---|
| `src/jsc/bindings/napi.cpp` | 3,469 | the C++ half: value/object/function/string/typedarray/property surface, written against JSC's **internal** C++ API |
| `src/jsc/bindings/napi.h` | 1,036 | `NapiEnv`, `NapiRef`, the `toJS`/`toNapi` conversions |
| `src/runtime/napi/napi_body.rs` | 5,352 | the Rust half: env lifetime, cleanup hooks, async work, **and the entire threadsafe-function machinery** |
| `src/jsc/bindings/napi_handle_scope.{h,cpp}` | — | a GC-visible handle scope (see 5.3) |
| Bun's `src/jsc/bindings/` directory (NapiClass, NapiRef, NapiWeakValue, napi_external, napi_finalizer, napi_type_tag) | — | the object-model pieces |
| `src/runtime/napi/{js_native_api.h,js_native_api_types.h,node_api.h,node_api_types.h}` | — | the four public headers, **copied verbatim from `nodejs/node`** |

(Paths confirmed by listing the repo tree via the GitHub API:
`gh api 'repos/oven-sh/bun/git/trees/main?recursive=1'`. Browse at
<https://github.com/oven-sh/bun/tree/main/src/jsc/bindings> and
<https://github.com/oven-sh/bun/tree/main/src/runtime/napi>.)

Note for anyone reading older writeups: this used to live at
`src/bun.js/bindings/napi.cpp`, and Bun's non-JS code used to be Zig. On
today's `main` the tree contains **0 `.zig` files** and 1,532 `.rs` files
(measured from the same tree listing) — Bun's runtime is Rust now. That
matters only in that a copy-the-code plan is copying Rust + C++, not Zig.

### How complete is it?

- `src/jsc/bindings/napi.h` sets `static constexpr int DEFAULT_NAPI_VERSION = 10;`
  and Bun's own header README says the default `NAPI_VERSION` was raised to 10
  "so the v9/v10 APIs that Bun implements are declared without the includer
  opting in (#20772)"
  (<https://github.com/oven-sh/bun/blob/main/src/runtime/napi/README.md>).
  Node-API version 10 is current Node's level, so Bun is not tracking an old
  snapshot.
- The headers are **byte-identical copies of Node's own** except three
  documented divergences (the opaque `napi_env` tag is typedef'd to Bun's
  concrete `struct NapiEnv*`; the default version bump; a dropped
  `NAPI_EXPERIMENTAL` `#warning` block). Same README. That is the strongest
  possible statement of ABI intent: same headers, same struct layouts, same
  symbol names.
- Bun vendors and runs **Node's own Node-API test suite**:
  `test/napi/node-napi-tests/test/node-api/...`, including
  `test_threadsafe_function/` with the uncaught-exception variants
  (<https://github.com/oven-sh/bun/tree/main/test/napi/node-napi-tests/test/node-api>).
- Every one of the 24 functions kaya uses is implemented. I grepped the three
  implementation files for each name; all 24 resolve (17 in `napi.cpp`, the
  rest — including all three threadsafe-function entry points,
  `napi_get_typedarray_info`, `napi_get_null/undefined/boolean`,
  `napi_create_int32` — in `napi_body.rs`). Nothing kaya calls is missing.

### License

**Bun itself is MIT** (<https://github.com/oven-sh/bun/blob/main/LICENSE.md>,
first line: "Bun itself is MIT-licensed"). The LGPL-2 encumbrance in that file
is on the *statically linked JavaScriptCore/WebKit*, not on Bun's own bindings.
So `napi.cpp` / `napi_body.rs` are MIT source kaya could lift or study freely
with attribution. The LGPL question would only arise from linking WebKit's JSC
— and on iOS you link Apple's *system* JavaScriptCore.framework, which is a
different (and already-shipped-by-Apple) proposition.

## 5.2 How Bun's threadsafe function actually works — the part kaya needs

This is the whole mechanism, read out of
`src/runtime/napi/napi_body.rs` (<https://github.com/oven-sh/bun/blob/main/src/runtime/napi/napi_body.rs>):

The `ThreadSafeFunction` struct (line ~2443) carries exactly what you would
expect if you were reimplementing Node's `node_api_threadsafe_function.cc`
against a different loop:

```
pub(crate) struct ThreadSafeFunction {
    pub poll_ref: KeepAlive,              // ref/unref: keeps the loop alive
    pub(crate) thread_count: AtomicI64,   // acquire/release refcount
    pub(crate) lock: Mutex,
    pub(crate) blocking_condvar: Condvar, // NAPI_TSFN_BLOCKING back-pressure
    pub(crate) queue: TsfnQueue,          // LinearFifo<*mut c_void> + max_queue_size
    pub(crate) handle: bun_jsc::VmHandle, // <-- the cross-thread door
    pub(crate) dispatch_state: AtomicU8,  // Idle / Running / Pending
    pub(crate) closing: AtomicU8, ...
}
```

- **Producer side** (`enqueue`, ~line 2869, called from
  `napi_call_threadsafe_function` at line 3293 via `ThreadSafeFunction::push`):
  take the mutex; if `block` and the queue is at `max_queue_size`, sleep on
  `blocking_condvar` — that is exactly N-API's `napi_tsfn_blocking`
  back-pressure; else return `napi_queue_full`. Push the `void*` into the FIFO.
  Call `schedule_dispatch()`.
- **The wake** (`schedule_dispatch`, ~line 2905): CAS the dispatch state to
  `Pending`; if it was `Idle`, build a `ConcurrentTask` and call
  `self.handle.post(self.loop_kind, ct)`. `VmHandle::post`
  (<https://github.com/oven-sh/bun/blob/main/src/jsc/VmHandle.rs>, line ~337)
  pushes onto the target loop's `concurrent_tasks` queue and calls
  `el.wakeup()`. If the VM has already closed, `post` returns
  `Posted::Refused(task)` and the caller frees it — a closed VM is a *refusal*,
  not a crash. **This is the entire cross-thread primitive: an MPSC queue plus
  a loop wakeup.** Nothing engine-specific about it.
- **Consumer side** (`on_dispatch`, ~line 2581): runs on the JS thread from the
  loop's task table; loops `dispatch_one()` until the queue is empty, then
  CAS `Running -> Idle`. The comment at line 2620 is worth stealing wholesale —
  it explains why the transition must be a CAS and not a store, or you get "a
  flaky lost-wakeup under load" when a producer enqueues between the empty-queue
  observation and the state store.
- Bun deliberately does **not** cap runs-per-tick where Node caps at 1,000
  (comment at line 2647).
- Teardown is the hard part and Bun spells the ownership rule at the top of the
  struct: "the JS thread owns this allocation until `finalize` or
  `env_teardown` sets `resources_released`; then the remaining `thread_count`
  references own it and the last one dropped frees it."

**Read for kaya:** N-API's threadsafe function is not a V8 feature and not a
libuv feature. It is (mutex + condvar + FIFO + "wake the JS loop"). kaya's
native pump thread already has the first three by construction; the only
per-engine work is the fourth.

## 5.3 The one genuinely engine-shaped piece: handle scopes and `napi_value`

`src/jsc/bindings/napi.h` line ~686:

```cpp
static inline JSValue toJS(napi_value val)
{ return JSC::JSValue::decode(reinterpret_cast<JSC::EncodedJSValue>(val)); }
```

So in Bun a `napi_value` **is** a bit-cast `JSC::EncodedJSValue` — a raw,
unrooted JS value. That only works because Bun also ships
`NapiHandleScopeImpl`, "an array of write barriers (so that newly-added objects
are not lost by GC) to JSValues", implemented as a real `JSC::JSCell` with its
own subspace and `DECLARE_VISIT_CHILDREN`
(<https://github.com/oven-sh/bun/blob/main/src/jsc/bindings/napi_handle_scope.h>).
The comment notes the one simplification over V8: "Unlike the V8 version,
pointer stability is not required (because `napi_value`s don't point into this
structure) so we can use a regular `WTF::Vector`."

This is the piece that does **not** port to Apple's shipped
JavaScriptCore.framework, because it uses JSC's *internal* C++ API — the
includes at the top of `napi.h` are `<JavaScriptCore/DeferGC.h>`,
`<JavaScriptCore/JSFunction.h>`, `<JavaScriptCore/VM.h>`, `<wtf/Lock.h>` — none
of which exist in the public framework. See §7 for what the public API gives you
instead (`JSValueProtect`/`JSValueUnprotect`, which is a rooting primitive, so
the same job is doable, just with a different representation for `napi_value`).

## 5.4 The other N-API-on-not-Node implementations

- **emnapi** — Node-API for Emscripten / wasi-sdk / clang-wasm32, MIT
  (<https://github.com/toyobayashi/emnapi>). Architecture: the Node-API surface
  is implemented in **JavaScript** (`library_napi.js` / `@emnapi/runtime`), with
  C shims on the wasm side; there is no engine C++ at all, so it runs on
  whatever engine the host browser or runtime has. Docs:
  <https://toyobayashi.github.io/emnapi-docs/>.
- **emnapi's threadsafe functions** are the clearest confirmation that the TSFN
  contract is loop-shaped, not engine-shaped. `packages/emnapi/src/threadsafe_function.c`
  (<https://github.com/toyobayashi/emnapi/blob/main/packages/emnapi/src/threadsafe_function.c>)
  is Node's own algorithm verbatim: `pthread_mutex_t mutex`, `pthread_cond_t*
  cond`, and a `uv_async_t async` whose callback `_emnapi_tsfn_async_cb` runs
  `_emnapi_tsfn_dispatch` on the JS thread. emnapi then *reimplements
  `uv_async`* in `packages/emnapi/src/uv/unix/async.c`
  (<https://github.com/toyobayashi/emnapi/blob/main/packages/emnapi/src/uv/unix/async.c>):
  under `EMNAPI_USE_PROXYING` it creates an `em_proxying_queue` and wakes the
  main thread with `emscripten_proxy_async(loop->em_queue, ...)`; otherwise it
  falls back to a JS-side `_emnapi_async_send_js(EMNAPI_NEXTTICK_TYPE, ...)`.
  Same three-line summary as Bun: queue + wake. Two projects, two engines, two
  wake primitives, one algorithm.

- **Deno** — a *fourth* independent implementation, in Rust, on V8 via `rusty_v8`.
  Source: <https://github.com/denoland/deno/tree/main/ext/napi>, organised
  deliberately like Node's: `js_native_api.rs` (the ECMAScript half),
  `node_api.rs` (the Node half), `value.rs`, `function.rs`, and — telling —
  `uv.rs`, a hand-written **libuv polyfill** (`uv_mutex_init`, `uv_async_*`) for
  addons that reach past Node-API into libuv. Its README says "Files are
  generally organized the same as in Node.js's implementation to ease in ensuring
  compatibility"
  (<https://github.com/denoland/deno/blob/main/ext/napi/README.md>). Deno reports
  `process.versions.napi === 10` (<https://docs.deno.com/runtime/fundamentals/node/>).
  Deno's TSFN (`ext/napi/node_api.rs`, `TsFn::call`, ~line 1064) is the same
  algorithm a third time: `queue_size` mutex + `queue_cond` condvar for
  `napi_tsfn_blocking` back-pressure, then `self.sender.spawn(|scope| ...)` —
  deno_core's cross-thread task spawner, which runs the closure on the isolate's
  own thread with a `v8::PinScope` in hand. MIT licensed
  (`// Copyright 2018-2026 the Deno authors. MIT license.`).
- **Electron** — not an independent implementation; it embeds Node itself
  (<https://www.electronjs.org/blog/electron-internals-using-node-as-a-library>).
  Worth knowing only for one thing: runtimes that are not Node have dropped
  support for **external buffers** (`napi_create_external_buffer`), Electron
  among them — see nodejs/node-addon-api's own doc
  <https://github.com/nodejs/node-addon-api/blob/main/doc/external_buffer.md>.
  kaya does not use external buffers (it copies into `Uint8Array`), which is
  lucky: the copy is the portable choice.
- **`node-api-headers`** — the headers alone, published to npm and maintained by
  the Node project so an addon can build without a Node checkout
  (<https://www.npmjs.com/package/node-api-headers>). This is what kaya would
  compile its addon against on iOS/Android, where there is no Node install.

## 5.5 The structural fact that makes all this work: the header split

Node's own docs state the design intent explicitly:

> "The Node-APIs associated strictly with accessing ECMAScript features from
> native code can be found separately in `js_native_api.h` and
> `js_native_api_types.h` ... in order to allow implementations of Node-API
> outside of Node.js."
> — <https://nodejs.org/api/n-api.html>

Counted on today's `main`: `src/js_native_api.h` declares **134** `NAPI_EXTERN`
functions and mentions "threadsafe" **zero** times; `src/node_api.h` declares
**35**, and every threadsafe-function entry point is in *that* file
(<https://github.com/nodejs/node/blob/main/src/js_native_api.h>,
<https://github.com/nodejs/node/blob/main/src/node_api.h>).

That split maps exactly onto kaya's port:

- 21 of kaya's 24 calls are pure `js_native_api.h` — value creation, property
  set, callback info, typed arrays, throw, coerce. Engine-only. No loop, no
  Node.
- 3 are `node_api.h`: `napi_create_threadsafe_function`,
  `napi_call_threadsafe_function`, `napi_release_threadsafe_function`. These are
  the ones that need a JS-thread loop, and they are the ones Bun, Deno and
  emnapi each had to write themselves against their own loop.

Also note the ABI promise the docs make — "This API will be Application Binary
Interface (ABI) stable across versions of Node.js ... intended to insulate
addons from changes in the underlying JavaScript engine" — and the version
caveat: NAPI_VERSION defaults to 8 if you do not `#define` it, and "As of
version 9, Node-API versions are no longer purely additive"
(<https://nodejs.org/api/n-api.html>).

## 5.6 Could kaya reuse this?

**Yes, and this is probably the answer.** The shape:

1. **Keep N-API as kaya's one JS-facing C ABI.** kaya already targets it, and it
   is the only JS embedding ABI with (a) a written engine-independence charter,
   (b) four independent implementations across three engines, (c) a stable ABI
   promise, and (d) headers shipped standalone. Nothing else on this list has
   more than one of those.
2. **On desktop, change nothing.** Node provides the implementation.
3. **On iOS/Android, kaya writes a small N-API *provider* over the host engine**,
   rather than porting its addon to a new API. The addon (`libkaya`) keeps
   exporting `napi_register_module_v1` and keeps calling the same 24 symbols;
   the provider resolves them. Today kaya finds them by `dlsym` out of the Node
   host — on a phone it links them out of its own provider instead. That is a
   *smaller* change than kaya's current dlsym trick, not a bigger one.
4. **Size the provider honestly.** 24 functions, not 169. Concretely:
   - ~18 are one-liners against JSC's public C API (`JSValueMakeNumber`,
     `JSObjectSetProperty`, `JSValueToStringCopy`, `JSObjectMakeTypedArray`,
     `JSObjectGetTypedArrayBytesPtr`, `JSObjectMakeFunctionWithCallback`, …).
   - `napi_value` representation is the one real design decision, because Bun's
     bit-cast-`EncodedJSValue` trick needs JSC internals kaya will not have on
     iOS (§5.3). The public-API answer is `napi_value == JSValueRef` plus a
     handle scope built on `JSValueProtect`/`JSValueUnprotect` — a Vec of
     protected refs unprotected at scope close. Slower than Bun's, and
     completely legal on the shipped framework.
   - The three TSFN functions are the queue+condvar+wake algorithm above, and
     kaya can copy the *structure* from Bun (MIT), Deno (MIT) or emnapi (MIT)
     while supplying its own wake. On iOS the wake is
     `CFRunLoopPerformBlock`/`dispatch_async` onto the thread that owns the
     `JSContext`; kaya already owns that thread.
5. **Steal the two hard-won comments, not just the code.** Bun's CAS-not-store
   lost-wakeup note (`napi_body.rs` ~2620) and its ownership rule ("the JS
   thread owns this allocation until `finalize` or `env_teardown` sets
   `resources_released`; then the remaining `thread_count` references own it")
   are exactly the two bugs a from-scratch TSFN gets wrong.
6. **What kaya gives up:** nothing on desktop. On mobile, whatever the addon
   would have used beyond the 24 — and kaya's discipline of a *counted, named*
   24-function surface is what makes this tractable at all. Guard it: a gate
   that greps `libkaya` for `napi_` imports and refuses any symbol outside the
   declared 24 turns "the mobile provider is complete" into something mechanical
   rather than remembered.

**The one caveat.** Bun proves N-API-on-JSC is possible and gives a reference
implementation, but Bun's is written against JSC *internals* (`JSC::JSValue`,
`JSC::VM`, `WTF::Vector`, `DECLARE_VISIT_CHILDREN`), which Apple's shipped
JavaScriptCore.framework does not expose. So kaya can reuse Bun's *design and
its threadsafe-function code shape*, and must re-derive the value/handle layer
against `JSValueRef`. See §7 for exactly what the public API offers there.

## 5.7 ADDENDUM — the React Native ecosystem is itself moving JSI → Node-API

This belongs in §5 rather than §1 because of what it says about the choice.

- **Hermes now has a first-party Node-API v10 implementation**, on the
  `static_h` branch: `API/napi/`, 24 `.cpp` files
  (<https://github.com/facebook/hermes/tree/static_h/API/napi>). Its README:
  "This is an implementation of Node-API (N-API) v10 for the Hermes JavaScript
  engine. It allows native addons written against the Node-API ABI to run on
  Hermes without modification. The implementation is built directly on Hermes VM
  internals (not JSI), covering all non-experimental APIs through NAPI_VERSION
  10."
  (<https://github.com/facebook/hermes/blob/static_h/API/napi/README.md>)
- **The design of `hermes_napi_host` is the single most useful artifact in this
  whole document for kaya.** Hermes' README says: "Async work and thread-safe
  functions use a pluggable host integration interface (`hermes_napi_host`) that
  the host application provides." The struct is in
  <https://github.com/facebook/hermes/blob/static_h/API/napi/hermes_napi.h>, and
  it is **eight fields**:

  ```c
  struct hermes_napi_host {
    void (*post_work)(void* loop_data, void* work_data,
                      void (*execute)(void*), void (*complete)(void*, napi_status));
    bool (*cancel_work)(void* loop_data, void* work_data);
    void (*post_task)(void* loop_data, void* task_data, void (*callback)(void*));
    void* data;
    struct uv_loop_s* uv_loop;              // nullptr for embedders without libuv
    void (*fatal_exception)(void*, napi_env, napi_value);
    void (*ref_loop)(void* loop_data);
    void (*unref_loop)(void* loop_data);
  };
  ```

  "Fields left as nullptr preserve default behavior — in particular, async work
  and thread-safe function APIs will return `napi_generic_failure` if the
  relevant callbacks are not provided." And on `uv_loop`: "Embedders without
  libuv leave this nullptr (the default)."

  **kaya needs exactly one of these: `post_task`.** That is the whole "Node half"
  of the ABI for kaya's use. Everything else can be nullptr.
- `API/napi/hermes_napi_tsfn.cpp` (550 lines,
  <https://github.com/facebook/hermes/blob/static_h/API/napi/hermes_napi_tsfn.cpp>)
  is the algorithm a **fifth** time: `std::mutex mutex`,
  `std::condition_variable cond`, `std::queue<void*> queue`, `max_queue_size`,
  a `dispatch_pending` flag, and one call to
  `env->host_->post_task(env->host_->data, tsfn, tsfnDispatch)`. No libuv, no V8,
  no JSC. 550 lines of portable C++ over one function pointer.
- **`react-native-node-api`** (Callstack, MIT,
  <https://github.com/callstackincubator/react-native-node-api>) ships Node-API
  addons into React Native apps on iOS and Android, loading the `.node` through a
  TurboModule and initialising the module per JSI Runtime. Its current limitation
  is that it pins a build of Hermes from `static_h`, because RN has not shipped
  the Node-API-enabled Hermes yet.
- **React Native Windows already did this in production**: it uses a fork of
  Hermes that "exposes Node API instead of JSI, which is not ABI safe, thus
  ensuring ABI safety" (Callstack's writeup,
  <https://www.callstack.com/blog/announcing-node-api-support-for-react-native>).
- The counter-argument, from Hermes' own maintainer (tmikov) in
  <https://github.com/facebook/hermes/discussions/1393>: "JSI is by far the most
  practical way to easily develop native extensions, far easier than Node API",
  and "it is the only way to develop extensions that are compatible between all
  React Native engines: JSC, v8, Hermes"; Node-API is being added "primarily to
  enable existing native extensions to work with Hermes."

**Read for kaya:** the two candidate abstractions in this document are JSI and
Node-API. The people who built JSI are shipping a Node-API implementation
alongside it, and the reason given is ABI stability. kaya, whose core is Rust
behind a C ABI and whose whole engineering culture is about not hand-editing the
same thing in nine places, wants the C ABI with the stability promise.

---

# 1. React Native's JSI (`facebook::jsi::Runtime`)

## 1.1 What it actually is

One header and one source file:
`packages/react-native/ReactCommon/jsi/jsi/jsi.h` (2,266 lines) and `jsi.cpp`,
MIT (<https://github.com/facebook/react-native/blob/main/packages/react-native/ReactCommon/jsi/jsi/jsi.h>).
Hermes vendors its own identical copy at `API/jsi/jsi/`
(<https://github.com/facebook/hermes/tree/static_h/API/jsi/jsi>) — which is why
RN's own podspec excludes `jsi/jsi.cpp` when Hermes is in use, with the comment
"JSI is a part of hermes-engine. Including them also in react-native will violate
the One Definition Rule"
(<https://github.com/facebook/react-native/blob/main/packages/react-native/ReactCommon/jsi/React-jsi.podspec>).

The abstraction is a **pure-virtual C++ class**, `jsi::IRuntime` (the older name
`jsi::Runtime` is kept as a facade). Every JS operation is a virtual method the
engine backend overrides. Roughly:

- **Values**: `jsi::Value` — a tagged union of undefined/null/bool/number/
  Symbol/BigInt/String/Object. `jsi::Object`, `jsi::Array`, `jsi::ArrayBuffer`,
  `jsi::Function`, `jsi::Uint8Array`, `jsi::PropNameID`, `jsi::Symbol`,
  `jsi::WeakObject` are all `Pointer` subclasses wrapping an engine-owned
  `PointerValue*`, with `cloneObject`/`cloneString`/… virtuals for refcounting.
- **Native functions**: `using HostFunctionType = std::function<Value(Runtime&,
  const Value& thisVal, const Value* args, size_t count)>` (jsi.h line 217),
  installed with `virtual Function createFunctionFromHostFunction(const
  PropNameID&, unsigned paramCount, HostFunctionType)` (line 577). That is the
  whole native-function story: a `std::function`, not a C function pointer, not
  a descriptor table.
- **Native objects**: `class HostObject` (line 222) with virtual
  `get`/`set`/`getPropertyNames`, installed by
  `virtual Object createObject(std::shared_ptr<HostObject>)` (line 518). Plus
  `NativeState` (line 255) for attaching an opaque C++ object to any JS object.
- **Bytes**: `class Buffer` (read-only `size()`/`data()`) and
  `class MutableBuffer` (line 167, `uint8_t* data()`), with
  `virtual ArrayBuffer createArrayBuffer(std::shared_ptr<MutableBuffer>)`
  (line 566) — **zero copy: the JS ArrayBuffer points at your bytes and holds
  your `shared_ptr` alive** — plus `virtual uint8_t* data(const ArrayBuffer&)`
  (line 570) to read the other direction in place, and
  `tryGetMutableBuffer` (line 642) which "directly points to arrayBuffer's data
  instead of copying". `createUint8Array(length)` and
  `createUint8Array(buffer, offset, length)` (lines 655-659).
- **Script**: `evaluateJavaScript`, `prepareJavaScript`/`evaluatePreparedJavaScript`
  (bytecode caching), `queueMicrotask`, `drainMicrotasks`.

## 1.2 Engine-neutral vs per-engine

Engine-neutral: everything above, plus `jsi.cpp`, `jsi-inl.h`, `decorator.h`
(a passthrough `RuntimeDecorator` for wrapping a runtime with instrumentation),
`threadsafe.h`, `JSIDynamic.{h,cpp}` (folly::dynamic conversion — *this* is the
one file that needs folly, and it is optional).

Per-engine: one `.cpp` implementing all the virtuals.

| backend | where | how big | notes |
|---|---|---|---|
| JSC | `ReactCommon/jsc/JSCRuntime.cpp` (<https://github.com/facebook/react-native/blob/main/packages/react-native/ReactCommon/jsc/JSCRuntime.cpp>) | **1,616 lines** | header is 12 lines: `std::unique_ptr<jsi::Runtime> makeJSCRuntime();` |
| Hermes | `hermes/API/hermes/hermes.cpp` in facebook/hermes | — | ships JSI in the engine itself |
| V8 | `react-native-v8`, `src/v8runtime/V8Runtime.cpp` (<https://github.com/Kudo/react-native-v8>) | — | third-party, Android-focused; iOS blocked by App Store JIT rules |

**The JSC backend is the one that matters for kaya, and it is a good sign.**
`JSCRuntime.cpp` includes exactly `<JavaScriptCore/JavaScript.h>` — the *public*
C API, the same one Apple ships in the iOS framework — plus the C++ standard
library. It roots values with `JSValueProtect` (lines 516, 576, 943). So the
full JSI surface over Apple's public JSC is 1,616 lines, and someone has already
written and shipped it under MIT.

Its gaps are instructive for what the public JSC C API cannot do:
`createArrayBuffer(MutableBuffer)` is `throw std::logic_error("Not implemented")`
(line 1149) — i.e. **no zero-copy adopt-my-bytes on JSC in RN's implementation**
(JSC's `JSObjectMakeArrayBufferWithBytesNoCopy` in `JSTypedArray.h` exists; RN
just never wired it) — and `createWeakObject`/`lockWeakObject` are marked
`// TODO: revisit this implementation` and are not actually weak (lines 1120-1130).
Reading the other direction *does* work: `data(const ArrayBuffer&)` is
`JSObjectGetArrayBufferBytesPtr` (line 1087).

## 1.3 The layer above: TurboModules and codegen

JSI is the floor. The developer-facing layer is **TurboModules**: you write a
TypeScript/Flow spec, RN's **codegen** emits a C++ spec class plus ObjC/Java
glue, and your native module registers as a `HostObject` reachable at
`global.__turboModuleProxy`. The C++ core lives at
`ReactCommon/react/nativemodule/core/` and the platform holders at
`ReactAndroid/src/main/jni/react/turbomodule/` and `React/Base/RCTCallInvoker.*`
(paths from the RN tree listing). The point of codegen is that the *same*
TypeScript spec produces the Java, ObjC and C++ sides, so the three cannot drift
— structurally the same argument kaya makes for `crates/kaya/src/spec.rs` and
`tools/gen-bindings.py`.

## 1.4 Threading

JSI itself declares no threading model — it forbids one. jsi.h line 333: "The
APIs must not be called from multiple threads concurrently. It is the user's
responsibility ensure thread safety when using IRuntime." And line 687: "this
object may not be thread-aware, but cannot be used safely from multiple threads
at once. The application is responsible for ensuring that it is used safely.
This could mean using the Runtime from a single thread, using a mutex, doing all
work on a serial queue, etc."

The thread-crossing primitive is therefore *outside* JSI, in
`ReactCommon/callinvoker/ReactCommon/CallInvoker.h`
(<https://github.com/facebook/react-native/blob/main/packages/react-native/ReactCommon/callinvoker/ReactCommon/CallInvoker.h>),
and it is tiny:

```cpp
using CallFunc = std::function<void(jsi::Runtime&)>;
class CallInvoker {
  virtual void invokeAsync(CallFunc&&) noexcept = 0;
  virtual void invokeAsync(SchedulerPriority, CallFunc&&) noexcept;   // default: drop priority
  virtual void invokeSync(CallFunc&&) = 0;
  virtual ~CallInvoker() = default;
};
```

Any native thread that wants to touch JS captures a
`std::shared_ptr<CallInvoker>` and calls `invokeAsync([](jsi::Runtime& rt){...})`;
the implementation (e.g. `BridgeJSCallInvoker`) queues it onto the JS thread's
message queue. `invokeSync` blocks the caller until the JS thread runs it. The
mirror-image `NativeMethodCallInvoker` carries JS→native calls the other way.
Note the callback receives `jsi::Runtime&` — the runtime reference is only handed
out *inside* the JS thread, which is how the "single thread" rule is enforced by
type rather than by discipline.

`HostObject`'s destructor is the one thing that escapes: "The C++ object's dtor
will be called when the GC finalizes this object... You have no control over
which thread it is called on... If you want to do JS operations, or any
nontrivial work, you should add it to a work queue, and manage it externally"
(jsi.h lines 224-232).

## 1.5 Is JSI usable outside React Native, and what does it cost?

**The header and its CMake target: yes, cleanly.**
`ReactCommon/jsi/jsi/CMakeLists.txt` is the whole build
(<https://github.com/facebook/react-native/blob/main/packages/react-native/ReactCommon/jsi/jsi/CMakeLists.txt>):

```cmake
set(CMAKE_CXX_STANDARD 17)
add_library(jsi jsi.cpp)
target_include_directories(jsi PUBLIC ..)
```

No dependencies. jsi.h's includes are `<cassert> <cmath> <cstdint> <cstring>
<exception> <functional> <memory> <string> <vector>` — C++17 STL only. **No
folly, no fbjni, no RN.** The folly dependency lives only in the optional
`JSIDynamic.{h,cpp}`.

**The CocoaPods packaging: no.** `React-jsi.podspec` ends with
`add_rn_third_party_dependencies(s)` and `add_rncore_dependency(s)` and, under
Hermes, `s.dependency "hermes-engine"`. So consuming JSI *as the RN pod* drags in
RN's third-party world; consuming it as source (two files, CMake target above)
does not. For kaya the second is the only sane route.

**The real costs, though, are these:**

1. **C++ ABI, not C ABI.** JSI is a pure-virtual C++ class hierarchy with
   `std::function`, `std::shared_ptr` and exceptions across the boundary. That
   is an unstable ABI by construction — the exact reason RN Windows moved to
   Node-API (§5.7) and the reason Hermes has a separate `API/hermes_abi/`
   directory for an ABI-stable C wrapper
   (<https://github.com/facebook/hermes/tree/static_h/API/hermes_abi>). kaya's
   core is Rust behind a C ABI; adopting JSI means a C++ shim layer in the
   middle, in a language kaya does not otherwise use for its core.
2. **You must supply the backend.** JSI is only an interface. For iOS you would
   take RN's `JSCRuntime.cpp` (MIT, 1,616 lines) — which then becomes kaya's to
   maintain, including its unimplemented `createArrayBuffer` and its non-weak
   weak refs. For Android you would take Hermes (a whole engine to vendor and
   build) or `react-native-v8`.
3. **No thread-crossing primitive.** JSI deliberately has none; `CallInvoker` is
   an interface with no implementation outside RN, so kaya writes the queue and
   the wake itself — which is the same work as §5.6 step 4, minus the N-API
   compatibility it would have bought.

## 1.6 Could kaya reuse this?

**Partly, and not as the abstraction.** The honest reading:

- kaya's JS binding is already an N-API addon. Adopting JSI means rewriting the
  binding against a C++ virtual interface, losing Node compatibility on desktop
  (Node exposes no JSI), and gaining an unstable C++ ABI. That is a net loss
  against §5.6.
- **What kaya should take from JSI is `JSCRuntime.cpp` as a worked example**, not
  as a dependency. It is the best available MIT-licensed answer to "how do you
  build a complete JS object model over Apple's public JavaScriptCore C API,
  including exceptions, typed arrays, host functions and rooting" — 1,616 lines
  someone has already debugged on real iOS devices. kaya's N-API-over-JSC
  provider (§5.6) would make many of the same calls in the same order.
- **And take `CallInvoker` as the shape of the interface**, which Hermes has
  already generalised into `hermes_napi_host::post_task` (§5.7). One function
  pointer, "run this closure on the JS thread", is the correct amount of API for
  the thread-crossing problem. kaya should define exactly that and nothing more.
- One concrete borrow: JSI's `MutableBuffer` +
  `createArrayBuffer(shared_ptr<MutableBuffer>)` is the right *shape* for kaya's
  wire bytes if it ever wants to stop copying — the JS ArrayBuffer holds a
  `shared_ptr` to native storage and releases it at GC. kaya copies today; if
  copying ever shows up in a measurement, this is the pattern, and note that RN's
  own JSC backend does not implement it.

---

# 7. The blocking-receive question: getting a native-thread event INTO the JS thread

kaya's current shape: a native pump thread blocks in `kaya_next_occurrence`,
hands each record to JS through a napi threadsafe function, and waits on a
condvar for the JS callback to return. The question is what replaces the middle
step on each engine.

## 7.0 The finding first

**Every implementation surveyed uses the same algorithm, and the only
per-engine part is one function: "run this closure on the JS thread".** Five
independent codebases, five engines/loops:

| project | engine | queue + back-pressure | the wake |
|---|---|---|---|
| Node.js | V8 | `node_api_threadsafe_function.cc` | `uv_async_send` |
| Bun | JSC (WebKit internals) | `Mutex` + `Condvar` + `LinearFifo` (`napi_body.rs` ~2443) | `VmHandle::post(kind, ConcurrentTask)` → `el.wakeup()` |
| Deno | V8 (rusty_v8) | `queue_size` Mutex + `queue_cond` Condvar (`node_api.rs` ~1064) | `sender.spawn(|scope: &mut v8::PinScope|…)` |
| Hermes | Hermes VM | `std::mutex` + `std::condition_variable` + `std::queue<void*>` (`hermes_napi_tsfn.cpp`) | `host->post_task(host->data, tsfn, tsfnDispatch)` — **a host-supplied function pointer** |
| emnapi | any (wasm) | `pthread_mutex_t` + `pthread_cond_t` (`threadsafe_function.c`) | `uv_async_t` reimplemented as `emscripten_proxy_async` (`uv/unix/async.c`) |

URLs for all five are in §5. So "port the TSFN" is not a port; it is supplying
one `post_task`. Hermes has already carved that out as the API
(`hermes_napi_host`, §5.7) and it is the design kaya should copy verbatim.

## 7.1 Per engine: can a NATIVE thread call a JS function directly?

### JavaScriptCore (iOS — kaya's ruled engine) — **yes, and this is unusual**

JSC is the one engine on this list where a native thread may legally call into
JS directly, because the public API locks for you.

- Apple's own header, `Source/JavaScriptCore/API/JSVirtualMachine.h`:
  "An instance of JSVirtualMachine represents a single JavaScript 'object space'
  or set of execution resources. **Thread safety is supported by locking the
  virtual machine, with concurrent JavaScript execution supported by allocating
  separate instances of JSVirtualMachine.**"
  (<https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSVirtualMachine.h>)
- The lock is `JSC::JSLock`, and `Source/JavaScriptCore/runtime/JSLock.h` states
  the rule: "To make it safe to use JavaScript on multiple threads, it is
  important to lock before doing anything that allocates a JavaScript data
  structure or that interacts with shared state such as the protect count hash
  table. The simplest way to lock is to create a local `JSLockHolder` object in
  the scope where the lock must be held... The lock is recursive so nesting is
  ok."
  (<https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/runtime/JSLock.h>)
- **And the public C API takes it for you on every call.** Measured on today's
  WebKit `main`: `Source/JavaScriptCore/API/JSValueRef.cpp` contains 41
  occurrences of `JSLockHolder` and `JSObjectRef.cpp` 32 — one at the top of
  essentially every exported entry point
  (<https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSValueRef.cpp>,
  <https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSObjectRef.cpp>).
  So `JSObjectCallAsFunction` from kaya's pump thread is legal: it blocks until
  the JS thread is out of JS, takes JSLock, runs, returns.

  **This means kaya's blocking-receive semantics fall out for free on iOS.** The
  pump thread's "wait for the JS handler to return before claiming the next
  occurrence" is just a direct call — no queue, no condvar, no TSFN. That is
  *simpler* than what kaya does on Node today, not harder. It also keeps the
  stall watchdog honest by construction, which is the property the charge says
  is deliberate.

- **Three caveats, each from a primary source:**
  1. `JSContextRef.h` on the group: "Contexts in the same group may share and
     exchange JavaScript objects. Sharing and/or exchanging JavaScript objects
     between contexts in different groups will produce undefined behavior. **When
     objects from the same context group are used in multiple threads, explicit
     synchronization is required.**"
     (<https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSContextRef.h>)
     The API call is locked; the *lifetime* of a `JSValueRef` you hold across
     threads is not. Anything kaya keeps (the guest's occurrence callback) must
     be `JSValueProtect`ed, and unprotected on a thread that holds the lock.
  2. **The run loop.** Both `JSVirtualMachine.h` and `JSContextRef.h` carry the
     same warning: "A virtual machine may need to run deferred tasks on a run
     loop, such as garbage collection or resolving WebAssembly compilations. By
     default, a virtual machine will use the run loop of the thread it was
     initialized on. **Currently, there is no API to change a JSVirtualMachine's
     run loop once it has been initialized.**" kaya's guest thread today blocks
     in a pump with no `CFRunLoop` spinning. On iOS, kaya must either create the
     `JSContext` on a thread that runs a real run loop, or accept that GC's
     deferred work never gets a turn. **This is the one iOS design constraint in
     this whole document that kaya's current architecture does not already
     satisfy**, and it should be settled before any code is written.
  3. Field reports agree the *API* is safe and the *values* are not. Cash App's
     engineering writeup on a production JSC threading bug: "The problem was that
     the parser was on a different background thread, which, by having a
     reference to the JSValue, was indirectly accessing the JSVirtualMachine
     across multiple threads," and their rule afterwards: "Avoid passing any
     JavaScriptCore objects across threads."
     (<https://code.cash.app/a-multithreading-saga-part-2>)

  4. **JSC drops the lock while your native callback runs.** Verified in
     `Source/JavaScriptCore/API/APICallbackFunction.h`, which wraps the call out
     to a `JSObjectCallAsFunctionCallback` in `JSLock::DropAllLocks
     dropAllLocks(globalObject);` (lines 69 and 120), and in
     `JSCallbackObjectFunctions.h`, which does the same at 14 sites
     (<https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/APICallbackFunction.h>).
     So while kaya's native function is executing on behalf of JS, the VM is
     *unlocked* and another thread may enter it. That is what makes a native
     callback able to call back into JS without deadlocking on a recursive lock
     — and it also means "the JS thread is inside my callback" is **not** mutual
     exclusion. Any kaya state the pump thread and a JS-invoked native function
     both touch needs its own lock; JSLock will not serve as one.

  So: direct call, yes. Shared `JSValueRef` lifetimes across threads, no —
  protect/unprotect under the lock.

### Hermes / JSI — **no. The JS thread must be handed a closure.**

jsi.h line 333: "The APIs must not be called from multiple threads concurrently.
It is the user's responsibility ensure thread safety when using IRuntime"; line
687: "this object may not be thread-aware, but cannot be used safely from
multiple threads at once... This could mean using the Runtime from a single
thread, using a mutex, doing all work on a serial queue, etc."
(<https://github.com/facebook/react-native/blob/main/packages/react-native/ReactCommon/jsi/jsi/jsi.h>)

The mechanism is `CallInvoker::invokeAsync(CallFunc&&)` where
`using CallFunc = std::function<void(jsi::Runtime&)>` — the runtime reference is
only ever handed to you *on* the JS thread
(<https://github.com/facebook/react-native/blob/main/packages/react-native/ReactCommon/callinvoker/ReactCommon/CallInvoker.h>).
`invokeSync` exists and blocks the caller, which is kaya's blocking-receive
shape, but it is the caller blocking on a queued item, not a direct call.

### V8 (Node, Deno, react-native-v8) — **no; isolate is thread-confined**

Node's answer is the threadsafe function over `uv_async_send`. Deno's is
`sender.spawn(|scope: &mut v8::PinScope| …)` — deno_core's cross-thread task
spawner, which runs the closure on the isolate's thread with a scope in hand
(`ext/napi/node_api.rs` ~1099,
<https://github.com/denoland/deno/blob/main/ext/napi/node_api.rs>). Either way
the isolate belongs to one thread at a time and the crossing is a posted task.

### QuickJS — **no cross-thread call at all. Strictly single-threaded per runtime.**

- Bellard's own manual: "JSRuntime represents a Javascript runtime corresponding
  to an object heap. Several runtimes can exist at the same time but they cannot
  exchange objects. **Inside a given runtime, no multi-threading is supported.**"
  (<https://bellard.org/quickjs/quickjs.html>)
- `quickjs.h` itself, on the stack guard: "/* should be called when changing
  thread to update the stack top value used to check stack overflow. */ `void
  JS_UpdateStackTop(JSRuntime *rt);`"
  (<https://github.com/bellard/quickjs/blob/master/quickjs.h>) — i.e. the runtime
  caches the *creating thread's* stack pointer, so another thread calling in
  makes the overflow check nonsense.
- quickjs-ng's threading doc says the same and names the only mutex in the
  engine: "QuickJS runtimes are single-threaded by design. The `JSRuntime` struct
  has no internal mutexes protecting its general state"; the sole
  `js_atomics_mutex` protects `SharedArrayBuffer` atomics, not the runtime. Its
  recommended patterns are "context per thread" or "a dedicated single-thread
  executor and lock"
  (<https://github.com/quickjs-ng/quickjs/blob/main/docs/threading.md>).
- Consequence: with QuickJS, kaya's pump thread cannot touch JS at all. It must
  push onto its own queue, wake the JS thread by some non-JS means (an eventfd, a
  pipe, a condvar), and the JS thread must run a loop that drains the queue and
  then drains promise jobs with `JS_ExecutePendingJob`. That is the poll model,
  and it is the only model QuickJS offers.

### Wasm / emnapi — **no; proxy to the owning worker**

`emscripten_proxy_async(loop->em_queue, …)`, or a JS-side `postMessage`-shaped
fallback (§5.4). A wasm worker cannot enter another worker's JS at all.

## 7.2 What this means for kaya's three targets

- **iOS / JavaScriptCore:** direct call is available and is the simplest correct
  answer. Blocking-receive is free. Open question is the run loop (7.1 caveat 2),
  not the call.
- **Android / engine TBD:** none of the candidates gives you a direct call.
  Whatever kaya picks (Hermes, V8, QuickJS), the shape is queue + `post_task`.
  Note the platform asymmetry: **Android ships no embeddable system JS engine**
  — even JSC on Android is a bundled third-party build
  (`jsc-android`, built out of a WebKit branch, maintained by the RN community:
  <https://github.com/react-native-community/jsc-android-buildscripts>, shipped as
  <https://www.npmjs.com/package/@react-native-community/javascriptcore>). So on
  Android every option costs binary size, and the choice is about size, JIT
  policy and licensing rather than availability. If kaya wants one JS
  implementation shared with iOS, `jsc-android` is the way to have literally the
  same engine on both phones; if it wants Node-API for free, Hermes `static_h`
  already has it (§5.7).
- **Desktop / Node:** unchanged.

The design that unifies all three is Hermes' `post_task`: kaya defines one
host-integration function pointer, implements it three ways (libuv async on
Node — already done for it; `CFRunLoopPerformBlock`/`dispatch_async` on iOS if
kaya chooses the queued route over the direct call; a looper/pipe on Android),
and the queue+condvar+FIFO above it is written once, portable C, copied in
structure from any of the five MIT implementations.

---

# 2. NativeScript's runtime

## 2.1 Which engines (verified today, not from memory)

**Both platforms are V8 now.** NativeScript's iOS runtime *used* to be
JavaScriptCore and was rewritten onto V8:

| repo | description (from the GitHub API) | last push | license |
|---|---|---|---|
| `NativeScript/ios-runtime` | "NativeScript for iOS using JavaScriptCore" | 2023-01-13 | Apache-2.0 |
| `NativeScript/ns-v8ios-runtime` (redirects to `NativeScript/ios`) | "NativeScript for iOS and visionOS using V8" | active (2026-09-02) | — |
| `NativeScript/android-runtime` (redirects to `NativeScript/android`) | "NativeScript for Android using v8" | active (2026-09-02) | Apache-2.0 |

(<https://github.com/NativeScript/ios>, <https://github.com/NativeScript/android>,
<https://github.com/NativeScript/ios-runtime>.)

**Why they moved** — from their own announcement
(<https://blog.nativescript.org/the-new-ios-runtime-powered-by-v8/>): their
customised JavaScriptCore "had significantly diverged from the main repository",
making each upgrade cost "up to 3 person-months"; V8 is "embedding friendly";
V8's heap snapshots have no JSC equivalent and cut startup of simple apps by
over 30%; and V8's **JIT-less mode**, added in early 2019, is what made V8 legal
on iOS at all (iOS forbids runtime-allocated executable memory).

**This is a directly relevant data point for kaya's ruling.** A serious
cross-platform project measured "maintain a JSC fork" at 3 person-months per
upgrade and left. kaya's situation is different in the one way that matters:
kaya would use Apple's *shipped system* JavaScriptCore.framework on iOS, not a
fork of WebKit — zero upgrade cost, zero binary size, but also zero control over
the version, and only the public API surface (§5.3, §1.2).

## 2.2 How "one JS API across both" is actually achieved

Not by an abstraction layer. By **two things stacked**:

**(a) Build-time metadata generation, per platform.** From NativeScript's own
deep-dive
(<https://github.com/NativeScript/NativeScript/wiki/Deep-dive:-How-NativeScript's-JS--native-bindings-work>):
on iOS a clang-based generator "searches for headers using clang's HeaderSearch
API, and traverses them using clang's RecursiveASTVisitor", builds `Meta` objects
for every declaration, serialises them to a binary blob, and links that blob into
the app as a mach-o section via the `-sectcreate` linker flag — you can see the
committed artifact at `NativeScript/metadata-arm64.bin` and the tool at
`metadata-generator/` in <https://github.com/NativeScript/ios>. Android has a
completely separate generator (`test-app/build-tools/android-metadata-generator/`,
a Gradle/Java tool reading `.jar` files, in <https://github.com/NativeScript/android>).
The docs describe the result uniformly: metadata "contains all the necessary
information about each of the supported native classes, interfaces, protocols,
structures, enumerations, functions, variables, etc. and is generated at build
time by examining the native libraries from the iOS/Android SDKs"
(<https://docs.nativescript.org/guide/metadata>).

**(b) Runtime marshalling, per platform.** "Marshalling in NativeScript refers to
the conversion of JavaScript data types to native platform language
(Swift/Objective C and Kotlin/Java) data types and vice versa. The conversion is
handled implicitly by the NativeScript iOS and Android runtimes"
(<https://docs.nativescript.org/guide/marshalling/>). On iOS the work is in
`ArgConverter` (types) and `ClassBuilder` (which "uses Obj-C runtime helpers like
`class_addMethod` to construct classes from the metadata, and binds every aspect
of the class to JS via V8 APIs") plus `Interop.mm`/`FFICall.cpp` (libffi for
arbitrary C calls). On Android the equivalents are `JsArgConverter`,
`JsArgToArrayConverter`, `MetadataNode`, `CallbackHandlers` and a pile of JNI
(`JEnv`, `JniSignatureParser`, `JType`). The `__extends`-style subclassing the
charge asks about is `ClassBuilder` on iOS and `MetadataNode`'s extend callback
on Android — JS code writes `SomeNativeClass.extend({...})` and the runtime
synthesises a real ObjC/Java subclass whose methods trampoline into JS.

## 2.3 What is shared and what is not — measured

The two runtimes are **separate C++ codebases in separate repositories**, and the
"shared" infrastructure is duplicated by copy, not linked as a library. Measured
by comparing file basenames in the two trees today
(`NativeScript/runtime/*.{cpp,mm,h,hpp}` vs
`test-app/runtime/src/main/cpp/*.{cpp,h}`): 72 files on iOS, 79 on Android, and
**32 basenames appear in both** —

`ArgConverter, Base64, BuiltinLoader, ConcurrentQueue, Constants, ErrorEvents,
EventLoop, Events, HttpLoader, Interop, IsolateTracked, LazyGlobals,
ModuleBinding, ModuleInternal, ModuleInternalCallbacks, NativeScriptException,
NativeScriptPlatform, NsBuiltinModules, ObjectManager, Performance, Runtime,
SimpleAllocator, StructuredClone, StructuredSerialization, TextEncoding, Timers,
URLImpl, URLPatternImpl, URLSearchParamsImpl, WeakRef, WorkerWrapper, robin_hood`

Those are the engine-neutral parts — timers, URL, TextEncoder, structured clone,
workers, the object manager — and NativeScript maintains **two copies of each**.
The genuinely per-platform halves are the other ~40 files each: ObjC/libffi
(`ClassBuilder`, `FFICall`, `Interop.mm`, `DictionaryAdapter`, `ArrayAdapter`,
`FastEnumerationAdapter`, `UnmanagedType`) vs JNI (`JEnv`, `JType`,
`JniLocalRef`, `JniSignatureParser`, `FieldAccessor`, `ArrayElementAccessor`,
`DirectBuffer`, `DesugaredInterfaceCompanionClassNameResolver`).

The layer that is genuinely shared is **JavaScript**: `@nativescript/core` (MIT,
<https://github.com/NativeScript/NativeScript>) is a TypeScript framework that
papers over the two global surfaces. So NativeScript's answer to "one JS API,
two platforms" is: same engine on both, two hand-maintained native runtimes with
duplicated common code, and one cross-platform library written in TypeScript
above them.

## 2.4 Read for kaya

kaya is already structurally better positioned than this. NativeScript's problem
is that it exposes *the entire platform SDK* to JS, so its per-platform layer is
unbounded and must be generated from headers. kaya exposes **one wire protocol
with a fixed record set** — the per-platform layer is bounded, and kaya already
generates it from `crates/kaya/src/spec.rs`.

The transferable lessons are the two negatives:

1. **Two runtimes drift.** 32 duplicated filenames is what "we'll just keep them
   in sync" looks like after a decade. kaya's whole culture (check-mirror,
   check-symbol-parity, check-verbs) exists because of exactly this failure mode.
   Whatever kaya builds for iOS and Android, the engine-neutral half must be
   *one* compilation unit reached from both, not two — which is another argument
   for the N-API-provider shape in §5.6, where the neutral half is the 21
   `js_native_api.h` functions and the per-platform half is one `post_task`.
2. **Forking an engine is a recurring cost, quantified**: 3 person-months per
   upgrade, and it is why they left JSC.

---

# 6. Other "portable JS host" precedents

## 6.1 Tencent ScriptX — the closest thing to a general answer, and nobody talks about it

**<https://github.com/Tencent/ScriptX>**, Apache-2.0, C++17. Self-described as
"a versatile script engine abstraction layer" whose goal is that you can
"seamlessly switch between scripting engine and scripting language without
changing the code". The front end is `ScriptEngine`, `EngineScope`,
`Local<T>`/`Global<T>`/`Weak<T>`, and `ClassDefine` for binding C++ classes; the
back ends are directories under `backend/`. Verified on today's `main`, the
backends are: **V8, JavaScriptCore, QuickJs, WebAssembly, Lua, Python, Ruby,
SpiderMonkey, WKWebView, and a `Template`** (a skeleton for adding your own).
Complete per the README: V8, JavaScriptCore, Node.js, QuickJS, WebAssembly, Lua.

The per-engine surface is spelled as a "trait" header set —
`backend/JavaScriptCore/trait/{TraitEngine,TraitException,TraitIncludes,TraitNative,TraitReference,TraitScope,TraitUtils}.h`
— which is a nicer factoring than JSI's one giant pure-virtual class, and it is
the only project here that ships a `Template` backend as documentation of the
port surface.

**Its threading answer is the same one as everybody else's** and is worth citing
because it is the sixth independent arrival at it: the docs say "Usually script
engines are single-threaded and do not support concurrent calls", enforce it with
`EngineScope`, and cross threads with `src/utils/MessageQueue.{h,cc}` — an
`ArbitraryData` payload, a `std::deque`, a `std::mutex`, a
`std::condition_variable`, and a `post` interface, with "some backends allow
multiple ScriptEngines to share a MessageQueue"
(<https://github.com/Tencent/ScriptX/blob/main/docs/en/Basics.md>,
<https://github.com/Tencent/ScriptX/blob/main/src/utils/MessageQueue.h>).

Caveat for kaya: C++17 with exceptions required, and 511 stars / last push
2025-08 — real but not a large ecosystem. Useful as a **design reference for the
port surface**, especially the trait split and the `Template` backend, more than
as a dependency.

## 6.2 Hermes' own `hermes_abi` — the ABI-stability admission

`API/hermes_abi/` in facebook/hermes (MIT), a C ABI wrapping Hermes with a C++
JSI shim on top. Its README states the problem plainly: "This directory contains
ongoing work to develop a stable C-based ABI for Hermes... The goal of this ABI
is to allow Hermes to be updated independently of the rest of a React Native
application. Note that this does not immediately solve the general problem of ABI
stability for RN extensions, since they are still written against the C++ JSI"
(<https://github.com/facebook/hermes/blob/static_h/API/hermes_abi/README.md>).
The header is plain C with vtable structs (`HermesABIManagedPointerVTable`,
`HermesABIBuffer`, `HermesABIMutableBuffer`, `HermesABIHostFunction`,
`HermesABIHostObject`) — i.e. someone re-derived a C ABI from JSI's shape. Read
this next to §5.7: two independent efforts inside Meta to put a stable C ABI
under or beside JSI.

## 6.3 quickjs-emscripten

**<https://github.com/justjake/quickjs-emscripten>** — QuickJS compiled to WASM
with TypeScript bindings, for running untrusted JS *inside* JS. `QuickJSContext`
is the sandbox; `QuickJSHandle` is a manually-disposed reference into the WASM
heap (`.dispose()` or you leak); host functions go in with `newFunction()` +
`setProp()`; values cross through `newString()`/`getString()` style converters.
Its async note is the QuickJS rule from §7 restated for embedders: "Once you
resolve an async action inside QuickJS, call `runtime.executePendingJobs()` to
run any code waiting on the promise." Relevant to kaya only as evidence that
QuickJS embedding is always poll-shaped.

## 6.4 deno_core / the `op` abstraction

deno_core is now merged into <https://github.com/denoland/deno> (its old repo is
a redirect stub). Its `op` layer (`#[op2]`, `JsRuntime`, extensions) is **not an
engine abstraction** — it is a codegen'd fast path *into V8 specifically*,
generating optimised V8 fast-API entry points from Rust signatures. The
engine-portable thing Deno built is its N-API implementation (`ext/napi`, §5.4),
not its ops. Worth saying explicitly because "Deno's op abstraction" sounds like
a candidate and is not one.

## 6.5 Boa

**<https://github.com/boa-dev/boa>**, MIT, a JS engine written in Rust. It is an
*engine*, not an abstraction — attractive to a Rust project because embedding is
pure-Rust with no C++ toolchain, but ECMAScript conformance is well below the
production engines and it has no mobile story. Realistic only as a fallback for
a host with no other option, not as kaya's phone engine.

## 6.6 Javy (Bytecode Alliance, ex-Shopify)

**<https://github.com/bytecodealliance/javy>**, Apache-2.0, "a JavaScript to
WebAssembly toolchain" that "takes your JavaScript code, and executes it in a
WebAssembly embedded JavaScript runtime" (QuickJS inside). Host interaction is
WASI file descriptors — `Javy.IO.readSync()` / `Javy.IO.writeSync()` — and the
output is a Wasm module (869 KB statically linked; 1-16 KB with dynamic linking
against a shared runtime module). Model is *run this script, get bytes out*, with
no event loop and no native callbacks; not applicable to a GUI binding, but the
size figures are a useful reference point for "what does bundling a JS engine
cost".

## 6.7 SpiderMonkey embedding

Mozilla's own embedding guidance
(<https://github.com/mozilla-spidermonkey/spidermonkey-embedding-examples>) is
that embedders should track **ESR** branches because "the master branch of
SpiderMonkey experiences a fair amount of breaking changes driven by the needs of
the Firefox browser", and the repo ships a per-release *Migration Guide*
documenting what broke. JSAPI is C++-only and moved wholesale to
`JS::Handle`/`JS::MutableHandle` rooting when the GC became moving. This is the
anti-pattern kaya is trying to avoid: a C++ API with no stability promise and an
annual migration.

## 6.8 ChakraCore / JsRT — effectively dead

**<https://github.com/chakra-core/ChakraCore>**, MIT, 9.2k stars, but the README
carries Microsoft's own statement: "Microsoft Edge no longer uses Chakra.
Microsoft will continue to provide security updates for ChakraCore 1.11 until 9th
March 2021 but do not intend to support it after that", and the project "is
planned to continue as a community project targeted primarily at embedded use
cases." Last push 2026-02. JsRT was a genuinely good C API design — worth a look
for API taste, and nothing else. Do not build on it.

## 6.9 Node-API for Electron / React Native Windows

Electron does not implement Node-API; it embeds Node
(<https://www.electronjs.org/blog/electron-internals-using-node-as-a-library>).
React Native Windows is the interesting one: it ships a Hermes fork
(<https://github.com/microsoft/hermes-windows>, MIT, actively pushed) that
"exposes Node API instead of JSI, which is not ABI safe"
(<https://www.callstack.com/blog/announcing-node-api-support-for-react-native>).
Same conclusion as §5.7 reached by a different team years earlier and shipped in
production.

## 6.10 The scoreboard

| candidate | one API? | engines | ABI | mobile-proven | license |
|---|---|---|---|---|---|
| **Node-API** | yes, by charter | Node/V8, Bun/JSC, Deno/V8, Hermes, wasm | **stable C** | yes (RN Windows prod; react-native-node-api on iOS+Android) | headers: Node's; impls MIT |
| JSI | yes | JSC, Hermes, V8 | unstable C++ | yes (all of React Native) | MIT |
| ScriptX | yes | V8, JSC, QuickJS, SpiderMonkey, Lua, Python, Ruby, wasm, WKWebView | unstable C++ | partly | Apache-2.0 |
| hermes_abi | no (Hermes only) | Hermes | stable C | experimental | MIT |
| deno ops | no | V8 only | — | no | MIT |
| ChakraCore JsRT | no | Chakra only | stable C | dead | MIT |

---

# Appendix A — kaya's 24 N-API calls mapped onto Apple's public JavaScriptCore C API

Not part of the charge, but it is what the charge is for, and it is cheap to
check while the headers are open. Availability annotations are read straight out
of WebKit's public headers (`Source/JavaScriptCore/API/`), which are the same
headers Apple ships in JavaScriptCore.framework.

| kaya's N-API call | public JSC C API | availability |
|---|---|---|
| `napi_create_function` | `JSObjectMakeFunctionWithCallback` | original API * |
| `napi_set_named_property` | `JSObjectSetProperty` + `JSStringCreateWithUTF8CString` | original API * |
| `napi_get_cb_info` | the `JSObjectCallAsFunctionCallback` signature's `argumentCount`/`arguments`/`thisObject` | — |
| `napi_throw_error` | write a `JSValueRef*` exception out, or `JSObjectMakeError` | — |
| `napi_get_value_double` | `JSValueToNumber` | original API * |
| `napi_get_value_string_utf8` | `JSValueToStringCopy` + `JSStringGetUTF8CString` | original API * |
| `napi_get_typedarray_info` | `JSValueGetTypedArrayType`, `JSObjectGetTypedArrayBytesPtr`, `JSObjectGetTypedArrayLength`, `JSObjectGetTypedArrayByteOffset`, `JSObjectGetTypedArrayBuffer` | **macOS 10.12 / iOS 10.0** |
| `napi_create_double` | `JSValueMakeNumber` | original API * |
| `napi_create_int32` | `JSValueMakeNumber` | original API * |
| `napi_create_bigint_uint64` | `JSBigIntCreateWithUInt64` | **macOS 15.0 / iOS 18.0** ⚠ |
| `napi_create_string_utf8` | `JSStringCreateWithUTF8CString` + `JSValueMakeString` | original API * |
| `napi_create_arraybuffer` | `JSObjectMakeArrayBufferWithBytesNoCopy` (with a `JSTypedArrayBytesDeallocator`) | **10.12 / 10.0** |
| `napi_create_typedarray` | `JSObjectMakeTypedArrayWithArrayBuffer` / `…AndOffset`, or `JSObjectMakeTypedArray` | **10.12 / 10.0** |
| `napi_create_object` | `JSObjectMake` | original API * |
| `napi_get_null` | `JSValueMakeNull` | original API * |
| `napi_get_undefined` | `JSValueMakeUndefined` | original API * |
| `napi_get_boolean` | `JSValueMakeBoolean` | original API * |
| `napi_create_threadsafe_function` | — (kaya writes it: queue + `post_task`, §5.2/§7) | — |
| `napi_call_threadsafe_function` | — (ditto) | — |
| `napi_release_threadsafe_function` | — (ditto) | — |
| `napi_call_function` | `JSObjectCallAsFunction` | original API * |
| `napi_get_and_clear_last_exception` | the `JSValueRef* exception` out-parameter every entry point takes | — |
| `napi_coerce_to_string` | `JSValueToStringCopy` | original API * |
| (`napi_value` rooting) | `JSValueProtect` / `JSValueUnprotect` | original API * |

\* "original API" = the header carries **no** `JSC_API_AVAILABLE` annotation at
all, i.e. it has been there since JavaScriptCore.framework was first public
(macOS 10.5; iOS 7.0, when the framework was opened to apps). Only the annotated
rows above have a floor.

Sources: <https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSTypedArray.h>,
<https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSValueRef.h>,
<https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/API/JSObjectRef.h>.

**Two things fall out of this table.**

1. **21 of the 24 are one-liners on an API that has been stable since 2016**, and
   the three that are not are the ones §5.7 shows Hermes reduced to a single
   host-supplied `post_task`. There is no cliff in this port.
2. **One real availability trap: `JSBigIntCreateWithUInt64` is iOS 18.0 / macOS
   15.0.** Every BigInt *creation* entry point in the public C API carries that
   annotation, as does `kJSTypeBigInt` and `JSValueIsBigInt`. If kaya's iOS floor
   is below 18, `napi_create_bigint_uint64` has to be implemented the long way —
   fetch `globalThis.BigInt` once and `JSObjectCallAsFunction` it with a string —
   which is correct on every version that has BigInt at all, and slower.
   Worth deciding deliberately rather than discovering on a device.
3. Note also that `JSObjectMakeArrayBufferWithBytesNoCopy` and
   `JSObjectMakeTypedArrayWithBytesNoCopy` take a `JSTypedArrayBytesDeallocator`,
   so **zero-copy in both directions is available on iOS** — better than RN's own
   JSI/JSC backend manages (§1.2, where `createArrayBuffer(MutableBuffer)` throws
   "Not implemented"). kaya copies today and should keep copying until something
   measures; the door is open if it ever does.

---

# Addendum to §5 — one honest negative, and one small existence proof

**The negative, stated plainly: I found no project implementing Node-API over
Apple's *public* JavaScriptCore C API (`JSContextRef`/`JSValueRef`).** Every
N-API-on-JSC implementation located uses JSC *internals*. Method: GitHub code
search over `napi + JSContextRef` and `napi_register_module_v1 + JSValueRef`
(2 hits total for the latter, both examined below), plus web search on the
question, plus reading Bun's, Hermes', Deno's and emnapi's implementations
directly. So §5.6's iOS plan is an **inference from two verified precedents**
(Bun proves N-API-on-JSC; RN's `JSCRuntime.cpp` proves a complete JS object
model over the public API — §1.2, Appendix A), not something someone has already
shipped. Treat the value/handle-scope layer as genuinely new work, budgeted
accordingly, and expect the first surprises there rather than in the TSFN.

**The small existence proof, with its caveat:**
`Sunrisepeak/mbun` (<https://github.com/Sunrisepeak/mbun>, "Rewrite Bun in
MC++ - Just for fun", 22 stars, active 2026-08) contains
`modules/jsc/src/runtime/napi_{core,objects,binary,async}.inc` plus a vendored
copy of Node's four headers. Its own header comment names the method:

> "CAP-NAPI core: env plumbing, primitive values, strings, errors, handle scopes,
> references... **Blueprint: bun-ref/src/jsc/bindings/napi.cpp +
> src/runtime/napi/napi_body.rs (function-by-function**; see
> runtime/napi/mbun_napi.h for the deviations)."

and `mbun_napi.h` documents its deviations from Bun explicitly (no
`BunClientData` iso-subspaces, so `NapiExternal` goes in
`vm.destructibleObjectSpace()`; the handle scope is a heap record owning a
`JSC::MarkedArgumentBuffer` rather than Bun's custom `JSCell`; `NapiEnv` is not
refcounted). **Caveat: it still links JSC internals** ("a mechanical port of
bun's Node-API layer onto the JSC internals this runtime already links"), so it
is not the public-API proof kaya wants. What it *does* prove is that Bun's
napi layer is legible and portable enough for an outsider to re-derive
function-by-function and write down where they diverged — which is exactly what
§5.6 asks kaya to do, one API tier lower.

(The other code-search hit, `blackboardsh/cottontail`'s `src/napi_bridge.cpp`,
6 stars and no license file, was not pursued.)

---

# 4. Tauri (v2)

Verified against the live `dev` branches on 2026-09-02: `tauri` **2.11.5**, `wry`
**0.56.1** (<https://raw.githubusercontent.com/tauri-apps/tauri/dev/crates/tauri/Cargo.toml>,
<https://raw.githubusercontent.com/tauri-apps/wry/dev/Cargo.toml>).

## 4.1 The webview layer (`wry`)

wry is a thin Rust wrapper over each OS's *system* webview; the module gating is
in <https://raw.githubusercontent.com/tauri-apps/wry/dev/src/lib.rs>:

| platform | wry module | widget | binding crate |
|---|---|---|---|
| macOS + iOS | `src/wkwebview/mod.rs` (+ `src/wkwebview/ios/`) | `WKWebView` | `objc2-web-kit` 0.3.2 |
| Windows | `src/webview2/mod.rs` | WebView2 (`ICoreWebView2`) | `webview2-com` 0.39 |
| Linux/BSD | `src/webkitgtk/mod.rs` | WebKitGTK | `webkit2gtk` **=2.0.2** (feature `v2_38`) |
| Android | `src/android/mod.rs` + `src/android/kotlin/*.kt` | `android.webkit.WebView` | `jni` 0.21 |

macOS and iOS share one module. Android's webview is built from Rust over JNI
(<https://raw.githubusercontent.com/tauri-apps/wry/dev/src/android/main_pipe.rs>:
`setWebChromeClient`, `addJavascriptInterface(ipc, "ipc")`, `setContentView`),
against Kotlin *templates* (`package {{package}}`) instantiated per app —
`WryActivity.kt`, `RustWebView.kt`, `RustWebViewClient.kt`, `Ipc.kt`, `Rust.kt`
— with tauri/crates/tauri/mobile/android-codegen/TauriActivity.kt layered on top.

## 4.2 IPC — two transports, chosen per call

`invoke()` in
<https://raw.githubusercontent.com/tauri-apps/tauri/dev/packages/api/src/core.ts>
is one line onto `window.__TAURI_INTERNALS__.invoke`, injected from
tauri/crates/tauri/scripts/{ipc,ipc-protocol,core,process-ipc-message-fn}.js
(<https://github.com/tauri-apps/tauri/tree/dev/crates/tauri/scripts>).

**(a) Custom protocol — the default.** `ipc-protocol.js` does a real
`fetch()` POST with `Tauri-Callback`, `Tauri-Error` and `Tauri-Invoke-Key`
headers and content type `application/json` or `application/octet-stream`. The
URL is `ipc://localhost/<cmd>` on macOS/iOS/Linux and
`http(s)://ipc.localhost/<cmd>` on Windows/Android (`core.js`). The Rust handler
is `pub fn get<R: Runtime>(…) -> UriSchemeProtocolHandler` in
<https://raw.githubusercontent.com/tauri-apps/tauri/dev/crates/tauri/src/ipc/protocol.rs>,
whose `parse_invoke_request` requires an `Origin` header (it is the ACL
principal). `application/octet-stream` becomes `InvokeBody::Raw(Vec<u8>)`.

**(b) `postMessage` fallback.** Always on Android (the Android webview cannot
read a request body); elsewhere only after a `fetch` rejection flips
`customProtocolIpcFailed`. Per platform wry defines `window.ipc.postMessage` as
`window.webkit.messageHandlers.ipc.postMessage` (macOS/iOS, `wkwebview/mod.rs`),
`window.chrome.webview.postMessage` (Windows, `webview2/mod.rs`),
`register_script_message_handler("ipc")` (Linux, `webkitgtk/mod.rs`), and an
`@JavascriptInterface fun postMessage(message: String?)`
(<https://raw.githubusercontent.com/tauri-apps/wry/dev/src/android/kotlin/Ipc.kt>).
**This path is string-only**, and the reply goes back as
`webview.eval(<generated JS source>)`
(tauri/crates/tauri/src/ipc/format_callback.rs).

## 4.3 Binary payloads and Channels — where the JSON stops

tauri/crates/tauri/src/ipc/mod.rs defines
`enum InvokeBody { Json(serde_json::Value), Raw(Vec<u8>) }` and
`pub struct Response`. The blanket `impl<T: Serialize> IpcResponse for T` is
`serde_json::to_string(&self)`, so **every ordinary command pays JSON**;
returning `tauri::ipc::Response` opts out and the handler emits the `Vec<u8>` as
`application/octet-stream` for JS to read with `response.arrayBuffer()`. Tauri's
own docs warn: "This can slow down your application if you try to return a large
data such as a file or a download HTTP response"
(<https://tauri.app/develop/calling-rust/>).

**Android is the documented hole**, in the source itself
(`ipc/mod.rs:55`): "On Android, `InvokeBody::Raw` is not supported. The enum will
always contain `InvokeBody::Json`. When targeting Android Devices, consider
passing raw bytes as a base64 `String`, which is still more efficient than
passing them as a number array."

**Channels** (native→JS streams,
<https://raw.githubusercontent.com/tauri-apps/tauri/dev/crates/tauri/src/ipc/channel.rs>)
serialise as the string `"__CHANNEL__:<id>"` and pick a transport by size,
against thresholds the maintainers benchmarked per webview — the constants and
their comments are worth quoting verbatim:

```rust
// 8192 byte JSON payload runs roughly 2x faster through eval than through fetch on WebView2 v135
const MAX_JSON_DIRECT_EXECUTE_THRESHOLD: usize = 8192;
// 1024 byte payload runs roughly 30% faster through eval than through fetch on macOS
const MAX_RAW_DIRECT_EXECUTE_THRESHOLD: usize = 1024;
```

Below threshold, `webview.eval()` the payload inline (raw bytes become
`new Uint8Array([…]).buffer`, i.e. a JSON number array); above, park it in
`ChannelDataIpcQueue` and eval a call that fetches it back over the custom
protocol. The older `emit` event system is JSON-string-only and `eval`-delivered;
the docs say "event payloads are always JSON strings making them not suitable for
bigger messages" and "The event system is not designed for low latency or high
throughput situations" (<https://tauri.app/develop/calling-frontend/>).

## 4.4 Mobile (Tauri 2)

- **iOS**: a real `WKWebView` via wry. Plugins are Swift classes subclassing
  `Plugin` (<https://github.com/tauri-apps/tauri/tree/dev/crates/tauri/mobile/ios-api/Sources/Tauri>)
  exported with `@_cdecl("init_plugin_<name>")`. Rust↔Swift is **swift-rs**:
  tauri/crates/tauri/src/ios.rs declares
  `swift!(pub fn run_plugin_command(id: i32, name, method, data: &SRString, callback: PluginMessageCallback, …))` —
  **JSON strings across a C boundary**. Dispatch on the Swift side is
  Objective-C selector lookup: `Selector(("\(invoke.command):completionHandler:"))`.
- **Android**: Kotlin plugins subclass `app.tauri.plugin.Plugin` with
  `@TauriPlugin`/`@PluginMethod`
  (<https://github.com/tauri-apps/tauri/tree/dev/crates/tauri/mobile/android/src/main/java/app/tauri/plugin>);
  the JNI `run_command` in tauri/crates/tauri/src/plugin/mobile.rs reflectively calls
  `runCommand(ILjava/lang/String;Ljava/lang/String;Ljava/lang/String;)V` with
  `serde_json::to_string(payload)`.
- One Rust API over both:
  `PluginHandle::run_mobile_plugin<T: DeserializeOwned>(command, payload)` —
  `serde_json::to_value` in, `serde_json::from_value` out.

## 4.5 Does Tauri ever use a bare JS engine? **No.**

- Maintainer `amrbashir`, <https://github.com/tauri-apps/tauri/issues/9773>
  (closed same day): "We only support using native webviews through wry atm,
  supporting an embedded chromium or another renderer is a tremendous amount of
  work."
- "Headless Tauri" (<https://github.com/tauri-apps/tauri/issues/1061>) floated a
  `headless: quickjs` mode in 2020 and was closed in 2021 by adding
  `visible: false` instead — the webview still runs the JS.
- The 2026 Tauri v3 proposal (<https://github.com/tauri-apps/tauri/issues/14944>)
  asked for JS in Node/Deno/Bun outside the webview; maintainer `FabianLars`
  answered that the plans are winit + a gtk4 backend, **Servo**
  (<https://github.com/versotile-org/tauri-runtime-verso>) and a CEF/Chromium
  webview on a `feat/cef` branch — all browser engines, not bare JS engines
  ("Servo is anything but a suitable replacement for system webviews… you're not
  even having CSS3").
- The pluggable seam is the `Runtime<T>` / `WebviewDispatch<T>` traits in
  tauri/crates/tauri-runtime/src/lib.rs; `tauri-runtime-wry` is the only first-party
  implementation.

## 4.6 Costs, concretely

- **No native handle into JS.** Every native→JS delivery is `eval(<generated
  source string>)` or a JS-initiated `fetch`. Rust can never hold a JS object or
  call a JS function by pointer.
- **JSON by default everywhere**; the docs call it "a JSON-RPC like protocol…
  all arguments and return data must be serializable to JSON"
  (<https://tauri.app/concept/inter-process-communication/>). Historical
  measurement in <https://github.com/tauri-apps/tauri/issues/5641>: 500 MB
  through `invoke` took 30 s against 5 s for a plain JSON read, the payload
  serialised three times and escaped into a JS string. Tauri 2's raw path and
  channels are the answer to that class; the JSON default remains.
- **The escape hatches are asymmetric**: raw bytes work everywhere except
  Android.
- **Two transports with per-webview benchmarked thresholds**, and response
  routing that forks on `cfg!(target_os = "macos") || cfg!(target_os = "ios")`.
- **Webview fragmentation** (<https://tauri.app/reference/webview-versions/>):
  Windows gets auto-updating Chromium; macOS gets whatever WebKit the OS shipped
  ("unsupported macOS versions do not receive WebKit updates"); Linux is pinned
  to `webkit2gtk = "=2.0.2"` against the distro's own library and "it is very
  hard to compile accurate information about WebKitGTK on the various distros";
  Android uses the device's WebView provider. FabianLars calls WebKitGTK
  "obviously the part of tauri that needs replacement the most".

## 4.7 Read for kaya

Tauri is the closest analogue to kaya in *shape* — Rust core, cross-platform, one
API on five targets — and it is the clearest illustration of the cost of the road
kaya did not take. Three things transfer:

1. **The eval-vs-fetch threshold constants are a gift.** 8192 bytes on WebView2,
   1024 bytes on macOS, measured, with the numbers written into the source beside
   the comment explaining them. That is the kaya house style, from another
   project, and it is the kind of number worth knowing exists before anyone
   argues about payload sizes.
2. **"JSON by default with a raw opt-out" degrades unevenly.** Tauri's raw path
   works on four platforms and silently becomes a JSON number array on the fifth,
   documented only in a source comment. kaya's `Uint8Array` copies are the
   uniform choice, and this is why uniformity was right: a per-platform
   fast-path that quietly falls back is worse than a slow path everywhere.
3. **The negative result is the useful one for the ruling.** Tauri has been asked
   repeatedly for a bare-JS-engine mode and has refused each time, and its v3
   answer is *more browser engines*. There is no Tauri precedent for kaya's
   question, and that itself is information: the WebView projects cannot get to
   where kaya is going, and kaya should not look to them for the mechanism.

---

# 3. Capacitor's bridge

Verified against `ionic-team/capacitor` **main @ `0c9e35de`** (2026-08-31);
`@capacitor/core` npm dist-tags today: `latest` = 8.5.1, `next` = 9.0.0-alpha.6
(<https://registry.npmjs.org/@capacitor/core>). The monorepo roots are `core/`,
`ios/`, `android/` (not `packages/core` — that path is stale in older writeups).

## 3.1 The model

`@capacitor/core` is a thin JS shim, not the bridge. Its public surface is
`Capacitor`, `registerPlugin`, `WebPlugin`, `CapacitorException` and a few
built-in plugins
(<https://github.com/ionic-team/capacitor/blob/main/core/src/index.ts>). The
actual bridge JS is a **separately rolled-up file**,
<https://github.com/ionic-team/capacitor/blob/main/core/native-bridge.ts> (1,161
lines, built by `core/rollup.bridge.config.js`), which the native layer *injects*
into the WebView at document start — it never ships as an app import.

| iOS | Android |
|---|---|
| [`ios/Capacitor/Capacitor/CapacitorBridge.swift`](https://github.com/ionic-team/capacitor/blob/main/ios/Capacitor/Capacitor/CapacitorBridge.swift) (756 L) | [`android/…/com/getcapacitor/Bridge.java`](https://github.com/ionic-team/capacitor/blob/main/android/capacitor/src/main/java/com/getcapacitor/Bridge.java) (1,633 L) |
| [`WebViewDelegationHandler.swift`](https://github.com/ionic-team/capacitor/blob/main/ios/Capacitor/Capacitor/WebViewDelegationHandler.swift) | [`MessageHandler.java`](https://github.com/ionic-team/capacitor/blob/main/android/capacitor/src/main/java/com/getcapacitor/MessageHandler.java) (157 L) |
| `CAPPlugin.h/.m`, `CAPPluginCall.*`, `CAPPluginMethod.*`, `CAPBridgedPlugin.h` | `Plugin.java`, `PluginCall.java`, `PluginHandle.java`, `PluginMethod.java` |
| [`JSExport.swift`](https://github.com/ionic-team/capacitor/blob/main/ios/Capacitor/Capacitor/JSExport.swift) | [`JSExport.java`](https://github.com/ionic-team/capacitor/blob/main/android/capacitor/src/main/java/com/getcapacitor/JSExport.java) |

(`CAPBridge.swift` survives only as a deprecated shell; the real class is
`CapacitorBridge`.) Plugins are located **by string** at call time:
`NSClassFromString(call.pluginId)` on iOS (`CapacitorBridge.swift:472`),
reflective `Method.invoke` in `PluginHandle.invoke` on Android (line 138) over
methods indexed by the `@PluginMethod` annotation.

## 3.2 How a call crosses

**iOS.** `WebViewDelegationHandler` conforms to `WKScriptMessageHandler` and
registers exactly **one** message name: `private let handlerName = "bridge"`,
then `contentController.add(self, name: handlerName)` (lines 18-22). JS posts
`win.webkit.messageHandlers.bridge.postMessage(data)` (`native-bridge.ts:960`).
`userContentController(_:didReceive:)` (line 192) reads a `type`
(`"message" | "js.error" | "cordova"`) and builds a `JSCall`. The **return path
is `evaluateJavaScript` with the JSON interpolated into a source string**, on the
main queue (`CapacitorBridge.swift:579-612`, `toJs`/`toJsError`):

```swift
self.webView?.evaluateJavaScript("""
  window.Capacitor.fromNative({ callbackId: '\(result.callbackID)', … data: \(resultJson) })
""")
```

**Android.** Two transports chosen at construction (`MessageHandler.java:27-41`):
preferred is
`WebViewCompat.addWebMessageListener(webView, "androidBridge", allowedOrigins, capListener)`
behind `WebViewFeature.WEB_MESSAGE_LISTENER`; the fallback (or
`android.useLegacyBridge` in `CapConfig`) is
`addJavascriptInterface(this, "androidBridge")` onto
`@JavascriptInterface public void postMessage(String jsonStr)` (line 51). JS
posts `win.androidBridge.postMessage(JSON.stringify(data))`
(`native-bridge.ts:950`). Return is `javaScriptReplyProxy.postMessage(String)` →
`win.androidBridge.onmessage`, or on the legacy path
`webView.post(() -> webView.evaluateJavascript("window.Capacitor.fromNative(" + data + ")", null))`.

**Correlation** is a string `callbackId` minted in JS —
`callbackIdCount = Math.floor(Math.random() * 134217728)`, incremented per call,
kept in a `Map` (`native-bridge.ts:934, 1013-1014`).

## 3.3 The wire format: JSON strings, both directions, both platforms

Docs: "The supported data types are those that can be represented in JSON such as
numbers, strings, booleans, arrays, and objects"
(<https://capacitorjs.com/docs/core-apis/data-types>). `Date` is the one
coercion (ISO 8601). **No binary path at all.** On iOS the result goes through
`JSONSerialization` and is then *string-interpolated into JS source*.

- <https://github.com/ionic-team/capacitor/issues/3059> ("Transmit raw bytes over
  the bridge") was closed as duplicate, a maintainer stating: "The current iOS and
  Android bridge implementation does not allow for anything but strings. To
  support other data types, it would need to be completely rewritten to use a
  socket or something."
- <https://github.com/ionic-team/capacitor/issues/984> ("Support blob/large
  data") closed 2024 as "should be handled by plugins".
- Base64 is the workaround, with its ~33% inflation.
- **The transport underneath could do better and Capacitor does not use it**:
  Android's `WebViewCompat` supports `WebViewFeature.WEB_MESSAGE_ARRAY_BUFFER` /
  `WebMessageCompat.TYPE_ARRAY_BUFFER` / `replyProxy.postMessage(byte[])`, and
  Capacitor calls only the `String` overloads.
- **Bulk data leaves the bridge entirely.** `Capacitor.convertFileSrc()` rewrites
  a file path to `/_capacitor_file_…` served by a URL-scheme handler
  (`WebViewAssetHandler.swift`, a `WKURLSchemeHandler`; Android's
  `WebViewLocalServer.shouldInterceptRequest`). The HTTP plugin docs say it
  outright: "Due to the nature of the bridge, parsing and transferring large
  amount of data from native to the web can cause issues"
  (<https://capacitorjs.com/docs/apis/http>).

## 3.4 Async only

Yes for plugin methods. Three return types exist —
`PluginMethod.RETURN_PROMISE / RETURN_CALLBACK / RETURN_NONE` (Android;
`CAPPluginReturnPromise/Callback/None` on iOS) — and the docs state "All are
asynchronous and promise-based"
(<https://capacitorjs.com/docs/plugins/method-types>). `registerPlugin`'s proxy
wraps *every* method in `loadPluginImplementation().then(...)`
(<https://github.com/ionic-team/capacitor/blob/main/core/src/runtime.ts>, lines
100-123). <https://github.com/ionic-team/capacitor/issues/3675> ("add support for
synchronous calls") was never implemented; Max Lynch: "the official APIs for
communicating between WKWebView and JS require you to cross a process boundary
and are all async."

Two synchronous paths exist internally and neither is exposed to third-party
plugins: on iOS, `document.cookie` and the http/cookie flags use
`prompt(JSON.stringify(payload))` intercepted in
`runJavaScriptTextInputPanelWithPrompt` (`WebViewDelegationHandler.swift:271-306`)
— the classic no-alert synchronous hack; on Android, `CapacitorCookies.java`
registers its own `@JavascriptInterface public boolean isEnabled()`, a genuine
synchronous JS→Java return.

## 3.5 Events and threading

Events reuse the call machinery: `addListener` is a `nativeCallback` whose
`PluginCall` is marked `keepAlive` (`CAPPlugin.m:107`) so `returnResult` does not
delete it; `notifyListeners(eventName, data)` resolves every retained call
(`Plugin.java:661-685`). A native event therefore costs exactly one
`replyProxy.postMessage` or one `evaluateJavaScript`.

Threading is **documented nowhere** and lives only in source:

- iOS: `open private(set) var dispatchQueue = DispatchQueue(label: "bridge")`
  (`CapacitorBridge.swift:127`); `handleJSCall` does
  `dispatchQueue.async { … plugin.perform(selector, with: pluginCall) }`
  (line 506). **Plugin methods run off the main thread** and UI work must hop.
- Android: `HandlerThread("CapacitorPlugins")` (`Bridge.java:138`, started 216);
  `callPluginMethod` does `taskHandler.post(...)` (line 860), with
  `executeOnMainThread(Runnable)` (915) and `eval(js, cb)` →
  `mainHandler.post(() -> webView.evaluateJavascript(...))` (874), because
  `evaluateJavascript` "must be called on the UI thread" (AOSP `WebView.java`).
  Message *arrival* differs by transport: `WebMessageListener.onPostMessage` is
  `@UiThread`, while `@JavascriptInterface` methods arrive on "a private,
  background thread of this WebView".

## 3.6 The cost, and the JS-engine question

No native pointer ever reaches JS and no JS value ever reaches native. Every
argument and result is `JSON.stringify`'d, copied across a **process** boundary,
and re-parsed; on iOS the result is additionally spliced into a JavaScript source
string and re-lexed by `evaluateJavaScript`. No shared memory, no zero-copy, no
synchronous call, no binary type, one callbackId + Map entry per call.

**Does Capacitor ever run JS outside a WebView? Yes — and the choice is
instructive.** The official
[`@capacitor/background-runner`](https://github.com/ionic-team/capacitor-background-runner)
is "an event-based standalone JavaScript environment for executing your
Javascript code outside of the web view." On **iOS it is JavaScriptCore** —
`packages/capacitor-plugin/ios/Sources/RunnerEngine/Context.swift` holds
`public let jsContext: JSContext` built from a `JSVirtualMachine`. On **Android
it is a vendored QuickJS**
(`packages/android-js-engine/AndroidJSEngine/src/main/cpp/js-engine/src/quickjs/`).
Isolated: "does not execute your Javascript code in a browser or web view,
therefore the typical Web APIs… may not be available", and each `dispatchEvent()`
gets a fresh context destroyed on resolve.

**Can native get a handle into the WebView's JS engine? No.** `WKWebView` runs
page JS in a separate **WebContent process** — WebKit's own architecture docs:
"Web pages are loaded in its own WebContent process"
(<https://docs.webkit.org/Deep%20Dive/Architecture/WebKit2.html>). Apple has
never exposed a `JSContext` for `WKWebView` (the standing request is
<http://openradar.appspot.com/17680867>); `evaluateJavaScript` with a completion
handler is the only route, which is precisely why Capacitor's return path is a
string splice. Android is the same in practice: the Chromium renderer is a
separate process and `addJavascriptInterface` / `WebMessageListener` /
`evaluateJavascript` are the only sanctioned channels.

## 3.7 Read for kaya

1. **The engine choices in `@capacitor/background-runner` are an independent
   arrival at kaya's exact shortlist**: JavaScriptCore on iOS, QuickJS on
   Android, chosen by a team that ships to millions of devices and had no
   ideological attachment. That is corroboration for the iOS ruling and a real
   data point for the Android question.
2. **The WKWebView process boundary is why the WebView projects can never do what
   kaya needs.** Capacitor (§3.6) and Tauri (§4.7) both end at
   `evaluateJavaScript`-a-string because the engine is in another process. kaya's
   guest runs in kaya's own process against kaya's own engine, so none of this
   applies — and none of these projects' mechanisms are borrowable. What is
   borrowable is their *catalogue of costs*, as the list of things kaya's design
   already avoids: JSON-only, async-only, string-spliced returns, a callbackId
   Map, and bulk data smuggled out through a URL scheme.
3. **Threading discipline undocumented is a bug waiting.** Capacitor runs plugin
   methods off the main thread on both platforms, and says so nowhere but in the
   source. kaya's equivalent rule — which thread owns the JS context, and what
   `post_task` means — belongs in DESIGN.md and in a gate, not in a `.swift`
   line number.
