# The typeface arm on Compose — progressive log

Started 2026-08-16. Design: docs/styling-plan.md Slice 2b.
Depth: styling/typeface-depth.md (SwiftUI on mac).
Mechanics: styling/typeface-compose.md (measured probe — the iron rule:
everything below comes from it, not from memory).

**VERDICT: the arm is DONE and proven on the lane** — both writes, the
per-platform row, the font-bytes route, the apply-time miss detector, and
`expect_typeface` on the honest read (the shaped glyph run's font file,
named out of its OpenType `name` table). 9 probe legs green, 10 watched
negatives (counts printed, sha256 restores verified), the whole compose
suite 32/32. **The SCENE is not wired on this lane and cannot be by this
arm**: `expect_typeface "Georgia"` is byte-frozen and Georgia is not on
the image — one cross-lane decision, §6, the same one the GTK arm hit.

## What the probe binds me to

1. TWO writes, not one. `MaterialTheme(typography = ramp.withFamily(f))`
   brands Material's own components; kaya's labels and text fields read
   `LocalTextStyle`, which `KayaTheme` deliberately holds at its
   PRE-theme value. One write alone leaves every kaya label on Roboto
   (measured: `typography` only -> plain label still 109px Roboto).
2. The honest read is the SHAPED GLYPH RUN's font file + its OpenType
   `name` table. `Typeface.getSystemFontFamilyName()` ECHOES the request
   (`georgia` -> "georgia" while Noto Serif shaped) and returns null for
   a bytes-loaded face; `layoutInput.style.fontFamily` is the request
   itself.
3. Fallback is Roboto, silently, and `Roboto` is itself a MISS by name.
   `preload` returns ok for a family that does not exist. The apply-time
   sentinel is the detector that works.
4. The negative leg is VACUOUS on its own: a nonsense family reports
   Roboto, and so does an unbranded app. The leg that must be watched
   going red is the POSITIVE one.

## Plan

1. Model + apply arm (blob via the file route; android row via the
   core's platform stamp; miss detector at apply time).
2. KayaTheme: both writes, family only.
3. `expect_typeface`: the honest read, per-site, disagreement reported.
4. Compile gates, then the lane.

(Sections below are appended as the work lands.)

## 1. THE ARM — android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt

- **decode** (APPLY_SET_TYPEFACE): mask, the core's platform STAMP, the
  default family, the pairs, the font slot. First matching row wins; the
  file keeps no copy of the platform vocabulary (the CLIP_* mirror trap).
- **collectBlobs** gains a SET_TYPEFACE arm — the font blob dies with its
  batch exactly as an image's does, and without the pre-fetch the handle
  resolves to null on the UI thread and the app falls back to the NAME,
  silently. Walked absolutely off the record's own shape.
- **kayaApplyTypeface** — precedence is the Apple arm's to the word:
  bytes, then this platform's row, then the default family. Bytes are
  staged to an app-private file and validated with
  `Typeface.Builder(file).build() != null` BEFORE Compose sees them,
  because Compose's own `Font(File)` throws inside composition for a bad
  blob (probe §6.3) — so bad bytes fall through to the name instead of
  taking the app down, which is what a failed CTFontManager registration
  does on Apple.
- **the presence gate**, Apple's semantics on Android's mechanics: a
  family this device does not have leaves the platform ramp standing and
  SAYS so. Detected with the probe's sentinel trick, in a two-sentinel
  form that needs no per-device table: resolve `[name, cursive]` and
  `[name, monospace]`; equal faces mean the name loaded, different faces
  mean each chain fell through to its own sentinel. It refuses a verdict
  (and says which) below API 31, or if the two sentinels are one face.
- **KayaTheme applies TWICE** — `typography = base.kayaWithFamily(f)` and
  `LocalTextStyle provides ambient.copy(fontFamily = f)`. Family only;
  the ambient size stays Unspecified, so KayaTheme's whole reason for
  holding that local survives the slice.
- **the honest read** (`kayaResolvedTypeface`): one real
  `TextLayoutResult` per ROUTE — heading and button take the ramp, label
  and the two editables take the ambient style — resolved through THE
  LAYOUT'S OWN `fontFamilyResolver`, shaped with `TextRunShaper`, and
  named out of the shaped font FILE's OpenType `name` table. The sites
  must agree or the read reports the disagreement by site.
- `depthStub` leaves the file with its last caller, the seventh time.

## 2. THE LANE — the probe matrix (emulator-5554, API 35)

One APK, one temporary guest driven by KAYA_TF_* extras
(`guests/rust/typefaceprobe.rs (gone)` + a dispatch arm, both deleted at
the end). Every leg's per-site identities are logged as `KAYA_TYPEFACE:`.

| leg | request | expect_typeface | apply-time diagnosis |
| --- | --- | --- | --- |
| positive | `serif` | **Noto Serif** on all 5 sites, `/system/fonts/NotoSerif-Regular.ttf` | (silent — it is present) |
| positive 2 | `monospace` | **Droid Sans Mono**, DroidSansMono.ttf | silent |
| control | no brand at all | Roboto, Roboto-Regular.ttf | silent |
| fallback | `KayaNoSuchFamily-9x` | Roboto | `typeface KayaNoSuchFamily-9x is not installed — the platform ramp stands` |
| deceptive | `Roboto` | Roboto | **not installed** — right pixels, wrong reason, now loud |
| the shared scene's family | `Georgia` | Roboto | **not installed** |
| per-platform ROW | `Georgia` + android row `serif` | **Noto Serif** | silent |
| FONT BYTES | `Georgia` + NotoSerif's bytes | **Noto Serif** from `/data/user/0/…/files/kaya-brand-font` | silent |
| bad BYTES | corrupt blob + `monospace` | Droid Sans Mono | `the brand typeface's 4096 bytes are not a font this platform can load — falling back to the family name` |

The widgets keep working under the swap (`set_text`/`click` → `clicked
hi`), which is the scene's other claim.

Two readings worth keeping:
- The control and the nonsense legs are INDISTINGUISHABLE in the read
  (Roboto, same file, same axes) — the probe measured that and it holds
  exactly. The only thing that tells them apart is the apply-time
  diagnosis, which is why the detector is in the lowering rather than in
  a scene.
- The bytes leg's family name is one a NAME request cannot reach on this
  image, and its shaped FILE is the app-private blob — so that leg proves
  the blob channel and nothing else could have produced it.

## 3. THE NEGATIVES, EVERY ONE WATCHED

Each is a perturbation of KayaCompose.kt with the substitution count
PRINTED (a count of 0 aborts the run rather than passing), a rebuild
whose artifacts are `--verify`'d, the leg re-run, then a restore checked
with `shasum -a 256 -c`. Every restore printed OK.

| # | perturbation | subs | result |
|---|---|---|---|
| 1 | the AMBIENT write deleted (`typography` only) | 1 | RED `sites disagree: button=Noto Serif, entry=Roboto, heading=Noto Serif, label=Roboto, textarea=Roboto` |
| 2 | the TYPOGRAPHY write deleted (ambient only) | 1 | RED `sites disagree: button=Roboto, entry=Noto Serif, heading=Roboto, label=Noto Serif, textarea=Noto Serif` |
| 3 | the read ECHOES the request | 1 | **GREEN — the false green.** `OK (typeface KayaNoSuchFamily-9x)` for a family that does not exist. The same leg on the honest read: `FAILED (typeface Roboto, wanted KayaNoSuchFamily-9x)` |
| 4 | the presence detector always says PRESENT | 1 | the `is not installed` line VANISHES, everything else identical — so that sentence is caused by the measurement, not printed unconditionally |
| 5 | the two sentinels become one face | 1 | `applied unverified — the fallback probe's two sentinels (cursive, cursive) resolve to ONE face on this device` |
| 6 | the shaped-run read refused as if below API 31 | 1 | `applied unverified — this device (API 35) has no shaped-run read`, and the READ refuses too: `FAILED (typeface the shaped font cannot be read on API 35 …)` |
| 7 | the record applied with no activity | 1 | `typeface serif arrived before the activity was mounted — the platform ramp stands`, RED `typeface Roboto, wanted Noto Serif` |
| 8 | no site records a layout | 3 | RED `typeface no laid-out text on screen, wanted Noto Serif` |
| 9 | the font blob is not pre-fetched in collectBlobs | 1 | RED `typeface Roboto, wanted Noto Serif` + `Georgia is not installed` — the handle dies with the batch and the request silently becomes the NAME |
| — | check-compose against a syntax error | 1 | RED `check-compose: FAIL (KayaCompose.kt does not compile)` — the gate was watched failing before being trusted |

1 and 2 are the probe's central finding proven in BOTH directions: each
write brands exactly the sites the other cannot reach, and the read is
what refuses to call either half the whole.

**#5 CAUGHT A DEFECT IN MY OWN DIAGNOSTIC, which is why the branch was
forced to print.** The first version had ONE "cannot tell" answer, and
its sentence blamed the API level — so with the sentinels collided on an
API 35 device it printed *"this device (API 35) cannot be asked which
font a run used"*, which is false, and is the `kayaOpenPanelWhyNot` shape
exactly (docs/traps.md): a sentence a reader would chase in the wrong
direction. The detector now returns four answers, not three, and each
not-knowing branch prints only what it measured. Both were then watched
printing (#5, #6).

## 4. EXISTING SCENES GREEN

`tools/android/run-emulator.py compose` on the FINAL tree: **32 legs,
32 PASS, 0 FAILED, rc=0** — including `styling-compose`, which exercises
the same KayaTheme the two new writes live in (brand accent, roles,
inset), and `ranges`/`textarea`/`entry`, which read the ambient text
style this arm now copies a family into. Log:
styling/compose-suite-final.log (an identical earlier run, before the
log-volume change, is compose-suite.log).

## 5. GATES

`tools/gates.py`: **declared 31, ran 31, passed 28.** The three reds,
attributed:

- **check-steps** — `scene "typeface" has no live legs` in
  tools/linux/run-suites.sh, tools/deploy-win.py AND
  tools/android/run-emulator.py. This is the fan-out's designed red (the
  gate stops demanding legs only while a backend still declares a depth
  stub, and three backends have now dropped theirs). The android line is
  MINE and cannot be cleared from here: wiring the leg is a tools/**
  edit, and the leg would fail anyway until the scene's family is
  decided — see §6.
- **check-stubs** — one line, `crates/kaya/src/protocol.rs:400 declares a
  depth stub on "typeface", but that file is not one of the backends this
  gate reads`. NOT MINE and it predates this arm: the line is a DOC
  COMMENT quoting the call ("the two Rust-native backends still declare
  `depth_stub("typeface")`"), it arrived with the depth slice's
  uncommitted work (`git show HEAD:crates/kaya/src/protocol.rs` has no
  such text), and it is also now factually stale — GTK has landed, so it
  is one backend, not two. The census clause fires on the spelling alone.
  Fix for whoever owns that file: reword so the call is not quoted
  verbatim, or name the file in the three helper tables. I did not edit
  it — it is core, and two agents are in it.
  (The second line this gate had, in
  android/milestone2kt/src/main/kotlin/dev/kaya/milestone2kt/MainActivity.kt, WAS about my arm — it said
  APPLY_SET_TYPEFACE "still calls depthStub" — so I corrected it, and
  that half is now green.)
- **check-build-id** — `a freshly built libkaya does not carry this
  tree's id`. A SHARED-TREE RACE, not a defect, and the evidence is in
  the numbers: three runs in half an hour reported three different TREE
  ids (db78506a5331c871, then 7e32f40d806c5308, against dylibs stamped
  4f234a9dd9b2ba8b and 829ca167bc513e0f), because sibling agents are
  editing crates/ while the gate builds and then verifies. Run standalone
  in a quiet moment — `cargo build -p kaya --features harness --locked`
  then `tools/build-id.py --verify` — it passed twice in a row, and
  `check-build-id: OK` was observed. I touched no file under crates/.

Individually green and watched: check-compose (watched failing first),
check-detekt, check-verbs (60 verbs, 86 constants, spec hash × 2).

**The same race bit my own probe once**, and it is worth carrying: a
`tfprobe.sh build 2>&1 | tail -2` swallowed the verify's non-zero exit
and the next leg ran against the PREVIOUS apk — the exact pipeline trap
CLAUDE.md names. The driver now `--verify`s the apk's compose id inside
`leg` as well, so a leg cannot run against an interpreter that is not the
one on disk, and the core build retries until its id converges.

## 6. THE ONE BLOCKER — the scene's family, and it is not android's alone

`tools/scenes/typeface.steps` freezes `expect_typeface "Georgia"`.
MEASURED on this lane: `Georgia` is not on the emulator image, the arm
reports `typeface Georgia is not installed — the platform ramp stands`,
and the read answers `Roboto`. Two facts make it unfixable by
capitalisation or by luck:

- Android's family lookup is **case-SENSITIVE** (the probe measured
  `serif` hitting while `Serif`/`SERIF` miss), so no spelling of Georgia
  resolves.
- The fallback is Roboto, which is **pixel-identical to declaring no
  brand at all** — so a leg wired today would not merely fail, it would
  fail identically to a backend with no arm at all. The apply-time
  diagnosis is the only thing that tells those two apart, which is
  exactly why it is in the lowering.

The GTK arm hit the same wall from the other side and its ledger entry
says so: mac and windows resolve `Georgia`, linux resolves `DejaVu
Serif`, android resolves `Noto Serif`. So this is one cross-lane
decision, not four:

1. **A shared font BLOB** — the only option that keeps the scene's
   expected family ONE byte-frozen string on every lane, which is
   invariant 6's whole shape. Measured working here end to end: bytes →
   app-private file → `FontFamily(Font(file))`, with the read naming the
   blob's own family out of its name table. Needs a redistributable font
   in the tree (a license call, ledgered since the depth slice).
2. **Per-platform rows in the guest** (`brand_typeface_with`) — measured
   working here too: `Georgia` default + android row `serif` resolves to
   `Noto Serif`. But then the scene's expected string differs per lane,
   which the steps grammar cannot say today.
3. **Android (and linux) stay off this scene.** Cheapest, and it leaves
   the arm asserted by nobody on its own lane — which is the state that
   let half-branded lowerings ship elsewhere.

If (2) is chosen, android's row is **`serif`**: it moves every measured
width, it is metric-matched to Roboto so no line box moves (probe §1.3),
and it is one of the four AOSP-baseline names, so it holds on an
arbitrary device rather than only on this image. `monospace` is the
second choice if the demo wants the change unmissable.

## 7. WHAT I DID NOT TOUCH, AND WHAT I REMOVED

- No `tools/**` and no `*.steps` edits.
- `guests/rust/typeface.rs` is **unchanged** — deliberately. Adding
  android's row there is one line, but the row and the scene's expected
  family are one decision (§6) and the file is shared with four other
  in-flight arms.
- The probe guest (`guests/rust/typefaceprobe.rs (gone)`) and its dispatch arm
  in `guests/rust/milestone2_android.rs` are DELETED; the restore is
  proven by sha256 (`milestone2_android.rs: OK` against the pre-probe
  hash), and `git status` shows no residue.
- Files changed: `android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt`
  (the arm), `android/milestone2kt/src/main/kotlin/dev/kaya/milestone2kt/
  MainActivity.kt` (a comment about my arm that my arm made false), and
  `docs/deferred.md` (the compose stub entry struck through, with what
  is still open). NO COMMITS.

## 8. HOUSEKEEPING, PROVEN

- **Processes.** `gradle --stop` → "1 Daemon stopped"; `ps` for
  `GradleDaemon|KotlinCompileDaemon` is EMPTY afterwards.
- **Emulators untouched.** The four AVDs are the same pids the earlier
  Compose probe recorded (1856/1859/1862/63625) at 20-day uptimes: not
  started by me, not stopped by me. No device SETTING was changed
  (nothing here needs font_scale or night mode).
- **Device state.** The one file my legs created —
  `/data/user/0/dev.kaya.milestone2/files/kaya-brand-font`, the blob
  route's staging file on emulator-5554 — is deleted, and `ls files/`
  now shows only `profileInstalled` on all four devices.
- **Disk.** My own scratch is ~1.5 MB of logs plus this report; the
  perturbation backups are deleted (their restores were verified first).
  `styling/` measures 89M, of which 79M is another agent's
  `typeface-winui-arm` directory. The repo's `target/` grew only by the
  ordinary android artifacts the lane rebuilds anyway.
