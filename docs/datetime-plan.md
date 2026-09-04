# Date and time pickers — the design pass (2026-09-03)

The maintainer picked date and time pickers as the milestone after drag
and drop on 2026-09-03, asking "I think GTK is the only one that doesn't
have a time picker?" This is the design pass that precedes any arm: what
the four toolkits give us at the versions kaya pins, the decisions the
design turns on (each a mechanism first and a recommendation second),
the probes to run before an arm is written, the bindings sweep, and the
build order with the files it touches. Rulings are marked. DESIGN.md
names date/time pickers in its first-admissions queue (lines 3378 and
3386); this plan is that admission.

## §0 — What the platforms settle

**The maintainer's question, answered: yes, and GTK's gap is wider than a
time picker.** At the versions the tree pins:

| Backend | Date, compact (a field that opens a calendar) | Date, inline calendar | Time |
|---|---|---|---|
| SwiftUI mac | `DatePicker` `.compact` / `.field` / `.stepperField` | `.graphical` | `DatePicker(displayedComponents: .hourAndMinute)`, same styles |
| SwiftUI iOS | `DatePicker` `.compact` (tap opens a calendar popover) | `.graphical`, `.wheel` | `.compact` (tap opens a wheel), `.wheel` |
| Compose, material3 1.3.2 (BOM 2024.10.01) | none as a control — the Material idiom is a text field with a calendar icon that opens `DatePickerDialog` | `DatePicker` | `TimePicker` (dial) and `TimeInput` (keyboard) inside a `Dialog`; a `TimePickerDialog` composable arrives only in 1.4.0 |
| WinUI 3 (WinUI 2.2.1 metadata, third_party/winappsdk) | `CalendarDatePicker` (flyout calendar, `MinDate`/`MaxDate`); `DatePicker` (three spinners, bounds by YEAR only) | `CalendarView` | `TimePicker` (flyout; `MinuteIncrement`, `ClockIdentifier`) |
| GTK 4.12 + libadwaita 1.4 | **nothing** — composed: `GtkMenuButton` + `GtkPopover` holding a `GtkCalendar` | `GtkCalendar` | **nothing** — composed: two `GtkSpinButton`s (hour, minute) and an AM/PM toggle where the locale wants one |

GTK 4's class index has exactly one date-shaped class, `GtkCalendar`, an
inline month view with no minimum or maximum date. libadwaita adds none
through 1.9 (its newest widgets are sidebars, shortcuts dialogs, toggle
groups, bottom sheets, spinners). GNOME's own apps compose their pickers
— Calendar's date chooser and Settings' hour/minute spinners are
hand-built from these primitives — so composition IS the platform idiom
there, not a fallback, and it is the roster's stated gap policy for the
widget backends (interpreter-internal drop-downs, 2026-07-20). The
Windows metadata in the tree carries all four controls and their event
args (`DatePicker`, `TimePicker`, `CalendarDatePicker`, `CalendarView`),
none yet admitted to the bindgen filter.

**Every platform's picker is a wall-clock value with no time zone.** A
date picker holds a civil calendar date (year, month, day); a time
picker holds a civil time of day (hour, minute). None of the four
controls carries a zone or an instant: SwiftUI's `DatePicker` binds a
`Date` but reads it through the environment's calendar and time zone;
Compose's `DatePickerState` stores the selected day as milliseconds at
UTC MIDNIGHT — the convention behind a whole genre of off-by-one-day
bugs when apps convert it through the local zone — and its
`TimePickerState` is a bare hour and minute; WinUI's `DatePicker` holds a
`DateTimeOffset` whose time part is ignored and its `TimePicker` a
`TimeSpan` since midnight; `GtkCalendar` is three integers. So the value
kaya carries must be the COMPONENTS, never an instant: an instant has to
pick a zone to become a date, and every platform would pick differently.

**Seconds are not a picker value.** Compose's `TimePicker` and WinUI's
`TimePicker` stop at minutes (WinUI adds a `MinuteIncrement`; Compose has
none). Only SwiftUI can show seconds. A uniform time is hours and minutes.

**Ranges exist for dates and not for times.** SwiftUI takes a
`ClosedRange<Date>` for either component; Compose's date picker takes a
`SelectableDates` predicate plus a `yearRange`; WinUI's
`CalendarDatePicker` takes `MinDate`/`MaxDate` (its `DatePicker` only
`MinYear`/`MaxYear`, which is why kaya's Windows arm is the calendar one);
`GtkCalendar` takes nothing and cannot disable a day — `mark_day` is a
highlight — so kaya's arm polices the range itself. No time picker but
SwiftUI's bounds its hours natively.

**The value is committed when the user finishes, not while they move.** A
wheel or a calendar emits intermediate values on every platform (a
SwiftUI binding updates as the wheel turns; Compose's state per tap;
WinUI's `SelectedDateChanged` on each spinner move before the flyout
closes). The occurrence kaya emits is the COMMITTED value, and each arm
names the platform event that means "done": SwiftUI the binding's change
once the popover closes (probe P1 settles the exact hook), Compose the
dialog's confirm button, WinUI `SelectedDateChanged`/`SelectedTimeChanged`
with the flyout closed, GTK `day-selected` and the spin buttons'
`value-changed`.

**Display is the platform's, in the user's locale.** Day-month order, 12-
or 24-hour clocks, the first day of the week, the calendar a user has
chosen (Japanese on iOS) are the toolkit's rendering of one civil value.
kaya never formats a date or time and never asserts a displayed string:
a shared scene reads the VALUE back through a label the guest writes
from its handler in fixed digits, and the wire carries proleptic
Gregorian components whatever calendar the user displays.

**Accessibility is a probe, not a plan line.** The four platforms publish
four roles for a date picker (AppKit's date-field role, UIKit's button-
shaped compact control, UIA's group-with-a-value, TalkBack's text field
for the Material idiom) and `expect_ax`'s role vocabulary is closed
(`button`, `label`, `field`, `checkbox`, `slider`, `image`, `progress`,
`combobox`, `group`, `heading`, `unknown`; DESIGN.md line 2509). Which
normalized role both kinds publish on every platform is measured first
(P4), and only then does the vocabulary grow — in the harness, the four
backends' role maps and DESIGN.md at once.

**What the slider's contract is, read out of the tree** (the pattern this
plan copies throughout): a kind row in the spec's `kind` enum; value
PROPS (`value`, `min`, `max`, all `PropKind::F64`) applied through the
generic `set_property` record with a typed setter GENERATED per binding
(`tx_set_value`, `tx_bind_value`, `tx_bind_value_element`); a
`value_changed` occurrence (kind 4, payload F64) carrying the new value
and the widget's identity tag; the control moves itself and the
occurrence tells the app, whose model changes only if the app writes back
or bound a signal (the echo doctrine: a property write never emits — GTK
and WinUI arm `apply_quiet` around every interactive SetProp); a
constructor in both construction zones of every binding (Python's and
JS's zones are ambient, so one function there); the harness verb
`set_value <target> <f64>` drives the CONTROL, and the value is read back
only through the guest's own label (`expect label#1 "volume: 75%"`) —
`Step::Expect` refuses slider and checkbox targets by name
(harness.rs:3032-3060).

## §1 — The decisions

### D1 — Two kinds, `date_picker` and `time_picker`; no combined kind (RULING)

Three toolkits ship dates and times as two controls (Compose, WinUI, and
GTK, which ships neither); SwiftUI's one control shows either component.
Two kinds cost nothing on SwiftUI (two `DatePicker`s with different
`displayedComponents`) and match the other three exactly. A
date-and-time is two widgets in a row, which is what every platform's
own settings screens do. A combined kind would need a third occurrence,
a third value shape and a third set of arms for a layout the app spells
itself.

**Recommendation:** two kinds.

### D2 — The value is civil components, typed at the floor: `PropKind::Date` and `PropKind::Time` (RULED 2026-09-04: (b))

Ruled 2026-09-04 after the maintainer asked what a "typed slot" is when the
wire is an integer either way: it is the ENUM PRECEDENT — `align` rides an
I64 and the spec's `PropKind::Enum("align")` label makes the generators emit
`set_align(Align.Center)`; `Date` and `Time` are two more labels in that
list, so the packing lives entirely in generated code and no guest ever
assembles the number. The packed integer is also a correct sort key and a
valid row key with no new core code, which three separate fields or a new
wire type would not be.

A date is three integers — year (proleptic Gregorian), month 1–12, day
1–31 — and a time is two — hour 0–23, minute 0–59. Not epoch days, not
milliseconds, not seconds since midnight (§0). The question is how the
spec SPELLS that, and there are two honest answers:

- **(a) Ride `PropKind::F64` like every numeric prop today** (`columns`
  is F64), packed decimal: `20260903.0`, `1430.0`. Zero generator work —
  the typed setter `tx_set_date(widget_id, f64)` appears in all nine
  wire files the moment the prop row exists. But the floor then types a
  date as a double, every binding's sugar packs and unpacks by hand, and
  a C guest that writes `20261303` finds out at apply time, not at
  compile time.
- **(b) Two new typed-slot kinds, `PropKind::Date` and `PropKind::Time`,
  riding the wire as the EXISTING `ValueType::I64` in decimal packing**
  (`20260903`, `1430`; readable in any dump, exact, ordered). No new
  wire value tag — enums already ride I64 — so no decode arm changes in
  the backends or interpreters. What is new is the GENERATOR: each of
  the nine emitters gains a per-kind setter shape whose signature is the
  components (`tx_set_date(widget_id, year, month, day)`,
  `kaya_tx_set_time(tx, id, hour, minute)`), and the occurrence decoder
  hands the components back. That is invariant 3's order — types over
  generation over runtime checks — applied at the one layer every guest
  meets. The core validates the packed value at apply either way (a 31st
  of February is refused by name, as an out-of-range slider value is).

Each binding then spells the value in its own idiom, one semantics:

| Binding | Date | Time |
|---|---|---|
| Rust | `kaya::Date { year, month, day }` (the core's own struct; no chrono/time dependency) | `kaya::Time { hour, minute }` |
| Python | `datetime.date` | `datetime.time` |
| Go | `kaya.Date{Year, Month, Day}` (no date-only type in Go; `time.Time` drags a zone in) | `kaya.Time{Hour, Minute}` |
| C# (.NET 10) | `DateOnly` | `TimeOnly` |
| Java | `java.time.LocalDate` | `java.time.LocalTime` |
| Swift | `DateComponents` with year/month/day (a `Date` needs a zone) | `DateComponents` with hour/minute |
| OCaml | a record `{year; month; day}` (no stdlib date) | `{hour; minute}` |
| Haskell | `Data.Time.Calendar.Day` (the `time` package is already a dependency of guests/haskell/kaya-guests.cabal) | `Data.Time.LocalTime.TimeOfDay`, seconds 0 |
| JS | `{ year, month, day }` (Node 24's V8 does not ship Temporal) | `{ hour, minute }` |
| C floor | the components on the generated setter; the packed i64 on the record | same |

**Recommendation:** (b). It is more generator work in nine emitters and
it is the floor doing what the floor is for.

### D3 — Minutes are the unit; no seconds (RULING)

Two of four platforms cannot show seconds. A `minute_step` prop (1, 5,
10, 15, 30; `PropKind::F64` like every count) rides where the platform
has it (WinUI `MinuteIncrement`; SwiftUI through the compact control's
`minuteInterval`, P1 settles the route; GTK's spin step) and is
emulated where it does not (Compose: the arm snaps the dial's value).
Seconds are refused at the spec: there is no slot for them.

**Recommendation:** minutes; `minute_step` optional, default 1.

### D4 — A date has a range; a time does not (RULING)

`min_date` and `max_date` (inclusive, `PropKind::Date`) on
`date_picker`, applied natively on SwiftUI (`in:`), Compose
(`SelectableDates` + `yearRange`) and WinUI (`CalendarDatePicker.MinDate/
MaxDate`), and POLICED on GTK, whose calendar cannot disable a day: the
arm answers `day-selected` outside the range by snapping the calendar
back to the previous value and emitting nothing. That snap is the one
place the GTK LOOK diverges; the semantics — no out-of-range value ever
reaches the app — is identical, and the scene proves it (D8). Time
pickers carry no range: three of four platforms have none, and "office
hours" is a validation the app spells in its handler.

**Recommendation:** date range yes, time range no.

**Amended 2026-09-04, on the first mac run:** the out-of-range answer is
CLAMP TO THE NEAREST BOUND, not snap back. NSDatePicker moves a
programmatic or stepped value onto its bound BEFORE its action fires
(the scene's `set_date 2027-01-01` read back `2026-12-31` and the app heard
it), UIDatePicker does the same, and a stepper user on any platform lands
on the bound the same way; so the uniform rule is the platform's own, and
GTK's arm clamps rather than snapping. "No out-of-range value ever reaches
the app" holds either way; the scene asserts the bound at both ends.

### D5 — A picker always holds a value; there is no empty state (RULING, a deliberate cut)

The app declares the initial value when it declares the picker, as a
slider declares its value. SwiftUI's `DatePicker` cannot represent "no
date" at all; `GtkCalendar` always has a selected day; WinUI's
`CalendarDatePicker` and Compose CAN show a placeholder. An empty state
in the uniform surface means composing a placeholder on two platforms
for a state a "due date" field genuinely wants but no in-tree app has
asked for. Cut with its trigger: the first example app that needs "no
date yet".

**Recommendation:** always-valued.

### D6 — One presentation: the compact field that opens the platform's picker (RULED 2026-09-04, a deliberate cut)

Ruled 2026-09-04 ("the compact one makes sense") over a side-by-side the
maintainer's own mac rendered: the one-line field against the always-on
month grid.

Every platform has a compact idiom (§0's first column), and the inline
calendar or clock is a second look with its own layout consequences (a
300pt calendar in a form). kaya ships the compact field: SwiftUI
`.compact` on both Apple platforms; Compose a Material text field with a
trailing calendar or clock icon whose tap opens `DatePickerDialog` or a
`Dialog` around `TimePicker` (material3 1.3.2 has no `TimePickerDialog`;
the BOM bump to 1.4.0 that adds one is a separate decision); WinUI
`CalendarDatePicker` and `TimePicker`; GTK the composed button-and-
popover for dates and the spin pair for times (the spin pair is inline
by nature and already compact). An `inline` prop is the cut, with its
trigger: an app whose screen IS the calendar rather than a form with a
date in it.

**Recommendation:** compact only.

### D7 — The occurrence carries the committed value; the value is owned the way the slider's is (RULING)

`date_changed` and `time_changed` carry the new components on the
widget's identity tag, so a stamped copy inside a For reports keys-first
like a checkbox's (protocol.rs's `carries_tag` is exhaustive with no
wildcard, and both kinds answer true). The control moves itself; the app
updates its model by writing back or by binding a signal — the slider's
contract, unchanged. Intermediate movements never reach the app (§0), and
a property write never emits (the echo doctrine; GTK and WinUI arm
`apply_quiet`). Handler spelling follows each binding's `on_value`:
`on_date`/`on_time` and their `_node` twins.

### D8 — The harness drives the platform control and reads it back (RULED 2026-09-04)

Ruled by the maintainer 2026-09-04: read-back stays, "for testing purposes" — the
scene asks the platform control in the two silent cases (a programmatic
write, GTK's snap-back) where occurrences and labels can only measure an
absence; "a lot better than relying on screenshots".

Three verbs. `set_date <target> 2026-09-03` and `set_time <target> 14:30`
change the value THROUGH the platform control (SwiftUI's binding,
Compose's state, WinUI's `SelectedDate`/`SelectedTime`, GTK's calendar
and spins) so the platform emits its own committed event and the app's
handler runs as it would for a user; the scene then reads the guest's
label, byte-identical everywhere because the guest formats in fixed
digits. And `expect_picker <target> "2026-09-03"` reads the CONTROL's
value back — a new no-default `Stage` observation in all four backends,
the `progress_state`/`selected_label` shape — which the label cannot
show: that the apply direction reached the platform (the initial value,
a programmatic `set_date`, and GTK's snap-back after an out-of-range
drive, which must leave the control on the old value with no
occurrence). Nothing asserts displayed text (§0).

### D9 — Locale and calendar are the platform's; kaya spells none of it (RULING)

No `format`, `is_24_hour`, `first_day_of_week` or calendar-identifier
props. The platform renders per the user's settings; the wire is
Gregorian components in every calendar system.

### D10 — The template zone: a stamped picker binds to a row field, and records learn `Date`/`Time` field types (RULED 2026-09-04: WIDE)

A For's row may carry a due date, and the picker in that row binds to it
the way a stamped checkbox binds to a bool field (`Tpl::checkbox(src:
TplSource<BoolKind>)`, app.rs:5795). Record fields carry the wire's five
value tags (Bool, I64, F64, Str, Blob), so a date field IS an I64 field
holding the packed value, and the question is who types it:

- **(narrow)** the picker's template constructor takes an I64 field and
  the binding's sugar exposes the date type only at the picker
  (`row.date_picker(Item::due())` with `due: i64` on the schema); a table
  column showing that date is a Str field the app formats.
- **(wide)** KayaGen learns `Date`/`Time` field types in all its emitters
  (the Rust derive, tools/gen-guests.py's four generated row surfaces,
  and the four hand-declared schemas), so `due: kaya::Date` is a record
  field with typed accessors everywhere and I64 only on the wire.

**Ruled 2026-09-04: WIDE.** The maintainer caught the inconsistency —
D2 types the prop slot at the generator and narrow would leave the same
value an integer in app code — and chose wide: the record machinery
learns the same label the prop slot did. The Rust derive, the four
generated row surfaces (Go, Java, C#, Swift through tools/gen-guests.py)
and the four hand-declared schemas (Python, JS, OCaml, Haskell) all map a
`Date`/`Time` field to the I64 tag on the wire and present the language's
date type (D2's table) everywhere the record is touched; sorting a table
by that column and keying a row by it work as integers, free. Nothing
below the generators moves.

### D11 — Deliberate cuts, each with its trigger

- Seconds (D3): a stopwatch-shaped app.
- A time range (D4): a validation that cannot live in the handler.
- An empty value (D5): the first "due date" field.
- Inline presentation (D6): a calendar-screen app.
- A date RANGE picker (two dates; Compose's `DateRangePicker`): a booking
  app — the other three have no such control and it is two pickers.
- Multiple date selection: no platform has it as a control.
- A combined date-time kind (D1): two widgets in a row.
- The material3 1.4.0 BOM bump for `TimePickerDialog`: its own decision;
  a `Dialog` around `TimePicker` is the 1.3 idiom.

## §2 — Probes before arms

- **P1 (SwiftUI, mac and iOS):** `.compact` `DatePicker` with `in:` —
  which `onChange` shape yields ONE committed value (popover close on
  the mac, sheet dismissal on iOS) rather than one per wheel tick; does
  `minuteInterval` reach the compact control through introspection of
  the hosted `NSDatePicker`/`UIDatePicker` or does D3's step need the
  AppKit/UIKit control hosted directly (dnd's D7 shape).
- **P2 (Compose 1.3.2):** `DatePickerDialog` and a `Dialog` around
  `TimePicker` compile under the pinned BOM with
  `@OptIn(ExperimentalMaterial3Api::class)` (KayaCompose already opts
  into the experimental adaptive and foundation APIs); reading
  `selectedDateMillis` back as `Instant.ofEpochMilli(x).atZone(UTC)`
  gives the tapped day on an emulator in a negative-offset zone.
- **P3 (WinUI):** `CalendarDatePicker`, `TimePicker` and their event args
  admitted to tools/winui-bindgen/src/main.rs's filter and
  crates/kaya/src/winui/bindings.rs regenerated; `SelectedDateChanged`
  fires once per commit; `MinuteIncrement` snaps; `SelectedDate` is an
  `IReference<DateTimeOffset>` and D5's always-valued rule means the arm
  never writes null.
- **P4 (all four):** the AX role each platform publishes for both kinds,
  through the existing `expect_ax` plumbing, so the vocabulary decision
  is measured (§0).
- **P5 (GTK):** the composed date field (`GtkMenuButton` + `GtkPopover` +
  `GtkCalendar`, the button's label from `g_date_time_format` in the
  locale), `day-selected` as the commit and the out-of-range snap; the
  spin pair with wrap, and the locale's 12/24 read from GSettings'
  `clock-format` with `nl_langinfo(T_FMT)` as the fallback.

**P1 and P4, measured on the mac 2026-09-04 (the depth slice):** the
commit is the control's own action — NSDatePicker sends it once per
stepper click, field edit or calendar-overlay pick, and a programmatic
`dateValue` write sends nothing, so the binding's change IS the commit
and there is no separate "done" event to wait for; AppKit has no minute
interval, so the step is snapped in the commit path (D3), while UIKit's
`minuteInterval` takes it natively. The AX role is `AXDateTimeArea` for
both kinds (subrole nil), normalized to the closed set's new `datetime`.
P2, P3 and P5 run with the breadth slice.

## §3 — The spec, in the record grammar

- `kind` enum: `("date_picker", 16)`, `("time_picker", 17)` after
  `canvas` (spec.rs:2540-2558).
- `PropKind`: two new variants `Date` and `Time` (spec.rs:76-90), each
  riding `ValueType::I64` (scene.rs `prop_value_type`); the generators'
  typed-setter emitters gain the component signatures (D2).
- PROPS (spec.rs:94-148): `("date", 19, PropKind::Date)`,
  `("time", 20, PropKind::Time)`, `("min_date", 21, PropKind::Date)`,
  `("max_date", 22, PropKind::Date)`, `("minute_step", 23,
  PropKind::F64)`; the `prop` enum mirror (spec.rs:2618-2640) and the
  lockstep test `props_match_prop_enum` follow.
- scene.rs `check_prop`: `date | min_date | max_date` legal on
  `DatePicker` only; `time | minute_step` on `TimePicker` only; both
  kinds admit `CommandKind::Focus` and the universal a11y props;
  `a11y_hint` joins the activation-kinds list for both.
- Occurrences: `("date_changed", 24, payload: Some(PropKind::Date))`,
  `("time_changed", 25, payload: Some(PropKind::Time))`, fields `id u64,
  path_len u32, reserved u32` (the `toggled` shape, spec.rs:2063-2076).
- Validation at apply: month 1–12, day valid for the month and year
  (leap rule), hour 0–23, minute 0–59, `min_date <= date <= max_date`
  when both are set, `minute_step` in {1,5,10,15,30} and the minute a
  multiple of it — each refused by name.
- The spec hash moves; both interpreters' pinned hash and their private
  constant blocks (swift/KayaSwiftUI.swift:110-141,
  KayaCompose.kt:1256-1296) follow, held by check-verbs.

## §4 — The bindings sweep

Nine DO, the C floor through the generated records alone (the floor has
no sugar by design). Per language: the constructor in the live zone, the
template-zone constructor taking a constant, a signal or a field (the
checkbox's three sources), the value type from D2's table, the handler
spelled as the binding spells `on_value`.

| Binding | Live | Template | Handler | Verdict |
|---|---|---|---|---|
| Rust | `tx.date_picker(Date)`, `tx.time_picker(Time)`, `_bound(SignalId)`; `min_date`/`max_date`/`minute_step` chained | `Tpl::date_picker(src: TplSource<DateKind>)` + `Row` forward | `msgs.on_date(w, Fn(Date) -> M)`, `on_date_node` | DO |
| Python | `date_picker(value, min=None, max=None, on_change=None)` with `datetime.date`; `time_picker(value, step=1, ...)` | same function (ambient zone), value a `Signal`/`FieldRef`/constant | `on_change=` | DO |
| Go | `tx.DatePicker(kaya.Date{...})`, `.Min/.Max`, `OnDate` | `tpl.DatePicker(v)`, `DatePickerBound[S]` | `OnDate`, `OnDateNode` | DO |
| C# | `DatePicker(DateOnly value, DateOnly? min, ...)` | `Node DatePicker(Field<DateOnly>)` — via the generated row surface the field is I64; the façade converts (D10 narrow) | `OnDate` | DO |
| Java | `datePicker(LocalDate, ...)` | `datePicker(long)`, `(Signal<Long>)`, `(Field<Long>)` + `Row` forwards | `onDate` | DO |
| Swift | `datePicker(DateComponents, ...)` | `KayaTpl.datePicker(...)` | `onDate` | DO |
| OCaml | `date_picker ?min ?max ~value ~on_change ()` with a record | `Tpl.date_picker` | labelled `~on_change` | DO |
| Haskell | `datePickerOn :: Day -> (Day -> IO ()) -> r` | `datePicker :: TplI64Source s => ...` | attr | DO |
| JS | `datePicker({ value, min, max, onChange })` | same function (ambient) | `onChange` | DO |
| C | `kaya_tx_create_widget(kind)` + the generated `kaya_tx_set_date(tx, id, y, m, d)` | same records at depth | the `date_changed` occurrence decoded by hand | records alone |

Nothing here needs a carve-out: every language can hold two small
integers and three, and every language already registers a value
handler.

## §5 — Build order

Depth then breadth, the sequencing doctrine: spec + core + Rust sugar +
SwiftUI mac + the scene green on the mac; then the three other backends
and eight bindings as parallel worktrees; then the matrix. The touch
list is the checkbox's path read out of the tree on 2026-09-03 (the
value-kind map), with the slider's file for every min/max shape.

1. **Spec and core.** spec.rs (§3); protocol.rs `WidgetKind` (:865),
   `carries_tag` (:936, exhaustive — both true), `Prop` (:1105),
   `Occurrence` (:505) with `DateChanged`/`TimeChanged` and their
   `Instance` twins; wire.rs constants and codec arms; ring.rs
   `REC_DATE_CHANGED`/`REC_TIME_CHANGED`; capi.rs constants,
   const-asserts, `kaya_emit_date_changed`/`kaya_emit_time_changed`,
   the vtable slots (swiftui_host.rs:118, android.rs:334 JNI names);
   scene.rs `check_prop`/`prop_value_type`/validation; app.rs `DateKind`/
   `TimeKind` `ValueKind`s, the constructors in `Tx`, `Tpl` and `Row`,
   `on_date`/`on_time` and node twins in `Messages`; the pin tests as
   the checklist (HACKING.md's regeneration workflow).
2. **Generators.** tools/kaya-bindgen: the two `PropKind` arms in each of
   the nine emitters (typed setters with component signatures, the three
   forms `set`/`bind`/`bind_element`; occurrence payload decode to
   components). tools/gen-header.py, tools/gen-bindings.py; the C header's
   new constants and `kaya_emit_*` declarations. AND THE RECORD MACHINERY
   (D10 wide): the Rust `Kaya` derive, the four generated row surfaces
   under tools/gen-guests.py, and the hand-declared schema spellings in
   Python, JS, OCaml and Haskell each learn `Date`/`Time` field types
   mapped to the I64 tag, with the language's date type on the accessor,
   the setter, the patch and the sort key.
3. **The harness.** harness.rs: `TargetKind::DatePicker/TimePicker`,
   `Step::SetDate/SetTime/ExpectPicker`, parse arms, three no-default
   `Stage` methods (`set_date`, `set_time`, `picker_value`), MockStage,
   grammar tests; `Step::Expect` keeps refusing pickers (the label is the
   reaction, `expect_picker` the control). check-harness-ceiling holds
   the three verbs to the ceiling shape in all three harnesses.
4. **SwiftUI (mac first, iOS in the same file).** Constants (:110-141),
   node model fields (date, time, min, max, step), scene-collect and
   apply arms (:4040, :4512), render arms (`DatePicker` `.compact`,
   displayedComponents per kind, `in:` from min/max; the commit hook P1
   settles), `KayaHost.emitDateChanged/emitTimeChanged` (:3706 shape),
   step arms (:6237 shape) and the target table (:5997), AX role maps
   per P4. The scene green on the mac closes the depth phase.
5. **The scene and gates, red by design across the fan-out.**
   a new scene `pickers.steps` beside the others under tools/scenes/:
   initial values read back (`expect_picker`),
   `set_date`/`set_time` driving the handler (labels in fixed digits),
   an out-of-range `set_date` leaving control and label unchanged, a
   `minute_step` snap, a programmatic write that must NOT emit (the
   gallery's echo negative), a stamped picker in a For reporting its
   keys, and `expect_ax` for both kinds. Gates: check-steps.py:74-80
   `TARGET_KINDS` and tpl-surfaces.py:24-27 `DEFAULT_KINDS` are the two
   HAND-MAINTAINED kind lists in the tree (every other census derives
   its kinds from the generated wire.py) — both grow AND gain a clause
   holding them equal to the generated list, so the next kind cannot
   skip them silently; check-sugar-surface's `check_kind` rows (:98-119)
   and tpl-surfaces' readers see the kinds automatically; check-verbs
   sweeps the new verbs, target kinds and constants; check-universal-
   props demands a Compose render arm; scene-features makes `pickers` a
   feature every backend supports or `depth_stub`s.
6. **Breadth, six worktrees by device pool.** Compose (constants
   :1256-1296, registries, scene-collect :1698, apply :1722, render arms
   in the Material idiom of D6 under `@OptIn(ExperimentalMaterial3Api)`,
   emit through `KayaPresent`, step arms :5502, target table :4494, AX
   :4534/:4551); GTK (variants :1145, registries :2343, create arms
   :7131 with the composed field and spin pair, SetProp arms :8587,
   Stage :10858, AX :10269, the range snap; check-gtk after); WinUI
   (bindgen rows at tools/winui-bindgen/src/main.rs:167 —
   `CalendarDatePicker`, `CalendarDatePickerDateChangedEventArgs`,
   `TimePicker`, `TimePickerSelectedValueChangedEventArgs`,
   `Windows.Foundation.DateTimeOffset` — and the 40k-line
   winui/bindings.rs regenerated; variants :101, create :10697, SetProp
   :11783, Stage :15164, AX :17709); iOS in the SwiftUI file; the eight
   bindings' sugar per §4 (Python `__init__.py:2942` shape, Go
   `app.go:1366`/`:3679`, C# `KayaApp.cs:1905`/`:3316`, Java
   `KayaApp.java:3688`/`:5137`, Swift `KayaApp.swift:2863`/`:4062`,
   OCaml `kaya_app.ml:921`/`:2884`, Haskell `KayaApp.hs:2313`/`:2824`, JS
   `index.ts:2791`); ten guests named `pickers` in each language's
   directory under guests/ (the C one on guests/c/Makefile and mac.py's
   `C_SCENES`); lane tables
   (tools/lib/lanes/mac.py:24,76; win.py:23,71; ios.py:25,39,59;
   android.py:44,62,78; tools/linux/run-suites.sh:33,601).
7. **Records.** DESIGN.md:3378/3386 struck (the admission made), the
   kinds and roles sections extended, the AX vocabulary line if P4
   grows it; the ledger entry with `KEY: date_picker, time_picker,
   PropKind::Date, PropKind::Time, date_changed, time_changed,
   set_date, set_time, expect_picker, min_date, minute_step, KayaGen
   date field`; docs/traps.md for whatever the probes find; the matrix
   ALL PASS before the feature is called landed.
