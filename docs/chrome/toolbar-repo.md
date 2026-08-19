# C2 toolbar — the REPO side

Scope: what machinery C2 would ride inside kaya. No web research; every
claim below is a repo read or a repo-run command. Evidence tiers:
**[REPO]** = read in this tree at the cited path/line, **[MEASURED]** =
I ran a command in this tree and quote its output, **[INFER]** = my
inference, flagged.

## HEADLINE (read this first)

**kaya already has a promotion list. It is `primary` (MENU_PROPS id 6),
and DESIGN.md forbids exactly what C2 proposes, in one sentence.**

> `primary` is inert in a regular window. It does not create a desktop
> toolbar, and no toolbar materialization is planned. This one bit is an
> adaptive menu hint, not the seed of a toolbar grammar.
> — **[REPO]** DESIGN.md:1878-1880

So C2 is not adding a promotion concept to a tree that has none. It is
either (a) DELETING that sentence and letting `primary` grow a desktop
lowering, or (b) adding a SECOND promotion concept beside a bit that
already means "promote me". The maintainer's "is there another toolbar
styling construct we can sneak it into?" has a repo answer, and it is
the bit that is already there.

Everything below is the evidence.

---

## 1. The menu/command catalog, end to end

### 1.1 The records (crates/kaya/src/spec.rs)

Five tx records make the catalog. Kinds are wire facts, append-only.
**[REPO]** spec.rs:796-874

| kind | record | fields | note |
|---|---|---|---|
| 28 | `menu_item_create` | `item:U64, kind:U32, reserved:U32` | own id space (`c_menu_item` allocator), distinct from widgets/nodes/surfaces |
| 29 | `menu_item_append` | `parent:U64, child:U64` | single-parent, ids never reused, closed kind grammar, depth cap at the root |
| 30 | `menubar_append` | `window:U64, item:U64` | **the window anchor**: "Append a top-level grouping node to `window`'s command catalog — the window anchor, riding the window construct under the window-attribute unification rule (0 = the primary surface)" |
| 31/32 | `context_attach` / `context_attach_node` | `widget\|node:U64, item:U64` | the same vocabulary scoped to a noun |
| 33 | `set_menu_prop` | `item:U64, prop:U32, source:U32` + SET_PROPERTY tail | SOURCE_ELEMENT rejected; icon/primary/shortcut reject SOURCE_SIGNAL (const-only) |

`menubar_append` is the shape C2's `toolbar(...)` would be modeled on:
a per-window, append-only, id-carrying RECORD (not a prop). It is
already "the window anchor riding the window construct".

### 1.2 The item's fields — MENU_PROPS **[REPO]** spec.rs:342-356

| name | id | PropKind | signal-bindable? |
|---|---|---|---|
| `label` | 1 | Str | yes |
| `enabled` | 2 | Bool | yes |
| `checked` | 3 | Bool | yes (toggle only) |
| `value` | 4 | F64 | yes (radio_group only) |
| `icon` | 5 | Blob | **const-only** |
| `primary` | 6 | Bool | **const-only**, action-only |
| `shortcut` | 7 | Str | **const-only**, window-anchored leaves |
| `role` | 8 | Str | action-only, closed vocabulary |
| `symbol` | 9 | Enum("symbol") | **const-only** (D6; "NOT id 6: these ids are wire facts and are append-only") |

C2's claim "items already carry label, symbol name, enabled signal, and
handler" is **true and complete** — all four exist today. The toolbar
button needs nothing new on the item.

The one wrinkle: **`primary` and `symbol` are const-only** (spec.rs:339-341,
"the signal-bindable slots are `label`, `enabled`, `checked`, and
`value`; `icon`, `primary`, and `shortcut` are const-only (enforced at
the root)"). So if C2 rides `primary`, the promotion set is STATIC per
item — which is fine (promotion is structure, not state), and it also
means an app cannot animate the toolbar's contents through a signal.
`enabled` IS signal-bindable, which is what makes C2's enablement
round-trip assertion work for free.

### 1.3 The symbol vocabulary (MPROP_SYMBOL / D6) **[REPO]** spec.rs:2286-2324

20 entries, ids 1..20, append-only forever ("wire values in eight
generated bindings and four backends' lowering tables; a renumber would
silently redraw every shipped app's menus. A new concept takes 21"):
add, remove, delete, edit, done, close, search, settings, refresh,
info, warning, back, forward, more, copy, paste, star, lock, person,
home.

`symbol` sits on BOTH SECTION_PROPS (id 3) and MENU_PROPS (id 9), same
Enum("symbol") kind — so the same vocabulary already serves the two
surfaces a toolbar would draw from. **[REPO]** spec.rs:328, 355.

There is a second spelling of the vocabulary in `wire::SYMBOLS`, pinned
against the spec enum by `symbol_names_match_the_spec_enum` **[REPO]**
spec.rs:2894-2918.


---

## 2. `primary`: the promotion list kaya already shipped

### 2.1 What it means today **[REPO]** DESIGN.md:1856-1880

> With no hint, regular windows render the full catalog and compact
> windows place the entire catalog in overflow. `primary: true` asks a
> compact host to promote an action into its top bar as a real native
> action. The host promotes the first *k* primary actions in catalog
> preorder: top-level grouping nodes in menubar-append order, then each
> node's children in append order, depth-first. Creation time is
> irrelevant. *k* is the platform's own idiomatic capacity, and the rest
> remain in overflow. The promoted set recomputes on every catalog
> mutation... This is advisory like initial window size.
>
> `primary` is inert in a regular window. It does not create a desktop
> toolbar, and no toolbar materialization is planned. This one bit is an
> adaptive menu hint, not the seed of a toolbar grammar.

Note what that machinery ALREADY IS, in C2's own words: an ORDER
(catalog preorder), a PROMOTION SET, a CAPACITY, an OVERFLOW remainder,
a recompute-on-mutation rule, and "advisory" status. C2's list differs
from it in exactly ONE respect: the order is app-declared rather than
derived from catalog preorder.

### 2.2 Where the bit is honored, backend by backend **[MEASURED]**

| backend | reads `primary`? | site |
|---|---|---|
| SwiftUI / **iOS** | YES | `kayaPromotedActions` → `KayaMenuToolbar`, `ToolbarItemGroup(placement: .primaryAction)`, swift/KayaSwiftUI.swift:9951, 11078-11124 |
| SwiftUI / **macOS** | **NO** | `kayaPromotedActions` (KayaSwiftUI.swift:9951) has exactly two callers: its own body and KayaMenuToolbar:11086, which is inside `#if !os(macOS)`. `KayaMenuChrome` on macOS is literally `content` (10844-10849) |
| Compose / Android | YES | `KayaMenuTopBar` actions slot, KayaCompose.kt:8766-8812 |
| GTK | **NO** | gtk.rs:2056-2059 — the field carries `#[allow(dead_code)]` and the comment *"The phone-promotion hint, mirrored for the record: INERT on desktop by design (DESIGN.md, Menus), so nothing here reads it."* |
| WinUI | **NO** | winui/mod.rs:711-713 — *"`primary` is stored but INERT on desktop (the phone-promotion hint; DESIGN.md, Menus)."* |

**So the repo already ships a promotion prop that is a no-op on 3 of 5
backends.** That is the maintainer's exact worry, in the tree, today.

### 2.3 How the no-op was STATED — the precedent the maintainer asked for

This is the repo's answer to "is there precedent for a prop honored on
one platform and ignored elsewhere, and how it was stated". There are
three distinct stances in the tree and they are NOT interchangeable:

1. **ADVISORY** (`width`/`height`/`sections_presentation`/`list_detail`):
   "honored where the platform has the idiom, resolved to the nearest
   thing otherwise, ignored where physics decides" — spec.rs:233-238.
   The prop is *asked for* everywhere; the platform answers as best it
   can. The harness verb reads the ARM THAT RENDERED
   (`expect_split` / `expect_sections_presentation` /
   `expect_menu_presentation` all take a BARE form asserting an
   INVARIANT rather than a literal, because "the exact literal differs
   per lane" — tools/scenes/menus.steps:88-96).
2. **INERT BY PHYSICS** (`veto_close` on mobile, `dirty` on the phones):
   "Inert on mobile by physics: no chrome close, and back is not close"
   — spec.rs:229-230; "the phones show nothing at all because they have
   no chrome to show it in (D4: the prop still applies and reads back
   there)" — spec.rs:257-261. The prop still *applies to the model* and
   still reads back; only the CHROME is absent.
3. **INERT BY POLICY** (`primary` on desktop): the two desktop backends
   store it and never read it, and DESIGN.md states the policy in one
   sentence. This is the weakest of the three, because nothing forces
   the sentence to stay true — it is not physics and not an idiom
   resolution, it is a decision.

Stance 3 is the one C2 would have to either honor or overturn.

### 2.4 The already-shipped no-op the harness cannot see **[MEASURED]**

Worse than a stated no-op: an UNstated one. I probed every read of
`.symbol` in the SwiftUI interpreter, tracking `#if` nesting the way
check-verbs.sh's stamped-observation rule does
(probe: `.../docs/chrome/symprobe.py`):

```
10318 cond=['#if os(macOS)']  kayaApplySymbol(holder, child.symbol)
10331 cond=['#if os(macOS)']  kayaApplySymbol(nsItem, option.symbol)
10350 cond=['#if os(macOS)']  kayaApplySymbol(nsItem, child.symbol)
10439 cond=['#if os(macOS)']  kayaApplySymbol(holder, top.symbol)
10471 cond=['#if os(macOS)']  kayaApplySymbol(nsItem, settings.symbol)
10132 cond=['#else of #if os(macOS)']  guard item.symbol != 0 else { ... }   <- the HARNESS read
```

Every RENDERING read of a menu item's `symbol` on the SwiftUI
interpreter is macOS-only. On iOS the item's semantic icon is drawn
NOWHERE: `KayaMenuToolbar` renders `item.icon` (the Blob) or falls back
to `Text(item.label)` (11091-11096), and `kayaCatalogElement` builds
`UIAction(title:)` with no image at all (11005). Compose, by contrast,
checks `item.symbol != 0` FIRST (KayaCompose.kt:8783-8790).

And `expect_menu_symbol "File>Save" "done"` (tools/scenes/menus.steps:14)
PASSES on iOS, because the iOS branch of `kayaMenuSymbolRead` reads the
MODEL — the value the apply arm stored — and merely checks the SF name
resolves on the OS (KayaSwiftUI.swift:10131-10143). Its own doc comment
says it reads *"the model the More menu and toolbar enumerate"*
(10149-10151); for `symbol` specifically, neither of them enumerates it.

**Bearing on C2:** a toolbar is icon buttons. The one platform where
kaya's promoted bar exists in shipped code is the one platform where
the semantic icon never reaches it, and the gate that should have caught
that is a model read. Any C2 arm must read the REAL button's
accessibility name (which is what macOS/GTK/WinUI already do for
`menu_symbol`), or it will repeat this exactly.

---

## 3. The iOS promoted-bar arm — what an app-declared list would replace

**[REPO]** swift/KayaSwiftUI.swift:11072-11124

```swift
struct KayaMenuToolbar: ViewModifier {          // inside #if !os(macOS)
    func body(content: Content) -> some View {
        if let window = scene.windows[windowId], !window.menubar.isEmpty {
            content.toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    let promoted = kayaPromotedActions(window)
                    ForEach(promoted) { item in
                        Button { kayaMenuUserActivate(item) } label: { ... }
                            .disabled(!kayaMenuEffectiveEnabled(item))
                    }
                    Menu { ...the whole catalog minus promoted... }
                        label: { Label("More", systemImage: "ellipsis.circle") }
                }
            }
        } else { content }
    }
}
```

What C2 changes here is ONE LINE: `kayaPromotedActions(window)` becomes
`window.toolbar.compactMap { scene.menuItems[$0] }`. Everything else —
the button, the dispatch through the one `kayaMenuUserActivate` path,
the `.disabled` off the inherited AND, the More menu's exclusion set —
is already written and already runs on every iOS leg.

Three structural facts about that arm that C2 inherits:

- **It is a ViewModifier attached per-surface, not per-window-object.**
  `KayaMenuChrome` is applied at exactly two sites: `KayaRoot`
  (12687, window 0's stack root) and `KayaSectionPane` (12590, one per
  section pane, keyed by `scene.sectionWindow[sectionId]`). It is NOT
  applied on `KayaAuxRoot` or `KayaSplitRoot` **[MEASURED: three
  occurrences of `KayaMenuChrome` in the file, one definition + those
  two]**. An aux window has no promoted bar today, and would have no
  toolbar under C2 without a third attachment site.
- **`kayaMenuEffectiveEnabled` is the inherited AND** (8575), and it is
  what every arm on every platform calls (16 call sites). C2's
  "disabling the menu item disables its toolbar button — for free" is
  literally true here: the same function, already called at 11097.
- **Capacity is a Swift constant**: `let kayaPromotionCapacity = 2`
  (8570). Compose has its own (KayaCompose.kt:1019, "How many promoted
  primary actions the top bar carries: k is this..."). An app-declared
  list either overrides *k* or is truncated by it — a decision C2 must
  make explicitly, because today *k* is the platform's answer and C2's
  list is the app's.

---

## 4. Who owns the header region, per backend

The question matters because C2's promoted buttons have to be packed
into something, and in three of five backends kaya already owns that
something.

| backend | the header region | who owns it today |
|---|---|---|
| **GTK** | one `gtk4::HeaderBar` per window, installed by `install_nav_chrome` with `window.set_titlebar(Some(&header))` — gtk.rs:1471-1512 | **kaya**. It already carries `pack_start(&back)` (the nav back button) and a `CenterBox` title widget holding the dirty marker + a bound title label. `pack_end` is free. In the split arm the `adw::NavigationPage`s *"carry the raw scene root"* and no AdwHeaderBar (gtk.rs:1717-1728), so there is exactly ONE header region per window on GTK |
| **Compose** | `TopAppBar` inside the scaffold — `KayaMenuTopBar` (KayaCompose.kt:8766-8812) | **kaya**, and its `actions = { ... }` slot already holds the promoted set + the `⋮` overflow |
| **SwiftUI / iOS** | SwiftUI's own `.toolbar` on the NavigationStack — `KayaMenuToolbar` (11084) | **kaya**, via the modifier; SwiftUI owns the geometry |
| **SwiftUI / macOS** | the real `NSWindow` title bar; `KayaMenuChrome` is a no-op and `NSApp.mainMenu`'s kaya-owned segment carries the catalog | **nobody, on the window**. This is the one backend with NO kaya-owned per-window header region today |
| **WinUI** | a `MenuBar` in a wrapper `Grid` (`WindowChrome { wrapper: Option<Grid>, back_button: Option<Button> }`, winui/mod.rs:698-702) | **kaya** |

So: 4 of 5 backends already have a kaya-owned band a promoted button
could be packed into with no new container. macOS is the odd one, and
macOS is also the platform whose "tall bar" the whole pass is about.

### 4.1 Sections and the sidebar, per backend **[REPO]**

- **SwiftUI**: `KayaSectionsView` (12476-12568) — `sidebar` resolves to
  `NavigationSplitView` with `.listStyle(.sidebar)` (macOS only,
  explicitly pinned at 12521-12528: *"a default that changed under an
  SDK bump would silently de-modernize every sectioned window"*);
  everything else is `TabView`. Section rows already draw the semantic
  icon via `Label(section.title, systemImage: sf)`.
- **GTK**: `adw::NavigationSplitView` inside an `adw::BreakpointBin`,
  collapse condition `max-width: 400sp` from libadwaita's own example
  (gtk.rs:1590-1643). The pages hold the raw root; kaya's own HeaderBar
  stays the window's titlebar above the whole thing.
- **Compose**: `KayaSectionsScaffold` → M3 bottom `NavigationBar`
  (KayaCompose.kt:9182-9210); list-detail is `ListDetailPaneScaffold`
  (8658).
- **WinUI**: `KAYA_WINUI_NAV_PROBE` mentions NavigationView (2481) —
  needs the WinUI agent's read, not mine.


---

## 5. How window PROPS travel vs per-window CONSTRUCTS

This is the wire-shape question the grammar sketch
`tx.window(0).toolbar(&[ids])` runs into.

### 5.1 A prop cannot carry a list **[REPO]** spec.rs:88-102

```rust
pub enum PropKind { Str, Bool, F64, Blob, Enum(&'static str) }
```

That is the whole vocabulary. `set_window_prop` is
`{window:U64, prop:U32, source:U32}` + the SET_PROPERTY tail, and the
tail is *"a value for SOURCE_CONST, a u64 signal id for SOURCE_SIGNAL,
or u32 level + u32 reserved for SOURCE_ELEMENT"* (spec.rs:363-366) —
one value, never a sequence. **A window prop carrying an id list is
not expressible without adding a sixth PropKind**, which would ripple
through every generated typed setter in 8 bindings plus the C floor.

### 5.2 The per-window CONSTRUCT shape is the one that exists

Every per-window collection in the wire today is a REPEATED RECORD, not
a list-valued prop:

| record | shape | destruction? |
|---|---|---|
| `menubar_append {window, item}` | one record per catalog root | none in v1 |
| `add_section {window, section}` | one record per section | none — *"the set is APPEND-ONLY — this grammar has no destruction verbs by design"* (spec.rs:768-770) |
| `push_entry {window, entry}` | one record per push | `pop_entry` (the exception, and stacks need it) |

`FieldTy::Values` (a counted list of typed values) exists and is used
for key paths, record fields, `show_file_dialog`'s `filters`, and
`copy`'s `reps` — but never for a list of ids. **[MEASURED]**: 10
`FieldTy::Values` fields in spec.rs, none of them an id list.

So the two candidate shapes, honestly stated:

- **(A) `toolbar_append {window: U64, item: U64}`** — kind 43 or
  whatever is next. Mirrors `menubar_append` and `add_section` exactly:
  ordered by arrival, append-only, no destruction grammar, one
  `UndoVerdict::Refused` line, and the sugar spelled as a repeated call.
  The sections precedent is unambiguous that this is the house shape.
- **(B) `window_toolbar {window: U64, items: Values}`** — one atomic
  list, replaceable wholesale. NO precedent in the tree. It would be
  the first record whose semantics is "replace this set", which is a
  new lifecycle question (what happens to a promoted item that leaves
  the list?) that append-only does not have to answer.

**[INFER]** (A) is right, and the reason is not aesthetics: the
"replace" semantics of (B) is exactly the destruction grammar the
sections design refused, arriving through a side door.

### 5.3 The window-attribute unification rule already covers it

**[REPO]** DESIGN.md:1640-1642 — the window anchor *"rides the window
construct under the window-attribute unification rule; it is not a
widget in the scene root."* And check-sugar-surface.sh:908-921 enforces
the pair: *"NO WINDOW ATTRIBUTE LIVES AS A LOOSE FUNCTION OUTSIDE THE
CONSTRUCT"* — swept in both directions since three bindings shipped a
loose `OnUndone(window, fn)` by transcribing Rust's shape.

So `tx.window(0).toolbar(...)` is the right RECEIVER by an existing
ratified rule. Good news for the grammar sketch.

### 5.4 What the 8-way sweep costs, and where it is automatic

This asymmetry matters for choosing prop-vs-record:

- **A new WINDOW_PROPS entry is swept AUTOMATICALLY.** The window-prop
  loop reads `WPROP_*` out of the GENERATED `bindings/python/kaya/wire.py`
  and demands a sugar spelling in 7 languages (C exempt)
  — check-sugar-surface.sh:706-759. *"Props come from the GENERATED wire
  file, so this tracks the spec by construction."*
- **A new RECORD is NOT.** It needs a hand-written `check_styling_point`
  clause, exactly like the one `add_section` eventually got
  (check-sugar-surface.sh:866-889) — and that clause exists BECAUSE the
  sweep was missing: *"add_section grew up primary-only, and six
  bindings gained a window target while two kept the hardcoded 0 — which
  no gate swept, so the divergence surfaced only when the
  sidebar-coverage scene put sections in an aux window and Python and
  Haskell could not say so (2026-08-15, both proven through the apply
  stream: the records went silently to window 0)."*

**[MEASURED]** the blast radius of the `add_section` record, as a proxy
for a new per-window construct: 38 tracked files mention it
(`git ls-files -z | xargs -0 grep -l`). Roughly 11 are generated
(`bindings/*/…Wire.*`, `bindings/c/kaya_wire.h`,
`crates/kaya/include/kaya.h`, `crates/kaya/src/wire.rs`), 8 are the
per-language guests, and the rest are hand-written: spec.rs, protocol.rs,
scene.rs, app.rs, capi.rs, the 4 backends, the 8 binding surfaces, and
one gate clause.

---

## 6. The minimal spec surface C2 needs

Stated as the smallest diff that reaches the ratified bar. **[INFER]**
throughout — this is a design proposal, not a repo read.

### Option 1 — ZERO new spec surface: overturn DESIGN.md:1878-1880

Nothing in spec.rs moves. The spec hash does not move. No generator
runs. No binding gains a spelling. `primary` stops meaning "phone
promotion hint" and starts meaning "promote this action into whatever
chrome this window has", and the three desktop backends grow a lowering
for the bit they already store.

What is lost against the C2 draft: app-declared ORDER (promotion is
catalog preorder), and *k* stays the platform's number.
What is gained: **the maintainer's "sneak it into another construct"
lands exactly, and there is no new no-op knob because there is no new
knob.** The bit becomes LESS of a no-op than it is today.

### Option 2 — one record, the `add_section` shape

```
kind 43  toolbar_append { window: U64, item: U64 }
```

Plus, at the root (scene.rs), the `MenubarAppend` arm's shape:
window-exists assert, item-exists assert, kind assert (actions only),
and — the one divergence — **NOT `assert_menu_root_free`**, because a
promoted item by definition already has its bar anchor. See §7.

Plus one line in the undo verdict table
(`TxOp::ToolbarAppend { .. } => UndoVerdict::Refused("toolbar_append")`,
scene.rs:369-390).

No new prop, no new enum, no PropKind change. Spec hash moves (a new
record), so every binding regenerates in lockstep — which is the
regeneration workflow doing its job, not a cost.

### What is NOT needed either way

- No new MENU_PROPS entry. `label`/`enabled`/`symbol`/`icon`/handler
  are all there (§1.2).
- No new `symbol` entries. 20 exist; a toolbar draws from the same 20.
- No `chrome`/`extended` window prop. See §9.

---

## 7. The existing walls that apply

**"Promote what exists"** is the `menubar_append` wall, verbatim
**[REPO]** scene.rs:2017-2036:

```rust
assert!(window == DEFAULT_WINDOW || self.windows.contains(&window),
    "kaya: menubar_append onto unknown window {window:?} — create_window first (0 is the primary)");
let kind = self.menu_items.get(&item)
    .unwrap_or_else(|| panic!("kaya: menubar_append of unknown menu item {item:?}")).kind;
self.assert_menu_root_free(item);
assert!(is_menu_group(kind), "kaya: the menu bar accepts only grouping nodes ...");
```

Three of those four transfer directly. **The fourth is the trap.**

### 7.1 `assert_menu_root_free` must NOT be reused **[REPO]** scene.rs:3509-3516

```rust
assert!(it.parent.is_none() && it.anchor.is_none(),
    "kaya: menu item {item:?} already has a parent or anchor \
     (an item takes exactly one parent or anchor)");
```

DESIGN.md:1751 states it as an invariant: *"An item may acquire exactly
one parent or anchor and ids are never reused."* A toolbar promotion is
by construction a SECOND reference to an item that already has a parent
(it lives under `File`) and whose root has an anchor. So the promotion
list is **not an anchor** and must be stated as such, or the invariant
reads as violated. The clean statement: a toolbar entry is a REFERENCE,
not an anchor — it confers no ownership, changes no dispatch identity,
and the item stays exactly where it was declared (the same sentence
`role` already needed, DESIGN.md:1851-1854: *"macOS keeps the item
addressable where it was DECLARED"*).

`primary` needs no such sentence at all, because a Bool on the item
cannot be mistaken for an anchor. **[INFER]** this is a real, if small,
argument for Option 1.

### 7.2 Set-once vs mutable — the precedent is explicit

- **Set-once, pre-mount**: `brand_accent` / `brand_typeface`
  (scene.rs:1617-1640) — *"SET ONCE, BEFORE THE FIRST MOUNT. Brand is
  identity, not state: a second write is a program error, and a
  post-mount write would promise the runtime theme-switching surface the
  vocabulary deliberately does not have."*
- **Append-only, live**: menus and sections — *"Topology is append-only
  and live: items may be created and appended at any time, while all
  applicable props remain mutable"* (DESIGN.md:1749-1752).

The menus scene PROVES the live half and would prove it for a toolbar
too: `click button#2` appends a fourth bar root, renames `File` to
`Document`, appends `Publish` under the retained parent, **and moves the
primary hint from Share to Publish**, then asserts the promoted set
followed (tools/scenes/menus.steps:71-86). That step already exercises
promotion recomputation on every lane. C2 inherits a working test.

### 7.3 Undo refuses it, mechanically

Every catalog and section op is `UndoVerdict::Refused` (scene.rs:369-390).
A toolbar record joins that list with one line; `primary` needs nothing
(it goes through `SetMenuProp`, already refused).

---

## 8. What the harness reads would traverse, per platform

The existing `menu_symbol` / `menu_count` reads are the template, and
they are NOT uniform — deliberately:

| platform | `menu_count` reads | `menu_symbol` reads |
|---|---|---|
| macOS | the REAL `NSApp.mainMenu` kaya-owned segment | the real `NSMenuItem.image.accessibilityDescription` (KayaSwiftUI.swift:10111-10130) |
| iOS | the model | **the model** (10131-10143) — the hole in §2.4 |
| GTK | the REAL GMenu the PopoverMenuBar renders, `model.n_items()` (gtk.rs:7279-7290) | the GIcon off the realized row (gtk.rs:2062-2064) |
| WinUI | the REAL `MenuBar.Items().Size()` (winui/mod.rs:10163-10175), *"never the model map (the section_count precedent)"* | the materialized item's icon (winui/mod.rs:780) |
| Compose | — (KayaCompose's own arm) | the row's semantics/testTag |

A `toolbar_count` / `toolbar_item` read would traverse, respectively:
`NSWindow.toolbar?.items` (macOS), the SwiftUI toolbar's rendered
buttons (iOS — no registry, hence the model problem again), the
HeaderBar's packed children (GTK), the CommandBar's PrimaryCommands
(WinUI), and the TopAppBar's actions via testTag (Compose).

**The one assertion that carries the design** is C2's own: disable the
MENU item through its bound signal, observe the BUTTON disabled. Every
backend already computes `kayaMenuEffectiveEnabled` /
`kayaMenuEffectivelyEnabled` / `effective_enabled` at 16+ call sites,
so the lowering side is free; only the READ is new.

**[REPO]** the byte-compared-verdict rule bites here: shared scenes are
compared byte-for-byte across platforms (CLAUDE.md invariant 6), and
capacity *k* differs per platform (2 on SwiftUI, its own on Compose). So
`expect_toolbar N` cannot ride a shared scene with a literal N unless
C2 fixes the capacity question — the same problem
`expect_menu_presentation` solved by admitting a BARE form that asserts
an INVARIANT rather than a literal (tools/scenes/menus.steps:88-96,
harness.rs:1964-1974). **[INFER]** `expect_toolbar` wants that same bare
form: "the promoted set FITS this window's chrome", not a count.

---

## 9. The maintainer's four questions, repo-side

### Q1 — what the promotion list lowers to, and whether a tall variant exists

Repo-side answer: on 4 of 5 backends the target container ALREADY EXISTS
and is kaya-owned (§4). The tall/modern variant is **not a knob in this
repo and does not need to become one**, and the ledger already says so
in the maintainer's own words **[REPO]** docs/deferred.md:2457-2465:

> The safe cases ALREADY auto-extend: a sidebar window gets the
> full-height treatment from the platform today, and a toolbar-carrying
> window would get the tall unified bar with the toolbar itself. What the
> knob alone buys is extended-without-chrome (the Zed-shaped editor),
> which only the app can promise its top edge tolerates. REOPENS when an
> app actually wants that shape; the cleaner rule to consider then:
> **extended is DERIVED (toolbar or sidebar present)**, and the knob
> exists only for the chrome-less case.

That is C1 already deferred with the derivation rule written down. C2
does not need to re-open it.

### Q2 — what comes automatically, repo-side

**Free, no new code:**
- the item's label, enabled signal, symbol, icon, handler (§1.2);
- the inherited-AND enablement, at one function per backend already
  called everywhere (§3);
- recompute-on-mutation (the promoted set is derived from observable
  state in both interpreters; §2.1);
- the overflow remainder (both mobile arms already exclude the promoted
  set from the overflow menu — KayaSwiftUI.swift:11100,
  KayaCompose.kt:4448-4450, 8843);
- one dispatch path (`kayaMenuUserActivate` / `kayaActivateMenuItem`) —
  chrome emits, no second handler table;
- undo refusal (one table line);
- the 8-way sugar sweep IF it is a window prop; NOT if it is a record.

**Not free:**
- the desktop lowerings (3 backends × pack the button);
- the harness read on 5 backends + the two interpreters' four layers;
- the iOS symbol gap (§2.4) — a toolbar of blobs-or-text is not the
  platform's real thing, and that is Phase B's D6 work reaching a
  surface it never reached;
- an ORDER that differs from catalog preorder, if C2 wants one;
- capacity: today *k* is the platform's; an app-declared list asks for
  all of them.

### Q3 — is an 'extended' knob NEEDED

**[REPO]** the tree answers no twice: DESIGN.md:1938-1940 sets the bar
(*"A toolbar grammar is not on the roadmap. It is admitted only if an
artifact demands semantics that adaptive menu promotion cannot
express."*), and deferred.md:2464 gives the derivation rule
(*"extended is DERIVED (toolbar or sidebar present)"*).

### Q4 — riding what already exists, with ZERO new styling vocabulary

Yes, and the construct is `primary`. §2.1 shows the machinery is already
a promotion list with an order, a capacity, an overflow and a
recompute rule. What C2 adds over it is app-declared ORDER and desktop
MATERIALIZATION — and only the second one is what the maintainer is
after.

**Knobs that would be no-ops on other platforms, to eliminate:**

1. **`chrome: standard|extended`** — a no-op on iOS and Android *"by
   construction"* (the draft's own table, chrome-plan.md:48), and
   DERIVABLE on the three desktops from "does this window have a toolbar
   or a sidebar". Already deferred. Keep it deferred.
2. **`title_hidden` (C1b)** — no-op on both phones, and it contradicts
   the editor plan's own rule. The draft already marks it optional.
3. **Any per-item PLACEMENT knob** (leading/trailing/center) — mac and
   GTK have packing, iOS effectively does not, Compose's TopAppBar has
   `navigationIcon`/`actions` and nothing else. The draft already
   refuses it; keep the refusal.
4. **A toolbar-only `capacity` knob** — would be a no-op on the two
   desktops that show everything and meaningful only on the phones,
   i.e. the exact shape of `primary`'s current problem, inverted.
5. **A per-item `toolbar_style` / `icon_only|icon_and_label`** — not
   proposed, and worth refusing pre-emptively: it is 4/5 expressible and
   the one platform that cannot say it (iOS's `.primaryAction`) would
   silently ignore it.

**The one knob that is NOT a no-op anywhere**: the promotion list
itself. Every platform has a top chrome band, every one of them can hold
an ordered set of icon buttons, and kaya already owns the band on four
of the five.

---

## 10. The four-layer interpreter discipline — what C2 owes

**[REPO]** tools/check-verbs.sh, and it is mechanical:

| layer | what the gate demands | line |
|---|---|---|
| verbs | every `"verb" =>` arm in harness.rs's `parse()` must appear as a string in BOTH KayaSwiftUI.swift and KayaCompose.kt | 247-255 |
| constants | every `APPLY_/KIND_/PROP_/COMMAND_/MENU_KIND_/MPROP_` const **with its value**, spelled `applyToolbarAppend = 43` in Swift and `APPLY_TOOLBAR_APPEND = 43` in Kotlin | 315-337 |
| spec hash | `let kayaSpecHash: UInt64 = 0x…` / `SPEC_HASH: ULong = 0x…uL` must match `bindings/c/kaya_wire.h` | 339-351 |
| render/model + step-verb arm | every `expect_*` arm must append to `observed` — or call the depth stub, the ONE exemption — *"an expect that records nothing passes without verifying anything"* | 353-392 |

Plus the **stamped-observation rule** (406-442): a field the harness
reads must have at least one write OUTSIDE every platform conditional.
`STAMPED = ["formFactor", "splitPresentation"]` today. If C2 stamps a
`toolbarPresentation` the way `expect_split` and
`expect_menu_presentation` stamp theirs, it joins that list — and
**[INFER]** it should, since the whole point of the observation is "which
arm rendered".

Other gates C2 trips, all of them by design:

- `check-sugar-surface.sh` — automatic for a prop, a hand-written
  `check_styling_point` clause for a record (§5.4).
- `check-stubs.sh` — a backend without the feature must call
  `depth_stub("toolbar")` / `depthStub` / `kayaDepthStub(_:on:)` and
  check-steps stops demanding those legs. This is the mid-milestone
  hold-open mechanism; the Swift stub names its platform because one
  file serves mac AND iOS.
- `check-gates.sh` — no new gate needed if C2 is a record; a new gate
  script must be in gates.sh's sweep or in EXCLUDED with a reason.
- `check-roles.sh` is the closest ANALOGUE gate: written because
  `MENU_ROLES` *"is ONE LINE, it is not in the spec hash, and adding an
  entry to it regenerates nothing — so before this gate a role could ship
  with the root accepting it and all four backends ignoring it"*
  (check-roles.sh:18-32). **[INFER]** if C2 rides `primary` (Option 1),
  the same failure shape applies — the bit is already in the spec hash,
  but "which backends read it" is not checked by anything, and today the
  answer is 2 of 5. A `check-promotion.sh` in that mold (every backend
  that renders a top chrome band reads `primary`) is the guard that
  would make Option 1 hold.


---

## 11. The versions every answer above assumes **[MEASURED]**

Read out of this tree today, so the platform agents' claims can be
checked against the same pins:

| layer | pin | source |
|---|---|---|
| GTK | `gtk4 = "0.11.4"`, features `["v4_10"]` | crates/kaya/Cargo.toml:151 |
| libadwaita | `adw = { package = "libadwaita", version = "0.9.2", features = ["v1_4"] }` — the comment notes the validation image carries libadwaita **1.7.6**, so *"anything above 1.7 would compile here and fail"* | Cargo.toml:165-175 |
| linux image | `debian@sha256:fac46bff…` (trixie, pinned by digest), `libgtk-4-dev`, `libadwaita-1-dev`, `adwaita-icon-theme`, `librsvg2-common` | tools/linux/Dockerfile:23,27,34,121 |
| pango | `0.22.8`, features `["v1_56"]` | Cargo.toml:164 |
| WinUI / WASDK | Base 2.0.4, Foundation 2.1.0, InteractiveExperiences 2.0.15, **WinUI 2.2.1**, Runtime 2.2.0 | tools/fetch-winappsdk.sh:48-53 |
| windows-rs | `windows` / `windows-core` **0.62**; `windows-numerics`/`collections`/`future` 0.3 | Cargo.toml:34-124 |
| Compose | `compose-bom:2024.10.01`, `material3` from the BOM (**M3 1.7.5**, per the comment at :73), `material3.adaptive:1.0.0` + `adaptive-layout:1.0.0` | android/kaya/build.gradle.kts:53,54,65,66,73 |
| Android | `compileSdk = 35`, AGP 8.7.3, Kotlin 2.0.21 (+ compose plugin 2.0.21) | android/kaya/build.gradle.kts:9, android/build.gradle.kts:2-5 |
| Apple | host macOS **26.5.2** (build 25F84); the flake carries `aarch64-apple-ios` / `aarch64-apple-ios-sim` rust targets and no pinned Xcode — the SDK is the host's | `sw_vers`; flake.nix:52-53 |

Note the M3 caveat for whoever writes the Compose arm: the pinned BOM
is **2024.10.01 / material3 1.7.5**, not a 2025 BOM. Any TopAppBar API
newer than that (large/medium variants' newer overloads, the 2025
`TopAppBarDefaults` additions) is not available here without moving the
BOM, and moving it is a `check-pins.sh` matter.

---

## 12. Bottom line for the synthesis

1. **C2's premise is right and its novelty is smaller than the draft
   thinks.** The catalog carries everything a toolbar button needs, the
   promoted-bar machinery exists and runs on two backends, and 4 of 5
   backends already own a header band. What C2 actually adds is
   *desktop materialization* plus *app-declared order*.
2. **There is a written line to clear, not an absence to fill.**
   DESIGN.md:1878-1880 and 1938-1940 both refuse a toolbar grammar, the
   second one with an admission trigger: *"admitted only if an artifact
   demands semantics that adaptive menu promotion cannot express."*
   Ratifying C2 means answering that trigger in one sentence. The honest
   answer available today: **order and desktop presence**, nothing else.
3. **The cheapest correct shape is `primary` growing a desktop
   lowering** (§6 Option 1) — zero spec surface, zero new vocabulary,
   zero new no-op knob, and it turns an existing 3-of-5 no-op into a
   5-of-5 honored bit. If app-declared ORDER is genuinely wanted, add
   `toolbar_append {window, item}` on the `add_section` shape (Option 2)
   and state, once, that a toolbar entry is a REFERENCE and not an
   ANCHOR (§7.1).
4. **No `extended` knob.** The ledger already wrote the rule:
   *"extended is DERIVED (toolbar or sidebar present)"*
   (deferred.md:2464). Every knob in §9 Q4's list is a no-op somewhere;
   the promotion list is the only construct that is a no-op nowhere.
5. **Fix the iOS symbol gap before or with C2** (§2.4). It is the one
   repo-measured fact that makes the whole pass hollow if ignored: a
   toolbar is icon buttons, and on iOS the semantic icon reaches no
   chrome at all while `expect_menu_symbol` passes off the model. The
   chrome-plan's dependency #1 ("D6's icons come FIRST") is satisfied on
   mac, GTK, WinUI and Compose — and unsatisfied on precisely the
   platform whose promoted bar already ships.
6. **Whatever lands, the read must be the real tree.** macOS, GTK and
   WinUI already read real chrome for `menu_count` and `menu_symbol`;
   iOS reads the model, and that is where the gap hid. And
   `expect_toolbar` should take the BARE invariant form
   (`expect_menu_presentation`'s shape), because capacity *k* is the
   platform's number — 2 on both mobile arms today, "never computed by
   kaya" in both files' words — and a shared scene is compared
   byte-for-byte.

### Probe left behind
`/private/tmp/…/docs/chrome/symprobe.py` — reports every read and
write of `.symbol` in KayaSwiftUI.swift with its `#if` nesting, the
technique check-verbs.sh's stamped-observation rule uses. Re-run it after
any iOS symbol work to confirm a rendering read exists outside
`#if os(macOS)`.

### Cleanup — and one thing to look at

**Mine:** no repo edits, nothing built, nothing launched, no processes
started. My footprint in the shared scratch dir is two files —
`toolbar-repo.md` (39 KB) and `symprobe.py` (1 KB). Everything else in
`scratchpad/chrome/` belongs to the sibling platform agents (screenshots,
`m3aar/`, `probe-bindgen/`, `probe-out-*.rs`, `out/`, `probe-mac/`) and I
left it alone; the directory measures **226 MB** total, and the four
`probe-out-*.rs` files alone are ~1.5 MB. Whoever closes this sweep
should have those agents account for it.

**Not mine, but flagging it:** the session started with a clean tree
(`Status: (clean)` in the opening snapshot) and `git status` now shows
`M docs/deferred.md` — 6 insertions, 2 deletions, striking through the
`brand_typeface` bindings entry and the "no font FILE ships" entry as
landed in 31ace6b. That is a typeface-ledger update, unrelated to this
chrome research, and it appeared during the session. I did not make it
and did not touch it. Worth confirming who did before anything is
committed.
