# macOS SDK bump — scout report

Read-only scout. Nothing in the repo was edited. Host: macOS 26.5.2 (25F84), arm64.
All numbers below are MEASURED on this machine unless marked otherwise.

---

## 1. THE FLAKE

`/Users/akhilindurti/Projects/kaya/flake.nix` — **contains no `apple-sdk` attribute at all.**
There is no `apple-sdk_14`, no override, no `MACOSX_DEPLOYMENT_TARGET` export, no
`darwinMinVersionHook`. The SDK that kaya-built guests link against is the
**nixpkgs darwin stdenv default**, inherited silently.

Measured inside `nix develop -c`:

```
DEVELOPER_DIR=/nix/store/mxzgf8zlr2mbxrqp1ami2ixqsqpskv0w-apple-sdk-14.4
SDKROOT=$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
MACOSX_DEPLOYMENT_TARGET=14.0
KAYA_DEV_SHELL=e859f7603e13
cc  -> /nix/store/yn81qpksaxk576qb807fsck5ch7zmj6c-clang-wrapper-21.1.8/bin/cc
```

Where those values come from (evaluated at the locked rev):

```
stdenv.hostPlatform.darwinMinVersion  = 14.0   <- becomes MACOSX_DEPLOYMENT_TARGET
stdenv.hostPlatform.darwinSdkVersion  = 14.4
pkgs.apple-sdk (default)              = apple-sdk-14.4
```

`DEVELOPER_DIR`/`SDKROOT` are exported by the SDK derivation's own setup hook
(`.../apple-sdk-14.4/nix-support/setup-hook`, line 85). Nothing in kaya sets them.

**Consequence that matters:** because the SDK arrives from the stdenv rather than
from an attribute in `flake.nix`, there is currently *no line in the repo that
states which macOS SDK kaya links against*. A reader cannot find it, and a
nixpkgs input bump moves it with no diff in `flake.nix`.

### flake.lock

```
nixpkgs      rev 3b32825de172d0bc85664f495edb096b10862524   (nixpkgs-unstable, 2026-07-12)
rust-overlay rev e013376c32a8fcf07ddb6ec71739552bc118b7bd   (2026-07-13, follows nixpkgs)
```

### KAYA_DEV_SHELL fingerprint

`flake.nix:122` sets `KAYA_DEV_SHELL` to the first 12 chars of
`sha256(flake.nix ++ flake.lock)`; the `tools/` scripts recompute it with
`cat flake.nix flake.lock | shasum -a 256` and refuse to run on a mismatch.

**Implication for the bump:** editing `flake.nix` changes the fingerprint, so
*every already-open dev shell and direnv session becomes a bystander toolchain
and every `tools/` script refuses immediately*. The bump is not "edit and keep
working" — it is edit, `exit`, re-`nix develop` (or `direnv reload`), then rebuild.
Any stale shell left open in another terminal will fail loudly, which is the
correct behavior and worth expecting rather than debugging.

Note also `tools/lib/swift-toolchain.sh` — it exists precisely because the nix
`DEVELOPER_DIR` breaks Apple tools. Same trap bit this scout: `/usr/bin/vtool`
is an `xcrun` shim and reports `tool 'vtool' not found` inside the dev shell.
Measurements below were taken with `env -u DEVELOPER_DIR -u SDKROOT`.

---

## 2. WHAT NIXPKGS OFFERS

Evaluated at **the locked rev** (`3b32825`), `system = aarch64-darwin`:

| attribute | version | status |
|---|---|---|
| `apple-sdk` (default) | **14.4** | what the shell gets today |
| `apple-sdk_11` | — | removed ("Nixpkgs no longer supports macOS 11", 25.11 release notes) |
| `apple-sdk_12` | — | removed |
| `apple-sdk_13` | — | removed |
| `apple-sdk_14` | 14.4 | present |
| `apple-sdk_15` | 15.5 | present |
| **`apple-sdk_26`** | **26.5** | **present at the locked rev** |

Also present at the locked rev:

```
pkgs.darwinMinVersionHook "26.0"  ->  darwin-deployment-target-hook-26.0
pkgs.apple-sdk_26.sdkroot         ->  /nix/store/v22r0hxqdqmc76cfk2rylnbqcdj22pgy-apple-sdk-26.5/...
```

**VERDICT: NO INPUT BUMP IS NEEDED.** Everything the bump requires already exists
in the pinned nixpkgs. Corroborating evidence from the live shell — the C++
standard library already in `NIX_CFLAGS_COMPILE`/`NIX_LDFLAGS` is
`libcxx-21.1.6+apple-sdk-26.5`, i.e. nixpkgs at this rev already builds parts of
the darwin world against SDK 26.5. Only the *default* stdenv SDK is 14.4.

This is the single most important finding for the plan: the bump is a **two-line
addition to the dev shell**, not a `nix flake update`. It does not move rustc,
clang, python, the JDK, dotnet, ghc, ocaml, or go, and it therefore does not risk
the toolchain-wide churn a `flake update` would.

### THE MECHANISM — MEASURED, AND IT IS NOT THE OBVIOUS EDIT

kaya's `flake.nix` builds its dev shell with `packages = with pkgs; [ ... ]`, so
the natural edit is to add `apple-sdk_26` to that list. **I tested it. It does
not work.** Both variants were built against the locked rev in the scratchpad and
a trivial `.c` file compiled in each:

| spelling | `DEVELOPER_DIR` | `cc t.c` | resulting stamp |
|---|---|---|---|
| `packages = [ apple-sdk_26 ]` | **stays 14.4** | **fails, exit 1** | no binary |
| `buildInputs = [ apple-sdk_26 ]` | **26.5** | succeeds | **minos 14.0, sdk 26.5** |

`packages` is `mkShell`'s alias for `nativeBuildInputs`, which puts the SDK in the
*build* role rather than the *host* role. The SDK setup hook then refuses the
clash and `cc` dies with:

```
Multiple conflicting values defined for DEVELOPER_DIR_arm64_apple_darwin
Existing value is /nix/store/…-apple-sdk-26.5
Attempting to set to /nix/store/…-apple-sdk-14.4 via DEVELOPER_DIR
```

Reproduced twice, deterministic. **The good news is that the wrong spelling fails
loudly rather than silently leaving the shell on 14.4** — a broken `cc` cannot
produce a false green. But anyone who writes the obvious edit will spend the
afternoon on that message, so: **the SDK goes in `buildInputs`, not `packages`.**
kaya's shell currently declares no `buildInputs` at all, so this adds a new
attribute to `mkShell` rather than a line to the existing list.

The verified working shape:

```nix
default = pkgs.mkShell {
  # The macOS SDK kaya-built guests link against. MUST be buildInputs,
  # not packages: packages is nativeBuildInputs (build role), and the
  # SDK hook then conflicts with the stdenv's default 14.4 and breaks cc.
  # Measured: minos 14.0 + sdk 26.5, which is the modern design generation
  # (docs/traps.md — SwiftUI reads the sdk field, not minos).
  buildInputs = [ pkgs.apple-sdk_26 ];
  packages = with pkgs; [ ... ];   # unchanged
};
```

Note what this does **not** include: `darwinMinVersionHook`.
`MACOSX_DEPLOYMENT_TARGET` stays **14.0** under `buildInputs` alone, so
kaya-built guests keep running on macOS 14+ while stamping `sdk 26.5`. Since
SwiftUI reads the **sdk** field and not minos (kaya's own verified finding, §4b),
that is the whole opt-in with none of the cost. Adding the min-version hook would
raise `minos` to 26.0 and drop macOS 14/15 as run targets for no design benefit —
recommend against it (§6g).

### For the record: current nixpkgs-unstable

Not needed for this plan (locked rev already suffices), so not fetched. If the
input is ever bumped for other reasons, note what it drags: `stdenv` moves, and
with it clang, and `stdenv.hostPlatform.darwinMinVersion/darwinSdkVersion` — which
would silently move the *vendor-ish* legs (nixpkgs' prebuilt `python3`) that §4
relies on to stay compat. That is a risk to name, not to quantify here.

---

## 3. THE LEGS' MAIN EXECUTABLES (measured)

`tools/validate-mac.sh` launches each leg as shown; the **main executable** is
what `dyld` treats as the program, and it is the binary whose `LC_BUILD_VERSION`
the OS reads. Stamps read with `vtool -arch arm64 -show-build`.

| leg | launch line (validate-mac.sh) | main executable | minos | **sdk** | whose SDK controls it |
|---|---|---|---|---|---|
| **rust** | `run rust-swiftui "$RUST_GUESTS"/milestone2` | `target/rust-guests/milestone2` (staged from `target/debug/examples`) | 14.0 | **14.4** | **ours (flake stdenv)** |
| **go** | `run go-swiftui target/go-guests/kaya-go` | `target/go-guests/kaya-go` | 14.0 | **14.4** | **ours** (cgo links via the nix clang wrapper) |
| **c** | `run …-c-swiftui target/c-guests/<scene>` | `target/c-guests/milestone2` | 14.0 | **14.4** | **ours** |
| **ocaml** | `… _build/default/guests/ocaml/milestone2.exe` | that `.exe` | 14.0 | **14.4** | **ours** (ocamlopt links via nix clang) |
| **haskell** | `run haskell-swiftui "$(hs_bin milestone2)"` | `guests/haskell/dist-newstyle/.../milestone2 (gone)` | 14.0 | **14.4** | **ours** (ghc links via nix clang) |
| **swift** | `run swift-swiftui target/swift-guests/milestone2` | `target/swift-guests/milestone2` | **26.0** | **26.0** | **Apple system toolchain** — built by `kaya_swiftc`, which deliberately steers back to Xcode/CommandLineTools |
| **python** | `run python-swiftui python3 guests/python/milestone2.py` | `/nix/store/…-python3-3.14.6-env/bin/python3.14` | 14.0 | **14.4** | nixpkgs prebuilt (moves only with the nixpkgs input, *not* with our SDK choice) |
| **csharp** | `… dotnet exec "$CS_GUEST"` | `/nix/store/…-dotnet-sdk-10.0.301/share/dotnet/dotnet` | 12.0 | **14.4** | **vendor** (Microsoft-built host, nix only repackages) |
| **java** | `… java -XstartOnFirstThread -cp target/java-guests …` | `/nix/store/…-zulu-ca-jdk-17.0.19/…/Contents/Home/bin/java` | 11.0 | **11.3** | **vendor** (Azul-built) |

Supporting artifacts (not main executables — see the note below):

| artifact | minos | sdk | built by |
|---|---|---|---|
| `target/debug/libkaya.dylib` | 14.0 | 14.4 | cargo / nix clang (ours) |
| `target/swiftui/libkaya_swiftui.dylib` | 26.0 | **26.0** | `kaya_swiftc` → Apple SDK |
| `target/swiftui/kaya-swiftui-mac` | 26.0 | 14.4 | **STALE** — dated 2026-07-14, mixed stamp; see risks |
| `/usr/bin/python3` (system, not used) | 26.5 | 26.5 | Apple |
| `go` toolchain binary (not a guest) | 13.0 | 26.2 | vendor Go distribution |

### THE ARCHITECTURAL POINT

kaya's macOS UI is drawn entirely by `libkaya_swiftui.dylib`, which is **already
SDK 26.0** — it is compiled by `kaya_swiftc`, and `tools/lib/swift-toolchain.sh`
exists specifically to route Swift builds away from the nix SDK and back to
Apple's. But the design generation is **not** chosen by the dylib. AppKit decides
it from the **main program's** `LC_BUILD_VERSION` (the `dyld_program_sdk_at_least`
family reads the main executable, not the loaded image). So today:

- the **swift** leg's host process is stamped SDK 26.0 → **modern generation**
- every other leg's host process is stamped SDK 14.4 / 11.3 → **compatibility generation**

**The mac lane is ALREADY running both design generations, and has been.**
`tools/validate-mac.py:699-704` says so in `build_swift`'s docstring — "the fleet's
modern-stamp legs" — and `docs/deferred.md:967-969` says so explicitly ("the
swift mac guests compile against the system toolchain and exercise the modern
generation — both covered on purpose"). But no gate asserts it.

### DOC DRIFT TO FIX IN THE SAME SLICE

`docs/traps.md:619-621` still claims the opposite:

> "The dev shell is uniformly old-stamped, so validate-mac exercises the compat
> generation; **the modern generation has no dedicated leg yet (ledgered)**."

That is contradicted by `docs/deferred.md:967-969` and by today's measurement
(swift guests stamp `sdk 26.0`). The traps entry is stale — presumably written
before the Swift guests moved onto `kaya_swiftc`/the Apple SDK. Anyone planning
the bump from traps.md alone would conclude there is no modern leg and would
build one that already exists. Correct that clause as part of the slice.

Corollary worth stating plainly: **bumping the flake SDK does not change what
kaya's macOS UI code is compiled against.** The SwiftUI interpreter is already on
26. The bump changes only which *host processes* opt in — i.e. it flips rust, go,
c, ocaml and haskell from compatibility to modern. That is a smaller and much
better-understood change than "bump the SDK" sounds like.

---

## 4. THE COMPAT LEG AFTER THE BUMP

Constraint (docs/deferred.md): after any bump, at least one mac-lane leg must
still exercise the compatibility design generation.

**It holds for free — but only by accident, and nothing measures it.**

After adding `apple-sdk_26` to the dev shell, the split becomes:

| generation | legs | why |
|---|---|---|
| **modern** (sdk ≥ 26) | swift (already), **rust, go, c, ocaml, haskell** (newly) | linked by our toolchain against the flake SDK |
| **compatibility** (sdk < 26) | **python (14.4), csharp (14.4), java (11.3)** | main executable is a prebuilt host our flake SDK does not touch |

Three compat legs survive, so the constraint is satisfied on day one without
pinning anything.

**Today's measurement reproduces the 2026-07-21 leg audit exactly.** The ledger
records "python3/go/dotnet/ocaml/rust 14.4, zulu JDK 11.3"; this scout measured
python3 14.4, go 14.4, dotnet 14.4, ocaml 14.4, rust 14.4, zulu 11.3. The audit
is confirmed, not stale, and it now also covers c (14.4) and haskell (14.4),
which it did not name. (The 13.3 / 14.2 / 15.5 figures in that entry are its
*vendor survey* of other distributions — zulu jre 21/25, Temurin 21, the .NET
apphost stub — not the hosts this lane actually launches. Don't conflate the two
lists: the lane's java leg is nix's `zulu-ca-jdk-17.0.19`, and no Temurin is
involved.)

The ledger's own framing is worth carrying into the plan: *"The compat generation
is where the Button measurement bug class lives and is a permanent first-class
citizen; the native-kit button bridges are load-bearing indefinitely, not
transitional."* So the compat legs are not a formality to be satisfied — they are
where a known bug class is observed, and losing them silently would cost real
coverage.

### Why "for free" is not good enough

Every one of the three compat legs is compat **by accident of someone else's
build**, and each can move without a kaya commit:

- **python** is nixpkgs' prebuilt `python3.14.6`, stamped with the *stdenv
  default* SDK. The next `nix flake update` that moves nixpkgs' default SDK to 26
  flips this leg to modern silently — no diff in `flake.nix`, no gate red.
- **csharp** and **java** flip whenever Microsoft or Azul rebuild their host
  against a newer SDK and nixpkgs picks up the new release.

So the constraint would be satisfied by three legs that nobody chose, that no
file names, and whose flip nobody would notice. That is precisely the shape
CLAUDE.md invariant 3 rejects: a guard you have to remember to check.

### Proposed post-bump coverage (recommendation)

1. **Do not pin a kaya-built leg to an old SDK.** It would mean maintaining a
   second SDK in the flake and a per-leg link override, and the leg would then be
   unrepresentative of anything kaya ships. The vendor-host legs are *better*
   compat coverage than a synthetic pin, because they are the real situation an
   embedder is in (a JVM or .NET host loading kaya).
2. **Declare the split in `flake.nix`**, next to the new `apple-sdk_26` line — a
   comment naming which legs are modern, which are compat, and that the compat
   side is vendor-host-derived and therefore *observed*, not *chosen*.
3. **Put the constraint on a path nobody can avoid**: a new gate,
   `tools/check-design-generation.sh`, that stamps each mac leg's main executable
   with `vtool -show-build` and compares against a declared table — failing if
   the modern set is empty, if the compat set is empty, or if any leg has moved
   sides without the table moving. It must clear `DEVELOPER_DIR`/`SDKROOT` (the
   trap in §1) and must refuse a verdict if it read fewer legs than declared
   (the census rule `tools/check-gates.sh` and `tools/tpl-surfaces.py` already
   set the precedent for). Register it in `tools/gates.sh` and
   `tools/check-gates.sh`'s census, and in CLAUDE.md/AGENTS.md's prose list —
   `tools/check-mirror.sh` and `check-gates.sh` will otherwise fail, which is the
   system working.
   Its negative test: perturb a copy of a guest binary's stamp with
   `vtool -set-build-version macos 26.0 26.0 -replace -output <copy>` and watch
   the gate go red — a stamp gate that has never been seen failing is worth
   nothing (and per the memory note, perturb-restore from a **copy**, never git).

---

## 4b. THE MECHANISM IS ALREADY VERIFIED IN-TREE

`docs/traps.md:612-614` and `DESIGN.md:2691-2695` record a prior kaya
investigation that answers the central mechanical question outright:

> "SwiftUI resolves its design generation from the MAIN EXECUTABLE's SDK stamp
> (**the sdk field, NOT minos** — verified: minos 14 + sdk 26.5 takes the modern
> path)"

This is exactly the configuration §2 recommends (`apple-sdk_26` **without**
`darwinMinVersionHook`), and kaya has already proven by experiment that it
produces the modern generation. The plan therefore does not rest on my reading of
Apple's docs — it rests on an in-tree measurement that agrees with them.

Apple's side agrees. `UIDesignRequiresCompatibility` (Info.plist,
introduced 26.0, **macOS included**): compatibility mode "displays the app as it
looks when built against previous versions of the SDKs"; the default is off "for
apps linking against the latest SDKs"; and the system **ignores the key** for
macOS 27+. Apple's adoption guide: "If you use standard controls from system
frameworks and don't hard-code their layout metrics, your app adopts changes to
shapes and sizes automatically when you rebuild your app with the latest version
of Xcode," and "lists, tables, and forms have a larger row height and padding."

Two consequences for kaya specifically:

- kaya's mac guests are **bare executables with no bundle and no Info.plist**, so
  `UIDesignRequiresCompatibility` is not available as an escape hatch. The SDK
  stamp is the only knob, in both directions. (It is also a dead end long-term —
  Apple removes it for macOS 27.)
- "larger row height and padding" for lists/tables is the one documented change
  that touches geometry kaya asserts. See §6.

---

## 5. THE GLASS PROOF (propose only — not run)

One measurement, on this macOS 26.5.2 host, using the depth-slice guest that
exists to show styling:

1. **Baseline first, before touching the flake.** The `typeface` guest is the
   in-flight styling depth slice and is rust-only today
   (`tools/lib/lanes/mac.py:35`, typeface in DEPTH_SCENES), so it is the natural
   subject; `styling` is the graduated sibling that exists in all eight
   languages. Copy the current `target/rust-guests/typeface` aside (a copy, not
   git) and record its stamp — measured today: `minos 14.0 sdk 14.4`.
2. Edit `flake.nix` to add `buildInputs = [ pkgs.apple-sdk_26 ];` (§2 — **not**
   `packages`, and *not* the min-version hook, so `minos` stays 14.0 and only the
   SDK field moves, making the experiment single-variable). Exit the shell,
   re-enter (`KAYA_DEV_SHELL` forces this), rebuild.
3. **Read the stamp.** `env -u DEVELOPER_DIR -u SDKROOT vtool -arch arm64
   -show-build target/rust-guests/typeface` must report `sdk 26.5` with
   `minos 14.0`. If the SDK field did not move, nothing downstream is worth
   looking at — stop here. This is the whole of the "did the bump work"
   question; everything after it is "did it do what we wanted".
4. **Run both, side by side, same scene, same script.** The old copy and the new
   build, `KAYA_SELFTEST=typeface` with the same `KAYA_SELFTEST_SCRIPT`, against
   the same `libkaya_swiftui.dylib`. Screenshot each. The two processes differ in
   exactly one bit — the main executable's SDK field — so any visual difference
   is the design generation and nothing else.
5. **Third data point, free:** the **swift** leg is already modern. Screenshot
   `target/swift-guests/styling` today, before any flake edit. If the post-bump
   rust build looks like today's swift leg and unlike today's rust leg, the
   causal story is closed from both directions. This is the strongest part of the
   proof and it costs one screenshot.

**What difference to expect.** Apple's compatibility behavior for the macOS 26
generation is: an app linked against an older SDK keeps the previous appearance;
linking against the macOS 26 SDK opts the process into the new design, and an app
that has linked against 26 but is not ready can set the
`UIDesignRequiresCompatibility` Info.plist key to stay on the old look. Expect
the change to show up in **system-drawn chrome** — window/title-bar treatment,
control shape and inset, sidebar and toolbar material, focus rings, default
corner radii, and the translucency of standard controls — rather than in kaya's
own brand colors or the typeface record, which the guest sets explicitly.
**Note this leg has no bundle and no Info.plist**, so the
`UIDesignRequiresCompatibility` escape hatch is not available to a bare
executable — for kaya's guests the SDK stamp is the only knob. That is worth
verifying as part of the proof rather than assuming.

(Apple's exact per-control list should be confirmed against the current macOS 26
release notes / HIG before anyone writes an expected-pixels assertion; this
report deliberately stops at "system chrome changes, brand tokens do not".)

---

## 6. RISKS

### 6a. THE BIGGEST ONE — `editor`'s `expect_inset row#0 8`, Go-only, never run modern

I swept every `tools/scenes/*.steps` for geometry assertions and cross-referenced
against which of them have a Swift guest (i.e. which are already proven under the
modern generation today):

| scene | geometry assertion | swift guest? | already proven modern? |
|---|---|---|---|
| `window` | `expect_window_size 640x400` | YES | **yes** |
| `panels` | `expect_window_size window#1 480x320` | YES | **yes** |
| `styling` | `expect_inset 0` | YES | **yes** |
| `feed` | `expect_order column#0 …` | YES | yes |
| `reorder` | `expect_order column#0 …` | YES | yes |
| **`editor`** | **`expect_inset row#0 8`** + `expect_order` | **NO — Go only** | **NO** |

`editor` is kaya's forcing artifact and runs on the mac lane as a **single Go
leg** (`tools/lib/lanes/mac.py:131`, the editor group's one go entry);
its HAND_QUEUED comment notes it is deliberately in neither `SCENES` nor
`DEPTH_SCENES`. Go is a kaya-built leg, so the bump moves it 14.4 → 26.5, and
`expect_inset row#0 8` — the tree's only **non-zero** geometry assertion — runs
under the modern generation **for the first time anywhere**.

Apple's documented change "lists, tables, and forms have a larger row height and
padding" points straight at it. The measurement is a differential
(`(outer - inner) / 2` around kaya's own `.padding(node.inset)`, per
`KayaSwiftUI.swift:7397-7404`), so in principle the system's row metrics cancel
and the 8 survives — but "in principle" is doing all the work, and this is the
one assertion with no modern-generation precedent.

**Mitigation, cheap and first:** before editing `flake.nix` at all, build just the
Go guest against `apple-sdk_26` in a throwaway shell and run the `editor` leg.
It is one leg and it answers the only open question in the whole plan. If
`expect_inset row#0 8` holds there, nothing else in the geometry table can
plausibly move, because everything else is already green under a modern leg.

### 6b. The Button measurement bridge loses its regression coverage if compat ever vanishes

`docs/traps.md:612-626` and `DESIGN.md:2680-2718` document a real
generation-dependent defect: in the **compat** generation SwiftUI's `Button`
answers `sizeThatFits(.unspecified)` with borderless metrics (38×20) while drawing
the bezeled control (52×32), so captions ellipsize ("tick" → "t…"). kaya's fix is
to bridge macOS buttons to `NSButton` via `NSViewRepresentable` + `fittingSize`,
"which cannot self-disagree under any stamp, **in either design generation**".

Two readings, both worth stating:

- **Reassuring:** the fix is generation-independent by construction, so moving
  five legs to modern does not disturb it. The bridge was designed for exactly
  this.
- **The reason the standing constraint exists:** the ledger calls the compat
  generation "where the Button measurement bug class lives … a permanent
  first-class citizen; the native-kit button bridges are load-bearing
  indefinitely, not transitional." The compat legs are the regression coverage
  that keeps the bridge honest. They survive the bump (§4) — but only by accident
  of vendor builds, which is precisely why §4 proposes a gate rather than trusting
  it.

### 6c. Chrome geometry — smaller than it looks

The 28pt-of-chrome measurement does not reach any assertion. `expect_window_size`
reads `window.contentRect(forFrameRect: window.frame)`
(`KayaSwiftUI.swift:5758-5761`) — the **content** rect, with the title bar
subtracted by construction — and it is already green on the modern swift leg at
both `640x400` and `480x320`. Title-bar height can move freely without touching it.

### 6d. No pixel comparison exists anywhere — this risk is nil

I checked specifically. **`git ls-files "*.png"` returns 0 tracked files.** There
are no golden images, no reference screenshots, no pixel-diff assertions. Every
PNG in the tree is an untracked output under `target-linux/recordings/`. The only
pixel-reading code is `tools/harness-extract.sh:81-89`'s `dominant()` selftest,
and it runs against **synthetic ffmpeg solid-color video**
(`color=red/lime/blue`), never real UI — immune by construction.

So "the modern look breaks a pixel test" cannot happen. The only screenshot
concern is the one the maintainer already acknowledged in the ledger: published
stills will show the modern look.

### 6e. The stale `kaya-swiftui-mac` artifact

`target/swiftui/kaya-swiftui-mac` is dated **2026-07-14**, is 46 MB, and carries
an incoherent stamp (`minos 26.0` / `sdk 14.4`) matching no current build path,
sitting beside the live `libkaya_swiftui.dylib`. Almost certainly dead (pre-dylib
interpreter), but confirm it is unreferenced *before* the bump so it cannot be
mistaken for a bump casualty afterwards.

### 6f. Two SDKs in one process, in a new combination

Post-bump a rust guest is `sdk 26.5` (nix SDK) loading a dylib built against
Apple's `sdk 26.0` (Xcode SDK). Today's pairing is 14.4-loads-26.0 and works, so
the new pairing is closer, not further — low risk. But it is the first time nix's
and Apple's SDKs will be the same major while still being different SDKs (26.5 vs
26.0). Watch for framework-symbol availability mismatches at link time.

### 6g. What a min-version bump would additionally cost

If `darwinMinVersionHook "26.0"` is added alongside, `minos` moves 14.0 → 26.0 and
kaya-built guests stop launching on macOS 14/15. Nothing here requires it — kaya's
own verified result is that **minos 14 + sdk 26.5 already takes the modern path**.
Recommend **not** doing it: one variable at a time, and the SDK field alone buys
the design generation.

### 6h. Fingerprint churn

Editing `flake.nix` invalidates `KAYA_DEV_SHELL` for every open shell. Expect
`tools/` scripts to refuse until every terminal and direnv session is re-entered.
Not a bug; budget for the confusion.

---

## SUGGESTED SLICE ORDER

1. Pre-flight `editor`'s Go leg against `apple-sdk_26` in a throwaway shell (§6a).
   This is the only real unknown.
2. Screenshot today's `target/swift-guests/styling` (modern) and
   `target/rust-guests/styling` (compat) as the before/after reference pair (§5.5).
3. Add `buildInputs = [ pkgs.apple-sdk_26 ];` to `flake.nix` — **`buildInputs`,
   not `packages`** (§2), and **without** `darwinMinVersionHook` — with a comment
   stating the generation split, why the spelling matters, and that the compat
   side is vendor-derived.
4. Re-enter the shell; rebuild; verify stamps moved (§5.3).
5. Add `tools/check-design-generation.sh` + register it in `gates.sh`,
   `check-gates.sh`'s census, and the CLAUDE.md/AGENTS.md prose list (§4).
   Watch its negative test fail.
6. Fix the stale `docs/traps.md:619-621` clause (§3).
7. Full matrix.
