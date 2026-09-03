# The typeface probe — the WinUI 3 arm

Measure-first probe for docs/styling-plan.md Slice 2b. **No repo file was
changed.** Everything below lived in
`scratchpad/styling/typeface-winui/ (gone)` — session scratch, dead with
the session; the measurements survive in this report.

**I CANNOT RUN THE WINDOWS LANE.** §6 says exactly which half of each
answer is measured here and which needs the VM, per question, with the
probe already written for the VM half.

The measurable half is unusually large on this platform, because the
**shipped Fluent resource dictionary is a text file on this mac**:
`third_party/winappsdk/Microsoft.WindowsAppSDK.WinUI-2.2.1/extracted/lib/native/Microsoft.UI/Themes/generic.xaml`
— 3,336,245 chars, sha256 `3f07e459…`, the exact WinAppSDK version
`tools/winui-bindgen` pins. Every claim in §1 is a census of that file
(`typeface-winui/census.py` → `census.txt`), not a doc page.

---

## 1. THE APPLY ROUTE — measured: there are TWO mechanisms and only ONE is overridable

The ramp does not hard-code `XamlAutoFontFamily` in one place. It uses
it two different ways, and the difference decides everything.

### 1a. The overridable half: `{ThemeResource ContentControlThemeFontFamily}`

```
ContentControlThemeFontFamily   <FontFamily> = 'XamlAutoFontFamily'
```

referenced as `{ThemeResource ContentControlThemeFontFamily}` by **58
keyed control Styles** plus the keyless (implicit, applies with no
opt-in) ones. The list is every control kaya renders:

    Button · TextBox · RichEditBox · CheckBox · RadioButton · ComboBox ·
    ToggleButton · ToggleSwitch · ListBox · ListViewItem · GridViewItem ·
    HyperlinkButton · AutoSuggestBox · PasswordBox · Slider · ToolTip ·
    DatePicker · TimePicker · AppBarButton · AppBarToggleButton ·
    NavigationViewItem · BreadcrumbBarItem · DropDownButton ·
    SplitButton · SelectorBarItem · PersonPicture · RepeatButton

A `{ThemeResource}` reference is re-resolved against the lookup chain, so
an app-level dictionary that redefines the key **wins** — this is exactly
the mechanism `apply_brand` already uses for the six accent stops
(crates/kaya/src/winui/mod.rs:4956-4989), including its ordering rule:
merged dictionaries are searched in REVERSE, so kaya's must be appended
after `XamlControlsResources`.

Three more keys resolve the same way and are worth writing while you are
there, because a half-overridden ramp is the accent arm's own trap one
level down (`SystemAccentColorLight1` is written for precisely this
reason): `KeyTipFontFamily`, `PivotHeaderItemFontFamily`,
`PivotTitleFontFamily` — all three also `XamlAutoFontFamily`.

**Do NOT touch `SymbolThemeFontFamily`.** Its value is
`'Segoe Fluent Icons,Segoe MDL2 Assets'`, it is read by 16 Styles and 80
template sites, and it is what the icons slice deliberately leaves unset
so glyphs resolve (mod.rs:1019-1022, the Windows 10 fallback). A typeface
lowering that swept "every FontFamily resource" would silently break
every icon in the app. It is also a MEASURED fact about the grammar:
`FontFamily.Source` takes a **comma-separated fallback list**, which is
Fluent's own answer to the missing-family problem.

### 1b. The hole: five Styles hard-code the LITERAL `XamlAutoFontFamily`

Not a resource reference — the bare string as a Setter value, so there is
**no key to redefine and no resource write that can reach them**:

| Style (all `x:Key`'d) | TargetType |
|---|---|
| **`BaseTextBlockStyle`** | TextBlock |
| `BaseRichTextBlockStyle` | RichTextBlock |
| `BaseContentControlStyle` | ContentControl |
| `BaseContentPresenterStyle` | ContentPresenter |
| `NavigationViewTitleHeaderContentControlTextStyle` | ContentControl |

`BaseTextBlockStyle` is the root of the **entire documented type ramp**.
Measured: `CaptionTextBlockStyle`, `BodyTextBlockStyle`,
`BodyStrongTextBlockStyle`, `BodyLargeTextBlockStyle`,
`BodyLargeStrongTextBlockStyle`, `SubtitleTextBlockStyle`,
`TitleTextBlockStyle`, `TitleLargeTextBlockStyle`,
`DisplayTextBlockStyle`, `SubheaderTextBlockStyle`,
`HeaderTextBlockStyle` are each `BasedOn={StaticResource
BaseTextBlockStyle}` and each set only sizes/weights — the family comes
from the base, as the literal.

```
BaseTextBlockStyle (TargetType=TextBlock, BasedOn=None)
    FontFamily = XamlAutoFontFamily      <== LITERAL, no key
    FontSize   = {StaticResource BodyTextBlockFontSize}
    FontWeight = SemiBold
    ...
```

**This hits kaya today.** The `heading` role lowers to
`label.SetStyle(theme_resource::<Style>("SubtitleTextBlockStyle"))`
(mod.rs:7854-7861). Under a `ContentControlThemeFontFamily` override and
nothing else, every button, entry and list row would change family and
**every kaya heading would stay on the system font** — one label out of
step, no error anywhere. That is the accent trap's twin in its exact
predicted shape, now with the list of which resources are which.

### 1c. Does an app-level `FontFamily` reach the ramp? Measured: NO, and the reason is structural

The charge asks this directly. The answer follows from the census
without needing the VM, because it is a question about **which values
exist**, not about how the framework prioritises them:

* A plain `<TextBlock/>` has **no implicit style at all** (measured: 0
  keyless `TargetType="TextBlock"` Styles in the whole dictionary; all 17
  TextBlock styles are `x:Key`'d and therefore opt-in). Nothing sets its
  FontFamily, so an inherited value from an ancestor is free to reach it.
* Every control kaya uses **does** have an implicit style, and that style
  **sets FontFamily**. A style value beats an inherited value in XAML's
  precedence, so the root's value never arrives.
* A ramp-styled TextBlock has the literal from `BaseTextBlockStyle`, so
  the root's value never arrives there either.

So an app-level FontFamily is the **complement** of the resource
override, not a substitute for it: it reaches exactly the elements the
resource route does not (unstyled TextBlocks), and misses exactly the
ones it does. **Neither route, nor both together, reaches the ramp
styles.** The precedence claim itself is the one part of this paragraph
that is read rather than measured — see §6.

### 1d. The route that does work, and why

A **local value** on the element beats the style that set it. kaya
applies the ramp style imperatively from Rust, so it can set the family
on the same object immediately after:

```rust
label.SetStyle(&theme_resource::<Style>("SubtitleTextBlockStyle")?)?;
label.SetFontFamily(&FontFamily::CreateInstanceWithName(&family)?)?;  // local: wins
```

The size, weight and line height stay the ramp's — only the family
moves, which is Slice 2b's rule exactly. The alternative (kaya defines
its own `SubtitleTextBlockStyle` shadowing the framework key) is worse:
`BasedOn={StaticResource SubtitleTextBlockStyle}` inside a dictionary
that shadows that key is self-referential, so kaya would have to restate
Fluent's sizes — which is the ramp-copying D4's ceiling refuses.

**Proposed shape for the arm** (not built — this is a probe):

1. `apply_brand`'s sibling writes `ContentControlThemeFontFamily`,
   `KeyTipFontFamily`, `PivotHeaderItemFontFamily`,
   `PivotTitleFontFamily` into an appended dictionary, same
   `XamlReader::Load` route, same set-once-before-mount rule (§1e).
   Not `SymbolThemeFontFamily`, ever.
2. Every site that applies a ramp style also writes the family locally —
   today that is the one `heading` arm, and the guard is that those two
   lines are inseparable (§5).

### 1e. Set-once holds here for the same measured reason as the accent

`apply_brand`'s doc comment already records it: changing a resource
VALUE at runtime does not re-theme a live WinUI tree. The typeface
inherits that constraint unchanged, and Slice 2b's "set once before
mount" is the same wall. Nothing new to decide.

---

## 2. THE HONEST READ — measured: the name is NOT readable from inside the XAML tree

Four candidate routes. Two are measured dead, one is an echo, one works
with a caveat that has to be stated.

### 2a. `FontFamily.Source` / `TextBlock.FontFamily` — the echo, and not even bound yet

`FontFamily` has exactly three members in the pinned metadata
(`typeface-winui/mdprobe`, windows-bindgen 0.62.1 against the same
winmd `tools/winui-bindgen` reads):

    FontFamily::CreateInstanceWithName(&HSTRING)
    FontFamily::Source(&self) -> HSTRING
    FontFamily::XamlAutoFontFamily() -> HSTRING   (static)

`Source` gives back the string that was set. It is the request, and it
answers "did my write land on the object", never "did the text system
find that font". It is the read Slice 2b's own sentence forbids.

Worth recording anyway: **kaya cannot call any of it today.** In
`crates/kaya/src/winui/bindings.rs` the string `FontFamily` appears 9
times and every one is a vtable pad —

    IControl_Vtbl        { FontFamily: usize, SetFontFamily: usize }
    ITextBlock_Vtbl      { FontFamily: usize, SetFontFamily: usize }
    IFontIcon_Vtbl       { FontFamily: usize, SetFontFamily: usize }
    plus three  FontFamilyProperty: usize  statics

because `Microsoft.UI.Xaml.Media.FontFamily` is not in the bindgen
filter. This is the icons slice's transitivity trap in the same disguise
(`IconElement` unfiltered ⇒ the generated file reads as "WinUI menu
items have no icon"). ONE filter entry unlocks the constructor, both
accessors on all three types, and `Control::SetFontFamily` — measured,
they all generate.

The trap is self-guarding, which is the good news: a lowering written
against an unfiltered type does not compile, and the windows
cross-compile is already in `tools/check-targets.py`.

### 2b. UIA's FontName attribute — MEASURED DEAD, twice, and kaya already knew

The route the plan would reach for first: `TextBlockAutomationPeer` →
`ITextProvider::DocumentRange` →
`ITextRangeProvider::GetAttributeValue(FontNameAttribute)`. Everything
exists in the metadata; `FontNameAttribute` is `40005i32` and its SDK
doc says "specifies the name of the font ... not localized", which reads
exactly like a resolved-family answer.

It does not work in this process, and there are two independent
measurements saying so.

1. **The pinned metadata.** `TextBlockAutomationPeer`'s declared
   hierarchy is
   `required_hierarchy!(TextBlockAutomationPeer, FrameworkElementAutomationPeer, AutomationPeer, DependencyObject)`
   — `ITextProvider` is not among its interfaces, where
   `ButtonAutomationPeer` does declare `IInvokeProvider` beside its own.
2. **kaya's own prior live measurement**, already written into this
   backend at `crates/kaya/src/winui/mod.rs:7574-7590`: "WinUI's
   in-process automation peer for a text control publishes no Text
   pattern at all, so `GetAttributeValue(BackgroundColor)` — the read the
   plan named — has no provider to answer it in this process. The SDK
   metadata and live reflection agree ... `GetPattern(Text)` returns NULL
   on both text controls."

And the escape hatch is nailed shut on purpose. An out-of-process UIA
client is the only thing that publishes the Text pattern, and
`Win32_UI_Accessibility` is deliberately absent from
`crates/kaya/Cargo.toml` with a measured reason: attaching an automation
client makes the Shell's file dialog raise a NONCONTINUABLE
`RPC_E_CANTCALLOUT_ININPUTSYNCCALL` that **kills the java leg**. The
comment there says the point out loud — "leaving the feature off means a
future attempt to reach for IUIAutomation fails `cargo build` here
rather than dying as an unexplained JVM crash on one lane." A typeface
arm that reaches for UIA walks into that wall, by design.

**So: WinUI cannot report the resolved family NAME from inside the app.**
That is a platform fact, not a missing effort, and the slice should hear
it now rather than after someone spends a session on it.

### 2c. DirectWrite, in-process — available, cross-compile verified, with one caveat

DirectWrite is the layer under the XAML text stack and carries none of
UIA's hazard: it is a local text API, not a cross-process automation
client. Adding `"Win32_Graphics_DirectWrite"` to the existing `windows`
dependency is the whole cost.

**Measured** — `typeface-winui/dwprobe` compiles clean for
`aarch64-pc-windows-msvc` against kaya's pinned `windows 0.62` /
`windows-core 0.62`, so every call below exists with the shape written:

    DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED) -> IDWriteFactory
    IDWriteFactory::GetSystemFontCollection(&mut collection, true)
    IDWriteFontCollection::FindFamilyName(name, &mut index, &mut exists)
    IDWriteFactory::CreateTextFormat(family, .., size, locale)
    IDWriteFactory::CreateTextLayout(text, &format, w, h)
    IDWriteTextLayout::GetMetrics(&mut DWRITE_TEXT_METRICS)
    IDWriteFont::GetFontFamily -> IDWriteFontFamily::GetFamilyNames

`FindFamilyName` is a genuinely honest binary read: it says whether the
system font collection HAS that family. It is what turns the silent
fallback loud.

**The caveat, stated rather than buried:** this is DirectWrite's answer
to DirectWrite's question. XAML does its own family-name handling first
— `XamlAutoFontFamily` is a XAML-side token with no DirectWrite
spelling, `FontFamily.Source` accepts a **comma-separated fallback list**
(measured: `SymbolThemeFontFamily` is `'Segoe Fluent Icons,Segoe MDL2
Assets'`), and it accepts `ms-appx:///path#Name` for bundled faces. A
presence check must parse the same grammar XAML does or it will answer
confidently about a string XAML never looks up that way.

Getting the SUBSTITUTE's name out of DirectWrite needs one more step
than `FindFamilyName`, and both options cost a COM implementation:
`IDWriteTextRenderer` (8 methods, gives `IDWriteFontFace` per glyph run
= the font that actually produced glyphs) or
`IDWriteFontFallback::MapCharacters` (+ `IDWriteTextAnalysisSource`, 4
methods, gives the mapped `IDWriteFont` directly). Both are writable
with `windows-core`'s `#[implement]`. **Which one agrees with XAML is a
VM measurement, not a reading.**

### 2d. The did-it-take proof, inside the real XAML tree, with zero new dependencies

The plan's own doctrine is "assert PIXELS or real-token reads, never API
read-backs". On this platform the cheapest real-token read is the text's
own MEASURED GEOMETRY, and it is already bound:

* `TextBlock::ActualWidth` — `ActualWidth` has 41 accessors in the
  generated bindings and kaya's layout reads already use it.
* `TextBlock::BaselineOffset` — a FONT METRIC, produced by the face that
  actually laid out, and it generates from the same metadata.

Two numbers for a pinned string are a fingerprint of the font that
really rendered. This cannot be faked by an echo: if the family did not
take, the numbers equal the fallback's. **This is the read that should
carry `expect_typeface` on WinUI**, with 2c's DirectWrite presence check
beside it as the why-not.

---

## 3. THE FALLBACK — NOT MEASURED, and the research says it is not knowable from here

The charge asks for the exact family a nonsense request resolves to. I
cannot measure it (§6), and three findings say nobody should guess it:

1. **Microsoft has never documented it.**
   [microsoft-ui-xaml#10709](https://github.com/microsoft/microsoft-ui-xaml/issues/10709)
   — "Which is the default Fallback Font Used in WinUI 3 When FontFamily
   Is Invalid", opened August 2025 — is **still unanswered** by
   maintainers. No font name, no API, no response. The question this
   probe was sent to answer is an open question upstream.
2. **It differs between WinUI 2 and WinUI 3.**
   [#9247](https://github.com/microsoft/microsoft-ui-xaml/issues/9247)
   reports families that resolve under WinUI 2 falling back to the
   default under WinUI 3.
3. **It differs for UNPACKAGED apps, by locale.**
   [#8360](https://github.com/microsoft/microsoft-ui-xaml/issues/8360):
   unpackaged WinUI 3 apps on a Japanese-configured system render
   English text in the wrong face while the packaged build is fine.
   **kaya's guests are unpackaged** — the backend already pays for that
   elsewhere (`require_control_resources`, the hand-written
   `ENTRY_STYLE_XAML` "this unpackaged app cannot resource-resolve").

**Consequence for the design, and it is the one thing here that changes
the scene's shape:** the WinUI fallback name is a property of the LANE
IMAGE (Windows build × locale × packaging), not a constant. A
`.steps` file is shared verbatim across platforms with byte-compared
expectations (invariant 6), so the negative test must NOT hard-code a
Windows fallback family name. Two shapes survive:

* assert the SHAPE of the answer — the read reports that the requested
  family is not installed, in the same words on every platform, and the
  substitute is reported but not compared; or
* assert the METRIC identity (§2d) — a nonsense family renders
  byte-identically to a brandless run, which is the same sentence on
  every platform and needs no font name at all.

The second is stronger and is what I would build. It also happens to be
the only one of the two that can be written before anyone measures the
name.

**One naming trap to bank now**, from the official Windows 11 font list:
**`"Segoe UI Variable"` is not an installed family.** The installed
families are `Segoe UI Variable Display`, `Segoe UI Variable Small` and
`Segoe UI Variable Text`. The obvious guess for "what the fallback
probably is" is itself an invalid request, and would silently fall back
in turn.

---

## 4. FAMILY NAMES SAFELY PRESENT ON A WINDOWS LANE

From Microsoft's own Windows 11 font list (its FOD/optional families are
in a clearly separate section, so "shipped" here means the main table):

| family | note |
|---|---|
| **Consolas** | monospace, present since Vista — Win10 AND Win11. The width read (§2d) discriminates it from any UI face by a mile. **My pick for the positive leg.** |
| **Georgia** | serif, obviously not the system face at a glance, and it ships on **macOS too**, so one wire value could serve two platforms in the demo. |
| Verdana, Tahoma, Trebuchet MS, Arial, Times New Roman, Courier New, Comic Sans MS, Calibri, Cambria, Candara, Corbel, Constantia, Palatino Linotype, Lucida Console, Impact, Sitka, Sylfaen | all in the shipped table |
| Cascadia Mono, Cascadia Code, Segoe UI Variable *, Segoe Fluent Icons | Windows 11 ONLY (marked "Added in Windows 11") |

Do NOT use: **Georgia Pro / Verdana Pro / Arial Nova / Gill Sans Nova /
Rockwell Nova / Neue Haas Grotesk** — those are Pan-European **Feature
On Demand** packages, absent from a default install. And not
`"Segoe UI Variable"` (§3).

**Unverified for this specific VM.** I could not enumerate the lane
image's fonts (§6). A default Windows 11 arm64 install has the table
above; an image someone trimmed does not have to. The `dwprobe`
presence pass answers it in one run.

---

## 5. THE GUARD THIS ARM NEEDS, and where it has to sit

Invariant 3 asks what wall would have caught the failure, and where
someone walks into it. The failure class here is specific: **a ramp
style applied without the local family write beside it** (§1b/§1d). It
is invisible — the app renders, the heading just quietly keeps the
system font — and it is exactly the shape that survives every existing
gate.

Right now there is **one** such site in the whole backend
(`mod.rs:7861`, `SubtitleTextBlockStyle` under the heading role;
`theme_resource::<Style>` has only two callers total and the other is
`AccentButtonStyle`). One site is the cheapest moment this guard will
ever be written.

Proposed, in decreasing order of preference per invariant 3's
types-over-generation-over-checks:

1. **Make the pair unsplittable in the type system.** A private helper
   `fn apply_ramp_style(el: &TextBlock, key: &str) -> Result<()>` that
   applies the style AND the brand family together, with the raw
   `SetStyle` for a `*TextBlockStyle` key reachable nowhere else. Then
   "forgot the family write" is not a state the source can express.
2. **Failing that, a gate in the set the lanes already run**: any
   `SetStyle` whose key ends `TextBlockStyle` must be followed by a
   family write in the same arm. That is `check-universal-props.py`'s
   shape (per-backend arm consumes the thing), and its negative test
   must be watched failing — delete the family line, see the gate go
   red, restore.
3. **A guard on the dictionary's key list**: `SymbolThemeFontFamily` must
   never appear in the typeface dictionary (§1a). Its negative is easy
   and its failure is loud in a way nothing else catches — the app's
   icons turn into boxes.

`tools/check-diagnostics.py` also applies to whatever why-not the read
grows: a WinUI typeface why-not must not print "the font is not
installed" when what it measured was "DirectWrite's collection does not
have that family string" (§2c's caveat is precisely a case where the
diagnostic can be true and misleading). One answer, or an answer that
interpolates nothing, is what that gate already refuses.

One more, from §5 of the icons report and still true: **`winui::tests`
runs on no lane.** `tools/deploy-win.py` filters the unit-test binary to
`capi::picked_tests`. Any structural guard for this arm should be a
`const` assertion or a shell gate, never a `#[test]` under `winui::`.

---

## 6. WHAT IS MEASURED HERE AND WHAT NEEDS THE VM — plainly, per question

**The VM is powered off.** `ping 192.168.64.2` (the host in
`tools/probe-env.sh:181`, `akhil@192.168.64.2`) — 2 packets sent, 0
received, 100% loss. So this is not "I chose not to run the lane"; there
is no guest to read. Nothing below was attempted against Windows.

| # | question | measured HERE | needs the VM |
|---|---|---|---|
| 1 | apply route | **All of it.** Which resources the ramp reads, which are `{ThemeResource}` (overridable) and which are literals (not), the full BasedOn chain, that TextBlock has no implicit style, that the hole hits kaya's own heading arm. From the shipped `generic.xaml` for the pinned SDK. | That an appended dictionary actually re-points the 58 control styles at run time; that the local write on a ramp-styled TextBlock takes. Both are *precedence* claims — read from Microsoft's own DP-precedence docs (local > style > inherited), never watched. |
| 2 | honest read | **The routes and their availability.** FontFamily's three metadata members; that kaya cannot call any of them today (vtable pads, one filter entry away); that the UIA FontName route is dead in-process (metadata + kaya's own prior live measurement) and barred out-of-process at the Cargo.toml; that DirectWrite is reachable — `dwprobe` cross-compiles clean for `aarch64-pc-windows-msvc`. | **Every number.** No font was resolved, no `ActualWidth` or `BaselineOffset` was read, no `FindFamilyName` was called. Whether XAML's family lookup agrees with DirectWrite's is UNMEASURED and is the single most important open question for the arm. |
| 3 | the fallback | **That it is undocumented and image-dependent** — upstream #10709 unanswered since Aug 2025, #9247 (differs WinUI 2 vs 3), #8360 (differs for unpackaged apps by locale, and kaya's guests are unpackaged). Plus the naming trap that `"Segoe UI Variable"` is not an installed family. | **The name itself. Not obtainable any other way.** This is the half that must not be guessed: writing a plausible-looking family name into a negative test would produce a guard that passes for the wrong reason on one image and fails on the next. |
| 4 | safe family names | The Windows 11 shipped-vs-FOD split from Microsoft's font list; Consolas and Georgia as the picks. | **What this particular VM image actually has.** One `dwprobe` presence pass answers it. |

**The VM half is one command once the guest is up.** `dwprobe` is
written, compiles, and takes family names as argv:

    cargo build --locked --target aarch64-pc-windows-msvc   # in typeface-winui/dwprobe
    dwprobe.exe "Consolas" "Georgia" "Segoe UI Variable" "Segoe UI Variable Text" "KayaNoSuchFamily-9x"

It prints, per request: `installed=true|false`, the API echo (so the
echo and the measurement sit side by side in one log), and the laid-out
width and line height. Requests that are absent and requests that are
present are distinguished by the FIRST column and confirmed by the
LAST — which is the discrimination §2's why-not needs.

The XAML half needs a kaya build, so it is a patch rather than a
standalone: add `Microsoft.UI.Xaml.Media.FontFamily` to the bindgen
filter, regenerate, then behind an env var write the dictionary of §1a,
apply the local family of §1d, and print `ActualWidth`/`BaselineOffset`
for a pinned string in four configurations — brandless, a real family,
a real family on a ramp-styled label, and `KayaNoSuchFamily-9x`. If the
nonsense request's numbers equal the brandless numbers, the fallback is
proven silent and the metric read is proven to discriminate. **I did not
write that patch, because it cannot be compile-checked without editing
the repo, and this probe changes no repo file.**

---

## 7. WHAT I DID NOT DO, said plainly

* **No font was rendered, resolved, measured or named on Windows.**
  Every number in §1 is a count of text in a resource dictionary; every
  claim in §2 about availability is a compile or a metadata read. §3 has
  no measurement in it at all and says so.
* **The DP-precedence claims (§1c, §1d) are READ, not watched.** They
  come from Microsoft's dependency-property precedence documentation
  (local value above style setters above inherited values). They are the
  load under §1d's recommendation and the first thing the VM half should
  confirm.
* **`dwprobe` has never run.** It compiles for the guest's target; it has
  not executed on any machine.
* **I did not verify that an appended `ContentControlThemeFontFamily`
  actually re-points a live control.** The accent arm's identical route
  is shipped and green on the windows lane, which is good evidence and
  is not the same as having seen it for this key.
* **RTL, high contrast, and the Windows text-scale setting** are untouched
  by this probe. The accent arm's HighContrast yield (kaya writes no
  HighContrast entry, so the brand stops applying there) has an obvious
  typeface analogue that nobody has decided.

## 8. Processes and disk

No background process was started; none to stop. `ps` at exit shows
nothing of mine.

Scratch: `styling/typeface-winui/` — the two probe crates' `target/`
directories are deleted (211M + 56M), leaving **420K**: the census script
and its output, the two probe sources, and the 374K generated metadata
read. Measured with du -sh AFTER deletion, not asserted. The repo tree is untouched: `git status --porcelain` shows one
modified file, `docs/styling-plan.md`, which is the coordinator's own
Slice 2b draft and was already modified before this probe started.

