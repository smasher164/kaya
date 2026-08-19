# Working on kaya — agent operating rules

<!-- Mirror of CLAUDE.md; edit both together. -->

This file is the distilled working doctrine for any agent or contributor.
The architecture and its reasoning live in DESIGN.md — read the relevant
section before changing a subsystem. Workflows and recipes live in
docs/HACKING.md. Known traps live in docs/traps.md. The work ledger lives
in docs/deferred.md.

## The environment

- Every command runs inside the nix dev shell. The tools/ scripts refuse
  to run outside it (they check a fingerprint of flake.nix+flake.lock in
  `KAYA_DEV_SHELL`). Enter with `nix develop`, or wrap one-off commands:
  `nix develop -c <cmd>`. If you edit the flake, re-enter the shell.
- For ad-hoc text processing use python3, never sed/awk (BSD/GNU
  divergence causes recurring breakage; this is repo policy with no
  "trivial enough" exception).
- Never pipe a build through `tail`/`head` in a verify loop — the
  pipeline's exit status becomes tail's, and a failed build silently
  runs the test against a stale artifact. Check the build's exit first.
- `$?` is read exactly once, on the line right after the command, into
  a named variable; everything downstream tests the VARIABLE. It is not
  a value you can come back for: an `if` that took no branch exits 0
  ITSELF, a bare `local rc` on the line between is a command and resets
  it, and a `[` overwrites it. shellcheck reports none of those three
  at warning level; check-shell enforces the shape. (`local rc=$?` on
  one line is fine — the expansion beats the command.)
- Every cargo invocation carries `--locked` (check-shell enforces it):
  a bare build may rewrite Cargo.lock mid-run, and the lane then goes
  green against a dependency graph nobody chose.
- A built artifact carries the id of the sources it came from
  (tools/build-id.sh). Anything a lane runs or ships gets
  `--verify`'d first — that is the mechanical version of "check the
  build's exit first", and it holds when nobody remembers to.
- `KAYA_FAST=1` skips any gate whose declared inputs have not moved
  since it last passed (tools/keyed.sh; input sets and the reasoning
  live in tools/build-id.sh's GATES). For the INNER LOOP only — the
  matrix never sets it, so the run that goes on the record consults no
  cache and cannot be wrong because of one.
- A COMMENT SURVIVES ONLY IF A FUTURE SESSION NEEDS IT to avoid a
  mistake (the maintainer's rule, ratified 2026-08-18: "the only things
  you shouldn't cut are things you'll need for future claude sessions
  that might need that context. everything else should be nixed,
  because it just makes things harder to read"). API narration,
  teaching prose about how kaya works, restated invariants, arguments
  that the code is correct, and the history of how we arrived are all
  nixed — the reader has the call in front of them, and DESIGN.md,
  this file and the plans hold the rest.
  AND WHERE THE CONTENT LIVES SOMEWHERE ELSE, THE COMMENT IS A POINTER.
  A line naming the gate that enforces it, or the trap, plan or ledger
  entry that records it, is the whole comment; a second copy of the
  reasoning only rots out of step with the first.
  THE ONE THING NEVER DELETED IS A MEASURED FINDING NOBODY ELSE WROTE
  DOWN. It moves to docs/traps.md FIRST and the pointer stays behind —
  deleting it is the only unrecoverable move in this rule, since a
  measurement costs a session to make again and prose costs nothing.
  The examples are held tightest of all: a guest should read as the
  kaya calls it makes.
- The maintainer approves every commit and its exact message. Do not
  commit or push on your own initiative.

## The invariants (violating these is never a style choice)

1. **Uniform binding semantics.** kaya has 8 guest-language bindings
   (Rust, Python, Go, C#, Java, Swift, OCaml, Haskell) plus a C floor.
   Any binding-level behavior — transaction rollback, abort handling,
   read guards, command surfaces — has ONE observable semantics in all
   of them. The language's idiom decides the *spelling* (exceptions vs
   panics vs Drop), never the *semantics*. Divergence is allowed only
   where a language literally cannot express the behavior, and the
   carve-out itself must be stated uniformly (see DESIGN.md's Binding
   conventions).
2. **Sweep all bindings.** A change to any binding surface is assessed
   against every guest language with an explicit do/can't/defer verdict
   per language. Never scope silently to the languages a request names.
3. **Failures become guards, ON A PATH NOBODY CAN AVOID.** Every
   failure class found gets a structural guard — types over generation
   over runtime checks — plus a negative test. If you fix a bug, ask
   what gate would have caught it and add that gate.
   AND THEN ASK WHERE IT SITS. A guard you have to remember to run is
   barely a guard: the session that needs it most is the one with no
   context, and it will not think to run your gate. Put the wall where
   someone walks into it by doing something BASIC — building, running
   the scene, deploying — and make the error say what to do next. A
   stale binding generator fails `cargo build` naming the fix
   (crates/kaya/build.rs); an unexpanded `$PID` fails the verb that
   reads it; a wrong scene name panics the guest. Prefer that to one
   more entry in a gate list, and when only a gate will do, put it in
   the set the lanes already run. Plan against your future self.
   AND WATCH THE NEGATIVE TEST FAIL. A negative test is only a test if
   the perturbation is PROVEN to have applied: print the substitution
   count and treat an unchanged file as a failed test, not a passed
   one. This has misfired twice — three of check-tx-liveness's five
   clauses passed with the guard deleted (grepping a bare function name
   matched the definition as well as the call), and the wayland seat
   guard's negative test passed VACUOUSLY TWICE because the pattern
   never matched the file at all. A guard you believe in but have never
   seen fail is worse than none: it stops you looking.
   AND THE SAME RULE COVERS DIAGNOSTICS. A why-not — any function whose
   job is to answer "why did that fail?" — is believed: the sentence it
   prints is what the next reader chases. So every branch of one must
   have been MADE TO PRINT before you trust it, exactly as a negative
   test must be watched failing. A branch nobody has seen print is a
   guess about a state nobody has reached. `kayaOpenPanelWhyNot()`
   blamed a fullscreen application for a missing NSOpenPanel; that
   branch was taken on EVERY mac leg (kaya's guests run `.accessory`,
   so `isActive` is always false), the branch under it was dead, and
   every claim in the sentence was false. Half an hour lost when it was
   written, and a whole session months later spent on macOS activation
   while the real cause was the panel's view mode. A DIAGNOSTIC MAY ONLY
   PRINT WHAT IT MEASURED; if it cannot tell two causes apart it says so
   and prints what it can see (docs/traps.md).
   `tools/check-diagnostics.sh` holds the shape of that — one answer, or
   an answer on the failure path that interpolates nothing, is a
   sentence that cannot discriminate — but a branch that discriminates
   and is still wrong is caught only by the review question.
4. **Validation scripts build and verify what they ship.** No stale
   artifacts, no bypassed mechanisms, no false PASS. A gate that can be
   satisfied without exercising the real thing is a bug in the gate.
5. **Examples use the construction sugar.** All example scenes use each
   language's sugar tier; only the C guests keep the fully explicit
   floor (deliberately, as the floor's documentation).
6. **Scene scripts are shared verbatim.** tools/scenes/*.steps feed
   every platform; expected strings are compared byte-for-byte across
   all languages, so guest output strings must be identical everywhere.
7. **The spec is the root.** Protocol changes start in
   crates/kaya/src/spec.rs; the spec hash moves; everything regenerates
   in lockstep (see the regeneration workflow in docs/HACKING.md).
   Generated files are never hand-edited.
8. **A duration anomaly is a bug signal.** If something is unexpectedly
   slow, investigate immediately — sample the interim state right then;
   never queue more work behind it.
9. **The ledger is not append-only.** Closing a deferred entry means
   striking the headline WITH its resolution — the strike and the note
   are one edit, never two — and then grepping the entry's key nouns
   across docs/ and the code comments and updating every hit. A fix
   recorded in a neighbouring entry is not recorded, and a headline
   nobody struck is what the next reader believes: two entries headlined
   "GAP — … cannot / is not implemented" carried "COMPLETE … matrix ALL
   PASS" in their own bodies for three weeks, and a survey reported a
   solved problem as the largest open one. So new entries carry a
   `KEY:` line naming the greppable nouns they will have to be swept
   for — the entry describes its own closing sweep, rather than leaving
   the next person to guess what to search. `tools/check-ledger.sh`
   holds the strike-and-note half; the sweep is yours.

## The validation ladder (in order; "done" means the top rung)

1. `cargo test -p kaya --features harness --locked` — unit tests, wire
   round-trips, pin tables,
   compile_fail doc-tests. THE FEATURE IS REQUIRED: `harness` is off by
   default so shipped apps do not carry the scene interpreter, and
   without it the 22 harness tests silently vanish (194 -> 172) rather
   than failing. GTK and WinUI builds need it too — mac/iOS do not,
   since the SwiftUI interpreter carries its own harness.
   IT RUNS WHERE YOU TYPE IT, which is why the windows lane now runs the
   core's unit tests ON THE GUEST as well (tools/deploy-win.sh's
   unit-tests phase, filtered to `capi::picked_tests`): the Windows half
   of the core — the HANDLE arms of protocol.rs's
   raw_handle/file_from_raw — is code no unix run compiles, and the one
   test of the redemption path had `#[cfg(all(test, unix))]` on it for
   four milestones. The phase refuses unless the number that passed
   equals the number of `#[test]`s the module declares, because a filter
   that matches nothing exits 0 saying "0 passed". The rest of the suite
   is 309/312 on that guest; the 3 are POSIX assumptions in harness
   tests, and fixing them is what widens the filter.
2. Fast gates. `tools/gates.sh` runs ALL of them and is the only thing
   that should. It builds libkaya and the SwiftUI interpreter FIRST — a
   gate cannot verify an artifact the run has not built yet, and one
   that tried read the PREVIOUS run's dylib and called it stale, which
   was true and useless — and then runs every gate below and REFUSES A
   VERDICT unless the number that ran equals the number it declared. A
   sweep that under-runs and still prints green is measured, not
   hypothetical: a hand-rolled loop over a shell variable ran 1 of 24
   gates and reported a clean run. There is deliberately no subset flag,
   because a flag that runs part of the list and still prints a verdict
   is that same defect with an interface; to run one gate, run that gate
   — each is standalone. `tools/check-gates.sh` holds this prose list,
   gates.sh's list and validate-mac's delegation to ONE census and fails
   naming both sides of any disagreement; the three had already drifted
   by four gates the day it landed. What each gate is for:
   `tools/gen-header.sh --check`, `tools/gen-bindings.sh --check`,
   `tools/gen-guests.sh --check` (compares what the generators produce
   against the WORKING TREE and puts every byte back — snapshot,
   regenerate, diff, restore, and a refusal if the restore left the tree
   changed. It used to regenerate in place and diff against git, which
   silently reverted any hand-edit to a generated file and then called
   the tree clean),
   `tools/check-steps.sh`, `tools/check-shell.sh`,
   `tools/check-mirror.sh` (CLAUDE.md and AGENTS.md are true mirrors
   modulo the line-3 comment — they drifted once, silently, for two
   milestones),
   `tools/check-gates.sh` (the drift sibling of the above, one file over:
   the gates this paragraph names, the gates gates.sh runs and the ones
   validate-mac reaches must be one list. Its census clause is the part
   that bites — every gate script on disk is either in the sweep or in
   gates.sh's EXCLUDED table WITH A REASON — and it is what would have
   caught the four gates this paragraph was missing while the lane ran
   them),
   `tools/check-ledger.sh` (docs/deferred.md may not disagree with
   itself: an UNSTRUCK headline over an entry that records a terminal
   resolution, or a STRUCK one with no resolution note. Two entries
   headlined "GAP — … cannot / is not implemented" carried "COMPLETE …
   matrix ALL PASS" in their own bodies for three weeks, and a survey
   that read the headlines reported a solved problem as the largest open
   item. The discriminator is calibrated, not guessed — this ledger
   spells LANDED, FIXED and CLOSED at SLICE scope routinely, so COMPLETE
   is the only whole-entry word available and the gate says out loud
   what that means it cannot see. Takes a path argument, which is how it
   was calibrated against the stale revision),
   `tools/check-doc-refs.sh` (the other half: every path-shaped
   reference in every tracked .md must exist. Globs are resolved and
   must match something, brace groups are expanded member by member, and
   a `<placeholder>` names a family rather than a file. A sentence that
   must name what the tree no longer has says so ONE way — struck,
   quoted inside a fenced block, or marked `(gone)` — and the exemption
   counts are printed on every run, with a refusal if they ever
   outnumber the checks),
   `tools/check-case.sh` (every tracked path matches the filesystem's
   case exactly. macOS is case-insensitive and Linux is not, so a Haskell
   guest created as `Background.hs` against a cabal stanza reading
   `background.hs` built locally, went green on mac, and would have died
   on the lane furthest from the change, after a full matrix),
   `tools/check-targets.sh` (cross-compiles every cfg'd backend, in BOTH
   feature configurations — it once reported "windows OK" while the
   windows lane failed to build the WinUI accessibility read, which
   only the harness config compiles. LINUX IS ITS HOLE, since gtk-sys
   needs the distro's pkg-config world, so it also text-checks that every
   backend's Stage impl names every required trait method: a trait method
   missed in gtk.rs alone used to survive every fast gate and die in the
   matrix),
   `tools/check-sugar-surface.sh` (every widget kind has a constructor
   in all 8 bindings IN BOTH CONSTRUCTION ZONES, AND every window prop
   has a sugar spelling in all 8 — the generic floor spells a prop
   without the sugar noticing, which is how Python shipped unable to
   declare `list_detail` at all.
   THE SECOND ZONE JOINED 2026-08-10 and is the half that had never been
   checked: the LIVE zone is what an app builds in its build closure,
   the TEMPLATE zone is the prototype inside a collection stamped once
   per row, and they are different surfaces handing out different
   handles. The template zone had 3 kinds where the live zone had 14, so
   kaya's own text editor spelled its find bar's text field
   `row.Widget(kaya.KindEntry)` and the undo scene did the same in seven
   languages — the floor, which is the C guests' tier and not an app's.
   That sweep is `tools/tpl-surfaces.py`, a python census rather than
   seven more greps, and the reason is forced: three bindings namespace
   the template zone by SCOPE rather than by name (Rust's `Tpl` methods
   are `pub fn entry` exactly like `Tx`'s; OCaml's live in `module Tpl =
   struct`), so a line-oriented pattern would be satisfied by the LIVE
   constructor and report a zone it never read. It also holds a zone's
   several surfaces level with each other — Rust's `Row` is a second
   façade onto `Tpl` and forwarded six methods while ten kinds were
   missing — and it REFUSES A VERDICT from a reader that found
   implausibly few constructors, because a census that reads nothing
   agrees with everything.
   IT CENSUSES PROPS TOO, since 2026-08-17, and a new template prop is
   spelled in its PROP_MEMBERS table rather than in sixteen more grep
   lines: the props are read out of each zone's OWN BLOCK, which is the
   thing a pattern cannot do when a binding spells its live and template
   setters identically (OCaml's `set_grow (Widget id)` against
   `set_grow (Node id)` — a name-keyed clause was measured passing with
   the template setter deleted). Three façades are held level by it now,
   Rust's `Row`, Java's `RowSurface` and C#'s GENERATED `<Rec>Row`; the
   two that are not (Go's, which EMBEDS the zone so the compiler holds
   it, and Swift's, which forwards no prop setter at all and is a slice
   of its own) are named in the file's exemption list, on the record
   rather than merely absent.
   AND THE CAPABILITY SURFACE SINCE 2026-08-19, in three clauses: the
   `capabilities` QUERY in all eight, one NAMED BOOLEAN per bit
   (`aux_windows` and its casings) in all eight, and the bit NUMBER
   against the core's own — five bindings have no header to read
   `KAYA_CAP_AUX_WINDOWS` out of and write the number themselves, which
   is the file-modes trap one surface over, and the three that DO read
   the core's constant (Rust, Go's cgo, Swift's bridging header) are
   checked for still naming it rather than quietly becoming copiers),
   `tools/check-universal-props.sh` (the lowering-side sibling: every
   backend applies the universal a11y props to every kind — Compose
   per-arm, SwiftUI's one wrapper unbypassed, GTK/WinUI's apply arm
   still keyed on the prop alone),
   `tools/check-roles.sh` (the role vocabulary reaches every backend:
   `MENU_ROLES` is one line, it is not in the spec hash, and adding an
   entry regenerates nothing — so before this gate a role could ship with
   the root accepting it and all four backends ignoring it. RED BY DESIGN
   across a fan-out; the role joins the vocabulary first and the arms
   follow),
   `tools/check-native-undo.sh` (the two native-tier undo guards that NO
   shared scene can fail — both sit inside a SECOND consecutive native
   walk, which the routing makes unreachable, and each was broken with
   the lane watched staying green. The scene cannot be fixed to reach
   them, so static pairing is the only wall available),
   `tools/check-diagnostics.sh` (a why-not may not print a sentence it
   cannot NOT print. Any function named `*WhyNot`/`*why_not`/`*Reason`
   is read as a diagnostic by that name alone; one answer, or an answer
   after the early-out that interpolates nothing, is a sentence the
   reader will believe for every cause it does not name — which is what
   `kayaOpenPanelWhyNot` did for months, twice sending someone after
   macOS activation rules. Its self-test splices the pre-fix body back
   in from git and requires the red),
   `tools/check-diagnostics.sh` (a why-not may not print a sentence it
   cannot have measured — see invariant 3. The shape it can see is a
   failure path with ONE answer, or an answer that interpolates nothing:
   such a sentence is printed for every cause it does not name, and it is
   believed),
   `tools/check-empty-child.sh` (ONE NODE IS ONE WIDGET, even when its
   content will not decode. The widget backends have that by
   construction — GTK keeps the GtkPicture and clears the paintable,
   WinUI keeps the Image and leaves Source unset — while a declarative
   backend that renders nothing takes the node OUT OF THE TREE, and
   every layout above it that counts children positionally then reads
   the wrong one. SwiftUI answered a failed decode with `EmptyView()`
   and `KayaCell` indexed `subviews[0]`: an undecodable image in a flex
   cell was a SIGTRAP during layout, on a position no scene has, so it
   survived every lane for months. Its macOS clause is a RUNTIME
   negative — the interpreter's own source compiled with
   tools/checks/swiftui-empty-child.swift and run, four byte shapes plus
   an unknown kind through the real KayaFlex/KayaCell; the static
   clauses hold all four backends' image arms present-and-empty and
   panic-free),
   `tools/check-abort.sh` (uniform abort
   semantics, all languages),
   `tools/check-tx-liveness.sh` (a transaction is usable only inside
   the build or handler that made it, on the app thread — the HANDLE
   bindings refuse a closed one at a single write chokepoint, the
   AMBIENT ones check the thread instead, having no handle to
   invalidate. The failure it guards is SILENT: a write through an
   already-submitted transaction vanishes with no error, which Go
   shipped for months because its check lived on two chains and not on
   the hundred other callsites), `tools/check-verbs.sh` (every harness verb
   and wire constant present in BOTH interpreter backends — plus the
   spec hash pinned against bindings/c/kaya_wire.h, the
   byte-compared-verdict rule, the vtable rule, and the
   stamped-observation rule),
   `tools/check-file-modes.sh` (the file-mode NUMBERS agree with the
   spec's wherever they are written down. `kaya_open_picked` takes an
   integer, crates/kaya/src/spec.rs decides what it means, and five
   hand-written sites decode it: protocol.rs's `picked_mode_code` sends
   it on, the SwiftUI interpreter picks POSIX flags out of bare literals
   (`case 1: flags = O_WRONLY | O_CREAT | O_TRUNC`), and the C# and
   Python bindings pick a FileAccess and an fdopen spelling the same
   way. Renumber the enum and every GENERATED surface moves while those
   literals stay: the guest asks to READ, the backend opens
   O_WRONLY|O_TRUNC, and the file the user picked is emptied with no
   error anywhere. The clause it replaces lived in check-steps and could
   not have caught that — it hard-coded 0/1/2 in the gate. The census is
   the half that survives a new site: every file that redeems a picked
   file is in one of two tables, and the pass-through table's claim is
   itself checked, by refusing any bare mode number in those files),
   `tools/check-app-identity.sh` (ONE declared identity, and every
   hand-written copy of it agrees. guests/assets/identity.toml names the
   app and names its mark; a BUILD reads it (the APK's mipmap and
   `android:icon`/`android:label`, the iOS bundle's icon and
   `CFBundleDisplayName`) and the RUNNING APP reads the same file's
   bytes onto the wire (the macOS Dock, the Windows taskbar and caption,
   an X11 window). Five routes reading five different files is how one
   mark on five platforms breaks quietly — the launcher shows last
   month's icon, the running window shows this month's, and every test
   still passes. The clause with teeth is the one nothing else could
   have: the byte-frozen `expect_app_icon "E01B24/33D17A/1C71D8/F6D32D"`
   in tools/scenes is DECODED against the mark's actual pixels, so
   swapping the asset without moving the expectation fails here instead
   of on five lanes at once. Beside it: every file naming
   `KAYA_ICON_FILE` takes its default from the declaration, every
   identity guest declares the declared name, any app-icon resource
   anywhere in the tree is byte-identical to the declared mark, and a
   tools/ packaging step reads the manifest rather than retyping the
   path — the .cmd launchers excepted, because cmd.exe cannot read TOML.
   BUILD OUTPUT IS DELIBERATELY OUT OF ITS WALK: the bytes actually
   written into an artifact are checked by the packaging step itself,
   which is the path nobody can avoid, and a gate that reads a build
   directory has a red that the last watched negative can manufacture),
   `tools/check-assets.sh` (ONE ASSET ROOT, ONE RESOLVER, and every
   lane carrying all of it. `asset(name)` moved the "where are the
   bytes and what do I say when they are not there" rule out of eight
   guests into crates/kaya/src/assets.rs, and that is only true while
   nothing else resolves an asset for itself — so this refuses any file
   outside the core that spells a `guests/assets/...` path or reads an
   asset environment variable, with an EXEMPT table whose every entry
   carries a reason and must name a file that still exists. Beside it:
   every family under the root has a README saying what the files are,
   where they came from, their licence and how to regenerate them (an
   honest "nobody knows" counts, silence does not — the opaque MRT index
   filed under tools/ is the file that failed this and the reason the
   survey found anything); the root's listing is printed with its count
   and REFUSES A VERDICT below a floor, because a census that reads two
   files agrees with everything; each of the five lanes either stages the
   root as a UNIT or says at the site why it needs nothing, and a lane
   caught copying one FILE under the root is the shape this convention
   replaced; and every staging lane verifies what arrived BY HASH, since
   a size check passes the same-length corruption a half-written push
   produces. AND TWO CLAUSES ABOUT THE ARTIFACTS: the census
   tools/scenes/assets.steps freezes must equal the root's own listing —
   that scene is the only run-time observation that a lane staged the
   WHOLE root, and it means adding an asset reddens five lanes, so the
   gate turns that into ONE red naming the .steps file before any lane
   runs — and the APK's asset prefix is one string in the three files
   that spell it (the Kotlin reader, the gradle copy, the emulator
   runner), because Android is the one platform whose packaged assets are
   not files and therefore the one with a packaging layout of its own.
   THE PACKAGED BYTES THEMSELVES ARE CHECKED WHERE THEY ARE PACKAGED,
   by `apk_assets_verify` right after the assemble that wrote them, in
   both directions: a missing entry, and an EXTRA one, which is the half
   the census actually catches. Watched negatives doctor a shadow of the
   real tree with the substitution count printed),
   `tools/check-stubs.sh` (no runner wires a scene's legs while its
   backend still stubs the feature — depth-slice stubs compile, so
   only this cross-check sees the combination. A DEPTH STUB IS A CALL,
   `depth_stub("<scene>")` / `depthStub` / `kayaDepthStub(_:on:)`, never
   a sentence: as a free-form string the convention went four milestones
   unwritten by any backend, so the gate could only ever pass, and a
   companion check now fails any backend that refuses in its own words.
   check-steps reads the same call from the other side and stops
   demanding those legs, so between them the two state one rule: a
   scene's legs are wired on a runner IF AND ONLY IF that runner's
   backend has the feature. The Swift declaration names its platform,
   because that one file serves mac AND iOS),
   `tools/check-compose.sh` (KayaCompose.kt actually compiles — the
   swift-typecheck sibling; the emulator must never be the first
   compiler to see the Kotlin layer),
   `tools/check-detekt.sh` (dead code in the Kotlin sources; the
   COMPILER cannot serve here — K2 moved the UNUSED_* diagnostics into
   IDE inspections (KT-69698), so a computed-and-never-applied local
   compiles clean, which is how a dead lowering once shipped a false
   green),
   `tools/check-jni.sh` (every native a Kotlin or Java class declares is
   in a registration list. JNI's own check runs one way only: it fails
   loudly at attach for a registered native the class lacks, but a
   declared-and-unregistered one just waits, and the UnsatisfiedLinkError
   fires at FIRST USE — which is how `KayaRing.openPicked` sat in the
   desktop-only list for months, under a comment promising it was
   shared),
   `tools/check-build-id.sh` (the stale-artifact guard is live: each of
   the three compiled artifacts — libkaya, the SwiftUI interpreter, the
   Compose interpreter — carries the id of the sources it came from,
   the verifier rejects one carrying any other, and every lane verifies
   what it runs or ships before it runs or ships it),
   `tools/check-pins.sh` (every dependency resolved over the network
   names an exact version — gradle, nuget, SwiftPM, and the container's
   opam index, none of which has a lockfile the way cargo and nix do;
   the SwiftPM clause is the one whose false green cost a debugging
   round, see docs/traps.md),
   `tools/check-design-generation.sh` (BOTH macOS design generations stay
   on the mac lane: SwiftUI reads the MAIN EXECUTABLE's sdk stamp, so
   flake.nix's apple-sdk_26 keeps the kaya-linked legs modern while the
   vendor-built hosts — python3, dotnet, the zulu JVM — hold the compat
   side, which is where the Button measurement bug class lives and which
   nobody chose. It measures COMPILES rather than artifacts (two probes
   built on the spot, three hosts resolved off PATH the way the lane
   resolves them) and refuses a verdict unless all five stamps were read),
   `tools/check-symbols.sh` (every SF name in the mac interpreter's
   symbol table exists in Apple's own availability plist at or below
   kaya's floor — an SF Symbols 6 rename resolves on every machine the
   project has and renders BLANK on the floor, so NO scene can see it;
   its self-test perturbs doc.on.doc to the macOS-15 rename out of the
   real file, count printed, and demands the refusal on every run),
   `tools/check-keyed.sh` (the gate cache is honest: a change inside a
   gate's input set re-runs it, a change outside does NOT, a FAILED gate
   is never cached, KAYA_FAST unset consults nothing, and the three
   gates that read a built artifact are never keyed),
   `tools/swift-typecheck.sh` (the guests, the Swift bindings AND the
   SwiftUI interpreter — a gate named after a layer it does not
   compile has burned someone here; docs/traps.md),
   `tools/java-typecheck.sh`,
   `tools/check-ambient-tx.sh` (no guest opens a transaction inside a
   handler — the binding already did, and a guest that opens its own is
   CAMOUFLAGE: five of them hid a real Python defect behind green
   scenes for months),
   `tools/check-go-env.sh` (a Go guest reads the HOST's environment
   through kaya.Env, never Go's copy of it: in a c-shared library — the
   Android artifact — os.Getenv is EMPTY FOREVER while C's getenv reads
   the live one, and the failure is silent because an empty
   KAYA_SELFTEST is not an unknown scene name, it is the default arm.
   A parser rather than a grep, because every file the rule protects
   documents the rule),
   `tools/check-wheel.sh`, `python3 bindings/python/kaya_app_checks.py`.
   One gate sits outside the sweep because it needs docker — gates.sh
   carries it in EXCLUDED, with that reason, so it is excluded on the
   record rather than merely absent:
   `tools/check-gtk.sh` compile-checks the GTK backend, which
   check-targets structurally cannot (gtk-sys needs the distro's
   pkg-config world). Run it after any gtk.rs change — a green
   check-targets does NOT mean every backend compiles.
3. `tools/validate-mac.sh` — every scene × every language on the
   SwiftUI interpreter, the one macOS backend (opens windows briefly;
   needs a logged-in GUI session).
4. The cross-platform matrix, before any feature is called landed:
   `tools/validate-all.sh` — ALL FIVE lanes concurrently by default
   (bounded by the slowest lane — ~7 minutes warm as of 2026-08-17,
   growing with the scene roster; ratified 2026-07-22). `--serial` for the special cases: single-lane
   benchmarking, debugging under contention, recording mode. The
   lanes remain individually runnable (`tools/validate-linux.sh`,
   `tools/ios/run-sim.sh`, `tools/android/run-emulator.sh`,
   `tools/deploy-win.sh akhil@192.168.64.2 all`;
   `tools/probe-env.sh` checks all environments). Fix-forward if a
   platform fails.

## Sequencing pattern for features

Depth then breadth: land the protocol + one backend (SwiftUI on mac)
+ one binding (Rust) + the scene, get it green on mac, then fan out
backends and bindings in parallel, then run the full matrix. Between-phase gates
keep half-landed states honest — some gates (check-verbs,
check-sugar-surface) are DESIGNED to stay red mid-milestone, holding the
remaining work open; that is not a regression.

## Interpreter backends are the historic miss layer

SwiftUI (swift/KayaSwiftUI.swift) and Compose
(android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt) re-implement the
harness verbs and carry private copies of wire constants, string-matched
rather than compile-checked. tools/check-verbs.sh now enforces coverage,
but when adding anything new, verify all four layers in BOTH files:
constants, apply arm, render/model, step-verb arm.
