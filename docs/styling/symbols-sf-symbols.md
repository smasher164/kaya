# Semantic icon names — the SF Symbols column (Apple: mac + iOS)

Target API: `Image(systemName:)` (SwiftUI) / `UIImage(systemName:)` (UIKit) /
`NSImage(systemSymbolName:accessibilityDescription:)` (AppKit).
Floor for this column: **macOS 13.0**, which is exactly **SF Symbols 4**
(confirmed below). kaya's SwiftUI interpreter serves mac AND iOS from one file
(swift/KayaSwiftUI.swift), so every row carries its iOS minimum too; the pairs
line up (SF Symbols year 2022 = macOS 13.0 / iOS 16.0).

Status: COMPLETE. 24/24 candidates resolved. Nothing in the recommended column
needs an OS above kaya's floor; the highest requirement in the whole table is
macOS 12.0.

## How each name was verified

Three sources, and the table says which carried each row.

**1. The catalog Apple ships, read on this machine — not recalled.**
`/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/`
(machine: macOS 26.5.2, build 25F84, so the catalog is current and contains
symbols far newer than kaya's floor):

- `name_availability.plist` — 9184 symbol names, each mapped to its introduction
  year, plus a `year_to_release` table giving the exact macOS/iOS/tvOS/watchOS
  version per year. This is the same data the SF Symbols app shows, and it is
  what every availability claim below is computed from.
- `semantic_to_descriptive_name.strings` — 15 entries. **Apple's own semantic
  name -> catalog name map.** Directly relevant to D6; quoted in full below.
- `symbol_search.plist` — 3189 symbols with Apple's search keywords. Inverting it
  gives Apple's own answer to "which symbol means *save*", and it is the source
  for the concept-fit judgements. Where it returns nothing for a concept, the
  report says so instead of inventing a mapping.
- `name_aliases.strings` — 970 old-name -> new-name pairs. This is what exposed
  the rename trap, which is the load-bearing finding of this column.
- `symbol_restrictions.strings` — 605 symbols Apple restricts to referring to
  Apple products/services. Every recommended name was checked against it; none
  is restricted.
- `nofill_to_fill.strings` — 2825 outline -> filled pairs, for selected states.
- `legacy_flippable.plist` — 75 symbols the system mirrors in right-to-left
  layouts. Settles the chevron question below.

**2. A live resolution check, with canaries.** All 25 recommended strings were
passed to `NSImage(systemSymbolName:accessibilityDescription:)` in a compiled
Swift program on this machine. All 25 resolved; two deliberately bogus names
(`kaya.definitely.not.a.symbol`, `house.of.leaves.bogus`) returned nil. The
canaries matter: without them a run in which everything resolves proves nothing,
because a check that cannot fail agrees with any name. Harness kept at
`docs/styling/symcheck.swift`.
Two things this measured, beyond spelling: the old spellings (`doc.on.doc`,
`doc.on.clipboard`) are still live on the *newest* OS, so shipping the old name
is safe forward as well as backward; and an unknown name yields nil rather than
a crash, so kaya's Swift side can detect a bad name at the callsite.

**3. Web corroboration** for the release numbering and the deprecation trap,
cited inline.

The version gate itself was canaried before the table was trusted: a known-new
symbol (`arrow.trianglehead.clockwise`) must report NEEDS, and does — "macOS 15.0
/ iOS 18.0 (year 2024)".

**[VERIFIED]** means the exact string was found in Apple's shipped catalog with
its introduction year AND resolved live on this machine, and the concept mapping
is backed by Apple's own semantic map or keyword index. Where the string is
verified but the *concept* fit is a judgement call, the row says so in words.

## Apple's own semantic map (all 15 entries, verbatim)

From `semantic_to_descriptive_name.strings`. Worth citing in DESIGN.md: Apple
maintains exactly the kind of small closed concept set D6 proposes, and it is
deliberately tiny. These are the `UIBarButtonItem.SystemItem` concepts resolved
to glyphs.

    action       -> square.and.arrow.up
    add          -> plus
    bookmarks    -> book
    camera       -> camera
    compose      -> square.and.pencil
    fastForward  -> forward.fill
    organize     -> folder
    pause        -> pause.fill
    play         -> play.fill
    refresh      -> arrow.clockwise
    reply        -> arrowshape.turn.up.left
    rewind       -> backward.fill
    search       -> magnifyingglass
    stop         -> xmark
    trash        -> trash

All 15 targets exist at macOS 10.15, i.e. every one clears kaya's floor by three
major versions. Seven of kaya's 24 candidates get an Apple-blessed answer here
(add, delete, search, share, refresh, open-as-organize, close-as-stop).

## The table

"10.15" in the availability column means introduced macOS 10.15 / iOS 13.0 — far
below kaya's floor. Anything above the floor is called out in words, not buried.

| kaya concept | SF Symbols name | Avail (macOS/iOS) | Status | Basis |
|---|---|---|---|---|
| add | `plus` | 10.15 / 13.0 | [VERIFIED] | semantic map `add -> plus`; keywords add, create, new |
| remove | `minus` | 10.15 / 13.0 | [VERIFIED] | keywords include remove AND delete |
| delete (trash) | `trash` | 10.15 / 13.0 | [VERIFIED] | semantic map `trash -> trash` |
| edit (pencil) | `pencil` | 10.15 / 13.0 | [VERIFIED] | keywords edit, rename, write |
| done (checkmark) | `checkmark` | 10.15 / 13.0 | [VERIFIED] string; concept untagged | catalog + live resolve; see note 5 |
| close (x) | `xmark` | 10.15 / 13.0 | [VERIFIED] | semantic map `stop -> xmark`; keywords clear, close |
| search (magnifier) | `magnifyingglass` | 10.15 / 13.0 | [VERIFIED] | semantic map `search -> magnifyingglass` |
| share | `square.and.arrow.up` | 10.15 / 13.0 | [VERIFIED] | semantic map `action -> ...`; keywords share, export |
| settings (gear) | `gearshape` | 11.0 / 14.0 | [VERIFIED] | keywords settings, general (same for `gear`) |
| save | `square.and.arrow.down` | 10.15 / 13.0 | [VERIFIED] | Apple tags it `save` — but also download/import; note 1 |
| open (folder) | `folder` | 10.15 / 13.0 | [VERIFIED] string; **Apple has no "open"** | semantic map `organize -> folder`; note 2 |
| refresh | `arrow.clockwise` | 10.15 / 13.0 | [VERIFIED] | semantic map `refresh -> arrow.clockwise`; **rename trap** |
| info | `info.circle` | 10.15 / 13.0 | [VERIFIED] | keyword info |
| warning | `exclamationmark.triangle` | 10.15 / 13.0 | [VERIFIED] | keyword warning (exactly this one word) |
| error | `exclamationmark.octagon` | 10.15 / 13.0 | [VERIFIED] string; **no canonical error glyph** | keywords stop, warning; note 3 |
| back (chevron) | `chevron.backward` | 11.0 / 14.0 | [VERIFIED] | direction-relative pair; note 4 |
| forward (chevron) | `chevron.forward` | 11.0 / 14.0 | [VERIFIED] | direction-relative pair; note 4 |
| menu (hamburger) | `line.3.horizontal` | 12.0 / 15.0 | [VERIFIED] string; **not an Apple concept** | catalog + live resolve; note 6 |
| more (ellipsis) | `ellipsis.circle` | 10.15 / 13.0 | [VERIFIED] | keywords more, overflow, action, extra |
| copy | `doc.on.doc` | 10.15 / 13.0 | [VERIFIED] | **rename trap — do NOT ship `document.on.document`** |
| paste | `doc.on.clipboard` | 10.15 / 13.0 | [VERIFIED] | **same rename trap** |
| star (favorite) | `star` | 10.15 / 13.0 | [VERIFIED] | keywords favorite, vip |
| lock | `lock` | 10.15 / 13.0 | [VERIFIED] | keywords lock, padlock, password, security |
| person | `person` | 10.15 / 13.0 | [VERIFIED] | keywords people, user; account variant in note 7 |
| home | `house` | 10.15 / 13.0 | [VERIFIED] | keywords home, house — **the name is `house`, not `home`** |

## THE TRAP: the names you would copy out of the SF Symbols app today are macOS 15+

This is the one finding that will bite kaya if it is not written down, because it
fails in the direction nobody checks: the *modern, correct-looking* name is the
broken one, and it looks right in every current tool.

Apple renamed families in SF Symbols 6 (2024) and 7 (2025). The old names still
work — they are entries in `name_aliases.strings` and they resolved live on
macOS 26.5.2 in the check above — but **the new names do not exist below macOS
15**, and Xcode's deprecation warnings push you toward exactly the name that
breaks the floor:

| What SF Symbols 7 / Xcode calls it | Needs | The name to ship | Works from |
|---|---|---|---|
| `document.on.document` | macOS 15.0 / iOS 18.0 | `doc.on.doc` | macOS 10.15 |
| `document.on.clipboard` | macOS 15.0 / iOS 18.0 | `doc.on.clipboard` | macOS 10.15 |
| `arrow.trianglehead.2.clockwise.rotate.90` | macOS 15.0 / iOS 18.0 | `arrow.triangle.2.circlepath` | macOS 11.0 |
| `arrow.trianglehead.clockwise` | macOS 15.0 / iOS 18.0 | `arrow.clockwise` | macOS 10.15 |
| `document` | macOS 15.0 / iOS 18.0 | `doc` | macOS 10.15 |

Corroborated independently: Xcode 16 deprecates `doc.on.doc` in favour of
`document.on.document`, and developers report that with an older deployment
target `document.on.document` "isn't available and produces a missing image" —
i.e. it fails as a blank, not as a build error. Nothing tells you at compile
time. See the Apple Developer Forums SF Symbols tag and the SFSafeSymbols
project, cited at the bottom.

Second-order effect worth knowing: Apple's **search index has already moved to
the new names**. Inverting `symbol_search.plist`, the keyword `copy` returns only
`document.on.document` (macOS 15+) and `paste` returns only
`document.on.clipboard` (macOS 15+) — the old spellings carry no keywords at all
any more. So anyone who researches "the copy symbol" by searching the catalog,
in the app or in the plist, is handed a macOS 15 name with nothing to warn them.
The availability plist is the only source that tells the truth here, which is why
this column was built from it rather than from search.

**Recommendation for kaya:** the mapping table should hold the *old* spellings,
with a comment saying why, and the SF Symbols column should be regenerated
against `name_availability.plist` rather than hand-edited from the SF Symbols
app. If D6 grows a gate, the mechanical form is: every name in the Apple column
exists in `name_availability.plist` with a year whose `year_to_release` macOS
value is <= the declared floor. That gate reads Apple's own data and cannot be
satisfied by a name that merely looks modern.

## Notes on the judgement calls

**1. save — a real glyph, but an overloaded one.** Apple's keyword index attaches
`save` to exactly one family: `square.and.arrow.down`. So this is not a
compromise I invented; it is Apple's own answer. What it is *not* is a
save-specific glyph — the same symbol carries the keywords `download` and
`import`, and it is the mirror of the share/export symbol. There is no
floppy-disk or save-only symbol in the catalog; Apple's platforms save with Cmd-S
or automatically and never needed one. If kaya's `save` concept is used next to a
`share` concept in the same toolbar, the two will read as an up/down pair rather
than as save/share. That is a design consequence to accept knowingly, not a
lookup error. Alternatives, all real and all below the floor: `arrow.down.doc`
(10.15), `tray.and.arrow.down` (10.15), `internaldrive` (11.0).

**2. open — Apple has no "open" symbol at all.** The keyword `open` returns zero
symbols. `folder` is the pragmatic answer and it is what the semantic map uses,
but Apple's meaning for it is `organize` (semantic map) and `move` (its only
keyword) — never the verb "open". Ship `folder`, but do not describe it in
DESIGN.md as Apple's open symbol, because it is not one.

**3. error — no canonical glyph, and the obvious guess is wrong.** The keyword
`error` returns four symbols, none of them a general-purpose error mark
(`exclamationmark.warninglight` is a car dashboard light and is macOS 14+; the
other two are account-specific). Apple's own error UI uses an alert with the app
icon, not a symbol. `exclamationmark.octagon` (10.15, keywords `stop`, `warning`)
is the closest honest choice — octagon reads as error/stop, and it is
distinguishable from the triangle used for warning, which matters if kaya exposes
both concepts. **Do not use `xmark.octagon`**: despite looking like an error mark
it is tagged `*`, `multiply`, `times` — it is a multiplication symbol.
Alternative: `xmark.circle` (10.15), tagged clear/close/stop.

**4. back / forward — use the direction-relative pair, but the usual reason given
for it is imprecise.** `chevron.backward` and `chevron.forward` (both macOS 11 /
iOS 14, comfortably below the floor) are the direction-relative names introduced
in SF Symbols 2; Apple's index files them under the keywords `left` and `right`
respectively, which is what makes them the semantic spelling. The common advice
is that `chevron.left`/`chevron.right` "do not mirror in right-to-left" — that
is **not what Apple's shipped data says**. `legacy_flippable.plist` lists 75
symbols the system mirrors in RTL, and `chevron.left`, `chevron.right`,
`sidebar.left` and `arrowshape.turn.up.left` are all in it, while the
`.backward`/`.forward`/`.leading` names are not (they need no flip entry because
they resolve by layout direction). So both spellings end up mirrored; the
difference is that the semantic pair states the intent at the callsite and is the
documented modern vocabulary. Recommend `chevron.backward`/`chevron.forward` on
that ground, and do not repeat the "left doesn't mirror" claim in kaya's docs —
it is contradicted by Apple's own flip list on disk.

**5. done — the glyph is obvious, the concept is untagged.** `checkmark` (10.15)
carries no search keywords at all, and the keywords `done`, `ok`, `confirm`,
`accept` return zero symbols catalog-wide. So the string is verified but no Apple
source states "done means checkmark"; it rests on universal Apple UI practice.
Flagging it because it is the one row where the concept mapping has no citation
behind it. `checkmark.circle` / `checkmark.circle.fill` (both 10.15) are the
bordered forms.

**6. menu (hamburger) — not a concept in Apple's vocabulary.** The keywords
`menu`, `hamburger`, `sidebar` and `list` all return **zero** symbols.
`line.3.horizontal` exists (macOS 12) and resolves, but it carries no keywords —
Apple ships the glyph without claiming it means "menu". The platform-correct
spelling of that affordance on mac/iOS is a sidebar toggle, `sidebar.leading`
(macOS 11), which is what Apple's own apps use. Two honest options for D6: map
kaya's `menu` to `line.3.horizontal` and accept a glyph that is un-Apple in
context, or let the Apple column render `menu` as `sidebar.leading` and diverge
from the literal hamburger the other platforms will draw. This is a design call
for the maintainer, not a lookup — flagging it rather than picking silently.
Note `line.horizontal.3` (10.15) is the pre-SF-Symbols-3 spelling and is now an
alias of `line.3.horizontal`; it still resolves, and it is the one to use if the
floor ever drops below macOS 12.

**7. person — pick by role.** `person` (10.15) is the generic figure;
`person.crop.circle` (10.15) is the one Apple tags `account`, `profile`,
`contact`, and is the account-button idiom. If kaya's `person` concept is
intended as "the account button", `person.crop.circle` is the better target.

## Fill variants, for selected/on states

From `nofill_to_fill.strings`. Useful if kaya's icon concept ever grows an
on/off state (tab bars, favourite toggles). All below are macOS 10.15 except
`gearshape.fill` (11.0):

    trash -> trash.fill                     star -> star.fill
    folder -> folder.fill                   lock -> lock.fill
    gearshape -> gearshape.fill (11.0)      person -> person.fill
    info.circle -> info.circle.fill         house -> house.fill
    exclamationmark.triangle -> .fill       ellipsis.circle -> .fill
    exclamationmark.octagon -> .fill        square.and.arrow.up -> .fill
    square.and.arrow.down -> .fill

No filled variant exists for: `plus`, `minus`, `checkmark`, `xmark`,
`magnifyingglass`, `pencil`, `arrow.clockwise`, `chevron.backward`,
`chevron.forward`, `line.3.horizontal`. (`doc.on.doc.fill` and
`doc.on.clipboard.fill` do exist at 10.15, but the pairing table now records them
under the `document.*` names, so derive them by hand rather than from that file.)

## Release numbering, for the flagging rule the charge asked for

Confirmed against the shipped `year_to_release` table and corroborated on the
web. The rule "flag anything later than SF Symbols 4" is equivalent to "flag
anything whose year is 2023 or later":

| SF Symbols | Catalog year | macOS | iOS |
|---|---|---|---|
| 2 | 2020 | 11.0 | 14.0 |
| 3 | 2021 | 12.0 | 15.0 |
| **4 (kaya's floor)** | **2022** | **13.0** | **16.0** |
| 4.2 | 2022.2 | 13.3 | 16.4 |
| 5 | 2023 | 14.0 | 17.0 |
| 6 | 2024 | 15.0 | 18.0 |
| 7 | 2025 | 26.0 | 26.0 |

Nothing recommended in this column is at or above SF Symbols 5. The three names
that touch the floor at all are `gearshape` (SF Symbols 2), `chevron.backward` /
`chevron.forward` (SF Symbols 2) and `line.3.horizontal` (SF Symbols 3) — all
below it.

## Restrictions

All 25 recommended names were checked against `symbol_restrictions.strings` (605
entries, e.g. "This symbol may not be modified and may only be used to refer to
Apple's iCloud service"). **None of the recommended names is restricted.** Worth
keeping the check in any future generator, because the restricted set includes
ordinary-looking names like `icloud` and would otherwise be easy to wander into
if the concept set ever grows toward cloud/device/service ideas.

## Sources

Primary (Apple, read locally on macOS 26.5.2 build 25F84):
`/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/{name_availability.plist,
semantic_to_descriptive_name.strings, symbol_search.plist, name_aliases.strings,
symbol_restrictions.strings, nofill_to_fill.strings, legacy_flippable.plist}`
plus a live `NSImage(systemSymbolName:)` resolution run with failing canaries.

Web:
- [SF Symbols — Apple Developer](https://developer.apple.com/sf-symbols/)
- [Right to left — Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/right-to-left) (HIG pages render client-side; recorded as the guidance source for the direction-relative chevrons, with the flip behaviour itself measured from `legacy_flippable.plist` above)
- [SF Symbols tag — Apple Developer Forums](https://developer.apple.com/forums/tags/sf-symbols?page=2) (Xcode 16 `doc.on.doc` deprecation vs older deployment targets producing a missing image)
- [SFSafeSymbols](https://github.com/SFSafeSymbols/SFSafeSymbols) (per-symbol availability by OS version)
- [What's new in SF Symbols 7](https://wwdcnotes.com/documentation/wwdcnotes/wwdc25-337-whats-new-in-sf-symbols-7/)
- [Apple Launches SF Symbols 5 — MacRumors](https://www.macrumors.com/2023/10/05/sf-symbols-5/)
- [SF Symbol Changes in iOS 16.0 — Geoff Hackworth](https://hacknicity.medium.com/sf-symbol-changes-in-ios-16-0-70a80660ba79) (SF Symbols 4.0 = iOS 16.0 / macOS 13.0)
- [The Complete Guide to SF Symbols — Hacking with Swift](https://www.hackingwithswift.com/articles/237/complete-guide-to-sf-symbols)
