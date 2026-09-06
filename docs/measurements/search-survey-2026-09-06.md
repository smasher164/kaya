# The search field, kaya's own plumbing (survey 2026-09-06)

Read for docs/search-plan.md §1. Written by a research agent from the tree at 75e86103, file:line throughout; the four options it prices and the questions it lists are the plan's §2. Its sub-surveys stayed in the session's scratch and are not needed to read this.


Research pass for the S1 design document (docs/tasks-plan.md §6, rank 1:
"a search entry filtering the open list", forced feature "the search field
(a role on entry)"). READ-ONLY survey; every claim carries a file:line.

Repo state at survey time: branch `main`, HEAD `7a58125` per the session
snapshot (working tree has later work — see §0.1).

---

## §0 — the headline, up front

**The plan's own words (docs/tasks-plan.md:445, R3 at :144-148) name the
spelling as "a role on entry", but that is explicitly UNRULED**: R3 says
"each later stage takes its own rulings at its own time: the search
field's spelling (a role on entry) …". The parenthetical is a proposal,
not a ruling. This survey is the evidence for taking it.

**The blocking fact for option (a):** roles today are legal on exactly two
kinds. `crates/kaya/src/scene.rs:842`

    Prop::Role => matches!(kind, WidgetKind::Button | WidgetKind::Label),

and the per-value check at `crates/kaya/src/scene.rs:1410-1440` binds each
of the five role numbers to ONE kind (1,2,5 → Button; 3,4 → Label). A
`search` role on `entry` widens both, and would be the FIRST role ever to
reach a third kind.

**CORRECTION to a premise this survey started with, and it matters:**
the styling `role` vocabulary IS IN THE SPEC HASH. `crates/kaya/src/spec.rs:329-335`

    for e in SPEC.enums {
        eat(e.name.as_bytes());
        for (name, value) in e.variants {
            eat(name.as_bytes());
            eat(&value.to_le_bytes());
        }
    }

and the `role` EnumSpec is one of `SPEC.enums` (spec.rs:2877-2885). So is
the `kind` EnumSpec (spec.rs:2637-2659). **Adding a role and adding a
kind are IDENTICAL on the spec-hash axis** — both move the hash, both
force `tools/gen-bindings.py` + `tools/gen-header.py` and all eleven
copies of the hash (nine generated wire files plus the two HAND-COPIED
ones, `swift/KayaSwiftUI.swift:11` and `KayaCompose.kt:1235`). Measured:
`6f997756`, the `plain` commit, moved it `0x07f8f30026825b06` →
`0x80fb73fecaaf397f`.

CLAUDE.md's sentence "`MENU_ROLES` is one line, it is not in the spec
hash" is about a DIFFERENT vocabulary — `crates/kaya/src/scene.rs:1100-1101`,
the menu GESTURE roles (`settings, cut, copy, paste, undo, redo`), a
`Str` on `MPROP_ROLE=8`. `tools/check-roles.py` guards only that one and
is untouched by a styling role. Do not carry the "roles are cheap
because they miss the hash" argument into the design doc; it is false.

(sections filled in below as the survey proceeds)


### Backing detail

Five deeper per-topic surveys sit beside this file, each with fuller
citation lists than the summaries here quote:
`sub-entry-sugar.md` (the nine bindings' entry surface),
`sub-entry-backends.md` (the four lowerings and `banked_text`),
`sub-roles.md` (roles end to end, `plain` measured),
`sub-newkind.md` (kind cost, `labeled`/pickers/slider/textarea measured),
`sub-harness.md` (verbs, observables, gates),
`sub-filtering.md` (the portfolio reconciler and the collection
primitives). READ-ONLY survey: the repo was not edited, no lane, VM,
simulator or emulator was run, and `git status` is clean.

## Contents

- **§0** the headline, and a correction to the brief's spec-hash premise
- **§0.1** repo state
- **§1.0** the entry's occurrences (and §1.0b: no placeholder prop anywhere)
- **§1.0c** the ratified precedent: the editor's find bar — and a THIRD option
- **§1.0d** a FOURTH option the brief did not name
- **§1.1** the entry's sugar in all nine bindings + the C floor
- **§1.2** how each backend lowers `entry` today (incl. WinUI `banked_text`)
- **§1.3** the native search controls: none is reachable today
- **§2** how a role works end to end, `plain` as the worked example
- **§2.G** the failure mode of a missing role arm, per backend
- **§3.0** the headline number for a new kind, measured
- **§3** how a new kind works end to end (and: "entry + a flag" is false)
- **§4** the filtering precedent
- **§5** the harness: what a search scene could and could not assert
- **§6** the toolbar question — a search field may not go in the chrome
- **§7** the ledger on search and filtering
- **§8** synthesis, and the questions only the maintainer can rule

---

## §0.1 — repo state

`git log` HEAD at survey time is `75e86103` (2026-09-06, "robustness,
round two"), well ahead of the session snapshot's `7a58125`. The three
overnight layout slices and the forms slice are IN the tree:

- `847de659` 2026-09-06 — kind 18 `labeled` (docs/forms-plan.md); the
  NEWEST widget kind, and therefore the honest cost model for §3.
- `e10e7d3a` `fill` (prop 27), `75223596` `min_column_width` (prop 28),
  `97419b0a` `wrap` (prop 29).
- `3a589f81` 2026-09-06 — R10, "a text field fills its column's width".
- `fa84be1f`, `ca812683`, `75e86103` — the robustness days.

Working tree is clean.

---

## §1.0 — THE ENTRY'S OCCURRENCES (core facts, read directly)

The full occurrence roster is `crates/kaya/src/spec.rs:2090-2605`, kinds
1..26. Every record name, in order: `button_clicked`(1),
**`text_changed`(2)**, `toggled`(3), `value_changed`(4),
`close_requested`(5), `window_closed`, `alert_result`, `entry_popped`,
`back_requested`, `section_selected`, `menu_activated`, `menu_toggled`,
`menu_value_changed`, `file_dialog_result`, `clipboard_result`,
`pasted`, `undone`, `redone`, `sort_requested`, `draw_requested`,
`tick`, `dropped`, `drag_ended`, `date_changed`, `time_changed`,
`value_committed`(26).

**An entry emits exactly ONE occurrence: `text_changed`.**
crates/kaya/src/spec.rs:2101-2115:

    Record {
        kind: 2,
        name: "text_changed",
        fields: &[ f("id", U64), f("path_len", U32), f("reserved", U32) ],
        payload: Some(PropKind::Str),
        doc: "path_len key values follow, then the entry's new text as
              one value. … The widget owns its text; the app folds these
              into its own model. USER edits and commands (clear acts
              like the user) emit; a property write is configuration and
              never echoes.",
    }

**THERE IS NO SUBMIT / ACTIVATE / RETURN OCCURRENCE ANYWHERE IN THE
SPEC.** Pressing Enter in a kaya entry emits nothing. That is the single
largest functional gap for a search field, because every platform's
search control has one and it is the control's defining event:

- WinUI `AutoSuggestBox.QuerySubmitted` (parity survey :537)
- SwiftUI `.onSubmit` / `.searchable`'s submit
- `GtkSearchEntry::activate` / `::search-changed` / `::stop-search`
- Compose `SearchBar(onSearch = …)`

**And the precedent for adding one is already in the tree, one control
over.** `value_committed` (spec.rs:2590-2604, kind 26) was added by the
slider slice for exactly this shape — a second occurrence beside an
existing per-change one, distinguishing "every movement inside the
gesture" from "the value the user settled on":

    doc: "… ONCE PER GESTURE: when the thumb is released, or a keyboard
          change lands (docs/slider-plan.md S2). value_changed carries
          every movement inside the gesture; this carries the value the
          user settled on. A programmatic write never echoes; same
          ownership stance."

A `submitted` occurrence for text would be kind 27 with the same field
layout, and `tools/check-slider-commit.py` is the gate precedent for
holding "the per-movement event is not the commit" across four backends.

**`clear` is already a COMMAND, not an occurrence.**
crates/kaya/src/scene.rs:853 — `CommandKind::Clear => matches!(kind,
WidgetKind::Entry | WidgetKind::Textarea)` — and text_changed's own doc
says "commands (clear acts like the user) emit". So an app-drawn
"Clear" button beside a search entry is spellable TODAY with zero new
surface: the button's handler issues `clear` on the entry, the entry
emits `text_changed("")`, the app's filter handler runs. What is NOT
spellable is the NATIVE clear button the platform draws INSIDE its own
search control, or the Escape key that dismisses it.

**`focus` is a command too** (scene.rs:854-863, legal on entry) — so
"focus the search field on ⌘F" is spellable today.

### The five things a search field does, against what kaya has

| the platform's search control does | kaya today |
|---|---|
| holds text, reports every keystroke | `text_changed`, spec.rs:2101 — HAVE |
| draws a magnifier glyph | NO — `symbol` is not a widget prop (§6) |
| draws a native clear ⓧ inside the field | NO — `clear` is a command the APP issues, not an affordance the user gets |
| Escape clears / dismisses | NO — no key occurrence anywhere in the roster |
| Enter submits the query | NO — no submit occurrence anywhere in the roster |
| reports as a search field to a11y | `expect_ax` role set has `field`, not search (DESIGN.md:2600) |
| a placeholder / prompt | see §1 (agent survey) — grep says kaya has no `placeholder` prop in `PROPS` (spec.rs:106-199) |

**This table is the argument, whichever way the ruling goes.** A `search`
ROLE can only buy the appearance (the magnifier, the rounded field, the
native clear ⓧ if the control draws it for free). It CANNOT buy the
submit occurrence, the Escape behaviour or an a11y value, because a role
is a pure enum with no payload (§2.F) and carries no occurrence of its
own. Those three, if wanted, are separate spec additions and are needed
under EITHER option.

### §1.0b — kaya has NO placeholder / prompt prop, on any kind

Grepped `placeholder` across the whole tree. Every hit is unrelated —
virtualization placeholder rows (DESIGN.md:3073, :3092, :3108, :3119-3120,
:3156, :3431), the drag slot's placeholder (crates/kaya/src/wire.rs:4146,
docs/dnd-plan.md §4), a clip placeholder (wire.rs:1342), the crates.io
placeholder version (DESIGN.md:3980). `PROPS` (spec.rs:106-199) has no
such slot and neither has any other prop table.

An entry's `text` (prop 1) is its CONTENT, not a prompt. So today a kaya
app that wants "Search" grey text in the field cannot author it at all.
Every platform's search idiom shows one (`.searchable(prompt:)`,
`SearchBarDefaults` placeholder, `GtkEntry:placeholder-text`,
`AutoSuggestBox.PlaceholderText`), so the search field's design has to
answer this whichever option wins — and a placeholder is a PROP (a Str),
which is orthogonal to role-vs-kind and would apply to `entry` and
`textarea` generally.

---

## §1.0c — THE RATIFIED PRECEDENT NOBODY HAS CITED YET: the editor's find bar

**docs/editor-plan.md:41-43, and it is a RATIFIED boundary:**

> The find bar is an ordinary row of kaya widgets (an entry, prev/next
> buttons, a match count) shown and hidden by the app. It is NOT a
> framework component — **that boundary is the ratified one**.

and docs/deferred.md:764-766, the ranges entry:

> kaya ships no find engine, find bar or regex dialect: those belong to
> the editor, which is what this unblocks.

The editor's find bar is built today from a plain `entry` in a stamped
row (docs/sugar-pass-plan.md:11 — `query = row.Widget(kaya.KindEntry)`;
docs/traps.md:4279 — "its find bar is a collection of ONE ROW rather
than the `When`"), and `tools/scenes/editor.steps:117` drives it.

**This means the design pass has THREE options, not two**, and the third
one is the one with a ratified precedent behind it:

- **(a) a `search` ROLE on `entry`** — the docs/tasks-plan.md:445
  parenthetical.
- **(b) a new `search` KIND** — wire 19.
- **(c) NOTHING NEW: the app composes it**, as the editor's find bar
  already does — an `entry` in a row, the guest's own filter handler,
  and at most an orthogonal `placeholder` prop so the field can say
  "Search". This is what the editor precedent ratified for `find`, and
  a search field is find one screen over.

The design doc must say WHY S1 is not (c), given that (c) is already
ratified for the sibling feature. The available answers, and their
evidence:

- The parity survey scores "search field as a **distinct control**" and
  counts frameworks that answer "use a text field" as NOT having it —
  Avalonia `P` because `AutoCompleteBox` "carries **no search chrome**"
  (docs/probes/roadmap-framework-parity-2026-09-05.md:637), egui/iced/Slint
  `N` because "a plain TextEdit is all there is" (:1270, :1370, :1470).
  By that survey's own scoring, option (c) leaves kaya at `N`.
- What (c) cannot buy at all, from §1.0's table: the magnifier, the
  native clear ⓧ, the a11y search value, Escape, submit-on-Enter, and
  the placeholder. Four of those six are missing under (a) too.

---

## §1.0d — A FOURTH OPTION the brief did not name, and the evidence for it

Recorded because §6's table makes it unavoidable, and flagged as this
survey's synthesis rather than anything the repo has ruled.

**(d) a SCREEN-LEVEL declaration, not a widget.** "This surface is
searchable" as a prop on the ENTRY (navigation entry) or the WINDOW,
with the field's text arriving as an occurrence — SwiftUI's `.searchable`
verbatim, and the shape Compose's `SearchBar` and GTK's `GtkSearchBar`
both take (a revealer/host above the content, not a leaf in the column).

The precedent for "the app declares semantics and kaya materializes the
platform's own chrome" is everywhere in this codebase and is exactly how
kaya handles the other platform-owned surfaces:

- `show_alert` / `present_alert` (spec.rs:601, :1534) — the app declares
  an alert; each backend materializes its platform's dialog.
- `show_file_dialog` / `present_file_dialog` (spec.rs:785, :1674).
- the menu bar and `primary` promotion (docs/chrome-plan.md C2) — the
  app declares actions, the platform decides the chrome.
- `sections_presentation` (WINDOW_PROPS 5, spec.rs:221) — "How this
  window presents its sections … `auto` (the default) resolves to each
  platform's dominant idiom."
- ENTRY_PROPS itself (spec.rs:247-250) is a two-slot typed table
  (`title`, `intercept_back`) that exists precisely so a
  navigation-scoped fact does not have to be a widget.

**What (d) buys that (a) and (b) cannot:** it is the only option under
which SwiftUI can call `.searchable` and Compose can host a real
`SearchBar` — i.e. the only one where two of the four backends get to
use the platform's actual search construct. Under (a) or (b) the field is
a leaf in the app's column and both must imitate it with a plain
TextField.

**What (d) costs:** the app can no longer say WHERE the field goes, and
a search field in the middle of a screen (the portfolio's filter row, a
form) becomes unspellable. It also collides with the chrome plan's
refusal of free-form toolbar widgets from the other side — (d) is not a
free-form widget in a toolbar, it is a declared semantic the platform
places, which is precisely the distinction chrome-plan C2 already draws
for `primary`. That reading should be checked with the maintainer rather
than assumed.

---

## §1.1 — THE ENTRY'S SUGAR IN ALL NINE BINDINGS + THE C FLOOR

Format per binding: **1** live constructor · **2** template constructor ·
**3** change handler · **4** submit (none anywhere) · **5** other entry
sugar · **6** the `role` setter (what "a role on entry" would ride).

**Rust** — `crates/kaya/src/app.rs`. 1 `pub fn entry(&mut self) ->
Widget<'_,'a>` `:2270` (`impl Tx` `:1359`), **takes nothing**. 2
`pub fn entry()` `:6157` (`impl Tpl` `:5996`) + `entry_bound(src)`
`:6166`; the `Row` façade forwards both at `:3464`/`:3468`. 3 raw
`Occurrence::TextChanged { id, text }` off `ctx.next()`
(guests/rust/entry.rs:35), or `Messages::on_change(w, f: Fn(String)->M)`
`:3782` / `on_change_node` `:3851`. 4 none. 5 `clear` `:2106`, `focus`
`:2115`, `set_text` `:2127`, `highlight_ranges` `:2137` / `select_range`
`:2158` / `reveal_range` `:2167`. 6 `pub fn role(self, role: crate::Role)
-> Self` `:1147`; Tpl `role(node, role)` `:6433`; Row forward `:3602`.

**Python** — `bindings/python/kaya/__init__.py`. 1 `def entry(text=None,
on_change=None, grow=None)` `:3318`; `text` is CONTENT (`tx_set_text`,
`:3324`). 2 THE SAME FUNCTION — ambient, one constructor for both zones
(tools/tpl-surfaces.py:1369-1371; python is not in `ZONES`, `:237-249`).
3 `on_change=` keyword → `_app._register(handle, wire.OCC_TEXT_CHANGED,
on_change)` `:3325-3326`. 4 none. 5 `clear` `:679`, `focus` `:683`,
`set_text` `:689`, ranges `:700`/`:716`/`:727`, `on_paste` `:538`.
6 `def role(self, role)` `:525`, on the base handle so both zones.

**Go** — `bindings/go/app.go`. 1 `func (tx *Tx) Entry(onChange
func(*Tx, string)) Widget` `:1244` — the sole argument is the handler.
2 `func (t *Tpl) Entry() Node` `:3905` + `EntryBound[S]` `:3914`; `Row`
EMBEDS `*Tpl`. 3 ctor arg or `(*App).OnChange(w, fn)` `:4558` /
`OnChangeNode` `:4564`. 4 none. 5 `Clear` `:997`, `Focus` `:1004`,
`SetText` `:647`, ranges `:1036`/`:1052`/`:1061`. 6 `(tx *Tx) SetRole`
`:958`, chained `(w Widget) Role` `:964`, `(t *Tpl) SetRole` `:3806`.

**C#** — `bindings/csharp/KayaApp.cs`. 1 `public Widget
Entry(Action<Tx,string> onChange = null, double? grow = null)` `:1832` —
no string. 2 four `Tpl` overloads: `Entry(onChange)` `:3596`,
`Entry(string text, …)` `:3603`, `Entry(Signal, …)` `:3610`,
`Entry(Field<string>, …)` `:3617` (the string SEEDS content). 3
`onChange:` or `OnChange(Widget…)` `:916` / `OnChange(Node…)` `:920`.
4 none. 5 `Clear` `:1768`, `Focus` `:1773`, `SetText` `:1642`, ranges
`:1781`/`:1805`/`:1812`. 6 `SetRole(Widget…)` `:1746`, `SetRole(Node…)`
`:3406`.

**Java** — `bindings/java/dev/kaya/KayaApp.java`. 1 `public Widget
entry()` `:4276` + `entry(BiConsumer<Tx,String>)` `:4287`. 2 `Node
entry()` `:5686`, `entry(String)` `:5696`, `entry(Signal<String>)`
`:5702`, `entry(Field<String>)` `:5716`; `RowSurface` forwards all four
`:2914`/`:2918`/`:2922`/`:2926`. 3 `onChange(Widget…)` `:6161` /
`onChange(Node…)` `:6169`. 4 none. 5 `clear` `:4338`, `focus` `:4344`,
`setText` `:3702`, ranges `:4357`/`:4375`/`:4385`. 6 `setRole(Widget…)`
`:3813`, chained `role(Role)` `:2421`, `Tpl.setRole` `:5220`,
`RowSurface.setRole` `:3112`.

**Swift** — `bindings/swift/KayaApp.swift`. 1 `func entry(onChange:…,
grow:…) -> KayaWidget` `:2819`. 2 four `KayaTpl` overloads `:4415`,
`:4426`, `:4435`, `:4444` (a String seeds; the doc at `:4421-4425`
warns a String is ONE write while a signal/field stays live). 3
`onChange:` label or `app.onChange(_ w:…)` `:1825` / node overload
`:1831`. 4 none. 5 `clear` `:2722`, `focus` `:2727`, `setText` `:2559`,
ranges `:2743`/`:2766`/`:2779`. 6 `setRole(_ w:…)` `:2626`,
`KayaTpl.setRole` `:4206`.

**OCaml** — `bindings/ocaml/kaya_app.ml`. 1 `let entry ?grow ?fill
?a11y_id ?a11y_id_bind ?a11y_label ?a11y_label_bind ?help ?help_bind
?on_change ()` `:922` — **no `?text` AND NO `?role`**, unlike `button`
`:866` and `label` `:899` which take both. 2 `Tpl.entry ?… ?accepts
?text ?bind ?bind_field ?level ?a11y_level ?on_change ()` `:3030`
(module Tpl `:2613`) — the TEMPLATE zone does take `?text`/`?bind`/
`?bind_field` (`:3039-3041`), an asymmetry with live. 3 `?on_change`
labelled argument (`:928-932` live, `:3042-3046` tpl) or
`on_change app widget handler` `:3430` / `on_change_node` `:3435`.
4 none. 5 `clear` `:823`, `focus` `:826`, `set_text` `:610`, ranges
`:838`/`:850`/`:857`. 6 `set_role (Widget id) r` `:729`;
`Tpl.Floor.set_role (Node id) r` `:2678`.

*Note for the design doc:* OCaml's live `entry` is the ONE constructor
in the tree that accepts neither `?text` nor `?role`. A `search` role
spelled as a constructor argument would have to be added there, or the
role would be set through `set_role` alone — a divergence
check-sugar-surface's role census would have to be told about.

**Haskell** — `bindings/haskell/KayaApp.hs`. 1 `entry :: (BothZones r)
=> r` / `entry = bothish (widget W.kindEntry)` `:2426-2427`. 2 THE SAME
NAME (BothZones instance `Tpl Node` at `:2407`), plus `entryBound ::
TplStrSource s => s -> Tpl Node` `:3101`. 3 `entryOn :: (LeafArgs r) =>
(String -> IO ()) -> r` `:2429`, else `onChange :: App -> e -> Keyed e
(String -> IO ()) -> IO ()` `:3909`. 4 none. 5 `clearWidget` `:1945`,
`focusWidget` `:1949`, `setText` `:1990` (floor `setTextProp` `:791`/
`:841`/`:882`), ranges `:1964`/`:1976`/`:1983`. 6 `setRole :: Widget ->
Role -> Build ()` `:2125`, and as an attr `applyAttr (Role r) w =
setRole w r` `:2271` — so `entry [Role …]` is already the attr-list
spelling, which is the cheapest of the nine for a new role.

**JS/TS** — `bindings/js/kaya/index.ts`. 1 `export function entry(opts:
TextInputOptions = {}): Widget` `:3090`; `type TextInputOptions =
GrowOption & { text?: string; onChange?: Handler }` `:3086`; `text` is
CONTENT (`:3092`). 2 THE SAME FUNCTION — ambient, one `class Handle`
serves both zones (tools/tpl-surfaces.py:362-372). 3 `onChange` option
→ `app()._register(handle, wire.OCC_TEXT_CHANGED, opts.onChange)`
`:3093`. 4 none. 5 `clear()` `:750`, `focus()` `:756`, `setText()`
`:764` — all three call `this._live(…)`, which THROWS on a template node
(`:744-746`); ranges `:774`/`:787`/`:795`; `onPaste` `:611`.
6 `role(role: RoleValue | RoleName): this` `:603`, on `class Handle`,
both zones.

**C floor** — `bindings/c/kaya_wire.h` + `crates/kaya/include/kaya.h`.
1 no per-kind constructor: `kaya_tx_create_widget(&tx, W_FIELD,
KAYA_KIND_ENTRY)` — helper `kaya_wire.h:222`, `#define KAYA_KIND_ENTRY 4`
`kaya.h:609`; guest `guests/c/entry.c:25`. 2 THE SAME CALL inside a
`create_for`/`template_end` scope (guests/c/entry.c:33-36; header
comment `kaya_wire.h:221`). 3 `kaya_parse_text_changed(rec, &id, keys, 2,
&n_keys, &text)` `kaya_wire.h:1840`, keyed on
`KAYA_OCCURRENCE_TEXT_CHANGED 2` (`kaya.h:22`). 4 none. 5
`kaya_tx_widget_command(&tx, id, KAYA_COMMAND_CLEAR|_FOCUS)`
`kaya_wire.h:340`, constants `kaya.h:583`/`:585`; `kaya_tx_set_text`
`kaya_wire.h:694`. 6 `kaya_tx_set_role(KayaTx*, uint64_t, int64_t)`
`kaya_wire.h:1174`, values `KAYA_ROLE_DESTRUCTIVE 1` … `KAYA_ROLE_PLAIN
5` `kaya.h:936-944`.

### Two corroborated absences

- **No `secure` / `password` / `obscure` anywhere.** A grep over
  `bindings/`, `spec.rs`, `wire.rs` and `guests/` returns only two NuGet
  lockfile lines.
- **Text ranges are TEXTAREA-only and the ENTRY is explicitly deferred**
  in the code itself, not only in the ledger:
  `crates/kaya/src/scene.rs:3699-3704` — "text ranges are a TEXTAREA
  surface this milestone. The entry is deferred with measured reasons
  per platform (docs/deferred.md)". So there is no `select_range` on an
  entry, which is the same fact §7.1 records from the ledger side.

### `tools/check-sugar-surface.py` has NO hand-written `entry` row

Important for §3's cost model: the kind list is DERIVED and the patterns
COMPOSED, so a NEW KIND needs no edit to that gate.

- `kinds = [m[5:].lower() for m in re.findall(r"^KIND_[A-Z_]+",
  read_rel("bindings/python/kaya/wire.py"), re.M)]` —
  `tools/check-sugar-surface.py:76-78`; `entry` enters from `KIND_ENTRY
  = 4` in the GENERATED `bindings/python/kaya/wire.py:31`. A reader
  finding no kinds is a self-test failure (`:79-81`).
- `def check_kind(kind, findings=None)` `:109-129`, driven by
  `for kind in kinds: check_kind(kind)` `:1524-1525`. The nine live
  patterns for `entry`: rust `pub fn entry[a-z_]*(<[^>]*>)?\(`
  (`:111-112`), python `^def entry[a-z_]*\(` (`:113-114`), go
  `func \(tx \*Tx\) Entry[A-Za-z]*\(` (`:115-116`), csharp
  `public Widget Entry[A-Za-z]*\(` (`:117-118`), java
  `public Widget entry[A-Za-z]*\(` (`:119-120`), swift
  `func entry[A-Za-z]*\(` (`:121-122`), haskell
  `^[[:space:]]*entry[A-Za-z]* ::` (`:124-125`), ocaml
  `^let entry[a-z_]* ` (`:126-127`), js
  `^export function entry[A-Za-z]*\(` (`:128-129`).
- Template zone is delegated to `tools/tpl-surfaces.py`
  (`check-sugar-surface.py:1533-1543`), seven structural readers in
  `ZONES` (`tpl-surfaces.py:237-249`) — python and JS absent because
  they are ambient. Prefix-loose: `entryBound`/`entry_bound` satisfy
  `entry` (`tpl-surfaces.py:1956-1969`). `DEFAULT_KINDS` must equal the
  generated wire list (`tpl-surfaces.py:27-31`, enforced `:1986-1997`).
- **What a new PROP would cost instead:** a `TPL_PROPS` /
  `PROP_MEMBERS` row (`tpl-surfaces.py:257-299`) and, for an enum with
  names, a `check_role_name`-shaped clause
  (`check-sugar-surface.py:572-603`, nine patterns per value).

### One discrepancy worth flagging to the design doc

`crates/kaya/src/spec.rs:2923-2932` declares an `occurrence` EnumSpec
with only FIVE variants — `pad`=0, `button_clicked`=1, `text_changed`=2,
`toggled`=3, `value_changed`=4 — while the occurrence RECORD list
(`spec.rs:2087-2607`) carries twenty-six. The C floor's
`KAYA_OCCURRENCE_TEXT_CHANGED 2` (`crates/kaya/include/kaya.h:22`) reads
off the small enum. Whoever adds a `submitted` occurrence should check
which of the two lists is authoritative for which consumer, because the
answer decides whether the C floor sees it.

---

## §1.2 — HOW EACH BACKEND LOWERS `entry` TODAY

Shared floor: `crates/kaya/src/wire.rs:190` `KIND_ENTRY = 4`; decode
`wire.rs:735`, encode `:3335`; spec name map `spec.rs:3380`. One
occurrence path — `crates/kaya/src/protocol.rs:2293`
`send_text_tag(tag, text)` → `wire.rs:2364` `decode_text_changed_tag`,
which reads the tag's PATH: empty → `Occurrence::TextChanged`
(`wire.rs:2369`), non-empty → `Occurrence::InstanceTextChanged`
(`:2374`).

### SwiftUI — `swift/KayaSwiftUI.swift`

| item | site |
|---|---|
| kind const | `:113` `private let kindEntry: UInt32 = 4` |
| create (model) | `:4125-4138` `case applyCreate:` → `kayaScene.entryWidgets.append(node)` |
| render arm | `:13836-13837` `case kindEntry: KayaEntry(node:flexVertical:)` |
| control | `:17417-17427` — SwiftUI **`TextField("", text: Binding(...))`** + `.textFieldStyle(.roundedBorder)`, in `struct KayaEntry: View` (`:17407-17448`) |
| edit → wire | `:17421-17425` `kayaUserWrite { node.text = value }` then `KayaHost.emitText(node, value)`; emitter `:3942-3954` |
| text apply | `:4605-4614` `case (propText, valueStr)` → `node.text = kayaLF(…)`, `kayaNoteQuietTextWrite` |
| sizing (R10) | `:17428-17434` `.frame(maxWidth: (node.grow > 0 \|\| (flexVertical == true && node.fill != false)) ? .infinity : 200)` |

The 200-point cap docs/tasks-plan.md:301-309 records is
`KayaSwiftUI.swift:17432-17434`, now conditional on `grow` / a column
that has not opted out with `fill = false`.

### Compose — `android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt`

| item | site |
|---|---|
| kind const | `:1414` |
| create | `:1866-1878` `APPLY_CREATE` → `KIND_ENTRY -> entryWidgets.add(node)` |
| render arm | `:10677` `KIND_ENTRY -> KayaTextField(node, a11y, boxFill, singleLine = true)` (textarea `:10676`, SAME composable) |
| control | `:10799-10855` — **`BasicTextField(state = node.textState, …)`**, `TextFieldLineLimits.SingleLine` (`:10808-10809`), M3 `TextFieldDefaults.DecorationBox` as `decorator` (`:10840-10854`). Deliberately NOT `TextField(value:,onValueChange:)`; reason at `:10756-10758` (its undo stack is invisible to apps) |
| edit → wire | `:10782-10798` `snapshotFlow { node.textState.text }`; echo guard `:10786`; `KayaPresent.emitTextChanged(...)` `:10795-10796` (decl `KayaPresent.kt:43`) |
| text apply | `:1904-1905` `PROP_TEXT -> kayaWriteText(...)` → `:8323-8333` |
| sizing (R10) | `:10037-10051` `textFills` → `boxFill.fillMaxWidth()` at `:10047-10050`. Compose's R10 set is WIDER than entry+textarea — `:10038-10041` covers date/time pickers and select too, "on THIS platform the pickers and the select are text fields" |

### GTK — `crates/kaya/src/gtk.rs`

| item | site |
|---|---|
| create arm | `:7934-7963` (inside `fn apply` at `:7922`) |
| control | `:7940` **`let entry = gtk4::Entry::new();`** — GtkEntry, not GtkText |
| edit → wire | `:7948-7960` `entry.connect_changed`, gated `!quiet.get()` (`:7949`), `sink.send_text_tag(&tag, &text)` `:7951`, undo-ledger bank `:7955-7958` |
| text apply | `:9663-9673` `(NativeWidget::Entry(entry), Prop::Text, Value::Str(s))` — `apply_quiet` bracket, then `note_quiet_text_write` |
| sizing (R10) | marker `:588-597` (`TEXT_FIELD_KEY` / `set_text_field`, set at `:7941`), consumed at `:711-714` in `fn apply_cross_align` (`:681`): `if vertical_container && is_text_field(child) { align = Align::Fill }` |
| intrinsic width | none — no `set_size_request`/`set_width_chars` on the entry (cf. slider `:8008` 160, textarea scroller `:8152` 240×96) |

### WinUI — `crates/kaya/src/winui/`

Directory: `bindings.rs` (11.2 MB, GENERATED), `mod.rs` (~900 KB),
`order.rs`, two title-centre probes.

| item | site |
|---|---|
| create arm | `winui/mod.rs:11105-11165` |
| control | `:11113` **`let field = TextBox::new()?;`** (textarea is a RichEditBox) |
| edit → wire | `:11122-11145` `TextChangedEventHandler`; swallow early-out `:11126-11135`; `if bank_text_changed(bank_id, &text) { sink.send_text_tag(…) }` `:11140-11142` |
| text apply | `:12417-12440` |
| sizing (R10) | `:2404-2406` in `fn reindex` (`:2247`) → `HorizontalAlignment::Stretch` `:2430-2432` |
| intrinsic width | none on the entry (`SetMinWidth`: checkbox `:11204` 0.0, slider `:11237` 160.0, textarea `:11349` 240.0) |

#### WinUI's `banked_text`, as asked

- field `winui/mod.rs:598-604` — `banked_text: HashMap<u64, String>`,
  "what the LEDGER has been shown for each field".
- two doors: `:9712-9717` `bank_text_changed(id, text)` and
  `:9723-9753` `bank_text_changed_on(core, …)` (for the harness's
  `set_text` inside `on_ui_mut`). Body: no-change guard `:9730-9732`
  compared against WHAT THE HANDLER LAST SAW, never the core model;
  unconditional insert `:9736`; ledger-quiet bracket `:9741-9747`;
  `scene.note_text_changed` `:9748-9752`.
- what `fa84be1f` added: ONE line, `winui/mod.rs:12439`
  `core.banked_text.insert(id.0, s.clone());`, placed OUTSIDE the
  `if lf(field.text()?) != s` guard at `:12432`, so the bank is stamped
  even when the control's text already matched (reasoning `:12420-12431`).
- WHY: `TextChanged` is async on WinUI and a RichEditBox raises it for
  kaya's OWN highlight paint (docs/traps.md:7068) — a raise the
  single-shot `entry_swallow` counter does not cover. That uncovered
  raise compared the document against an EMPTY bank, `bank_text_changed`
  returned true, and the whole unchanged text went to the app as a user
  edit; the `ranges` guest reset to "0 matches" over the find it had
  just answered. Sighted on `ranges_rust`, matrix #16 and standalone.
- second consumer: the `type` verb's settle, `:16225-16255`, polls
  `core.banked_text.get(&id)` (`:16233`) 400×5ms rather than the
  control, because `menu_activate "Edit>Undo"` routes off the ledger;
  why-not sentence `:16250-16255`. `fn set_text` `:16266-16299` banks at
  `:16293`.
- distinct from `entry_swallow` (`:378-384`, an `AtomicUsize` per entry
  suppressing the async echo of a programmatic write 1:1; bumped at
  `:11435`, `:12433-12435`, `:13193-13194`, `:16283-16285`).

**Relevance to S1:** a search field that filters on EVERY KEYSTROKE runs
straight through this machinery. WinUI's echo/bank pair and Compose's
`snapshotFlow` echo guard both exist because a programmatic text write
must not read back as a user edit — and an app that rebuilds its list on
each `text_changed` while the field is being typed into is the busiest
consumer this path has ever had.

### One create arm serves BOTH construction zones

The CORE expands templates into the same op stream —
`crates/kaya/src/scene.rs:6012-6026` (`TplOp::Widget` →
`out.push(ApplyOp::Create { id, kind, tag })` at `:6021`), from
`fn stamp_entry` `:5963-5997` via `fn run_body` `:6001`; the stamped tag
is `Self::button_tag(*node, copy_path)` (`:6020`). So there is NO
separate stamped path in any backend: `KayaSwiftUI.swift:4138`,
`KayaCompose.kt:1878`, `gtk.rs:7935`, `winui/mod.rs:11106` receive
stamped entries identically, and the split happens downstream in
`wire.rs:2364-2380`.

Carry into the design: GTK's undo banking explicitly does NOT cover
stamped rows — `gtk.rs:6673-6677`, "`Scene::text_field_of_tag` answers
None for a stamped row, whose typing is therefore banked on no backend."

---

## §1.3 — THE NATIVE SEARCH CONTROLS: none is reachable today

| toolkit | control | present in the repo? |
|---|---|---|
| SwiftUI | `.searchable(…)`, `.searchScopes`, `@Environment(\.isSearching)` | **docs only** (roadmap-framework-parity:43, :1683). ZERO hits in `swift/KayaSwiftUI.swift` |
| AppKit | `NSSearchField` | **zero hits repo-wide**, docs included |
| UIKit | `UISearchBar` / `UISearchController` | docs only (roadmap-…:936, find-frameworks.md:15) |
| Compose | M3 `SearchBar` / `DockedSearchBar` | **docs only** (roadmap-…:140, find-frameworks.md:511). ZERO hits in `KayaCompose.kt` |
| GTK | `GtkSearchEntry` / `GtkSearchBar` | one COMMENT in `crates/kaya/src/gtk.rs:63` — and that is the SYMBOL_SEARCH *icon* table, not a control |
| WinUI | `AutoSuggestBox` | docs only in hand-written files. In `bindings.rs` only as three opaque `usize` placeholder vtable slots on NavigationView (`:75281`, `:75282`, `:75906`) — **the class is NOT generated and is NOT in the bindgen filter `tools/winui-bindgen/src/main.rs:35-95`. Reaching it means editing that filter and regenerating the 11 MB `bindings.rs`.** |

The only search-flavoured thing already reaching all four backends is
the ICON: `wire.rs:525` `SYMBOL_SEARCH = 7` → `gtk.rs:64`
(`system-search-symbolic`), `KayaSwiftUI.swift:253` (`magnifyingglass`),
`KayaCompose.kt:1520` (`Icons.Default.Search`), `winui/mod.rs:842` —
but as established in §6 that vocabulary rides menu items and sections,
not widgets.

**And the repo's own probe already drew the distinction that decides
whether these controls are the right target.**
docs/probes/find-frameworks.md:960-964:

> *The distinction that must not be muddled:* Compose's 93 `Search*`
> symbols, WinUI's `AutoSuggestBox` and GTK's `GtkSearchBar` are **app
> search**, not document find. GTK's search bar performs no matching
> whatsoever and cannot even attach to a `GtkTextView`. Any survey done
> by keyword will read these as find bars and conclude the opposite of
> the truth.

Read the right way round, that paragraph is FOR S1, not against it: S1
is app search — a field that filters the app's own list — which is
exactly what these four controls are built for. The paragraph's warning
is aimed at the EDITOR's find bar, which is document find and correctly
gets none of them. The design doc should quote it, because a careless
reading of it would kill the native route for the wrong reason.

---

## §2 — HOW A ROLE WORKS END TO END, with `plain` as the worked example

### 2.A The vocabulary's home, and the hash

`crates/kaya/src/spec.rs:2877-2885`:

    EnumSpec {
        name: "role",
        variants: &[
            ("destructive", 1),
            ("prominent", 2),
            ("heading", 3),
            ("caption", 4),
            ("plain", 5),
        ],
    },

in `SPEC.enums` (field `spec.rs:71`, array opens `spec.rs:2607`). The
prop is `("role", 16, PropKind::Enum("role"))` at `spec.rs:144`; the wire
constants are `crates/kaya/src/wire.rs:510-514`; `PROP_ROLE = 16` at
`wire.rs:319`.

**In the spec hash — see the §0 correction.** `spec.rs:329-335`. The
eleven hash copies: generated —
`bindings/python/kaya/wire.py:13`, `bindings/go/kaya_wire.go:17`,
`bindings/csharp/KayaWire.cs:15`, `bindings/java/dev/kaya/KayaWire.java:16`,
`bindings/swift/KayaWire.swift:21`, `bindings/ocaml/kaya_wire.ml:33`,
`bindings/haskell/KayaWire.hs:27`, `bindings/js/kaya/wire.ts:10`,
`bindings/c/kaya_wire.h:202`; HAND-COPIED —
`swift/KayaSwiftUI.swift:11` and
`android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt:1235`. The first
hand run of `6f997756` died on a dylib built with the old hash.

### 2.B The four backend switches

The core checks first: `scene.rs:842` (kind union) and `scene.rs:1410-1440`
(the per-VALUE check, plus a name table at `:1427-1433` and the "does not
fit" sentence at `:1434-1439`).

1. **SwiftUI** — private numeric copies `swift/KayaSwiftUI.swift:153-157`
   (`private let rolePlain: Int64 = 5`). Three readers: the iOS button
   arm `:13736-13743` (`Button(node.text, role: node.role ==
   roleDestructive ? .destructive : nil).buttonStyle(KayaButtonStyle(
   prominent: …, plain: node.role == rolePlain))`, style at
   `:13395-13407`); `KayaMacButton.updateNSView` `:14107-14110`
   (`button.isBordered = role != rolePlain`, `contentTintColor = role ==
   rolePlain ? .controlAccentColor : nil`); the label arm `:13749-13782`,
   opening with an explicit refusal at `:13754-13757`
   (`precondition(… "kaya: label role \(node.role) has no swiftui arm")`),
   plus the iOS grouped-screen sectioniser `:12178-12187`.
2. **Compose** — private copies `KayaCompose.kt:1476-1480`
   (`const val ROLE_PLAIN = 5L`). Button `when (node.role)` `:10539-10582`
   — prominent `:10540` `Button`, destructive `:10551`
   `Button(errorContainer)`, **plain `:10563-10569` `TextButton`**,
   `else -> OutlinedButton` `:10570` (a FALLTHROUGH, not a refusal).
   Label if/else `:10589-10615`, whose final `else` IS a refusal
   (`:10612-10615`).
3. **GTK** — no private constants, bare literals, `gtk.rs:9841-9851`:

        (NativeWidget::Button(button), Prop::Role, Value::I64(role @ (1 | 2 | 5))) => {
            button.remove_css_class("destructive-action");
            button.remove_css_class("suggested-action");
            button.remove_css_class("flat");
            button.add_css_class(match role { 1 => "destructive-action", 2 => "suggested-action", _ => "flat" });
        }

   Labels `:9858-9862` (role 3) and `:9868-9873` (role 4). A new role
   edits **the pattern literal AND the inner match** — two places in one
   arm.
4. **WinUI** — bare literals, one arm per role: `winui/mod.rs:12796`
   (role 2, `AccentButtonStyle`), `:12803-12809` (**role 5,
   `SubtleButtonStyle`**), `:12810` (role 1, on the caption foreground),
   `:12821` (role 3), `:12839` (role 4), catch-all panic `:12850-12852`.
   A new style key may also need `tools/winui-bindgen/src/main.rs`.

### 2.C The nine bindings' spelling of `plain`

Two surfaces per binding: the wire NUMBER (generated by
`tools/kaya-bindgen`, each emitter carrying a `for e in spec.enums` loop
— `python.rs:36`, `go.rs:59`, `java.rs:59`, `csharp.rs:80`,
`ocaml.rs:57`, `haskell.rs:70`, `js.rs:66`) and the NAME (hand-written).

| # | binding | wire number (generated) | role NAME (hand) | `role(…)` setter |
|---|---|---|---|---|
| 1 | Rust | `crates/kaya/src/wire.rs:514` | `crates/kaya/src/app.rs:5445` `Plain = 5,` (enum `Role` `:5426`) | live `app.rs:1147`; tpl `:3602`, `:6433` |
| 2 | Python | `bindings/python/kaya/wire.py:156` | `__init__.py:2814` `PLAIN = wire.ROLE_PLAIN` AND `:2822` `"plain": wire.ROLE_PLAIN,` — TWO sites | `role=` kw; `_role_value()` `:2826` |
| 3 | Go | `bindings/go/kaya_wire.go:160` `RolePlain = 5` | **none** — Go spells the role AS its wire constant | `app.go:958` `SetRole`; `:964` `Role` |
| 4 | C# | `bindings/csharp/KayaWire.cs:158` | `KayaApp.cs:376` `Plain = KayaWire.RolePlain,` | `KayaApp.cs:1746`; tpl `:3406` |
| 5 | Java | `bindings/java/dev/kaya/KayaWire.java:159` | `KayaApp.java:155` `PLAIN(KayaWire.ROLE_PLAIN);` (enum `:141`) | `:2421`, `:3813`; tpl `:3112`, `:5220` |
| 6 | Swift | **none** — `bindings/swift/KayaWire.swift:1062` has only `setRole(_:_ role: Int64)` | `bindings/swift/KayaApp.swift:348` `case plain = 5` — **number HAND-TYPED** | `KayaApp.swift:2626`; `role:` arg `:2807`, `:2842`; tpl `:4206` |
| 7 | OCaml | `bindings/ocaml/kaya_wire.ml:176` | `kaya_app.ml:720` `type role = … \| Plain` AND `:727` `\| Plain -> Int64.of_int Kaya_wire.role_plain` — TWO sites | `:729`; `?role` `:875`, `:906`; tpl `:2678` |
| 8 | Haskell | `bindings/haskell/KayaWire.hs:311-312` | `KayaApp.hs:2114` `Plain` AND `:2122` `roleWire Plain = 5` — **number HAND-TYPED, does NOT read `KayaWire.rolePlain`** | `:2125-2126`; attr `:2271`; tpl `:3021` |
| 9 | JS | `bindings/js/kaya/wire.ts:153` | `index.ts:2746` `PLAIN: wire.ROLE_PLAIN,` AND `:2749` `RoleName = … \| "plain"` | `index.ts:603` |
| — | C floor | `crates/kaya/include/kaya.h:944` (cbindgen from `capi.rs:1010`, equality assert `:1016`) | the macro is the name | `bindings/c/kaya_wire.h:1174`, role-agnostic |

**Hand-typed numbers no generator holds — the drift surface:**
`bindings/swift/KayaApp.swift:348`, `bindings/haskell/KayaApp.hs:2122`,
`crates/kaya/src/app.rs:5445`, `crates/kaya/src/capi.rs:1010`,
`swift/KayaSwiftUI.swift:157`, `KayaCompose.kt:1480`, and the bare
literals in `gtk.rs:9841/9846-9849` and `winui/mod.rs:12803`.

**Only `heading` and `caption` have CONSTRUCTOR sugar**
(`tools/check-sugar-surface.py:496-551`, 18 patterns × both zones).
`destructive`, `prominent` and `plain` ride the generic `role(…)`
setter — so a `search` role would follow `plain`: name only, no
constructor. (Unless the design wants `search_entry()` sugar, which is
then a constructor census clause of its own.)

### 2.D The gates

- **`tools/check-roles.py` does NOT guard the styling role at all.**
  Every clause reads `MENU_ROLES` out of `scene.rs` (`:109`, `:228`,
  `:243`) — the menu gesture vocabulary. Three clauses: per-backend
  `role_enabled`/`perform*Role` must name every gesture role
  (`:120-142`, BACKENDS table `:87-96`); a `matches!` naming any gesture
  role must be total (`:144-166`); the `PLACEMENT = {"settings"}`
  exemption (`:83`) is itself guarded (`:168-190`). Nine watched
  negatives (`:270-325`). **Adding a styling role touches it zero times.**
- **`tools/check-sugar-surface.py` is the real role census** —
  `:564-613`. `check_role_name(snake, pascal, upper)` at `:572` with
  NINE patterns at `:583-595`:

        rust    crates/kaya/src/app.rs                 ^    {Pascal} = \d,$
        python  bindings/python/kaya/__init__.py       ^    {UPPER} = wire.ROLE_{UPPER}$
        go      bindings/go/kaya_wire.go               ^\tRole{Pascal} = \d+$      # the GENERATED file
        csharp  bindings/csharp/KayaApp.cs             ^    {Pascal} = KayaWire.Role{Pascal},$
        java    bindings/java/dev/kaya/KayaApp.java    ^        {UPPER}\(KayaWire.ROLE_{UPPER}\)[,;]$
        swift   bindings/swift/KayaApp.swift           ^    case {snake} = \d$
        haskell bindings/haskell/KayaApp.hs            ^roleWire {Pascal} = \d$
        ocaml   bindings/ocaml/kaya_app.ml             ^  \| {Pascal} -> Int64.of_int Kaya_wire.role_{snake}$
        js      bindings/js/kaya/index.ts              ^  {UPPER}: wire.ROLE_{UPPER},$

  The driving list is `:598-603` — **adding a role is ONE tuple line
  there.** Watched negative `:605-613` (`kaya_fake_role` must fire all 9).
- **`tools/check-verbs.py:1116-1139`** censuses the interpreters' private
  constant copies; the alternation gained `ROLE|ALIGN` at `:1122-1123`;
  the floor at `:1136-1139` refuses fewer than 5 `ROLE_*`. **Adding a
  role is `5` → `6`, one line.**
- Everything else naming "role" is a different thing:
  `tools/tpl-surfaces.py:257, 266-304` censuses the role SETTER per
  binding (not the vocabulary); `tools/build-id.py:69-71`;
  `tools/gates.py:82-85`; `tools/lib/scene-features.py:71, 190-213`
  (MENU_ROLES again); `tools/check-canvas-blit.py:14, 431` ("paint role").

**No scene sees `plain`.** `tools/scenes/styling.steps:1-14` says so:
`heading` is the one role with a real-tree observable on every platform;
`destructive` and `prominent` are declared only so each backend's arm
runs. `plain` is proved indirectly through geometry —
`tools/scenes/align.steps:17-20`, `expect_aligned row@plain "center"`.

### 2.E THE MEASURED COST OF ONE MORE ROLE

`plain` landed in **`6f997756`** (2026-09-05), a commit that also carried
R5/R7/R9, D6.2 `columns_when`, the Windows pane shape and the GTK
intrinsic-image fix — **70 files, +1832 / -245 in total.** The role hunks
separate cleanly (the judgement calls: the `align.steps` / align-guest
`row@plain` hunks are R5's row ID, not the role; the
`picture.set_can_shrink` hunk is the GTK image fix).

**HEADLINE: +172 / -37 across 31 files for one role**, of which
**+62 / -4 is ONE-TIME gate construction** written for `plain`. **The
RECURRING cost of role number six is +110 / -33 over 29 files** — 11 of
those files change only their spec-hash line, 10 more are fully
generated, and roughly half the remaining lines are doc comments.

| group | files | lines | note |
|---|---|---|---|
| core `crates/kaya` | 6 | +20 / -4 | `scene.rs` is the only real logic |
| the four backends | 4 | +35 / -9 | GTK's is a rewrite, +11 / -8 |
| 9 bindings + C floor | 15 | +34 / -16 | 10 files fully generated |
| gates | 2 | +62 / -4 | **one-time** |
| guests | 1 | +2 | optional |
| docs | 1 (+plan/ledger) | +8 / -1 | |
| (spec-hash-only lines, inside the above) | 11 | +11 / -11 | 9 generated, 2 hand |

Two of the eleven hash files — `bindings/c/kaya_wire.h:202` and
`bindings/swift/KayaWire.swift:21` — carry NO other role line at all;
they are in the change only because the hash moved.
`bindings/go/styling_test.go:285` +1/-1 is a pinned refusal sentence that
moves when the role list grows.

### 2.E2 The checklist for `search` = 6

1. `spec.rs` — the variant (~:2884) AND the `mod tests` name→value mirror
   (~:3498). **Hash moves.**
2. `wire.rs` — `ROLE_SEARCH: u32 = 6`.
3. `capi.rs` — const + one assert line (`:1010`, `:1016`).
4. `app.rs` — `Role::Search = 6` (`:5445` area).
5. **`scene.rs:842` — widen `Prop::Role`'s kind union to include
   `Entry`. This is the first role ever to reach a THIRD kind.**
6. `scene.rs:1410-1440` — value arm, name table, BOTH sentences.
7. Run `tools/gen-bindings.py` + `tools/gen-header.py` (10 generated
   files, 9 also carrying the new hash).
8. Hand-edit the NAME in seven bindings (python ×2, csharp, java, swift,
   ocaml ×2, haskell ×2, js ×2; **Go needs nothing**).
9. `bindings/go/styling_test.go:285` — the pinned sentence.
10. Four backends: `KayaSwiftUI.swift` (constant + button arm + the macOS
    NSButton arm + the label precondition), `KayaCompose.kt` (constant +
    arm), `gtk.rs:9841` (pattern AND inner match), `winui/mod.rs` (one
    arm). **Plus, for `search`, a brand-new ENTRY arm in all four —
    every existing role arm is keyed on Button or Label.**
11. The two hand-copied hashes: `swift/KayaSwiftUI.swift:11`,
    `KayaCompose.kt:1235`.
12. `tools/check-sugar-surface.py:598-603` — one tuple.
13. `tools/check-verbs.py:1137` — floor `5` → `6`.
14. `docs/styling-plan.md` D4 + the plan/ledger entry.
15. **Nothing** in `tools/check-roles.py`, `tools/tpl-surfaces.py`, or
    any scene — *unless the role publishes an accessibility fact*, which
    §5 says it would have to in order to be observable at all.

### 2.F ROLE PAYLOAD — a role is a PURE ENUM, definitively

**One I64. No payload, no per-role props, no per-role occurrence.**

- `spec.rs:144` — `("role", 16, PropKind::Enum("role"))`.
- `spec.rs:88-89` — "One of the spec's enums, named here. **Rides the
  wire as I64.**"
- The carrier is `set_property` (`spec.rs:396-405`): fields
  `widget_id: U64, prop: U32, source: U32`, `payload: None`, one value
  in the tail. The C floor shows it bare at
  `bindings/c/kaya_wire.h:1174-1181`.
- `spec.rs:141-143` says it outright: "Which VARIANT fits which kind is
  the root's check, not a type — **the prop is one wire slot**."
- The role IS signal- and element-bindable (`kaya_wire.h:1184`, `:1195`),
  so the value is dynamic — but it is still one integer.

**No per-role prop mechanism exists.** The typed prop tables are `PROPS`,
`WINDOW_PROPS`, `ENTRY_PROPS` (`spec.rs:247-250`), `SECTION_PROPS`
(`:254-261`) and `MENU_PROPS` (`:266+`). Props are scoped BY KIND
(`scene.rs:842` and neighbours), never by role. No table anywhere is
keyed on a role value.

**No per-role occurrence exists.** The occurrence channel is 26 flat
records (`spec.rs:2090-2607`), each keyed on a widget id and a kind,
never a role.

#### What a `search` ROLE could not carry

1. **A clear/cancel occurrence.** None exists, and a role cannot
   introduce one. A platform search field's own clear ⓧ would arrive as
   `text_changed` with `""` (spec.rs:2101-2115, whose doc says "USER
   edits and commands (clear acts like the user) emit") —
   indistinguishable from select-all-delete. Reporting the cancel
   affordance means a NEW occurrence record, with an arm in all four
   backends and all nine bindings. The role buys nothing toward it.
2. **A submit occurrence.** There is NONE today for any kind. An `entry`
   emits `text_changed` and nothing else. A search field whose semantics
   is "act on Return" cannot express that through a role.
3. **Per-role configuration** — a placeholder/prompt, a scope bar, a
   suggestions list, a debounce. Each would be a new PROP, and a prop is
   KIND-scoped, so it would be legal on every `entry` whether or not it
   wears the role. **That asymmetry is precisely what a new KIND
   avoids**, and it is the strongest structural argument in the survey.

**The bearing on the ruling, stated plainly.** A role is a one-integer
*look and meaning* tier with no state, no events and no props of its own.
It is the right shape only if the search field is exactly a text entry
whose CHROME differs and whose behaviour is entirely `text_changed`. The
moment `search` needs to (a) report a submit, (b) report the clear
button, or (c) take a prop nothing else takes, the role tier cannot
express it.

---

## §2.G — THE FAILURE MODE of a missing role arm, per backend

This decides what a `search` role on `entry` costs and how loudly a
missing arm fails.

| backend | switch site | shape | if the ENTRY has no arm |
|---|---|---|---|
| SwiftUI | `:13724`, `:13738-13743` (button); `:13755-13782` (label); `:14109-14110` (NSButton `isBordered = role != rolePlain`) | `if node.role == roleX` INSIDE the kind arm | **silent** |
| Compose | `:10539-10582` `when (node.role)` inside `KIND_BUTTON`; label `:10589-10626` with `check(node.role == 0L)` at `:10616` | `when(node.role)` per kind | **silent** |
| GTK | `gtk.rs:9841-9851`, `:9858-9862`, `:9868-9873` | `(NativeWidget, Prop, Value)` tuple match | **PANIC** `gtk.rs:10116` |
| WinUI | `winui/mod.rs:12796-12849` | `(NativeWidget, Prop, Value)` tuple match | **PANIC** `winui/mod.rs:12850-12852` |

Two of four fail loudly, two silently. Compose's label arm at `:10616`
even asserts `node.role == 0L` — a role on a kind it did not expect is a
`check()` failure there, which is the good shape.

Core cost of `search` = role 6: `spec.rs:2884` (add `("search", 6)`),
`wire.rs:514` area (a new `ROLE_SEARCH: u32 = 6`), `scene.rs:842` (widen
the union to include `WidgetKind::Entry`), `scene.rs:1411-1425` (add
`6 => kind == WidgetKind::Entry` and a name arm). Then all nine bindings
must spell the NAME — `tools/check-sugar-surface.py:572-603`
`check_role_name`, nine patterns per role — and
`tools/check-verbs.py:1136-1138` censuses the ROLE constants with a
floor of 5, reading both interpreters' private copies.

---

## §3.0 — THE HEADLINE NUMBER for a new kind, measured

`git show --stat 847de659` — kind 18 `labeled`, the NEWEST widget kind
(2026-09-06), depth AND breadth in ONE commit:

    61 files changed, 1959 insertions(+), 131 deletions(-)

The file list, grouped (full stat in the command output; every path below
is from that stat):

| group | files | notable line counts |
|---|---|---|
| core | `crates/kaya/src/{spec.rs +2, wire.rs +3, protocol.rs +13, scene.rs +212, harness.rs +11, capi.rs +4, app.rs +39}`, `crates/kaya/include/kaya.h +2` | scene.rs +212 is the root's shape validation and its six unit tests |
| backends | `crates/kaya/src/gtk.rs +235`, `crates/kaya/src/winui/mod.rs +288`, `swift/KayaSwiftUI.swift +254`, `android/.../KayaCompose.kt +169` | ~950 lines across four arms |
| generated wire files (9) | `bindings/{c/kaya_wire.h, csharp/KayaWire.cs, go/kaya_wire.go, haskell/KayaWire.hs, java/dev/kaya/KayaWire.java, js/kaya/wire.ts, ocaml/kaya_wire.ml, python/kaya/wire.py, swift/KayaWire.swift}` | 2-4 lines each — GENERATED, so free |
| hand-written binding sugar (8 + Rust in-crate) | `bindings/{csharp/KayaApp.cs +46, go/app.go +52, haskell/KayaApp.hs +19, java/.../KayaApp.java +61, js/kaya/index.ts +22, ocaml/kaya_app.ml +35, python/kaya/__init__.py +28, swift/KayaApp.swift +73}` + `crates/kaya/src/app.rs +39` | **~375 hand-written lines, nine idioms, BOTH construction zones** |
| conformance guests (10) | `guests/{c/gallery.c, csharp/GalleryScene.cs, go/gallery/gallery.go, haskell/gallery.hs, java/dev/kaya/guests/Gallery.java, js/gallery.ts, ocaml/gallery.ml, python/gallery.py, rust/gallery.rs, swift/gallery.swift}` | 4-19 lines each — every kind joins the gallery scene |
| generated record classes (7) | `guests/csharp/{Account,DndItem,Item,TableItem,Task,Todo,Track}Kaya.cs` +8 each | generated |
| scenes | `tools/scenes/gallery.steps +3`, `tools/scenes/tasks.steps +5` | |
| gates | `tools/check-steps.py`, `tools/tpl-surfaces.py`, `tools/kaya-csgen/Program.cs`, `tools/run-leg.py`, `tools/linux/run-suites.sh` | small edits: TARGET_KINDS, the 18-kind census |
| docs | `DESIGN.md +11`, `docs/{forms-plan.md +93, layout-knobs-plan.md +63, deferred.md +52, traps.md +33, adaptive-layout-plan.md +11, tasks-plan.md +17}` | |
| the consuming guest | `guests/rust/tasks.rs +53/-…` | |

**Caveat, stated honestly:** `847de659` is not a pure new-kind commit —
it also carried the derived-form lowering (a column of labelled rows IS
a form), the iOS grouped-screen widening, two Compose sizing fixes and
two guards. The share attributable to "a kind exists and all nine
bindings can spell it" is roughly the generated-wire rows (free), the
~375 lines of binding sugar, the ten gallery guests, and the four
backend create/apply arms; the form derivation is most of scene.rs's
+212 and much of the four backends' totals.

**Cross-check needed:** the date/time pickers and the slider (see the
agent survey in §3) are the second and third data points. The pickers
were TWO kinds at once (16, 17) and their commit is the better
apples-to-apples number for "one control, five platforms".

---

## §3 — HOW A NEW KIND WORKS END TO END, measured

### 3.1 First, a correction to the brief's worked example

**The slider is NOT a recently added kind.** `slider` is wire kind 7 and
dates from `258b7071` (2026-07-16, "add sliders");
`docs/slider-plan.md` §0 says so — "`slider` (kind 7) is one of the
original roster controls". The 2026-09-04 slider work
(`7e57dd01` depth, `0914b996` breadth) added **two PROPS** (`step`,
`tick_spacing`) and a committed-value occurrence to an EXISTING kind.

The three usable data points are therefore:

| kind | wire # | commit(s) | why it is or is not a clean measurement |
|---|---|---|---|
| `labeled` | 18 | `847de659` 2026-09-06 | **NEW kind, the cleanest measurement in the repo**: no new prop, no new occurrence, no new value type, no new verb; depth and breadth in one commit |
| `date_picker` / `time_picker` | 16 / 17 | `50b9048a` depth + `28c672aa` breadth, 2026-09-04 | NEW kinds, but bundled with 2 new PropKind labels, 5 props, 2 occurrences and a new record-field type family — OVERSTATES a kind's cost |
| `slider` props | — | `7e57dd01` + `0914b996` | a PROP data point, not a kind one — and see §3.5, it cost MORE than `labeled` did |

### 3.2 The mechanical checklist, file by file

**Spec — two edits, and the hash moves.**
`crates/kaya/src/spec.rs:2637-2659` (the `kind` EnumSpec; `("labeled",
18)` at `:2657`) and `spec.rs:3371-3394` (the name→wire pin,
`enums_match_wire`, `:3394`). The hash walk is `spec.rs:305-335` and
`:329-335` eats every enum's variants — **measured: `847de659` moved
`KAYA_SPEC_HASH 0x80fb73fecaaf397f` → `0x27300640cf479cec`.** The nine
generated wire files plus `crates/kaya/include/kaya.h` regenerate, and
the three HAND-WRITTEN hash copies pinned by
`tools/check-verbs.py:1167-1180` move with them (`kaya_wire.h`'s
`KAYA_SPEC_HASH`, `KayaSwiftUI.swift`'s `let kayaSpecHash`,
`KayaCompose.kt`'s `SPEC_HASH: ULong`). Wire-file cost of the kind
itself: **+19/-9 across 9 files + `kaya.h`**, almost all of it the moved
hash.

**wire.rs — three arms.** `:204` the constant, `:730-752` `fn
widget_kind` decode (`:749`), `:3330-3351` `fn kind_raw` encode
(`:3349`).

**protocol.rs — three sites, one a FORCED compile error.** the
`WidgetKind` variant + doc `:876-937`; `WidgetKind::ALL: [WidgetKind;
18]` `:1094-1114` — **the length literal must be bumped**; and
`carries_tag()` `:1123-1147`, exhaustive with no wildcard, whose own
comment says why (`:1134-1136`): "A kind added to the spec lands here as
a compile error, which is the moment to decide whether it reports."

**capi.rs — a value pin AND a count pin.** `:631`
`KAYA_KIND_LABELED`; `:632-651` a `const _: () = assert!` chaining every
`KAYA_KIND_* == wire::KIND_*` (`:650`); `:652-671` a SECOND const-assert
counting exports — `assert!(kinds == 18, "the spec kind enum grew:
export the new KAYA_KIND_* above, extend the pin, and bump this count")`
at **`:668`. That literal must be bumped too.**

**scene.rs — where a kind's SEMANTICS cost lives.** 347 `WidgetKind::`
sites (`#[cfg(test)]` starts `:6976`). `fn check_prop` `:750-845` is 22
prop arms, each a `matches!` — `labeled` appears in two, `Prop::Spacing`
(`:786`) and `Prop::Inset` (`:801`). `fn check_command` `:851-866` —
`labeled` in neither. Plus whatever shape validation the kind needs:
`labeled` needed a root-side shape validator in both zones (`:1317-1337`,
`:1784`, `:1918-1928`, `:2763`) — **`scene.rs` +204/-8, the single
biggest core cost**, including six unit tests.

**harness.rs — three sites, +8 lines for `labeled`.** `pub enum
TargetKind` `:55-93` (`:82`); `fn parse_target_kind` `:2099-2121`
(`:2118`) — the `entry@quickadd` parser; `fn target_spec` `:4170-4190`
(`:4189`) — the byte-compared verdict spelling.

**The four backends — the real cost centre.** Each keeps a
native-widget variant, a registry vector, an init, a create arm and
three to six target-resolution arms:

- **GTK** `crates/kaya/src/gtk.rs`, 17 sites: `NativeWidget::Labeled`
  `:1776`, `:1801`, `struct GtkLabeledRow` `:1826`, `kind_registry`
  `:2302`, registries `:3023`/`:3026`, `target_of` `:6041`, **create arm
  `:8218-8232`**, `:9768`, `:10043`, `:10053`, `:10177-10206`, init
  `:11029`, `target_widget` `:14902`
- **WinUI** `crates/kaya/src/winui/mod.rs`, 30 sites: `:135`, `:159`,
  `:453`, `:1888`, `:1997`, `:2029`, `:2111-2117`, `:2250`, `:2392`,
  `:2482`, **create `:11189-11193`**, `:11612`, `:12390`, `:12642`,
  `:12651`, `:12936`, `:12964`, `:14451`, `:14760`, `:14767`, `:14841`,
  `:14926`, `:14970`, `:15004`, `:15066`, `:16947`, `:17041`, `:17197`,
  `:17369`
- **SwiftUI** `swift/KayaSwiftUI.swift`, 8 sites: constant `:127`,
  registry `:681`, apply `:4150`, target table `:6191`,
  `KayaLabeledFold` `:11836`, form detect `:12045`, **render
  `:13677-13710`**
- **Compose** `android/.../KayaCompose.kt`, 8 sites: registry `:848`,
  constant `:1428`, apply `:1892`, target table `:4824`, `:9941`,
  `:10018`, `:10351`, **render `:10470`**

Measured for `labeled` (hunks naming the kind): **gtk +206/-1,
winui +250/-17, SwiftUI +197/-18, Compose +101/-5 = +754/-41.**

**The generators — what each WRITES.**

| generator | outputs | does a new kind change it? |
|---|---|---|
| `tools/gen-header.py` (cbindgen) | `crates/kaya/include/kaya.h` | yes — one `#define` |
| `tools/gen-bindings.py` → `tools/kaya-bindgen/src/{c,csharp,go,haskell,java,js,ocaml,python,swift}.rs` | the nine `bindings/*/…Wire.*` files + `bindings/.generator-id` | yes (one constant each) — but **no emitter edit needed**. Contrast: the pickers' new PROP KINDS forced edits in all nine emitters, `tools/kaya-bindgen/src/*.rs` **+572/-95** |
| `tools/gen-guests.py` (go generate, java processor, `tools/kaya-csgen`, `tools/kaya-swift-gen`) | `guests/*_kaya.go`, `guests/*Kaya.java`, `guests/*Kaya.cs`, `guests/*+Kaya.swift` | **YES, indirectly** — C#'s generated `<Rec>Row` façade forwards every template-zone constructor, so `847de659` regenerated **seven `guests/csharp/*Kaya.cs` at +8 each (+56)** and edited `tools/kaya-csgen/Program.cs` (+3). The naive reading ("gen-guests is record-driven, kinds do not touch it") is wrong |
| Rust "binding" | none — `crates/kaya/src/app.rs` is hand-written | n/a |

**The gates a new kind trips.**

| gate | learns the kind how | edit needed |
|---|---|---|
| `tools/check-sugar-surface.py:76-78` | **derives** from `bindings/python/kaya/wire.py`'s `KIND_*` | none — but `check_kind()` `:109-129` then demands **nine live-zone constructor patterns**, one per binding; `kind_case()` `:98-106` handles snake→Pascal/camel |
| `tools/tpl-surfaces.py:27-31` `DEFAULT_KINDS` | **HAND-MAINTAINED**, held equal to the wire at `:1983-1991` with a one-short watched negative | **+1 word**, then a TEMPLATE-zone constructor demanded in all nine |
| `tools/check-steps.py:74-78` `TARGET_KINDS` | **HAND-MAINTAINED**, held equal to the wire at `:3660-3685` | **+1 word** |
| `tools/check-verbs.py:1002-1046` | derives from `harness.rs`'s `parse_target_kind` | demands `case "<kind>"` in `KayaSwiftUI.swift:6169-6194` and `"<kind>" ->` in `KayaCompose.kt:4803-4833` |
| `tools/check-verbs.py:1122-1163` | reads `KIND_*` out of `wire.rs` | demands `let kind<Pascal> = 18` (Swift) and `KIND_LABELED = 18` (Kotlin) |
| `tools/check-universal-props.py` | derives from `wire.py` | the universal a11y props must reach the new kind in all four backends |
| `tools/check-targets.py:201` → `tools/lib/stage-coverage.py` | text-checks `Stage` methods per backend | only if the kind brings a verb |
| `crates/kaya/src/capi.rs:668`, `protocol.rs:1095` | count literals | **+1 each** |

**There are exactly TWO hand-maintained kind lists in the tree** —
`TARGET_KINDS` and `DEFAULT_KINDS` — and both are held equal to the
generated wire, so forgetting either is a red rather than a silent miss
(made so by `50b9048a`).

### 3.3 The numbers

**`labeled` — `847de659`. 61 files, +1959 / -131.**

| bucket | files | +/- | notes |
|---|---|---|---|
| generated (9 wire + `kaya.h` + 7 `*Kaya.cs`) | 17 | +75 / -9 | wire files +19/-9; the seven C# row façades +56 |
| **hand-written binding sugar, 9 languages × 2 zones** | 9 | **+375 / -0** | swift 73, java 61, go 52, csharp 46, rust `app.rs` 39, ocaml 35, python 28, js 22, haskell 19 |
| core Rust | 5 | +223 / -11 | `scene.rs` +204/-8 |
| harness | 1 | +9 / -2 | ~+8 attributable |
| **backends** | 4 | +877/-69 → **+754 / -41 attributable** | winui 250, gtk 206, SwiftUI 197, Compose 101 |
| guests (10 gallery + `tasks.rs`) | 11 | +88 / -25 | 4-5 lines per gallery guest |
| gates + scenes + lane tooling | 7 | +33 / -14 | `check-steps.py` +1/-1, `tpl-surfaces.py` +1/-1, scenes +6/-2 |
| docs | 7 | +279 / -1 | |

Bundled unrelated work, deducted: `docs/layout-knobs-plan.md` +63; the
iOS grouped-screen widening in `KayaSwiftUI.swift` +34/-5; the Compose
select-icon and bottom-bar fixes +51/-12; `tools/run-leg.py` +3.
**Net of docs and bundling, the kind is ~50 files and ~+1550 lines.**

**date/time pickers — two commits.** Depth `50b9048a`: **47 files,
+3553/-149** (generated wire 9 files +1331/-20; Rust sugar +317; core 6
files +468, `protocol.rs` +234 for `Date`/`Time`; harness +138 for three
no-default `Stage` methods and two verbs; backends 4 files +418 —
SwiftUI +360, the other three only their `depth_stub` refusals;
**generators 10 files +572/-95**; guests +104; `pickers.steps` +45;
gates +78/-7; docs +70). Breadth `28c672aa`: **88 files,
+27690/-14413** — but **+22022/-14207 is ONE FILE**,
`crates/kaya/src/winui/bindings.rs`, a full winmd regeneration from
admitting `Windows.Foundation.DateTime`. **Excluding it: 87 files,
+5668/-206** (generated guest surfaces 22 files +920; binding sugar 16
files **+2069/-42**; backends 7 files +1464/-86, winui 515, gtk 503,
Compose 379; guests 14 files +559; gates 19 files +232/-45). Follow-up
`2adc3c08`: 4 files +33/-9. **Two kinds ≈ 135 file-touches, ≈
+9250/-355** excluding the winmd blob — inflated by two PropKinds, five
props, two occurrences and a new field-type family.

**slider, the original** — `258b7071` (2026-07-16): 57 files
+14829/-7062; excluding a +12439 winmd regeneration, **56 files
+2390/-502**, against an eight-binding tree.

### 3.4 Harness and scene cost of a kind

**A per-kind target-address parser: YES, three of them.**

1. `crates/kaya/src/harness.rs:2099-2121` `parse_target_kind` (the
   grammar) + `:4170-4190` `target_spec` (the verdict spelling)
2. `swift/KayaSwiftUI.swift:6169-6194` `kayaAnyTarget` — `case
   "labeled": return kayaTarget(spec, "labeled", kayaScene.labeleds)`,
   behind it a registry array (`:681`) and an apply arm (`:4150`)
3. `android/.../KayaCompose.kt:4803-4833` `kayaWidgetTarget` —
   `"labeled" -> KayaSceneModel.labeleds`, registry `:848`, apply `:1892`

`tools/check-verbs.py:1002-1046` censuses (2) and (3) against (1) with a
watched negative each, and its comment records why: "the canvas fan-out
never added `canvas` to KayaCompose.kt's kayaWidgetTarget" — a missing
row makes FIVE verbs answer "no such target". The widget backends
resolve from `Vec` registries instead: `gtk.rs:2291-2308`, `:6031-6048`,
`:14877-14902`; `winui/mod.rs:14970`, `:15004`, `:15066`, `:16947`.

**One kind = 3 parser/table rows + 4 backend registry rows + 2
interpreter arrays + 2 apply arms + 2 private constants.**

**Per-kind VERBS: no — verbs are per-verb and whitelist kinds.**
`labeled` added no verb; its only observable rides the pre-existing
`expect_ax` (`tools/scenes/gallery.steps:18` `expect_ax slider#1
"slider/Level"`; `tools/scenes/tasks.steps:70,72` `expect_ax
date_picker@when "datetime/When: none"`). **Entire scene cost of kind
18: +3 lines in `gallery.steps`, +3/-2 in `tasks.steps`, no new `.steps`
file.**

The slider's verbs, for contrast: `Step::SetValue(Target, f64)`
`harness.rs:155`, `Step::ExpectSlider` `:167`; parser `:1288-1299`,
`:1318-1330`; run arms `:2855-2861`, `:2876-2886` (the
`TargetKind::Slider` whitelist is INSIDE the run arm, refusal at
`:2885`); two **no-default `Stage` methods**, `fn set_value` `:760` and
`fn slider_value` `:776` — the trait doc at `:754-756`: "NO METHOD HERE
GETS A DEFAULT BODY. A backend that forgets one must fail to COMPILE."
Impls `gtk.rs:12364`, `winui/mod.rs:16135`, three `MockStage`s
(`harness.rs:5011`, `:5907`, `:6163`); interpreters
`KayaSwiftUI.swift:6519`/`:6538`, `KayaCompose.kt:5902`/`:5951`.

A new `.steps` file is not free either: a guest per language (the
pickers' `pickers.steps` needed 9 guests, +663), a roster entry on each
of five lanes, and a `tools/guest/run_<scene>_<lang>.cmd` per language
on Windows, held by `tools/check-staging.py`.

**One scene-authoring constraint a role would not impose:** `labeled` is
targetable "like Row" (`harness.rs:80-82`) — only index 0, only in a
scene keeping exactly one — enforced by `check-steps.py`.

### 3.5 THE SHORTCUT QUESTION: is "a search kind is cheap because it is entry + a flag" true?

**NO. It is false by this repo's own measurements, and `textarea` is the
proof.**

`textarea` (14) IS "entry + a flag" by its own documentation —
`protocol.rs:906-908`: "The multi-line entry: the platform's real
multi-line editor, on the Entry's uncontrolled text contract."
`harness.rs:87-89`: "same set_text/read_text/focus verbs as the entry,
its own registry." It shares `Prop::Text` (`scene.rs:752-759`), `Clear`
(`:853`), `Focus`, **every verb**, and **the same occurrence**
(`TextChanged`). No new prop, no new verb, no new occurrence.

And it is duplicated anyway. Lines naming one but not the other, current
tree:

| file | Entry-only | Textarea-only | both |
|---|---|---|---|
| `crates/kaya/src/gtk.rs` | 20 | **24** | 4 |
| `crates/kaya/src/winui/mod.rs` | 30 | **42** | 2 |
| `crates/kaya/src/scene.rs` | 12 | 9 | 4 |
| `crates/kaya/src/harness.rs` | 6 | 6 | 2 |
| `crates/kaya/src/protocol.rs` | 5 | 3 | 0 |
| `swift/KayaSwiftUI.swift` | ~29 sites | ~25 sites | — |

The GTK create arm alone (`gtk.rs:8131-8202`) is **72 lines sharing
nothing with the entry arm** — a different native widget, its own signal
wiring, its own sizing contract, its own preedit handler, its own
registry, a two-field `NativeWidget::Textarea(ScrolledWindow, TextView)`.

**Its landing cost** — `0ec42236` (2026-07-22): **75 files, +1393/-127**,
in a tree with eight bindings, five backends and no JS. It needed its
own `textarea.steps` (20 lines), eight guests, five Windows launchers,
and +73 in `check-steps.sh`. **It would cost more today.**

`radio` vs `checkbox` is the wrong pairing — `radio` shares ZERO lines
with `checkbox` in any backend and does not even take `Prop::Checked`
(`scene.rs:760`, checkbox-only). The real "one contract, two
presentations" pair is `select`/`radio`, stated at `scene.rs:714-719`:

    /// The choice kinds: one selection among label-children options. Select
    /// is the dropdown presentation, Radio the inline group — SAME semantics,
    /// different chrome.
    fn is_choice(kind: WidgetKind) -> bool {
        matches!(kind, WidgetKind::Select | WidgetKind::Radio)
    }

Yet gtk 14/17/**0 shared**, winui 14/15/**0**, scene 11/6/2, harness
4/4/2, protocol 5/3/0. Its cost — `1486b7a3` (2026-07-22): 56 files,
+4202/-87; excluding a +3217 winmd regeneration, **+985/-87** — for a
kind reusing an existing kind's ENTIRE semantic contract with no new
verb and no new occurrence. **The sharing all happens ABOVE the backend
line**: `is_choice` saves about three lines in `scene.rs`, and four
backends plus two interpreters each still write a full arm.

### 3.6 THE HEADLINE COMPARISON

| | new KIND | new ROLE on an existing kind |
|---|---|---|
| spec hash moves | **yes** | **yes** |
| generated wire files touched | 9 + `kaya.h` | 9 + `kaya.h` |
| core Rust | ~13 lines / 5 files, **2 count literals bumped** (`protocol.rs:1095`, `capi.rs:668`), + shape validation (`labeled`: +204) | ~20 lines, 1 `matches!` arm, 1 value check |
| hand-maintained gate lists | **2** (`TARGET_KINDS`, `DEFAULT_KINDS`) | 0 (the census is derived) |
| **binding sugar** | **9 languages × 2 zones — +375 (`labeled`), +2069 (pickers breadth)** | **7-9 one-line chained setters — +25** |
| **backend arms** | **4 create + registry + target + render — +754 (`labeled`), +1464 (pickers), ~+400 for a "thin variant"** | **4 one-arm render tweaks — +42** |
| interpreter target tables | 2 rows + 2 registries + 2 apply arms + 2 constants | none |
| generated C# row façades | +8 per record type in the tree | none |
| **measured total** | **`labeled` ~+1550 / ~50 files; `textarea` (an explicit "entry + a flag") +1393 / 75 files in a SMALLER tree; `radio` (full contract reuse) +985** | **`plain` +248 / 38 files; ~+196 for the next one** |

**A role costs roughly 6× less**, and adds nothing to `TARGET_KINDS`,
`DEFAULT_KINDS`, `WidgetKind::ALL`, `carries_tag`, the capi count pin, or
the two interpreter target tables.

For `labeled`, sugar (375) + backends (754) + guests (88) + scenes (6) =
**~1220 of ~1550 attributable lines — 79% of a kind's cost is per-binding
sugar and per-backend arms, neither of which a role incurs.**

**And the honesty check the design doc must include:** the slider's
2026-09-04 work — **two props on an existing kind** — cost **87
file-touches, +3735/-150**, MORE than `labeled` cost as a whole new
kind. So "kind versus role" is not the axis that predicts effort. **What
predicts effort is how many NEW SURFACES the feature brings: a new prop,
a new occurrence, a new verb, a new scene.** A search field that needs a
placeholder prop, a submit occurrence and an Escape verb costs
approximately the same whether the thing carrying them is a kind or a
role — and under a role, two of the three (the occurrence, the verb)
cannot attach to it at all (§2.F).

### 3.7 A discrepancy in the two cost measurements, stated

The role's cost was measured twice with different scoping and the design
doc should quote a range rather than a point:

- **+172/-37 across 31 files** (recurring **+110/-33 over 29 files**
  once the one-time `check-sugar-surface.py` census construction is
  excluded) — the tighter reading, which attributes the
  `align.steps`/align-guest `row@plain` hunks to R5's row id rather than
  to the role.
- **+248/-36 across 38 files** — the looser reading, which counts those
  guests (+86 across nine `align.*` guests plus `tasks.rs`).

Both exclude docs. The difference is entirely whether the role's
demonstrating guests count as the role's cost. **They should**, if the
role is to have any observable at all (§5.C), so the honest figure to
quote for `search` is the higher one plus whatever a11y work §5.C says
is needed — which is unbounded until the five-platform probe is run.

---

## §4 — THE FILTERING PRECEDENT

### 4.1 The portfolio DIFFS a keyed collection by hand. That is the only precedent.

`guests/python/portfolio.py`. Collections: `accounts` `:496`,
`positions` `:505` (TEMPLATE zone, one instance per account card),
`recent` `:435`, `ledger` `:444` (`grow=1`, `on_sort=on_ledger_sort`
`:447-449`). Keys are strings minted from CSV position (`:290-297`)
because the scene addresses them `kind@id[key]`.

The filter handler (`:432-434` is the select):

    384	def on_filter(index):
    385	    view["account"] = FILTERS[index][1]
    386	    refresh()

    372	def refresh():
    373	    want = selected()
    374	    # The guest's own bookkeeping: items() is refused at record time.
    375	    sync(screen["ledger"], screen["in_ledger"], want)
    376	    sync(screen["recent"], screen["in_recent"],
    377	         [(key_of(i), row) for i, row in enumerate(txns)][-RECENT:])
    378	    screen["count"].set(f"{len(want)} of {len(txns)} transactions")
    …

**`sync()` (`:347-369`) is THE reconciler**, hand-written, and the only
one in the tree:

    347	def sync(collection, held, want):
    348	    """Make `collection` hold exactly `want`, in that order.
    349	
    350	    Removals and insertions first, and the reordering ONLY if what they
    351	    left is not already the wanted order: narrowing a filter preserves
    352	    relative order, and a table that re-sorted itself for nothing would
    353	    cost one move record per row for no observable change.
    354	    """
    355	    wanted = {k for k, _ in want}
    356	    surviving = [k for k in held if k in wanted]
    357	    for k in held:
    358	        if k not in wanted:
    359	            collection.remove(k)
    360	    have = set(held)
    361	    for k, row in want:
    362	        if k not in have:
    363	            collection.insert(k, cells(row))
    364	            surviving.append(k)
    365	    order = [k for k, _ in want]
    366	    if surviving != order:
    367	        for k in order:
    368	            collection.move_to_end(k)
    369	    held[:] = order

Three facts the design doc needs from it: the app keeps **its own
mirror** of what the collection holds (`screen["in_ledger"]`, seeded at
`:457`) because `items()` is refused at record time (`:374`); the
reorder is SKIPPED when survivors are already ordered (`:366`); the
sort indicator is re-declared separately (`on_ledger_sort` `:389-395`).
It runs in the binding's ambient handler transaction — guests may not
open their own (tools/check-ambient-tx.py) — and the initial fill is
deliberately the NEXT one (`portfolio.py:458-460`, "THE PUSH LANDS
BEFORE THE LEDGER FILLS").

**Measured cost at the portfolio's scale**, which is the scaling warning
and NOT the task manager's situation: 15,003 ledger rows
(docs/portfolio-plan.md:53, :175; tools/scenes/portfolio.steps:110), the
retirement filter narrowing to 4,698 (portfolio.steps:134) — one filter
change is ~10,305 removes in one batch. Packing 15,003 records is
6.03 ms in Python / 11.30 ms in JS (docs/deferred.md:10622-10624). A
15,003-row RE-SORT blew the 5s step deadline on mac and android under
matrix load (docs/deferred.md:11674-11677, :11608-11631) and the remedy
was raising every runner's deadline to 15s, not making the refill
cheaper. Android dies on 15,000 inserts in one transaction
(docs/deferred.md:9325-9327), and the standing rule is "guests chunk …
no wired leg inserts at the dying scale" (:9338-9339).

### 4.2 The task manager already diffs, one row at a time

`guests/rust/tasks.rs` (976 lines). Five app-lifetime task collections
(four section lists in the loop at `:380`, the Logbook at `:442`), plus
`projects_coll` `:446` and three screen-scoped ones (`:719`, `:842`,
`:882`). Caches `:197-200`: `tasks: BTreeMap<String,(List,TaskRow)>`,
`projects`, `order`.

Routing, `:220-234` `fn list_of`, and the move, `:250-275` `fn place`:

    256	        match current {
    257	            Some(cur) if cur == target => {   // same list: per-field patch
    258	                self.coll(cur).patch(tx, key.to_string()).title(...)…
    269	            Some(cur) => {                    // moved: remove then insert
    270	                tx.remove(&self.coll(cur), key.to_string());
    271	                tx.insert(&self.coll(target), key.to_string(), row.clone());
    272	            }
    273	            None => tx.insert(&self.coll(target), key.to_string(), row.clone()),
    274	        }

That IS `sync()`'s diff for one row. Every mutating message calls it
inside `ctx.apply` after `tx.undoable(...)` — `:550-553`, `:565-575`,
`:654-657`, `:686-691`, `:820-825`, `:952-956`, `:966-970`.

Quick-add, `:401-409`, and its handler split:

    402	tx.row(|tx| {
    403	    quick = tx.entry().a11y_id("quick").grow(1.0).id();
    404	    msgs.on_change(quick, Msg::Draft);
    405	    let add = tx.button("Add").a11y_id("add").id();
    406	    msgs.on_click(add, Msg::Add);
    407	})

`on_change` only BANKS the text (`:533` — `Msg::Draft(text) => app.draft
= text`); the work is on the button (`:534-559`), which mints `t{next}`,
runs one undoable `ctx.apply` calling `place`, then a SECOND `ctx.apply`
clearing and refocusing the entry (`:554-557`). Same pair on the project
screen (`:724-728`, `:753`, `:754-779`).

Seed (`:490-529`): three projects, **nine tasks**, fixed clock
2026-09-07 (`:132-141`) — Inbox 2, Today 2, Upcoming 2, Anytime 2,
Logbook 1 (tools/scenes/tasks.steps:10, 32, 54, 59, 43), keys `t1..t9`.

### 4.3 kaya has NO filtered view, and the reasons are structural

Every collection primitive, from `crates/kaya/src/spec.rs`:
`create_collection`(7, `:422`), `collection_insert`(8, `:436`),
`collection_update`(9, `:452`), `collection_remove`(10, `:469`),
`create_for`(11, `:480`), `create_when`(12, `:487`),
`template_end`(13, `:494`), `collection_move`(15, `:501`),
`collection_update_field`(14, `:516`), `variant_case`(16, `:535`).
**Insert, update, update_field, remove, move. No clear, no bulk op, no
predicate, no view.** (`collection_clear` occurs zero times in the
tree.) Rust sugar at `crates/kaya/src/app.rs:2478/2509/2519/2543/2590/
2620/2630/2640/2654/2757`, `Collection::patch` `:395`, `Tx::items`
`:1515` (a BUILD-TIME read-back only), `Collection::derive` `:460`
(yields a derived scalar SIGNAL, never a derived collection — tasks.rs
uses it for the "3 today" label, `:381-390`).

**`when` cannot hide a row.** `create_when` takes `signal_id: U64`
(spec.rs:488) and the core resolves it in the app's GLOBAL signal table,
asserting Bool, in both zones — `crates/kaya/src/scene.rs:3236-3243`
(live) and `:5004-5011` (template); sugar mirrors it at
`crates/kaya/src/app.rs:2849` and `:6514`. A `When` inside a `For` body
is legal but binds ONE app-level signal shared by every stamped copy:
there is no encoding by which it reads a row field, so toggling it
toggles ALL rows. And a `When` is destroy/rebuild, not hide —
DESIGN.md:199-202 and DESIGN.md:3662-3665, "hide-without-forgetting is a
future visible prop, not a second When". **That prop does not exist**:
the whole widget vocabulary is `crates/kaya/src/wire.rs:299-337`,
`PROP_TEXT`(1) … `PROP_WRAP`(29) — no `hidden`, no `visible`.

**Sorting is the app's too**, and its doc is the model for what a filter
would be: `sort_requested` kind 19, `crates/kaya/src/spec.rs:2442-2462`
— "A REQUEST, NOT A REPORT: nothing has changed on screen. The platform
never sorts the model — the guest reorders its collection by key
(collection_move: order is data) and re-declares set_columns with the
new indicator". Echoed at `spec.rs:1251-1257`, "THE INDICATOR IS THE
GUEST'S."

`filter` in `crates/kaya/src/` appears only as the file dialog's
advisory extension `filters` (protocol.rs:276-295; spec.rs:791, :1022,
:1680, :1850) and Rust's own `Iterator::filter`.

### 4.4 The "collection-pipelines gap" has NO ledger entry — a doc/code disagreement

docs/tasks-plan.md:75 cites "the collection-pipelines gap the parity
survey named", but **there is no `docs/deferred.md` entry for it**.
Grepping `collection.pipeline` across `docs/` returns exactly two hits:
docs/tasks-plan.md:75 and the survey itself. The survey's entry, item 8
of "what everyone else has that kaya does not"
(docs/probes/roadmap-framework-parity-2026-09-05.md:1765-1768):

> 8. **Collection pipelines as reusable objects.** Qt's
>    `QSortFilterProxyModel` and GTK's `GtkFilterListModel`/
>    `GtkSortListModel`/`GtkSelectionModel` make sorting, filtering and
>    selection composable model objects rather than per-view code.
>    kaya's tables emit `sort_requested` and leave the rest to the app.

(also :414 for Qt's model/view and :509 for GTK's `GListModel` family.)
The ledger's roadmap paragraph (docs/deferred.md:531-547) ranks the
survey's findings and puts the search field first in the table-stakes
tier but names NO pipeline item. **Per invariant 9's spirit, this gap
has a consumer (tasks-plan §1) and no ledger headline; the design doc
should either open one or say why it does not.**

### 4.5 What S1 would actually cost the guest, mechanically

Transposing `sync()` into `tasks.rs`:

1. **A mirror of the VISIBLE set per filtered collection** (one
   `Vec<String>`, the shape of `screen["in_ledger"]`). `app.tasks`
   (`:198`) mirrors the MODEL, not the visible set.
2. **Per keystroke, in one ambient transaction:** recompute matches in
   Rust; `tx.remove` every visible key that no longer matches;
   `tx.insert` every newly-matching key **carrying the full 8-field
   `TaskRow` again**; `tx.move_to_end` only if survivors are out of
   order (never fires for a stable-order narrowing search); rewrite the
   count label.
3. **Times five collections**, or per-section as docs/tasks-plan.md:89
   words it ("a search entry at the top of each list").
4. **`place()` has to compose with the predicate.** `place` (`:252`)
   inserts into `self.coll(target)` unconditionally; under a live filter
   a task edited into a non-matching state must not be inserted. That
   composition is exactly the work docs/tasks-plan.md:76-79 predicted a
   filtered view would remove.
5. **Undo is a hazard and needs a ruling.** Every existing mutation
   opens `tx.undoable(...)`; a search-driven remove/insert must NOT be
   undoable or ⌘Z un-types. The precedent for a non-undoable `place` run
   is `Msg::KeepDone` (`:820-825`, "re-placed, not undoable");
   `create_when` is already `UndoVerdict::Refused`
   (crates/kaya/src/scene.rs:453), but insert/remove are undoable by
   default.

**It must be a DIFF, not clear-and-refill** — forced, since there is no
clear op, and a clear would itself be N removes then M inserts. The
consequence that matters: an insert RE-SENDS the whole record and
RESTAMPS the template ("Stamps a copy from that variant's case",
spec.rs:447-448; "its stamped copy tears down", `:476`). There is no
cheap hide.

**At the task manager's scale this is trivially cheap.** Nine seeded
tasks, two per visible list — three orders of magnitude below the
portfolio's pain. Cost is O(visible-set churn), not O(model), and the
worst keystroke (the first character, or backspacing to empty) is ~2×
the list length. Fine to a few thousand rows; above that it wants
debouncing or virtualization. On the harness side every action verb now
waits for the app's answer in all three runners and the step deadline is
15s everywhere (docs/deferred.md:11664-11680), so an S1 scene driving a
search field is observable without the portfolio's flake class.

### 4.6 No guest does incremental text-driven filtering today

**Not one.** The closest is the editor's find bar, and it is not a
collection filter — `guests/go/editor/editor.go:442-447`:

    442	app.OnChangeNode(query, func(tx *kaya.Tx, _ []any, s string) {
    443		pattern = s
    444		refind(tx)
    445		// The one place the selection moves without a person asking.
    446		show(tx, 0)
    447	})

`refind` (`:201-232`) compiles the pattern, scans the document and calls
`tx.HighlightRanges(buffer, hits)` (`:230`) — text ranges on a textarea
plus a count signal, never collection membership. Its comment is the
useful precedent for keystroke-rate work (`:199-200`): "A declared set
dies on the next edit (docs/ranges-plan.md D2). HIGHLIGHTS ONLY: this
runs while somebody is typing."

The editor DOES use a collection for the bar itself — `findRows` with
the single key `"bar"` (`:148`, `:192`), inserted on Find… (`:401`),
removed on Dismiss (`:456`): a one-row collection as a structural
toggle, the `When` idiom spelled with a `For`. That is the tree's
precedent for membership-as-visibility, at N = 1.

Every other `on_change` in the tree banks a draft:
guests/rust/tasks.rs:533, guests/python/todos.py:26-27 (commit at
`:31-37`), guests/python/undo.py:66, and their JS/OCaml/Go twins. The
portfolio's filter is a `select`, discrete and low-frequency, and even
so it produced three matrix flakes at 15,003 rows.

**S1 would be the first text-driven collection filter in the tree, and
guests/python/portfolio.py:347-369 is the only reconciler to copy.**

---

## §5 — THE HARNESS: what a search scene could and could not assert

Three implementations that must agree: `crates/kaya/src/harness.rs`
(Rust runner; GTK + WinUI), `swift/KayaSwiftUI.swift` (mac AND iOS),
`android/.../KayaCompose.kt`. The grammar is `pub fn parse(…)`,
`harness.rs:1268-2016` — 88 tokens as `tools/check-verbs.py:970` extracts
them (three — `cancel`, `0`, `1` — are sub-arguments of
`alert_choose`/`file_save`). **No `focus`, `clear`, `key`, `press` or
`escape` among them.**

### 5.A The two drive verbs

**`set_text <target> "<text>"` — programmatic write.** Step variant
`harness.rs:168`; parse `:1344-1349`; Rust exec `:2898-2904`; Stage
method `:777`; GTK `gtk.rs:12628`; WinUI `winui/mod.rs:16258`; SwiftUI
`KayaSwiftUI.swift:6637-6656`; Compose `KayaCompose.kt:6116-6135`.
Targets: `entry` and `textarea` only. Lint: `tools/check-steps.py:1277-1300`
refuses `\n`/`\r` in `set_text entry#…`.

**`type "<text>"` — REAL keystrokes, no target.** Step `harness.rs:169-175`;
parse + validation `:1350-1354`, `check_typing` `:2181-2201`; Rust exec
`:2905-2919`; the six-point Stage contract `:778-792`; GTK
`gtk.rs:12396`; WinUI `winui/mod.rs:16176`; SwiftUI `:6657-6685`
(mac `kayaTypeAtFocus`, iOS through the XCUITest driver
`kayaTypeThroughHost`); Compose `:6106-6115`. Three constraints that
shape S1:

- **printable ASCII only, 0x20..0x7e** (`harness.rs:2187-2201`; lint
  `tools/check-steps.py:1363-1369`). No Escape, Return, Tab, arrows.
- **no target** — it goes to whatever holds focus, and
  `tools/check-steps.py:1309-1378` refuses any `type` in a scene that has
  not asserted `expect_focused` first.
- **it APPENDS**, caret at the end, nothing selected (contract point 3,
  `harness.rs:784-786`). No backspace, no replace-selection.

**`focus` and `clear` are kaya COMMANDS, not harness verbs** —
`spec.rs:2933-2936` (`("clear",1),("focus",2)`), wire `wire.rs:581-582`.
Only the GUEST can focus. A scene focuses by CLICKING (`click` is native
on any target by contract; `tools/scenes/clipboard.steps:99-104`,
`click entry#2` / `expect_focused entry#2`). **A stamped copy cannot be
focused at all** (`tools/scenes/editor.steps:126-128`).

**There is no key-press verb.** The one keyboard verb is
`shortcut "<spelling>"` (`harness.rs:1955-1970`, Step `:476`, exec
`:3901`) and it dispatches a MENU KEY-EQUIVALENT, not a raw key. Its
spellings go through `crates/kaya/src/scene.rs:1213`, and **`escape` is
explicitly REFUSED** at `scene.rs:1253-1257` ("the platforms' universal
dismiss key is never a shortcut"). `scene.rs:1160-1164` has a closed
named-key set (`enter, escape, delete, left, right, up, down`) and
`:1253-1257` then refuses `escape` outright.
`tools/scenes/editor.steps:175-177` records the workaround (a `done`
button). **No verb divergence between runners for text:**
`tools/check-verbs.py:967-979` extracts every parse arm and fails if the
literal is missing from either interpreter.

### 5.B The read verbs

- **`expect <target> "<text>"` on an entry reads THE FIELD'S CONTENT.**
  Parse `harness.rs:1355-1360`, exec `:3292-3321`; the kind picks the
  observation, `TargetKind::Entry | Textarea => stage.read_text(*t)`
  (`:3305`); anything outside `Entry|Textarea|Image|Label|Progress|
  Select|Radio` errors (`:3318-3320`). GTK `gtk.rs:12663`; WinUI
  `winui/mod.rs:16312`; SwiftUI `:6686-6724` (the node the TextField
  binding renders from); Compose `:6136-6176` —
  `it.textState.text.toString()`, explicitly the WIDGET and not the
  model mirror (`:6139-6143`). So `expect entry@search "milk"` works on
  all five lanes today.
- **`expect_focused <target>`** — parse `:1361`, exec `:3868-3873`,
  Stage `is_focused` `:800`; SwiftUI `:6752-6773`, Compose `:6177-6194`.
- **`expect_ax` / `expect_ax_hint`** — Step `:442`/`:446`; parse
  `:1882-1889`/`:1876-1881`; exec `:3941-3948`/`:3957-3964`; Stage
  `:1125`/`:1129`. **The closed role set is twelve words,
  `harness.rs:2273-2276`:** `button, label, field, checkbox, slider,
  image, progress, combobox, group, heading, datetime, unknown`. **No
  `search`, and no subrole half.** An entry reports `field` on every
  platform:

  | platform | emitter | entry → |
  |---|---|---|
  | macOS | `KayaSwiftUI.swift:5170-5199` | `kAXTextFieldRole, kAXTextAreaRole → "field"` (`:5178`) |
  | iOS | `KayaSwiftUI.swift:5483-5521` | `UITextView \|\| UITextField → "field"` (`:5508`) |
  | GTK | `gtk.rs:11540-11603` | `atspi::Role::Text → "field"` (`:11573`) |
  | WinUI | `winui/mod.rs:18752-18804` | `AutomationControlType::Edit → "field"` (`:18777-18778`) |
  | Compose | `KayaCompose.kt:4842-4883`, `:4963-4998` | `EditableText → "field"` (`:4982`), `android.widget.EditText → "field"` (`:4873`) |

  The label half is the authored a11y label, else the field's own
  content (iOS `:5639-5649`; WinUI `winui/mod.rs:15453-15470`; Compose
  `:4892-4898`). `expect_ax` REQUIRES an authored `a11y_id`
  (`KayaSwiftUI.swift:8644-8645`, `KayaCompose.kt:7734-7737`), and the
  observation text is byte-frozen by `tools/check-verbs.py:146-321`.
- **Row-count observables — there is no count verb, there are two
  readings.**
  - **`expect_window <container> <first> <total>`** — the realized
    band's first row and the collection's DECLARED TOTAL. Step
    `harness.rs:200`, parse `:1764-1784`, exec `:3382-3396`, Stage
    `:822-830`; GTK `gtk.rs:12905`, WinUI `winui/mod.rs:16582`. **This
    is the existing filtered-count precedent**:
    `tools/scenes/portfolio.steps:122` reads `0 15003`, then after
    `choose select#0 2` filters, `:143` reads `0 4698`.
  - **`expect_order <container> "a|b|c"`** — the container's LABEL
    CHILDREN ONLY, in child order, `|`-joined. Step `:180`, parse
    `:1362-1367`, exec `:3322-3339`, Stage `:804-806`; GTK
    `gtk.rs:13250`, WinUI `winui/mod.rs:16964`, SwiftUI `:6774-6797`
    (`.filter { $0.kind == kindLabel }`), Compose `:6195-6217`
    (`.filter { it.kind == KIND_LABEL }`). **R8 confirmed from the code**:
    a row carrying a checkbox and a button contributes nothing;
    `docs/tasks-plan.md:200-211` records the deeper reading as REFUSED
    2026-09-05, and `tools/scenes/feed.steps:1-3` leans on it.
  - **`expect_rows <column> "c1,c2|…"`** — per-row cell label texts.
    Step `:186-190`, parse `:1374-1379`, exec `:3354-3367`, Stage
    `:812-814`. Works on real Fors, not only tables
    (`tools/scenes/portfolio.steps:54, 57, 60, 121`).
- **Layout observables (existence only):** `expect_fills` (parse
  `:1408`, Stage `container_fills` `:931` / `widget_fills` `:937` — the
  MAIN axis); `expect_breadth` (parse `:1409`, Stage
  `widget_spans_breadth` `:944` — the CROSS axis;
  `tools/scenes/tasks.steps:16, 69`); `expect_hugs` (`:1410`);
  `expect_aligned` (parse `:1439-1444`, Stage `cross_mode` `:945-950`,
  classified from GEOMETRY into five modes); `expect_lines`
  (`:1411-1424`).
- **PLACEHOLDER — none, and the sweep was clean.** Zero hits in any
  `tools/scenes/*.steps`; zero in `crates/kaya/src/spec.rs`;
  `harness.rs:802` is the failed-image-decode placeholder; the five
  Swift hits (`:358, 3213, 5046, 13411, 16914`) and two Kotlin hits
  (`:441, 2343`) are failed-decode or an NSOpenPanel empty state; no
  `placeholder_text`/`PlaceholderText` in gtk.rs or winui/mod.rs.
- **CHECKBOX STATE — confirmed absent**, matching
  docs/tasks-plan.md:413-417: `expect` routes seven kinds only
  (`harness.rs:3297-3320`); `Checkbox` hits the `other =>` error arm in
  Rust, and in both interpreters a `checkbox…` spec falls through the
  prefix ladder to the LABEL registry (`KayaSwiftUI.swift:6716`,
  `KayaCompose.kt:6169`). `toggle` (`harness.rs:1275-1287`) drives with
  no read.

### 5.C ROLE IS INVISIBLE TO THE HARNESS — the finding that decides option (a)

- **There is no `expect_role` verb** — no such string in `harness.rs`,
  either interpreter, or any `.steps` file.
- **`expect_ax` cannot see a kaya role change except `heading`.**
  `tools/scenes/styling.steps:1-4`: "`heading` is the one role with a
  real-tree observable on every platform; `destructive` and `prominent`
  are DECLARED here so every backend's arm runs, but their look has no
  AX-visible marker." `:12-14`: caption's "LOOK has no universal AX
  observable (GTK alone has a caption role), so the walls are each
  backend arm's refusal of an unarmed role, and this text." `plain` is
  proved only through geometry, `tools/scenes/align.steps:17-20`.
- A `plain`-role button and a default button report IDENTICALLY in
  `expect_ax`.
- **Even on macOS, where an `NSSearchField` publishes `AXTextField` with
  subrole `AXSearchField`, the mac read passes THE ROLE ATTRIBUTE
  ALONE** — `swift/KayaSwiftUI.swift:5344` is
  `kayaAxRole(kayaAxCopy(hit, kAXRoleAttribute) as? String)`. The
  subrole is read only in the diagnostic `kayaAxWhy` (`:5470-5476`),
  never in the observation. Same shape on iOS, GTK, WinUI, Compose.

**Consequence: a `search` ROLE would have NO harness observable.** No
shared scene could prove it landed without (i) adding `search` to the
closed role set at `harness.rs:2273-2276` AND (ii) a subrole / trait /
class read in ALL FIVE emitters — and DESIGN.md:2622-2625's rule then
applies: "A role only one platform can produce is normalized DOWN to the
coarsest one they all publish". macOS has `AXSearchField`; whether
UIKit, AT-SPI, UIA and Compose can each publish something a shared scene
can byte-freeze is unproven and would need a five-platform probe before
the design is ratified.

This is the strongest evidence available on the role-vs-kind question,
because it is the invariant-3 test: **under option (a) the search
field's landing has no wall that a lane can fail.** Under option (b) it
has one for free — `expect_ax search@x "field/…"` still reads `field`,
but the KIND is addressable (`search@x` resolves or it does not), the
`check-sugar-surface` kind census fires in all nine bindings, and
`tools/check-stubs.py` holds "a scene's legs are wired IFF the backend
has the feature".

### 5.D Scenes that already drive a text field

| scene | line | step |
|---|---|---|
| `tools/scenes/entry.steps` | 4 | `set_text entry#0 "milk"`; `:6` label, `:7` `expect entry#0 ""`, `:8` `expect_focused entry#0` |
| `tools/scenes/todos.steps` | 8 | `set_text entry#0 "buy milk"` (quick-add); `:11-12` clear + focus; header `:4-6` says why set_text and not keystrokes |
| `tools/scenes/tasks.steps` | 22 | `set_text entry@quick "Buy oat milk"` → `:23` click → `:24` count label → `:26-27` clear + focus |
| `tools/scenes/tasks.steps` | 91 | `set_text entry@pquick "Pack chargers"` → `:92` click → `:93` `expect_order column@rows` |
| `tools/scenes/editor.steps` | 132, 135 | `set_text entry#0 "["` / `"[0-9]+"` — the find bar |
| `tools/scenes/editor.steps` | 167 | `set_text textarea#0 "scratch"` |
| `tools/scenes/editor.steps` | 95, 108 | `type "z"` / `type " 99"` (real keystrokes, focused textarea) |
| `tools/scenes/textarea.steps` | 2, 11 | multi-line `set_text` |
| `tools/scenes/identity.steps` | 22 | `set_text entry#0 "hi"` |
| `tools/scenes/typeface.steps` | 9 | `set_text entry#0 "hi"` |
| `tools/scenes/undo.steps` | 169 | `set_text entry#last "ha"` |
| `tools/scenes/clipboard.steps` | 71-107 | drives entries by CLICK + `Edit>Paste`; reads with `expect entry#N` and `expect_ax entry#1` |

**`tools/scenes/editor.steps:117-160` is already a de-facto search-field
scene**, and it is the closest template S1 has: summoned by menu
(`:123`); presence proved by a LIVE LABEL whose index never moves
(`:120-124`); the query set by `set_text entry#0` (`:132`, `:135`, with
`:126-131` explaining that nothing can focus a stamped copy); results
read as an app-computed label (`:133` `"bad pattern"`, `:140` `"1 of 4"`)
plus `expect_highlights` / `expect_selection` (`:141-142`); teardown
proved by `expect entry#last ""` (`:185`).

### 5.E What a search scene would need, assertion by assertion

| # | assertion | covered today? | how |
|---|---|---|---|
| 1 | type into the field, the filtered row count drops | **YES**, two ways | drive `set_text entry@search "…"` (`harness.rs:1344`) or `click entry@search` + `type "…"` (`:1274`, `:1350`); read `expect_window column@results 0 <total>` (`:1764`; precedent portfolio.steps:143), or `expect_order column@results "a\|b"` (`:1362`; precedent tasks.steps:88, 90, 93), or an app-computed label |
| 2 | the field's own text | **YES** | `expect entry@search "milk"` — `harness.rs:1355`, `read_text` `:3305`; precedent entry.steps:7 |
| 3a | the CLEAR button APPEARS | **NO direct verb** | no existence/absence observable exists. In-tree workarounds: the editor.steps live-label pattern (`editor.steps:120-124`), or `click button@clear` failing "no such target" if absent. **A scene cannot assert a button is GONE.** |
| 3b | clearing restores the full list | **YES** | `click button@clear`, then `expect entry@search ""` + `expect_window …` |
| 4 | **Escape clears the field** | **NO — no verb can send Escape** | `type` refuses non-printable ASCII (`harness.rs:2187-2201`; lint check-steps.py:1363-1369); `shortcut` is menu key-equivalent dispatch and the root explicitly refuses `escape` (`scene.rs:1253-1257`). **Needs a NEW DRIVE VERB in all three harnesses**, or a ruling that unreserves Escape plus a per-platform dispatch path |
| 5 | the field reports as a SEARCH field to a11y | **NO** | see §5.C |
| 6 | the field's PLACEHOLDER text | **NO — the concept does not exist** | needs a new wire prop through the generator to all 9 bindings + 4 backends, AND a new read verb in all three harnesses |

Two more facts for the scene author: a STAMPED (per-row) field can only
be driven by `set_text`, never focused or typed into
(`editor.steps:126-128`, `clipboard.steps:99-104`); and `type` APPENDS,
so an incremental cadence (`"m"` → `"mi"` → `"mil"`) is expressible but
backspacing is not. Both drive verbs already wait for the app's answer,
held by `tools/check-verbs.py:1622-1631` (`ACTION_VERBS` contains
`set_text` and `type`).

### 5.F The gates a new verb or observable would touch

- **`tools/check-verbs.py` — a new verb registers itself.** `:967-979`
  slices `harness[index("pub fn parse("):index("fn parse_target(")]`,
  regexes `"([a-z_]+)" =>` out of it, subtracts `{"on","off"}`, and
  fails `verb "<x>" missing from KayaSwiftUI.swift / KayaCompose.kt`. It
  is a BARE SUBSTRING TEST, so a stub arm satisfies it. You edit the
  gate when the verb is:
  - an ACTION — add it to `ACTION_VERBS` (`:1622-1631`), or `QUIET_ONLY`
    (`:1646`), or `REFUSALS` (`:1653-1657`); `answer_wait`
    (`:1711-1767`) then reads each runner's arm out of its own block and
    demands `await_quiet()` before and `await_answer(` after, floor
    `len(ACTION_VERBS) * 3`.
  - ax-family — `AX_OBS`/`AX_WANTED`/`AX_HARNESSES` (`:153-180`)
    byte-freeze the observation and failure sentences across the three
    harnesses, flattened per language.
  - a new TARGET KIND — `:1002-1046` censuses `parse_target_kind`
    against `kayaAnyTarget`/`kayaWidgetTarget`.
  - a new WIRE CONSTANT (a `ROLE_SEARCH`, a placeholder PROP) —
    `:1116-1139` sweeps `APPLY|KIND|PROP|COMMAND|VALUE|MENU_KIND|MPROP|
    ROLE|ALIGN` with their VALUES into both interpreters.
  - every `expect_*` arm in both interpreters must append to `observed`
    (`:1181-1217`) or call the depth stub (`:1201-1203`).
- **`tools/check-steps.py`** (3,692 lines) reads every
  `tools/scenes/*.steps` (`:64-65`). The text-entry clauses: the
  container-target lint (`:70-80` onward), `entry_newline_lint`
  (`:1277-1300`), `typing_lint` (`:1309-1378`, self-tested `:1383-1415`),
  and the WIRING CENSUS (`:1576-1620`, `:2037-2230`) — **a new
  `search.steps` must be wired into every lane roster in
  `tools/lib/lanes/*.py`** (or declared off in `DESKTOP_ONLY_SCENES` /
  `UNWIRED_SCENES`) and into `guests/c/Makefile`'s `SCENES` if a C guest
  exists.
- `tools/check-gates.py` holds CLAUDE.md's prose gate list,
  `tools/gates.py`'s list and validate-mac's delegation as ONE census, so
  any new gate file must land in all three.

---

## §6 — THE TOOLBAR QUESTION: a search field may not go in the chrome

**docs/chrome-plan.md:150-157, the "Refused, stated once" block, names
search fields FIRST among what a toolbar may not hold:**

> Free-form widgets in toolbars (search fields, pickers — not the 5-way
> intersection); per-item placement beyond catalog order; toolbar-only
> actions (everything promotable lives in the catalog first — the
> accessibility argument: every action stays reachable by menu and
> keyboard) …

That refusal is not a deferral with a trigger — it is in the same list
as "any `chrome`/`extended`/toolbar-style prop", refused because it is
"a no-op on at least one platform in every variant surveyed".

**What kaya's toolbar actually holds today: nothing but promoted menu
ACTIONS.** docs/chrome-plan.md:63-72 — C2's whole semantics is the
`primary` bit on a MENU ITEM (`MENU_PROPS` id 6,
crates/kaya/src/spec.rs:272), promoted in catalog preorder with a
platform-owned capacity k. There is no record, no prop and no
construction zone that puts a WIDGET into a toolbar. The known shape for
even reordering it is ledgered as unpaid: "the `add_section`-shaped
record `toolbar_append { window, item }` is the known shape …; it is not
paid for now" (docs/chrome-plan.md:84-88).

**Consequence for S1, and it is the load-bearing one.** The five-way
intersection is exactly what breaks a search field placed like every
other platform places it:

| platform | native search idiom | where the field lives | source |
|---|---|---|---|
| SwiftUI | `.searchable(text:placement:prompt:)`, `.searchScopes`, `@Environment(\.isSearching)` | a MODIFIER on the navigation container — SwiftUI puts the field in the nav bar / toolbar itself | docs/probes/roadmap-framework-parity-2026-09-05.md:43 |
| Compose | `SearchBar` / `DockedSearchBar` + `SearchBarDefaults` (M3) | a whole component with its own expanded/collapsed state and result surface | :140 |
| GTK | `GtkSearchEntry` + `GtkSearchBar` (`gtk_search_bar_set_key_capture_widget` for type-to-search) | `GtkSearchEntry` is an ordinary widget; `GtkSearchBar` is the revealer above the content | :434 |
| WinUI | `AutoSuggestBox` (`QueryIcon`, `QuerySubmitted`) | an ordinary control | :537 |

So on TWO of the four backends the platform's search control is not a
leaf widget you place in a column at all: SwiftUI's is a modifier that
hoists the field into the chrome, and Compose's is a stateful container.
GTK's and WinUI's ARE ordinary controls. Any design that says "the
search field is a widget the app puts at the top of the list column" is
choosing GTK's and WinUI's shape and asking SwiftUI and Compose to
imitate it with a plain TextField — which is available (`TextField` +
`.searchFieldStyle`-less; `OutlinedTextField` with a leading icon) but
is NOT the platform's own answer, and the chrome plan refused the other
direction already.

**This is the question the design pass must put to the maintainer, and
it is not the role-vs-kind question.** It is: does a kaya search field
sit IN THE CONTENT (a widget in the column, which all four can draw and
two would draw non-idiomatically), or is it a WINDOW/SECTION-level
declaration (which is SwiftUI's and Compose's own shape and would need
a new surface — the chrome plan's refused ground)?

### DESIGN.md's own words on roles and on text fields

- **Roles are SEMANTIC EMPHASIS, and that is the tier's definition.**
  DESIGN.md:2714-2716 — "**Semantic emphasis** — this button is
  destructive, this label is a heading. Per-widget, closed value set,
  never a raw value. ADMITTED as the `role` grammar the menus milestone
  already established." docs/styling-plan.md:162-183 (D4) is the
  vocabulary's own record: destructive, prominent (buttons), heading,
  caption (labels), plain (buttons, 2026-09-05). Every one of the five
  is an EMPHASIS fact — how loud this control is, or where it sits in a
  text hierarchy. None changes what control the backend instantiates,
  what occurrences it emits, or what keys it handles.
- **The vocabulary is kaya's to grow.** docs/styling-plan.md:210-218
  (D5, ratified 2026-08-12) — "a new role or slot is a spec change,
  ratified, landing in all backends with its gates — exactly how
  MENU_ROLES grows, with check-roles as the model." So adding a role is
  a legitimate, cheap, precedented move. The question is whether
  `search` IS a role by the tier's own definition.
- **`expect_ax`'s closed role set has `field` and no search value.**
  DESIGN.md:2600-2618 — the set is `button`, `label`, `field`,
  `checkbox`, `slider`, `image`, `progress`, `combobox`, `group`,
  `heading`, `datetime`, `unknown`. And the rule at DESIGN.md:2622-2625:
  "A role only one platform can produce is normalized DOWN to the
  coarsest one they all publish … because a name only one backend can
  say is a name no shared scene can assert." A `search` a11y value would
  have to clear that bar on all five lanes (macOS `AXSearchField` exists;
  GTK/AT-SPI, UIA and Compose are the doubtful ones) — otherwise the
  search field reports `field`, exactly as a plain entry does, and NO
  SHARED SCENE CAN TELL THEM APART.
- **The clipboard section already imagines a search field as a text
  target.** DESIGN.md:2508 and docs/clipboard-plan.md:145 — "a search
  field wants plain text; a rich editor takes images" — i.e. the
  `accepts` list is the existing mechanism for that distinction, and it
  is a PROP, not a kind.

### The symbol vocabulary cannot supply the magnifier

`SYMBOL_SEARCH = 7` exists (crates/kaya/src/wire.rs:525, named at
:550), but `symbol` is a SECTION prop (spec.rs:260, SECTION_PROPS id 3)
and a MENU prop (spec.rs:277, MENU_PROPS id 9). It is NOT in `PROPS`
(spec.rs:106-199) — no widget carries a symbol. So the magnifying glass
inside the field cannot be authored; it has to come from the native
control's own chrome, which is an argument for reaching the native
search control (GtkSearchEntry / AutoSuggestBox / `.searchable` /
`SearchBar`) rather than dressing a plain entry.

---

## §7 — THE LEDGER on search and filtering

Two entries and one roadmap paragraph. Grepped `docs/deferred.md` for
`search`, `filter`, `search field`, `search box` (most `search` hits are
the word "research").

### 7.1 UNSTRUCK, and S1 is its named trigger — "Text ranges are deferred on the ENTRY widget"

docs/deferred.md:901-923. Heading (:901): **"Text ranges are deferred on
the ENTRY widget"** — UNSTRUCK. Body: `highlight_ranges`,
`select_range` and `reveal_range` are TEXTAREA-only in the spec, with
three measured reasons (linux "can't honestly" — absolute byte offsets
that do not follow edits, nothing observable over AT-SPI; ios "can't
fully" — three gaps at the iOS floor; "no consumer" — the editor is a
textarea). Then, verbatim (:917-920):

> TRIGGER: an artifact whose decoration lives in a single-line field
> (validation marking, **find-as-you-type in a search box**). It arrives
> with per-platform verdicts already taken, so the work is the linux
> and iOS answers, not the design.
> KEY: entry ranges, entry-widget deferral, highlight_ranges,
> select_range, reveal_range, weak sibling

**Read this carefully before writing the design doc.** S1 as
docs/tasks-plan.md:445 scopes it — "a search entry filtering the open
list" — filters ROWS and decorates nothing, so it does NOT pull this
trigger. But if the design adds match highlighting inside the field, or
inside the row titles, this entry's linux and iOS work comes with it.
The design doc should say explicitly which side of that line S1 is on.

### 7.2 The roadmap paragraph — search field is rank 1

docs/deferred.md:521-547, the "Next milestones" section. :538-541:

> What they say: the table stakes come first — **search field**, toggle
> switch, badge, hyperlink label, splash slot, local notifications,
> settings persistence, and a compliance pass proving dynamic type, RTL
> and locale formatting on every lane …

Backed by docs/probes/roadmap-app-needs-2026-09-05.md:17-21:

> - **The single clearest gap is a search field** — must-have in 11 of
>   15 archetypes, needed by 30% of a 105-app real catalogue, in all
>   four vendor catalogues and all nine Electron apps checked, and cheap
>   to build.
> - **The top four gaps are all cheap**: search field, notifications,
>   tree view, background tasks.

and docs/probes/roadmap-framework-parity-2026-09-05.md:1683, in the
TABLE STAKES table (threshold: first-party in ≥8 of the 10 full
toolkits):

> | A6 | **search field as a distinct control** | 8 | `.searchable`,
> `SearchBar`, `SearchBox`, `GtkSearchEntry`, Qt 6.10's new
> `SearchField`. |

**The parity survey's own wording is "search field as a DISTINCT
CONTROL"** and its per-framework row (:1577) scores 15 toolkits: only
egui, iced and Slint have none — and those three are the "no search
control; a plain TextEdit is all there is" cases (:1270, :1370, :1470).
Avalonia is `P` because "No dedicated search control. `AutoCompleteBox`
is the nearest … but carries **no search chrome**" (:637). That is the
comparative evidence bearing directly on role-vs-kind: the frameworks
the survey marks `P`/`N` are exactly the ones that said "use a text
field", and the survey counted that as NOT having the feature.

### 7.3 No filtered-view entry under a "search" name

There is no ledger entry headed "filtered view" or "collection
pipelines" found by a `search` grep; docs/tasks-plan.md:76 names "the
collection-pipelines gap the parity survey named" — see §4 for what the
survey actually says and whether the ledger records it.

### 7.4 Adjacent, unstruck, and NOT to be confused with S1

- **Secure / password entry does not exist in kaya at all.** No
  `secure`, `password` or equivalent in crates/kaya/src/spec.rs, and no
  ledger entry. The parity survey scores it `Y` in all 15 toolkits
  (docs/probes/roadmap-framework-parity-2026-09-05.md:1575, table
  stakes at :1671 "Unanimous across all 15 columns"). This matters to
  the ruling: `secure` is the SAME SHAPE of question as `search` — an
  entry variant that changes the control's behaviour, not its emphasis
  — and whatever mechanism S1 chooses sets the precedent for it. A
  design that admits `search` as a role admits `secure` as a role, and
  `number` (A5) after it.

---

## §8 — SYNTHESIS: what the evidence says, and what only the maintainer can rule

Nothing below is a ruling. It is the survey's reading of its own
evidence, so the design pass can start from the argument rather than
rebuild it.

### 8.1 Four options, priced

| | what it is | spec hash | ~cost | can a lane prove it landed? |
|---|---|---|---|---|
| **(a)** `search` ROLE on `entry` | role 6, `scene.rs:842` widened to a THIRD kind | **moves** (§0) | **31-38 files, +172/-37 to +248/-36** (§2.E, §3.7) PLUS a brand-new ENTRY arm in each of four backends — every existing role arm is keyed on Button or Label | **NO** — §5.C. Role is invisible to `expect_ax` on all five platforms unless `search` joins the closed set AND all five emitters learn a subrole/trait/class read |
| **(b)** `search` KIND (wire 19) | a kind beside `entry` and `textarea` | **moves** (identical mechanism) | **~50 files, ~+1550** net of docs and bundling (`labeled`, §3.3); `textarea` — the tree's own "entry + a flag" — cost +1393/75 files in a SMALLER tree (§3.5) | **YES** — the target `search@x` resolves or does not; check-sugar-surface's kind census fires in all nine; check-stubs holds wired-IFF-implemented |
| **(c)** nothing new; the app composes it | an `entry` in a row + the guest's filter, the editor find bar's ratified shape (§1.0c) | none | ~0 framework, all guest | **YES**, trivially — but it proves an app, not a feature |
| **(d)** a SCREEN-level declaration | `.searchable`'s shape as an ENTRY_PROP or WINDOW_PROP (§1.0d) | moves | unpriced; new surface | **YES** — a declared surface has an observable the way `sections_presentation` does |

### 8.2 The three findings that actually decide it

1. **The spec-hash argument is dead.** Roles and kinds are hashed by the
   same loop (`spec.rs:329-335`); both force full regeneration and both
   move the hand-copied hashes. Whatever makes a role cheaper, it is not
   the hash. (§0 correction.) A role IS about 6× cheaper for other
   reasons — 79% of a kind's cost is per-binding sugar and per-backend
   arms (§3.6) — but see the next point before treating that as the
   argument.
1b. **Cost does not track the kind/role axis; it tracks NEW SURFACES.**
   The slider's 2026-09-04 work — **two props on an existing kind** —
   cost 87 file-touches and +3735/-150, MORE than the whole `labeled`
   kind (§3.6). A search field that brings a placeholder prop, a submit
   occurrence and an Escape verb costs about the same either way — and
   under a role, two of those three cannot attach to it at all.
2. **A role carries no payload, and a search field needs payload.** §2.F:
   one I64, no per-role props, no per-role occurrence, no table anywhere
   keyed on a role. Meanwhile §1.0's table lists six things a platform
   search control does and kaya cannot say: the magnifier, the native
   clear ⓧ, Escape, submit-on-Enter, the a11y value, the placeholder.
   Two of those (the submit occurrence, the placeholder prop) are
   ORTHOGONAL additions needed under EITHER option; the other four are
   what a native control gives for free and neither (a) nor (b) gives
   without reaching the native control. **And a prop is kind-scoped, so
   under (a) a `placeholder` prop would be legal on every entry whether
   or not it wears the role — the asymmetry a kind avoids.**
3. **Under (a) there is no wall a lane can fail.** §5.C: `expect_ax`
   reads the ROLE ATTRIBUTE only (`KayaSwiftUI.swift:5344`), the closed
   set (`harness.rs:2273-2276`) has no search value, and the tree's own
   record says so — `tools/scenes/styling.steps:1-4` and `:12-14`
   document that only `heading` has a real-tree observable. That is a
   direct collision with invariant 3 ("failures become guards, ON A PATH
   NOBODY CAN AVOID") and with `docs/styling-plan.md:196-204`'s own rule
   ("WHICH WALL HOLDS WHICH ROLE, stated up front because they differ …
   A weaker wall stated plainly beats a stronger-looking one that is
   vacuous").

### 8.3 The tension the design doc must resolve honestly

- **docs/tasks-plan.md:445 proposes (a)**, and R3 (`:144-148`) leaves it
  unruled. The parenthetical is the only in-tree support for the role
  reading.
- **docs/editor-plan.md:41-43 ratified (c) for the sibling feature**, in
  those words: "It is NOT a framework component — that boundary is the
  ratified one."
- **The evidence that ranked search #1 scored it as a DISTINCT CONTROL**
  (docs/probes/roadmap-framework-parity-2026-09-05.md:1683), and marked
  down every framework that answers "use a text field" (:637, :1270,
  :1370, :1470). By that scoring, (c) leaves kaya at `N`.
- **docs/chrome-plan.md:150-157 refused free-form toolbar widgets,
  naming search fields first** — and two of the four backends' native
  search idioms are chrome-placed or container-shaped (§6). So (b) as a
  leaf widget means SwiftUI and Compose imitate rather than adopt.

### 8.4 Questions for the maintainer, in the order they gate the work

1. **Content or chrome?** Does the search field sit where the app puts
   it (a widget in the column — all four can draw it; SwiftUI and
   Compose non-idiomatically), or does the app declare "this screen is
   searchable" and each platform place it (§1.0d)? Everything else
   follows from this, and it is not the role-vs-kind question.
2. **Does S1's search field submit?** If Return must do something, a new
   occurrence record (kind 27, `value_committed`'s shape,
   `spec.rs:2590-2604`) is needed regardless of (a) or (b).
3. **Does it need a placeholder?** If yes, that is a new `PROPS` slot
   applying to `entry` and `textarea` generally — orthogonal, and worth
   landing separately either way.
4. **Does it need Escape?** If yes, that is a new drive verb in all
   three harnesses plus a ruling that unreserves `escape`
   (`scene.rs:1253-1257` refuses it today).
5. **What wall holds it?** If (a), name the observable before building,
   because §5.C says there is none today. A five-platform a11y probe
   (does UIKit / AT-SPI / UIA / Compose publish anything a shared scene
   can byte-freeze for a search field?) should precede the ruling —
   DESIGN.md:2622-2625's normalize-down rule decides whether `search`
   can join the closed set at all.
6. **Does the filter get a framework answer or stay the app's?**
   §4.4 — "the collection-pipelines gap" is cited by
   docs/tasks-plan.md:75 with NO ledger entry behind it. At nine tasks
   the app-side diff is trivial (§4.5); the reason to care is that S1
   would be the tree's first text-driven collection filter and the
   pattern it sets is the one every later app copies.
7. **`secure` next?** §7.4 — whatever mechanism S1 chooses sets the
   precedent for `secure`/`password` (unanimous in all 15 surveyed
   toolkits, absent from kaya entirely) and `number` (A5). If `search`
   is a role, those are roles too, and the tier stops being "semantic
   emphasis" (DESIGN.md:2714-2716) and starts being "entry variants".
