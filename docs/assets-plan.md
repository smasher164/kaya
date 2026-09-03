# kaya assets: one root, three readers

Status: **RATIFIED 2026-08-18 (maintainer), AND BUILT 2026-08-18** — the
ruling is stated plainly below; the survey and evidence sections follow
unchanged. What landed, against the ruling: `asset(name)` is a core call
(crates/kaya/src/assets.rs, six C exports beside `kaya_blob_register`)
with the blob and bytes redemptions and no descriptor anywhere; the
resolution rule and the miss sentence live once, in Rust, with every
branch made to print; the file-like reader is binding-side sugar over
bytes in each language's own idiom; the eight typeface guests collapsed
from a ten-line preamble to one line; the asset root moved as a UNIT on
every lane that stages one; guests/assets/win/minimal-resources.pri moved under
the root with a provenance README; and tools/check-assets.py holds all of
it. STREAMING and Go's `fs.FS` façade stayed refused behind their named
triggers, as ruled. The two carve-outs the build itself forced are stated
in A3's walls and in A8.

**COMPLETED 2026-08-18** by a second pass that closed the four things the
first one deferred, each for a reason the pass had to discharge rather
than repeat: the CONFORMANCE SCENE (tools/scenes/assets.steps, nine
guests including the C floor, legs on all five lanes) freezes the miss
sentence's census, which is the only run-time observation that a lane
staged the whole root; the APK's own `assets/` is read through
AssetManager and the arm IS REACHED — two android legs arrive with no
`KAYA_ASSET_DIR` and resolve out of their own package with nothing staged
beside them, and the same byte-frozen census comes out of both routes on
the same device; the eight IDENTITY guests joined the typeface guests on
`asset(name)`, with check-app-identity's C3 taught a third accepted form
and given the watched negative it had never had; and the C floor gained
guests/c/assets.c. Three things the building forced and the design had
not: a PUBLIC `asset_miss_sentence` in all eight bindings (the scene
reads the sentence through a total query, because unwinding is not one
semantics in nine languages), an `assets/kaya/` prefix inside the APK
(an app's AssetManager root listing is not exclusively the app's), and a
QUOTE-AWARE statement split in all three interpreters (the frozen
sentence contains a `;`, which is the grammar's newline stand-in — no
expected string could contain one before, a restriction written down
nowhere). This brief answers the maintainer's
question of 2026-08-18: "we have some examples right now where we declare
binary data in a source file that can probably be replaced with an asset
that's packaged/bundled." It surveyed every such place first and designs
second.

Claims are marked [REPO] (read from this tree), [MEASURED] (run by this
pass; the notes and the extraction script's output are in
docs/chrome/assets-survey.md), [INFER] (reasoning a depth slice
must confirm).

Every path and line this document cites is checked by
tools/check-doc-refs.py.

The ratified precedent this generalizes is docs/app-identity-plan.md:124
(ruling 4, "the identity comes from a file") and its mechanism section
docs/app-identity-plan.md:186, which established one asset file with two
readers, the vendored-font pattern, and a byte-equality gate.

## The ruling, plainly (ratified 2026-08-18)

`asset(name)` is a CORE call returning an asset HANDLE. Two redemptions:
the BLOB route (hand it to kaya — fonts, icons, images — bytes never
round-trip through guest memory) and `bytes()` (when the guest is the
consumer). A file-like reading API is BINDING-SIDE SUGAR ONLY: each
language wraps the bytes in its own standard in-memory reader
(bytes.NewReader, BytesIO, MemoryStream, ...) — idiomatic spelling,
zero core surface. NO file descriptors: that was PickedFile's necessity
(a provider-opened file with no path behind it), not ours — kaya
resolves the name and produces the bytes itself, so no noCompress
packaging rule and no fd-offset sharing subtleties exist. Assets are
READ-ONLY structurally (no mode argument — the check-file-modes bug
class cannot exist here). The resolution rule and its failure sentence
("no asset named X; the package carries [...]") live once, in the core.
STREAMING IS DEFERRED BEHIND A NAMED TRIGGER: admitted only when an
artifact carries an asset too large to hold in memory; designed then,
not now. GO'S SECOND SPELLING IS ADMITTED BEHIND ITS OWN TRIGGER, and
this is an admission rather than a refusal (maintainer, 2026-08-18): an
`fs.FS` façade over the asset root is legal binding-side sugar — the
same tier as `bytes.NewReader`, zero core surface — the moment a real Go
artifact wants to hand its assets to something FS-shaped
(`http.FileServer`, `template.ParseFS`, `embed.FS`'s consumers). Not
speculatively: the trigger is an artifact that wants it, and until one
does, `bytes()` plus `bytes.NewReader` is the whole Go surface.
The refusal list stands unchanged. The maintainer's churn rule
applies to the implementation: every decision here was made on
correctness (packaged assets are not files on Android; platform
locations are the host's knowledge), never on update effort.

## The decisions this brief asks for, plainly

This section stands on its own. Everything after it is the evidence.

### 1. The survey's headline answer: most of the inline data should stay inline.

The maintainer's hunch was right about one site and wrong about the rest,
and the honest report is worth more than a tidy one. The tree declares
binary data inline in 40 places [MEASURED]. Thirty-nine of them are three
tiny PNGs (75, 75 and 77 bytes) plus one deliberately corrupt one, and
they are the **inputs to assertions about image decoding**. A scene whose
job is to prove that kaya decodes a picture must not be able to fail
because a file was not staged to a device. They stay.

What is genuinely mis-filed is one file, and it is not a guest at all:
an opaque 1040-byte Windows resource index that sat beside a shell
script under tools/guest/ with no provenance and no way to regenerate it
[MEASURED]. That was an asset filed as a tool. It now lives at
guests/assets/win/minimal-resources.pri with a README that says, among
other things, that nobody knows who produced it.

### 2. kaya already has three assets, and has only ever named one.

The vendored font is the one everyone knows. The 38-file scene corpus
under tools/scenes and the Windows resource index are the same shape:
bulk data files, staged to devices, resolved through an environment
variable with a default. The convention below is written to fit what the
tree already does rather than to replace it.

### 3. The wire learns nothing. This is the question the brief was asked to answer.

kaya's protocol does not gain an asset concept, and no record ever
carries an asset name. The wire already carries bytes, through the blob
channel the typeface and the icon both ride, and it is indifferent to
where the guest got them. An asset is a file that the guest's own build
put on disk. Putting a name on the wire would make some later reader
resolve it, and the resolution would have to happen in a place that does
not know the answer.

### 4. The one real design decision: whose file API reads an asset.

Today a guest reads an asset with its own language's file call, and the
resolution rule plus the error sentence are hand-written eight times
(guests/rust/typeface.rs:1 and its seven siblings). This brief
recommends replacing those eight copies with **one call, `asset(name)`,
that returns a blob handle rather than bytes**: the guest says "load this
and use it," the core resolves the path, reads the file and registers the
bytes into the blob table the wire already has, and no picture or font
ever passes through the guest's heap. Three shapes are weighed in A3, the
recommendation is the third, and this is what ratification is really
being asked to decide.

### 5. Two gates, and one of them closes a real hole today.

The 39 image literals are byte-identical right now [MEASURED], and a
typo that broke a decode would redden that language's leg on five lanes.
But every scene asserts a **decoded size** and never a pixel
(tools/scenes/gallery.steps:8, tools/scenes/clipboard.steps:19,
docs/clipboard-plan.md:688 titles the reason), so a copy whose colors
drifted would stay green everywhere forever. One census gate closes that
for less than the cost of staging four scenes' inputs to five lanes. The
second gate is the identity plan's, generalized: the bytes inside a
packaged artifact equal the bytes in the tree.

## A1. The survey, measured

Every site where the tree declares binary or bulk data inline. The
extraction parsed each language in its own spelling (hex, decimal, Java's
signed decimals, OCaml's `\ddd` escapes, Haskell's `BS.pack` lists,
Kotlin's `byteArrayOf(...toByte())`), stripped comments, and hashed the
reconstructed bytes.

| what | bytes | sha256[:12] | sites | verdict |
|---|---|---|---|---|
| 2x2 RGB PNG | 75 | `e6d668891312` | **18** (a11y and gallery, 9 languages each) | keep inline |
| 2x64 PNG | 75 | `546bc373c85c` | **8** (align, 8 languages; no C guest) | keep inline |
| 4x4 RGB PNG | 77 | `97720159d21d` | **13** (clipboard, 8 languages, plus 5 in tools/) | keep inline |
| corrupt PNG, bad IDAT CRC | 88 | `759ad58259a5` | 1 (tools/win/clipprobe/clipprobe.ps1:93) | keep, deliberately |
| `ranges` document | 813 | text | 9 languages | keep inline |
| `editor` seed document | ~131 | text | 1 (guests/go/editor/editor.go) | keep inline |
| `"not an image"`, `note=1` | 12, 6 | text | 17 | keep |

**Every copy of each image is byte-identical today [MEASURED].**

Two negative results worth stating, because the request anticipated both:
**there is no base64 anywhere in the guests** and **there is no pixel
synthesis in the guests** [MEASURED]. Every image is a pre-encoded PNG
spelled out byte by byte, and the source comments say so ("embedded as
source: scenes carry their inputs, no runtime file I/O"). Runtime
synthesis exists only in two probes, tools/ios/clipprobe/run2.sh (python
`struct` and `zlib` build a PNG) and tools/mac/clipprobe/main.swift
(NSImage to TIFF to PNG), where it is right: a probe that synthesizes its
own input is proving the platform's encoder, not kaya's.

The 5 non-guest copies of the 4x4 image are separately compiled programs
on four toolchains: tools/win/clipprobe/src/main.rs:50,
tools/linux/gdkclipprobe/probe.rs:63, tools/ios/clipprobe/main2.swift:46,
tools/android/clipprobe/app/src/main/kotlin/dev/kaya/clipprobe/SeedReceiver.kt:82,
and tools/android/cliphelper/run3.sh:61 (base64 over an intent extra, the
only base64 of it in the tree).

### Why the images stay inline, stated properly

1. **They are inputs to the assertion, not app content.** gallery proves
   that a valid PNG decodes and an invalid one becomes a placeholder
   rather than a crash. Making that scene depend on a staged file adds a
   failure mode to the very thing under test, on five lanes.
2. **They are 75 to 77 bytes.** The duplication costs nothing anyone can
   measure, and the spelling differences across nine languages are the
   guests' documentation of each language's byte-literal idiom.
3. **The drift is already caught, at the level that matters most.** A
   typo that breaks a decode turns that language's leg red on five lanes.
4. **What is not caught is the pixel content**, and no assertion in the
   tree reads a color. That is the one hole, and A6's census closes it
   for the cost of one gate.

The `ranges` document (813 bytes, 9 languages) has a stronger guard
still: the scene's assertions are byte offsets into it, so any drift
shifts an offset and reddens the lane. guests/csharp/RangesScene.cs even
checks its length at runtime. It needs nothing.

The corrupt 88-byte PNG is the clearest keep of all. It is a
decoder-strictness negative whose entire point is that it is malformed,
and a file on disk invites the next reader to fix it.

### The three things the repo already treats as assets [REPO]

1. **The vendored font.** guests/assets/fonts/sora-wght.ttf, 111400
   bytes, with guests/assets/fonts/OFL.txt and a README beside it stating
   provenance, licence and why the file is what it is. Read by 8 guests
   through `KAYA_FONT_FILE` with the repo-relative default. This is the
   precedent docs/app-identity-plan.md:212 names.
2. **The scene corpus.** tools/scenes/*.steps, 38 files, 188 KB, resolved
   in crates/kaya/src/harness.rs from `KAYA_SCENES_DIR` with a
   compile-time-relative default. It has **two transports**, and this is
   the design input that matters most below: the path, and
   `KAYA_SELFTEST_SCRIPT` carrying the content itself, because an iOS
   bundle and an Android intent have no shared filesystem with the runner.
3. **The Windows resource index**, surveyed at
   guests/assets/win/minimal-resources.pri and now at
   guests/assets/win/minimal-resources.pri: 1040 bytes of opaque MRT
   data, committed once, not regenerable, no provenance file, working-
   tree mode `-rw----r-x`. It was shipped to the VM by
   tools/deploy-win.py and hashed into the deploy stamp, so it was
   already treated as data by the machinery and as a tool by the layout.

### One layering note

The tree's only `include_bytes!` compiles the vendored font into the
core's harness build (crates/kaya/src/winui/mod.rs, the DirectWrite
name-table tests). The core reaches across into guests/. It works, and
nothing states the dependency, so moving the font breaks a core test with
an error that names neither the asset nor the reason [REPO].

### What is not an asset, and must not become one

The four per-platform icon tables (swift/KayaSwiftUI.swift for SF
Symbols, crates/kaya/src/gtk.rs:65 for Adwaita names,
crates/kaya/src/winui/mod.rs for Fluent, and KayaCompose.kt for Material,
20 entries each) are per-platform spellings of a semantic vocabulary, and
DESIGN.md:2418 already ruled the question: "Icons want names, not bytes
... The Blob stays for genuinely app-specific art."

A measured gap found while surveying them, since closed in full
(2026-08-19): `check-symbols.py` (gate 38) holds the SwiftUI table's
names to the OS floor, and `check-symbol-parity.py` (gate 39) pins all
the tables to `wire::SYMBOLS` — value, name and coverage for the
hand-copied layers, coverage for the two that name the wire constants.

## A2. The convention

**Where assets live.** One root, `guests/assets/`, which already exists
and already holds one family in its own subdirectory
(guests/assets/fonts/). Assets are named by their path under the root:
`fonts/sora-wght.ttf`, later `identity/icon.png`. Flat families, no
nesting beyond one level, no manifest of contents. The directory listing
is the manifest.

This is not a proposal so much as a description: the app-identity slice
in flight on 2026-08-18 has already created its own family under
guests/assets/ with a README beside the picture, without having read this
brief [REPO]. Two independent slices reaching the same layout is the
evidence that it is the layout.

**Every family carries a README** stating what the files are, where they
came from, their licence, and how to regenerate them if they were
generated. guests/assets/fonts/README.md is the model and is unusually
good: it explains why the file was renamed (brackets are glob
characters), why it is variable rather than static, why it was chosen
over a smaller candidate, and why the OFL's Reserved Font Name term means
it ships whole. That is the standard, and a gate can hold it (A6).

**The name is a relative path under the root.** No absolute paths, no
`..`, no symlinks out. This is a wall rather than a convention, because
an asset name that can escape its root turns a data reference into a file
read of anything.

**The root moves as a unit.** A lane stages the root, not a file. This is
the single change from today, where each lane stages the one font by
name, and it is what stops every future asset from costing five more
staging lines.

## A3. The one real design decision: how a guest reads an asset

The wire question first, because it is the one that was asked.

### The wire does not need an asset concept

**Recommended: refuse.** The blob channel already solves the problem the
wire has. The guest registers bytes, gets a handle valid for exactly one
submit, and the record carries the handle
(crates/kaya/src/capi.rs, the blob tables). Where the bytes came from is
not the protocol's business, and the C floor's guests already call
`kaya_blob_register` directly (guests/c/a11y.c:95).

Putting an asset **name** on a record, so that a backend or the core
resolved it, would be a different mechanism with three costs and no
matching benefit:

1. **The resolver would sit on the wrong side.** By the time a record
   reaches a backend, the process may be an APK, a simulator bundle or a
   guest on a Windows VM whose repo mirror is at a different path. The
   guest knows its own installation; a lowering does not.
2. **It would break the rule that the core does not inspect blob bytes**
   (docs/app-identity-plan.md, the typeface's five walls), by making the
   core the party that produced them.
3. **It would give the wire a second way to say one thing.** Both
   `brand_typeface(font: bytes)` and `brand_typeface(font: name)` would
   have to exist, since an app that computes a font at runtime still
   needs the bytes form. Two spellings of one semantics across eight
   generated bindings is what invariant 1 exists to prevent.

The asset problem is "how do bytes reach the guest," which is one layer
below the wire.

### Three shapes for the guest-side read

**(A) Convention only, the status quo generalized.** Document the root,
give each asset family an environment override with a repo-relative
default, and let every guest read the file with its own language's API.

- Costs nothing to build. It is what ships today.
- Every new asset costs eight hand-written preambles. The resolution rule
  and the diagnostic sentence exist eight times each, and they are
  identical prose that nothing holds equal.
- One of those eight has a language-specific trap severe enough to have
  earned its own gate: a Go guest must read the host's environment
  through `kaya.Env` and never `os.Getenv`, because in a c-shared library
  Go's copy is empty forever (tools/check-go-env.py, and
  guests/go/typeface/typeface.go:11 carries the comment). Invariant 3
  prefers one implementation to a gate over eight copies.

**(B) A binding-level reader.** `kaya.asset("fonts/sora-wght.ttf")`
returning bytes, implemented once per binding.

- The guests collapse to one line each, and the sweep lands where
  check-sugar-surface already looks.
- The resolution rule still exists eight times, moved from guests to
  bindings. Eight is a smaller number of copies to hold equal than
  eight-per-asset, but it is not one.
- It makes kaya's bindings own a file-reading API, which is a capability
  the vocabulary has deliberately not had. The picked-file handle is
  host-mediated on purpose; a general read is not.

**(C) A core call that returns a blob handle, not bytes. RECOMMENDED.**
`asset(name)` in all eight bindings and the C floor, over one C ABI entry
point that resolves the root, reads the file, registers the bytes into
the blob table, and returns the handle a record will carry.

```
  tx.brand_typeface_with("Sora", &[], Some(tx.asset("fonts/sora-wght.ttf")))
  kaya.brand_typeface("Sora", font=kaya.asset("fonts/sora-wght.ttf"))
```

- **The rule and the diagnostic exist once**, in Rust, in the one place
  that can be unit-tested and whose branches can be watched printing, as
  invariant 3 requires of any why-not.
- **It is the pattern the core already runs.** crates/kaya/src/harness.rs
  resolves the scene corpus from an environment variable with a
  compile-time-relative default, which is exactly this code with a
  different variable name.
- **The bytes never enter the guest's heap.** This is what keeps it from
  being a file API: the guest cannot look at an asset, only hand it to
  something. "kaya, load this and use it," not "kaya, read me a file."
  It is also free of a copy on every language's boundary.
- **The Go trap becomes unreachable** rather than gated, along with any
  future language's version of it, because no guest reads an environment
  variable at all.
- **The C floor gets a primitive** that reads beside `kaya_blob_register`
  rather than under it.

Costs, stated plainly. It is a new surface in kaya's C ABI and an eight
way binding sweep with a check-sugar-surface row. It is not spec-driven
(no wire record moves, so no generator runs), which means the eight
spellings are hand-written and the sweep is the only thing holding them
level. And it has one honest limit: **a guest that needs the bytes
themselves still reads the file.** The clipboard scene writes its PNG to
a temp file for the seeding tool, and a handle cannot serve that. Under
(C) such a guest uses its own language's file call, which is ordinary
program code that kaya need not own. That limit is a feature, because it
is what keeps the surface from growing into a virtual filesystem.

### The walls on `asset(name)`, if (C) is ratified

Written to mirror the typeface's five, which the identity brief already
copied once (docs/app-identity-plan.md, I5):

1. **The name is a relative path under the root.** No absolute path, no
   `..`, no escape. Refused at the call, in the core, in every language
   at once.
2. **Missing, unreadable or empty is a hard error**, in one sentence
   naming the resolved path and the environment variable that overrides
   it. Empty is refused for the identity rule's reason: an empty blob
   sails through a lowering and is indistinguishable from a default.
3. **The bytes are not inspected.** Whether a blob is a font or a picture
   is a question only the platform's decoder can answer.
4. **No caching promise, no watching, no reload.** Each call reads.
5. **The handle obeys the blob table's existing lifetime**: valid for
   exactly one submit, drained whether referenced or not.

## A4. Where an asset sits, per platform

The identity plan's table (docs/app-identity-plan.md:248) is about which
reader puts an icon where a user sees it. This one is a layer below: how
the bytes get to the machine at all. All rows [REPO].

| platform | repo run today | staged to the lane today | in a packaged app | reader exists? |
|---|---|---|---|---|
| **macOS** | repo-relative default, no copy | nothing needed, runs from the repo root | `Contents/Resources/` in a `.app` | later; no bundle in the tree |
| **Linux** | repo-relative default | nothing needed, the repo is bind-mounted at `/work` (tools/linux/run-suites.sh:606 states the reasoning) | `$datadir/kaya/<app>/` beside the `.desktop` file | later |
| **Windows** | n/a | `scp` every run into a repo-mirror path, deliberately outside the deploy stamp so an asset edit cannot be swallowed by a stamp skip (tools/deploy-win.py:450) | beside the exe, or inside an MSIX | staging today, packaging later |
| **Android** | n/a | `adb push` to `/data/local/tmp` with a size check, then named into the app through an intent extra (tools/android/run-emulator.py:662) | APK resources or `assets/`, read through `AssetManager` | staging today, packaging later |
| **iOS** | n/a | **nothing. No file-push route for assets exists.** | inside the `.app`, copied at bundle assembly | **neither** |

**The iOS row is the finding.** [MEASURED] `grep -c typeface` over the
five lane scripts: validate-mac 5, the linux suite runner 19, deploy-win
15, the android emulator runner 21, **ios/run-sim 0**. The scene lists at
tools/lib/lanes/ios.py:24 do not contain `typeface`. The one asset kaya
ships has never reached iOS, and the lane's only host-to-guest binary
channel is a base64-over-container-file bridge that is the clipboard and
dialog protocol, not an asset installer.

The recommended fix is the one that is also the packaging reader:
**tools/ios/run-sim.py:198 (`make_bundle`) copies the asset root into the
bundle's Resources.** That is what a shipped iOS app does anyway, so iOS
becomes the first lane whose asset delivery is the real mechanism rather
than a test convenience, and the typeface scene becomes runnable there.

Note what this row shows about the scene corpus's two transports: when a
platform has no shared filesystem, the tree's existing answer was to send
the **content** rather than a path (`KAYA_SELFTEST_SCRIPT`). For a
111 KB font or an icon, content-over-intent is not available on Android
(intent extras cannot carry newlines, which is why the scene grammar has
a `;` stand-in) and is clumsy on iOS. Bundling at build time is the
right answer for assets, and staging by path is the right answer for the
lanes that have a filesystem. Both already exist; neither needs inventing.

## A5. What the harness and the lanes need

1. **Stage the root, not the file.** `font_prepare()` (now
   `assets_prepare`, tools/android/run-emulator.py:662) becomes an
   asset-root push. Its
   size verification (`adb shell stat -c %s` compared against `wc -c`)
   is the model, and it should become a **hash** comparison rather than a
   size one when it generalizes, because a same-length corruption is
   exactly the failure a size check misses.
2. **Windows keeps its property** of copying every run, outside the
   deploy stamp. Generalize the path, keep the reasoning.
3. **iOS gains the bundle copy** described above.
4. **Linux and macOS need nothing**, and the reason should be written
   down at the staging site rather than inferred: the root resolves by
   default because the process runs with the repo visible.
5. **One environment variable, `KAYA_ASSET_DIR`**, replacing per-asset
   variables. `KAYA_FONT_FILE` can stay as the font's own override during
   the transition and then go, or stay forever as a per-file escape
   hatch. This is a small ratification question in A8.

## A6. The gates

**Gate 1, the census: duplicated binary literals stay byte-equal.**

The hole this closes is precise and measured: every scene asserts a
decoded size and never a pixel, so a copy whose IDAT differed while its
header matched would stay green on all five lanes forever. The gate
decodes every image literal in the tree, in all nine guest spellings plus
Kotlin and PowerShell base64, groups them by scene, and requires the
copies of one image to be identical. The extraction is already written
and measured (docs/chrome/assets-survey.md).

It follows tools/tpl-surfaces.py's shape, and for the same forced reason:
a line-oriented grep cannot read a 75-byte array spelled nine different
ways, and three of the spellings put the literal on one line while others
span twelve.

Two properties it must have, both from invariant 3:

- **It refuses a verdict on an implausible count.** A census that decodes
  two literals agrees with everything. It prints how many it found and
  fails if the number falls below the known set.
- **It has a watched negative that is proven to have applied.** Perturb
  one byte of one copy in a saved copy of the file, print the
  substitution count, treat an unchanged file as a failed test, and see
  the gate go red. Restore from the saved copy and verify with
  `shasum -c`, never with git.

**Gate 2, packaged bytes equal declared bytes.** This is
docs/app-identity-plan.md:226's gate, generalized from the icon to the
root. For every artifact a lane builds or ships, the asset bytes inside
it equal the asset bytes in the tree. The failure it prevents is the
quiet kind the identity plan names: the launcher shows last month's icon,
the running window shows this month's, and every test passes. It belongs
where invariant 3 puts guards, which is in the packaging step itself,
with tools/gates.py as the backstop for platforms whose packaging step
does not exist yet.

**Gate 3, provenance.** Every family directory under the asset root has a
README naming what the files are, where they came from, the licence, and
how to regenerate them. This is three lines of shell and it is the thing
that makes vendoring safe. guests/assets/fonts/README.md passes it today, and
guests/assets/win/minimal-resources.pri is the file that FAILED it,
which is how the survey found it at all.

## A7. Refused, stated once

- **An asset name on the wire.** A3 gives the three reasons. No record
  ever carries an asset reference.
- **Runtime asset mutation, writing, or hot reload.** Assets are read
  only, and are read when the guest asks. A watched directory would
  promise a live-reload surface the vocabulary does not have, exactly as
  a settable icon would promise theme switching
  (docs/app-identity-plan.md, I6).
- **Asset catalogs, density and scale variants, `@2x` and `@3x`,
  per-platform art rows.** This was refused once already, in the sentence
  that put fonts on the blob channel: "an asset pipeline offers fonts
  nothing the blob channel lacks, density variants and OS packaging are
  raster-art concerns" (docs/styling-plan.md:270, ledgered at
  docs/deferred.md:3126). The identity brief answers that sentence for
  the icon by converting in the lowering, and re-refuses per-platform
  icon art **for now**, to be reopened when packaging lands
  (docs/app-identity-plan.md:696). This brief changes neither. An asset
  is one file, and the platform converts.
- **Localized asset variants.** kaya has no localization vocabulary at
  all; a per-locale asset would be its first and would arrive through the
  back door.
- **Archives, compression, or a bundle format.** Assets are files in a
  directory. The directory listing is the manifest.
- **A virtual filesystem, a resource-bundle API, or asset preprocessing**
  (image resizing, format conversion, font subsetting). kaya is not a
  build system. The font README already records why subsetting in
  particular is refused: it would be a modification under the OFL, which
  reserves the family name, and the family name is the scene's frozen
  observable.
- **Moving the scene corpus into the asset root.** tools/scenes is
  harness input with its own two-transport delivery, and it is beside the
  runner that ships it on purpose.
- **Moving the test image literals into the asset root.** A1 gives the
  four reasons.
- **Turning the four icon tables into assets.** DESIGN.md:2418 settled
  it: icons want names, not bytes.

## Dependencies and sequencing

1. **The app-identity slice is not blocked and should not wait.** It
   ships its icon under the convention that exists today: a file under
   guests/assets/, an environment override with a repo-relative default,
   and the three staging lines the font already established
   (docs/app-identity-plan.md:212). Everything below is additive.
2. **Gate 1, the census.** Independent of every decision here, cheap, and
   it closes a measured hole. Schedulable immediately.
3. **This ratification** decides A3's question and A5's variable question.
4. **If (C):** the C ABI entry point, the core resolver and its five
   walls with unit tests and a watched-negative diagnostic, then the
   eight-way binding sweep plus the C floor, then the typeface guests
   collapse from a ten-line preamble to one line in each of eight
   languages, and the identity guest is written that way from the start.
5. **The Windows resource index moves** under the root with a README
   stating its provenance and how to regenerate it, or an honest note
   that nobody knows. LANDED: guests/assets/win/minimal-resources.pri,
   and the note is the honest one.
6. **iOS gains the bundle copy** in `make_bundle`, which is both the
   lane's missing staging route and the icon's iOS packaging reader.
7. **The packaging milestone consumes all of it** (docs/deferred.md:2059,
   which already names "cargo build-script asset embedding" among the
   things a real package must carry).

## What ratification asks

1. **A3's question, which is the brief's reason for existing:** (A)
   convention only, (B) a binding-level reader returning bytes, or (C) a
   core call returning a blob handle. Recommended: **(C)**, on the ground
   that it puts the resolution rule and its diagnostic in one place, is
   the code the core already runs for the scene corpus, and never hands a
   guest bytes, so kaya does not acquire a file API.
2. **The survey's headline:** that the 39 inline image literals stay
   inline, with a census gate rather than an asset file. This is the
   opposite of what the question anticipated and the reasons are in A1.
3. **The iOS bundle copy** in `make_bundle`, which makes the typeface
   scene runnable on the one lane that has never seen an asset, and is
   the same code the icon's packaging needs.
4. **One `KAYA_ASSET_DIR` for the root**, and whether `KAYA_FONT_FILE`
   retires with the transition or stays as a per-file escape hatch.
5. **The refusals in A7**, particularly the re-refusal of density and
   scale variants, which is a re-affirmation of docs/styling-plan.md:270
   rather than a new decision, and stays reopenable with packaging on the
   identity plan's terms.

Two findings that stand on their own, whether or not any of this
proceeds: ~~no gate pins the four per-platform icon tables to one
another~~ [MEASURED] (closed 2026-08-19: `check-symbols.py` gate 38 +
`check-symbol-parity.py` gate 39);
and **the core's only
`include_bytes!` reaches into guests/assets/ with nothing stating the
dependency**, so moving the font breaks a core harness test with an error
that names neither the asset nor the reason.
