# Handoff: adaptive list-detail, the platform wrappers

Written 2026-07-27, at the end of a long session. Two of the three
wrapper swaps are done, matrix-verified, and COMMITTED; the tree is
clean. The Android half is not done, and is what this document is for.

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

## What remains

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

Last known good: 724 legs (mac 185, linux 342, windows 117, ios 38,
android 42), plus the android lane green again after the threshold
change.

## Prompt for a fresh session

> Read docs/split-wrappers-handoff.md first; it has the ratified
> decisions and the traps. What it describes as done is already
> committed and the tree is clean, so you are starting fresh work rather
> than picking up a half-applied change.
>
> Finish the Android half of the adaptive list-detail milestone, in two
> steps and in this order.
>
> First, add phone-lane coverage for list-detail. The existing
> `split` scene is desktop-only because it drives `resize_window`, so
> the Compose arm is currently untested on any lane. Add a phone-safe
> sibling scene that asserts the bare `expect_split` invariant (no
> literal, no resize) and register it in all five runners, since
> check-steps requires every scene in tools/scenes/ to have live legs
> everywhere. Get the matrix green.
>
> Then replace the Compose split arm's hand-built `Row` with
> `ListDetailPaneScaffold`, supplying the scaffold state yourself rather
> than using the navigator, and make the split observation read the
> scaffold's own arrangement instead of a value the arm stamped about
> itself. The API details you will need are in the handoff; they cost
> three compile rounds to find.
>
> Do not commit or push without my explicit approval of the message.
