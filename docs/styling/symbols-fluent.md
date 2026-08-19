# Semantic icon names — the FLUENT (WinUI 3) column

Platform: WinUI 3 / Windows App SDK, `Microsoft.UI.Xaml.Controls`.
Two routes, both drawing from the same font:

- **`SymbolIcon` + `Symbol` enum** — preferred. The member is a stable API
  name; kaya never writes a codepoint. Only a subset of the font is in the
  enum.
- **`FontIcon` + `Glyph` codepoint** — the fallback for concepts the enum
  never got (info, warning, error, lock, chevrons, open-folder).

Both resolve their font through the `SymbolThemeFontFamily` theme resource,
so **neither route sets a FontFamily**: "Rather than specifying a FontFamily
directly, FontIcon and SymbolIcon use the font family defined by the
`SymbolThemeFontFamily` XAML theme resource" (Icons in Windows apps). A
FontIcon with no FontFamily, or one naming a font absent at runtime, falls
back to that same resource.

## How each claim below was verified

Five checks, not one. `[VERIFIED]` on a row means it passed all that apply.

1. **Enum member, numeric value, glyph code** — Microsoft Learn, *Symbol Enum
   (Microsoft.UI.Xaml.Controls)*, Windows App SDK 2.0 moniker:
   https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.symbol
   Cross-checked against the UWP twin (same names, same values, legacy E1xx
   glyph codes):
   https://learn.microsoft.com/en-us/uwp/api/windows.ui.xaml.controls.symbol
2. **Glyph name ↔ codepoint** — extracted mechanically from the Segoe Fluent
   Icons catalog HTML (`<img src="images/segoe-fluent-icons/eXXX.png"
   alt="Screenshot of NAME.">`), **1413 pairs**, no summarizer in the loop:
   https://learn.microsoft.com/en-us/windows/apps/design/iconography/segoe-fluent-icons-font
   (the `/design/style/` URL 301s to `/design/iconography/`). Saved as
   `fluent-catalog.json` next to this report.
3. **Codepoint exists in the shipped font** — downloaded Segoe Fluent Icons
   (https://aka.ms/SegoeFluentIcons) and parsed the `cmap` directly
   (`dumpfont.py`, no dependencies). 1437 glyphs, 1832 mapped codepoints.
   Every codepoint below resolved to a real glyph id; none was ABSENT.
4. **Shape** — downloaded Microsoft's own 32×32 renderings of 38 glyphs and
   looked at them (`sheet.png`). This is the check that caught the `Error`
   trap below; a name-only reading would have shipped the wrong glyph.
5. **Windows 10 fallback** — the same extraction run against the Segoe MDL2
   Assets catalog: **33 of 33** codepoints used here are present there too:
   https://learn.microsoft.com/en-us/windows/apps/design/iconography/segoe-ui-symbol-font
6. **Presence in the SDK kaya actually pins** — string scan of
   `third_party/winappsdk/Microsoft.WindowsAppSDK.WinUI-2.2.1/extracted/metadata/Microsoft.UI.Xaml.winmd`:
   all 30 `Symbol` members probed and all 11 icon types present.

## The table

`Symbol` column is the preferred route. `Glyph` is what `FontIcon` takes;
in Rust that is the one-character string, e.g. `"\u{E946}"`.

| # | kaya concept | Symbol member | value | Glyph | Fluent name | shape seen | status |
|---|---|---|---|---|---|---|---|
| 1 | add | `Symbol.Add` | 57609 | U+E710 | Add | plus sign | [VERIFIED] |
| 2 | remove | `Symbol.Remove` | 57608 | U+E738 | Remove | single minus stroke | [VERIFIED] |
| 3 | delete (trash) | `Symbol.Delete` | 57607 | U+E74D | Delete | trash can with lid | [VERIFIED] |
| 4 | edit (pencil) | `Symbol.Edit` | 57604 | U+E70F | Edit | pencil, tip lower-left | [VERIFIED] |
| 5 | done (checkmark) | `Symbol.Accept` | 57611 | U+E8FB | Accept | bare checkmark | [VERIFIED] |
| 6 | close (x) | `Symbol.Cancel` | 57610 | U+E711 | Cancel | X | [VERIFIED] |
| 7 | search (magnifier) | `Symbol.Find` | 57626 | U+E721 | **Search** | magnifier | [VERIFIED] — name mismatch, see note |
| 8 | share | `Symbol.Share` | 59181 | U+E72D | Share | box with arrow leaving it | [VERIFIED] |
| 9 | settings (gear) | `Symbol.Setting` | 57621 | U+E713 | Settings | gear | [VERIFIED] — member is SINGULAR |
| 10 | save | `Symbol.Save` | 57605 | U+E74E | Save | floppy disk | [VERIFIED] |
| 11 | open (folder) | *(see note)* | — | U+E838 | FolderOpen | open folder | [VERIFIED] — **no enum member for the folder shape** |
| 12 | refresh (arrows) | `Symbol.Refresh` | 57673 | U+E72C | Refresh | one circular arrow | [VERIFIED] |
| 13 | info | **none** | — | U+E946 | Info | circle with "i" | [VERIFIED] — FontIcon only |
| 14 | warning | **none** | — | U+E7BA | Warning | triangle with "!" | [VERIFIED] — FontIcon only |
| 15 | error | **none** | — | U+EA39 | ErrorBadge | circle with X | [VERIFIED] — FontIcon only, see trap |
| 16 | back (chevron) | `Symbol.Back` | 57618 | U+E72B | Back | left **arrow** | [VERIFIED] — arrow, not chevron |
| 16b | back, true chevron | **none** | — | U+E76B | ChevronLeft | chevron "<" | [VERIFIED] |
| 17 | forward (chevron) | `Symbol.Forward` | 57617 | U+E72A | Forward | right **arrow** | [VERIFIED] — arrow, not chevron |
| 17b | forward, true chevron | **none** | — | U+E76C | ChevronRight | chevron ">" | [VERIFIED] |
| 18 | menu (hamburger) | `Symbol.GlobalNavigationButton` | 59136 | U+E700 | GlobalNavButton | three stacked lines | [VERIFIED] |
| 19 | more (ellipsis) | `Symbol.More` | 57612 | U+E712 | More | three dots, horizontal | [VERIFIED] |
| 20 | copy | `Symbol.Copy` | 57711 | U+E8C8 | Copy | two overlapping pages | [VERIFIED] |
| 21 | paste | `Symbol.Paste` | 57709 | U+E77F | Paste | clipboard with page | [VERIFIED] |
| 22 | star, unset | `Symbol.OutlineStar` | 57806 | U+E734 | FavoriteStar | outline star | [VERIFIED] |
| 22b | star, set | `Symbol.SolidStar` | 57807 | U+E735 | FavoriteStarFill | solid star | [VERIFIED] |
| 23 | lock | **none** | — | U+E72E | Lock | closed padlock | [VERIFIED] — FontIcon only |
| 24 | person | `Symbol.Contact` | 57661 | U+E77B | Contact | head and shoulders | [VERIFIED] |
| 25 | home | `Symbol.Home` | 57615 | U+E80F | Home | house | [VERIFIED] |

All 25 concepts have a native mapping. **Six** of them (open-as-folder, info,
warning, error, lock, and the chevron spellings of back/forward) are not in
the `Symbol` enum and need the `FontIcon` route — so the WinUI arm must
support both routes, not just the enum. The docs say so plainly: "Only a
small subset of Segoe Fluent Icon glyphs are available in the Symbol
enumeration."

## Traps, each one measured

**`Error` (U+E783) is not an error icon.** The glyph *named* Error draws a
circle with an **exclamation mark**, which collides with `Warning`
(U+E7BA)'s triangle-plus-exclamation. The circle-with-X — what the concept
"error" wants — is **`ErrorBadge` U+EA39**. I only know this because I
rendered them side by side; both catalog pages list `Error = U+E783` with no
hint of the shape. `StatusErrorFull` U+EB90 is the same circle-X filled
solid, for when a filled status dot is wanted.

**`Symbol.Find` draws the magnifier named `Search`.** The enum member and
the glyph disagree on the name (member `Find` = 57626 → U+E721, whose
catalog name is `Search`). Do not go looking for a `Symbol.Search`; it does
not exist. Separately, `Symbol.Zoom` (57763, U+E71E) is a *different*
magnifier meaning zoom — do not use it for search.

**`Symbol.Setting` is singular.** No trailing "s" on the member, although
the Segoe Fluent Icons catalog names the glyph `Settings` (and the MDL2
catalog names it `Setting`). A C#/Rust binding written from the glyph name
will not compile.

**Back and Forward are arrows, not chevrons.** `Symbol.Back` (U+E72B) and
`Symbol.Forward` (U+E72A) are full left/right arrows — which is the correct
Windows convention for a navigation back button. If kaya's `back` concept
means a disclosure chevron in a list row, that is `ChevronLeft` U+E76B /
`ChevronRight` U+E76C, and neither has an enum member. This is a real
semantic fork: decide which one `back` means before wiring it.

**"open" splits in two.** There is no enum member whose glyph is an open
folder. `Symbol.OpenFile` (57765, U+E8E5) looks like a **document with an
up-arrow badge**, not a folder; `Symbol.Folder` (57736, U+E8B7) is a
**closed** folder. Only `FolderOpen` U+E838 (FontIcon) is the open folder.
Choose by meaning: the open-a-file *command* → `Symbol.OpenFile`; the folder
*object* → U+E838.

**`Symbol.Favorite` is a duplicate of `Symbol.OutlineStar`.** Both are
U+E734. Use the `OutlineStar`/`SolidStar` pair so the unset and set states
are obviously siblings.

**Two checkmarks, plus a circled one.** `Symbol.Accept` (U+E8FB) and
`CheckMark` (U+E73E, no enum member) are both bare checkmarks and look
nearly identical at 32px. `Completed` (U+E930) is the checkmark inside a
circle, if "done" wants to read as a status rather than an action.

**Two X's.** `Symbol.Cancel` (U+E711) is the general-purpose X. `ChromeClose`
(U+E8BB, no enum member) is the heavier X used for window close buttons —
noticeably bolder in the rendering. Use Cancel for in-content close.

## Version gating

- **Segoe Fluent Icons ships with Windows 11.** On Windows 10 it is not
  present ("Windows 10: users must download it"), and `SymbolThemeFontFamily`
  falls back to **Segoe MDL2 Assets** on "Windows 10, version 20H2 or
  earlier". **This costs kaya nothing**: all 33 codepoints used above are in
  the MDL2 catalog too (checked mechanically, 33/33), so no per-OS branch and
  no font shipping. Note the fallback also renames things — MDL2 calls U+E700
  `GlobalNavigationButton` and U+E713 `Setting`, Fluent calls them
  `GlobalNavButton` and `Settings`. Codepoints identical; only names moved.
- **The font may not be shipped with the app.** Microsoft's page: available
  for download for design use, but "cannot be shipped to another platform".
  So the GTK/mac/Android columns cannot reuse these glyphs — they need their
  own catalogs, which is exactly why the mapping is per-backend.
- **Windows App SDK 1.4 and earlier used E1xx glyph codes** for the Symbol
  enum; **1.5 and later remapped** to the E7xx/E8xx codes in the table. kaya
  pins Foundation 2.1.0 / WinUI 2.2.1 (`tools/fetch-winappsdk.sh`), so it is
  firmly on the new mapping. This matters for the FontIcon column only: pass
  E7xx/E8xx, never the E1xx codes the UWP documentation still shows.
- **UWP-only gate, noted for completeness:** `GlobalNavigationButton`,
  `Share`, `Print`, `XboxOneConsole` were added to the *UWP* enum in Windows
  10 1709 / SDK 16299. Under WinUI 3 the enum comes from the App SDK, not the
  OS, so kaya is not exposed to this.
- No other candidate in this set is version-gated. Everything else has been
  in the enum since Windows 10 10240.

## What this costs kaya to implement (read before scheduling D6)

**The WinUI backend cannot construct an icon today.** Verified two ways:

- `tools/winui-bindgen/src/main.rs` — 160 filter entries, and `grep` for
  `Symbol|FontIcon|IconElement|IconSource|Glyph` returns **nothing**.
- `crates/kaya/src/winui/bindings.rs` — `grep -c SymbolIcon` → **0**,
  `grep -c FontIcon` → **0**.

That file's own comment states the rule: "each type is named explicitly
because the filter never pulls referenced types transitively
(docs/traps.md)" — so the icon work starts by adding filter entries and
regenerating. Minimum set for the table above:

```
Microsoft.UI.Xaml.Controls.IconElement     // the base both routes return
Microsoft.UI.Xaml.Controls.Symbol          // the enum (unfiltered enum => vtable pad)
Microsoft.UI.Xaml.Controls.SymbolIcon      // route 1, 19 of 25 concepts
Microsoft.UI.Xaml.Controls.FontIcon        // route 2, the other 6 — NOT optional
```

All four names are present in the pinned `Microsoft.UI.Xaml.winmd`
(WinUI 2.2.1), along with `IconSource`, `IconSourceElement`, `FontIconSource`,
`SymbolIconSource`, `AnimatedIcon`, `BitmapIcon` and `PathIcon` if a later
slice wants them.

Placement: `IconElement` is a `FrameworkElement`, so it can be a `Button`'s
`Content` directly (kaya already filters in `Button` and `ContentControl`).
Controls with a dedicated slot — `AppBarButton.Icon`, `MenuFlyoutItem.Icon`,
`NavigationViewItem.Icon` — take an `IconElement`; the `*IconSource` spellings
take an `IconSource` instead. Icon-plus-label needs a `StackPanel`, per the
documented pattern.

## Sources

- Symbol enum, WinUI 3 / Windows App SDK 2.0 — https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.symbol
- Symbol enum, UWP (values cross-check, E1xx legacy codes, 1709 additions) — https://learn.microsoft.com/en-us/uwp/api/windows.ui.xaml.controls.symbol
- Segoe Fluent Icons catalog — https://learn.microsoft.com/en-us/windows/apps/design/iconography/segoe-fluent-icons-font
- Segoe MDL2 Assets catalog (Windows 10 fallback) — https://learn.microsoft.com/en-us/windows/apps/design/iconography/segoe-ui-symbol-font
- Icons in Windows apps (SymbolThemeFontFamily, FontIcon fallback, icon slots) — https://learn.microsoft.com/en-us/windows/apps/design/style/icons
- FontIcon.FontFamily — https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.fonticon.fontfamily
- Font binary — https://aka.ms/SegoeFluentIcons (parsed, then deleted; see below)

## Artifacts kept next to this report

- `fluent-catalog.json` — 1413 codepoint → glyph-name pairs, machine-extracted.
  The next agent should map against this rather than re-reading prose.
- `fluent-sheet.png` — the 38-glyph labelled contact sheet the shape column
  came from (696×1015, 6 per row, each labelled with its codepoint).
- `fluent-dumpfont.py` — dependency-free cmap reader, if a codepoint needs
  re-checking against a font binary.

(All three carry the `fluent-` prefix because this directory is shared with
the SF Symbols, Material and Adwaita columns.)

The font itself (`segoe.zip`, `segoe/`), both catalog HTML dumps and the raw
glyph PNGs were deleted after use — the font's EULA allows design use but not
redistribution, so it should not linger in a scratch tree.
