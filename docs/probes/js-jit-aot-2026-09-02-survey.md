# AOT compilation of JavaScript/TypeScript to native machine code — survey

Research date: 2026-09-02. Every status claim carries the date it was read (all
reads are 2026-09-02 unless stated). Static Hermes is covered by a separate
agent and appears here only in passing.

Question being answered: kaya has a TypeScript binding that runs on node today
and must run on iOS and Android. Ruling: "no interpreted JS — a normalization
step (babel/esbuild) or bundling a runtime is fine, but no interpretation."
iOS forbids JIT for third-party apps, so on iOS a literal reading of the ruling
requires AOT compilation to native code.

Guest code shape: packs binary wire records into Uint8Array/DataView, uses
async/await, Promises, Proxy (a row-handle proxy), tagged template literals,
classes, closures, and calls native functions across a Rust C ABI.

Contents: (1) Porffor  (2) AssemblyScript  (3) WebAssembly on iOS — the crux
(4) other JS AOT compilers and the things mistaken for them  (5) summary table
(6) what it adds up to.

---

## 1. Porffor

**What it is.** A genuinely ahead-of-time JavaScript/TypeScript compiler by Oliver
Medhurst (CanadaHonk). The README states it plainly: "Porffor is a 100% AOT
compiled JS engine/runtime. There is nothing interpreted or compiled just-in-time.
Porffor compiles JS to C (with an IR inbetween)."
(https://raw.githubusercontent.com/CanadaHonk/porffor/main/README.md, read 2026-09-02)

### Version and activity (read 2026-09-02)

- Latest release: **`alpha-4`, published 2026-08-29T04:10:28Z** (release name
  "alpha 4 (a415d19 2026-08-29)").
  https://api.github.com/repos/CanadaHonk/porffor/releases
- Release train: `alpha-1` 2026-08-12, `alpha-2` 2026-08-26, `alpha-3` 2026-08-27,
  `alpha-4` 2026-08-29. Before that the tags were `pre-alpha-N` (`pre-alpha-18`
  on 2026-08-12). Porffor left pre-alpha **three weeks ago**.
- Last commit on `main`: **2026-08-29T04:02:35Z** ("builtins/object: fix spread
  missing symbols"). Repo created 2023-06-25; 5,104 stars; 33 open issues; not
  archived. https://api.github.com/repos/CanadaHonk/porffor
- Versioning scheme: "Porffor releases use a single increasing release number.
  Releases are automatically published every git push after CI testing." (README)
- The homepage still carries a launch banner: "Porffor goes alpha August 11th …
  Join us at PlanetScale's San Francisco HQ for a launch event and meetup."
  (https://porffor.dev, read 2026-09-02)

### Test262 conformance — the number as published TODAY

The homepage's Conformance chart is fed live from
`https://cdn.porffor.dev/test262/history.json`. I fetched that file directly on
2026-09-02. Its **most recent data point is 2026-03-06T20:11:00Z**:

| percent | total | passes | fails | runtime errors | native compile errors | compile errors | timeouts |
|---|---|---|---|---|---|---|---|
| **67.45%** | 50,718 | 34,211 | 8,180 | 8,049 | 0 | 241 | 37 |

(field order taken from `test262/index.js` lines 99-110, which builds exactly
`[percent, total, passes, fails, runtimeErrors, nativeErrors, compileErrors,
timeouts]`;
https://raw.githubusercontent.com/CanadaHonk/porffor/main/test262/index.js)

Two caveats a reader must have:

1. **67.45% is the newest published figure, and it is ~6 months stale.** The
   in-repo `test262/history.json` and the CDN copy are byte-identical (both
   201,849 bytes, 1,155 entries, same last hash `82e4c455`) and neither has been
   updated since 2026-03-06, even though the compiler has had hundreds of commits
   and four alpha releases since. So the *real* number today is unknown and
   probably higher — but nobody is publishing it.
2. For scale, a mature engine scores 95-99% on test262. 67% means roughly **one
   test in three still fails**, and 8,049 of those failures are *runtime errors* —
   the program compiles and then dies.

Porffor's own site is blunt about it: "Porffor is alpha and still has a lot of
compatibility bugs" and "Porffor is still early: most existing JavaScript
projects will not work out of the box yet." The docs overview goes further and
says "Porffor is pre-alpha. Treat compatibility as something to verify, not
something to assume." (https://porffor.dev/docs/, read 2026-09-02 — note the site
and the docs disagree with each other about alpha vs pre-alpha.)

### Feature support against kaya's actual guest code

From the official runtime-surface page
(https://porffor.dev/docs/runtime.html, read 2026-09-02):

| kaya needs | Porffor status |
|---|---|
| closures | supported ("closures, classes and private fields, async functions, generators, destructuring, spread, symbols, templates, exceptions, regular expressions … are implemented") |
| classes | supported (incl. private fields) |
| tagged template literals | "templates" listed as implemented |
| async/await, Promise | supported: "Promise, iterators, async iterators; **timers only in event-loop server builds**" |
| Uint8Array / DataView | supported: "typed arrays, `ArrayBuffer`, `DataView`" |
| **Proxy** | **"Stub — The target is returned unchanged; traps never run."** |

The Proxy line is the one that matters and it is the worst possible shape of
failure. It is not a compile error — the page files it under a heading called
**"Silent gaps"**: "`Proxy` and `with` can compile without delivering spec
behavior. Search dependencies for them during migration." The migration guide
repeats it: "`Proxy` or runtime-generated code — **No reliable shim. Replace the
design or keep this code on another runtime.**"
(https://porffor.dev/docs/adapt.html, read 2026-09-02)

Confirmed structurally: the builtins directory
(https://api.github.com/repos/CanadaHonk/porffor/contents/compiler/builtins, read
2026-09-02) contains `promise.ts`, `dataview.ts`, `typedarray.js`,
`arraybuffer.ts`, `reflect.ts`, `generator.ts`, `symbol.ts` — and **no
`proxy.ts`**.

For kaya specifically this is fatal as written: the row handle is a Proxy whose
whole job is to refuse a misspelled field *by name*. Under Porffor the traps
never fire, so `todo.dnoe = true` would silently set a property on the target and
the record would be written wrong, with no error anywhere. That is precisely the
class of defect kaya's guard rules exist to make impossible.

Other gaps worth naming: `eval`/`new Function` are build-time only; BigInt is
partial; Atomics is "mostly stubbed"; there is **no `process` object**, no `fs`,
no `path`, no `node:` modules, no client `fetch`, no `crypto`, no workers, no
`structuredClone`, and — notably — **no `WebAssembly` object**. Plain builds
compile **one source file**: "Plain Porffor builds compile one source file.
Runtime `import` is not a module loader. Bundle a project before handing it to
the compiler" — the docs recommend esbuild for exactly that, which fits kaya's
"a normalization step is fine" ruling.

TypeScript is *syntax only*: "Annotations, interfaces, aliases, assertions,
`satisfies`, generics, enums, and type-only imports are accepted. Types are
erased… Namespaces and decorators parse but are not meaningfully supported. Keep
`tsc --noEmit` in CI for semantic checking."

### The native path — what it actually is

This is the part where the common description of Porffor is now **out of date**.
Porffor used to emit WebAssembly and reach native via wasm2c. It does not any
more. Reading `compiler/index.js` on main (2026-09-02), the whole pipeline is:

```
parse(code) -> codegen(program)  [Porffor IR] -> render(cg)  [C source]
   -> target 'c'      : write the C to a file
   -> target 'native' : invoke a C compiler on it
```

There is **no Wasm emitter left in the compiler**. `runtime/index.js`'s own
`--help` table lists exactly two commands beyond running a script:

```
porf c      foo.js -o foo.c    Compile to C source code
porf native foo.js -o foo      Compile to a native binary
```

(https://raw.githubusercontent.com/CanadaHonk/porffor/main/runtime/index.js, read
2026-09-02). The website's line "The same pipeline targets WebAssembly" therefore
means *compile the emitted C with a Wasm-targeting C compiler*, the same trick as
native — not a first-class Wasm backend.

The native compiler is chosen by `Prefs.compiler ?? process.env.CC ?? 'cc'`, with
`--cxx`/`CXX` for the C++ half and a `--musl` switch that hard-codes
`zig cc -target x86_64-linux-musl`. So the native path is: **generate C, hand it
to whatever C compiler you name.** That is the one interesting fact for kaya —
`porf c app.js -o app.c` produces "self-contained C source"
(https://porffor.dev/docs/runtime.html), and self-contained C is something the
iOS and Android toolchains can compile and link like any other C file. Nobody has
demonstrated that, and Porffor ships no iOS/Android target, but the shape of the
route exists and it is legal AOT.

Against it: "The result targets the OS and CPU architecture of the build machine…
A Porffor executable has no Node.js dependency, but it is not automatically
cross-platform. Build once per operating system and architecture you distribute."
(https://porffor.dev/docs/ship.html). And: "Windows is currently a WSL workflow.
Native Windows output is not part of the supported path yet."
(https://porffor.dev/docs/) — which is a problem for kaya, whose windows lane is
one of five.

### Calling a C ABI function

**Yes, and it is first class.** Porffor has a Deno-style FFI:
`Porffor.dlopen("libsqlite3.so.0", { sqlite3_open_v2: { parameters: ["buffer",
"buffer", "i32", "pointer"], result: "i32" }, … })`, used in the repo's own
benchmark
(https://raw.githubusercontent.com/CanadaHonk/porffor/main/bench/ffi/sqlite.porf.ts,
read 2026-09-02). Parameter kinds include `"pointer"`, `"buffer"` and `"i32"`,
and `Porffor.wasm.i32.load(ta, 0, 4)` is used to get a raw pointer out of a typed
array. That is exactly the shape kaya needs to reach `kaya_submit`. Caveat: it is
`dlopen`, i.e. a *dynamic* load at runtime, which on iOS means the library has to
be an embedded framework in the bundle rather than a system dylib — workable, but
not the static link an iOS app usually wants.

### Production use

None that I can find. There is a package-compatibility page
(https://porffor.dev/compat.html) driven by "Automated Porffor compatibility
testing for popular npm packages, using focused, LLM-generated test cases" —
which tells you where the project's confidence level actually is. The homepage's
performance section is honest in the same direction: Porffor beats Node's
`--jitless` mode by ~14% and QuickJS by 86%, but "Porffor is not at JIT level
yet: with their JITs on, Node and Bun score 13 to 17x higher on this suite."

### Verdict

Real AOT, real momentum (four alpha releases in three weeks, a single very
capable author), genuinely the most interesting thing in this space — and **not
something to build a shipping product on in 2026**. One test262 test in three
fails; the published conformance number is six months old; and the one feature
kaya's design depends on, Proxy, is a stub that returns the target unchanged and
never runs a trap. A silent-wrong-answer stub is worse for kaya than an
unimplemented feature, because no gate can see it.

---

## 2. AssemblyScript

**What it produces: WebAssembly, not native.** "AssemblyScript compiles a
*variant* of TypeScript (a typed superset of JavaScript) to WebAssembly using
Binaryen", and the canonical invocation is `asc fib.ts --outFile fib.wasm
--optimize`. (https://www.assemblyscript.org/introduction.html, read 2026-09-02)
There is no native-code backend. Whatever you do with the `.wasm` afterwards is
section 3's problem.

**Version and activity (read 2026-09-02).**
- npm `assemblyscript@0.28.20`, published **2026-07-22T02:56:28Z**
  (https://registry.npmjs.org/assemblyscript). Still 0.x after eight years.
- GitHub `v0.28.20` tagged 2026-07-22; last commits to `main` 2026-07-21
  ("chore: Update Binaryen and other dependencies (#3035)"). 18,000 stars, 203
  open issues, not archived.
  (https://api.github.com/repos/AssemblyScript/assemblyscript)
- So: alive, maintained, but in maintenance cadence — a dependency bump and a
  date fix in the last two months.

**What it does NOT support.** The authoritative page is
https://www.assemblyscript.org/status.html (read 2026-09-02), whose own headings
are "🥚 Not implemented" and "🕳️ Not supported":

*Not implemented:*
- **Closures.** "Captures of local variables are not yet supported… Can be worked
  around by using a global variable instead… or passing an argument." The page
  has a whole "On closures" section showing that `arr.forEach(value => { sum +=
  value })` **fails** and must be rewritten with a module-level global.
- **Iterators / `for..of`.** "Iterators and `for..of` loops are not supported yet."
- **Rest parameters.**
- **Exceptions.** "Exceptions require support from the WebAssembly engine first.
  **Throwing currently aborts the program.**"
- **Promises / async-await.** "There is no concept of async/await yet due to the
  lack of an event loop."
- **BigInt.**

*Limited:*
- **Union types** — "Union types are not supported yet, except for nullable class
  types. **There is no `any` type.**"
- Symbols (in stdlib, no deep compiler integration), object literals (only where
  the type is a bare class), **no JSON**, **no RegExp**, partial `Date`.
- OOP: "Access modifiers like `private` and `protected` are not currently
  enforced. There is rudimentary support for interfaces."

*Not supported at all — "Dynamicness":* the page lists, as things that will not
work, assigning any value to any variable, assigning an undeclared property to an
object, assigning a class to a variable, **patching prototypes ("there are
none")**, `arguments`, and "dynamically obtain the name of a function at runtime
or otherwise use reflection". **`Proxy` is not mentioned anywhere on the page** —
it is unreachable by construction, since a Proxy is a prototype-and-reflection
mechanism and AssemblyScript has neither. The page is explicit about why: "some
features would work in an interpreter and may become efficient with a JIT
compiler, yet going down that rabbit hole runs counter to WebAssembly's, and by
definition AssemblyScript's, goals."

There is also no standard JS stdlib in the Node sense — it has its own
"JavaScript-like standard library" (Math, Array<T>, String, Map<K,V>, typed
arrays) with `i32`/`u32`/`f64` WebAssembly types rather than JS `number`.

**Verdict for kaya.** AssemblyScript is not a JS/TS AOT compiler in the sense
this survey is about; it is a *different language with TypeScript syntax*. kaya's
binding uses closures, async/await, Promise, Proxy, exceptions and tagged
templates — five of the six are on the "not implemented / not supported" list.
Porting the binding to AssemblyScript is not a normalization step, it is a
rewrite into a language that cannot express the design, and the output is still
Wasm rather than native. Rule it out.

---

## 3. WebAssembly on iOS — does a Wasm route escape interpretation?

First, the platform rule, from Apple's own documentation rather than folklore.

**JIT on iOS.** The entitlement that permits writable-and-executable memory is
`com.apple.security.cs.allow-jit` — "A Boolean value that indicates whether the
app may create writable and executable memory using the `MAP_JIT` flag." Apple's
metadata for that page lists exactly one platform: **macOS, introduced 10.7. iOS
is not listed.** Its own text states the consequence: "Without the *Allow
execution of JIT-compiled code entitlement*, frameworks that rely on
just-in-time (JIT) compilation **may fall back to an interpreter**."
(https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit,
fetched via Apple's own documentation JSON 2026-09-02.)

I checked the whole entitlements index for any iOS JIT grant. The only
JIT-adjacent iOS entitlements are the alternative-browser-engine ones —
`com.apple.developer.embedded-web-browser-engine` (iOS/iPadOS 17.4+), whose
abstract reads "An entitlement that enables an app to embed an alternative
browser engine… To use the entitlement, request it from Apple. The steps to
request the entitlement vary by geographic region: … European Union … Japan."
(https://developer.apple.com/documentation/bundleresources/entitlements, index
JSON read 2026-09-02). That is not a general JIT route; it is a regulatory
carve-out for browser engines, granted case by case.

**Bundled code is fine; downloaded code is not.** App Store Review Guideline
2.5.2, verbatim: "Apps should be self-contained in their bundles, and may not
read or write data outside the designated container area, nor may they download,
install, or execute code which introduces or changes features or functionality
of the app, including other apps."
(https://developer.apple.com/app-store/review/guidelines/, read 2026-09-02.)
Shipping an interpreter plus the script inside the bundle is not what 2.5.2
forbids — that is how React Native, Hermes and every Lua-in-a-game work. So the
constraint that actually bites kaya is *technical* (no executable pages) and
*self-imposed* (the maintainer's "no interpretation" ruling), not App Review.

**Android is not affected by any of this.** Android permits JIT and permits
`mmap` with `PROT_EXEC`; every runtime below works there in its fastest mode.
Everything in this section is an iOS problem only.

### 3a. Wasm inside JavaScriptCore on iOS — interpreted

JavaScriptCore has a WebAssembly interpreter and it is what runs when there is no
JIT.

- WebKit's own blog, **"Introducing the JetStream 3 Benchmark Suite", dated
  Mar 31, 2026**: "JavaScriptCore has three execution tiers for WebAssembly: BBQ
  and OMG are the JIT tiers, as described above, but there is also **an
  interpreter tier, IPInt**. IPInt executes WebAssembly bytecode directly without
  any compilation, taking inspiration from the Wizard engine."
  (https://webkit.org/blog/17899/introducing-the-jetstream-3-benchmark-suite/,
  read 2026-09-02)
- IPInt = "in-place interpreter". Its first commits land in WebKit on
  **2023-07-20** ("Implement fundamentals of in-place interpreter"), followed by
  a run of commits through that summer (GitHub commit search over WebKit/WebKit,
  279 commits mentioning IPInt, read 2026-09-02).
- It is the **default** Wasm tier on iOS hardware:
  `static constexpr bool ipintEnabledByDefault() { return isARM64() || isARM64E()
  || isX86_64(); }`
  (https://raw.githubusercontent.com/WebKit/WebKit/main/Source/JavaScriptCore/runtime/Options.h,
  read 2026-09-02), wired to the option `useWasmIPInt` — "Use the in-place
  interpereter for WASM instead of LLInt"
  (`Source/JavaScriptCore/runtime/OptionsList.h`, same date). Both interpreters
  (LLInt and IPInt) exist; IPInt is the newer one.
- **Wasm is available with the JIT off.** `Wasm::isSupported()` is now just
  `return Options::useWasm();`
  (`Source/JavaScriptCore/wasm/WasmCapabilities.h`), and `canUseWasm()` is
  `#if ENABLE(WEBASSEMBLY) && !PLATFORM(WATCHOS) return true;`
  (`Source/JavaScriptCore/runtime/Options.cpp` line 1558) — no JIT test anywhere.
- And the code path proves the fallback explicitly. In
  `Source/JavaScriptCore/wasm/WasmIPIntPlan.cpp` (read 2026-09-02):

  ```cpp
  CodePtr<WasmEntryPtrTag> entrypoint { };
  #if ENABLE(JIT)
      if (Options::useJIT())
          entrypoint = LLInt::inPlaceInterpreterEntryThunk().retaggedCode<WasmEntryPtrTag>();
  #endif
      if (!entrypoint)
          entrypoint = LLInt::getCodeFunctionPtr<CFunctionPtrTag>(ipint_trampoline);
  ```

  With the JIT off, the entry point is a **plain C function pointer** into the
  interpreter. The same file even carries the sentence
  `"JIT is disabled, but the entrypoint for … requires JIT"` for the one case
  (SIMD without IPInt SIMD) that cannot be interpreted.

**Conclusion: running Wasm in JSC on iOS is interpretation, full stop.** It fails
the ruling exactly as running JS in JSC would.

### 3b. Standalone Wasm runtimes on iOS

**wasm3** — an interpreter, and honest about why that is the point. Its README
lists iOS among supported platforms and says: "Why use a 'slow interpreter'
versus a 'fast JIT'? … Finally, **on some platforms (i.e. iOS and WebAssembly
itself) you can't generate executable code pages in runtime, so JIT is
unavailable.**"
(https://raw.githubusercontent.com/wasm3/wasm3/main/README.md, read 2026-09-02).
Status: **v0.9.0 released 2026-08-24** — the first tagged release since v0.5.0 in
June 2021 — with commits as recent as 2026-09-02. 8,015 stars, 19 open issues.
(https://api.github.com/repos/wasm3/wasm3, read 2026-09-02.) So wasm3 has just
come back to life after four dormant years. It is an interpreter; it does not
satisfy the ruling.

**WAMR (WebAssembly Micro Runtime)** — three modes: interpreter, AOT (`wamrc`
producing `.aot`), and JIT. Note first that **the project moved out of the
Bytecode Alliance org**: `api.github.com/repos/bytecodealliance/wasm-micro-runtime`
now reports `full_name: wasm-micro-runtime/wasm-micro-runtime` (read 2026-09-02).
Latest release **WAMR-2.4.5, 2026-06-29**; active (commits 2026-09-01); 6,082
stars, 608 open issues.

- **iOS is not on WAMR's platform list.** The README's "Supported architectures
  and platforms" names Linux, Linux SGX, MacOS, Android, Windows, MinGW/MSVC,
  Zephyr, AliOS-Things, VxWorks, NuttX, RT-Thread, ESP-IDF. No iOS. And the AOT
  claim is scoped the same way: "Self-implemented AOT module loader to enable AOT
  working on **Linux, Windows, MacOS, Android, SGX and MCU systems**."
  (https://raw.githubusercontent.com/bytecodealliance/wasm-micro-runtime/main/README.md,
  read 2026-09-02). `core/shared/platform/` has a `darwin` directory and no `ios`
  one.
- **The measured answer for iOS is in WAMR's own issue tracker.** Issue #242,
  "AOT support for iOS platform" (opened 2020-04-28, closed 2020-07-20): the
  reporter measured "1. the interpreter mode works fine on both iOS simulator and
  real device 2. AOT mode works fine on simulator (target=x86_64) but **fails on
  real device (target=aarch64)**" with `EXC_BAD_ACCESS`. Maintainer `xwang98`
  replied 2020-04-29: "**iOS doesn't support mmap for allocating executable
  memory, right? Then it is probably not able to support AoT on iOS.**"
  (https://github.com/wasm-micro-runtime/wasm-micro-runtime/issues/242)
- Still true five years later. Issue #4166 (2025-03-28, **open**): "I tested WAMR
  on iOS, and the interpreter mode worked fine. **I know iOS does not support
  using mmap to allocate executable memory, so AOT mode is not supported on
  iOS.**" The thread then discusses static-linking the AOT module instead, and a
  commenter notes "iOS requires code signing or the device will refuse to run the
  app, so at least the AOT module's code needs to be signed along with the host
  app when it's built" — which a maintainer concedes: "You are right that the App
  Store policy wouldn't allow it. I was speaking from a purely technical
  standpoint, and it would only work for development."
  (https://github.com/wasm-micro-runtime/wasm-micro-runtime/issues/4166)
- **Does XIP help? No.** WAMR's XIP doc opens: "Some IoT devices may require to
  run the AOT file **from flash or ROM which is read-only**, so as to reduce the
  memory consumption, or resolve the issue that there is no executable memory
  available to run AOT code." XIP's mechanism is *removing relocations* —
  indirect calls through a function-pointer table (`--enable-indirect-mode`) and
  replacing LLVM intrinsics (`--disable-llvm-intrinsics`) — so the AOT text
  section never has to be *patched*.
  (https://raw.githubusercontent.com/bytecodealliance/wasm-micro-runtime/main/doc/xip.md,
  read 2026-09-02.) XIP solves "the code cannot be written to". iOS's problem is
  the other one: **the code cannot be made executable**, because every executable
  page must be backed by a valid code signature. An `.aot` file sitting in your
  app bundle is data; there is no signature covering it as code. XIP does not
  change that.
- The escape hatch a maintainer pointed at is **wasm2native**
  (https://github.com/web-devkits/wasm2native) — compile the `.wasm` to a native
  *object file* and link it into the binary at build time, which the code signer
  then covers. That is legal AOT and is the same idea as wasm2c. But the project
  is a stub: **26 stars, last commit 2024-08-20**, 2 open issues
  (https://api.github.com/repos/web-devkits/wasm2native, read 2026-09-02), and
  the maintainer's own answer to "can it be used on an iOS app?" was "In theory
  it should work, but I didn't try it on iOS platform and it may need some extra
  configuration" (2025-04-10, same thread). Treat it as abandoned research.

**Wasmtime** — precompilation exists, an interpreter exists, and only the
interpreter reaches iOS.

- Version: **v48.0.1, 2026-08-24** (https://api.github.com/repos/bytecodealliance/wasmtime/releases,
  read 2026-09-02).
- Precompiled modules: `Engine::precompile_module` / `Module::deserialize`, plus
  the `wasmtime compile` CLI, and `Config::target("x86_64")` for cross-target
  compilation. Wasmtime can even be built **run-only**: "Wasmtime can be built
  such that it can *only* run Wasm programs that were pre-compiled elsewhere.
  These builds will not include the executable code for Wasm compilation. This is
  done by disabling the `cranelift` and `winch` cargo features at build time."
  (https://docs.wasmtime.dev/examples-pre-compiling-wasm.html, read 2026-09-02.)
  The `.cwasm` is native machine code that gets `mmap`ed and made executable at
  load — the doc sells exactly that: "Pre-compiled Wasm programs can be lazily
  `mmap`ed from disk, only paging their code into memory as those code paths are
  executed." On iOS that mapping is the thing that cannot be made executable.
- **Pulley is an interpreter.** Its own README: "Pulley is a portable bytecode and
  fast interpreter for use in Wasmtime. Pulley's primary goal is portability and
  its secondary goal is fast interpretation… **Pulley is very much still a work in
  progress!** Expect the details of the bytecode to change, instructions to appear
  and disappear, and APIs to be overhauled."
  (https://raw.githubusercontent.com/bytecodealliance/wasmtime/main/pulley/README.md,
  read 2026-09-02.) The RFC's motivation is ISA portability — "Adding a portable
  interpreter to Wasmtime means that you will be able to take Wasmtime anywhere
  that you can compile Rust. However, you will not have the near-native execution
  speeds you can expect from an optimizing Wasm compiler."
  (https://github.com/bytecodealliance/rfcs/blob/main/accepted/pulley.md)
- **And Pulley is the answer Wasmtime gives for iOS.** Issue #12251, "[Question]
  Is Pulley the right solution for running Kotlin/Wasm (GC + EH) dynamically on
  iOS?" (2026-01-07). Chris Fallin, Wasmtime maintainer, same day: "Yes, Pulley
  supports GC and exception handling! And, as far as I know, **it should work on
  iOS: execution with Pulley doesn't generate or jump to any native code.**"
  (https://github.com/bytecodealliance/wasmtime/issues/12251) The asker's premise
  is the other half of the citation: "On iOS, I can't use JIT (Cranelift) due to
  code-signing restrictions, and static AOT doesn't solve the dynamic loading
  requirement."
- Support tiers (https://docs.wasmtime.dev/stability-tiers.html, read 2026-09-02):
  **Pulley is Tier 2** ("More time fuzzing/baking"); **`aarch64-apple-ios` and
  `aarch64-linux-android` are Tier 3** ("CI testing, full-time maintainer"
  missing). So the iOS story is: an unfinished interpreter on an untested target.

**Wasmer** — the advertised iOS/headless story has been quietly dismantled.

- Version: **v7.4.0, 2026-08-31**; 21,007 stars; very active
  (https://api.github.com/repos/wasmerio/wasmer, read 2026-09-02).
- **`wasmer create-exe` no longer exists.** PR #6923, "feat!: drop legacy
  create-exe code", **merged 2026-08-27**, body: "We made `create-exe` obsolete
  some time ago, and I think we can remove the underlying infrastructure now. If
  we want to support this functionality again in the future, we can simply provide
  a Rust binary crate that embeds modules/WebC files as resources and invokes them
  through the Wasmer API."
  (https://github.com/wasmerio/wasmer/pull/6923). There is no
  `create_exe.rs` in `lib/cli/src/commands/` on `main` today
  (https://api.github.com/repos/wasmerio/wasmer/contents/lib/cli/src/commands,
  read 2026-09-02). What survives is `wasmer compile -o out --target <triple>`,
  which produces a *serialized module*, not a linkable object file. Wasmer also
  dropped the WAMR and Wasmi backends (PR #6500, 2026-04-20) and the
  x86_64-darwin target (PR #6506, 2026-04-21).
- **"Headless" on iOS means: load a precompiled `.wasmu` — which still needs
  executable memory.** A `make build-capi-headless-ios` target exists and has a
  history of breaking (issues #5329, #5565). In the standing question thread
  #5571 (2025-05-16, still open), a user states the design plainly: "because
  iOS policy forbids compiling on the phone, the official build scripts only
  provide headless mode for iOS; headless means serializing the module to
  `.wasmu` after loading the wasm and loading that directly on the device without
  recompiling — but that is tied to the CPU architecture." No one in that thread
  reports it running on an iOS device.
  (https://github.com/wasmerio/wasmer/issues/5571)
- **The most recent first-hand report is negative.** Issue #6381, "Many
  modifications necessary to run on iOS" (2026-03-31, **open**): a contributor
  got Wasmer working on iOS only after a stack of patches including "**MAP_JIT
  support on Apple aarch64 (iOS and macOS Hardened Runtime)**" and "Static object
  compilation and linking for Apple targets", and concluded: "**Given the extent
  of the changes necessary to get Wasmer working on iOS, I've decided to use a
  different Wasm runtime for my use case**, which works without modifications."
  (https://github.com/wasmerio/wasmer/issues/6381) The `MAP_JIT` line is the tell:
  the headless path is still executing freshly-mapped native code, which on a
  store-distributed iOS app is exactly what is not allowed.

### 3c. wasm2c (WABT) and w2c2 — the one route that is legal AOT on iOS

Both take a `.wasm` and emit **portable C** that you compile with clang at
*build* time and link into your app. The resulting machine code is inside your
signed binary, indistinguishable from any other object file. Nothing is mapped
executable at runtime, nothing is interpreted, and Apple has nothing to object to.

**wasm2c** (part of WABT). "`wasm2c` takes a WebAssembly module and produces an
equivalent C source and header… The C code produced targets the C99 standard."
(https://raw.githubusercontent.com/WebAssembly/wabt/main/wasm2c/README.md, read
2026-09-02). Release **1.0.41 on 2026-05-07**, repo pushed 2026-08-30, 8,117
stars (https://api.github.com/repos/WebAssembly/wabt, read 2026-09-02). Mature and
production-proven — it is the sandboxing compiler behind RLBox. Notable
sharp edge the README states: "wasm2c relies on certain behavior from the C
compiler to maintain conformance with the WebAssembly specification… When
compiling with optimization (e.g. `-O2` or `-O3`), it's necessary to disable some
optimizations to preserve conformance. With… clang 14, just
`-fno-optimize-sibling-calls -frounding-math` appears to be sufficient."

**w2c2**. "Translates WebAssembly modules to portable C. Inspired by wabt's
wasm2c… Passes 99.9% of the WebAssembly core semantics test suite… Written in
(mostly) C89 and generates (mostly) C89… **Performance — Coremark 1.0: ~7% slower
than native.**" (https://raw.githubusercontent.com/turbolent/w2c2/main/README.md,
read 2026-09-02). 825 stars, last commit **2026-08-01**
(https://api.github.com/repos/turbolent/w2c2). Has its own WASI implementation
"able to run clang and Python". One maintainer, but steadily worked on.

**Performance versus native.** w2c2's own published figure is the concrete one:
**~7% slower than native on Coremark 1.0**. For a peer-reviewed placement, the
USENIX Security 2022 paper *Provably-Safe Multilingual Software Sandboxing using
WebAssembly* (Bosamiya, Lim, Parno; Distinguished Paper) benchmarks wasm2c
against wasm3, WAMR (both modes), Wasmer, Wasmtime and WAVM on all thirty
PolyBench-C programs, normalized to native clang -O3. wasm2c sits in the
**fastest group** — the paper's own summary is that rWasm "is only slower by 3%
to 26% on average than the first three of the four faster runtimes on the list
(**wasm2c**, WAMR in AOT compilation mode, and wasmtime respectively)" — while
the interpreters are far behind: their verified compiler vWasm "is on average
**2× to 3× faster than the interpreters**" and yet still "slower than the other
compilers by **3.5× to 7.5×**". Composing those: **an AOT-compiled Wasm module
(the wasm2c class) is roughly 7×–22× faster than a Wasm interpreter** on that
suite. (https://www.usenix.org/system/files/sec22-bosamiya.pdf, §6.1.1 and
Figure 6, read 2026-09-02.) The commonly-repeated "wasm2c is ~2x native" claim
should not be quoted without a source; what I could verify is the two figures
above.

**Calling a C ABI function from wasm2c output.** Direct and static: "If a module
imports a function, `wasm2c` declares the function in the output header file, and
**the host function is responsible for defining the function**" (wasm2c README).
So `kaya_submit` becomes an ordinary C symbol resolved by the linker — no
`dlsym`, no trampolines. The friction is the sandbox boundary: a pointer inside
the module is an offset into a `wasm_rt_memory_t`, not a host address, so every
`Uint8Array` handed across has to be translated to `mem->data + offset`. That is
a wrapper layer, not a blocker.

**Build cost, stated honestly.** This route means: for every change to the guest
TypeScript, run (TS → JS bundle) → (JS → Wasm, by *some* compiler) → wasm2c →
clang → link. Two of those steps are ordinary build steps kaya already tolerates
(esbuild, cargo). The one that does not exist is the middle one — see below.

### 3d. Plain conclusion for section 3

**On iOS, no Wasm route escapes interpretation *at runtime* except one: compile
the Wasm to C at build time (wasm2c or w2c2) and link the C into the app.** Every
in-process Wasm *runtime* on iOS — JavaScriptCore's IPInt, wasm3, WAMR's
interpreter mode, Wasmtime's Pulley, and in practice Wasmer's headless mode too —
is either an interpreter or needs executable pages iOS will not grant. WAMR's XIP
does not help, because it solves read-only *code* rather than non-executable
*data*. Wasmer's static-link route (`create-exe`) was deleted from the tree six
days ago.

And the sting: **wasm2c does not solve kaya's problem, because kaya's input is
JavaScript, not Wasm.** wasm2c is the second half of a pipeline whose first half —
a JS→Wasm compiler that supports Proxy, async/await and DataView — is the very
thing that does not exist (section 1: Porffor no longer even emits Wasm; section
2: AssemblyScript is a different language). Wasm-on-iOS is a solved problem for
Rust and C. For JavaScript it is not, and Wasm is not where the difficulty lies.

---

## 4. Other JS AOT compilers, and the things people mistake for them

Static Hermes (`shermes`) is deliberately out of scope here — another agent is
covering it in depth. In one line: it is the only *credible* JS→native compiler
besides Porffor, and it is the one route worth taking seriously alongside them.

### 4a. Genuine JS → native attempts

**NectarJS / Nerd — dead.** Tagline: "No VM. No Bytecode. No packaging. No
Garbage Collector. Fully compiled to native binaries", and the README claims
"Nerd is a JavaScript native compiler… able to compile native apps for Windows,
Mac, Linux, **iOS**, Android, Raspberry, STM32 and more."
(https://raw.githubusercontent.com/NectarJS/nectarjs/master/README.md) Reality:
**last commit 2022-12-30**, repo last pushed **2023-01-25**, 3,613 stars, 16 open
issues (https://api.github.com/repos/NectarJS/nectarjs, read 2026-09-02). Its own
README says "NectarJS becomes Nerd" and points at a Trello roadmap and a Discord.
The stated goal was "Supporting EcmaScript 3 standard (then 5, 6 …)". Three and a
half years without a commit. Do not build on this.

**ts2c — a toy, honestly labelled.** "Produces readable C89 code from JS/TS code."
Its own Project status section: "**Work in progress:** it works, but only about
**70% of ES3** specification is currently supported: statements and expressions -
95%, **built-in objects - 17%**. Notable NOT supported features include, for
example: float and big numbers (**all numbers are `int16_t` currently**),
`prototype`, `eval`, `Date`, `Math`, etc."
(https://raw.githubusercontent.com/andrei-markeev/ts2c/master/README.md, read
2026-09-02). Last push 2025-11-21, 1,377 stars. ES3 with 16-bit integers has no
classes, no Promise, no Proxy, no TypedArray, no DataView. Not applicable.

### 4b. "Compilers" that produce bytecode — the JS is still interpreted

These are the ones most often mistaken for AOT-to-native. All four ship a
*bytecode compiler plus an interpreter*; at runtime the interpreter walks the
bytecode.

**QuickJS `qjsc`.** From the official manual (QuickJS version 2026-06-04): "The
`qjsc` compiler generates C sources from Javascript files. By default the C
sources are compiled with the system compiler (`gcc` or `clang`). **The generated
C source contains the bytecode of the compiled functions or modules.** If a full
complete executable is needed, it also contains a `main()` function with the
necessary C code to initialize the Javascript engine and to load and execute the
compiled functions and modules." And: "`qjsc` works by compiling scripts or
modules and then **serializing them to a binary format**." The flags say the same
thing: `-c` "Only output bytecode in a C file", `-e` "Output `main()` and
bytecode in a C file". (https://bellard.org/quickjs/quickjs.html §4.2, read
2026-09-02.) So `qjsc -o hello hello.js` gives you a self-contained native
executable — of the **QuickJS interpreter**, with your program's bytecode baked
in as a byte array. **The JavaScript is interpreted at runtime.** It fails the
ruling. (Both forks are alive: bellard/quickjs pushed 2026-06-16, quickjs-ng
pushed 2026-09-02.)

**Moddable XS `xsc`.** "**xsc** is the XS compiler, a command line tool that
compiles files containing JavaScript source code … into **XS binary files
containing symbols and byte codes**."
(https://raw.githubusercontent.com/Moddable-OpenSource/moddable/public/documentation/tools/tools.md,
read 2026-09-02). Moddable 9.0.0 released 2026-08-05; healthy project. Same
verdict: bytecode, interpreted by XS at runtime. XS is excellent at what it does
(JS on microcontrollers with a few hundred KB of RAM) and is not an AOT-to-native
compiler.

**Hermes `hermesc`.** "Hermes is a JavaScript engine optimized for fast start-up
of React Native apps. It features **ahead-of-time static optimization and compact
bytecode**." (https://raw.githubusercontent.com/facebook/hermes/main/README.md,
read 2026-09-02.) The "ahead-of-time" there is *bytecode* generation plus
optimization passes — `doc/Design.md` describes "a register-based bytecode" whose
opcodes are chosen so the *interpreter* can dispatch them efficiently ("it does
introduce a few more opcodes which could slow down the interpreter"). HBC is
interpreted. Repo very active (pushed 2026-09-03), though the last tagged release
is v0.13.0 from 2024-08-16 because Hermes ships on React Native's cadence.

**JerryScript snapshots.** `jerry_generate_snapshot` / `jerry_exec_snapshot`
serialize the parsed program — "Snapshots contain literal pools, and these
literal pools contain references to constant literals… **Hence these snapshots
can be executed from ROM**" (static snapshots)
(https://raw.githubusercontent.com/jerryscript-project/jerryscript/master/docs/02.API-REFERENCE.md,
read 2026-09-02). A snapshot is bytecode; `jerry_exec_snapshot` runs it on the
JerryScript interpreter. v3.0.0 released 2024-12-18; last push 2025-10-08 —
slowing down.

### 4c. Things that are not AOT-to-native at all

**Prepack.** "Prepack is a partial evaluator for JavaScript. Prepack rewrites a
JavaScript bundle, **resulting in JavaScript code** that executes more
efficiently." Input JS, output JS — never native. And it is dead: the repo is
`facebookarchive/prepack`, **archived**, last pushed 2022-02-11, with the README
still carrying "We, the Prepack team at Facebook, have temporarily set down work
on Prepack".
(https://raw.githubusercontent.com/facebookarchive/prepack/master/README.md and
https://api.github.com/repos/facebookarchive/prepack, read 2026-09-02.)

**GraalVM Native Image + GraalJS.** This is the one people most often get wrong,
so state the mechanism precisely. `native-image` AOT-compiles a *JVM program* to
a native binary. When that program is a Truffle language implementation such as
GraalJS, what gets AOT-compiled is **the JavaScript interpreter**, not your
JavaScript. Your JS is then executed by that interpreter, and the way it becomes
machine code is **runtime compilation** — a JIT, done by the Graal compiler
embedded in the image. GraalVM's own docs define the two modes:

> **Optimizing runtime:** Executed guest application code can be compiled and
> executed as highly efficient machine code **at run time**.
> **Fallback runtime:** The guest application code is executed in
> **interpreter-only mode, without runtime compilation to machine code**.

and print this at startup when the fallback is in force:

> `[engine] WARNING: The polyglot engine uses a fallback runtime that does not
> support runtime compilation to native code. Execution without runtime
> compilation will negatively impact the guest application performance.`

(https://www.graalvm.org/latest/reference-manual/embed-languages/, "Runtime
Optimization Support", read 2026-09-02.)

**Is there any "AOT the guest JS" story?** No. The closest thing is Truffle's own
"AOT" feature, which is *not* build-time: "AOT compilation can be triggered and
tested by using the `--engine.CompileAOTOnCreate=true` option. This will trigger
AOT compilation for every created call target with a root node that supports AOT
compilation… Note that enabling this flag will also disable background
compilation which makes it not suitable for production usage."
(https://www.graalvm.org/latest/graalvm-as-a-platform/language-implementation-framework/AOT/,
read 2026-09-02.) That is "compile the AST before its first execution instead of
after N warm-up iterations" — still runtime compilation, still needs a JIT.

**On iOS**, therefore: even if you got the image onto the device, Truffle would
have no runtime compiler and would fall back to interpreter-only mode — the same
outcome as JSC, only slower. And getting there is itself an unpaved road: GraalVM
says Native Image is "Available for Linux, macOS, and Windows platforms"
(https://www.graalvm.org/latest/reference-manual/native-image/, footer, read
2026-09-02). iOS comes only via **Gluon Substrate**, which "converts Java(FX)
Client applications into native executables for desktop, mobile and embedded
devices… It uses the GraalVM native-image tool to compile the required Java
bytecode into code that can be executed on the target system (e.g. your desktop,
on iOS, on a Raspberry Pi)"
(https://raw.githubusercontent.com/gluonhq/substrate/master/README.md; release
0.0.69 on 2026-06-18, 446 stars,
https://api.github.com/repos/gluonhq/substrate, read 2026-09-02). Nobody appears
to have combined the two for JS: a search of oracle/graaljs issues for "iOS"
returns **five results total, none about running GraalJS on iOS**
(GitHub issue search, read 2026-09-02).

**Bun `bun build --compile`.** Bundles, does not compile. Bun's own words: "Bun
bundles all imported files and packages into the executable, **along with a copy
of the Bun runtime**. All built-in Bun and Node.js APIs are supported."
(https://bun.com/docs/bundler/executables, Bun v1.4.0, read 2026-09-02). Its
`--target` list is `bun-linux-x64`, `bun-linux-arm64`, `bun-windows-x64`,
`bun-windows-arm64`, `bun-darwin-arm64`, `bun-darwin-x64` — **no iOS, no
Android**. The runtime it embeds is JavaScriptCore, JIT and all. There is also a
`--bytecode` flag ("Bytecode Caching") which caches JSC bytecode to cut startup;
that is a cache, not a compiler.

**Deno `deno compile`.** Same shape, stated even more plainly: "`deno compile`
embeds your program into `denort` ('Deno runtime'): a **stripped build of Deno**
that contains only what's needed to run a compiled program, with none of the
tooling subcommands." Supported targets, complete: `x86_64-pc-windows-msvc`,
`aarch64-pc-windows-msvc`, `x86_64-apple-darwin`, `aarch64-apple-darwin`,
`x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu` — **no iOS, no Android**.
(https://docs.deno.com/runtime/reference/cli/compile.md, page `last_modified:
2026-08-06`, read 2026-09-02.) Deno now also has an experimental
`deno compile --engine quickjs`, and its own trade-off note is the point of this
whole section: "**QuickJS is an interpreter with no JIT**, so compute-heavy code
runs slower than on V8."

Neither `bun build --compile` nor `deno compile` is AOT compilation of
JavaScript. They are self-extracting bundles of (your JS) + (a full JS engine),
for desktop and server only.

---

## 5. The honest summary table

All statuses read 2026-09-02. "Interpreted?" means: at runtime on the device, is
the guest JavaScript walked by an interpreter?

| Route | What it actually produces | JS interpreted at runtime? | Works on iOS today? | Maturity | Can the compiled program call a C ABI function? |
|---|---|---|---|---|---|
| **Porffor** | Porffor IR → **C source** → native binary via your `cc`. `porf c` stops at self-contained C. | **No** — genuinely AOT | **Untested.** No iOS target; "The result targets the OS and CPU architecture of the build machine." The `porf c` → clang-for-iOS route is plausible and undemonstrated. | **alpha-4, 2026-08-29** (alpha since 2026-08-12). test262 **67.45%**, published figure last updated 2026-03-06. One author. | **Yes**, first class: `Porffor.dlopen(lib, {fn:{parameters:["pointer","buffer","i32"],result:"i32"}})`. `dlopen`-based, so an embedded framework on iOS. |
| **AssemblyScript** | **WebAssembly** (`asc x.ts -o x.wasm`), via Binaryen | n/a — it is not JS | n/a (output is Wasm; see the Wasm rows) | 0.28.20, 2026-07-22; 8 years old, still 0.x; maintenance cadence | Only through a Wasm host's imports |
| **Wasm in JavaScriptCore (iOS)** | nothing — runs a `.wasm` | **Yes** — IPInt / LLInt. `Options::useJIT()` false ⇒ `ipint_trampoline` C function pointer | Yes, and it is interpreted | Shipping, mature | Yes, via JS imports through the JSC C API |
| **wasm3** | nothing — runs a `.wasm` | **Yes**, by design ("on some platforms (i.e. iOS…) you can't generate executable code pages in runtime") | Yes, interpreted | v0.9.0 **2026-08-24**, first tag since 2021; active again | Yes — register native functions |
| **WAMR interpreter** | nothing — runs a `.wasm` | **Yes** | Yes, interpreted (reported working on device since 2020) | WAMR-2.4.5, 2026-06-29; note the repo moved out of Bytecode Alliance | Yes — `export_native_api` |
| **WAMR AOT (`wamrc` → `.aot`)** | native code in a `.aot` file, `mmap`ed executable | No | **No.** "iOS doesn't support mmap for allocating executable memory… probably not able to support AoT on iOS" (maintainer, #242); still stated in #4166 (2025). XIP does not help — it solves read-only *code*, not non-executable *data*. | Mature on Linux/Windows/macOS/Android/MCU. iOS is not on the platform list. | Yes |
| **Wasmtime + Cranelift / `.cwasm`** | native code, `mmap`ed executable at `Module::deserialize` | No | **No** — needs executable pages | v48.0.1, 2026-08-24; `aarch64-apple-ios` is **Tier 3** | Yes — host funcs in Rust/C API |
| **Wasmtime + Pulley** | nothing — runs a `.cwasm` of Pulley bytecode | **Yes** — Pulley is an interpreter | Yes: "it should work on iOS: execution with Pulley doesn't generate or jump to any native code" (cfallin, 2026-01-07) | Pulley **Tier 2**, "very much still a work in progress"; iOS **Tier 3** | Yes |
| **Wasmer headless / `.wasmu`** | precompiled native module, loaded at runtime | No | **In practice no.** The one 2026 first-hand report needed a `MAP_JIT`-on-iOS patch and the author then switched runtimes (#6381). | v7.4.0, 2026-08-31, very active — but **`create-exe` was deleted 2026-08-27** (PR #6923), removing the static-link route | Yes |
| **wasm2c (WABT)** | **portable C99**, compiled by *your* clang at build time and linked in | **No** | **Yes — this is the one Wasm route that is legal AOT on iOS.** Code lives inside the signed binary; nothing is mapped executable at runtime. | WABT 1.0.41, 2026-05-07; mature, production-proven (RLBox) | **Yes, directly**: "If a module imports a function, `wasm2c` declares the function in the output header file, and the host function is responsible for defining the function." Pointers need offset↔host translation across the sandbox. |
| **w2c2** | portable **C89** | **No** | Yes, same reasoning | 825 stars, last commit 2026-08-01, one maintainer; "passes 99.9% of the WebAssembly core semantics test suite"; **~7% slower than native on Coremark 1.0** | Yes, same shape as wasm2c |
| **wasm2native (WAMR-adjacent)** | native **object file** you link | No | Untried — "In theory it should work, but I didn't try it on iOS" | **Abandoned**: 26 stars, last commit 2024-08-20 | Yes |
| **QuickJS `qjsc`** | C file containing **bytecode** + the QuickJS interpreter | **Yes** | Yes (interpreted) | Mature; both forks active (bellard 2026-06-16, quickjs-ng 2026-09-02) | **Yes, excellent** — `JS_NewCFunction`, C modules |
| **Moddable XS `xsc`** | "XS binary files containing symbols and **byte codes**" | **Yes** | Yes (interpreted) | Moddable 9.0.0, 2026-08-05; mature for embedded | Yes — "XS in C" host functions |
| **Hermes `hermesc`** | HBC **bytecode** | **Yes** | Yes (interpreted) — this is what React Native ships | Mature, pushed 2026-09-03 | Yes — JSI HostFunction |
| **JerryScript snapshots** | serialized **bytecode** | **Yes** | Yes (interpreted) | v3.0.0 2024-12-18, last push 2025-10-08 — slowing | Yes — external functions |
| **Prepack** | **JavaScript** | Yes (whatever runs it) | n/a | **Archived**, last push 2022-02-11 | n/a |
| **GraalVM Native Image + GraalJS** | a native binary containing **the JS interpreter**; your JS stays source/AST | **Yes on iOS.** With the optimizing runtime it JITs at run time; without a JIT it uses the "fallback runtime… interpreter-only mode" | Not realistically. Native Image is "Available for Linux, macOS, and Windows"; iOS only via Gluon Substrate, and no one has done it with GraalJS | GraalVM mature; this combination unexplored | Yes, via Truffle NFI / polyglot host access |
| **Bun `bun build --compile`** | your bundle **+ a copy of the Bun runtime** (JSC) | **Yes** (JIT'd, on desktop) | **No** — targets are linux/windows/darwin only | Mature (Bun 1.4.0) | Yes — `bun:ffi` (`dlopen`) |
| **Deno `deno compile`** | your bundle embedded in **`denort`, a stripped build of Deno** | **Yes** | **No** — targets are windows/macos/linux only | Mature | Yes — `Deno.dlopen` |
| **NectarJS / Nerd** | claims native binaries incl. iOS | claims no | **No** — dead | **Dead**: last commit 2022-12-30 | unknown |
| **ts2c** | readable C89 | No | (would be, if it could compile anything real) | **Toy**: "~70% of ES3… built-in objects 17%… all numbers are `int16_t`" | n/a |
| **Static Hermes (`shermes`)** | native code | No | *covered by a separate agent* | *see that report* | *see that report* |

---

## 6. What this adds up to

1. **On iOS, "AOT-compiled JavaScript" has exactly two live candidates: Porffor
   and Static Hermes.** Everything else on the list is either an interpreter, a
   bytecode compiler feeding an interpreter, a bundle-plus-runtime, dead, or a
   toy. That is the whole field as of 2026-09-02.

2. **The Wasm detour does not help, because the hard half is JS→Wasm, not
   Wasm→iOS.** Wasm→iOS is solved: wasm2c/w2c2 emit C, you compile it with the
   iOS toolchain, and it is ordinary signed native code with no interpreter and
   no executable-page problem. But there is no JS→Wasm compiler to feed it.
   Porffor abandoned its Wasm backend (main today has only `c` and `native`
   targets), and AssemblyScript is a different language that lacks closures,
   exceptions, Promises and prototypes. Every *runtime* Wasm route on iOS —
   JSC's IPInt, wasm3, WAMR interpreter, Pulley, Wasmer headless — is an
   interpreter or needs pages iOS will not make executable.

3. **Porffor's `Proxy` is a stub that silently returns the target and never runs
   a trap**, filed by Porffor's own docs under "Silent gaps". kaya's row handle is
   a Proxy whose contract is to refuse a misspelled field by name. Under Porffor
   that contract inverts into a silent wrong write, which no gate can observe.
   Any Porffor plan starts with "replace the Proxy design", which is a binding
   redesign, not a port.

4. **Watch the strategic direction of the field.** In the last six months the
   ecosystem moved *toward* interpreters for constrained platforms, not away:
   Wasmtime added Pulley and a maintainer named it the iOS answer; Deno added a
   QuickJS engine option; wasm3 came back from the dead; Wasmer *deleted*
   `create-exe`, its static-link AOT path, six days ago. The one countercurrent
   is Porffor going alpha on 2026-08-12 with four releases in three weeks.

5. **Calling into a Rust C ABI is not the constraint.** Every serious route can
   do it: Porffor via `Porffor.dlopen` with pointer/buffer parameter kinds,
   wasm2c by declaring the import as a C symbol you define and the linker
   resolves, QuickJS/XS/Hermes/JerryScript through their C embedding APIs.
   Choose the route on language coverage and iOS legality; the FFI will follow.
