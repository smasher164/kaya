# Fluent's pale accent surface for text: research (2026-09-25)

Status: complete. Sources were read from GitHub raw source at `master`/`main` on 2026-09-25. Local copies and the python port are in `scratchpad/fs/`: `ramp.py` is a line-for-line port of the theme designer's generator, and `calc.py` holds the contrast and compositing helpers.

Short answer: Fluent 2 draws the user's own chat bubble with **`colorBrandBackground2`**, which is **brand[160] in light and brand[20] in dark**, with **`colorNeutralForeground1`** text. WinUI 3 has no brush for a pale accent surface. `SystemAccentColorLight3` and `Dark3` are Windows' text and emphasis shades, not surface shades. The rule that reproduces Fluent 2's own step in light and lands in WinUI's own severity-background lightness band in dark is **the accent composited at about 8% over white in light and about 20-25% over the dark base in dark**.

---

## 1. How Fluent 2 builds a brand ramp from one key colour

| Claim | Verdict | Source |
|---|---|---|
| A brand ramp is `BrandVariants` with 16 steps, 10..160. The shipped ramps (`brandWeb` key `#0f6cbd`, `brandTeams` key `#5b5fc7`, `brandTeamsV21`, `brandOffice`) are **hard-coded hex tables**, not computed at run time. | CONFIRMED | https://github.com/microsoft/fluentui/blob/master/packages/tokens/src/global/brandColors.ts |
| `createLightTheme(brand)` and `createDarkTheme(brand)` take any `BrandVariants` and map semantic tokens onto its steps (`generateColorTokens(brand)`). Teams dark uses `createTeamsDarkTheme` (`alias/teamsDarkColor.ts`). | CONFIRMED | https://github.com/microsoft/fluentui/blob/master/packages/tokens/src/themes/teams/darkTheme.ts ; .../src/utils/createTeamsDarkTheme.ts |
| The public generator is `getBrandTokensFromPalette(keyColor, {darkCp, lightCp, hueTorsion})` in the **theme designer** package (react-components/theme-designer, the tool behind the Fluent theme designer page). It is not exported from `@fluentui/tokens`. | CONFIRMED | https://github.com/microsoft/fluentui/blob/master/packages/react-components/theme-designer/src/utils/getBrandTokensFromPalette.ts |
| The algorithm works in CIELAB (D50, CSS Color 4 conversions). It lays two quadratic Béziers: black (L0) to key to white (L100), with control points `[L*(1-darkCp), a, b]` and `[L+(100-L)*lightCp, a, b]`. An optional hue torsion twists the curve into a helix. It then samples 16 lightness values with **linearity = 1** (purely linear through a per-hue centre), clamped to the range `[min, max]` from the lookup table `hueToSnappingPointsMap[hue]`. The hue is the HSL hue, rounded to a degree. Each sample is gamut-snapped by binary search on LCH chroma. | CONFIRMED (source read) | .../theme-designer/src/colors/palettes.ts ; geometry.ts ; csswg.ts ; hueMap.ts |
| The table's max is about 0.859, so **the generated brand160 has L\* ≈ 86**. The shipped hand-tuned ramps sit much paler, at L\* 92.5-95.4 (below). The designer's output is therefore a darker bubble than Teams and Web actually ship. | CONFIRMED from source values; hex outputs from my python port are UNVERIFIED against a JS run | hueMap.ts (last column ~0.8585-0.859) |
| Designer UI defaults: vibrancy 0 gives `darkCp = lightCp = 0`, and hue torsion 0. The function's own defaults are 2/3 and 1/3. In dark the designer also overrides `colorBrandForeground1` to brand110 and `colorBrandForeground2` to brand120. | CONFIRMED | .../theme-designer/src/components/Sidebar/Form.tsx (useState(0)) ; .../Context/ThemeDesignerContext.tsx ; .../utils/getOverridableTokenBrandColors.ts |

Measured lightness of the shipped ramps (CIELAB D50, my calc):

| Ramp | 160 (light bubble) | 150 | 20 (dark bubble) | 30 | 80 (key) |
|---|---|---|---|---|---|
| brandWeb | #ebf3fc L95.4 C5.5 (0.11×Ckey) | #cfe4fa L89.5 | #082338 L12.6 C17.3 (0.34×Ckey) | #0a2e4a L17.7 | #0f6cbd L44.1 |
| brandTeams | #e8ebfa L93.1 C7.7 (0.13×) | #dce0fa L89.5 | #2f2f4a L20.4 C17.8 (0.30×) | #333357 L22.6 | #5b5fc7 L44.2 |
| brandTeamsV21 | #e8e8ff L92.5 C11.6 (0.12×) | #dcdbff L88.3 | #2f2a5e L19.9 C34.1 (0.36×) | #352e70 L22.8 | #654cf5 L43.7 |

The ported generator's output for `#0078D4`, vibrancy 0: brand160 `#cbd8f5` (L86) and brand20 `#111723` (L7.6). With the function defaults: brand160 `#c6d9ff` and brand20 `#001833`. (UNVERIFIED port)

## 2. Semantic brand tokens: light versus dark

Source: https://github.com/microsoft/fluentui/blob/master/packages/tokens/src/alias/lightColor.ts and .../darkColor.ts; the Teams dark mapping is .../alias/teamsDarkColor.ts. The hex values in these files' comments are stale. The values below resolve the steps against `brandWeb`. All rows CONFIRMED.

| Token | Light | Dark (web, and Teams) |
|---|---|---|
| colorBrandBackground | brand80 | brand70 |
| **colorBrandBackground2** | **brand160** (#ebf3fc) | **brand20** (#082338; Teams #2f2f4a) |
| colorBrandBackground2Hover | brand150 | brand40 |
| colorBrandBackground2Pressed | brand130 | brand10 |
| colorBrandBackground3 | *does not exist*; only `colorBrandBackground3Static` = brand60 (and `4Static` = brand40) | same |
| colorBrandBackgroundInverted | white (hover 160, pressed 140, selected 150) | white |
| colorCompoundBrandBackground | brand80 | brand100 |
| colorNeutralForeground1 | grey14 #242424 | white |
| colorNeutralForegroundOnBrand | white | white |
| colorNeutralBackground1 / 3 | #ffffff / #f5f5f5 | #292929 / #141414 (Teams 3 = #1f1f1f) |

- `colorBrandBackground2` is the subtle brand surface that carries ordinary `colorNeutralForeground1` text. `colorBrandBackground` and `colorCompoundBrandBackground` are saturated fills that take `ForegroundOnBrand` (white). CONFIRMED by the chat component below.
- **Teams "my message" bubble** (`@fluentui-contrib/react-chat`, whose README says it is the chat component "used in Microsoft Teams"): `ChatMyMessage` body `backgroundColor: tokens.colorBrandBackground2`, text `color: tokens.colorNeutralForeground1` (from `bodyBaseStyles`), corner radius 4px. The other party's bubble is `colorNeutralBackground3`. CONFIRMED.
  - https://github.com/microsoft/fluentui-contrib/blob/main/packages/react-chat/src/components/ChatMyMessage/ChatMyMessage.styles.ts
  - https://github.com/microsoft/fluentui-contrib/blob/main/packages/react-chat/src/components/styles/shared.styles.ts
  - https://github.com/microsoft/fluentui-contrib/blob/main/packages/react-chat/src/components/ChatMessage/ChatMessage.styles.ts
- Exact bubble: Teams light `#e8ebfa`, Teams dark `#2f2f4a`, Web light `#ebf3fc`, Web dark `#082338`. Text contrast is 13.1:1, 12.9:1, 13.9:1 and 16.1:1. CONFIRMED (token to step to hex).
- Note: web-dark brand20 (L12.6) is *darker* than web-dark page `colorNeutralBackground1` #292929 (L~17). Teams' ramp keeps brand20 at L~20, just above its page. For Windows, with its #202020 base and ~#2B2B2B cards, the Teams behaviour is the one to copy.
- I found no Fluent 2 design-site chat guidance. The contrib component is the primary evidence. (UNVERIFIED that a design page exists)

## 3. Fluent 2 status palette, for comparison

Source: .../tokens/src/alias/lightColorPalette.ts, darkColorPalette.ts, statusColorMapping.ts (success=green, warning=orange, danger=cranberry), global/colors.ts. All rows CONFIRMED.

| Token | Light | Dark |
|---|---|---|
| colorStatus*Background1 (**the pale surface**) | tint60 | shade40 |
| colorStatus*Background2 | tint40 | shade30 |
| colorStatus*Background3 (solid) | primary | primary |
| colorStatus*Foreground1 | shade10 (warning shade20) | tint30 |
| colorPalette{Color}Background1/2/3 | same pattern | same pattern |

Values: green tint60 `#f1faf1` L97.4 and shade40 `#052505` L11.8. Cranberry `#fdf3f4` L96.7 and `#3b0509` L9.8. Orange `#fff9f5` L98.3 and `#4a1e04` L17.7. So Background1 is the pale surface, just as brand160 and brand20 are for brand.

## 4. The Windows and WinUI 3 side

| Claim | Verdict | Source |
|---|---|---|
| Windows computes the Light1-3 and Dark1-3 shades itself. Learn says only "Accent color values are generated automatically and optimized for contrast in both light and dark modes"; the algorithm is **not documented**. Apps read the shades via `UISettings.GetColorValue(UIColorType.AccentLight3, …)`. | CONFIRMED (undocumented) | https://learn.microsoft.com/en-us/windows/apps/design/signature-experiences/color ; https://learn.microsoft.com/en-us/windows/apps/develop/ui/theming |
| Win11 default blue palette: Light3 #99EBFF, Light2 #4CC2FF, Light1 #0091F8, accent #0078D4, Dark1 #0067C0, Dark2 #003E92, Dark3 #001A68. The page says the Win11 algorithm differs from Win10's. | UNVERIFIED (third-party registry reader) | https://valer100.github.io/winaccent/colors/accent-color-and-shades/ |
| In WinUI's own brushes the Light3/Dark3 shades are **text and emphasis colours**. In the Dark dictionary, AccentTextFillColorPrimary = Light3 and AccentFillColorDefault = Light2. In Light, AccentTextFillColorPrimary = Dark2, Secondary = Dark3, and AccentFillColorDefault = Dark1. Using Light3 as a *light-theme* surface inverts its intended role, which explains the loud cyan. | CONFIRMED | https://github.com/microsoft/microsoft-ui-xaml/blob/main/controls/dev/CommonStyles/Common_themeresources_any.xaml (the `Default` dictionary is Dark) |
| **No WinUI 3 brush is a pale accent surface for text.** `AccentAcrylic*FillColor*` is acrylic tinted with Dark1/Dark2 (dark) or Light3 (light) at TintOpacity 0.8, a saturated accent material. `LayerOnAccentAcrylicFillColorDefault` (#40FFFFFF / #09FFFFFF) is a *neutral* layer on top of accent acrylic. `SystemFillColorAttentionBackground` (#80F6F6F6 / #08FFFFFF) is *neutral*; it is the InfoBar "informational" background. | CONFIRMED | Common_themeresources_any.xaml ; https://github.com/microsoft/microsoft-ui-xaml/blob/main/controls/dev/CommonStyles/AcrylicBrush_themeresources.xaml ; https://github.com/microsoft/microsoft-ui-xaml/blob/main/controls/dev/InfoBar/InfoBar_themeresources.xaml |
| **The selected item in WinUI 3's ListView and NavigationView is NOT accent-tinted.** `ListViewItemBackgroundSelected` and `NavigationViewItemBackgroundSelected` = `SubtleFillColorSecondaryBrush` (#09000000 light / #0FFFFFFF dark), foreground `TextFillColorPrimaryBrush`. The accent appears only as the selection pill (`ListViewItemSelectionIndicatorBrush` / `NavigationViewSelectionIndicatorForeground` = `AccentFillColorDefaultBrush`). ComboBoxItem selected is the same. ItemContainer's selection visual is the solid AccentFillColorDefault. | CONFIRMED | https://github.com/microsoft/microsoft-ui-xaml/blob/main/controls/dev/CommonStyles/ListViewItem_themeresources.xaml ; https://github.com/microsoft/microsoft-ui-xaml/blob/main/controls/dev/NavigationView/NavigationView_themeresources.xaml ; .../ComboBox/ComboBox_themeresources.xaml ; .../ItemContainer/ItemContainer_themeresources.xaml |
| The only accent-*tinted* text surface left in WinUI is the legacy Win10 one: `ListBoxItemBackgroundSelected` = `SystemControlHighlightListAccentLowBrush` = **SystemAccentColor at Opacity 0.4 (Light) / 0.6 (Dark)**, with primary text. For #0078D4 that is #99C9EE (L78) and #0D558C (L34), louder than today's choice. | CONFIRMED | https://github.com/microsoft/microsoft-ui-xaml/blob/main/controls/dev/CommonStyles/ListBox_themeresources.xaml ; https://github.com/microsoft/microsoft-ui-xaml/blob/main/dxaml/xcp/dxaml/themes/generic.xaml |
| WinUI's own pale severity surfaces (InfoBar): Success #DFF6DD / #393D1B, Caution #FFF4CE / #433519, Critical #FDE7E9 / #442726. That is **L\* 93.5-96.3 in light and 19.5-24.7 in dark**, chroma 8-21. | CONFIRMED (values); L\* my calc | Common_themeresources_any.xaml |

## 5. Recommendation

WinUI has no token of its own for this. Take Fluent 2's rule, "the user's bubble is `colorBrandBackground2` with `colorNeutralForeground1` text", and hit the lightness band that both Fluent 2's shipped ramps and WinUI's own severity backgrounds occupy.

**Rule (any accent A; opaque compositing in sRGB):**
- Light: `surface = A over white at α = 0.08` (equivalently `#14`-alpha A as a translucent brush). Text: `TextFillColorPrimary`.
- Dark: `surface = A over #202020 at α = 0.20-0.25`, or a translucent brush of A at that alpha over whatever layer sits beneath. Text: white (`TextFillColorPrimary`).

Why this rule:
- In light, 8% over white reproduces Fluent 2's brandWeb160 almost exactly. `#0F6CBD` gives `#ECF3FA`; shipped is `#EBF3FC`. It lands at L≈95, inside WinUI's severity band.
- In dark, 20-25% gives L 18-21, which matches Teams' brand20 (L20.4) and WinUI's Critical background (L19.5). It sits just above the #202020 base. Web-Fluent brand20 (L12.6) would read as a hole on Windows.
- It needs only `SystemAccentColor` (or the app brand colour). There is no dependency on Windows' undocumented Light3/Dark3 shades, so a branded app and the user's accent go through one path. That also closes the ledger's "brand dictionary only overrides the stops" gap.

The alternative is a perceptual rule: keep the accent's CIELAB hue and set L\*=95, C\*=0.12×C_accent (light) and L\*=20, C\*=0.33×C_accent (dark). These are the ratios measured on the shipped ramps. It gives nearly the same results for blue. It keeps chroma more even across hues, but it needs a Lab path in the backend and can push yellow down to muddy brown in dark (`#3F2C03` below).

Computed for the default Windows blue **#0078D4** (python, `scratchpad/fs/calc.py`):

| Candidate | Light | Dark |
|---|---|---|
| Today: Light3 / Dark3 | #99EBFF L88 C28.7, text 13.3:1 | #001A68 L13 C52.7 |
| Legacy ListAccentLow (0.4 / 0.6) | #99C9EE L78.5 | #0D558C L34.4 |
| Theme designer brand160/20, vibrancy 0 (port) | #CBD8F5 L86 | #111723 L7.6 |
| **Recommended: 8% over #FFFFFF / 20% over #202020** | **#EBF4FC** L95.7 C5.3, text 15.7:1 | **#1A3244** L19.5 C15.2, white 13.3:1 |
| Dark at 25% over #202020 | n/a | #18364D L21.2, white 12.6:1 |
| Dark at 20% over a #2B2B2B card | n/a | #223A4D |
| Perceptual rule (L95 C0.12× / L20 C0.33×) | #ECF1FE | #20314B |
| Fluent 2 shipped for comparison | Web #EBF3FC, Teams #E8EBFA | Teams #2F2F4A, Web #082338 |

Other accents under the recommended rule (light 8% over white | dark 20% over #202020): Teams #5B5FC7 gives #F2F2FB and #2C2D41. Red #E81123 gives #FDECED and #481D21. Green #107C10 gives #ECF5EC and #1D321D. Gold #FFB900 gives #FFF9EB (L98, the palest) and #4D3F1A (L27.5, the lightest). Purple #881798 gives #F5ECF7 and #351E38. The perceptual rule for gold gives #FBEFDE and #3F2C03.

Caveats:
- The Fluent designer port is not cross-checked against a JS run. It matters only for the "designer brand160" row.
- High Contrast must still map the surface to a system colour; WinUI's HC dictionaries use `SystemColorWindowColor` and `SystemColorHighlightColor`.
- "8%" and "20-25%" are fitted to Fluent's shipped hex, not constants Microsoft publishes.
