# Working on kaya — agent operating rules

<!-- Mirrored as AGENTS.md; edit both together. -->

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
- New tools/ scripts are written in PYTHON FIRST, on the kaya_gate
  prelude (ruled 2026-08-31, after the gate tier's conversion measured
  its wins) — shell remains only for the launcher shapes: in-container
  and in-toolchain payloads, the guest-side .cmd schtasks stubs, and
  thin wrappers whose consumers are still shell, each such choice
  stated where it stands. Nothing new joins a porting backlog.
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
- Every cargo invocation carries `--locked` (check-shell enforces it
  in shell, check-python's rule 11 in the converted gate bodies):
  a bare build may rewrite Cargo.lock mid-run, and the lane then goes
  green against a dependency graph nobody chose.
- A built artifact carries the id of the sources it came from
  (tools/build-id.py). Anything a lane runs or ships gets
  `--verify`'d first — that is the mechanical version of "check the
  build's exit first", and it holds when nobody remembers to.
- `KAYA_FAST=1` skips any gate whose declared inputs have not moved
  since it last passed (tools/keyed.py; input sets and the reasoning
  live in tools/build-id.py's GATES). For the INNER LOOP only — the
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

1. **Uniform binding semantics.** kaya has 9 guest-language bindings
   (Rust, Python, Go, C#, Java, Swift, OCaml, Haskell, JS) plus a C floor.
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
   `tools/check-diagnostics.py` holds the shape of that — one answer, or
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
   the next person to guess what to search. `tools/check-ledger.py`
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
   core's unit tests ON THE GUEST as well (tools/deploy-win.py's
   unit-tests phase, filtered to `capi::picked_tests`): the Windows half
   of the core — the HANDLE arms of protocol.rs's
   raw_handle/file_from_raw — is code no unix run compiles, and the one
   test of the redemption path had `#[cfg(all(test, unix))]` on it for
   four milestones. The phase refuses unless the number that passed
   equals the number of `#[test]`s the module declares, because a filter
   that matches nothing exits 0 saying "0 passed". The rest of the suite
   is 309/312 on that guest; the 3 are POSIX assumptions in harness
   tests, and fixing them is what widens the filter.
2. Fast gates. `tools/gates.py` runs ALL of them and is the only thing
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
   — each is standalone. `tools/check-gates.py` holds this prose list,
   gates.py's list and validate-mac's delegation to ONE census and fails
   naming both sides of any disagreement; the three had already drifted
   by four gates the day it landed. What each gate is for:
   `tools/gen-header.py --check`, `tools/gen-bindings.py --check`,
   `tools/gen-guests.py --check` (compares what the generators produce
   against the WORKING TREE and puts every byte back — snapshot,
   regenerate, diff, restore, and a refusal if the restore left the tree
   changed. It used to regenerate in place and diff against git, which
   silently reverted any hand-edit to a generated file and then called
   the tree clean),
   `tools/check-steps.py`, `tools/check-shell.py`,
   `tools/check-python.py` (check-shell's opposite number, and the
   gate the 2026-08-27 ruling asked for: the gate BODIES are python
   now, imported against tools/lib/kaya_gate.py — never a launcher,
   so every gate stays standalone-runnable. That retires the `$?`
   class and puts eleven rules in its place, each mapping to a defect
   this repo has already been bitten by ONE SURFACE OVER: no
   swallowed exception (a caught-and-dropped one is the new false
   green), no shell=True or os.system (the sed/awk rule's
   descendant — a filename with a space must not become two words),
   an explicit `encoding="utf-8"` on every text read and write (the
   javac -encoding trap, which bites hardest on the Windows guest),
   NO LITERAL-ZERO EXIT (a gate leaves by falling off the end or
   through its verdict; `sys.exit(0)` in the middle is the false-PASS
   class with a keyword), every `walk()` paired with a
   `counted(..., floor=)`, `re.subn` only through the prelude's
   count-printing `doctor()`, the five-line import header held
   BYTE-IDENTICAL (check-mirror's job description, on the lines that
   replace SIX drifted copies of the dev-shell preamble — one of
   which printed ONE sentence for BOTH causes), and `ast.parse` over
   every body, which has no analogue today: a SyntaxError in a
   rarely-taken heredoc branch was invisible until that branch ran,
   and COMMAND HYGIENE FOLLOWING THE COMMAND INTO PYTHON — cargo
   --locked, javac -encoding, no sed/awk, ffmpeg -nostdin, read
   from argv lists AND from embedded shell in strings, because the
   conversion moved twelve such invocations out of check-shell's
   *.sh population where they were policed by nothing (audit
   2026-08-31), AND A SCRIPT A BODY NAMES EXISTS, with no `.sh` name
   composed at run time — the shim removal's own guard: the word sweep
   that renamed 1,405 citations could not see an f-string appending
   `.sh` to a gate's name, and three lanes died at their first step on
   the matrix that followed (2026-09-02); a self-test's deliberate fake
   is exempt by name with its reason, and held to still being named
   and still absent. Rules 1, 2 and 4 come off `ruff` for free, which
   is why ruff joined the flake. A GATE IS ITS `.py` FILE, run
   directly — executable, python shebang, the dev-shell check inside —
   so `tools/check-steps.py` is the whole invocation; the two-line
   `.sh` shims that bridged the docs' citations through the conversion
   went on 2026-09-02, every citation renamed with them. It also runs
   the prelude's OWN negatives — the fingerprint against the real
   shell pipeline, both dev-shell sentences, a perturbation that
   applied nothing, the census floor, scratch surviving nothing —
   because the file every converted gate imports must prove its
   refusals somewhere nobody can skip. Eighteen watched negatives,
   counts printed, red demanded on every run),
   `tools/check-mirror.py` (CLAUDE.md and AGENTS.md are true mirrors
   modulo the line-3 comment — they drifted once, silently, for two
   milestones),
   `tools/check-gates.py` (the drift sibling of the above, one file over:
   the gates this paragraph names, the gates gates.py runs and the ones
   validate-mac reaches must be one list. Its census clause is the part
   that bites — every gate script on disk is either in the sweep or in
   gates.py's EXCLUDED table WITH A REASON — and it is what would have
   caught the four gates this paragraph was missing while the lane ran
   them. It also pins validate-all's launch order: ALL FIVE platform lanes
   start together before the runner waits for Android's recorded lane pid;
   the one gate sweep starts at niceness 10 after Android exits while any
   longer lanes continue. It holds the runner and environment probe to the
   same four-phone pool; its self-tests watch lane count, pool width,
   concurrent platform launch, pid provenance, single-sweep shape and
   niceness red),
   `tools/check-ledger.py` (docs/deferred.md may not disagree with
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
   `tools/check-doc-refs.py` (the other half: every path-shaped
   reference in every tracked .md must exist. Globs are resolved and
   must match something, brace groups are expanded member by member, and
   a `<placeholder>` names a family rather than a file. A sentence that
   must name what the tree no longer has says so ONE way — struck,
   quoted inside a fenced block, or marked `(gone)` — and the exemption
   counts are printed on every run, with a refusal if they ever
   outnumber the checks),
   `tools/check-case.py` (every tracked path matches the filesystem's
   case exactly. macOS is case-insensitive and Linux is not, so a Haskell
   guest created as `Background.hs` against a cabal stanza reading
   `background.hs` built locally, went green on mac, and would have died
   on the lane furthest from the change, after a full matrix),
   `tools/check-targets.py` (cross-compiles every cfg'd backend, in BOTH
   feature configurations — it once reported "windows OK" while the
   windows lane failed to build the WinUI accessibility read, which
   only the harness config compiles. LINUX IS ITS HOLE, since gtk-sys
   needs the distro's pkg-config world, so it also text-checks that every
   backend's Stage impl names every required trait method: a trait method
   missed in gtk.rs alone used to survive every fast gate and die in the
   matrix),
   `tools/check-sugar-surface.py` (every widget kind has a constructor
   in all 9 bindings IN BOTH CONSTRUCTION ZONES, AND every window prop
   has a sugar spelling in all 9 — the generic floor spells a prop
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
   `capabilities` QUERY in all nine, one NAMED BOOLEAN per bit
   (`aux_windows` and its casings) in all nine, and the bit NUMBER
   against the core's own — five bindings have no header to read
   `KAYA_CAP_AUX_WINDOWS` out of and write the number themselves, which
   is the file-modes trap one surface over, and the three that DO read
   the core's constant (Rust, Go's cgo, Swift's bridging header) are
   checked for still naming it rather than quietly becoming copiers.
   AND THE TABLE SURFACE SINCE 2026-08-21, `columns` and `on_sort` in
   all nine: a table is not a KIND but a For with a header, so neither
   the constructor sweep nor the window-prop sweep can see it while the
   wire records reach every binding through the generator whether or
   not a guest can spell either. The handler rides the declaration
   wherever the binding's own click does — Python's `on_sort` is a
   KEYWORD on `columns`, OCaml's a labelled argument, Go's and Rust's a
   chained call — and is app-registered in the registry family (C#,
   Java, Swift, Haskell), which is why the eight patterns are written
   out rather than derived from one casing rule.
   AND THE ROW'S OWN FIELDS SINCE 2026-08-25, which is what a table
   inside a row template is FOR: the record-schema constructor must
   stand in the TEMPLATE zone (the only scope a nested collection may be
   declared in) and narrowing the handle to one stamped copy must KEEP
   the element type, or every record mutation is out of reach and the
   rows stay scalar. Both points, all eight, out of the block that owns
   them — six bindings spell the typed narrowing exactly as the untyped
   one and are told apart only by the receiver's type. Fourteen watched
   census reds beside the Haskell four, each a shape that COMPILES and
   lies.
   AND THE SIZE-POLICY SURFACE SINCE 2026-08-28, which is neither a KIND
   nor a WINDOW PROP and so was invisible to both sweeps above while TX
   47 and occurrences 20/21 reached all eight bindings through the
   generator: `fixed`, `on_draw` and `on_tick` in every binding's own
   handler idiom (chained on five, keyword arguments on Python's
   `canvas`, labelled on OCaml's, a Build action plus two App-registered
   handlers on Haskell's), `scale` with NO spelling anywhere because it
   is what a canvas that declares nothing gets, and the TEMPLATE ZONE
   REFUSED — by type where the zone has its own handle, and in one
   BYTE-FROZEN SENTENCE, compared FLATTENED, in the two whose single
   handle serves both zones. Sixteen watched census reds plus the
   sentence's own),
   `tools/check-universal-props.py` (the lowering-side sibling: every
   backend applies the universal a11y props to every kind — Compose
   per-arm, SwiftUI's one wrapper unbypassed, GTK/WinUI's apply arm
   still keyed on the prop alone),
   `tools/check-roles.py` (the role vocabulary reaches every backend:
   `MENU_ROLES` is one line, it is not in the spec hash, and adding an
   entry regenerates nothing — so before this gate a role could ship with
   the root accepting it and all four backends ignoring it. RED BY DESIGN
   across a fan-out; the role joins the vocabulary first and the arms
   follow),
   `tools/check-native-undo.py` (the two native-tier undo guards that NO
   shared scene can fail — both sit inside a SECOND consecutive native
   walk, which the routing makes unreachable, and each was broken with
   the lane watched staying green. The scene cannot be fixed to reach
   them, so static pairing is the only wall available),
   `tools/check-diagnostics.py` (a why-not may not print a sentence it
   cannot NOT print. Any function named `*WhyNot`/`*why_not`/`*Reason`
   is read as a diagnostic by that name alone; one answer, or an answer
   after the early-out that interpolates nothing, is a sentence the
   reader will believe for every cause it does not name — which is what
   `kayaOpenPanelWhyNot` did for months, twice sending someone after
   macOS activation rules. Its self-test splices the pre-fix body back
   in from git and requires the red),
   `tools/check-diagnostics.py` (a why-not may not print a sentence it
   cannot have measured — see invariant 3. The shape it can see is a
   failure path with ONE answer, or an answer that interpolates nothing:
   such a sentence is printed for every cause it does not name, and it is
   believed),
   `tools/check-harness-ceiling.py` (THE HARNESS LOSES LEGIBLY: every
   step is entered with a CEILING, and once a verdict is published the
   process leaves within the GRACE whether or not the platform's exit
   path runs — one rule, all three harnesses. A step's retry deadline is
   read only AFTER the step returns and every step blocks in a hop to
   the platform's UI thread with no timeout of its own, so a saturated
   app printed NOTHING, no verdict and no timeout sentence, until
   something outside killed it (measured on four platforms 2026-08-24,
   docs/measurements/choke-*-2026-08-24.txt; on the mac lane that
   something is `timeout 120`, a KILL that takes the log with it). NO
   SCENE CAN FAIL THIS — the wedge would have to happen on every
   platform at once and would then measure nothing else — so, like the
   native-undo pair, a gate is the only wall available. The static
   clause holds the two numbers equal in all three, the arm INSIDE the
   script runner carrying the step itself (a fixed string names every
   step the same), the publish over the exit hop, and ONE sentence
   compared FLATTENED, since Rust's line continuations and the
   interpreters' `+` splices spell that text three ways. The macOS
   clause is check-empty-child's shape: the interpreter's OWN watchdog,
   cut out of KayaSwiftUI.swift by the gate and compiled with
   tools/checks/swiftui-wedge.swift, run against a REAL wedged main
   thread — with a ceiling that can never expire watched reporting the
   silence. The Rust half's runtime proof is in the unit suite instead,
   where a wedged MockStage read leaves a child process under its own
   verdict),
   `tools/check-empty-child.py` (ONE NODE IS ONE WIDGET, even when its
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
   `tools/check-pane-ladder.py` (the macOS pane ladder, live: macOS has
   no compact mode to defer to, so kaya's own arithmetic decides how
   many of a three-pane window's columns fit — and the MIDDLE rung is
   observable nowhere else, because the platforms legitimately disagree
   at every width inside check-steps' panes band, so no shared scene may
   sample it. The static clause refuses any column MINIMUM declared to
   SwiftUI — a declared minimum becomes the WINDOW's floor, collapse can
   never fire, and resize_window silently no-ops, all measured
   (docs/multicolumn-plan.md MECHANICS AMENDMENTS). The runtime clause
   is check-empty-child's shape: the interpreter's own source compiled
   with tools/checks/swiftui-pane-ladder.swift and run — the rung
   arithmetic including content+detail < 600, which is what keeps the
   bare expect_panes invariant true at every regular width, the
   edge-triggered command rule the sidebar toggle depends on, and the
   REAL NSSplitView walked 1400 -> 700 -> 1400 counting visible
   columns),
   `tools/check-table-tier.py` (the table's TIER ROUTING, which no device
   can assert: decision 5 took the size class out of every table
   observable, so the native and the synthesized tier present identical
   bytes and a leg cannot name the one that drew it. The proof used to be
   a one-arm perturbation with the other device's leg watched staying
   green, redone by hand whenever the routing moved (docs/traps.md). The
   rule is a pure function of width and availability now, so the static
   clause holds KayaTableSurface as the split's ONLY caller and the rule
   free of `#if` and of the environment — a rule compiled per platform
   cannot be driven on the mac at all — and reads the two one-line arms of
   `widthClass`, the environment's single reading, the iOS one most of all
   because it is the line no host that runs this gate executes. The
   runtime clause is
   check-pane-ladder's shape: the interpreter's own source compiled with
   tools/checks/swiftui-table-tier.swift and run, the whole truth table
   (mac native, iOS compact synthesized at ANY availability, iOS regular
   native only at or above TableColumnForEach's floor) plus a REAL
   KayaTableSurface in an NSWindow with the NSTableView the native tier
   is made of found in its view tree. The same probe holds the geometry
   half too: viewport, cells and assigned track share the current table
   generation; every batch, native resize and USER-ROUTE MODEL WRITE
   (`kayaUserWrite`) invalidates it before acting; and a generation-keyed
   reporter republishes even after a same-size resize. The generation is
   the STORED epoch and the static clause refuses a walk in it — the
   recursive subtree hash it replaces was 41% of the mac main thread at
   100k rows and caused the 37% of observation bookkeeping beside it
   (docs/measurements/choke-macos-2026-08-24.txt), so a model-derived
   generation is a measured defect, not a style. Beside it a census: every
   assignment to the interpreter's own `text`/`checked`/`value` is inside
   kayaApply, inside a kayaUserWrite block, or in an EXEMPT table with a
   reason that must still match a real site. The watched shadows remove
   each link separately. What no gate holds is whether a PHYSICAL device
   reports the size class the simulator did),
   `tools/check-canvas-blit.py` (KAYA RASTERIZES, BACKENDS BLIT — the
   canvas architecture's one rule (docs/canvas-plan.md §1.1), in the
   three places NO SCENE CAN FAIL. A backend that interpreted a draw op
   would draw THE SAME PICTURE, because the hash is taken of the core's
   raster and expect_ink samples pixels that would still match — so the
   lowering design the plan killed could reintroduce itself one arm at a
   time with every lane green. The rule is held statically: the two
   widget backends may not name the op vocabulary at all, and the two
   interpreters, which carry private copies of the numbers, may name one
   only at its definition and in the one list that keeps the compiler
   from calling them unused. Beside it the PIXEL FORMAT each backend
   declares, by name — GTK's R8g8b8a8Premultiplied and Android's
   ARGB_8888 are tiny-skia's layout verbatim, SwiftUI says so with
   premultipliedLast|byteOrder32Big, and WinUI is the ONE arm that
   swizzles — because the scene catches a channel swap only at a probe
   point whose colour is ASYMMETRIC, and a scene sampling greys would
   pass a red-blue swap on five lanes. And the SCALE: every lane runs at
   1.0 or at a scale its platform states exactly, so a backend that read
   the ROUNDED scale, or reported none at all, is invisible to all of
   them — which is GTK's own trap, since gtk_widget_get_scale_factor
   "returns the next higher integer value" under fractional scaling.
   Eleven watched negatives on doctored copies, counts printed; two of them
   caught the gate's own first draft, whose comment-stripping shifted
   every line number and whose block reader stopped at the first bracket
   it found rather than the one at the block's indent),
   `tools/check-appearance.py` (THE APPEARANCE OVERRIDE IS INERT UNLESS
   ASKED FOR, AND HONEST WHEN IT IS. `KAYA_APPEARANCE=light|dark` makes ONE
   PROCESS adopt an appearance through each platform's own supported
   override — NSApp.appearance, overrideUserInterfaceStyle, libadwaita's
   forced colour scheme, FrameworkElement.RequestedTheme, and on Android
   the window background plus LocalConfiguration's night bits — so the
   dark half of
   `expect_ink`'s frozen string is a leg on a light desk instead of a whole
   lane re-run with the machine's own setting flipped. NEITHER HALF IS
   VISIBLE TO ANY LANE: an override installed with the variable UNSET would
   move every leg to a default that is light, which is what every lane host
   already is, and a backend that reported the VARIABLE instead of reading
   its toolkit back would make the dark leg self-fulfilling — passing with
   the window still light, which is the exact bug the dark leg exists to
   catch. So the guard must DOMINATE each install site rather than merely
   share its file, and no reporter may derive its mode from the variable.
   Patterns are call-shaped and read comment-stripped code, and a guard
   must dominate its call IN THE SAME FUNCTION BODY: two of its own
   negatives first passed because the night-mode call and
   `kayaAppearanceOverride()` are named in the PROSE beside their calls,
   and a pure character window later called a real guard absent.
   ANDROID IS THE ONE PLATFORM THAT NEEDS TWO INSTALLS, and the gate
   demands both plus the absence of the mechanism they replaced:
   `UiModeManager.setApplicationNightMode` moves the app's resource
   configuration, which RELAUNCHES the activity — `onCreate` then runs
   twice in ONE process, which is how that call cost the dark leg three
   deaths at ~63s with no verdict, measured on the android lane
   2026-08-27. The second mount survives now (KayaCompose.mount is
   re-entrant, and the android lane's `remount-*` legs hold it), but a
   knob that relaunches the window to say one word about the appearance
   still rebuilds every leg's surface. So Compose sets the window
   background out of the SAME
   `-night` theme the system would have picked, and provides
   `LocalConfiguration` with the night bits forced; either half alone is
   the measured half-dark app D1 exists to have fixed.
   AND THE READ'S SCOPE MUST MATCH THE OVERRIDE'S, which is the iOS
   clause and the rule the other three obey for free: macOS overrides
   `NSApp.appearance` and reads `NSApp.effectiveAppearance`, both APP
   scope, so they cannot drift — while iOS overrides per WINDOW and
   `kayaCanvasAppearance` read `UITraitCollection.current`, a
   process-ambient value UIKit defines only inside a trait callback or a
   view update. That function runs on the HARNESS THREAD with no view in
   hand, so it reported the SYSTEM's light while the raster used the
   window's dark: `ink light 16181C/2B3B4F`, stable across a boot rather
   than flickering, green for many runs and then red twice (ios lane,
   2026-08-27). It reads the window's own `traitCollection` now, which is
   still a toolkit read-back. The gate refuses `.current` inside that one
   function and demands the window read; the file's two OTHER ambient
   reads are deliberately untouched and audited, since `kayaBrandTint`
   and `kayaPlatformFont` are reached only from view bodies where
   `.current` is exactly what SwiftUI set.
   Thirteen watched negatives, counts printed. The runtime halves are the legs:
   `canvas-*` is the unset proof and `canvasdark-*` the set proof, on all
   five lanes),
   `tools/check-abort.py` (uniform abort
   semantics, all languages),
   `tools/check-tx-liveness.py` (a transaction is usable only inside
   the build or handler that made it, on the app thread — the HANDLE
   bindings refuse a closed one at a single write chokepoint, the
   AMBIENT ones have no handle to invalidate and check the thread
   instead. The failure it guards is SILENT: a write through an
   already-submitted transaction vanishes with no error, which Go
   shipped for months because its check lived on two chains and not on
   the hundred other callsites.
   CLOSED WAS NEVER THE WHOLE RULE, and until 2026-08-21 this gate
   asked the handle bindings for that half alone: a transaction still
   OPEN, written from a thread the handler spawned, passed every
   clause, and a background Build opening one of its own reached no
   chokepoint at all — both race the app thread's model in silence. So
   Go, Java, C# and Swift (the HANDLE bindings) now check the thread
   at that same chokepoint AND at the build entry, printing the same
   error sentence the ambient bindings (Python, OCaml, Haskell) do, and
   the gate's wrong-thread census reads the four bodies rather than
   grepping the name — `alive()` is also the ASSET handle's liveness
   check in Java and Swift and comes FIRST in both files. Four
   self-tests perturb copies, counts printed, red demanded on every
   run), `tools/check-verbs.py` (every harness verb
   and wire constant present in BOTH interpreter backends — plus the
   spec hash pinned against bindings/c/kaya_wire.h, the
   byte-compared-verdict rule, the vtable rule, and the
   stamped-observation rule.
   THE CANVAS VOCABULARIES JOINED 2026-08-26, and they are the reason
   the constant sweep now reads a TYPE as well as a prefix: draw_op,
   paint, fill_rule, text_align and text_baseline ride the op stream as
   i64, so twenty-one hand-copied numbers in two interpreters sat
   outside every gate — check-symbol-parity is symbol-only and this
   sweep's alternation named neither the prefixes nor the width. It
   refuses a reader that finds fewer than twenty-one, because a census
   that reads nothing agrees with everything.
   AND THE INK TOLERANCE, ruled 2026-08-26: `expect_ink` compares within
   ±1 PER CHANNEL because a macOS window's backing store carries the
   DISPLAY's profile and reads the core's D2E3F7 back as D2E2F7 while
   Android reports the core's own bytes, so no one frozen string can
   exact-match both (docs/canvas-plan.md §7.2, docs/traps.md). Three
   harnesses hand-write that number and this PINS ALL THREE AT THE RULED
   VALUE rather than merely holding them equal — copies drifting APART
   would eventually redden a lane, while copies drifting TOGETHER makes
   every ink assertion quieter with nothing anywhere slower or redder.
   A second clause refuses a tolerance nothing calls. Four watched
   negatives, counts printed.
   AND THE AX SPELLING, ruled QUOTED 2026-08-27: an observation IS the
   byte-compared verdict text, and `expect_ax` was recorded two ways —
   harness.rs (`{want:?}`, Rust Debug) and Compose quoted it, SwiftUI
   left it bare, so the one verdict nothing compared across platforms
   was the accessibility one. NO LANE CAN SEE IT: every runner greps the
   verdict for `KAYA_SELFTEST: OK` and never diffs its text, so the
   spellings sat green for months. The census reads each emitter out of
   its OWN ARM in all three harnesses and flattens every interpolation
   to `<v>`, since three languages spell interpolation three ways; it
   holds the observation AND the `wanted` failure sentence, and covers
   `expect_ax_hint`, which carried the identical divergence. An arm it
   cannot read is a finding that names it, never a skip — anchoring on
   `Step::ExpectAx(` alone matches harness.rs's PARSER first and finds
   ZERO observations there. Five watched negatives, counts printed.
   AND THE METRICS CLASS CHANNEL, ruled 2026-08-31 (adaptive-layout
   D8): iOS is the one platform whose size class the platform itself
   decides, and the only route it reaches the core is
   KayaWindowMetricsReporter's kaya_window_metrics report — NO lane
   can see that read, because the simulator pool is phones, where
   deriving from the width answers compact exactly as the platform
   does. The reporter's block is held to the shape (environment read,
   both classes mapped, every report passing the DERIVED class, a
   re-report on class change, the mac arm answering NONE alone) and
   wire.rs's 600-point boundary is PINNED at the ruled value, since
   the scenes hold it only to (560, 900]. Six watched negatives,
   counts printed, plus the wiring itself watched red once on the
   real file),
   `tools/check-file-modes.py` (the file-mode NUMBERS agree with the
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
   `tools/check-app-identity.py` (ONE declared identity, and every
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
   `tools/check-assets.py` (ONE ASSET ROOT, ONE RESOLVER, and every
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
   the census actually catches.
   AND THE LEDGER NETS TO THE BOOK since 2026-08-26: the portfolio's two
   screens claim the same positions, so guests/assets/market/transactions.csv
   is GENERATED to net to guests/python/portfolio.py's BOOK — per account
   and per ticker, buys minus sells, dividends carrying no quantity — the
   generator reads that book by ast and refuses to write a file that does
   not tie. This clause holds the ARTIFACT ON DISK to the same book,
   derives the scene's `label@net` lines from it, and refuses any net line
   whose money the dashboard does not also say: a tie-out asserted on one
   screen ties nothing (invariant 3, docs/portfolio-plan.md §6).
   Watched negatives doctor a shadow of the
   real tree with the substitution count printed),
   `tools/check-staging.py` (a wired leg's artifact is in the staging
   derivation its own runner declares: a mac `$RUST_GUESTS` reference
   outside SCENES/DEPTH_SCENES, a windows suite with no launcher or a
   launcher naming an exe no list builds, a leg whose scene script or
   python guest file is gone — each named with the list to extend. The
   measured instance: the windowed-rust mac leg was wired hand-queued
   and absent from the derivation, and the miss cost a full matrix to
   learn what this census says in seconds. Launchers are the artifact
   truth on windows — listdetail runs split.exe, two scenes one guest),
   `tools/check-c-ids.py` (ONE ID SPACE FOR WIDGETS AND TEMPLATE NODES,
   on the one tier with no allocator to hold it. Every binding mints
   both from one monotone counter; the eight template-declaring C
   guests hand-author their numbers, and crates/kaya/src/scene.rs keeps
   `widgets` and `template_nodes` as SEPARATE MAPS on purpose — so a
   collision is legal at the core, renders correctly and ships. All
   eight overlapped until 2026-08-25 with every lane green, which is
   why the gate's first negative is that shipped state itself: the
   eight guests one revision before the renumber, all refused. It reads
   the CALLS, never the `W_`/`N_` names — comments and string literals
   are blanked, then create_widget / create_for / create_when /
   template_end are walked in source order against a template-nesting
   depth, which is scene.rs's own division of the two maps. A
   name-keyed census would refuse guests/c/feed.c and
   guests/c/reorder.c today: their N_POSTS and N_ITEMS are row COUNTS
   whose numbers collide with real widget ids. An id it cannot fold to
   a number is a finding naming the site, never a skip),
   `tools/check-c-bounds.py` (THE C FLOOR REFUSES PAST ITS CAP INSTEAD OF
   SMASHING PAST IT (ruled 2026-08-26). `KayaTx` was `{buf, len}` — a Go
   slice header missing its third field — and every packer wrote through
   the bare pointer, so a long string was an unchecked memcpy into the
   caller's array. The seven sugar bindings all encode into a growable
   buffer, so C was the one surface where overflow was undefined
   behaviour rather than an error (docs/deferred.md's
   java-record-ceiling entry, which recorded it and left the ruling
   open). NOTHING ELSE CAN SEE IT: every in-tree guest sizes its buffers
   correctly, so the wire bytes are identical either way and no scene,
   lane or capture is any different — the unchecked memcpy shipped from
   milestone 0 under green lanes. TWO MODES, THE WALL PRIMARY:
   tools/checks/c-tx-cap.c mmaps exactly cap writable bytes with the next
   byte unmapped, so a one-byte overrun is a FAULT and not a redzone
   heuristic, and with no runtime in it the linux lane runs it unchanged.
   ADDRESSANITIZER IS THE COMPANION SINCE 2026-08-27, on the shape a wall
   cannot take — a plain malloc, whose next byte is another allocation,
   which is what a guest's buffer is. It asks for flake.nix's
   `kaya-asan-clang` BY NAME, because every nixpkgs clang below 22 has an
   ASan that hangs before main here and the shell's own would spend the
   whole ceiling saying nothing (docs/traps.md); a host without it runs
   the primary alone and PRINTS the skip, which self-test N5 cuts out of
   the gate and makes print on every run. Its build turns the wrapper's
   hardening OFF: `fortify` preempts ASan, and the same overrun then dies
   of a mute SIGTRAP or is not seen at all, so a companion wired naively
   would have been green and blind. The negative is the SHIPPED
   BUG: the same probe built against ee7bc41's pre-cap header, which must
   die of a signal in both walled modes where this one prints a sentence,
   and be a REPORTED heap-buffer-overflow in both heap modes. Beside
   that: a brace-depth parser holding every write through `tx->buf`
   inside a `kaya_wire_fits()` (a line pattern cannot — kaya_wire_begin's
   guard is two lines up), the refusal's TWO branches each naming both
   sizes (the kind is read back out of the record header, so the branch
   where even those 8 bytes were past cap has no kind to name and says
   so), and guests/c/Makefile's `-Werror=missing-field-initializers`,
   which is the wall on the path nobody can avoid: `KayaTx tx = {buf, 0}`
   still COMPILES against a three-field struct, reads cap 0 and refuses
   every record at run time, so the build is made to fail naming `cap`.
   AND NO OUTPUT BYTE MOVED, proven rather than asserted: the probe's
   repertoire — begin/end, u32, u64, pad, values, variant_schemas and a
   value of all five tags, which is everything a guest emits — is
   hexdumped under both headers and compared, 432 bytes identical.
   Four watched negatives, counts printed, each pointed at the mode its
   packer actually runs off the end in),
   `tools/check-stubs.py` (no runner wires a scene's legs while its
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
   `tools/check-compose.py` (KayaCompose.kt actually compiles — the
   swift-typecheck sibling; the emulator must never be the first
   compiler to see the Kotlin layer),
   `tools/check-detekt.py` (dead code in the Kotlin sources; the
   COMPILER cannot serve here — K2 moved the UNUSED_* diagnostics into
   IDE inspections (KT-69698), so a computed-and-never-applied local
   compiles clean, which is how a dead lowering once shipped a false
   green),
   `tools/check-compose-state.py` (a KayaSceneModel field a composable
   DRAWS FROM must be composition state: Compose recomposes on a
   `mutableStateOf` it read and never on a plain field, so `windowTitle`
   shipped plain for a milestone with the bar composing once and only a
   film caught it — the scenes read the task label, the other surface.
   Reads each `KayaSceneModel.<field>` inside every `@Composable fun`
   body, comments and strings blanked positionally first (a bare-word
   census reported `rows` and `labels` off prose and KayaNode locals),
   writes excluded (a composable STAMPING a field for the harness is not
   a draw read), against the model's own declarations; the six plain
   fields a composable may read are EXEMPT by name with a reason and
   must each still be read somewhere, since a stale exemption is the
   next stale audit — and the one ordering four of them lean on, the
   alert fields written BEFORE `alertId` in APPLY_PRESENT_ALERT, is read
   and held rather than assumed. Four watched negatives, counts printed,
   the first of them the shipped defect itself),
   `tools/check-jni.py` (every native a Kotlin or Java class declares is
   in a registration list. JNI's own check runs one way only: it fails
   loudly at attach for a registered native the class lacks, but a
   declared-and-unregistered one just waits, and the UnsatisfiedLinkError
   fires at FIRST USE — which is how `KayaRing.openPicked` sat in the
   desktop-only list for months, under a comment promising it was
   shared),
   `tools/check-build-id.py` (the stale-artifact guard is live: each of
   the three compiled artifacts — libkaya, the SwiftUI interpreter, the
   Compose interpreter — carries the id of the sources it came from,
   the verifier rejects one carrying any other, and every lane verifies
   what it runs or ships before it runs or ships it),
   `tools/check-pins.py` (every dependency resolved over the network
   names an exact version — gradle, nuget, SwiftPM, and the container's
   opam index, none of which has a lockfile the way cargo and nix do;
   the SwiftPM clause is the one whose false green cost a debugging
   round, see docs/traps.md.
   AND THE WINDOWS DOOR SINCE 2026-08-26, which is a curl and therefore
   invisible to the other four: tools/fetch-winappsdk.sh pulls five
   Windows App SDK packages out of nuget's flat container, and the
   .csproj clause cannot reach it because the three .csproj files in the
   tree are guest-side and tooling, not the backend. A curl names BYTES
   as well as a version, so that script records each package's sha256
   beside its version and checks it on every run INCLUDING the cached
   path — the cache is the half a version pin cannot speak for, the
   lesson deploy-win's version-keyed go check learned one machine over.
   The gate holds the shape (a literal version, a 64-hex hash, the
   verification unreachable-around) and then CUTS verify_sha256 out of
   the script and runs it against wrong bytes, since static text saying
   a hash is compared is not the comparison refusing. Eight watched
   negatives on doctored copies, counts printed; one of them found its
   own first draft doctoring the dev-shell fingerprint instead of the
   verifier, so an ambiguous pattern is a failed test too. A second
   tools/ script curling the same flat container is refused BY NAME,
   because reading one file by name is how this hole existed),
   `tools/check-design-generation.py` (BOTH macOS design generations stay
   on the mac lane: SwiftUI reads the MAIN EXECUTABLE's sdk stamp, so
   flake.nix's apple-sdk_26 keeps the kaya-linked legs modern while the
   vendor-built hosts — python3, dotnet, the zulu JVM — hold the compat
   side, which is where the Button measurement bug class lives and which
   nobody chose. It measures COMPILES rather than artifacts (two probes
   built on the spot, three hosts resolved off PATH the way the lane
   resolves them) and refuses a verdict unless all five stamps were read),
   `tools/check-symbols.py` (every SF name in the mac interpreter's
   symbol table exists in Apple's own availability plist at or below
   kaya's floor — an SF Symbols 6 rename resolves on every machine the
   project has and renders BLANK on the floor, so NO scene can see it;
   its self-test perturbs doc.on.doc to the macOS-15 rename out of the
   real file, count printed, and demands the refusal on every run),
   `tools/check-symbol-parity.py` (its sibling: ONE symbol vocabulary,
   SIX files. wire::SYMBOLS owns the (value, name) set and is not in
   the spec hash; GTK and WinUI name the wire constants so the compiler
   holds their values and the gate holds coverage, while Swift, Compose
   and the C floor copy the NUMBERS by hand — check-file-modes' trap
   one surface over — so there it holds value, name and coverage all
   three. Five self-tests perturb the real files in memory, counts
   printed, red demanded on every run — the fifth (a drifted C-floor
   number) added 2026-08-31 when the python conversion's probing found
   that clause had never been watched firing),
   `tools/check-accent.py` (the Windows accent near-no-op has a fast
   wall: Fluent fills read six DERIVED stops, never bare
   SystemAccentColor, so writing the bare key moves the text-selection
   highlight and nothing else and no lane can see it — this holds the
   emitted markup to exactly the six stops, self-tested both directions
   on every run; winui::tests' brand test is its rendered-output sibling
   on the windows guest's unit phase),
   `tools/check-table-card.py` (A TABLE BOUNDS ITS OWN EXTENT — one
   semantics, four spellings (ruled 2026-08-25). The mac's NATIVE tier
   has it from the widget and is out of the rule; GTK and WinUI each draw
   a flat card; the iOS SYNTHESIZED tier draws the INSET-GROUPED one —
   the Settings look, where the grouped ground behind the card is the
   whole boundary and there is no stroke at all — and COMPOSE draws
   Android's own answer to that same sentence, the SEGMENTED GROUPED
   CONTAINER: a header segment, androidx's 2dp gap, one container for
   every body row, corners BY POSITION (ListTokens.ContainerShape = 16dp
   at the group's true ends, ItemContainerExpressiveShape = 4dp at the
   boundary), and no stroke either, since nothing in the grouped idiom
   draws one. NO SCENE CAN FAIL
   THIS: the card is pixels, and every table
   observable — expect_columns, expect_rows, expect_column_edges,
   expect_window — answers identically with it gone, which is how all
   three shipped a table's OPENING grammar and never its close, running
   the last row into the label under it. So it holds three things a
   capture would otherwise be the only witness to: the card is THERE,
   it is FLAT (no shadow, no blur, no elevation — and on the two grouped
   tiers no stroke either) and its colours are the
   platform's own tokens rather than literals. The flatness clause reads
   the card's OWN BLOCK with comments stripped — all four files
   legitimately name shadows elsewhere, and a comment saying the card
   carries no elevation is the rule written down rather than a breach.
   AND WHICH LAYER WEARS IT, which is the clause a capture bought: the
   iOS card is CONTENT, inside the scroll clip, so it ends with the last
   row and scrolls with a tall table. Painted as the viewport's
   background — the first implementation — a three-row grown table ran
   white to the bottom of the phone, and no observable moved. So the
   face is read INSIDE the clip's block and the ground outside it, and
   both of a grown table's viewport writers are held to the cells' box,
   since the interior scrolls inside that clip. COMPOSE HAS THE SAME
   CLAUSE, in the shape its toolkit forces: no modifier there can draw
   two separated shapes, so the segments are laid-out CHILDREN of the
   table's own Layout — which already sizes itself to the whole extent —
   and the gate holds the two invariants that buys, that they are the
   LAST TWO children (every index in the measure block counts from the
   end) and the FIRST TWO PLACED (placement order is draw order, and a
   segment placed after the rows paints over them). Nothing on that
   modifier chain may paint or pad.
   AND WHERE IT MAY NOT REACH: the mac. The card is the synthesized
   tier's alone (a count in the file AND inside that tier's own block)
   and its numbers are zero on macOS, since the edge instrument subtracts
   what they say the card spends — a card wrapped around KayaNativeTable
   and a macOS arm that draws are each watched being refused.
   AND ON COMPOSE, NO HEADER RULE INSIDE A SEGMENT (ruled
   2026-08-26): the grouped idiom's separator IS the 2dp gap, and a
   HorizontalDivider under the header drew a second one nine pixels
   away and of a different width. Read out of the table's own content
   lambda, so the file's menu separators and the other three backends'
   native hairlines are untouched.
   59 watched negatives, counts printed, red demanded on every run),
   `tools/check-keyed.py` (the gate cache is honest: a change inside a
   gate's input set re-runs it, a change outside does NOT, a FAILED gate
   is never cached, KAYA_FAST unset consults nothing but RECORDS its
   passes, the gates that read a built artifact carry the artifact's
   REAL BYTES in their key (build-id.py's ARTIFACT_GATES; ratified
   2026-08-20 — sources alone cannot vouch for target/), and
   check-build-id alone is never keyed, because caching the staleness
   gate's answer is the defect it exists to find),
   `tools/swift-typecheck.sh` (the guests, the Swift bindings AND the
   SwiftUI interpreter — a gate named after a layer it does not
   compile has burned someone here; docs/traps.md),
   `tools/java-typecheck.py` (the binding and every java guest compile —
   AND, since 2026-08-26, the one clause in that file that is RUN: a
   record LARGER THAN THE ENCODER'S FIRST BUFFER encodes and reads back.
   Java's encoder was a fixed `ByteBuffer.allocate(4096)`, which capped
   EVERY record at 4064 characters of text or 252 wire values — the only
   binding of the eight that could not grow, and invisible to every gate
   because the ceiling is a THROW and no scene builds a big record. Its
   negative removes the growth from a COPY, prints the substitution count
   and demands BufferOverflowException by name; six refusal branches,
   all six watched firing, docs/deferred.md's java-record-ceiling entry),
   `tools/check-ambient-tx.py` (no guest opens a transaction inside a
   handler — the binding already did, and a guest that opens its own is
   CAMOUFLAGE: five of them hid a real Python defect behind green
   scenes for months),
   `tools/check-go-env.py` (a Go guest reads the HOST's environment
   through kaya.Env, never Go's copy of it: in a c-shared library — the
   Android artifact — os.Getenv is EMPTY FOREVER while C's getenv reads
   the live one, and the failure is silent because an empty
   KAYA_SELFTEST is not an unknown scene name, it is the default arm.
   A parser rather than a grep, because every file the rule protects
   documents the rule),
   `tools/check-wheel.py`, `python3 bindings/python/kaya_app_checks.py`,
   `tools/js-typecheck.py` (strict tsc over the JS binding and every
   JS guest — the compiler the guests never otherwise meet, since node
   strips their types and checks nothing; it also writes the workspace
   link the guests import through, and prints the census it compiled),
   `node bindings/js/kaya_app_checks.ts` (the JS surface's negatives,
   the python checks' twin, run in a worker because importing the
   binding on the main thread surrenders it to kaya_run;
   docs/js-plan.md §5).
   One gate sits outside the sweep because it needs docker — gates.py
   carries it in EXCLUDED, with that reason, so it is excluded on the
   record rather than merely absent:
   `tools/check-gtk.py` compile-checks the GTK backend, which
   check-targets structurally cannot (gtk-sys needs the distro's
   pkg-config world). Run it after any gtk.rs change — a green
   check-targets does NOT mean every backend compiles.
3. `tools/validate-mac.py` — every scene × every language on the
   SwiftUI interpreter, the one macOS backend (opens windows briefly;
   needs a logged-in GUI session).
4. The cross-platform matrix, before any feature is called landed:
   `tools/validate-all.py` — ALL FIVE platform lanes run concurrently by
   default (ratified 2026-07-22). After Android exits, the one
   `nice -n 10` gate sweep runs, so the wall is Android plus the sweep
   IN SERIES, not the slowest lane: on the accepted 2026-08-24 run the
   sweep's last ~83s ran with every lane already done (619s wall).
   `--serial` is for the special cases: single-lane benchmarking,
   debugging under contention, recording mode. The
   lanes remain individually runnable (`tools/validate-linux.py`,
   `tools/ios/run-sim.py`, `tools/android/run-emulator.py`,
   `tools/deploy-win.py akhil@192.168.64.2 all`;
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
rather than compile-checked. tools/check-verbs.py now enforces coverage,
but when adding anything new, verify all four layers in BOTH files:
constants, apply arm, render/model, step-verb arm.
