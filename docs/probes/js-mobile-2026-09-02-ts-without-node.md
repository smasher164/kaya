# Running kaya's TypeScript guest files without node — options and cost

Research date: **2026-09-02**. Every claim carries its source URL inline.

Problem statement: kaya's JS guests are `guests/js/*.ts`, run **directly** by node 24
(type stripping, `erasableSyntaxOnly`, no build step, no artifact that can go stale).
The maintainer wants the same binding on **iOS (JavaScriptCore)** and **Android (an
embedded engine)**. Neither JavaScriptCore, nor QuickJS, nor Hermes strips TypeScript.
Project invariant: scene guests are shared **verbatim** across platforms — the same
file must run everywhere.

---

## A. Node's own type stripping — the exact facts

### A1. Which node versions strip types, and when it stopped being experimental

From the official `Modules: TypeScript` doc,
<https://nodejs.org/api/typescript.html> (version history table on that page):

| Node version | Change |
|---|---|
| **v22.6.0** | Type stripping added (behind `--experimental-strip-types`) |
| **v22.7.0** | `--experimental-transform-types` flag added |
| **v23.6.0** and **v22.18.0** | "Type stripping is enabled by default" |
| **v25.2.0** and **v24.12.0** | "Type stripping is now stable" |
| **v26.0.0** | `--experimental-transform-types` flag removed |

- 22.6.0 introduction: <https://nodejs.org/en/blog/release/v22.6.0> —
  "Node.js 22.6.0 (Current)", the release that added `--experimental-strip-types`.
- 22.18.0 (2025-07-31, LTS 'Jod') is the release that flipped the default on the 22
  line: <https://github.com/nodejs/node/releases/tag/v22.18.0> and
  <https://nodejs.org/en/blog/release/v22.18.0>. Its notes say Node.js "will be able
  to execute TypeScript files without additional configuration", i.e. `node file.ts`
  with no `--experimental-strip-types`, and that it can be turned off with
  `--no-experimental-strip-types`.
- The **stable** designation landed in **v24.12.0 / v25.2.0** (per the version-history
  table on <https://nodejs.org/api/typescript.html>). The disable flag in current
  docs is spelled `--no-strip-types`.

**Consequence for kaya:** the desktop lanes' `node 24.19.0` pin is on the "enabled by
default, experimental" side of that line (stable arrives at 24.12.0); either way
`node guests/js/todos.ts` works with no flag. This whole mechanism is **node-only** —
it is a loader hook inside node, not a language feature. See §F for why no engine
ships type erasure natively.

### A2. What node REFUSES to strip

<https://nodejs.org/api/typescript.html> — "By default Node.js will execute TypeScript
files that contain only erasable TypeScript syntax. Node.js will replace TypeScript
syntax with whitespace, and no type checking is performed." Features that error with
`ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX`:

1. `enum` declarations
2. `namespace`/`module` with **runtime** code ("This namespace is exporting a value");
   type-only namespaces are fine
3. **parameter properties** (`constructor(public x: number)`)
4. `import =` / `export =` aliases

Decorators are a separate case: still a TC39 stage-3 proposal, so they are a **parser
error** (same doc page).

### A3. `erasableSyntaxOnly` — the tsconfig flag that pins the guests inside that set

Added in **TypeScript 5.8**:
<https://www.typescriptlang.org/docs/handbook/release-notes/typescript-5-8.html> —
"TypeScript 5.8 introduces the `--erasableSyntaxOnly` flag. When this flag is enabled,
TypeScript will error on most TypeScript-specific constructs that have runtime
behavior." It disallows exactly the four constructs in A2 (enums; namespaces/modules
with runtime code; parameter properties; non-ECMAScript `import =`/`export =`), and the
release notes recommend combining it with `--verbatimModuleSyntax`. The node docs
recommend the same pair.

**This is the load-bearing fact for the whole question:** because kaya already sets
`erasableSyntaxOnly`, every `guests/js/*.ts` file is, byte for byte, *a JavaScript file
with type annotations spliced in*. Any tool that deletes those annotations produces a
correct program — there is no lowering, no helper injection, no runtime semantics to
preserve. That makes every option in §B and §C a pure text transform, and it is why the
"blank it out in place" trick in §B works at all.

### A4. The `node_modules` restriction

<https://nodejs.org/api/typescript.html>: Node.js "refuses to handle TypeScript files
inside folders under a `node_modules` path", raising
`ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING`, "in order to discourage package authors
from publishing packages written in TypeScript". Tracking issue asking for it to be
relaxed: <https://github.com/nodejs/node/issues/57215> (open).

kaya has already been bitten by exactly this: the commit log records that "node refuses
to strip types for a file whose real path is under node_modules, which the mac and linux
workspace SYMLINK had hidden" — i.e. the Windows lane, which staged the binding behind a
junction rather than a symlink, hit the real path and failed. So the restriction is a
known, already-paid cost in this repo.

### A5. What node uses internally: `amaro` (a wrapper over swc's WASM build)

- Repo: <https://github.com/nodejs/amaro> — "Amaro is a wrapper around
  `@swc/wasm-typescript`, a WebAssembly port of the SWC TypeScript parser… It is used as
  an internal in Node.js for Type Stripping but can also be used as a standalone
  package."
- npm: <https://www.npmjs.com/package/amaro> — **latest 1.1.11, published 2026-07-16**,
  MIT, **zero runtime dependencies**, unpacked size **3.83 MB** (the `.wasm` blob is
  most of that).
- Standalone API is `amaro.transformSync(source, opts)` returning `{ code }`; the
  node-specific part is only the `--import="amaro/strip"` loader.

**Can amaro run inside JavaScriptCore or QuickJS?** Not usefully. It is a
`@swc/wasm-typescript` bundle produced by `wasm-bindgen`, so it needs (a) a
**WebAssembly** implementation and (b) the wasm-bindgen JS glue's expectations of
`TextDecoder`/`TextEncoder` and typed-array globals. JavaScriptCore *does* implement
WebAssembly on macOS/iOS-simulator, but on **iOS devices** JIT is unavailable to
third-party apps and JSC's public API surface for Wasm on-device is not something to
build a product on; **QuickJS has no WebAssembly at all** (it is a plain interpreter —
<https://bellard.org/quickjs/quickjs.html>), and **Hermes has no WebAssembly**
(<https://github.com/facebook/hermes> — Hermes is an AOT-bytecode engine; its docs list
the ES features it supports and Wasm is not among them). So amaro is a **build-host**
tool for kaya, never an on-device one.

---

## B. `ts-blank-space` (Bloomberg) — the one tool that could run *on the device*

Repo: <https://github.com/bloomberg/ts-blank-space>.
npm: <https://www.npmjs.com/package/ts-blank-space> —
**latest 0.9.0, published 2026-05-12**, **Apache-2.0**, unpacked **54.8 kB**, 10 files.
Release cadence: 0.6.1 (2025-03-03) → 0.6.2 (2025-08-07) → 0.7.0 (2026-01-22) →
0.8.0 (2026-03-30) → 0.9.0 (2026-05-12). Actively maintained.

### B1. What it is

README: "A small, fast, pure JavaScript type-stripper that uses the official TypeScript
parser." It does not generate code — "no new JavaScript code is generated; instead, it
re-uses slices of the existing source string", replacing every type annotation with
**spaces**, so output byte offsets equal input byte offsets and **no source map is
needed**. Around 800 lines of code.

Its own published `out/index.js` is itself blanked TypeScript — you can see the runs of
spaces where the annotations were. (Verified by unpacking the tarball.)

### B2. Dependencies — a *regular* dependency, and the version range is the catch

From `ts-blank-space@0.9.0`'s package.json (npm registry):

```json
"dependencies": { "typescript": "5.1.6 - 6.0.x" },
"engines": { "node": ">=18.0.0" },
"type": "module"
```

So `typescript` is a **regular dependency, not a peer dep**, and — the load-bearing
detail — the range **stops at 6.0.x**. It cannot use `typescript@7`, because
**TypeScript 7.0 ships no programmatic API** (see §C5). It needs the pure-JS compiler
package. `typescript@6.0.3`'s `lib/typescript.js` is **9.14 MB** of JavaScript
(measured by unpacking the published tarball).

The `engines: node >= 18` field is a packaging declaration, not a runtime requirement —
see B4, where it runs under QuickJS with no node at all.

### B3. Speed

README: "only 4 times slower than a native multi-threaded transformer" and "fastest
compared to non-native (JavaScript or Wasm)" — i.e. it beats amaro/swc-wasm and Babel,
and loses only to native binaries (esbuild/oxc/swc-native).

### B4. **Measured: it runs inside a bare engine with no node APIs**

This is the key question in the charge, so I measured it rather than reasoning about it.

Setup: `ts-blank-space@0.9.0` + `typescript@6.0.3` bundled to a single IIFE with esbuild,
then run under **QuickJS-ng 0.13.0** (nixpkgs `quickjs-ng`), which has no `require`, no
`fs`, no `process`, no `Buffer`, and no WebAssembly:

```
$ esbuild entry.js --bundle --format=iife --platform=node '--external:node:*'
  tbs.iife.js  10.42 MB      (minified: 3.59 MB; gzip of minified: 1.03 MB)

$ qjs tbs.probe.js
STRIPPED_OK len=65 same=true
"const x         = 1; export function f   (a   )    { return a; }\n"
```

It works. The output is the input with the annotations blanked, identical length
(`same=true`) — the byte-offset guarantee holds. **No shims were needed**: the
`process.`/`require(`/`Buffer` references the TypeScript bundle carries (32/4/6
occurrences in the minified bundle) are all inside `ts.sys` feature-detection that is
never reached by the parser path.

Cost, measured on an Apple-silicon Mac (`/usr/bin/time -p`, 3 runs each, medians):

| script under QuickJS-ng | wall |
|---|---|
| baseline (`print("hi")`) | **0.08 s** |
| ts-blank-space + typescript, minified 3.59 MB | **0.46 s** |
| ts-blank-space + typescript, unminified 10.42 MB | **0.63 s** |

So loading the stripper costs **~0.38 s of engine time per process on a fast desktop
CPU, before any kaya code runs**. Inside the script, `Date.now()` around the calls gives
`eval_ms=7` (QuickJS parses function bodies lazily, so the 3.6 MB is cheap to *evaluate*
— the 0.38 s is the tokenizer walking the file) and `strip_ms=6` for a 5.4 kB TypeScript
source. On a phone, with no JIT (iOS third-party apps cannot JIT; QuickJS never JITs),
expect that 0.38 s to become **1–2 s of added startup, on every launch of every scene**.

For contrast, in the same engine a **pre-stripped** kaya guest bundle (§D, 52 kB
minified) loads in **0.08 s — the baseline**, i.e. free.

### B5. Limitations — the same erasable-syntax-only set, plus two precedence cases

<https://github.com/bloomberg/ts-blank-space/blob/main/docs/unsupported_syntax.md>:

- non-`declare` `enum` (use `const … as const`)
- instantiated `namespace` / non-ambient `module` declarations
- `import x = …` / `export = …`
- constructor parameter properties
- decorators are **preserved, not stripped** ("Decorators are a runtime feature they are
  correctly preserved in the output")
- legacy prefix assertions `<const>value`
- `as`/`satisfies` in precedence-sensitive positions: "If `OP2` has **higher
  precedence** than `OP1`, erasing would re-group evaluation, so `onError` is called."

The first four are exactly node's list (§A2) and exactly `erasableSyntaxOnly`'s list
(§A3), so **kaya's guests already satisfy them**. The last two are extra and narrower
than node's, but they are reported through an `onError` callback rather than silently —
and a gate could simply fail on any `onError`.

**Verdict on B:** ts-blank-space is the only credible *on-device* stripper. It is real,
maintained, correct, and measurably runs in QuickJS with zero node. Its cost is 3.6 MB
of script and ~0.4 s (desktop) / ~1–2 s (phone) of startup per process, and it pins
kaya to `typescript@6.x` for as long as TypeScript 7 has no API.

---

## C. Build-step transpilers

kaya's pinned nixpkgs is `github:NixOS/nixpkgs/391b592eb44808b3bd0cb80bb71b63a5a118b8bb`
(from `flake.lock`). Every "version in kaya's nixpkgs" below was read with
`nix eval --raw github:NixOS/nixpkgs/391b592…#<attr>.name`.

### C1. `esbuild` (evanw) — the strongest fit

- Repo <https://github.com/evanw/esbuild>, **MIT**.
- npm latest **0.28.2, published 2026-08-08** (<https://www.npmjs.com/package/esbuild>);
  recent cadence 0.27.5/0.27.7/0.28.0 (2026-04-02), 0.28.1 (2026-06-11), 0.28.2.
- **nixpkgs attribute: `esbuild`**, and in kaya's pinned nixpkgs it is **`esbuild-0.27.2`**
  (<https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/es/esbuild/package.nix>).
- **Single static binary**: measured `10,540,624` bytes at `$out/bin/esbuild`, written in
  Go, no runtime dependencies, nothing fetched at run time — **fully offline and
  hermetic**, which is what kaya's lanes need.
- Type stripping without type checking: <https://esbuild.github.io/content-types/#typescript>
  — "esbuild *does not* do any type checking so you will still need to run `tsc -noEmit`
  in parallel with esbuild to check types." It treats TypeScript as "type-checked
  JavaScript": annotations, interfaces, type aliases and type-only imports are removed;
  namespaces, enums, const enums, generics, casts and instantiation expressions are
  *converted* rather than refused (so it is a **superset** of node's erasable set — a
  file that node runs, esbuild will handle). It requires `isolatedModules` semantics
  because each file compiles independently.
- **Bundling**: `--bundle --format=iife` — <https://esbuild.github.io/api/#format-iife>.

**Measured on kaya's actual tree** (binding = 4,992 lines / 240 kB across
`bindings/js/kaya/{index,wire,runtime}.ts`; 42 guests in `guests/js/*.ts`):

| what | result |
|---|---|
| one guest, `--bundle --format=iife` (whole binding inlined) | **113.7 kB**, built in 11 ms |
| all 42 guests, IIFE, unminified | **3.9 MB total** (~93 kB each), ~0.13 s wall |
| all 42 guests, IIFE, `--minify` | **1.8 MB total**, ~52 kB each, ~0.12 s wall |
| `todos.js` minified, gzipped | **16.6 kB** |
| strip-only (`--outdir`, no bundle), 45 files | 324 kB, ~0.10 s wall |

So "the whole binding gets inlined into every guest bundle" costs **~52 kB per guest
minified**, and 42 guests build in about **a tenth of a second**. That is not a cost
worth designing around.

### C2. `swc`

- Repo <https://github.com/swc-project/swc>, **Apache-2.0**.
- npm `@swc/core` **1.16.1, 2026-08-19**; `@swc/cli` **0.8.1, 2026-04-01** (which needs
  `@swc/core` as a peer dep plus `chokidar`, `piscina`, `@xhmikosr/bin-wrapper` etc. —
  a real node_modules tree, unlike esbuild's single binary).
- **nixpkgs attribute: `swc`** — in kaya's pinned nixpkgs, `swc-0.91.495`, whose
  `swc --version` reports **`SWC 16.0.0`**; `meta.mainProgram = "swc"`, Apache-2.0.
  Single binary, measured **41,448,608 bytes** (4× esbuild).
- **Caveat measured on kaya's own guest**: `swc compile guests/js/todos.ts` with no
  config **downlevels** — the output opens with a generated `asyncGeneratorStep` helper,
  because swc's default `jsc.target` is old. It is a *transpiler* first and a stripper
  second; you must pin `jsc.target=es2022` (and `isolatedModules`) to get erasure only.
  esbuild and node-strip do not have this failure mode by default.
- **Rust crate route** (the charge's question — could kaya's own Rust build strip types
  with no new toolchain?): yes, the crates exist and are current —
  `swc_core` **77.1.2, updated 2026-08-27** and
  `swc_ecma_transforms_typescript` **55.0.1, updated 2026-08-26**
  (<https://crates.io/crates/swc_ecma_transforms_typescript>). The latter has **10
  required non-optional dependencies** (`swc_common`, `swc_ecma_ast`,
  `swc_ecma_transforms_base`, `swc_ecma_transforms_react`, `swc_ecma_utils`,
  `swc_ecma_visit`, `swc_atoms`, `bytes-str`, `rustc-hash`, `serde`) — but you also need
  a *parser* and *emitter* (`swc_ecma_parser`, `swc_ecma_codegen`), and the transitive
  closure of `swc_core` is famously large (it is the whole SWC compiler). This would add
  hundreds of crates and minutes to kaya's cold `cargo build`, for a job a 10 MB binary
  already does in 11 ms. **Not worth it** — and note it does *not* avoid a build step,
  it only moves the build step into cargo.

### C3. `tsc --emit` / `ts.transpileModule` — the official route

- `transpileModule` is real and documented:
  <https://github.com/microsoft/TypeScript/wiki/Using-the-Compiler-API#a-simple-transform-function>
  and the API reference — it compiles one file with no program, no type information, no
  cross-file resolution (isolatedModules semantics).
- **Measured** with `typescript@5.9.3` (kaya's nixpkgs `typescript` attribute is
  **`typescript-5.9.3`**) under `nodejs-24.19.0`:
  - `ts.transpileModule` over all **42 guests: 73 ms** (3 runs: 73.2 / 73.8 / 70.8 ms),
    68,328 bytes out.
  - `tsc -p` over the 42 guests **plus** the 3 binding files, with **full type checking**
    and emit: **0.53 s** wall.
- Cost: it needs node to run. kaya's mobile lanes have node **on the build host** (the
  mac lane already runs node 24.19.0, and `tools/js-typecheck.py` already shells out to
  `tsc`), just not on the device. So `tsc --emit` is *free of new tooling* — it reuses
  the gate that already exists.
- The honest downside vs esbuild: `tsc` cannot bundle. For a JSC target that needs one
  script per guest (§D), you would still need a bundler afterwards.

### C4. `oxc`

- Repo <https://github.com/oxc-project/oxc>, **MIT**: "a collection of high-performance
  tools for JavaScript and TypeScript written in Rust" — parser, transformer, minifier,
  resolver, linter (oxlint), formatter (oxfmt).
- npm **`oxc-transform` 0.148.0, published 2026-09-01**
  (<https://www.npmjs.com/package/oxc-transform>) — a napi native addon with 19
  per-platform optional deps (including `@oxc-transform/binding-android-arm64`).
- crates.io: **`oxc_transformer` 0.148.0, updated 2026-09-01**
  (<https://crates.io/crates/oxc_transformer>), 22 required deps;
  `oxc_parser` 0.148.0 with 15. Much lighter than swc_core's closure.
- **nixpkgs: the transformer is NOT packaged.** Only the linter is:
  attribute **`oxlint`**, `oxlint-1.78.0` in kaya's pin, defined at
  `pkgs/by-name/ox/oxlint/package.nix`
  (<https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/ox/oxlint/package.nix>).
  `nix eval nixpkgs#oxc-transform` and `nixpkgs#oxc-parser` both fail with "does not
  provide attribute". So using oxc means either an npm install (a node_modules tree, and
  a napi binary per platform) or vendoring the Rust crate — both worse than esbuild's
  one nixpkgs attribute for kaya's hermetic-lane rule.
- Version churn is high (0.144.0 on 2026-08-10 → 0.148.0 on 2026-09-01: five releases in
  three weeks), still pre-1.0 for the transformer.

### C5. TypeScript 7 / the Go port ("Corsa", `typescript-go`) — **it shipped, and it takes the API away**

This is the one item that genuinely changes the calculus, and it cuts against the
on-device stripper.

- **TypeScript 7.0 was released 2026-07-08**:
  <https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/>. Confirmed by
  the npm registry: `typescript@7.0.2` published **2026-07-08**, and its package now
  ships **platform-specific native binaries** as optional deps
  (`@typescript/typescript-darwin-arm64` etc.) — unpacked size dropped from 23.6 MB
  (5.9.3) / 23 MB (6.0.3) to **2.50 MB**, because the JavaScript compiler is gone.
  Independent coverage: <https://www.infoq.com/news/2026/08/typescript-7-released/>,
  <https://www.theregister.com/devops/2026/07/09/speedier-type-checks-in-typescript-70-as-first-stable-go-release-ships/>.
- **No programmatic API in 7.0.** The announcement: "TypeScript 7.0 does not yet ship
  with an API. We expect TypeScript 7.1 to ship with a new (and different) API, but until
  then we have made it a priority to ensure TypeScript can be run side-by-side with
  TypeScript 6.0." Microsoft publishes `@typescript/typescript6` (and a `tsc6` binary)
  as the compatibility shim.
- **Consequence for ts-blank-space:** it depends on `typescript` in the range
  `5.1.6 - 6.0.x` precisely because it needs the JS parser. `typescript@6.0.3`'s
  `lib/typescript.js` is 9.14 MB. As long as TS 7 has no API, an on-device
  ts-blank-space means kaya carries a **frozen TypeScript 6 JavaScript compiler** in
  every mobile app bundle, on a package line Microsoft has stopped developing.
  `ts.transpileModule` (§C3) has the same exposure — it is a TS ≤ 6 API.
- dist-tags today (registry read 2026-09-02): `latest: 7.0.2`, `beta: 6.0.0-beta`,
  `rc: 7.0.1-rc`, `next: 7.1.0-dev.20260902.1`. So 7.1 (and its API) is in nightly but
  not released.

---

## D. Bundling for engines with no module loader

### D1. JavaScriptCore's public API has **no** module loader — verified against the SDK

I did not take this from a blog. I read the headers Apple ships. In
`MacOSX26.5.sdk/System/Library/Frameworks/JavaScriptCore.framework/Headers` the complete
public header set is:

```
JSBase.h  JSContext.h  JSContextRef.h  JSExport.h  JSManagedValue.h  JSObjectRef.h
JSStringRef.h  JSStringRefCF.h  JSTypedArray.h  JSValue.h  JSValueRef.h
JSVirtualMachine.h  JavaScript.h  JavaScriptCore.h  WebKitAvailability.h
```

`grep -rn "Module\|module"` over all of them returns **nothing**. The only entry points
are:

- `- (JSValue *)evaluateScript:(NSString *)script;` (`JSContext.h:72`)
- `- (JSValue *)evaluateScript:(NSString *)script withSourceURL:(NSURL *)sourceURL;`
  (`JSContext.h:81`, `API_AVAILABLE(macos(10.10), ios(8.0))`)
- `JS_EXPORT JSValueRef JSEvaluateScript(JSContextRef ctx, JSStringRef script,
  JSObjectRef thisObject, JSStringRef sourceURL, int startingLineNumber,
  JSValueRef* exception);` (`JSBase.h:113`)

Apple's reference for the same:
<https://developer.apple.com/documentation/javascriptcore/jscontext/evaluatescript(_:)>.

**So on iOS a guest must arrive as one script.** There is no `import` at all — not
"no dynamic loader", literally no ESM entry point in the public framework.

**How Bun gets modules on JSC (the charge's question):** it does not use the public API.
<https://github.com/oven-sh/bun/discussions/2398> — Bun's own maintainer: "This is where
we call the code to evaluate the ESM module: `promise = JSModuleLoader.loadAndEvaluateModule()`",
which is `JSC::loadAndEvaluateModule(globalObject, name, JSC::jsUndefined())` — a
**C++ internal** of WebKit, plus its own resolver written in Zig
(<https://bun.com/docs>). Bun links its own WebKit build; it is not reachable from an
app that links Apple's shipped `JavaScriptCore.framework`. So Bun is proof the engine
*can* do modules, and proof that kaya *cannot get at it* on iOS.

### D2. QuickJS *does* expose a module loader

Verified against `quickjs.h` on `quickjs-ng/master`
(<https://github.com/quickjs-ng/quickjs/blob/master/quickjs.h>):

- `#define JS_EVAL_TYPE_MODULE (1 << 0) /* module code */` (line 448)
- `JS_EXTERN void JS_SetModuleLoaderFunc(JSRuntime *rt, JSModuleNormalizeFunc*,
   JSModuleLoaderFunc*, void *opaque);` (line 1213), plus
  `JS_SetModuleLoaderFunc2` with import-attribute support (1218) and
  `JS_SetModuleNormalizeFunc2` (1225).

kaya's pinned nixpkgs has **`quickjs-ng-0.16.1`**; the version I ran the experiments on
was **0.13.0**. So if Android used QuickJS, a host-side loader could serve
the `*.js` files beside bindings/js/kaya/index.ts as real modules and the guest could keep its `import * as kaya`.
That does **not** rescue iOS.

### D3. Android's engine choices, and what each does to modules

- **Hermes** (React Native's default): <https://reactnative.dev/docs/hermes> — "Hermes is
  used by default by React Native and no additional configuration is required." JS
  reaches it as a **Metro bundle**, and for production as **precompiled `.hbc`
  bytecode**: "This will compile JavaScript to Hermes Bytecode during build time which
  will improve your app's startup speed on device." Metro's own docs
  (<https://metrobundler.dev/docs/concepts/>) describe a three-stage
  Resolution → Transformation → Serialization pipeline producing "one or multiple
  bundles. A bundle is literally a bundle of modules combined into a single JavaScript
  file." So the entire React Native ecosystem — the largest embedded-JS deployment there
  is — **already answers this exact question with "pre-bundle on the build host"**.
- **androidx.javascriptengine** (V8 in a separate process):
  <https://developer.android.com/develop/ui/views/layout/webapps/jsengine> — "This
  library uses the V8, Chrome's JavaScript engine, and lets your application evaluate
  JavaScript or WebAssembly code without creating a WebView instance… The JavaScript
  executes in a different process." Its surface is `evaluateJavaScriptAsync(String)` —
  again script-only, and worse for kaya: it is **out of process**, so the synchronous
  native calls kaya's binding makes into `libkaya` are not available at all.
- **QuickJS / quickjs-ng**: modules available (D2), no JIT, small.

### D4. **Measured: what one-script-per-guest actually costs kaya**

The charge asks how big the binding gets when inlined into every guest. Measured on the
real tree with `esbuild --bundle --format=iife`:

| | unminified | minified | minified+gzip |
|---|---|---|---|
| one guest (`todos.ts`) | **113.7 kB** | **52.3 kB** | **16.6 kB** |
| largest guest (`undo`) | — | 53.1 kB | — |
| **all 42 guests** | **3.9 MB** | **1.8 MB** | — |
| build time, all 42 | ~0.13 s | ~0.12 s | — |

The spread across the 42 is tiny (52.0–53.1 kB minified) because the binding dominates
and the guests are ~55 lines each. **1.8 MB for all 42 scenes** is the whole cost of the
"inline the binding into every guest" objection — and a shipped app carries *one* guest,
i.e. **52 kB**.

I also confirmed the bundles are real by running one: `qjs out-min/todos.js` under
QuickJS-ng **parses and executes** the bundle in 0.08 s (== the engine's baseline
startup), failing only at `Dynamic require of "node:fs" is not supported` — i.e. at
`bindings/js/kaya/runtime.ts`'s dlopen/`fileURLToPath(import.meta.url)` layer, which is
the **native bridge kaya must replace on mobile anyway** and has nothing to do with type
stripping. Two related notes from the build:

- esbuild warns `"import.meta" is not available with the "iife" output format and will
  be empty` at `runtime.ts:39`. The IIFE format cannot carry `import.meta.url`; the
  mobile runtime layer has to find `libkaya` some other way regardless.
- `--format=esm` keeps `import.meta` but produces a module, which JSC cannot load.
  So for iOS the format is forced to `iife`, and the runtime layer must be ported.

### D5. **Hermes needs more than stripping — it needs downleveling.** This is decisive.

Hermes's own feature list is the primary source and it is current (last edited
2026-07-27): <https://github.com/facebook/hermes/blob/main/doc/Features.md>.

> "Hermes plans to target **ECMAScript 2015 (ES6)**, with some carefully considered
> exceptions."

Under **"In Progress"** (i.e. *not* supported):

> - "Async function (`async` and `await`)."
> - "ES modules (`import` and `export`)"

Under **"Excluded From Support"**:

> - "Other features added to ECMAScript after ES6 not listed under 'Supported'"

kaya's `bindings/js/tsconfig.json` sets `"target": "es2022"`, and the JS binding's four
ruled sugar shapes are built on `async`/`await` — the implicit transaction commits on a
microtask, `await app.commit()` ends a batch early, and every dialog answers a promise.
`guests/js/todos.ts` opens with `async function onAdd(): Promise<void>`.

So on Hermes the guests need **`async` lowered to generators**, not merely typed
annotations removed. That rules out, on Android-via-Hermes:

- **node's type stripping** — it only replaces syntax with whitespace, by construction
  (§A2); it can never lower `async`.
- **`ts-blank-space`** — same, and by design: "no new JavaScript code is generated"
  (§B1). It is a *blanker*, not a compiler.

Only a real transpiler (esbuild `--target=es2015`, swc with `jsc.target`, or `tsc`
with a low `target`) can produce something Hermes runs.

**Measured, on kaya's real guests:**

```
$ esbuild guests/js/*.ts --bundle --format=iife --target=es2015 --minify
   42 files, 1.8 MB total, 0.13 s wall
```

Counting constructs in `todos.js` before and after the target change:

| | `async function` | `await` | `function*` | `yield` | bytes |
|---|---|---|---|---|---|
| `--minify` (no target) | 1 | 1 | 0 | 0 | 52,348 |
| `--minify --target=es2015` | **0** | **0** | **1** | **1** | 54,437 |

esbuild rewrites the coroutine into a generator, and the bundle grows **4%** (52.3 kB →
54.4 kB) for all 42 guests in the same **0.13 s**. So the Hermes constraint is real but
its *cost* is nil — provided there is a build step at all. If Android uses **QuickJS-ng**
instead (ES2023-class, and it has a module loader, §D2) this pressure disappears — so
the Android engine choice decides whether downleveling is required. **iOS/JSC does not
have this problem** (JavaScriptCore is a modern full-featured engine); iOS's problem is
modules only.

---

## E. Plain JS with JSDoc types

### E1. What TypeScript supports in JSDoc

<https://www.typescriptlang.org/docs/handbook/jsdoc-supported-types.html> and
<https://www.typescriptlang.org/docs/handbook/type-checking-javascript-files.html>.
Supported: `@type`, `@param`, `@returns`, `@typedef`, `@callback`, **`@template` with
constraints and defaults** (generics), **`@satisfies`**, `@overload`, `@import`, type
casts `/** @type {T} */ (expr)`, `@constructor`, `@extends`/`@augments`, `@implements`,
`@this`, `@override`, `@public`/`@private`/`@protected`/`@readonly`, `@enum`.

Documented *unsupported* patterns: `@memberof` (#7237), `@yields` (#23857), `@member`
(#56674); JSDoc's postfix-equals optional property syntax `{ b: number= }`; and JSDoc's
nullable/non-nullable `?T` / `!T` — "Unlike JSDoc's type system, TypeScript only allows
you to mark types as containing null or not. There is no explicit non-nullability."

### E2. **Measured on kaya-shaped code** — does `tsc --checkJs` really give the same errors?

I wrote probes in the shape kaya's guests actually use (the binding leans hard on
`kaya.Fields<typeof Todo.schema>`, a mapped type over a schema object) and ran
`tsc 5.9.3 --strict --checkJs`:

| construct | JSDoc spelling | result |
|---|---|---|
| generic function with a constraint | `@template {Record<string, …>} S` | ✅ |
| mapped type over a type parameter | `@typedef {{ [K in keyof S]: … }} Fields` | ✅ |
| the *wrong* value assigned to `Fields<typeof Todo.schema>` | — | ✅ **caught**, `error TS2322: Type 'string' is not assignable to type 'boolean'` — byte-identical to what `.ts` reports |
| `satisfies` | `/** @satisfies {Record<string, number>} */` | ✅ |
| const assertion | `/** @type {const} */ ({ x: 1 })` | ✅ |
| generic arrow function | `/** @type {<T>(a: T) => T} */` | ✅ |
| function overloads | `@overload` blocks | ✅ — `pick("s")` narrowed to `string`, wrong assignment caught `TS2322` |
| generic method on a class | `@template U` on the method | ✅ — `TS2322` on `number[] = wrap("x")` |
| `@readonly` on `this.n = 1` in a constructor | ✅ — `TS2540: Cannot assign to 'n' because it is a read-only property` |
| **`@readonly` on a class *field declaration*** (`/** @readonly */ m = 1`) | ❌ **silently ignored** — no error on `new Q().m = 2` |

So the answer is: **almost all of it, and the errors are the same error codes**. The one
gap I found by trying is `@readonly` on a class field declaration, which is a footgun
precisely because it is silent. Expect to find a handful more of those by walking into
them.

The real cost is not expressiveness, it is **density**. `function itemsLeftText(items:
Map<kaya.Key, kaya.Fields<typeof Todo.schema>>): string` is one line in `todos.ts`; in
JSDoc it is a four-line comment block above the function. kaya's 42 guests are ~2,334
lines total (~55 lines each) and the maintainer's own rule is that "a guest should read
as the kaya calls it makes" — JSDoc makes every typed signature three to five lines of
comment. That is the honest pain, and it lands on exactly the files the project holds
tightest.

### E3. Who actually does this

- **Svelte** — and the charge's premise ("moved to JSDoc and then BACK") is **not what
  happened**; they have not moved back.
  - Svelte 3 (released 2019-04-21) was written in TypeScript.
  - The conversion PR is **sveltejs/svelte#8569 "TS to JSDoc Conversion", opened
    2023-05-09**, 247 files, +9,751 / −8,608
    (<https://github.com/sveltejs/svelte/pull/8569>), preceded by
    **#8526 "chore: TypeScript to JavaScript + JSDoc for tests", 2023-04-22**
    (<https://github.com/sveltejs/svelte/pull/8526>). It shipped in **Svelte 4
    (2023-06-22)**.
  - Rich Harris's stated rationale, reported 2023-05-11:
    <https://www.devclass.com/development/2023/05/11/typescript-is-not-worth-it-for-developing-libraries-says-svelte-author-as-team-switches-to-javascript-and-jsdoc/1630004>
    — and his own framing, "typescript for apps, JSDoc for libraries… types with a build
    step for apps, types without a build step for libraries. it's all typescript either
    way" (<https://x.com/Rich_Harris/status/1661051005985865728>). Earlier:
    "the resulting code is generally smaller than transpiled code. Building, testing etc
    all become much less finicky. And .d.ts files are still generated from source code"
    (<https://x.com/Rich_Harris/status/1350436286948122625>).
  - The earlier SvelteKit rationale, 2022-03-23:
    <https://github.com/sveltejs/kit/discussions/4429> — smaller output, easier to change
    while experimental, and "Using JSDoc types means you can run tests without adding a
    build step."
  - **The move back was proposed and rejected.** `sveltejs/svelte#16647`
    "Reconsidering TypeScript for Svelte Compiler Internals", opened **2025-08-19**,
    arguing "Node 23.6 now allows TypeScript files to run natively, substantially
    reducing the historical overhead of compilation" — **closed as not planned**
    (<https://github.com/sveltejs/svelte/issues/16647>).
  - **Verified today (2026-09-02):** `packages/svelte/src/compiler` on `main` still
    contains `errors.js`, `index.js`, `legacy.js`, `state.js`, `warnings.js`,
    `validate-options.js` alongside `private.d.ts` / `public.d.ts`
    (<https://github.com/sveltejs/svelte/tree/main/packages/svelte/src/compiler>).
    Still JS + JSDoc, three years on.
- **Preact** — same model, verified today: `src/` is `component.js`, `render.js`,
  `diff/`, `create-element.js` … with hand-written `index.d.ts`, `internal.d.ts`,
  `jsx.d.ts` (<https://github.com/preactjs/preact/tree/main/src>), and the `.js` carries
  real JSDoc types, e.g. in `src/component.js`:
  `/** @this {import('./internal').Component} @param {object | ((s: object, p: object) => object)} update … */`
  (<https://raw.githubusercontent.com/preactjs/preact/main/src/component.js>).
- **esbuild** — not an example: the compiler is Go, and its npm wrapper's own sources
  (`lib/shared/common.ts`, `types.ts`, `worker.ts`) are **TypeScript**
  (<https://github.com/evanw/esbuild/tree/main/lib/shared>).

---

## F. The TC39 "Type Annotations" proposal ("types as comments") — do not wait for it

- Proposal repo: <https://github.com/tc39/proposal-type-annotations>.
- **Stage 1**, and that is authoritative, not inferred: it is listed in
  <https://github.com/tc39/proposals/blob/main/stage-1-proposals.md> and appears in
  **none** of `stage-2-proposals.md`, `stage-3-proposals.md`, `finished-proposals.md`,
  or `inactive-proposals.md` (checked 2026-09-02 — zero matches in each).
- Champions per that table: **Daniel Rosenwasser (Microsoft), Romulo Cintra (Igalia),
  Rob Palmer (Bloomberg)**; authors also list Gil Tayar.
- **Last presented to committee: 2023-09.** The stage-1 table's notes links for this
  proposal are 2023-09, 2023-03, 2022-03-31, 2022-03-29 — nothing since. The README
  itself opens with a notice that "This document has not been updated regularly."
- Repo activity: last commit **2025-08-27** (a CI/deploy-workflow change and doc PRs, not
  spec work), 108 open issues, not archived.
- Community read: <https://github.com/tc39/proposal-type-annotations/issues/178>
  ("This proposal is probably dead?", opened 2023-06-01), which quotes the March 2022
  committee objections; no champion has answered it in the thread.
- **No engine ships it.** Nothing in V8, JavaScriptCore, SpiderMonkey, Hermes or QuickJS
  implements type-annotation syntax; a stage-1 proposal has no spec text to implement,
  and shipping unstaged syntax is not something engines do.

Aged three years at stage 1 with no committee appearance since 2023-09, this is not a
plan for 2026. It is worth knowing only as the reason *why* every other option here is a
tool rather than a language feature.

---

## Summary table

| option | build step? | one guest file per scene, shared verbatim? | cost |
|---|---|---|---|
| **A. node type stripping only** (today) | **No** | **Yes — but only on node.** Fails everywhere else | Free on the 3 desktop lanes; does not reach iOS or Android at all. Also carries the `node_modules` restriction (§A4) that already bit the Windows lane. **Cannot lower `async` for Hermes** (§D5) |
| **B. ship `ts-blank-space` + `typescript@6` inside the app** | **No** | **Yes — the .ts file is the shipped artifact on every platform** | 3.59 MB minified script in every app bundle; **+0.38 s engine load measured on desktop QuickJS**, likely **1–2 s on a phone**, per process; +6 ms per strip; pins kaya to the frozen TS 6 JS compiler because TS 7 has no API (§C5); on iOS also needs the bundle+guest as one script anyway (§D1); and **it cannot lower `async` for Hermes** (§D5) — a blanker never emits new code |
| **C1. `esbuild --bundle --format=iife` on the build host** | Yes | **Yes — the guest file on disk is untouched and is the input to every platform's build** | One nixpkgs attribute (`esbuild`, 0.27.2 in kaya's pin), one 10.5 MB static Go binary, offline/hermetic. **Measured: 42 guests → 1.8 MB minified, ~0.12 s.** 52 kB per shipped app. Adds an artifact that can go stale → needs a `build-id --verify` the way libkaya already has one |
| **C2. `swc` on the build host** | Yes | Yes | nixpkgs `swc` (SWC 16.0.0), 41 MB binary, Apache-2.0. **Downlevels by default** — must pin `jsc.target=es2022` or it injects helpers. No bundler, so still needs esbuild for iOS. Strictly worse than C1 here |
| **C2b. `swc_core` / `swc_ecma_transforms_typescript` from kaya's own cargo build** | Yes (inside cargo) | Yes | Crates are current (77.1.2 / 55.0.1, Aug 2026) but pull in the whole SWC compiler; adds hundreds of crates and minutes to a cold build to replace an 11 ms binary. Does **not** remove the build step, only hides it |
| **C3. `tsc --emit` / `ts.transpileModule`** | Yes | Yes | Zero new tooling — `tsc` is already in the flake (`typescript-5.9.3`) and `tools/js-typecheck.py` already runs it. **Measured: `transpileModule` over 42 guests = 73 ms; full `tsc -p` with typecheck = 0.53 s.** But it cannot bundle, so iOS still needs esbuild after it |
| **C4. `oxc-transform`** | Yes | Yes | **Not in nixpkgs** (only `oxlint` is) → an npm install with per-platform napi binaries, against kaya's hermetic-lane rule. Pre-1.0 with five releases in three weeks |
| **E. plain `.js` + JSDoc types** | **No** | **Yes — on every engine, with no tool at all** | The guests stop being TypeScript. Measured: generics, mapped types, `satisfies`, const assertions, overloads and generic methods all work under `tsc --checkJs` with identical error codes; `@readonly` on a class field is silently ignored. The price is prose density — every typed signature becomes a 3–5 line comment block in files the project deliberately keeps short and readable |
| **F. TC39 type annotations** | n/a | n/a | Stage 1 since 2022, last presented **2023-09**, no engine implements it. Not an option |

### The two that actually keep the invariant

Only **B** and **E** keep "the file on disk is the file the engine runs" on all five
platforms. **B** buys that with 3.6 MB and ~1–2 s of phone startup per launch, plus a
dependency on a TypeScript API Microsoft has already replaced — and **B still does not
work on Hermes**, because blanking cannot lower `async` (§D5). **E** buys it by giving up
TypeScript syntax in the guests — and E has the same Hermes problem, since plain
ES2022 JavaScript is still not ES6.

Everything in **C** keeps a weaker but arguably sufficient version of the invariant: the
**source** `guests/js/*.ts` stays one file, unedited, shared by every platform — what
differs per platform is a derived artifact, which is the same relationship kaya already
has with `libkaya`, the SwiftUI interpreter and the Compose interpreter, and which
`tools/build-id.py --verify` already exists to police. **C1 (esbuild)** is the cheapest
of these by a wide margin: one nixpkgs attribute, one static binary, 0.12 s for all 42
guests, 52 kB per app, and it is the same answer React Native reached for the same
engines (§D3).
