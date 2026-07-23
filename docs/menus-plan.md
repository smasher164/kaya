# Menus and the command vocabulary — execution plan

Status: design settled in conversation with Akhil 2026-07-23 (the
carve, the item vocabulary, the two anchors, overflow/`primary`, the
defaults). This document is the plan of record for executing it. The
DESIGN.md section gets written as Phase 1 of this plan and Akhil
reviews its text; anything marked ESCALATE below is not the
implementer's call.

Read first, in this order: AGENTS.md (operating rules — nix develop,
python3-never-sed, spec-is-root, no hand-edited generated files,
commit approval is Akhil's, every commit message is his), DESIGN.md
"Presentation contexts" + "Sections (tabs)" (the ratification pattern
this follows), docs/traps.md entries named in Phase 4, and the
deferred.md packaging notes for adding a scene.

## 0. The design, normatively

### The carve

- Navigation answers *where am I* — serial stacks; chrome derived.
- Sections answer *which peer area* — selection; chrome derived.
- Menus answer *what can I do right now* — VERBS, never places. A
  menu item fires an occurrence and the menu closes. Menu items never
  host content, never hold a stack, never participate in layout.
  Submenus are grouping, not navigation.
- A context menu is the same verbs scoped to a NOUN — "what can I do
  to this thing." Same item vocabulary, different anchor.

One item vocabulary, two anchors:

- **Window anchor** (the menubar): the window's command catalog.
  Rides the window construct like every window attribute
  (the window-attribute unification rule). macOS materializes the
  focused kaya window's bar as the global bar; Windows/Linux put it
  in that window's chrome; phones fold it into the top bar's
  overflow. The mac application menu (About/Quit) and the standard
  Edit menu remain DRESS — backend-provided, zero API (this is also
  what keeps cmd+C alive in native text controls; the Electron trap).
- **Widget/node anchor** (the context menu): right-click on desktop,
  long-press on phones — each platform's own gesture. No shortcuts on
  context items (a shortcut needs a catalog home to exist in native
  dispatch). v1 rejects attachment to text-bearing controls (entry,
  textarea): their native context menus are dress.

### The item vocabulary

Kinds: `menu` (a submenu node; top-level menus are this kind appended
to the bar), `action`, `toggle`, `radio_group`, `radio_option`,
`separator`.

Props (MENU_PROPS table, the SECTION_PROPS/ENTRY_PROPS precedent):

| prop | type | notes |
|---|---|---|
| label | Str | required on all but separator; SIGNAL-BINDABLE (source tail) |
| enabled | Bool | default true; SIGNAL-BINDABLE |
| checked | Bool | toggle items only; signal-bound both ways (checkbox contract) |
| value | Value (F64 integral) | radio_group only: selected option index (choice contract) |
| icon | Blob | optional; used by phone promotion, ignored where the platform doesn't dress items with icons |
| primary | Bool | default false; action items only; the phone-bar promotion hint, INERT on desktop |
| shortcut | Str | normalized spelling (below); menubar-anchored action items only |

State model is pure reuse: toggle = the checkbox contract, radio
group = the choice contract (select/radio), enablement = a bound
Bool. Echo doctrine applies unchanged: user activation emits;
programmatic checked/value writes are QUIET; enabled writes never
emit anything.

Handlers scope to their creator: `on_activate` rides the item
declaration, `on_toggle` rides the toggle, `on_select` rides the
radio group. No app-global menu dispatcher exists in any language.

### Shortcuts and the policy rules

Spelling: `primary`, `shift`, `alt` modifiers plus a key — a
printable character or a named key (enter, escape, delete, f1..f12,
arrows). `primary` = cmd on Apple platforms, ctrl elsewhere (GTK's
`<Primary>` accelerator and Electron's CmdOrCtrl are the precedent;
we adopt GTK's name). Canonical wire form: lowercase,
`primary+shift+s` ordering (primary, shift, alt, key). The parser
lives in ONE place per binding (generated layer 1), not per call
site.

Policy validation at the root (scene.rs), all deterministic scene
errors with the domain-check spelling:

- duplicate shortcut within a window's catalog;
- reserved floor (the strict UNION across platforms, uniform
  everywhere): `primary+q`, `alt+f4`. ESCALATE before widening.
- `shortcut` on anything but a menubar-anchored action;
- `primary` on anything but an action;
- tree depth beyond bar > menu > submenu > leaf (context: root items
  + one submenu level);
- an item anchored or appended twice (items are single-parent; no
  shared nodes — every platform forbids them);
- `context_menu` on a text-bearing kind.

### Overflow and `primary`

Default (nothing specified): desktops show the full catalog in a real
bar; phones put the ENTIRE catalog in the top bar's overflow (⋮ /
More). Top-level menus become labeled groups in the overflow (inline
sections with headers on iOS, headers + dividers in the M3 dropdown);
one submenu level survives as a real cascade/drill-in.

`primary: true` promotes an action out of overflow into the top bar
as a real bar action (TopAppBar action / trailing UIBarButtonItem).
The platform promotes the first k primaries in declaration order — k
is the platform's own idiom, never computed by kaya — and the rest
fall back to overflow. Advisory, like initial window size. Inert on
desktop: no desktop toolbar materialization exists or is planned;
that is the line that keeps this one bit from becoming a toolbar
grammar.

### Ids and occurrences

Menu items get their OWN id space: one guest-side counter per app
(`c_menu_item`), a distinct handle type per binding (`MenuItem` /
`menu_item` / etc.) so cross-use with widgets/nodes is a compile
error where the language can express it. Dispatch tables keyed by
item id, separate from every other table ("two tables, always" —
now N tables, still always).

Occurrences (id-only or id+payload shapes; the DERIVED id-only
emitter branch from the nav slice should absorb what it can):

- `menu_activated(item)` — action fired (menu click OR its shortcut:
  ONE occurrence, one dispatch path; the shortcut is another
  affordance of the same item);
- `menu_toggled(item, bool)`;
- `menu_value_changed(group, index)`;
- context-menu items attached to a template node carry the stamped
  copy's key path, the on_click_node encoding — the keys ARE the
  noun.

v1 structural rule: items may be created and appended at any time
(append-only, the sections discipline); props mutate freely; nothing
is ever removed. Dynamic collections of items (recent files) are
recorded as the For-stamped-menu-items follow-on, not built now.

## 1. Phase 0 — archaeology reconcile (read-only)

Mine the prior sessions (Claude Code history, memory directory,
earlier Codex sessions) for menu/menubar/shortcut discussions.
Deliverable: a short list of (a) confirmations, (b) contradictions
with this plan. Contradictions go to Akhil BEFORE any spec edit.
Particular attention: the original "MenuBar carries the declarative
shortcut policy" framing, anything about mac focused-window menu
semantics, anything about roles (Preferences/About placement).

## 2. Phase 1 — DESIGN.md section + ledger

Write "Menus and the command vocabulary" into DESIGN.md beside the
Presentation contexts / Sections sections, from §0 above: the carve,
the vocabulary, both anchors, the lowering table, the policy rules,
the cuts, and the deferred follow-ons with their triggers:

- shared command identity across both anchors (the responder-chain /
  target problem) — trigger: an artifact needing shared enablement;
- For-stamped menu items (recent files);
- bind_field labels on context items in templates;
- merging app items into text-control native menus (GTK extra-menu,
  UIKit edit menu);
- GTK hamburger as a presentation hint value;
- item removal; context-item shortcuts; role-based standard items;
- a toolbar grammar: explicitly NEVER unless an artifact demands it.

Replace docs/deferred.md's "Menus/MenuBar design pass" entry with a
pointer to the DESIGN section + this plan + the open follow-ons.
Akhil reviews the DESIGN text before implementation proceeds.

## 3. Phase 2 — spec, scene, guards (the protocol root)

All in crates/kaya/src/spec.rs first; the hash moves; everything
regenerates in lockstep (tools/gen-header.sh, gen-bindings.sh,
gen-guests.sh; prove idempotence; commit generators with outputs).

New records (names normative, numbers assigned by spec.rs):

- tx `menu_item_create(item, kind)`
- tx `menu_item_append(parent_item, child_item)`
- tx `menubar_append(window, item)` — top-level `menu` items only
- tx `context_attach(widget, item)` / the node-anchored variant for
  the Tpl zone
- tx `set_menu_prop(item, mprop, value)` + the signal-source tail
  variant (label, enabled; checked/value ride the existing
  bind-shaped duals per the checkbox/choice contracts)
- occ `menu_activated`, `menu_toggled`, `menu_value_changed` (+ keyed
  variants for node-anchored context items)
- `MENU_PROPS` enum ("mprop") per the table in §0.

scene.rs: the §0 validation list, each a deterministic error with a
unit test, the should_panic style the sections slice used. capi:
count pins for MENU_PROPS and the occurrence count (the KAYA_KIND
konst_eq precedent — the spacing-prop class died twice; kill it here
on day one). kaya.h regenerates; swift-typecheck is the tripwire that
has caught every missing constant so far.

Emission checks: extend bindings/python/kaya_app_checks.py with menu
construction assertions in the same commit as the Python sugar (the
dropped-`spacing:` lesson: surface checks cannot see a constructor
that emits nothing).

## 4. Phase 3 — mac depth slice

The standard depth pattern: protocol + SwiftUI interpreter + Rust
sugar + the scene, green on validate-mac before any fan-out.
check-verbs and check-sugar-related gates are DESIGNED to hold red
mid-milestone; that is the holding pattern, not a regression.

SwiftUI interpreter (swift/KayaSwiftUI.swift — update the FOUR layers:
constants, apply arms, render/model, step-verb arms; sync the spec
hash):

- Model: `KayaMenuItem` (kind, label, enabled, checked, value,
  children, primary, shortcut) in the window model; menubar as an
  ordered list of top-level items.
- Bar: `.commands { }` on the WindowGroup building `CommandMenu`s
  from the model (ForEach over observable state — labels/enabled/
  checked all live). Toggle → `Toggle`; radio group → `Picker` inline
  (SwiftUI renders the checkmark group); shortcut →
  `.keyboardShortcut` (primary → `.command`).
- Context: `.contextMenu` on the anchored node's view; for template
  rows the emit carries the stamped keys (the on_click_node path).
- iOS same file: promoted primaries as
  `ToolbarItem(placement: .primaryAction)`; the rest behind a
  trailing More `Menu`. Hardware-keyboard menu and the HUD come free
  from the same declarations.

Harness verbs (harness.rs + Stage methods NO-DEFAULT + MockStage +
grammar tests + both interpreters — check-verbs will demand Compose
before the milestone closes):

- `menu_activate "<path>"` — labels joined with `>`; resolves
  wherever the item surfaced (bar, overflow, open context menu).
- `context_open <target>` — opens the context menu on a live-widget
  target; the scene anchors row menus on addressable labels so the
  existing target grammar suffices.
- `expect_menu "<path>" <enabled|disabled|checked|unchecked|value N>`
- `expect_menus <count>` — top-level catalog count.
- `shortcut "<spelling>"` — drives the realest dispatch the platform
  offers (see the per-backend notes); at minimum it must traverse the
  same table the platform's own key event would hit, and it must emit
  the SAME `menu_activated` occurrence.

Interpreter verb route: the established user-route pattern
(select_section precedent) — drive the model AND emit as the user.
Real-chrome driving on mac (walking NSApp.mainMenu by title and
performing the item's action through SwiftUI's trampoline) is the
depth slice's flagged risk: attempt it; if it needs NavigationStack-
back-button-grade archaeology, fall back to the model route, record
the carve-out in the ledger exactly like the ledgered mac `back`
verb, and move on. ESCALATE the verdict either way.

Rust sugar (app.rs): `tx.window(0).menu("File", |m| ...)` building
items through a menu proxy; handlers are messages —
`msgs.on_menu_item(item, Msg::Save)`, `msgs.on_menu_toggle(item,
Msg::Details)`, the alert/entry spelling. `#[must_use]` where a
chain mints a handle.

Scene: `menus` (guests/rust/menus.rs + tools/scenes/menus.steps),
registered via DEPTH_SCENES on mac first. Canonical coverage — the
scene IS the contract:

1. bar with File(action Save; action Export DISABLED via bound
   signal)/View(toggle Details bound)/Sort(radio group name|date);
2. `expect_menus 3`; `expect_menu "File>Export" disabled`; enable via
   fold; re-expect;
3. `menu_activate "File>Save"` → fold appends "saved";
4. toggle round + THE ECHO NEGATIVE: programmatic checked write, then
   assert the fold did NOT run (gallery precedent, polling cannot
   prove an absence — this keeps one deliberate settle);
5. radio: `menu_activate "Sort>Date"`, `expect_menu "Sort" value 1`,
   quiet programmatic write back to 0, absence-assert again;
6. `shortcut "primary+s"` → same fold arm as 3 (one dispatch path
   proven);
7. context: `context_open label#1` (a live label), activate
   "Rename", fold proves it; a For-row context menu on the row's
   label, activate "Remove", verdict carries the keys ("removed
   g2/a" — the second consumer of stamped keys after on_click_node);
8. one `primary` item ("Share"): on phones the steps activate it
   WITHOUT a preceding More-open, which is the structural proof of
   promotion; on desktop the same step resolves through the bar.

Verdict strings: byte-identical in all languages, decided at this
slice and never re-spelled (propose to Akhil with the slice; scene
strings are his call like commit messages).

Unit tests: parser/grammar for the new steps verbs; spec round-trips;
scene validation should_panics; shortcut-spelling normalization
table.

## 5. Phase 4 — backend fan-out (parallelizable per backend)

Each backend lands the same four observable behaviors: catalog
materialization, context materialization, prop liveness
(label/enabled/checked/value), and verb support. Verify against the
scene, not by eyeball.

**GTK4 (gtk.rs).** GMenu model per window; `PopoverMenuBar` in a
strip above the mounted root (the header bar already carries nav
chrome; the bar is its own row, the traditional Linux shape —
ESCALATE only if it collides with the nav header work). Every item
is a window-scoped `GSimpleAction` (`win.kmi_<id>`): enabled =
action.set_enabled, toggle = stateful bool action, radio group =
stateful action with targets — checkmarks and radio rendering come
free from GMenu. Shortcuts: `set_accels_for_action` (the `<Primary>`
spelling maps 1:1) — display and dispatch are native. Context:
`GtkPopoverMenu::from_model` + `GtkGestureClick` button 3 on the
anchor. Verbs activate the GAction (that IS the real dispatch path);
expect_menu reads the action/menu model. Run tools/check-gtk.sh
after every gtk.rs change — check-targets structurally cannot
compile GTK.

**WinUI 3 (winui/).** bindgen filter grows: MenuBar, MenuBarItem,
MenuFlyout, MenuFlyoutItem, ToggleMenuFlyoutItem,
RadioMenuFlyoutItem, MenuFlyoutSubItem, MenuFlyoutSeparator,
KeyboardAccelerator, VirtualKey/VirtualKeyModifiers, and the
automation peers for flyout items; regenerate bindings.rs (never
hand-edit; the missing `--check` gate is a ledgered gap — do not
widen it). MenuBar goes into the root Grid as its own row (the nav
back-bar wrapper precedent). Item kinds map 1:1
(RadioMenuFlyoutItem.GroupName per radio group). Shortcuts =
KeyboardAccelerator (primary → Control), tooltip display free.
Context: MenuFlyout as `ContextFlyout` on the element; verbs open
via `ShowAt` + invoke through automation peers (the ContentDialog
precedent). FIRST MATERIALIZATION RULE: probe in an unpackaged
process immediately (the NavigationView stow-crash class;
KAYA_WINUI_NAV_PROBE is the instrument pattern) — MenuBar is
expected clean, but expected-clean is how the last saga started.
Remember pri adjacency for any new control resources.

**Compose (KayaCompose.kt — the second interpreter; constants, apply,
render/model, verbs, hash sync; tools/check-compose.sh compiles it
on the mac before the emulator ever sees it).** TopAppBar: promoted
primaries as action IconButton/TextButton (icon blob decoded like
Image; label fallback); overflow ⋮ → DropdownMenu rendering the
catalog with headers/dividers; one submenu level as drill-in (content
swap with a back row — deterministic, no cascade gymnastics). Toggle
rows with trailing checkmark; radio rows with RadioButton. Context:
`combinedClickable(onLongClick)` on the anchored node → DropdownMenu
at the press offset; template rows resolve keys exactly as click
does. Shortcuts: the activity's dispatchKeyShortcutEvent feeds the
interpreter's shortcut table → same emit (hardware keyboards:
ChromeOS/DeX). Remember value padding (paddedString) for any
multi-value record reads.

**Traps required reading before this phase**: the aggregation trap,
pri adjacency, Compose value padding, the GTK borrow trap
(emit deferred one idle tick), the Swift grapheme/CR entry, python
str.replace anchor uniqueness (interpreter patch scripts), and the
`| rg -v warning` exit-code eater note (check verdict COUNTS).

## 6. Phase 5 — sugar sweep + guests (all eight, plus the C floor)

Sweep verdicts are per-language and explicit (do/can't/defer per the
doctrine); the expected verdict is DO for all eight — nothing here
exceeds any language's expressiveness.

Spellings per the ratified conventions (construction props +
handler-rides-declaration; menus are trees, so child conventions
apply):

- Python: `with app.menu("File"):` blocks; `kaya.item("Save",
  shortcut="primary+s", on_activate=f)`; `widget.context_menu(...)`;
  Tpl flavor takes the keys-first handler.
- Rust: the Phase-3 chains.
- Go/Java: chains — `tx.Menu("File")` proxy, `.Item("Save").
  Shortcut("primary+s").OnActivate(f)`; closed-flag discipline on
  outliving handles (the grow-chain rule).
- C#/Swift: named-args constructors nested by argument lists.
- OCaml: the curried-children convention extends to items — creators
  end in `()`, omitted unit is the child form, `menu ~label:"File"
  [ item ~label:"Save" ~shortcut:"primary+s" ~on_activate:h; ... ]`,
  labeled optionals throughout; remember the expectation-directed
  optional-erasure taste (docs/traps.md).
- Haskell: attr lists — `menu "File" [ item "Save" [IShortcut
  "primary+s", IOnActivate h] ]`, the closed-GADT class indexing
  item-only attrs so `IShortcut` on a context item is a TYPE error
  where the anchor is known (best-effort; the runtime guard is the
  floor).
- C floor: the menus scene spelled as explicit records (the floor is
  the documentation; the linux lane runs C legs).

Gate: extend the sugar-surface check to menu constructors in all 8
(check-sugar-surface gates widget kinds today; menus need an
explicit clause or a sibling check — a surface this size does not
ship gate-less; failures-become-guards). Per-binding emission
assertions for menu construction land WITH each sugar (python's in
kaya_app_checks.py; the others per the ledgered emission-checks
pattern as it exists by then).

Guests: `menus` in all 8 languages + C, byte-identical verdicts.
Runner registrations — the full checklist from deferred.md's
packaging note: validate-mac SCENES + build legs; linux SCENES +
legs (X11+Wayland; dotnet/javac pool before cargo, dune/cabal/go/C
after); deploy-win case + suites + run_menus_<lang>.cmd files
(quote-free run_ssh lines; kill-list entries); iOS bundle in
run-sim.sh (IOS_SWIFT_SCENES); Android: `mod menus` + match arm in
guests/rust/milestone2_android.rs AND the matching arm in
milestone2kt's MainActivity. check-steps' wired() will hold red until
every runner carries the leg signatures — that is the gate working.

## 7. Phase 6 — matrix and close-out

- `tools/validate-all.sh` — all five lanes concurrently; fix-forward.
- Recordings: capture the phone promoted-vs-overflow states and the
  desktop bar once, as the visual record (recording traps are in
  docs/traps.md; anchors in-band, never launch/stop arithmetic).
- Ledger: strike the executed items; record the Phase-1 follow-on
  list with triggers; record any carve-outs (mac real-chrome verb
  verdict) in DESIGN's conventions style.
- Memory/checkpoint update is Akhil's session hygiene, not the
  implementer's.

Every commit: Akhil approves the message. Suggested slice boundaries
(his to rename): "menus part 1" (spec + mac depth), "menus part 2"
(backends), "menus part 3" (sugar + guests + matrix).

## 8. ESCALATE list (never decide alone)

1. Any archaeology contradiction with §0.
2. The mac real-chrome `menu_activate` verdict (real NSMenu drive vs
   model-route carve-out).
3. GTK bar placement if it collides with existing header-bar nav
   chrome.
4. Widening the reserved-shortcut floor beyond primary+q / alt+f4.
5. The scene's canonical verdict strings.
6. Any place a platform cannot express an §0 semantic — the
   carve-out must be stated uniformly, and Akhil words it.
