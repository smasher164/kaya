# The styling/branding pass — the design

Ratified with Akhil 2026-08-12, on top of DESIGN.md's "Brand identity
and the styling ceiling" (the three-verdict frame: brand slots ADMITTED,
semantic roles ADMITTED, arbitrary per-widget appearance REFUSED). Six
research reports back this plan — one per backend, one comparative
survey of ten toolkits, one on adaptive-color correctness — in the
session scratchpad (styling/*.md), each claim cited, several measured
rather than read. The findings that survive into decisions are restated
here so the plan stands alone.

## §0 — what the research settled

**The frame's history.** Closed app-level color slots over native
widgets is the DEFAULT design, not an experiment — QPalette's ~20 roles
since 1996, libadwaita's 31 named colors, Apple's AccentColor, the web's
accent-color. The two toolkits that broke their ceiling (Qt to
stylesheets, SWT to a bolted-on CSS engine) both broke the same way:
colors WITHOUT semantics. Qt's own documentation names "red text for
potentially destructive push buttons" as what a palette cannot say. That
is kaya's `role: destructive`, which is why THE ROLE TIER SHIPS WITH THE
BRAND TIER — the semantic tier is not a follow-up, it is the part whose
absence historically forced the escalation the ceiling exists to refuse.

**Read-backs lie on every platform.** macOS `controlAccentColor` reads
are poisoned (FB13688723); GTK's AdwStyleManager returns the SYSTEM
accent after an app override succeeds, `@accent_bg_color` does not read
`--accent-bg-color`, `has_icon()` is presence-not-loadability, and
same-turn pixel reads are stale; WinUI's `SystemAccentColor` write
silently no-ops (microsoft-ui-xaml#6394, docs still publishing the
broken snippet) and the SAME trap shape repeats for its typeface ramp
(XamlAutoFontFamily hard-coded) and icons; Material's static
ColorScheme silently ignores Android 14's contrast slider (MDC #3524).
CONSEQUENCE, and it is doctrine-shaped: the styling scene asserts
PIXELS or real-token reads, never API read-backs, and every lowering
lands with a negative test that watches the write actually take.

**Nobody computes a foreground to fit an accent.** Every platform
shifts the ACCENT until a fixed foreground works, and the two that do
compute foregrounds disagree (SwiftUI flips at luminance 0.5, measured;
Material at 0.281). The safe design is a clamp, not a contrast solver.

## §1 — the decisions

### D1 — the accent slot (ratified as researched)

```
brand.accent : Accent
Accent ::= one sRGB hex                    # required; most apps write only this
         | { any, light?, dark? }          # optional per-appearance override
         | { <platform>: Accent, ... }     # optional per-platform override — VALUES only
```

Three hard rules, each with its reason:

1. **The app never writes a foreground.** kaya computes it. An
   app-supplied pair can be illegible with nothing to catch it, and
   three of four platforms hard-code or compute the foreground anyway —
   an app value would be honored on some platforms and ignored on
   others, which is invariant-1 divergence by construction.
2. **The app never writes contrast variants.** Derived from the
   appearance and the platform's contrast signal (including Android
   14's slider, which a static scheme silently ignores — the M3 trap).
3. **Unstated cells default from the one written hex.** One hex in, a
   correct four-platform, two-appearance, three-contrast result out.

The derivation is ONE function in the core (Rust), producing per
appearance: `fill` (perceptual lightness clamped OUT of the L* 60–76
danger band where the platforms' foreground rules disagree), `on_fill`
(L* < 60 → white, else black — reproduces 8 of 9 GNOME accents, both
Apple blues, both WinUI pairings), `standalone` (libadwaita's rule
verbatim — accent-colored text on a neutral surface needs a different
number than a fill), and a small hover/pressed ramp. Backends receive
VALUES; no backend re-derives.

Per-platform lowering of those values:
- SwiftUI: `.tint` at the root; the asset-catalog dark variant where a
  per-appearance override was authored.
- Material: the hex is the SEED of the documented custom-brand flow
  (one hex → the full role scheme, deterministically); contrastLevel
  from UiModeManager.
- libadwaita: `--accent-bg-color`/`--accent-fg-color`/standalone via
  the documented override route (adw feature bump v1_4 → v1_7).
- WinUI: the SIX SystemAccentColor* stops in ThemeDictionaries — never
  SystemAccentColor itself — minding the cross-reads (light theme reads
  Dark1, dark reads Light2), Light+Dark dictionaries only (D4's
  high-contrast rule owns the third).

### D2 — the accent is a REQUEST, uniformly (ratified; mac yield DROPPED 2026-08-12)

**AS REVISED (maintainer, 2026-08-12): a declared brand wins on every
platform.** The original reading kept a macOS yield — the interpreter
returned no tint when the user's AppleAccentColor preference was set,
implementing the HIG's accent-ASSET convention ("the system applies
your accent color when the user's setting is multicolor") on top of
SwiftUI's `.tint()`, which never needed it: the tint is an explicit
environment value the system does not arbitrate, which is how every
heavily-styled native mac app paints its own colors. Meanwhile the
other three backends already branded unconditionally (GTK's per-app
CSS override, WinUI's theme-dictionary stops and Compose's
seed-derived scheme all shadow their platform's user accent), so the
yield was the vocabulary's one divergence, not its rule. Dropped —
the mac arm now paints the derived tint whenever a brand is declared.

What survives of the request semantics: a BRANDLESS app gets the
platform default everywhere, and on macOS that default IS the user's
accent preference (nil tint = the environment's own value). The same
sentence still covers Android dynamic color below.

MEASURED 2026-08-12, pixels on an active window: with the machine's
AppleAccentColor forced to purple, the styling scene's prominent
button paints the BRAND fill, both appearances (the capture set
beside the artifact). Two findings came out of taking that
measurement rather than trusting the docs:
- **The brand had no pipe into AppKit at all.** The mac button is an
  NSButton bridge (the SDK-stamp bezel bug), and an NSButton never
  reads SwiftUI's `.tint` environment — so the root tint reached
  every SwiftUI control and NO mac button, which is why the first
  hand-run looked unbranded regardless of the yield. The prominent
  role now carries the derived fill as `bezelColor`, per appearance
  via a dynamic provider; brandless stays nil and the system paints
  the user's accent.
- **An unbundled binary's default activation policy is PROHIBITED**
  (policy=2 measured), which also leaves the AX tree partially
  unpublished — the accessory call was RAISING guests, not lowering
  them. KAYA_ACTIVATE=1 now sets `.regular` explicitly for pixel
  proofs; the lanes never set it and stay accessory.

The same sentence covers Android dynamic color: if the app requests a
brand accent, kaya builds the static scheme from it (brand wins); an
app that requests NOTHING gets the platform default, which on Android
12+ is the user's wallpaper-derived palette. Opting into dynamic color
WHILE branded is not offered in v1 (it is a per-app setting real apps
expose as user choice; kaya has no settings surface to hang it on —
ledgered).

### D3 — the window content inset is LAYOUT (ratified)

The 16-unit root inset every backend applies today becomes a WINDOW
prop, `inset`, beside title/size/dirty — defaulting to 16 so no
existing scene moves; the editor asks for 0. Spec-first, additive, the
dirty-state milestone's shape (the ledger's costing (a); (b), container
padding, stays refused — DESIGN.md names a padding override as exactly
what the dressed floor exists to refuse, and D3 does not reopen it).

Akhil's "advisory at best?" instinct, answered by splitting the fact:
the inset is KAYA'S OWN padding, added inside the root by our
interpreters, so honoring 0 is unconditional on every platform —
nothing platform-side defends it. What stays advisory is the SAFE AREA
on mobile (notch, home indicator): those regions are not kaya's inset
and are not removed by inset 0; content extends to the safe-area edge,
and the platform keeps flowing like itself. Two facts, one knob, and
the knob is fully honorable.

### D4 — the role vocabulary opens with three (ratified)

`destructive` (buttons), `prominent` (buttons — the one-primary-action
affordance), `heading` (labels). Per-widget, closed set, never a raw
value — the menu-role grammar one tier over. Lowerings:

- destructive: `.buttonRole(.destructive)` / M3 error-role container /
  `.destructive-action` / (WinUI has no first-class destructive
  affordance — the lowering styles via the error/critical brushes, and
  the arm SAYS SO in its comment rather than pretending Fluent has one).
- prominent: `.borderedProminent` / M3 filled button /
  `.suggested-action` / `AccentButtonStyle`.
- heading: the platform's heading trait/semantics — AX trait on Apple,
  Compose heading semantics, AT-SPI heading role, Narrator
  HeadingLevel. ALSO the accessibility story: a heading role is how
  assistive users skim, which is why it is a role and not a font size.

WHICH WALL HOLDS WHICH ROLE, stated up front because they differ:
`heading` is observable in every platform's accessibility tree, so the
styling scene freezes it with expect_ax on all five lanes. `destructive`
and `prominent` have NO AX-visible marker on SwiftUI — the observable is
the tint itself — so they are held by lowering-side gates (every
backend's render arm consumes the role, the check-universal-props
shape) plus pixel probes where the platform permits one, and the scene
does NOT pretend to freeze what it cannot read. A weaker wall stated
plainly beats a stronger-looking one that is vacuous.

The root refuses a role on a kind it does not fit (destructive on a
label dies at declare time, in the root's words, before a backend sees
it) — check_prop's precedent.

### D5 — the vocabulary is closed to APPS, extensible by KAYA (ratified)

Akhil, 2026-08-12: kaya can extend what is supported — roles, slots,
rendering — through its own work on the widgets and lowerings. That is
DESIGN.md's lowering-tier-2 escape (interpreter-internal, invisible to
apps) plus ordinary vocabulary growth: a new role or slot is a spec
change, ratified, landing in all backends with its gates — exactly how
MENU_ROLES grows, with check-roles as the model. What it is NEVER is a
per-app or per-widget escape hatch; the ceiling stays chosen.

### D6 — typeface and icons are SLICE 2, shaped now, built after

Both are ratified in DESIGN.md; the research adds the hard facts, and
they are recorded here so slice 2 starts from evidence:

- **Typeface substitutes the family, never the scale** (ratified
  DESIGN.md). New facts: macOS has NO Dynamic Type (per Apple DTS) —
  what scales there is user font-size preference in a few places only;
  a custom family on Apple loses Bold Text response and SF Symbols'
  metric matching (symbols track the SYSTEM font); WinUI's type ramp
  hard-codes XamlAutoFontFamily, so family substitution must override
  the ramp resources — the accent trap's typeface twin.
- **Icons are semantic NAMES, closed set, mapped per platform**
  (ratified DESIGN.md). New facts: SF Symbols are license-locked to
  Apple platforms — which VALIDATES names-not-bytes, since no shared
  asset is even legal; Material Symbols are Apache (usable anywhere) —
  the fallback family where a platform set lacks a concept;
  material-icons-extended is frozen at 1.7.8; the linux container is
  MISSING librsvg2-common, so no SVG icon renders on that lane today —
  fixed in slice 2's first commit or no icon leg can ever pass.

## §2 — what this pass does NOT do (recorded)

- No per-widget appearance: no colors, radii, or padding on a widget.
  Unchanged, load-bearing, the ceiling's whole point.
- No stylesheet or theme-object surface. The comparative survey's
  no-ceiling cases (Flutter, CMP, Electron) all pay in native fidelity;
  kaya's bet is the opposite one.
- No dynamic-color opt-in while branded (D2; ledgered).
- No runtime theme SWITCHING surface: slots are set at build, once.
  WinUI resource reloads and Compose recomposition make runtime
  switching a per-platform research problem with no current consumer;
  the vocabulary does not promise it, so adding it later is additive.
- Vector/resolution-independent app art (the Blob icon path) stays as
  is; the ledger keeps the open question.

## §3 — sequencing (depth then breadth, per doctrine)

Slice 1 — the accent + roles + inset core:
1. Spec: `brand.accent` (D1's grammar), window `inset`, widget `role` —
   one spec change, hash moves, everything regenerates.
2. Core: the derivation function with its unit tests (the danger-band
   clamp is pure math — property-testable), declare-time role/kind
   checks.
3. Compose interpreter FOUNDATION: a MaterialTheme root (there is NONE
   today — Android has no theme root to hang anything on). This lands
   before any Android styling can exist at all.
4. SwiftUI depth slice: accent + roles + inset on mac, the styling
   scene (pixel/AX assertions per D4's walls), rust guest, mac green.
5. Fan out backends (GTK: adw v1_4→v1_7 bump rides along; WinUI: the
   six stops + startup dictionaries), then bindings (the slot spelling
   in eight languages), then guests.
6. The editor asks for inset 0 — the forcing artifact takes its
   full-bleed, which is the visible payoff of D3.
7. Gates: the role vocabulary gets check-roles' sibling (a role reaches
   every backend's arm); every lowering write gets its watched negative
   (the read-backs-lie rule); ladder.

Slice 2 — typeface + icons, on D6's facts, after slice 1's matrix is
green. Its plan section is this document's D6 plus whatever slice 1
taught.
