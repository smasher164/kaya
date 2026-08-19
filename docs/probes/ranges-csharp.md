# TEXT RANGES — C# ARM (guest + sugar)

Charter: docs/ranges-plan.md. Frozen contract: scratchpad/ranges-depth.md
(FROZEN CONTRACT). Units ruling: scratchpad/ranges-units.md.

Files this arm owns:
`bindings/csharp/KayaApp.cs`, `guests/csharp/RangesScene.cs`, plus the
two one-line registrations a C# guest cannot exist without —
`guests/csharp/Program.cs` (the selector switch check-steps reads) and
the `run ranges-csharp-swiftui` leg in `tools/validate-mac.sh` (added
after seeing the python and C arms had already added theirs in the same
block).

VERDICT: **DONE.** `ranges-csharp-swiftui` green twice consecutively;
five flip proofs, each with a counted substitution and each watched
FAILING; every restore sha256-proven.

---

## THE ARM'S ONE INTERESTING FACT

**C# is the language where the units ruling costs something.**
`match_indices` gives Rust UTF-8 byte offsets, which is kaya's unit, so
the Rust guest hands kaya the ranges it already had. `String.IndexOf`
gives .NET **UTF-16 code units**, and over this document — whose first
line is `line 00: 日本語 preface` — that is exactly SIX less from the
first match onward:

| match | UTF-8 bytes (kaya's unit, the scene's) | .NET `IndexOf` | what an unconverted offset covers |
| --- | --- | --- | --- |
| 1 | 57:62 = `alpha` | 51 | `e 02:` |
| 2 | 203:208 = `alpha` | 197 | `e 09:` |
| 3 | 753:758 = `alpha` | 747 | `e 37:` |

Six is not a crash and nothing refuses it: 51, 197 and 747 are valid
offsets, on character boundaries, inside the text, so all three of the
core's clauses pass and the highlight simply covers the wrong six
characters. **That is why the C# sugar takes a `TextRange` and not two
ints** — and the flip proof below is that exact bug, watched painting
`e 02:`.

---

## WHAT LANDED

### 1. `bindings/csharp/KayaApp.cs` — the sugar

**`readonly struct TextRange`** (beside `Widget`, the type it belongs
to). Half-open, UTF-8 byte offsets, two named constructors and no public
raw one:

| spelling | for |
| --- | --- |
| `TextRange.In(text, index, length)` | .NET char indices — the conversion, done once, in the binding. What an app reaches for, because `IndexOf` and `Length` are what it has. |
| `TextRange.Bytes(start, stop)` | offsets that ALREADY count bytes (a file the app read, a parser it ran). Named for its unit, because the only way to misuse it is to believe it takes chars. Refuses a negative, as the core does. |

`In` takes the TEXT as an argument rather than remembering it: a byte
offset means nothing without the string it indexes, and the string the
app searched is the only authority on what its own numbers meant.

**One guard inside the conversion**, and it is C#-specific for a
measured reason: a .NET index INSIDE A SURROGATE PAIR is the one error
the core cannot name, because by the time the range arrives the evidence
is gone — `Encoding.UTF8` encodes the orphaned half as U+FFFD, three
bytes where the character is four, so the offset that comes back points
into the middle of a character the app never meant to split. The core
DOES refuse it (its boundary clause cannot do otherwise), but it refuses
a number the conversion invented. `TextRange.In` refuses the INDEX
instead, in the unit the app was thinking in, naming the pair. Same
observable semantics as everywhere else (the range is refused), spelled
in C#'s idiom (`ArgumentException`) — invariant 1's shape, and there is
nothing to mirror in the four byte-native bindings, which do no
conversion at all.

**Three verbs on `Tx`**, beside `Focus` and `SetText`:

```csharp
public void HighlightRanges(Widget w, IEnumerable<TextRange> ranges)
public void SelectRange(Widget w, TextRange range)
public void RevealRange(Widget w, TextRange range)
```

- all three write through the `Records` property, never the raw
  `records` field — that is the tx-liveness chokepoint, and
  check-tx-liveness pins the raw-field count at exactly 2;
- `HighlightRanges` flattens to the count-prefixed `Values` list the
  record wants (start, stop, start, stop…) and passes `flat.Count / 2`
  as the count, so the core's "declares N but carries M offsets"
  assertion cannot fire from a C# miscount;
- `SetText` already existed (KayaApp.cs:1149) and already satisfied the
  fourth clause of `check_range_verb`.

### 2. `guests/csharp/RangesScene.cs` — the guest

A port of `guests/rust/ranges.rs`, same five lines of search
(`IndexOf`, `Ordinal`, forward, non-overlapping), same handlers, same
widget order (`textarea#0`, `label#0`, `button#0..3`).

Two things it does that the Rust guest does not need to:

- **the document is `string.Join("\n", …)` over 40 line literals**, not
  one verbatim string. The scene's offsets are ABSOLUTE, so a checkout
  or a deploy that translated this file's line endings would move every
  one of them. The separator is stated, so it cannot be translated.
  Verified byte-identical to the Rust guest's `DOC`: 813 bytes, sha256
  `443dfd613ec741f820f24177ff921a853d27ab6f91ade4c0bede67850c25834c`.
- **a byte-frozen-document guard at the top of `Run()`**: if the
  document is not 813 UTF-8 bytes the guest throws, naming the length
  and pointing at tools/scenes/ranges.steps. Without it, a corrupted
  document fails as `expect_highlights 61:66=lpha …` — numbers nobody
  can read back to a cause. Watched firing (flip 5).

### 3. Registrations

- `guests/csharp/Program.cs`: `case "ranges": RangesScene.Run(); break;`
  — the selector is what check-steps reads (`SELECTORS`, :631), and a
  guest class the switch never dispatches is exactly as broken as a
  missing file.
- `tools/validate-mac.sh`: `run ranges-csharp-swiftui …`, in the ranges
  block beside the rust, python and C legs. Without it the leg is
  something someone has to REMEMBER to run — CLAUDE.md invariant 3's
  named failure — and check-steps only demands legs for scenes in
  `SCENES`, which `ranges` will not join until every arm has landed.

---

## RESULTS

### The leg, green twice consecutively

Standalone, spelled exactly as the lane spells it (`KAYA_SELFTEST=ranges`,
`KAYA_LIB=$ROOT/target/debug/libkaya.dylib`,
`KAYA_SWIFTUI_LIB=$ROOT/target/swiftui/libkaya_swiftui.dylib`,
`KAYA_SELFTEST_SCRIPT` = ranges.steps minus comments), under the
fan-out's GUI lock, after rebuilding from the restored sources:

```
21:37:59  ranges-csharp-swiftui rc=0   scratchpad/green1.log
21:38:01  ranges-csharp-swiftui rc=0   scratchpad/green2.log
21:43:__  ranges-csharp-swiftui rc=0   scratchpad/green3.log  (re-verify)
21:48:44  ranges-csharp-swiftui rc=0   scratchpad/green4.log  } the FINAL
21:48:45  ranges-csharp-swiftui rc=0   scratchpad/green5.log  } shipped bytes
KAYA_SELFTEST: OK (0 matches, expect_highlights , 3 matches,
  expect_highlights 57:62=alpha|203:208=alpha|753:758=alpha,
  expect_selection 203:208=alpha, 753:758 offscreen, 753:758 visible,
  expect_highlights 57:62=alpha|203:208=alpha|753:758=alpha,
  expect_selection 203:208=alpha, textarea#0 focused, 0 matches,
  expect_highlights , expect_selection 820:820=)
KAYA_DIAG select_range refused: ime_composition (widget 2)
```

All 13 steps, byte offsets not UTF-16 offsets, D2's drop observed after
`type " z"`, D4's refusal observed at the composition. Both runs used
SwiftUI interpreter source sha256
`12c01d8ce9ef038de52c9d68dabeab8e309ec3ede40f052c0d58085a5f991275` —
the depth arm's proven one. (The iOS arm rewrote that file at 21:38:45
and the dylib was rebuilt at 21:38:53, i.e. AFTER both runs; a later
re-verification is at the end of this report.)

### The flip proofs — five, each watched failing

Driver: `scratchpad/cs-flip.sh` + `scratchpad/cs-perturb.py`. Every
perturbation is a counted substitution required to be exactly 1 (a
count of 0 exits 2 as a REFUSED proof, never a passed one); a
perturbation that fails to compile is an aborted proof, not a passed
one; every restore copies a baseline and compares sha256 against the
recorded digest. `git checkout` was never used.

| # | perturbation | subs | the leg's failure |
| --- | --- | --- | --- |
| 1 | `TextRange.In`'s conversion → pass the UTF-16 index straight through | 1 | `expect_highlights 51:56=e 02:\|197:202=e 09:\|747:752=e 37:, wanted 57:62=alpha\|203:208=alpha\|753:758=alpha` (twice) and `expect_selection 197:202=e 09:, wanted 203:208=alpha` (twice) |
| 2 | the guest's `t.HighlightRanges(editor, hits)` deleted | 1 | `expect_highlights , wanted 57:62=alpha\|…` (twice) |
| 3 | the guest's `t.SelectRange(editor, hits[1])` deleted | 1 | `expect_selection 0:0=, wanted 203:208=alpha` (twice) |
| 4 | the guest's `t.RevealRange(editor, hits[last])` deleted | 1 | `753:758 is offscreen, wanted visible` |
| 5 | one document line lengthened (the byte-frozen guard) | 1 | the GUARD fired before a window opened: `kaya guest: the ranges document is 822 UTF-8 bytes, not 813` |

Flip 1 is the arm's whole point: the covered-text half of the read
spelling turns "six off" from a number into `e 02:` — the six characters
before the match — which is why the depth arm put it there.

sha256, recorded before the run and re-proven after every restore
(KayaApp.cs was re-baselined for the last flip after the surrogate fix
below; the first five proofs ran against `ea88d800…`):

```
896274ccd3cc079040bee617773dce65e25c0a16b31f3d298692b788da4a1081  bindings/csharp/KayaApp.cs
d64197e68d68cb2284b4bf8a3337d037405794f06d8a4a0feed702287416a3ff  guests/csharp/RangesScene.cs
be71ce01d98c678045444777b133c7b2a792d6abd1f124295957b66b8516767e  guests/csharp/Program.cs
```

Flip 1 was **run again against the final shipped bytes** after that fix
(same counted substitution, same failure, restore proven against
`896274cc…`), and the green pair above was re-run after it — so the
proof and the pass are both about the file that ships, not an earlier
one.

### The conversion, checked at the unit level

The leg proves the conversion through the platform; these ten cases
prove it directly, compiling the REAL `bindings/csharp/**/*.cs` (a
throwaway csproj with the same glob and a `Main`, since deleted — the
binding's TextRange is same-assembly-visible):

```
IndexOf(alpha) = 51 (UTF-16)
ok  converted match: 57:62                     ok  whole emoji converts: 2:6
ok  prefix is identity on ASCII: 0:4           ok  after the emoji: 6:8
ok  empty range is a caret: 57:57              ok  negative bytes refused
ok  already-bytes escape hatch: 57:62          ok  out of range refused
ok  split surrogate refused: char index 3 is inside the surrogate pair at 2..4
ok  lone low surrogate is not a split: 2:5
CONV: OK
```

The last two are one finding: the split guard **must test both halves**.
An earlier version fired on the low surrogate alone, which (a) misreads
a lone low surrogate — ill-formed text the FFI boundary already owns —
as a split index, and (b) would have thrown from inside its own error
message, because `char.ConvertToUtf32` refuses the pair it is handed.
Fixed and both cases pinned above.

### Gates

| gate | result |
| --- | --- |
| `tools/check-sugar-surface.sh` | **OK** — and it is now GREEN OUTRIGHT (0 "has no sugar" lines), re-run against the final bytes: the csharp clause of `check_range_verb` passes, and the other six binding arms landed theirs while this arm ran. The gate the depth arm left red by design is closed. |
| `tools/check-tx-liveness.sh` | OK (the three new verbs go through `Records`, raw-field count still 2) |
| `tools/check-ambient-tx.sh` | OK (every handler uses the transaction it was handed) |
| `tools/check-stubs.sh` | OK (mac's backend does not stub ranges, so a mac leg is allowed) |
| `tools/check-shell.sh` | OK (after the validate-mac.sh leg addition) |
| `tools/check-case.sh` | OK |
| `tools/gen-bindings.sh --check` | OK (KayaApp.cs is hand-written; nothing regenerates over it) |
| `tools/gen-guests.sh --check` | OK |
| `dotnet build guests/csharp/kaya-guests.csproj` | rc=0, 0 errors, 39 warnings — all pre-existing CS8632 nullable-annotation warnings, none from this arm's files |
| `tools/check-steps.sh` | **FAILS, and NOT from this arm**: `scene "ranges" has no live legs in tools/linux/run-suites.sh` / `tools/android/run-emulator.sh`. The gtk and Compose arms removed `depth_stub("ranges")` from gtk.rs and KayaCompose.kt at 21:38 (mtimes), which is what makes the gate demand those runners' legs. It was green before those edits and is theirs to close. |

---

## SWEEP NOTE (invariant 2)

This arm's verdict for its language is **do** — all three primitives are
expressible in C# with no carve-out, and the one thing C# needs that the
byte-native bindings do not (a unit conversion) is in the binding rather
than in the app.

One cross-arm item the coordinator should reconcile: **the five UTF-16 /
scalar bindings each need a conversion, and each will have named it
something.** C# named the type `TextRange` and the conversion
`TextRange.In(text, index, length)`. The semantics is fixed by the
protocol (a pair of UTF-8 byte offsets) so any spelling is conformant,
but `tools/check-sugar-surface.sh` currently sweeps only the four VERBS
— nothing demands the conversion exists at all, and a binding that
shipped `HighlightRanges(Widget, long, long)` would pass every gate in
the tree while inviting the exact defect this arm's flip 1 produced.
**If the conversion is meant to be uniform, it needs a clause in that
gate**; this arm did not add one, because a sweep clause invented by one
arm mid-fan-out would fail the other seven for a name they never agreed
to.

---

### Re-verified against the tree as it moved

The fan-out is live around this arm: `swift/KayaSwiftUI.swift` changed
twice while it worked (`12c01d8c…` at the green pair, `212c46e0…`,
`28eb86f7…`), and gtk.rs / KayaCompose.kt at 21:38. A third leg run at
21:43, against the rebuilt interpreter and with both artifacts
`build-id --verify`'d (core rc=0, swiftui rc=0), is **green with
byte-identical output** — so this arm's result does not depend on the
interpreter snapshot it was measured on.

## CLEANUP, PROVEN

```
GUI lock:             this arm holds none. Every leg took it with the
                      fan-out's mkdir loop and released it with an
                      EXIT/INT/TERM trap; the lock now present was
                      created at 21:48:58, THIRTEEN SECONDS AFTER this
                      arm's last leg (21:48:45) — another arm's, left
                      alone.
stray processes:      none. `dotnet build-server shutdown` run; the
                      Roslyn VBCSCompiler this arm's builds started is
                      gone, and `ps -Ao pid,etime,pcpu,command | grep -Ei
                      "VBCSCompiler|kaya-guests|dotnet exec|MSBuild"`
                      prints nothing.
repo files perturbed: none — the three C# files sha256-match the
                      baseline; `tools/validate-mac.sh` carries only the
                      one intended leg addition
windows left up:      none (every leg exits through the harness; the
                      120s timeout ceiling was never reached)
scratchpad delta:     +224 KB, final. The throwaway conversion-check
                      csproj (772 KB with its bin/obj) was DELETED after
                      it ran, along with every build log. What remains:
                      cs-baseline/ 136 KB (the restore sources), the leg
                      and gate logs, three harness scripts, this report.
```

## FILES

- `/Users/akhilindurti/Projects/kaya/bindings/csharp/KayaApp.cs`
  (`TextRange`; `Tx.HighlightRanges` / `Tx.SelectRange` / `Tx.RevealRange`)
- `/Users/akhilindurti/Projects/kaya/guests/csharp/RangesScene.cs` (new)
- `/Users/akhilindurti/Projects/kaya/guests/csharp/Program.cs` (one case)
- `/Users/akhilindurti/Projects/kaya/tools/validate-mac.sh` (one leg)
- harness: `scratchpad/ranges-cs-leg.sh`, `scratchpad/cs-flip.sh`,
  `scratchpad/cs-perturb.py`, `scratchpad/cs-baseline/`
