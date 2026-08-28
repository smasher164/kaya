# Adaptive / responsive content layout across UI frameworks

Research date: 2026-08-28. Sources: framework docs, API references, design
guidelines, verified live (not from memory).

Question this serves: what PRIMITIVE does a declarative native-widget toolkit
add so that an app's CONTENT layout (a chart column beside data-table columns)
reorganizes between a desktop window and a phone — given rows, columns, grow
factors, cross-axis alignment as the existing vocabulary, and byte-frozen
cross-platform expected strings in the tests.

STATUS: complete. Every API name, version and quotation below was verified
against a live primary source in this session (Apple's documentation JSON
API, developer.android.com, docs.flutter.dev, the libadwaita reference,
learn.microsoft.com, MDN). Nothing here is from memory.

**Headline:** every vendor now says the same thing — key on the WINDOW, never
the device — and the two frameworks that made a stack's direction a *type*
rather than a *value* both had to build machinery to undo that, one of them
(Compose's `FlexBox`) as recently as August 2026.

---

## 1. SwiftUI

Verified against Apple's documentation JSON API (the HTML pages are
JS-rendered and fetch empty; `developer.apple.com/tutorials/data/documentation/...json`
returns the real content).

### 1a. Size classes — the platform-supplied discrete signal

`EnvironmentValues.horizontalSizeClass`, iOS 13 / macOS 10.15+:

```swift
@backDeployed(before: macOS 14.0, tvOS 17.0, watchOS 10.0)
var horizontalSizeClass: UserInterfaceSizeClass? { get set }
```

Two cases only: `.compact`, `.regular`. Read with
`@Environment(\.horizontalSizeClass) private var horizontalSizeClass`.

The critical detail for a cross-platform toolkit: **the size class is not a
width.** Apple's own doc states the platform behaviors flatly — on watchOS it
is always `.compact`; **on macOS and tvOS it is always `.regular`**, no matter
how narrow the window. It is set from "current device type, device
orientation, and Slide Over / Split View appearance on iPad." So an app that
keys its content layout on `horizontalSizeClass` gets *no* adaptation from
resizing a Mac window. That is the single most important fact in this whole
survey for a toolkit whose tests run the same scene on desktop and phone:
Apple's discrete signal is a **device-and-mode** classification, not a
measurement of the container.

Since macOS 14 / tvOS 17 / watchOS 10 the value is *writable* (`get set`,
back-deployed), so a parent can impose a size class on a subtree — which is
how you'd fake a compact region inside a wide window. That writability is
itself an admission that the platform-supplied value is too coarse.

### 1b. AnyLayout — the declared discrete switch

`@frozen struct AnyLayout`, iOS 16 / macOS 13+. Conforms to `Animatable`,
`Layout`, `Sendable`. Apple's overview: "enables dynamically changing the type
of a layout container **without destroying the state of the subviews**."

Apple's own example keys on Dynamic Type, not size class:

```swift
struct DynamicLayoutExample: View {
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    var body: some View {
        let layout = dynamicTypeSize <= .medium ?
            AnyLayout(HStackLayout()) : AnyLayout(VStackLayout())
        layout {
            Text("First label")
            Text("Second label")
        }
    }
}
```

The `Layout`-conforming stack values are `HStackLayout`, `VStackLayout`,
`ZStackLayout`, `GridLayout` — value types that mirror the view containers
`HStack`/`VStack`/`ZStack`/`Grid`. The community pattern for the exact
question kaya faces (HStack on desktop, VStack on phone) is a one-line
ternary over these:

```swift
let layout = horizontalSizeClass == .regular
    ? AnyLayout(HStackLayout()) : AnyLayout(VStackLayout())
```

**Why the type erasure matters, and it's a lesson not an incidental:** writing
`if compact { VStack { … } } else { HStack { … } }` in SwiftUI creates two
*different* branches of the view tree, so the children lose structural
identity — state is destroyed and the transition can't animate. `AnyLayout`
exists precisely so the *children are one set of nodes* and only the
arrangement algorithm swaps. Any toolkit adding this primitive inherits the
same design pressure: the switch must be over the *container's arrangement*,
not over two alternative subtrees, or it silently resets child state.

DECLARED vs COMPUTED: the *switch point* is entirely app-declared (the
programmer writes the ternary and picks the predicate); the *input* is
platform-supplied when it's `horizontalSizeClass`, app-supplied when it's
Dynamic Type or a `GeometryReader` width. `AnyLayout` itself is pure
mechanism with no policy.

### 1c. ViewThatFits — fit-based selection, no breakpoint at all

`@frozen nonisolated struct ViewThatFits<Content> where Content: View`,
iOS 16 / macOS 13+. Initializer:

```swift
init(in axes: Axis.Set, content: () -> Content)
```

Apple's rule: it "evaluates its child views in the order provided to the
initializer and selects the first child whose ideal size on the constrained
axes fits within the proposed size. Views should be provided in order of
preference (usually largest to smallest). By default, `ViewThatFits`
constrains in both horizontal and vertical axes."

Apple's example degrades a progress readout three ways:

```swift
ViewThatFits(in: .horizontal) {
    HStack {
        Text("\(uploadProgress.formatted(.percent))")
        ProgressView(value: uploadProgress).frame(width: 100)
    }
    ProgressView(value: uploadProgress).frame(width: 100)
    Text("\(uploadProgress.formatted(.percent))")
}
```

This is a genuinely distinct class from breakpoints: **there is no number in
the app's source.** The app declares an ordered menu of alternatives and the
framework measures ideal sizes to pick one. Cost for a byte-frozen test
suite: the chosen alternative depends on the *ideal size* of real content in
a real font on a real platform, so the same scene at the same width can pick
different children on macOS and iOS. Powerful, but the least deterministic
mechanism in the survey.

### 1d. Adaptive grids — wrapping expressed as a column spec

`GridItem.Size` has exactly three cases:

- `case fixed(CGFloat)` — "A single item with the specified fixed size."
- `case flexible(minimum: CGFloat, maximum: CGFloat)` — "A single flexible item."
- `case adaptive(minimum: CGFloat, maximum: CGFloat)` — "**Multiple items in
  the space of a single flexible item.**"

`adaptive` is SwiftUI's answer to CSS `repeat(auto-fit, minmax(…))`: one
declared column entry expands to as many real columns as fit at the stated
minimum. The app declares a *minimum size*, not a breakpoint; the count is
computed. Used with `LazyVGrid`/`LazyHGrid`.

### 1e. NavigationSplitView — framework-owned collapse

`struct NavigationSplitView<Sidebar, Content, Detail>`, iOS 16 / macOS 13+.
Apple: "On watchOS, tvOS, and with narrow sizes like on iPhone or on iPad in
Slide Over, the navigation split view collapses all of its columns into a
stack, and shows the last column that displays useful information."

The app declares *nothing* about when. It can only influence the result:
`NavigationSplitViewVisibility` (a `State` binding for programmatic column
visibility) and `.navigationSplitViewStyle(_:)` (whether to emphasize the
detail column or give all columns equal prominence). This is kaya's existing
three-pane behavior's precedent, and note that it is scoped to *navigation*,
not to arbitrary content — Apple ships no `ContentSplitView`.

### 1f. What moved in 2025-2026

`containerRelativeFrame()` (iOS 17+) is the "size me as a fraction of my
container" escape hatch: fill the container's width or height, take a chosen
number of equal portions of it, or compute a custom length from the container
size. It sizes; it does not re-arrange.

WWDC26 (June 2026) is dominated by **resizable iPhone apps** — iPhone apps
running at non-phone sizes on iPad and in iPhone Mirroring — plus adaptive
APIs for hinge state and multi-configuration displays on flexible-screen
hardware, with Apple stating that fluid reflow rather than letterboxing is
the expected default. The direction of travel matches Google's: *stop
assuming a fixed screen; adapt to your window.* No new "content breakpoint"
primitive appeared; the existing four (size class, `AnyLayout`,
`ViewThatFits`, adaptive grids) remain the vocabulary.

---

## 2. Jetpack Compose / Material 3 Adaptive

### 2a. Versions and artifact names, verified August 2026

`androidx.compose.material3.adaptive` — **stable 1.3.0** (2026-08-12), latest
alpha **1.4.0-alpha01** (2026-08-26). Four artifacts:

- `androidx.compose.material3.adaptive:adaptive` — core, window size class
  computation (`currentWindowAdaptiveInfo`)
- `androidx.compose.material3.adaptive:adaptive-layout` —
  `ListDetailPaneScaffold`, `SupportingPaneScaffold`, `ThreePaneScaffold`
- `androidx.compose.material3.adaptive:adaptive-navigation` — standalone
  navigators, `NavigableListDetailPaneScaffold`
- `androidx.compose.material3.adaptive:adaptive-navigation3` — **new in
  1.3.0**, integrates Navigation3: `ListDetailSceneStrategy` /
  `rememberListDetailSceneStrategy`, `SupportingPaneSceneStrategy` /
  `rememberSupportingPaneSceneStrategy`

Separately `androidx.compose.material3:material3-adaptive-navigation-suite`
carries `NavigationSuiteScaffold`, which "automatically switches between
navigation bar and navigation rail depending on app window size class and
device posture."

### 2b. WindowSizeClass — a platform signal that is actually a width

```kotlin
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.material3.adaptive.WindowSizeClass

val windowSizeClass = currentWindowAdaptiveInfo().windowSizeClass
```

Breakpoints, from Google's own table:

| class | width |
|---|---|
| compact | `< 600dp` |
| medium | `600dp ≤ w < 840dp` |
| expanded | `840dp ≤ w < 1200dp` |
| large | `1200dp ≤ w < 1600dp` |
| extra-large | `w ≥ 1600dp` |

Height: compact `< 480dp`, medium `480–900dp`, expanded `≥ 900dp`. Large and
extra-large are opt-in:
`currentWindowAdaptiveInfo(supportLargeAndXLargeWidth = true)`.

Two pieces of Google guidance are directly load-bearing for kaya's problem:

> "Available width is usually more important than available height due to the
> ubiquity of vertical scrolling, so the width window size class is likely
> more relevant to your app's UI."

> **"Do not test for equality with a size class."**

The second is the API-design finding. The recommended shape is an
*at-least* predicate, not a match on an enum case:

```kotlin
val showTopAppBar =
    windowSizeClass.isHeightAtLeastBreakpoint(WindowSizeClass.HEIGHT_DP_MEDIUM_LOWER_BOUND)
```

`isWidthAtLeastBreakpoint` / `isHeightAtLeastBreakpoint` against named
lower-bound constants replaced the older `WindowWidthSizeClass.Compact ==`
enum comparisons (the `androidx.compose.material3.windowsizeclass.WindowSizeClass`
of 2022-2023, computed via `calculateWindowSizeClass(activity)`, is the
superseded surface; the current type lives in `androidx.window.core.layout`
and is re-exported from `androidx.compose.material3.adaptive`). The reason
is forward compatibility: an equality test against `Expanded` silently
does the wrong thing the day `Large` is added — which is exactly what
happened when Large/XL landed. **A monotone `>=` predicate survives a
widened vocabulary; an equality test does not.**

And on *what* to key on at all:

> "In the past, apps typically ran full screen. Today, apps run in
> multi-window mode in arbitrarily sized windows independent of the device
> screen size. Users can change the window size at any time. So even on a
> single device type, apps must be adaptive."

> "Adaptive apps simplify and generalize the problem ... by considering only
> the app window when rendering layouts."

Scope of use: "Use window size classes to make **high-level** application
layout decisions, such as deciding whether to use a specific canonical
layout" — explicitly *not* `isTablet` logic, and by implication not
fine-grained per-component decisions.

### 2c. Canonical layouts — framework-owned collapse, with a declared override

`ListDetailPaneScaffold` "presents a list and the detail of a list item in
side-by-side panes on the expanded window size class, but just the list or
the detail on compact and medium window size classes."
`SupportingPaneScaffold` does the same for main + supporting pane.

The policy object is `PaneScaffoldDirective` (from
`calculatePaneScaffoldDirective(windowAdaptiveInfo)`) — the app can
substitute its own directive to move the thresholds, so the collapse rule is
framework-owned *by default* but app-overridable. 1.3.0 added margins and
edge-to-edge support to both scaffolds; 1.4.0-alpha01 **removed** the
component-override APIs for `NavigationSuiteScaffold` and `ThreePaneScaffold`.

`PaneExpansionState` allows runtime control of the split and preferred pane
dimensions (drag-to-resize was folded into it in 1.2.0-beta02).

### 2d. Reflow and levitate — the newest idea in the survey

Since 1.2.0 the pane scaffolds carry **reflow** and **levitate** strategies.
Reflow: when the scaffold drops to a single-pane layout, an associated pane
is *reflowed underneath* the main pane rather than hidden entirely. Levitate:
the pane floats above as an overlay. This is the answer to the complaint that
"collapse" is lossy — the secondary content moves below instead of
disappearing. **Conceptually this is exactly the desktop-row → phone-column
transformation kaya is asking about, expressed as a per-pane policy rather
than as a layout swap.**

### 2e. FlowRow / FlowColumn — wrapping

```kotlin
@Composable
fun FlowRow(
    modifier: Modifier = Modifier,
    horizontalArrangement: Arrangement.Horizontal = Arrangement.Start,
    verticalArrangement: Arrangement.Vertical = Arrangement.Top,
    maxItemsInEachRow: Int = Int.MAX_VALUE,
    content: @Composable FlowRowScope.() -> Unit
)
```

`FlowColumn` mirrors it with `maxItemsInEachColumn`. Items align within their
line via `Modifier.align()`. These graduated out of experimental. Wrapping is
*content-measured*, so the number of lines is computed, never declared —
`maxItemsInEachRow` is a declared ceiling, not a breakpoint.

### 2e-bis. FlexBox (2026) — the newest thing in the entire survey

Compose Foundation **1.11.0-alpha04, 2026-01-28**:

> "Introduced `FlexBox`, a configurable layout system that is a superset of
> `Row`, `Column`, `FlowRow`, and `FlowColumn`. It supports features like
> flex-grow, flex-shrink, custom wrapping, direction change and detailed
> alignment control via `FlexBoxConfig` and `Modifier.flex`."

Promoted to stable in **1.13.0-alpha01, 2026-08-12**: "`FlexBox` and its
related configuration APIs have been promoted to stable and are no longer
experimental." (A 1.11.0-beta01 breaking change moved the DSL from properties
to functions: `grow(1f)` rather than `grow = 1f`.)

```kotlin
FlexBox(
    config = {
        direction(FlexDirection.Column)
        wrap(FlexWrap.Wrap)
        alignItems(FlexAlignItems.Center)
        alignContent(FlexAlignContent.SpaceAround)
        justifyContent(FlexJustifyContent.Center)
        gap(16.dp)
    }
) { /* child items */ }
```

`direction` "sets the main axis, which dictates the direction items are laid
out in": `Row` (default), `RowReverse`, `Column`, `ColumnReverse`.
`wrap`: `NoWrap` (default), `Wrap`, `WrapReverse`. Plus `gap` / `rowGap` /
`columnGap`, `maxItemsInEachLine`, and `Modifier.flex { grow(…) }` per item.

Three things about this are worth the maintainer's attention:

1. **Google filed it under adaptive layouts** —
   `develop/ui/compose/layouts/adaptive/flexbox`. Its stated purpose: "It can
   resize, wrap, align, and distribute space among items to optimally fill the
   available space. It's a useful layout for different sized items and for
   resizing items when the available space changes."
2. **It makes the axis a value.** Compose was one of the two frameworks where
   `Row` and `Column` are separate composables; in 2026 it added a single
   container whose direction is configuration. That is the same shape UIKit,
   GTK, WinUI and Flutter have always had, arrived at from the other side.
3. **It supersedes the wrapping composables**: "If you need to wrap items, use
   FlexBox instead of FlowRow and FlowColumn." Scope guidance:
   "FlexBox is usually used to display a small number of items *within* an
   overall screen layout. For an overall screen layout, Grid is usually a
   better choice. FlexBox does not support lazy-loading of items."

### 2f. BoxWithConstraints — measure-and-branch

```kotlin
@Composable
fun WithConstraintsComposable() {
    BoxWithConstraints {
        Text("My minHeight is $minHeight while my maxWidth is $maxWidth")
    }
}
```

Google's framing: "In order to know the constraints coming from the parent
and design the layout accordingly, you can use a `BoxWithConstraints`. ...
You can use these measurement constraints to compose different layouts for
different screen configurations."

The mechanism cost, which Google's basics page does *not* state but which is
well established in the ecosystem: `BoxWithConstraints` is built on
`SubcomposeLayout`, so its content is composed **during the measure/layout
pass** rather than during composition. That crosses the composition/layout
phase boundary in the hottest part of the frame, and overuse produces
measure passes long enough to drop frames. The standard advice is to reach
for window size classes for high-level decisions and use
`BoxWithConstraints` only where a child's *composition* genuinely depends on
another child's *measurement*.

This is the single most transferable warning in the survey for a toolkit
considering a measure-and-branch primitive: **it inverts the phase order.**
A declarative tree that can only be built after measuring is a tree the
framework must build twice, or build late.

---

## 3. Flutter

Flutter has the clearest *vocabulary* of any framework here, and almost no
*primitives* — it hands you measurement and expects you to write the `if`.

### 3a. The official definition, which is worth stealing on its own

From `docs.flutter.dev/ui/adaptive-responsive`:

> "An easy way to think about it is that responsive design is about fitting
> the UI **into** the space and adaptive design is about the UI being
> **usable** in the space."

> "Often adaptive and responsive concepts are collapsed into a single term.
> Most often, *adaptive design* is used to refer to both."

### 3b. Abstract → Measure → Branch

Flutter's official general approach is a named three-step process:

**Abstract.** "First, identify the widgets that you plan to make dynamic.
Analyze the constructors for those widgets and abstract out the data that you
can share." The canonical example: switching between `NavigationBar` (small)
and `NavigationRail` (large), you factor out a `Destination` value holding the
icon and label so both renderings consume one data model. The three widget
families named as usually needing this: dialogs (fullscreen vs modal),
navigation UI (rail vs bottom bar), and custom layout (is the area taller or
wider).

**Measure.** "You have two ways to determine the size of your display area:
`MediaQuery` and `LayoutBuilder`."

- `MediaQuery.sizeOf(context)` — the **entire app window**, in logical
  pixels. "If you want your widget to be fullscreen, even when the app window
  is small, use `MediaQuery.sizeOf` so you can choose the UI based on the size
  of the app window itself." Prefer `sizeOf` over `of` for performance: "if
  you're only interested in the size property, it's more efficient to use the
  `sizeOf` method" (`of` subscribes the widget to *every* MediaQuery change).
- `LayoutBuilder` — "provides the layout constraints from the parent
  `Widget`. This means that you get sizing information based on the specific
  spot in the widget tree where you added the `LayoutBuilder`." Gives a
  `BoxConstraints` (min/max width and height). Use it when sizing should be
  relative to the widget's own slot rather than the window.

**That window-vs-container distinction is the same axis CSS draws between
media queries and container queries**, arrived at independently and stated
just as plainly.

**Branch.** "At this point, you must decide what sizing breakpoints to use
when choosing what version of the UI to display." And the rule:

> "your choice shouldn't depend on the **type** of device, but on the
> device's available window size."

The recommended number comes from Material, not Flutter: bottom nav bar below
600 logical pixels, nav rail at 600 and above.

### 3c. Widgets

`Wrap` (wrapping/flow), `Flex` (a `Row`/`Column` whose `direction` is a
runtime `Axis` value — Flutter's equivalent of `AnyLayout` is simply that the
axis is a *parameter*, since `Row` and `Column` are both `Flex`),
`OrientationBuilder`, `GridView`, `AnimatedSwitcher` for the transition.

Flutter recommends **no package** for this on the official pages; the
adaptive-scaffold packages (`flutter_adaptive_scaffold`) exist in the
ecosystem but the docs teach the built-in widgets plus your own `if`.

**Assessment for a byte-frozen test suite:** `Flex(direction: axis)` is the
cheapest possible spelling of the row/column switch — no type erasure needed,
no second subtree, because the axis was always data. That is a real design
lesson: *if the arrangement axis is a field rather than a type, adaptivity is
free.*

---

## 4. UIKit / AppKit (the classic, pre-declarative model)

### 4a. Trait collections

`UITraitCollection` — "A collection of data that represents the environment
for an individual element in your app's user interface," iOS 8+. It carries
`horizontalSizeClass`, `verticalSizeClass`, `displayScale`,
`userInterfaceIdiom`, `userInterfaceStyle`, `displayGamut`,
`preferredContentSizeCategory`, `accessibilityContrast`, `legibilityWeight`
and more. Apple's framing:

> "The `traitCollection` property of the `UITraitEnvironment` protocol
> contains traits that describe the state of various elements of the iOS user
> interface, such as size class, display scale, and layout direction.
> Together, these traits compose the UIKit trait environment."

**The trait environment is a tree, and a parent can override it for its
subtree.** That is the structural idea UIKit contributed and SwiftUI later
inherited via the writable `horizontalSizeClass` environment value: adaptation
is an *inherited ambient value*, not a global.

**iOS 17 changed how you observe it.** `traitCollectionDidChange` is
deprecated; the replacement is the `UITraitChangeObservable` protocol's
`registerForTraitChanges(_:handler:)` and
`registerForTraitChanges(_:target:action:)`. Apple's stated reason is exactly
the dependency-tracking problem a declarative toolkit already solves for
free: with the old override "the system doesn't know which traits you
actually care about, so it has to call that method every time that any trait
changes value." Registering names the traits you depend on.

### 4b. Flipping the axis

`UIStackView.axis`:

```swift
var axis: NSLayoutConstraint.Axis { get set }   // iOS 9+, default .horizontal
```

`.horizontal` makes a row, `.vertical` a column. Alongside it: `alignment`,
`distribution`, `spacing`, `isBaselineRelativeArrangement`,
`isLayoutMarginsRelativeArrangement`.

So the classic answer to "make this row a column on a phone" is one property
assignment inside a trait-change handler. **Same shape as libadwaita's
breakpoint setter, same shape as Flutter's `Flex(direction:)` — the axis is a
mutable field, so nothing is rebuilt.** SwiftUI is the outlier that needed
`AnyLayout`, precisely because its stacks are *types* rather than objects with
a settable axis.

### 4c. Per-size-class constraint installation

Auto Layout's contribution is that **individual views and individual
constraints can be installed or uninstalled per size class**. In Interface
Builder this is the `Installed` property's trait-variation `[+]` (the "Vary
for Traits" button existed in Xcode 8-12 and was removed in Xcode 13; the
`Installed` trait variations remain). Programmatically it degenerates to
holding two arrays of constraints and calling
`NSLayoutConstraint.activate` / `.deactivate` on trait change.

Notable as a *data model*: the adaptation is stored as a per-constraint
predicate in the archived nib, not as code. It is the closest classic analogue
to `AdwBreakpoint`'s setter list — declared, enumerable, inspectable — and it
is also widely considered the least pleasant to maintain, because the
alternatives are expressed as *differences between constraint sets* rather
than as whole named arrangements. `AdwMultiLayoutView` is the fix for that
complaint.

### 4d. AppKit has none of this

macOS has no size classes at all (SwiftUI's own docs: on macOS
`horizontalSizeClass` is always `.regular`). AppKit's adaptivity is
`NSSplitViewController` with per-item collapse: you collapse a pane by
setting its holding thickness to 0 and calling `adjustSubviews()`, with
`splitView(_:canCollapseSubview:)` and
`splitView(_:shouldCollapseSubview:for:)` as the delegate hooks, and Auto
Layout constraints deciding whether the window grows or the siblings absorb
the space. Everything is imperative and app-driven. **The platform that has
resizable windows as a first-class fact is the platform with no declarative
adaptivity mechanism** — which is why cross-platform toolkits cannot inherit
one and must define it themselves.

---

## 5. GTK4 / libadwaita

libadwaita is the most interesting case in the survey, because GNOME went
furthest toward making adaptation **declarative data** rather than app code —
and it is the closest existing model to a toolkit like kaya, since it is
native widgets with a markup-declared tree.

### 5a. AdwBreakpoint — a media query for widgets

A breakpoint is an object with a **condition** and a list of **setters**. The
canonical UI-XML form:

```xml
<object class="AdwBreakpoint">
   <condition>max-width: 400px</condition>
   <setter object="button" property="visible">True</setter>
   <setter object="box" property="orientation">vertical</setter>
   <setter object="page" property="title" translatable="yes">Example</setter>
</object>
```

**Read the second setter again**: `<setter object="box" property="orientation">vertical</setter>`
is exactly kaya's question — a horizontal box becomes vertical at a declared
width — and libadwaita answers it with no app code at all, no callback, no
measurement in the app's hands. The breakpoint sets a *property* on an
existing widget; the widget is not rebuilt and children keep their identity
(the same property `AnyLayout` protects with type erasure, obtained for free
because GTK boxes are mutable objects with an `orientation` property).

Signals `apply` and `unapply` fire on activation/deactivation for the cases a
property setter can't express. API for building them in code:
`adw_breakpoint_add_setter()`, `adw_breakpoint_add_setters()`,
`adw_breakpoint_add_settersv()`.

### 5b. The condition grammar (`adw_breakpoint_condition_parse`)

This is the most precisely specified breakpoint language of any native
toolkit, and it is *parsed from a string*:

- **Length**: `"<type>: <value>[<unit>]"` where type ∈ `min-width`,
  `max-width`, `min-height`, `max-height`; unit ∈ `px`, `pt`, `sp`
  (default `px`). Examples: `"min-width: 500px"`, `"min-height: 400pt"`,
  `"max-width: 100sp"`, `"max-height: 500"`.
- **Ratio**: `"<type>: <width>[/<height>]"` where type ∈ `min-aspect-ratio`,
  `max-aspect-ratio`; height defaults to 1. Examples:
  `"min-aspect-ratio: 4/3"`, `"max-aspect-ratio: 1"`.
- **Logic**: `"<c> and <c>"`, `"<c> or <c>"`, with parentheses for nesting;
  without parentheses the first operator wins. Example:
  `"min-width: 400px and (max-aspect-ratio: 4/3 or max-height: 400px)"`.

The `sp` unit is the one worth noticing: it scales with the user's text size,
so `"max-width: 360sp"` means "narrower than 360 units *of the user's current
type scale*" — a breakpoint that moves when the font grows. That is the same
concern Apple's `AnyLayout` example addresses with `dynamicTypeSize`, but
folded into the length unit instead of into a separate predicate.

### 5c. Where breakpoints live — window scope and widget scope

Breakpoints attach to `AdwWindow`, `AdwApplicationWindow`, and `AdwDialog`
(window-scoped, the media-query analogue). **`AdwBreakpointBin`** (since 1.4)
is the container-scoped analogue: "provides a way to use breakpoints without"
a window, "designed for limiting breakpoints to individual pages or specific
UI sections."

```xml
<object class="AdwBreakpointBin">
   <property name="width-request">150</property>
   <property name="height-request">150</property>
   <property name="child">
     <object class="GtkLabel" id="child">
       <property name="label">Wide</property>
       <property name="ellipsize">end</property>
       <style><class name="title-1"/></style>
     </object>
   </property>
   <child>
     <object class="AdwBreakpoint">
       <condition>max-width: 200px</condition>
       <setter object="child" property="label">Narrow</setter>
     </object>
   </child>
</object>
```

The documented constraint is a real API-design finding, not a footnote: "The
`GtkWidget:width-request` and `GtkWidget:height-request` properties must
always be set when using breakpoints, indicating the smallest size you want to
support." A container that adapts to its own allocation must declare a floor,
or it can be squeezed to zero and the condition becomes meaningless. **Any
container-scoped breakpoint primitive needs a mandatory declared minimum.**

### 5d. AdwMultiLayoutView — named alternative arrangements over shared children

Since **libadwaita 1.6**. This is the mechanism nobody else in the survey has,
and it is the most direct precedent for "a dashboard that arranges one way on
desktop and another on a phone."

The view holds **children by id** and **layouts by name**. Each layout is a
tree of ordinary widgets containing `AdwLayoutSlot` placeholders that name a
child id. Switching layouts re-parents the same child widgets into the new
slots — the children are constructed once and *moved*, never rebuilt.

```xml
<object class="AdwMultiLayoutView">
  <child>
    <object class="AdwLayout">
      <property name="name">sidebar</property>
      <property name="content">
        <object class="AdwOverlaySplitView">
          <property name="sidebar">
            <object class="AdwLayoutSlot"><property name="id">secondary</property></object>
          </property>
          <property name="content">
            <object class="AdwLayoutSlot"><property name="id">primary</property></object>
          </property>
        </object>
      </property>
    </object>
  </child>
  <child>
    <object class="AdwLayout">
      <property name="name">bottom-sheet</property>
      <property name="content">
        <object class="AdwBottomSheet">
          <property name="open">True</property>
          <property name="content">
            <object class="AdwLayoutSlot"><property name="id">primary</property></object>
          </property>
          <property name="sheet">
            <object class="AdwLayoutSlot"><property name="id">secondary</property></object>
          </property>
        </object>
      </property>
    </object>
  </child>
  <child type="primary"><!-- primary child --></child>
  <child type="secondary"><!-- secondary child --></child>
</object>
```

API: `adw_multi_layout_view_set_layout_name()`,
`adw_multi_layout_view_set_child()`, `adw_multi_layout_view_add_layout()`.

And the composition with 5a is the whole point: **the layout is switched by an
`AdwBreakpoint` setter on the `layout-name` property.** So the app declares
(a) a set of named arrangements, (b) which content goes in which named slot,
and (c) a width condition mapping to a name. Nothing is measured by the app,
nothing is branched in app code, and the arrangement alternatives are
*enumerable data* — a property the byte-frozen-test problem cares about a great
deal, because a test can assert "layout-name is `bottom-sheet`" without
asserting a single pixel.

### 5e. AdwNavigationSplitView — collapse, but app-declared

Since 1.4. A `collapsed` property switches between side-by-side panes and an
`AdwNavigationView` stack. **It does not collapse automatically** — GNOME
routes it through the same breakpoint machinery:

```xml
<object class="AdwBreakpoint">
  <condition>max-width: 400sp</condition>
  <setter object="split_view" property="collapsed">True</setter>
</object>
```

This is a deliberate divergence from SwiftUI's `NavigationSplitView` and
Compose's `ListDetailPaneScaffold`, both of which own the threshold. GNOME
made the threshold **app-declared**, at the cost of every app having to write
the breakpoint. Same for `AdwOverlaySplitView`.

### 5f. AdwWrapBox and AdwClamp

`AdwWrapBox`, since **1.7**: "a widget that functions like a box container
but with the capability to wrap content across multiple lines," behaving
"more like words in a wrapping label" as opposed to a flow box's grid.
Properties: `orientation`, `wrap-policy` (wrap when children can't fit at
natural size, or only after shrinking to minimum), `justify`, `line-spacing`,
`child-spacing`, `natural-line-length`, plus homogeneous line heights and
reversed wrap direction.

`AdwClamp` (since API version 1; `unit` property added in 1.4): "A widget
constraining its child to a given size," with `maximum-size` and
`tightening-threshold`. This is the *upper*-bound half of adaptivity that the
breakpoint story ignores — content that would otherwise stretch to a
2000px-wide line gets capped and centered.

### 5g. GNOME's doctrine

From the HIG's adaptive guidelines: apps should "scale from narrow sizes that
are appropriate for phones or split screen, all the way up to very large
desktop sizes, **while always providing the same functionality**." Minimum
desktop window size **1024×600px**; phone-appropriate apps go down to
**360×294px**. Method is explicitly mobile-first: "start from the most
constrained environment (smallest screen size, most limited input devices) and
then work your way up to the least constrained one." For large displays,
place "content within containers that have a maximum width" (i.e. `AdwClamp`).

---

## 6. WinUI 3 / UWP lineage

Microsoft's model is the oldest of the "declared breakpoint" designs (it
shipped with Windows 10 in 2015) and it has barely changed; the WinUI 3 docs
were last revised 2026-03 and 2026-07 and still teach it.

### 6a. AdaptiveTrigger + VisualStateManager

A `VisualState` "defines property values that are applied to an element when
it's in a particular state." A `VisualStateManager` "applies the appropriate
VisualState when the specified conditions are met." An `AdaptiveTrigger`
"provides an easy way to set the threshold (also called 'breakpoint') where a
state is applied in XAML."

The modern (post-Windows-10) `Setter` form, which is the one to compare
against `AdwBreakpoint`:

```xaml
<Page ...>
    <Grid>
        <VisualStateManager.VisualStateGroups>
            <VisualStateGroup>
                <VisualState>
                    <VisualState.StateTriggers>
                        <!-- VisualState to be triggered when the
                             window width is >=640 effective pixels. -->
                        <AdaptiveTrigger MinWindowWidth="640" />
                    </VisualState.StateTriggers>

                    <VisualState.Setters>
                        <Setter Target="mySplitView.DisplayMode" Value="Inline"/>
                        <Setter Target="mySplitView.IsPaneOpen" Value="True"/>
                    </VisualState.Setters>
                </VisualState>
            </VisualStateGroup>
        </VisualStateManager.VisualStateGroups>
        <SplitView x:Name="mySplitView" DisplayMode="CompactInline"
                   IsPaneOpen="False" CompactPaneLength="20">
            ...
        </SplitView>
    </Grid>
</Page>
```

And the canonical example on the `AdaptiveTrigger` reference page itself is
*precisely kaya's question*, answered in one setter — a `StackPanel` that is
`Vertical` by default and becomes `Horizontal` above 720 epx:

```xaml
<VisualState>
    <VisualState.StateTriggers>
    <!--VisualState to be triggered when window width is >=720 effective pixels.-->
        <AdaptiveTrigger MinWindowWidth="720"/>
    </VisualState.StateTriggers>
    <VisualState.Setters>
        <Setter Target="myPanel.Orientation" Value="Horizontal"/>
    </VisualState.Setters>
</VisualState>
...
<StackPanel x:Name="myPanel" Orientation="Vertical"> ... </StackPanel>
```

Note the direction of the default: the **narrow** arrangement is the base
declaration and the wide one is the breakpoint override, matching GNOME's
mobile-first doctrine.

Four details that matter to an API designer:

1. **`MinWindowWidth` / `MinWindowHeight` are *minimums only*, and they
   compose as AND.** There is no `MaxWindowWidth`. So states are expressed as
   an ordered ladder of lower bounds and the last matching one wins — the
   same monotone `>=` shape Google arrived at with
   `isWidthAtLeastBreakpoint`. Both ecosystems independently rejected
   equality/range matching in favour of at-least thresholds.
2. **No default state is needed.** "When you use state triggers, you don't
   need to define an empty `DefaultState`. The default settings are reapplied
   automatically when the conditions of the state trigger are no longer met."
   The base declaration *is* the fallback; a breakpoint is a *diff* against
   it. That is a real simplification over "declare N complete layouts."
3. **A placement gotcha that is pure API-design smell:** "When you use
   StateTriggers, always ensure that VisualStateGroups is attached to the
   first child of the root in order for the triggers to take effect
   automatically." A rule you can silently violate is a rule a better design
   would have made unrepresentable.
4. **`StateTrigger` is extensible.** "You can extend the `StateTrigger` class
   to create custom triggers for a wide range of scenarios" — e.g. keying on
   input type (touch vs mouse) or device family. So the trigger is an open
   predicate, not a closed size vocabulary. Multiple triggers in one
   `StateTriggers` collection compose as OR.

The imperative fallback remains `VisualStateManager.GoToState(this,
"WideState", false)` from a `SizeChanged` handler.

### 6b. Microsoft's breakpoints and its stance on device detection

From the design guidance (revised 2026-07):

| Size class | Breakpoints | Typical screen size | Devices | Window sizes |
|---|---|---|---|---|
| Small | up to 640px | 20" to 65" | TVs | 480x854, 540x960 |
| Medium | 641 – 1007px | 7" to 12" | Tablets | 960x540 |
| Large | 1008px and up | 13" and up | PCs, Laptops, Surface Hub | 1024x640, 1366x768, 1920x1080 |

> "When you design for specific breakpoints, design for the amount of screen
> space available to your app (the app's window), not the physical screen
> size."

> "Windows doesn't provide a way for your app to detect the specific device
> your app is running on. It can tell you the effective resolution, and the
> amount of screen space available to the app (the size of the app's window).
> We recommend defining visual states for screen sizes and break points."

The **effective pixel** system is the mechanism that makes one breakpoint
number mean the same thing across devices: viewing distance and pixel density
are folded into the unit, so "a 1080p TV ... has only 540 effective pixels"
and therefore lands in the *Small* class despite being physically huge.
Scaling plateaus are 100/125/150/175/200/225/250/300/350/400%, and the
guidance is that sizes and positions be multiples of 4 epx so every plateau
lands on whole pixels.

**This is directly relevant to byte-frozen cross-platform tests**: a
breakpoint expressed in raw device pixels means different things on different
hosts, and every ecosystem here solved it the same way with a
density-independent unit — Windows `epx`, Android `dp` (and libadwaita's
`sp`, which also folds in text scale), Flutter "logical pixels," Apple
points.

### 6c. The six named techniques

Microsoft names the vocabulary of what adaptation can *do*, and it is the
best taxonomy any of these vendors published:

- **Reposition** — "alter the location and position of UI elements to make
  the most of the window size. In this example, the smaller window stacks
  elements vertically."
- **Resize** — "adjusting the margins and size of UI elements."
- **Reflow** — "changing the flow of UI elements ... when going to a larger
  screen, it might make sense to add columns."
- **Show/hide** (reveal) — "show or hide UI elements based on screen real
  estate," including how much metadata to surface.
- **Replace** — swap one UI for another at a breakpoint (nav pane vs tabs;
  `NavigationView` supports it via pane position top/left).
- **Re-architect** — "collapse or fork the architecture of your app," e.g.
  expanding into the full list/details pattern.

And Microsoft's own responsive/adaptive distinction, which is the mirror
image of Flutter's:

> "*Responsive* design uses just one layout where the content is fluid and can
> adapt to changing window sizes. ... *Adaptive* design is similar, but
> replaces one layout with another layout."

> "An adaptive layout ... has multiple fixed layout sizes and triggers the
> page to load a given layout based on the available space."

**Reposition is kaya's question exactly** ("the smaller window stacks elements
vertically"), and Microsoft classifies it as the *cheapest* technique, below
replace and re-architect.

### 6d. Fluid sizing underneath

Everything above sits on star sizing (`Width="*"`, `"2*"`, `"Auto"`, plus
`MinWidth`/`MaxWidth`), which is kaya's grow factor by another name. Microsoft
is explicit that breakpoints are the *second* tool: "Layout panels let you
organize your UI into logical groups of controls. When you use them with
appropriate property settings, you get some support for automatic resizing,
repositioning, and reflowing of UI elements. **However, most UI layouts need
further modification when there are significant changes to the window size.
For this, you can use visual states.**"

That sentence is the whole argument for adding a breakpoint primitive to a
toolkit that already has grow factors.

---

## 7. Web / CSS — the reference point

### 7a. Media queries vs container queries

Media queries key on the **viewport**; container queries key on an
**ancestor element's size**. The web is the only ecosystem where both exist
as first-class, side by side, and where the industry has fully moved to the
component-scoped one for component-scoped problems.

Declaring a container is two properties (or one shorthand):

```css
.post {
  container-type: inline-size;
  container-name: sidebar;
}
/* shorthand */
.post { container: sidebar / inline-size; }
```

`container-type` values:

- `size` — query inline **and** block dimensions; applies layout, style and
  size containment
- `inline-size` — query inline dimension only; applies layout, style and
  inline-size containment
- `normal` — default; no size queries, but name-only and style queries work

Querying:

```css
@container (width > 700px) {
  .card h2 { font-size: 2em; }
}

@container sidebar (width > 700px) { ... }
```

Container query length units, usable inside the rule:
`cqw` (1% of container width), `cqh` (height), `cqi` (inline size),
`cqb` (block size), `cqmin`, `cqmax`.

```css
@container (width > 700px) {
  .card h2 { font-size: max(1.5em, 1.23em + 2cqi); }
}
```

**The crucial structural constraint, and the reason this is hard to copy:**
declaring `container-type: size` or `inline-size` applies *containment*. The
container's size must not depend on its contents along the queried axis, or
the query is circular (query says "I'm wide, so make children big," children
being big makes the container wide, repeat). CSS resolves this by *forcing*
the container to stop sizing itself from its contents on that axis.
`inline-size` is the common choice exactly because the block axis stays
content-sized. **Any toolkit adding container-scoped adaptivity has to answer
this same question, and CSS's answer is: the querying container's size on the
queried axis must be determined by its parent, not by its children.**

Support status as of 2026: container **size** queries have been in Chrome,
Firefox and Safari since 2023, sit around 93% global availability, and are
treated as safe without fallback. Container **style** queries are still
partial and are landing in Firefox during 2026 under Interop 2026.

### 7b. Wrapping and auto-fitting — adaptation without any breakpoint

`flex-wrap: wrap` on a flex container: items overflow onto new lines instead
of shrinking past their basis. Zero declared numbers.

CSS Grid's `repeat()` with `auto-fill` / `auto-fit` and `minmax()`:

- `auto-fill` — "Resolves to the largest number of repetitions that does not
  cause overflow of a constrained (has a maximum size) content box."
- `auto-fit` — "Behaves as `auto-fill`, except that after placing grid items,
  any empty repeated tracks are collapsed."

```css
grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
```

The app declares **one minimum track size**; the column count is computed. A
three-column dashboard becomes one column on a phone with no breakpoint, no
media query, and no second layout declaration. This is the single most
economical adaptive construct in the survey and it is the direct ancestor of
SwiftUI's `GridItem.Size.adaptive(minimum:maximum:)`.

`flex-basis` + `flex-wrap` + a percentage basis gives the same effect for
flex containers, which is the pattern most component libraries actually ship.

---

## 8. Cross-cutting synthesis

### 8a. The five classes, every mechanism sorted

**(a) Discrete breakpoint / size-class switching**

| mechanism | switch point comes from | scope | observable state |
|---|---|---|---|
| SwiftUI `horizontalSizeClass` | **platform** (device + mode; always `.regular` on macOS/tvOS, always `.compact` on watchOS) | environment subtree, writable since macOS 14 | enum, 2 cases |
| SwiftUI `AnyLayout` | **app** (mechanism only, no policy) | one container | none — layout type is erased |
| Compose `WindowSizeClass` + `isWidthAtLeastBreakpoint` | **platform-defined constants**, app-chosen predicate | window | 5 width buckets |
| UIKit trait collection + per-size-class constraint installation | **platform** | environment subtree | enum, 2 cases |
| WinUI `AdaptiveTrigger` + `VisualState` | **app** (`MinWindowWidth`/`MinWindowHeight`) | window; group attached to root's first child | **named visual state** |
| libadwaita `AdwBreakpoint` | **app** (parsed condition string) | window, or one container via `AdwBreakpointBin` | applied/unapplied + property values |
| `AdwMultiLayoutView` | **app**, usually via a breakpoint setter | one container | **layout name (a string)** |
| Flutter `MediaQuery.sizeOf` + `if` | **app** | window | whatever the app models |
| CSS media queries | **app** | viewport | matched rules |
| CSS container queries | **app** | a declared container element | matched rules |

**(b) Fit-based selection** — SwiftUI `ViewThatFits(in:)` only. The app
supplies an ordered menu, largest to smallest; the framework measures each
child's *ideal size* and takes the first that fits. Nobody else shipped this.

**(c) Wrapping / flow** — Compose `FlexBox` with `wrap(FlexWrap.Wrap)` (stable
2026-08-12, and now Google's recommendation *over* `FlowRow`/`FlowColumn`),
`FlowRow`/`FlowColumn`, Flutter `Wrap`, `AdwWrapBox` (1.7), WinUI
`VariableSizedWrapGrid`, CSS `flex-wrap`, and the "declared minimum, computed
count" variants: CSS `repeat(auto-fit, minmax(200px, 1fr))` and SwiftUI
`GridItem.Size.adaptive(minimum:maximum:)`.

**(a/c hybrid, and the 2026 arrival)** — Compose `FlexBox`'s
`direction(FlexDirection.Row|Column)` is class (a)'s *effect* (an axis swap)
with no trigger attached: the container accepts direction as a value, and
whatever computes the breakpoint sets it. That separation — mechanism here,
policy elsewhere — is what `AnyLayout`, `UIStackView.axis` and
`GtkOrientable:orientation` all have in common too.

**(d) Measure-and-branch** — Compose `BoxWithConstraints`, Flutter
`LayoutBuilder`, SwiftUI `GeometryReader` (and `containerRelativeFrame` for
the sizing-only case). The app receives the container's constraints and
builds a subtree from them.

**(e) Framework-owned navigation collapse** — SwiftUI `NavigationSplitView`,
Compose `ListDetailPaneScaffold` / `SupportingPaneScaffold` /
`NavigationSuiteScaffold`, UIKit `UISplitViewController`. GNOME's
`AdwNavigationSplitView` and `AdwOverlaySplitView` belong here by *shape* but
not by *policy* — their `collapsed` property is set by an app-declared
breakpoint, so GNOME alone put the threshold in the app's hands.

### 8b. Determinism, ranked (the axis a byte-frozen test suite cares about)

**Most deterministic → least:**

1. **App-declared threshold on window width in a density-independent unit,
   producing a named state or a property value.** (`AdaptiveTrigger`,
   `AdwBreakpoint`, `AdwMultiLayoutView`.) The switch is pure arithmetic on
   one number the test already controls. The *result* is a name or a property
   value, not pixels — so a test asserts `layout == "stacked"` and never
   measures anything. Byte-identical across platforms by construction.
2. **Platform-supplied size class.** Deterministic *given the platform*, but
   the platforms disagree about what the classes mean and when they change.
   Apple's is not a width at all; Google's is. A shared scene keyed on "size
   class" would produce different arrangements on macOS and Android at the
   same window width.
3. **Declared-minimum column count** (`auto-fit`/`minmax`,
   `GridItem.adaptive`). Computed, but the computation is
   `floor((W + gap) / (min + gap))` over numbers the app declared. Predictable
   across platforms as long as the toolkit owns the arithmetic.
4. **Measure-and-branch.** Deterministic in principle, but the measured value
   is the container's *allocated* size, which depends on everything above it
   in the tree — including platform chrome, insets, and native widget minimum
   sizes that legitimately differ. Plus the phase-order cost
   (`SubcomposeLayout`: composition during the measure pass).
5. **Wrapping / flow.** The line count depends on children's natural sizes.
   For fixed-size children this is arithmetic; for **text** it is font
   metrics, which differ per platform by design. A `FlowRow` of labels wraps
   at different points on macOS and Windows with no bug anywhere.
6. **Fit-based selection (`ViewThatFits`).** Least deterministic of all: the
   choice among N alternatives is a function of the ideal size of real
   content in the platform's real font. Same scene, same width, potentially
   different child selected on every platform — and the observable difference
   is not a measurement that is "close enough," it is a *different subtree*.

### 8c. What everyone converged on

**Unanimous: key on the window, never the device.** Google — "even on a single
device type, apps must be adaptive"; "considering only the app window when
rendering layouts." Microsoft — "Windows doesn't provide a way for your app to
detect the specific device your app is running on"; "design for the amount of
screen space available to your app (the app's window), not the physical screen
size." Flutter — "your choice shouldn't depend on the *type* of device, but on
the device's available window size." Apple arrived last and by force
(resizable iPhone apps at WWDC26), but arrived. Apple's `horizontalSizeClass`
is the one surviving API that still encodes device-and-mode rather than size,
and it is the one that behaves worst on a resizable desktop window.

**Unanimous: a density-independent unit.** WinUI `epx` (with viewing distance
folded in, so a 1080p TV is 540 epx and classes as *Small*), Android `dp`,
Flutter logical pixels, Apple points, libadwaita `px`/`pt`/**`sp`**. GNOME's
`sp` goes furthest by folding *text scale* into the length, so
`max-width: 360sp` moves when the user enlarges type — the same concern Apple
handles by keying `AnyLayout` on `dynamicTypeSize` instead.

**Convergent and independent: monotone at-least thresholds, not equality.**
Google states it as a rule — "**Do not test for equality with a size class**"
— and ships `isWidthAtLeastBreakpoint(WindowSizeClass.WIDTH_DP_*_LOWER_BOUND)`.
Microsoft only ever shipped `MinWindowWidth`/`MinWindowHeight`; there is no
`Max`. libadwaita is the exception, offering both `min-` and `max-` plus
`and`/`or`/parentheses. The argument for at-least is forward compatibility:
Android added Large and Extra-Large width classes, and every
`== Expanded` in the ecosystem silently changed meaning.

**Convergent: the adaptation is a DIFF against a base declaration.** WinUI
setters, libadwaita setters, UIKit's per-constraint `Installed` flag. WinUI
states the payoff outright: "you don't need to define an empty `DefaultState`.
The default settings are reapplied automatically when the conditions of the
state trigger are no longer met." Only `AdwMultiLayoutView` takes the other
road — N complete named arrangements over shared children — and it is the
newest design in the survey (libadwaita 1.6).

**Convergent: children must keep identity across the switch.** `AnyLayout`
exists *only* for this ("without destroying the state of the subviews").
`AdwMultiLayoutView` re-parents the same widgets through named slots.
Property-setter designs (`AdwBreakpoint`, `AdaptiveTrigger`, `UIStackView.axis`)
get it free because they mutate an existing object. **The naive spelling —
`if narrow { column { … } } else { row { … } }` — is the one design every
framework specifically built machinery to avoid.**

**Convergent: two scopes are needed, window and container.** CSS names them
(media vs container queries) and container queries are the growth area — safe
without fallback since 2023, ~93% availability. Flutter names them
(`MediaQuery.sizeOf` vs `LayoutBuilder`) and explains exactly when each
applies. libadwaita ships both (window/dialog breakpoints vs
`AdwBreakpointBin`, added in 1.4 for "limiting breakpoints to individual
pages"). Compose has both (`WindowSizeClass` vs `BoxWithConstraints`) and
tells you to prefer the window one for "high-level" decisions. SwiftUI is
weakest here — its size class is ambient and its container-scoped answer is
`GeometryReader`/`containerRelativeFrame`.

**And the constraint that comes with container scope, stated twice
independently:** a container that adapts to its own allocation must not size
itself from its contents on the queried axis, or the query is circular. CSS
enforces this by making `container-type: size|inline-size` apply containment
(and `inline-size` is the common choice precisely to leave the block axis
content-sized). libadwaita enforces it by documentation: "The
`GtkWidget:width-request` and `GtkWidget:height-request` properties **must
always be set** when using breakpoints, indicating the smallest size you want
to support."

**Divergent: who owns the navigation collapse threshold.** SwiftUI and
Compose own it (with Compose allowing a substituted `PaneScaffoldDirective`);
GNOME hands it to the app as a breakpoint setter. Notably Compose's 2026
answer to "collapse is lossy" is **reflow** — under a single-pane layout the
secondary pane moves *below* the main one rather than disappearing — which is
the row→column transformation expressed as a per-pane policy.

**The structural observation that cuts across everything, and 2026 sharpened
it:** the toolkits make the stack's axis a **value on one container** —
`UIStackView.axis` (iOS 9, 2015), `GtkOrientable:orientation` (which is what
`<setter object="box" property="orientation">vertical</setter>` sets),
`StackPanel.Orientation` (whose canonical `AdaptiveTrigger` example is
literally `<Setter Target="myPanel.Orientation" Value="Horizontal"/>`),
Flutter's `Flex(direction:)` where `Row` and `Column` are just presets. In all
of those, "row on desktop, column on phone" is a *one-property change* and
needs no adaptive primitive beyond something that can set a property.

SwiftUI and Compose were the two exceptions, where a stack is a **type**, and
both had to add machinery: SwiftUI shipped `AnyLayout` in iOS 16 purely to
erase that type without destroying child identity, and **Compose gave up on
the distinction in 2026** — `FlexBox` (stable 1.13.0-alpha01, 2026-08-12) is
"a superset of `Row`, `Column`, `FlowRow`, and `FlowColumn`" with
`direction(FlexDirection.Column)` as configuration, filed by Google under
*adaptive layouts*.

So the convergence is now near-total: **the arrangement axis is data, not
type, in every mainstream toolkit except SwiftUI** — and SwiftUI's
`AnyLayout` exists to simulate that fact. The shape of the layout vocabulary
decides how expensive adaptivity is, and the industry spent a decade
discovering it.

---

## 9. The shapes kaya could steal

Four, presented with precedent, and with what each costs. No recommendation —
these are the options the survey actually supports.

### Shape 1 — Arrangement axis as a property rather than a node kind

**Precedent:** `UIStackView.axis` (UIKit, iOS 9+), `GtkOrientable:orientation`
(GTK), `StackPanel.Orientation` (WinUI), `Flex(direction:)` (Flutter, where
`Row` and `Column` are literally presets over one widget), and — decisively —
Compose's `FlexBox` with `direction(FlexDirection.Column)`, stable
2026-08-12, which Google introduced as "a superset of `Row`, `Column`,
`FlowRow`, and `FlowColumn`" and filed under *adaptive layouts*.

If a kaya row and a kaya column are one node with an axis prop, then every
other mechanism below becomes "set one prop" and needs no new layout code.
It is also the move that lets adaptation reuse the existing prop-mutation
path, the existing transaction semantics, and the existing observation
surface — a test asserts a prop, not a pixel.

The evidence that this is the load-bearing decision: SwiftUI and Compose were
the only two frameworks where the stack was a *type*, both had to build extra
machinery for a problem the other four never had, and **one of the two
abandoned the position this year.** WinUI's own canonical `AdaptiveTrigger`
example is exactly this — `<Setter Target="myPanel.Orientation"
Value="Horizontal"/>` at `MinWindowWidth="720"` — a row/column switch in one
line with no adaptive layout type anywhere.

Cost: it is a change to the layout vocabulary itself, touching all eight
bindings and all four backends, and it makes `row` and `column` sugar over
one thing rather than two kinds. Whether the axis is a *prop* (mutable,
observable, settable by anything) or a *constructor argument* is the sub-
decision that determines whether Shape 2 can drive it.

### Shape 2 — A declared breakpoint that applies property setters

**Precedent:** `AdwBreakpoint` + `AdwBreakpointBin` (libadwaita 1.4+) and
WinUI's `AdaptiveTrigger` + `VisualState.Setters`. Both are markup-declared
lists of `(target, property, value)` applied when a width condition holds,
and both auto-revert to the base declaration when it stops holding.

This is the mechanism with the best determinism story in the whole survey:
the condition is app-declared arithmetic on one number, the effect is a
property value, and the observable is a property — so a byte-frozen
assertion is `expect_prop`-shaped and identical on every platform *provided
the core evaluates the condition itself* rather than delegating to
`AdwBreakpoint` on GTK and `AdaptiveTrigger` on WinUI (which would make the
switch point platform-computed and put uniform binding semantics at risk).

Two design points the precedents settle for you: the condition should be a
**monotone at-least threshold** (Google: "Do not test for equality with a size
class"; WinUI ships only `MinWindowWidth`), and the state should be a
**diff against the base declaration**, not a second complete layout (WinUI:
"you don't need to define an empty `DefaultState`").

Two hazards the precedents also record: WinUI's "always ensure that
VisualStateGroups is attached to the first child of the root" is a rule you
can silently violate — the kind invariant 3 says to make unrepresentable —
and container-scoped breakpoints require a **mandatory declared minimum size**
(libadwaita: width-request "must always be set") or the container can be
squeezed to nothing and the condition means nothing.

### Shape 3 — Named alternative arrangements over shared, slotted children

**Precedent:** `AdwMultiLayoutView` (libadwaita 1.6), with `AdwLayout` naming
each arrangement and `AdwLayoutSlot` naming where each child goes; switched by
setting one `layout-name` property, typically from a breakpoint setter.
SwiftUI's `AnyLayout` is the same idea with the names erased.

The app declares content **once** with ids, declares N arrangements
containing slots that reference those ids, and declares which width picks
which name. Children are constructed once and moved between slots, so state
and identity survive the switch — the property `AnyLayout` was invented to
protect.

Why it suits a byte-frozen suite specifically: **the entire adaptive state is
one string.** A scene can assert `layout-name == "stacked"` and never sample a
pixel, a geometry, or a font metric. It is also the only mechanism here that
handles arrangements too different to express as a property diff (a chart
*beside* three tables vs a chart *above* a scrolling stack of them).

Cost: it is a genuinely new node kind with a slot-reference mechanism, and it
overlaps kaya's existing template zone in ways that would need thinking
through. It also composes with Shape 2 rather than replacing it — in
libadwaita, the breakpoint is what sets `layout-name`.

### Shape 4 — Declared-minimum wrapping, count computed

**Precedent:** CSS `repeat(auto-fit, minmax(200px, 1fr))`, SwiftUI's
`GridItem.Size.adaptive(minimum:maximum:)` ("Multiple items in the space of a
single flexible item"), `AdwWrapBox` (1.7), Flutter `Wrap`, and Compose's
`FlexBox` with `wrap(FlexWrap.Wrap)` + `maxItemsInEachLine` — which Google
now says to use *instead of* `FlowRow`/`FlowColumn`, and which packages
wrapping and direction in the same container as Shape 1.

The app declares **one minimum** and the toolkit computes how many fit; a
three-column dashboard becomes one column on a phone with no breakpoint
declared anywhere. This is the most economical construct in the survey and
the only one that adapts continuously without the app naming a number twice.

Determinism caveat, which is the reason it belongs *below* Shapes 2-3 for
this codebase: the count is arithmetic (`floor((W + gap) / (min + gap))`) and
therefore reproducible — but only when the children's sizes are *declared*.
For text-sized children it becomes font metrics, and font metrics differ per
platform by design. If kaya took this shape, the deterministic version is the
one where the minimum is an explicit number, not `natural size`; the
`AdwWrapBox` `wrap-policy` distinction ("wrap when children can't fit at
natural size" vs "only after they're shrunk to minimum") is exactly this fork,
written down.

### What the survey argues against, for this codebase specifically

Not a recommendation about what to add, but the two mechanisms whose costs
this codebase would pay disproportionately:

- **Fit-based selection (`ViewThatFits`)** selects a *different subtree* based
  on the ideal size of real content in the platform's real font. Under
  invariant 6 (scene scripts shared verbatim, expected strings compared
  byte-for-byte across all languages and platforms) this is the mechanism
  whose output varies most unpredictably per platform, and it fails not by
  drifting a pixel but by rendering different widgets.
- **Measure-and-branch (`BoxWithConstraints` / `LayoutBuilder`)** inverts the
  phase order: the tree can only be built after measuring. Compose pays for
  this with `SubcomposeLayout` composing during the measure pass, and the
  ecosystem's standing advice is to prefer window size classes for high-level
  decisions and reserve it for cases where a child's composition genuinely
  depends on another child's measurement. A build closure that cannot run
  until layout has run is a different execution model, not a new widget.

---

## Sources

SwiftUI / UIKit (Apple documentation JSON API):
- https://developer.apple.com/tutorials/data/documentation/swiftui/anylayout.json
- https://developer.apple.com/tutorials/data/documentation/swiftui/viewthatfits.json
- https://developer.apple.com/tutorials/data/documentation/swiftui/environmentvalues/horizontalsizeclass.json
- https://developer.apple.com/tutorials/data/documentation/swiftui/griditem/size-swift.enum.json
- https://developer.apple.com/tutorials/data/documentation/swiftui/navigationsplitview.json
- https://developer.apple.com/tutorials/data/documentation/uikit/uitraitcollection.json
- https://developer.apple.com/tutorials/data/documentation/uikit/uistackview/axis.json
- https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/Size-ClassSpecificLayout.html
- https://developer.apple.com/wwdc26/guides/swiftui/

Jetpack Compose / Material 3 Adaptive:
- https://developer.android.com/develop/ui/compose/layouts/adaptive
- https://developer.android.com/develop/ui/compose/layouts/adaptive/use-window-size-classes
- https://developer.android.com/jetpack/androidx/releases/compose-material3-adaptive
- https://developer.android.com/develop/ui/compose/layouts/flow
- https://developer.android.com/develop/ui/compose/layouts/basics
- https://developer.android.com/jetpack/androidx/releases/compose-foundation (FlexBox 1.11.0-alpha04 / stable 1.13.0-alpha01)
- https://developer.android.com/develop/ui/compose/layouts/adaptive/flexbox
- https://developer.android.com/develop/ui/compose/layouts/adaptive/flexbox/container-behavior

Flutter:
- https://docs.flutter.dev/ui/adaptive-responsive
- https://docs.flutter.dev/ui/adaptive-responsive/general

GTK4 / libadwaita / GNOME:
- https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.Breakpoint.html
- https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/type_func.BreakpointCondition.parse.html
- https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.BreakpointBin.html
- https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.MultiLayoutView.html
- https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.NavigationSplitView.html
- https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.WrapBox.html
- https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.Clamp.html
- https://developer.gnome.org/hig/guidelines/adaptive.html

WinUI 3 / Windows:
- https://learn.microsoft.com/en-us/windows/apps/develop/ui/layouts-with-xaml
- https://learn.microsoft.com/en-us/windows/apps/design/layout/screen-sizes-and-breakpoints-for-responsive-design
- https://learn.microsoft.com/en-us/windows/apps/design/layout/responsive-design
- https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.adaptivetrigger

Web / CSS:
- https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_containment/Container_queries
- https://developer.mozilla.org/en-US/docs/Web/CSS/repeat
- https://caniuse.com/css-container-queries
