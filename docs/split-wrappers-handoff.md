# Handoff: adaptive list-detail, the platform wrappers

Written 2026-07-27, at the end of a long session. Two of the three
wrapper swaps are done, matrix-verified, and COMMITTED; the tree is
clean. The Android half is not done, and is what this document is for.

> **CLOSED 2026-07-27, later the same day.** Everything under "What
> remains" is done and matrix-verified; see the What landed section at
> the bottom. This file is kept only for the two reference sections —
> the measured libadwaita facts and the traps — and ONE of those traps
> (the container linker OOM) is in docs/traps.md. The rest still want
> folding in there, which is where traps live; this file can go once
> they are.

## The one-line task

Finish Android: replace the Compose split arm's hand-built `Row` with
`ListDetailPaneScaffold`, and add phone-lane coverage so that swap is
verifiable. Do the coverage first.

## Decisions already ratified with Akhil. Do not relitigate these.

1. **Each platform decides where one pane becomes two.** kaya no longer
   draws that line. The app declares `list_detail` and the platform says
   how it presents, which is the same reason there is no prop for which
   way it presents. The `>= 600` that used to gate the split arm is gone
   from GTK and WinUI and must go from Compose too.

   The separate 600 that decides compact-vs-regular **for menus** is a
   different thing and stays where it is. Do not conflate them.

2. **Back on a two-pane window does not pop.** Back reveals what the top
   entry covers, and in the split arm it covers nothing, so popping
   would blank the detail pane. This is the platforms' own rule
   (Compose's `canNavigateBack` reports false with both panes visible;
   libadwaita and NavigationSplitView draw no back button in an
   uncollapsed content pane). It must be REAL behaviour, not the harness
   verb declining: the affordance has to be absent from the screen, and
   the verb has to refuse to drive an affordance that is not there.

3. **The wrapper owns layout and gesture; kaya's core owns the stack.**
   Never mirror a wrapper's navigation history into kaya's entry stack.
   Tell the wrapper the one fact it needs (is a detail open) and let it
   report intent back. Anything else and the guest's pop and the
   widget's pop become two different truths.

4. **Scenes may only sample widths where every platform agrees.** GNOME
   collapses below 400sp, Material wants 840dp, TwoPaneView's default is
   between them. `tools/check-steps.sh` rejects an `expect_split` taken
   inside 400..840, or one with no preceding `resize_window`.

## What is already committed (matrix green at 724 legs)

- **The back rule, all four backends.** GTK hides the back button in the
  split arm and `back()` refuses to click a hidden one. WinUI hides and
  restores the covered entry's back bar and `back()` checks its
  Visibility. SwiftUI guards the pop path on `kayaSplitArm`. Compose
  disables its `BackHandler`.
- **Windows uses `TwoPaneView`.** `MinWideModeWidth` keeps its default,
  so Windows picks the threshold. The split observation reads the
  control's `Mode` rather than a value the arm stamped. `ModeChanged`
  drives the back bar, because `Mode` settles during layout.
- **GTK uses `AdwNavigationSplitView`** in an `AdwBreakpointBin` with
  libadwaita's documented `max-width: 400sp`. `show-content` is the only
  stack fact the widget is told. `notify::show-content` going false is
  the user's back.
- **Compose** got the divergence fix (its split arm no longer requires a
  non-empty stack, which GTK and mac explicitly reject as a backend
  deciding semantics alone), the dependency, and the threshold change.
- Scene rewritten, band guard added, both negative-tested.

## What remained (both done — see What landed)

1. **Phone-lane split coverage. Do this first.** The `split` scene is
   desktop-only because it drives `resize_window`, which a phone cannot
   do. So today a wrong Compose arrangement compiles and passes every
   lane. A phone-safe sibling asserting the BARE `expect_split` (the
   verb takes `Option<String>`; the bare form asserts the asymmetric
   invariant instead of comparing a literal) runs everywhere by
   construction. `check-steps` requires every scene in `tools/scenes/`
   to have live legs in all five runners, so this means registering it
   in all five.

2. **The container swap.** `kayaSplitArm()` already asks Material's
   directive; the arm still renders a `Row`. Replace it with
   `ListDetailPaneScaffold`, supplying the scaffold state yourself.

## API facts already paid for (three compile rounds)

- `calculatePaneScaffoldDirective` is in
  `androidx.compose.material3.adaptive.layout`, NOT in the `adaptive`
  package it reads like it should be in.
- `currentWindowAdaptiveInfo` IS in `androidx.compose.material3.adaptive`.
- The whole surface needs
  `@OptIn(androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi::class)`.
- `ListDetailPaneScaffold` takes a caller-supplied scaffold state, so no
  navigator is needed. `adaptive-navigation` is deliberately NOT a
  dependency: its navigator owns a destination history, and kaya's core
  owns the stack (decision 3).
- Material's standard directive gives two panes only at **840dp**. That
  is now Android's threshold, up from kaya's old 600, and nothing tests
  it yet. That is what item 1 is for.

## Measured facts about libadwaita 1.7.6 (probed, not assumed)

- Flipping `collapsed`, which is what crossing the breakpoint does, does
  NOT change `show-content`. A resize is therefore not mistakable for a
  pop, and the detail page stays alive across the flip.
- `navigation.pop` sets `show-content` false and emits
  `notify::show-content`. That is the one signal meaning "the user went
  back", and it is distinguishable from a resize.
- An UNcollapsed view still accepts `navigation.pop`. GTK does not
  decline back on a wide window the way Compose does, which is why the
  rule is enforced by removing the affordance rather than trusting the
  widget.

## Traps hit this session. Each cost real time.

- **WinUI `back_button` is assigned once, at `mount_entry`.** Clearing
  it in the split arm destroys the affordance permanently, so the window
  collapses to one pane and then cannot pop at all. Hide it, never clear
  it. The Windows lane caught this; nothing else did.
- **The WinUI split arm renders the entry's WRAPPER**, whose row 0 is
  the back bar. That is why a back arrow was drawn above a detail pane
  that covers nothing.
- **The WinUI bindgen filter never pulls referenced types
  transitively.** `Visibility` and every `TwoPaneView*` enum had to be
  named explicitly in `tools/winui-bindgen/src/main.rs`, then
  regenerated by running that binary with cwd = its own directory (it
  writes `../../crates/kaya/src/winui/bindings.rs`).
- **The container linker OOM returned** when libadwaita added two
  binding rlibs per link. `docs/traps.md` had already prescribed the
  remedy: bound link parallelism, not the example count. `run-suites.sh`
  now passes `-j6`.
- **`unparent` must know about `AdwNavigationPage`.** A page owns its
  child through a property, so the generic `child.unparent()` detaches
  the widget while leaving the page pointing at it. The pane then lives
  in no tree the accessibility walk can reach, so `expect_ax` reports it
  absent while kaya's model still has it. Model assertions pass and only
  the real-tree one fails, which is a confusing signal if you have not
  seen it before.
- **Do not run `tools/gen-bindings.sh` without `--check`** unless you
  mean to regenerate. It rewrites binding sources with identical content
  but fresh mtimes; dune is content-based and will not relink, while the
  lane's freshness assert is mtime-based, so it can never clear. Deleting
  the stale `.exe` files makes it worse, because dune's database then
  believes targets exist that do not and `--force` does not repair it.
  The repair is `rm -rf _build-linux`.

## Verifying

```
nix develop -c cargo test -p kaya --features harness --locked
nix develop -c tools/check-compose.sh      # the Kotlin actually compiles
nix develop -c tools/check-detekt.sh       # dead Kotlin K2 cannot see
nix develop -c tools/check-steps.sh        # includes the band rule
nix develop -c tools/check-gtk.sh          # needs docker; check-targets cannot see gtk
nix develop -c tools/validate-all.sh       # all five lanes, ~170s warm
```

Last known good: 731 legs (mac 186, linux 344, windows 117, ios 40,
android 44). (It was 724 when this was written; the seven new legs are
listdetail on five lanes plus a second device on each phone lane, and
Windows is unchanged because a duplicate depth leg went away as one
arrived.)

## What landed (2026-07-27)

Both items above, in that order.

- **The `listdetail` scene**, the phone-safe sibling: no resize, no
  literal, the bare `expect_split` plus one `expect_ax` on the detail
  pane (the read that proves something rendered on every lane). It runs
  the SAME guest as `split` — split.rs grew `app_titled`, and
  listdetail.rs is a five-line example over it — because the claim both
  scenes make is that nothing in the guest changes with the form factor.
- **A device per size class on both phone lanes.** iOS already had the
  iPad; Android now has a 1280dp `medium_tablet` beside its 320dp pool.
  Those legs are the ONLY ones in any lane that reach the SwiftUI and
  Compose split arms — on a compact host the invariant is vacuous. Each
  appends the literal the shared file may not carry, and the Android one
  also appends the back rule.
- **The band rule now distinguishes the two forms.** A literal still
  needs a preceding `resize_window` outside 400..840; the bare form may
  run at a width the file never names, which is what makes it runnable
  on a host that cannot resize. A named width still has to clear the
  band either way. Four self-tests, both directions.
  The device side of that rule is enforced in run-emulator: each
  device's dp is asserted outside the band before any leg runs. The
  same tablet rotated to portrait is 800dp — measured, not assumed —
  and would fail the invariant for a reason that is not a bug.
- **`ListDetailPaneScaffold`**, entered on the app's declaration alone:
  the ARM is no longer gated on a width kaya picked, because the
  scaffold is what collapses. It is handed a `ThreePaneScaffoldValue`
  computed from Material's directive and ONE stack fact (is a detail
  open), which is how it is driven without adaptive-navigation.
  `expect_split` reads that value's per-role adapted values.
  `expandedCount` would say it in one word but is internal in 1.0.0, so
  the two roles are named.
- **A back-rule divergence the tablet leg immediately exposed.** The
  Compose `back` verb called `kayaUserBack()` unconditionally, so it
  popped on a two-pane window where the real gesture — a disabled
  BackHandler — would not. Decision 2 says the verb must refuse; it
  now does. Nothing had run Compose's split arm, so nothing had seen it.
- **A duplicate Windows leg, removed.** deploy-win ran each depth scene
  twice: once from a literal `run_suite` (which check-steps requires)
  and again from a loop that generated the same launcher on the fly.
  Two gates make that generator unreachable, so it is gone and the
  depth legs are named one by one.

Matrix after: 731 legs (mac 186, linux 344, windows 117, ios 40,
android 44). Both new gates negative-tested: forcing the directive to
one partition fails the tablet leg on all four of its claims, and
restoring the unconditional `back` fails it on the back claim alone
while nav-compose stays green.
