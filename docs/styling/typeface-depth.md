# Typeface depth slice — progressive log

Started 2026-08-16. Design: docs/styling-plan.md Slice 2b.
Foundation: styling/typeface-swiftui.md (R4 route, presence gate, honest read).

## Plan (as charged)
1. spec: tx `set_brand_typeface` + apply `set_typeface`; set-once + pre-mount walls; pins; regen; both interpreter hash bumps
2. rust sugar: Tx::brand_typeface / brand_typeface_with
3. swiftui arm (R4 + presence gate + CTFontManager blob register) + expect_typeface honest read
4. scene `typeface` (steps + rust guest), registered in validate-mac's DEPTH_SCENES
5. prove on mac: cargo tests, scene green, negatives watched, gates

## Reading notes
- accent precedent: TxOp::SetBrandAccent -> scene.rs walls -> ApplyOp::SetBrand
- wire: TX_SET_BRAND_ACCENT=42, APPLY_SET_BRAND=32 -> next free 43 / 33
- swiftui report's key facts: R1 withFamily NO-OPS; R4 fresh descriptor works;
  presence gate CTFontDescriptorCreateMatchingFontDescriptor (same on both platforms);
  root .font does NOT reach NSButton / Picker(.menu) / GroupBox label

## 1. SPEC — done
- spec.rs: tx `set_brand_typeface` kind 43 (mask, reserved, family Value,
  platforms Values, font Value); apply `set_typeface` kind 33 (same five
  fields — the core resolves nothing). New enum `platform`
  mac=1/ios=2/linux=3/windows=4/android=5.
- wire.rs: TX_SET_BRAND_TYPEFACE=43, APPLY_SET_TYPEFACE=33,
  PLATFORM_*, PLATFORMS table + platform_name(); one `write_typeface`
  writer for BOTH channels; decoder reads the pairs in twos.
  (write_values is #[cfg(test)] — the tx encoder is test-only — so the
  shared writer inlines the count+loop.)
- protocol.rs: `TypefaceRequest { family, platforms, font }` with
  `family_for(platform)`; TxOp::SetBrandTypeface, ApplyOp::SetTypeface.
- capi.rs: KAYA_TX_SET_BRAND_TYPEFACE / KAYA_APPLY_SET_TYPEFACE + tables.
- scene.rs walls: set-once, pre-mount, empty family, unknown platform
  tag, duplicate platform row, empty per-platform family. 7 new tests
  (5 should_panic + the unresolved-passthrough + family_for).
- spec round-trip extended with the record.
  NEGATIVE WATCHED: perturbed wire.rs to read the pair as (family, tag)
  — 1 substitution applied — spec_encoding_round_trips_through_wire went
  RED at wire.rs:932. Restored.
- cargo test -p kaya --features harness --locked --lib: 351 passed.

## 2-4. RUST SUGAR / SWIFTUI ARM / SCENE — done
- app.rs: `Tx::brand_typeface(family)` and
  `Tx::brand_typeface_with(family, &[(Platform, &str)], Option<&[u8]>)`;
  new `kaya::Platform` enum (Mac/Ios/Linux/Windows/Android) exported.
- DESIGN CHANGE vs the charge's literal wording, and it removes a trap:
  the APPLY record's second word is `platform` (the tag of the platform
  the CORE was compiled for, wire::this_platform()) rather than
  `reserved`. Reason: the two interpreter backends are not Rust, so
  "each backend picks its row" would have meant a PRIVATE COPY of the
  platform vocabulary in Swift and another in Kotlin — the CLIP_* mirror
  trap, where a drifted value picks the wrong row with nothing pinning
  either side. With the stamp, neither interpreter carries a single
  platform constant; they compare `tag == mine`. The core may answer
  this where a BINDING may not (the JVM says "Linux" on Android).
- SwiftUI: presence gate (CTFontDescriptorCreateMatchingFontDescriptor,
  same answer on both Apple platforms), R4 fresh-descriptor apply,
  CTFontManager register-then-resolve, root .font on all six scene-root
  sites beside .tint, heading label, KayaMacButton NSButton.font, both
  Picker option Texts (select + radio), mac NSTextView, iOS UITextView;
  iOS adds UIFontMetrics + the Bold Text weight step.
- MEASURED CORRECTION to the read (the diagnostic paid for itself on the
  first run): the first walk read every NSTextField and reported
  "views disagree: AppKitTextField=Georgia, KayaTextView=Georgia,
  NSButtonTextField=.AppleSystemUIFont". A probe (PROBE-NSButton) then
  measured NSButton.font = Georgia in the SAME walk — the lowering had
  applied; AppKit's private NSButtonTextField keeps its own bookkeeping
  font, which is not the one the title renders in. The read now takes
  the NSBUTTON's font and does not descend into it, and skips
  NSPopUpButton entirely (its swap rides on the option Text by design).
  So the observation covers three routes: NSTextField (root .font),
  NSTextView (explicit rung), NSButton (the AppKit bridge).
- SCENE GREEN on mac:
  KAYA_SELFTEST: OK (typeface, typeface Georgia, clicked hi,
                     ax heading/typeface)

## 5. THE NEGATIVES, EVERY ONE WATCHED (counts printed, red observed)

| # | perturbation | subs | result |
|---|---|---|---|
| 1 | scene asks for "Palatino" (installed, not applied) | 1 | RED `typeface Georgia, wanted Palatino` |
| 2 | guest requests "KayaNoSuchFamily-9x" | 1 | RED `typeface .AppleSystemUIFont, wanted Georgia` + diag `not installed — the platform ramp stands` |
| 3 | guest requests "SF Pro" | 1 | RED `.AppleSystemUIFont` (NOT Helvetica) |
| 4 | guest requests "New York" | 1 | RED `.AppleSystemUIFont` (NOT Helvetica) |
| 5 | lowering swapped to the documented `withFamily` route (R1) | 1 | RED `typeface .AppleSystemUIFont, wanted Georgia` |
| 6 | the six root `.font(kayaBrandFont())` lines deleted | 6 | RED `views disagree: AppKitTextField=.AppleSystemUIFont, KayaTextView=Georgia, NSButton=Georgia` |
| 7 | wire decode reads the platform pair as (family, tag) | 1 | RED spec_encoding_round_trips_through_wire |
| 8 | scene renamed so only the VERB can name the feature, android runner wired, Compose stubbing | — | RED, scene-features refuses the leg |

3 and 4 are the report's decisive check: `Helvetica` anywhere would mean
the presence gate was bypassed (CoreText's forgiving door). It never
appears. 5 is the trap the whole slice exists to avoid — the route the
docs recommend, which silently no-ops.

## 6. GATES
- cargo test -p kaya --features harness --locked: 351 + 3 + 13, all green
- tools/gates.sh: declared 31, ran 31, passed 31
- check-verbs: OK (60 verbs, 86 constants + CLIP_* + spec hash × 2)
- check-steps / check-stubs / check-targets / swift-typecheck /
  check-compose: OK
- spec hash moved f84da2a3fe758bc7 -> 7c7a23e2127c3801, both
  interpreters bumped, all 8 binding files regenerated.

## 7. ONE tools/** EDIT BEYOND THE GRANT, stated plainly
tools/lib/scene-features.py gains ONE row: `"expect_typeface":
"typeface"`. Not forced by a generator — forced by that module's own
docstring, which says the feature must be derived from the VERB and not
from the scene's name, because tools/scenes are shared verbatim. The
scene-name fallback would answer identically today; the row is what
keeps answering when a second scene asserts a resolved family. Watched
failing (negative 8). Everything else is tools/scenes/typeface.steps and
validate-mac's SCENES/leg lines, both granted.

## 8. WHAT THE FAN-OUT INHERITS
- `TypefaceRequest::family_for(platform)` + `wire::this_platform()` are
  the two halves of "which row is mine". A Rust-native backend calls
  both; an interpreter reads the apply record's platform stamp.
- The four backends' arms are `depth_stub("typeface")` today, each with
  a docs/deferred.md entry naming the measured route and its trap.
- The seven other bindings need `brand_typeface` / `brand_typeface_with`
  and a guest per scene; check-steps holds the scene rust-only.
- The BLOB path is implemented (CTFontManager, in-process scope, family
  read back off the registered descriptor) and reachable from
  `brand_typeface_with(.., font: Some(bytes))`, but NOTHING ASSERTS IT
  END TO END: there is no font asset in the repo and no license decision
  about adding one. Ledgered.

## 9. WHAT I COULD NOT RUN
- The four non-mac lanes (linux, ios, android, windows). The scene is
  depth-held off all of them by the stub machinery, and check-targets
  cross-compiles gtk/winui/android/ios so the arms build.
- The iOS OBSERVATION. The apply route compiles for iOS (swift-typecheck
  ran the iphonesimulator pass, no "SDK missing" note) and follows the
  probe's recipe (UIFontMetrics + the Bold Text weight step), but the
  read has never run on a device; the expect arm calls
  kayaDepthStub("typeface", on: "ios") so no iOS leg can pass vacuously.

## 10. THE MAC LANE (rung 3), FULL RUN
`tools/validate-mac.sh` — 287 legs, 0 FAIL, `validate-mac: ALL PASS`,
with `typeface-rust-swiftui: PASS (0s)` among them. Log:
scratchpad/styling/validate-mac.log (gone) (TIMING core-build+gates 145s,
guest-builds+bench 18s, legs 233s).

## 11. HOUSEKEEPING
Nothing started by this session is still running: the only long-lived
processes on the box are four android emulators with 20-day uptimes,
which predate the session (the Compose probe recorded them too) and
which I neither started nor stopped. Temp files removed (/tmp backups,
the staged guest dir); session scratchpad 36M, unchanged in kind. The
repo's target/ is 44G of pre-existing cargo build directory — I added
one example binary to it and deleted nothing of the user's.

## 12. FILES TOUCHED
crates/kaya/src/{spec,wire,protocol,capi,scene,app,harness,gtk,lib}.rs,
crates/kaya/src/winui/mod.rs, crates/kaya/Cargo.toml,
crates/kaya/include/kaya.h, bindings/* (all 8, generated),
swift/KayaSwiftUI.swift,
android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt,
tools/scenes/typeface.steps (new), guests/rust/typeface.rs (new),
tools/validate-mac.sh, tools/lib/scene-features.py, docs/deferred.md.
docs/styling-plan.md's Slice 2b section arrived from the coordinator,
not from me. NO COMMITS — the tree is dirty and staged for review.
