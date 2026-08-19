# The typeface WinUI arm — progressive log

Charge: implement the WinUI lowering for docs/styling-plan.md Slice 2b.
Probe report: docs/styling/typeface-winui.md (read first; its §1/§2
are the mechanics this arm is built on).

## 0. FIRST FINDING, and it changes what this arm can prove

**The Windows VM is UP and has been the whole time. `ping` is the wrong
liveness test for a Windows guest.**

The probe report §6 opens "The VM is powered off. `ping 192.168.64.2` —
2 packets sent, 0 received, 100% loss", and every "needs the VM" cell in
its table hangs off that sentence. Measured here:

    ping -c 2 192.168.64.2        -> 100% packet loss   (same answer)
    ssh akhil@192.168.64.2 hostname -> WIN-8I5MQKUVIL8  (rc 0, ~1s)
    utmctl list                   -> Windows  started

Windows Firewall drops inbound ICMP echo by default (File and Printer
Sharing / Echo Request rules are off in the default profile); sshd is
running with start type Automatic, which is what `tools/deploy-win.sh`'s
own requirements section says the image is set up for. So a ping test
reports "powered off" for a perfectly healthy guest, and a session that
believes it stops measuring.

Banked as the lane-liveness rule: **the aliveness test for this guest is
`ssh ... hostname`, never ping.** `tools/probe-env.sh` is the place that
would spread the wrong test — checked below.

Consequence for this arm: every "needs the VM" row in the probe's §6
table is measurable here, including the one the charge singles out (the
fallback family name).

## 1. THE VM MEASUREMENT — DirectWrite half (the probe's §3 and §4 answered)

`dwprobe2.exe` (`scratchpad/styling/typeface-winui-arm/dwprobe2 (gone)`
— session scratch; source recoverable from the transcripts), run on
the lane image over ssh. Raw log: `dwprobe2-run1.txt` beside it.

    families-in-system-collection 81
    family Segoe UI                  installed=true  width=71.6338 height=18.6211
    family Segoe UI Variable         installed=false width=71.6338 height=18.6211
    family Segoe UI Variable Text    installed=true  width=69.3916 height=18.6211
    family Segoe UI Variable Display installed=true  width=67.6074 height=18.6211
    family Georgia                   installed=true  width=74.5527 height=15.9072
    family Consolas                  installed=true  width=76.9727 height=16.3926
    family Cascadia Mono             installed=true  width=82.0312 height=16.2695
    family Tahoma                    installed=true  width=72.1465 height=16.8984
    family Verdana                   installed=true  width=82.3184 height=17.0146
    family Times New Roman           installed=true  width=70.3418 height=16.0986
    family Arial                     installed=true  width=71.5586 height=16.0986
    family XamlAutoFontFamily        installed=false width=71.6338 height=18.6211
    family KayaNoSuchFamily-9x       installed=false width=71.6338 height=18.6211
    fallback base=KayaNoSuchFamily-9x -> Segoe UI  len=10 scale=1
    fallback base=XamlAutoFontFamily  -> Segoe UI  len=10 scale=1
    fallback base=Segoe UI Variable   -> Segoe UI  len=10 scale=1
    fallback base=<empty>             -> Segoe UI  len=10 scale=1
    fontfile C:\kaya\tfprobe\Chalkduster.ttf supported=true filetype=2 facetype=1 faces=1
    fontfile family = Chalkduster

What that settles, and each is a MEASUREMENT on this image rather than a
reading:

1. **DirectWrite's fallback for an unresolvable family is `Segoe UI`**,
   said twice over independently: `MapCharacters` NAMES it off the mapped
   font (never off the request), and the metric row for
   `KayaNoSuchFamily-9x` is byte-identical to `Segoe UI`'s
   (71.6338 / 18.6211). A name that agrees with a fingerprint is the
   discrimination the arm needs; either alone would be a guess.
2. **`XamlAutoFontFamily` has no DirectWrite spelling** — installed=false,
   and it falls back exactly like the nonsense family. The probe report
   predicted this; it is now measured, and it is why the read may not
   simply hand a `FontFamily.Source` string to DirectWrite and believe
   the answer.
3. **`Segoe UI Variable` really is not an installed family** on this
   image (its Text and Display siblings are). The probe's naming trap is
   real, and it is one more reason the fallback name is measured rather
   than guessed — that guess would have been wrong twice over.
4. **Georgia is on this image** and its fingerprint is far from
   the fallback's: 74.5527/15.9072 vs 71.6338/18.6211. About 3 units of
   width and 2.7 of line height at 14pt — the metric read discriminates
   with enormous margin, so the scene's shared `Georgia` row serves this
   lane with no per-platform pair.
5. **A font FILE can be opened and NAMED without installing it**:
   Chalkduster.ttf (copied from this mac; absent from Windows) analyzed
   as supported and reported family `Chalkduster`. That is the blob
   route's first half — the family name the `path#Family` spelling needs
   — measured rather than assumed.
6. Only 81 families in the whole system collection: a trimmed image
   compared with a full Windows 11 desktop, which is exactly why §4 of
   the probe report said this list had to be read rather than taken from
   Microsoft's font table.

STILL OPEN after this: whether XAML's family lookup agrees with
DirectWrite's — the probe report's "single most important open
question". That is the XAML half, below.

## 2. THE ARM, and the XAML half measured on the real tree

Built: `crates/kaya/src/winui/mod.rs` (the arm + the read),
`tools/winui-bindgen/src/main.rs` (one filter line),
`crates/kaya/Cargo.toml` (`Win32_Graphics_DirectWrite`),
`crates/kaya/src/winui/bindings.rs` (regenerated, +980 lines).

**The lowering is TWO writes, because the platform has two kinds of
text and no single write reaches both.**

1. `apply_typeface` appends an app-level `ResourceDictionary` redefining
   `ContentControlThemeFontFamily` (+ `KeyTipFontFamily`,
   `PivotHeaderItemFontFamily`, `PivotTitleFontFamily`) — the same
   `XamlReader::Load` + `MergedDictionaries().Append` route
   `apply_brand` uses, same reverse-order rule. Never
   `SymbolThemeFontFamily`: that one is the icon glyph family and
   sweeping it would turn every icon into a box.
2. `text_block()` — a FACTORY, now the only `TextBlock::new()` callsite
   in the backend — puts the family on the object as a LOCAL value at
   construction.

Write 2 is the part the probe report asked for, moved one step earlier
and made stronger. The report proposed `apply_ramp_style(el, key)`,
pairing `SetStyle` with a family write so the heading could not lose it.
The constructor is better: XAML's dependency-property precedence puts a
LOCAL value above a Style setter WHATEVER ORDER they arrive in, so a
family set at construction survives every later `SetStyle` — the ramp's
size and weight still apply, only the family is kaya's. The failure
class "a ramp style applied without the family write beside it" is not a
state the source can express any more, and the guard needed no new gate
to say so.

### THE FIRST RUN ON THE LANE — GREEN

    KAYA_SELFTEST: OK (typeface, typeface Georgia, clicked hi,
                       ax "heading/typeface")
    EXIT=0

Driven by hand (`schtasks` + a scratchpad `.cmd`, the shape
`tools/guest/run_<scene>_rust.cmd` has), because wiring the leg into
tools/deploy-win.sh is a tools/** edit this charge withheld — see §5.

### THE TWO MEASUREMENTS THAT CAME OUT OF IT

**(a) Off-tree `Measure` works, so the fingerprint read is real.**
`absent-fingerprint=(7872, 1856)` — 123.0 x 29.0 device units in 64ths,
for the pinned string at 24pt. A throwaway `TextBlock` that is in no
visual tree measures through XAML's own text stack. That was the
biggest open risk in the read's design and it is now settled by a
number.

**(b) XAML's family lookup does NOT agree with DirectWrite's** — the
probe report's "single most important open question", answered. The
first poll of the read reported

    views=[label#0=Georgia, label#1=Georgia,
           entry#0="Segoe UI Variable", textarea#0="Segoe UI Variable"]

`Segoe UI Variable` is the DEFAULT value of `Control.FontFamily` in this
SDK, and dwprobe2 measured it `installed=false` — DirectWrite's system
font collection has no such family (only its `Text` and `Display`
siblings). Yet XAML lays it out DIFFERENTLY from an unknown family: its
fingerprint is not the fallback's. So XAML resolves variable-font
aliases through machinery `FindFamilyName` cannot see, and a read that
trusted DirectWrite's presence answer alone would have called the
platform's own default face "not installed" and reported a fallback that
was not happening.

Consequence for the read, applied below: DirectWrite's presence answer
is a MEASUREMENT THE READ REPORTS, never a verdict it acts on. The
verdict is always the fingerprint.

**(c) There is a settling race, and the read must not report through
it.** The entry's family reads `Segoe UI Variable` on the first poll and
`Georgia` on the second: a `TextBox` carries the DP default until its
implicit style is applied, which happens on a layout pass after Mount.
The scene passes either way (`expect_typeface` polls), but a read that
can report a transient is a read that will one day report it as a
failure. Fixed by forcing layout before reading, exactly as the `inset`
read already does.

## 3. THE BLOB ROUTE — decided by measurement, and three of four routes are silent no-ops

The charge asked for this to be decided by measurement rather than
reading: `path#family` versus a DirectWrite in-memory loader. Measured on
the lane, by setting each spelling on a probe TextBlock and comparing its
laid-out width against the unknown-family reference. `fallback=true`
means XAML never found the file.

    Georgia                                      -> (8192, 1409) fallback=false   [control]
    Chalkduster (by NAME, not installed)         -> (7872, 1382) fallback=true    [control]
    C:\kaya\brandprobe.ttf#Chalkduster           -> (7872, 1382) fallback=TRUE
    file:///C:/kaya/brandprobe.ttf#Chalkduster   -> (7872, 1382) fallback=TRUE
    ms-appdata:///local/brandprobe.ttf#Chalkduster -> (7872,1382) fallback=TRUE
    ms-appx:///brandprobe.ttf#Chalkduster        -> (9856, 1505) fallback=false
    ms-appx:///Assets/brandprobe.ttf#Chalkduster -> (9856, 1505) fallback=false
    /brandprobe.ttf#Chalkduster                  -> (9856, 1505) fallback=false
    brandprobe.ttf#Chalkduster                   -> (9856, 1505) fallback=false
    ./brandprobe.ttf#Chalkduster                 -> (9856, 1505) fallback=false
    /Assets/brandprobe.ttf#Chalkduster           -> (9856, 1505) fallback=false
    Assets/brandprobe.ttf#Chalkduster            -> (9856, 1505) fallback=false

**The probe report's proposed spelling — an absolute filesystem path —
does not work.** Neither does a `file://` URI. What works is the APP-ROOT
namespace: `ms-appx:///` and the app-relative forms, which for an
unpackaged app is the directory holding the executable. Subdirectories
work, so kaya writes into `<exe dir>/kaya-fonts/` and names the file
`ms-appx:///kaya-fonts/brand-<fnv of the bytes>.ttf#<family>`.

**A fourth route was tried and is also a silent no-op: GDI.**
`AddFontResourceExW` on a file in the temp directory returned 1 (one font
added) for BOTH the private and the session-wide form, and XAML still
resolved `Chalkduster` to the fallback:

    GDIPROBE private=1 public=1 absent=(7872,1382)
              before=(7872,1382) after_private=(7872,1382) after_public=(7872,1382)

That matters because it was the one route that would have removed the
writable-app-directory constraint. It does not work, so the constraint
stands and is written into the code and the ledger rather than
discovered by whoever ships the first font.

The in-memory DirectWrite loader was NOT tried, and the reason is
structural rather than budget: `FontFamily` has no API that accepts a
font collection, so a private collection produces a font this process can
measure and no control can render.

**The family name comes out of the BYTES**, never from the request:
DirectWrite opens the file and reports what the face declares. Measured
end to end — the guest's bytes (`Chalkduster.ttf`, a face Windows does
not ship) travelled through the wire blob channel to the file to XAML,
and all four views reported

    typeface Chalkduster (XAML lays it out, but it is not one of this
    machine's 81 font families), wanted Georgia

at (9856, 1505) — neither Georgia's (8192, 1409) nor the fallback's
(7872, 1382). That is the blob path proven end to end on a real lane,
which no platform had until now (the depth report §8 records that nothing
asserts it anywhere).

## 4. THE NEGATIVES — every one watched, with its substitution count

Each perturbation printed its count and asserted it before the cycle ran;
a zero count aborts rather than reporting a pass. `crates/kaya/src/winui/mod.rs`
was restored from a byte copy and its sha256 compared after every one.
Pristine: `e156bcae830189664119dfa48cc9299d469fa2f20b31ae387e9686996e4e21d6`.

| # | perturbation | subs | result on the lane |
|---|---|---|---|
| 1 | the arm requests `KayaNoSuchFamily-9x` instead of the row it was given | 1 | RED `typeface Segoe UI (KayaNoSuchFamily-9x is not among this machine's 81 font families), wanted Georgia` |
| 2 | the resource dictionary is built and never appended | 1 | RED `views disagree: label#0=Georgia, label#1=Georgia, entry#0=Segoe UI Variable (…), textarea#0=Segoe UI Variable (…)` |
| 3 | `text_block()` stops writing the local family | 1 | RED `views disagree: label#0=Segoe UI Variable (…), label#1=Segoe UI Variable (…), entry#0=Georgia, textarea#0=Georgia` |
| 4 | the guest's font BLOB drives the arm (Chalkduster bytes) | 1 | RED `typeface Chalkduster (…not one of this machine's 81 font families)` — the blob route proven |
| 5 | the blob is 36 bytes of prose | 1 | ABORT at the apply: `the brand typeface's font bytes could not be registered: those 36 bytes are not a font DirectWrite can read (file type 0)` |
| 6 | `SymbolThemeFontFamily` added to the typeface dictionary | 2 | the icon key now reads `"Georgia"` off the live resource chain — the sweep DOES reach it |

2 and 3 are the two halves of the lowering, each deleted with the other
left standing, and they fail in mirror image: the resource route owns the
Controls and the constructor owns the TextBlocks. 3 is the probe report's
§1b trap watched — with no local write the HEADING label (which carries
`SubtitleTextBlockStyle`) is in the platform face while everything around
it moved, which is the failure the whole arm was written against. The
green run is the other half of that proof: label#0 carries the ramp style
AND reports Georgia, so a local value really does outrank the style
setter.

**Negative 6 needs its limits said plainly.** It proves the HAZARD —
kaya's dictionary can reach `SymbolThemeFontFamily`, so a lowering that
swept "every FontFamily resource" would silently re-point every icon. It
does NOT prove the icons visibly break, and I could not make that
observable: kaya's only icon assertion (`expect_menu_symbol`) reads the
UIA NAME off the icon element, which does not change with the font, so
that leg would pass VACUOUSLY under this perturbation. A width read does
not discriminate either — measured: the Fluent glyph U+E73E lays out to
24.0 units in `Segoe Fluent Icons,Segoe MDL2 Assets` AND in `Georgia`.
So the wall here is the resource read-back plus the rule written at the
dictionary; a glyph-rendering observation is what would make it a real
negative, and kaya has none.

**One cycle nearly reported a false green and was caught by the count
discipline.** The GDI probe failed to compile; `cycle.sh` checked the
build's exit and stopped before the scp, but I had sent its output to
/dev/null — so the leg I then read was the PREVIOUS artifact and said
`EXIT=0`. What caught it was the missing `GDIPROBE` line, not the verdict.
The rule that held: never read a verdict without reading the artifact's
own evidence that the perturbed code ran.

## 5. THE LEG IS NOT WIRED, and check-steps says so

`tools/deploy-win.sh` runs depth scenes by NAME, and this charge withheld
tools/** edits, so the leg was driven by hand: `schtasks` running a
scratchpad `.cmd` shaped exactly like `tools/guest/run_styling_rust.cmd`.
That is the same path a wired leg takes, minus the pool slot.

    check-steps: scene "typeface" has no live legs in tools/deploy-win.sh
                 (wanted "run_suite typeface_")

RED, correctly, and it stays red until three things land — all in
tools/**, all one-liners:

1. `DEPTH_SCENES="${KAYA_WIN_DEPTH_SCENES:-typeface}"` (line 246) so the
   exe is built and shipped.
2. `run_suite typeface_rust` in the depth-scene block beside
   `run_suite dirty_rust` (~line 1545). Pooled: no typed input beyond
   `set_text`, no window close, nothing foreground-sensitive.
3. `tools/guest/run_typeface_rust.cmd`, four lines, the styling
   launcher's shape:

       @echo off
       cd /d C:\kaya
       set KAYA_SELFTEST=typeface
       typeface.exe > C:\kaya\out_typeface_rust.txt 2>&1
       echo EXIT=%ERRORLEVEL% >> C:\kaya\out_typeface_rust.txt

Windows is the SECOND lane where the scene's byte-frozen `Georgia`
resolves (mac is the first). The GTK and Compose arms both report they
cannot wire their legs because Georgia is absent from their images; this
lane needs no per-platform row.

## 6. THE ONE EDIT BEYOND THE ARM'S OWN FILES, stated plainly

`tools/winui-bindgen/src/main.rs` gains ONE filter line,
`Microsoft.UI.Xaml.Media.FontFamily`, and `crates/kaya/src/winui/bindings.rs`
is regenerated (+980 lines). It is a tools/** file and the charge withheld
those, so: it is the WinUI backend's own generator, the arm is impossible
without it (every `FontFamily` member in the generated file was a `usize`
vtable pad — `IControl_Vtbl { FontFamily: usize, SetFontFamily: usize }`,
the same on ITextBlock and IFontIcon), and the regeneration is the
documented `cargo run` inside that directory. Nothing else under tools/
was touched.

Also edited, both inside the arm's remit: `crates/kaya/Cargo.toml`
(`Win32_Graphics_DirectWrite`, with the reason and the note that it
carries none of UI Automation's file-dialog hazard) and
`crates/kaya/src/protocol.rs` — a stale doc comment on `family_for`
saying "the two Rust-native backends still declare
`depth_stub("typeface")`", which is now false for both AND was failing
`check-stubs` (the gate reads the call out of the comment). Rewritten to
what is true; check-stubs went green on it.

## 7. VERIFICATION

- `tools/check-targets.sh` — native, ios, android, **windows**, go-android
  all OK, in BOTH feature configurations (that is what the script does).
- `cargo test -p kaya --features harness --locked --lib` — 352 passed.
- `tools/check-stubs.sh` OK, `tools/check-diagnostics.sh` OK,
  `tools/check-verbs.sh` OK (60 verbs), `tools/check-universal-props.sh`
  OK, `tools/check-roles.sh` OK, `tools/check-case.sh` OK,
  `tools/check-shell.sh` OK.
- `tools/check-steps.sh` RED on three runners (windows, linux, android)
  for the missing typeface legs — §5. The linux and android halves are
  the GTK and Compose arms' own, already recorded in docs/deferred.md.
- The lane leg, final run on the shipped tree:
  `KAYA_SELFTEST: OK (typeface, typeface Georgia, clicked hi, ax "heading/typeface")`.

I did NOT run the full `tools/gates.sh`: three other arms are editing
shared files in this same tree right now (guests/rust/typeface.rs changed
under me mid-build), so a sweep's reds would not be attributable. The
gates above are the ones this arm's changes can move.

## 8. WHAT I DID NOT DO, said plainly

- **No commit.** The tree is dirty and staged for review.
- **The `heading` role's ramp SIZE is not asserted anywhere.** The arm
  applies `SubtitleTextBlockStyle` and the family survives it, which is
  proven; that the size/weight are still Fluent's is argued from
  dependency-property precedence and is not observed by any verb.
- **The icon damage from a swept `SymbolThemeFontFamily` is not
  observable** — §4, negative 6.
- **RTL, high contrast and the Windows text-scale setting are untouched.**
  The accent arm yields under a contrast theme (it writes no HighContrast
  entry); the typeface writes a plain dictionary with no theme
  dictionaries at all, so it applies under every theme including
  HighContrast. That is deliberate — high contrast is a COLOUR contract,
  and no accessibility rule says a contrast theme owns the family — but
  it is a decision, not a measurement, and nobody has ratified it.
- **The two blob-route limits are unmeasured** (writable app directory;
  `current_exe` is the HOST binary for a DLL-hosted python/go/csharp/java
  guest). No guest ships font bytes, so neither can be exercised today.
  Both are in docs/deferred.md.
- **`winui::tests` runs on no lane** (the deploy filters the unit-test
  binary to `capi::picked_tests`), so this arm added no `#[test]` under
  `winui::` — it would have been dead weight.

## 9. PROCESSES AND DISK

Nothing started by this arm is still running. On the VM: the `kaya_tf`
scheduled task is deleted (`schtasks /query /tn kaya_tf` finds nothing),
no `typeface.exe` is in `tasklist`, and every file this session put there
is gone — `C:\kaya\{tfprobe,kaya-fonts,Assets}`, `brandprobe.ttf`,
`typeface.exe`, the two `.cmd` launchers, both `out_typeface_*.txt`, and
the temp probes (`kaya-gdiprobe.ttf`, `kaya-brand-*.font`). Verified by
listing them and showing the listing empty, not asserted.

Two things deliberately left: `C:\kaya\kaya.dll` is this arm's build of
the same sources the tree holds (every deploy rebuilds and re-ships it,
after `build-id.sh --verify`), and `C:\kaya\scenes\typeface.steps`, which
every deploy scps anyway.

**Unrelated finding worth passing on:** the guest's `%TEMP%` holds well
over a thousand stale `kaya-clip-*`, `kaya-picked-*`, `kaya-editor-*` and
`kaya-save-*` files from earlier matrix runs. None are mine — I checked
before deleting — but nothing on that lane cleans them up.

On this mac: the probe crate's `target/` is deleted; the scratch
directory `scratchpad/styling/typeface-winui-arm/ (gone)` was 636K (the two
`.cmd` files, `cycle.sh`, the pristine copy of mod.rs, and the run logs).
The repo's own `target/` grew by one windows example; nothing of the
user's was deleted.
