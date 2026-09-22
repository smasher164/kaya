# Sheets — the design pass (2026-09-21)

> A SHEET is the third presentation context DESIGN.md names and the one it
> left for later: a modal that hosts a real scene root. Alerts (title,
> message, buttons, no root) and file dialogs (a capability, no root) are
> the first two. This document says what a sheet is in kaya's own terms,
> how each platform draws one, what the protocol adds, and the rulings the
> maintainer takes before the first arm. Written against 85dc511b; the
> §2 unknowns are measured before any arm is written.

## §1 THE RULE, FROM ZERO

### 1.1 What a sheet is

A sheet is a screen the app shows OVER the one the user is on, to ask for
something before they continue: the "new task" form on a phone that slides
up from the bottom, the "save as" panel that drops from a Mac window's title
bar, the "edit profile" dialog in the middle of a desktop window. Three
things make it a sheet rather than a window or a pushed screen:

- it is MODAL: while it is up, the screen under it does not take input;
- it is PARENT-BOUND: it belongs to one window, moves with it, and goes
  when the window goes;
- it holds a WHOLE SCENE ROOT: any tree of kaya widgets, not the fixed
  title-message-buttons of an alert.

DESIGN.md's presentation-context section already sorts the three
lifecycle grammars, and a sheet is squarely in the modal one: its
lifecycle verb is DISMISS, and its cancel path is the uniform slot every
platform spells natively (Esc on the desktops, the back gesture on
Android, swipe-down or a Close button on iOS, a tap outside on the phones).

### 1.2 What is fixed by what already shipped

- **A sheet is a surface.** Windows and navigation entries share ONE
  guest-allocated id space, and `mount {window, root}` addresses any of
  them by that id. A sheet takes an id from the same allocator, is
  materialized hidden by its request, and is PRESENTED by mounting a root
  into it, the way an auxiliary window and a pushed entry are. Nothing new
  in the mount grammar; a third kind of target.
- **Handlers bind to the request.** The alert's `on_result` rides the
  show, the entry's `on_popped` rides the push (the creator rule,
  DESIGN.md). A sheet's dismissal handler rides the present.
- **A sheet's parent is any surface, and each surface holds one child
  sheet at a time.** A sheet is presented over a window or over another
  sheet, so modal-over-modal is a CHAIN (the form sheet's picker sheet),
  never a fan-out: a second sheet requested over the same parent while one
  is live is a guest error at the request, the alert's own rule, never a
  silent queue. Every platform can draw the chain (§2); on Windows that is
  what decides the lowering.
- **Dismissal is the close-veto class transplanted, exactly as back
  interception was** (DESIGN.md, Navigation): off by default, the platform
  dismisses natively with its full animation and the app hears about it
  after the fact; armed, the cancel affordance asks and nothing goes until
  the app answers with a dismiss. Same three-record shape, same prop table
  discipline, same one-shot registration that retires with the surface.
- **No capability gate.** Every host has a native sheet (§2), so, like
  entries and unlike auxiliary windows, a sheet needs no bit.

### 1.3 What is spelling, per language

The NAME of the request (`present_sheet` / `sheet(...)`), how the root is
handed in (a builder body in the closure languages, `mount_in` in Rust),
and how the two handlers are attached (chain, keyword, config attr, or
Rust's per-id registration). What is NOT spelling: that dismissal is one
occurrence with one cancel path, that a second sheet is refused at the
request, and that a dismissed sheet's tree is forgotten the way a popped
entry's is.

### 1.4 The whole thing, and what is deliberately not a sheet

There is no staged subset: the maintainer's rule is that with no users a
deferral buys nothing, so the surface is complete on day one.

- **Height, where the platform has the idiom.** The phones have two
  natural heights for a bottom sheet, half and tall: iOS's `medium` and
  `large` detents, Android's partially-expanded and expanded states. The
  `detent` prop (`medium` or `large`, unset = the platform's own default)
  says which the sheet opens at; the phones honor it and the harness reads
  it back from the platform. The desktops have no half-height idiom (a
  window sheet, an adaptive dialog and a content dialog all size to their
  content), so there the prop is stated as having nothing to say, the way
  the badge is on a desktop that draws none. That is the platform's
  semantics, not a kaya carve-out: the app writes `detent = medium` once
  and every phone opens the sheet half way.
- **Sheets over sheets** are in (1.2).
- **A sheet has no result value.** Its answer is whatever the app's own
  widgets wrote, and the app already holds that state; the alert keeps its
  choice, the sheet has none. This is a design fact, not a deferral.
- **The sheet's header is the app's root**, as it is on every platform
  that shows one natively: iOS puts Cancel and Done in the sheet's own
  navigation bar, the Mac's sheet has no chrome at all, Android's bottom
  sheet has a drag handle and nothing else. So the root mounted into a
  sheet gets the same chrome promotion a pushed entry's root gets (its
  toolbar items rise into the phone's bar), and `title` is the sheet's
  accessible name everywhere and its drawn header where the platform draws
  one (GNOME's and Windows' dialogs).

Not sheets, and not owed by this slice: the non-modal bottom panel (a
Maps-style drawer that leaves the screen under it live) and the
full-screen cover (a modal page, iOS's `fullScreenCover`). Both are
different presentation contexts with different lifecycle grammars and get
their own design pass if an app asks for them.

## §2 THE MECHANISM PER PLATFORM, AND THE UNKNOWNS

| Platform | The native sheet | Cancel path | Veto | Detent | A sheet over a sheet |
| --- | --- | --- | --- | --- | --- |
| macOS (SwiftUI) | `.sheet`, a window-attached NSWindow sheet, 400×300 minimum, its title on the NSWindow (the accessibility name; no title bar is drawn) | Esc, natively (measured 2026-09-21: 2 ms from the key to `onDismiss`) | `interactiveDismissDisabled`, and kaya reads the armed sheet's Esc through a local key monitor, since `onExitCommand` fires only with a focused responder inside (U2b) | nothing to say | yes, measured: Esc closes the child first, the parent on the next press |
| iOS (SwiftUI) | `.sheet` with `presentationDetents`; the harness's `dismiss_sheet` is the driver's REAL PAN from the sheet's top to the screen's bottom (an element swipe travels with the element's size, and a one-label sheet's fell short; measured 2026-09-21), after the presentation has settled | swipe-down, tap outside on medium | `interactiveDismissDisabled`, whose attempt SwiftUI never reports: the PRESENTED controller's presentation delegate takes a proxy while armed (`KayaSheetDismissProxy`, UIKit's `presentationControllerDidAttemptToDismiss`), forwarding the rest to SwiftUI's own — on the presented controller, not the NavigationStack's inner hosting controller (measured landing there first) | `.medium` / `.large`; the phone lanes drop `expect_sheet_detent none` and reopen the medium sheet at the end | yes |
| Android (Compose) | material3 `ModalBottomSheet` (BOM 2024.10.01 carries it), a dialog window of its own; kaya draws the title row, nests a child inside its parent's content, and the harness's back key goes to the sheet's OWN window's decor view (the activity's dispatcher finished the app; measured 2026-09-21) | back gesture, scrim tap, swipe | `shouldDismissOnBackPress` off with kaya's own back handler asking; the scrim and the swipe hide first, so the sheet is shown again and the app asked | `skipPartiallyExpanded` off over full-height content (Material offers the partial anchor only to content taller than half the screen) / on; unset wraps the content | yes, each is its own window |
| Linux (GTK4 + libadwaita) | `AdwDialog` (1.5) with a header bar over the root, hosted IN the parent since the windows became `AdwApplicationWindow`/`AdwWindow` (2026-09-21, the maintainer's call from the review captures); the harness's Esc goes to the parent's X window (gdk4-x11's xid) with focus moved into the dialog first, since the x11 lane has no window manager to activate anything (docs/traps.md, the AdwDialog toplevel, which records the fallback this replaced) | Esc, the close button | `can-close` off plus the `close-attempt` signal | nothing to say | measured (U3) |
| Windows (WinUI 3) | a modal `Popup` with a full-root smoke and Fluent's layer card (measured 2026-09-21: ContentDialog refuses a second one with `0x80000019`; a Popup takes a ContentDialog and a second Popup over it); it opens at the mount, deferred to the root's Loaded when the island is not up yet (the alert arm's rule; the python, js and C# legs presented within milliseconds of launch) | Esc through the popup's own key handler; the header's close button — one function, which the harness's `dismiss_sheet` drives directly since an OS-global key belongs to legs that run alone | the same function asks | nothing to say | yes, measured |

Measured facts already in hand: the linux image is Debian trixie with
libadwaita 1.7.6, so `AdwDialog` exists at run time; the crate is pinned at
the `v1_4` feature set, so the depth slice bumps it to `v1_5` (a feature
bump, not a version move, and check-pins reads the version). The Compose
BOM's material3 is 1.3, which has `ModalBottomSheetProperties`.

Unknowns, each measured before an arm depends on it:

- **U1, WinUI: a modal over a modal.** MEASURED 2026-09-21 on the lane's
  VM (tools/win/sheetprobe, the undo probe's route): a second
  `ContentDialog` is refused with `0x80000019`, "Only a single
  ContentDialog can be open at any time"; a `Popup` with a full-root smoke
  backdrop opens, a ContentDialog shows over it, and a second Popup opens
  over the first with both reading open. So the sheet is a modal Popup and
  ContentDialog stays the alert's. What the arm owes beyond the probe: the
  backdrop taking the pointer, Esc through the popup's key handler, focus
  moving in on open (docs/measurements/sheet-probes-2026-09-21.md).
- **U2, macOS: Esc.** MEASURED 2026-09-21, and the first draft of this
  table was wrong: SwiftUI's macOS sheet closes on Esc by itself (an
  in-process Esc through `NSApp.sendEvent`, the harness's own key route,
  reached `onDismiss` in 2 ms with no cancel button inside), a chain closes
  topmost-first, and `interactiveDismissDisabled` makes Esc inert while a
  programmatic dismiss still lands. Nothing to wire; the arm keeps the
  platform's own path (docs/measurements/sheet-probes-2026-09-21.md).
- **U3, GTK: a modal over an AdwDialog.** MEASURED 2026-09-21 in the
  container (libadwaita 1.7.6 under Xvfb, Esc through xdotool): a second
  AdwDialog presents over the first as a chain and Esc closes the topmost
  first; an AdwAlertDialog over a dialog answers `close` to Esc with the
  dialog under it kept; `can-close` off turns Esc into a `close-attempt`
  signal with the dialog kept, and `force_close` still ends it. The arm
  maps `intercept_dismiss` to `can-close` and `dismiss_sheet` to
  `force_close` (docs/measurements/sheet-probes-2026-09-21.md).
- **U4, Android: the keyboard.** A text field at the bottom of a
  ModalBottomSheet must rise with the IME. Measured on the emulator by the
  quick-add sheet itself (§6).

## §3 THE PROTOCOL

Three tx records and two occurrences, the navigation grammar's shape one
context over. Numbers are assigned at depth; the spec hash moves once.

- `present_sheet {parent, sheet}`: request a sheet over `parent`, any
  live surface — a window (0 = the primary), a pushed entry, a section or
  a live sheet; `sheet` is a guest-allocated surface id. Materializes
  hidden; mounting a root into it presents it. A second live sheet over
  the same parent is refused at the root, and so is a parent that is not
  a live surface (the task manager presents over its project screen, an
  entry, which the first draft of this check refused).
- `dismiss_sheet {sheet}`: dismiss and forget the sheet's tree, as
  `pop_entry` does; also the veto grammar's confirmation. Dismissing an
  unknown or already-gone sheet is a scene error.
- `set_sheet_prop {sheet, prop, source}`: `SHEET_PROPS`, its own typed
  table like `ENTRY_PROPS`: `title` (Str; the accessible name, and the
  header where the platform draws one), `intercept_dismiss` (Bool, default
  off) and `detent` (Str, `medium` or `large`, unset = the platform's
  default; honored by the phones, nothing to say on the desktops).
- `sheet_dismissed {sheet}` (occurrence): the user's cancel path closed it
  natively; post-fact, the core has already forgotten the tree. A
  programmatic `dismiss_sheet` does not echo here.
- `dismiss_requested {sheet}` (occurrence): with `intercept_dismiss` on,
  the cancel path asks and nothing goes until the app answers with
  `dismiss_sheet`.

The apply side mirrors: `present_sheet`, `dismiss_sheet`,
`set_sheet_prop`, with the backend's own dismissal reported through one new
emit beside `kaya_emit_entry_popped`. Undo refuses all three, as it refuses
the window and entry records.

## §4 THE HARNESS

- `expect_sheets <n>`: how many sheets are live, the chain's depth, read
  from the platform (the presented controllers, the dialogs' open state,
  the AdwDialogs present), never from the model.
- `expect_sheet_detent <medium|large|none>`: the height the platform
  reports for the live sheet, iOS's selected detent and Android's sheet
  state; the desktops answer `none`. The shared script asserts `none`,
  and the phone lanes cut that line and append `medium` through their
  per-scene cut-and-append tables (the adaptive scene's precedent in
  tools/lib/lanes/ios.py and android.py), settled at depth.
- `expect_sheet "<title>"`: the live sheet's title as the platform draws
  it; on a platform that draws no header the model's title, and the
  observation says which.
- `dismiss_sheet`: drive the platform's own cancel path on the topmost
  sheet (Esc, back, swipe, the close button), the way `alert_choose
  cancel` does for alerts.
- The existing widget verbs address the sheet's widgets by id as they do
  an entry's; `expect label#0` inside a sheet needs nothing new.

Byte-compared verdicts, one spelling in all three harnesses, held by
check-verbs like the alert observations.

## §5 THE BINDINGS

One family in nine, the entry's spellings one context over:

| Binding | Present | Mount | Dismiss | Handlers |
| --- | --- | --- | --- | --- |
| Rust | `tx.present_sheet(id).title("new task").detent(Detent::Medium).intercept_dismiss(true)`, `.over(parent)` for a chain | `tx.mount_in(id, root)` | `tx.dismiss_sheet(id)` | `msgs.on_sheet_dismissed(id, Msg)`, `msgs.on_dismiss_requested(id, Msg)` |
| Python | `sheet = kaya.sheet(title="new task", on_dismissed=..., on_dismiss_requested=...)` with a body | inside the body | `sheet.dismiss()` | keywords at the present |
| Go | `tx.PresentSheet().Title("new task").OnDismissed(fn).Show()` | `tx.MountIn(id, root)` | `tx.DismissSheet(id)` | chain |
| C# / Java / Swift | the entry's shape: a ref with `Title`, `InterceptDismiss`, `OnDismissed`, `OnDismissRequested`, `Show()` | `MountIn` | `DismissSheet` | chain |
| OCaml | `sheet ~title ~on_dismissed ()` answering the surface id, a body function | body | `dismiss_sheet id` | labelled |
| Haskell | `sheet [STitle "new task", SOnDismissed h]` in Build | body | `dismissSheet` | config attrs |
| JS | `sheet({ title, onDismissed }, body)` | body | `dismiss()` | object |

Each binding's dismissal handler registration is one-shot and retires with
the surface; `dismiss_requested` fires per request while armed. Every
spelling takes the parent (default: the primary window) and the three
props. The check-sugar-surface census gains a row per binding (present,
mount into, dismiss, both handlers, the three props, the parent), counted,
with the empty-reader refusal the other rows carry.

## §6 THE SCENE, AND THE APP

The sheet scene script (`sheet.steps` beside the others in tools/scenes), byte-identical in nine languages: open a sheet
from a button, read its title and a label inside it, write through a field
inside it and read the label under it change, dismiss through the cancel
path and read `sheet_dismissed`'s status, open it again with the veto
armed, cancel, read `dismiss_requested`'s status while the sheet is still
up, open a second sheet OVER it from a button inside it and read two live,
dismiss the child through the cancel path and read one, dismiss the parent
programmatically, read 0 live, a medium sheet's detent read back on the
phones, and a second present over a live parent refused (the scene's
loud-error shape, the alert scene's precedent). The task manager's S6 (docs/tasks-plan.md) then moves quick-add
into a sheet: on the phones a bottom sheet with the entry rising over the
keyboard (U4), on the desktops the window sheet or dialog. The tasks scene
gains the click that presents it (`button@new`, `button@pnew` on the
project screen) and reads the sheet up and gone around the same
`entry@quick` / `button@add` steps; Add inserts and dismisses. BUILT
2026-09-21.

## §7 RULINGS

Each states the recommendation; the maintainer confirms or redirects.

**R1 — A sheet's parent is any surface and each parent holds one child
sheet at a time.** RECOMMENDED: the chain is expressible on every platform
once Windows draws its sheet as a Popup, and a second sheet over the same
parent is refused at the request, the alert's rule.

**R2 — The dismiss veto ships.** RECOMMENDED yes: it is the entry's
`intercept_back` transplanted, every platform has the switch (§2), and the
first real sheet, a form, is exactly what wants "discard changes?" on the
way out.

**R3 — The `detent` prop ships, honored by the phones, with nothing to say
on the desktops.** RECOMMENDED: it is the one height idiom both phones
share, and the desktops genuinely have no half-height sheet, which is the
"cannot say it" category DESIGN.md's binding conventions already allow
when it is stated uniformly.

**R4 — WinUI draws the sheet as a modal Popup, ContentDialog staying the
alert's.** DECIDED BY MEASUREMENT (U1): ContentDialog cannot nest, the
Popup takes both an alert and a child sheet. One sentence in DESIGN.md says
so with the arm.

**R5 — The name is `sheet` in all nine**, the platforms' own word on the
Mac, iOS and GNOME, and Android's bottom sheet; WinUI has no word for it
and takes kaya's.

**R6 — A sheet is uniform on the desktops too.** It is a window sheet on
the Mac, an adaptive AdwDialog on GNOME, a dialog on Windows; not a
phone-only feature with a desktop carve-out. The app writes one thing.

## §8 THE ORDER OF WORK

1. ~~Probes U1 (Windows VM, the undo probe's route), U2 (mac), U3 (the linux
   container).~~ DONE 2026-09-21, docs/measurements/sheet-probes-2026-09-21.md;
   U4 (the keyboard under Android's sheet) is measured by the quick-add sheet
   itself in step 3.
2. ~~Depth on the mac: spec records and the hash, the core's surface table
   and refusals with unit tests, the SwiftUI arm with U2's Esc wiring, the
   three harness verbs, the Rust sugar, `sheet.steps` and the Rust guest,
   check-verbs and check-sugar-surface rows, depth stubs on the other
   three backends so check-stubs holds the fan-out open.~~ DONE 2026-09-21;
   the check-sugar-surface rows land with the eight bindings, as the
   sliders' did, so the gate stays green at depth and the ledger holds the
   fan-out open.
3. ~~Breadth: the eight bindings and guests, the three backend arms~~ DONE
   2026-09-21 (the sheet scene green in nine languages on the mac, sixteen
   linux legs, six windows legs, three android legs and the iOS leg), then
   S6 in the task manager on all five lanes.
4. ~~The matrix, then a review page with the sheet on every lane, each
   capture viewed before it is published.~~ DONE 2026-09-21: the breadth
   matrix in ab31ec09, S6's with its own commit, and the review page at
   https://claude.ai/artifact/549v7HfaFeTJv4rVuLt8RF (the shared scene and the
   quick-add on all five lanes, each capture viewed first). The first
   linux captures showed the AdwDialog beside the parent, a toplevel of
   its own over kaya's plain GtkWindow; the maintainer asked whether that
   is how a sheet looks, and the windows are AdwWindows now with the
   dialog hosted inside them (docs/traps.md, the AdwDialog toplevel; the
   page's linux captures were retaken).
