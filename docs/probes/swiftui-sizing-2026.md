# How SwiftUI sizes an NSViewRepresentable, and what it does not say

Research date: 2026-08-29. Sources: Apple's own documentation, WWDC
sessions and release notes, verified live (not from memory).

Question this serves: kaya's macOS table is an NSScrollView inside an
NSViewRepresentable, and a chain that proposes a CONCRETE width to it
was measured ending up sized to the DOCUMENT's width instead — so the
scroll view was as wide as its own content, had nothing to scroll, and
the ancestor clipped it (docs/deferred.md's mac-table-reachability
entry). This asks what the documented contract actually is.

THE HEADLINE, and it is the reason that entry stays open: Apple defines
`sizeThatFits` returning nil as "use the default sizing algorithm" and
never says what that algorithm IS. The composite size is whatever the
method returns, so answering the proposal is the only documented lever.

STATUS: complete, and explicit about its holes — the "could not verify"
list at the end is as load-bearing as the findings.

## Q1. `NSViewRepresentable.sizeThatFits(_:nsView:context:)` — the exact contract

**Source:** <https://developer.apple.com/documentation/swiftui/nsviewrepresentable/sizethatfits(_:nsview:context:)>
(fetched as `.../tutorials/data/documentation/swiftui/nsviewrepresentable/sizethatfits(_:nsview:context:).json`)

Declaration and availability, verbatim:

> **Platform:** macOS 13.0+
>
> ```swift
> @MainActor
> @preconcurrency
> func sizeThatFits(
>     _ proposal: ProposedViewSize,
>     nsView: Self.NSViewType,
>     context: Self.Context
> ) -> CGSize?
> ```

Abstract:

> "Given a proposed size, returns the preferred size of the composite view."

Return value, verbatim — this is the precise `nil` wording:

> "The composite size of the represented view controller. Returning a value of
> `nil` indicates that the system should use the default sizing algorithm."

Discussion, verbatim:

> "This method may be called more than once with different proposed sizes during
> the same layout pass. SwiftUI views choose their own size, so one of the values
> returned from this function will always be used as the actual size of the
> composite view."

### Version introduced

macOS 13.0 (Ventura), per the availability block quoted above. The UIKit
counterpart `UIViewRepresentable.sizeThatFits(_:uiView:context:)` is
"iOS 16.0+, iPadOS 16.0+, Mac Catalyst 16.0+, tvOS 16.0+, visionOS 1.0+" with
byte-identical abstract, return-value and discussion text —
<https://developer.apple.com/documentation/swiftui/uiviewrepresentable/sizethatfits(_:uiview:context:)>.
(Both ship with the SwiftUI release that also introduced the `Layout` protocol.)

**Note on "no implementation" vs "returns nil".** SwiftUI ships a *default
implementation* of this requirement in a protocol extension — the symbol
`sizethatfits(_:nsview:context:)-fuqx` is documented as a default
implementation, with identical text, at
<https://developer.apple.com/documentation/swiftui/nsviewrepresentable/sizethatfits(_:nsview:context:)-fuqx>.
Apple does not publish that implementation's body, so I cannot quote proof that
it returns `nil`; but its existence is why omitting the method compiles, and the
two paths ("omit it" and "return `nil`") are described by the same page.

**NOT VERIFIED:** neither the Xcode 14 release notes
(<https://developer.apple.com/documentation/xcode-release-notes/xcode-14-release-notes>)
nor Apple's "SwiftUI updates" page
(<https://developer.apple.com/documentation/Updates/SwiftUI>) mentions
`sizeThatFits`, `UIViewRepresentable` or `NSViewRepresentable` at all. I checked
both. The availability metadata on the symbol page is the only version source I
could find.

### What is "the default sizing algorithm"?

**NOT VERIFIED / NOT DOCUMENTED.** Apple names the fallback ("the default
sizing algorithm") but nowhere in the SwiftUI reference does it define what that
algorithm computes for an AppKit view. I could find no Apple page, release note
or WWDC session that states whether the default fills the proposal, consults
`intrinsicContentSize`, consults `fittingSize`, or does something else. Treat
any statement of the form "the default is X" as unsourced.

What *is* documented and constrains the answer:

- The representable's frame is set by SwiftUI, not by the AppKit view.
  <https://developer.apple.com/documentation/swiftui/nsviewrepresentable>:
  > "**Warning:** SwiftUI fully controls the layout of the AppKit view using the
  > view's `frame` and `bounds` properties. Don't directly set these
  > layout-related properties on the view managed by an `NSViewRepresentable`
  > instance from your own code because that conflicts with SwiftUI and results
  > in undefined behavior."

- Whatever the default is, SwiftUI still treats the answer as the view's chosen
  size: "SwiftUI views choose their own size, so one of the values returned from
  this function will always be used as the actual size of the composite view."
  (quoted above).

The practical consequence for the concrete problem — a representable that
reports 430pt against a 320pt proposal — is covered in Q2 and Q4.

---

## Q2. How SwiftUI sizes a representable with NO `sizeThatFits`

### What Apple documents

Nothing. This is the central gap in the sources.

- `NSViewRepresentable` (<https://developer.apple.com/documentation/swiftui/nsviewrepresentable>)
  documents `makeNSView`, `updateNSView`, `dismantleNSView`, `makeCoordinator`
  and `sizeThatFits`. Its Overview says nothing about sizing beyond the warning
  that SwiftUI owns the frame:
  > "**Warning:** SwiftUI fully controls the layout of the AppKit view using the
  > view's `frame` and `bounds` properties."

  The `UIViewRepresentable` page carries the same warning with the UIKit
  property list ("center, bounds, frame, and transform") and likewise says
  nothing about how the size is chosen —
  <https://developer.apple.com/documentation/swiftui/uiviewrepresentable>.

- The only pointer is the phrase in the `sizeThatFits` return-value docs, "the
  system should use the default sizing algorithm" (quoted in Q1), and that
  phrase is never expanded anywhere I could find.

**NOT VERIFIED:** I could find no Apple documentation, release note, WWDC
session or developer-forums reply from an Apple engineer that states whether
the default algorithm consults `NSView.intrinsicContentSize`, Auto Layout
`fittingSize`, `NSView.fittingSize`, or simply accepts the proposal. I looked at:
the `NSViewRepresentable`/`UIViewRepresentable` reference pages, the
`sizeThatFits` pages for `NSViewRepresentable`, `UIViewRepresentable` and
`UIViewControllerRepresentable`, WWDC22 "Use SwiftUI with AppKit" (10075),
WWDC22 "Compose custom layouts with SwiftUI" (10056), and several
developer.apple.com forum threads. None states the rule.

### The relevant AppKit facts (documented) that bound the answer

`NSView.intrinsicContentSize`
(<https://developer.apple.com/documentation/appkit/nsview/intrinsiccontentsize>):

> "The natural size for the receiving view, considering only properties of the
> view itself."
>
> "The default width and height values of this property are set to
> `noIntrinsicMetric`. … If your custom view has no intrinsic size for a given
> dimension, you can set the corresponding dimension to the
> `noIntrinsicMetric`."

`NSView.noIntrinsicMetric`
(<https://developer.apple.com/documentation/appkit/nsview/nointrinsicmetric>):

> "A value that tells the layout system to ignore the intrinsic size value for a
> given dimension."
>
> "Specify this value if a view doesn't have an intrinsic height or width. For
> example, a horizontal slider has an intrinsic height but might have no
> intrinsic width."

So an `NSScrollView` that has not overridden `intrinsicContentSize` reports
`noIntrinsicMetric` in **both** axes — i.e. "ignore me" — and there is no
documented statement of what SwiftUI then does. I searched specifically for an
Apple statement covering the `noIntrinsicMetric`-in-one-or-both-axes case for
representables and found none.

**What we can say from primary sources about the observed 430pt behaviour:**
only that the composite view's size is whatever the representable answers, and
that a larger-than-proposed answer is legal and unclipped (Q4). Any story about
*why* the default produced 430pt — Auto Layout `fittingSize` of the scroll view
with an unconstrained-width document view, for instance — is a hypothesis, not
something I could source. The actionable consequence is the same either way:
**implement `sizeThatFits` and stop relying on the undocumented default.** See
Q5.

---

## Q3. `ProposedViewSize` semantics — `nil`, `.zero`, `.infinity`

**Source:** <https://developer.apple.com/documentation/swiftui/proposedviewsize>

Overview, verbatim:

> "During layout in SwiftUI, views choose their own size, but they do that in
> response to a size proposal from their parent view. When you create a custom
> layout using the Layout protocol, your layout container participates in this
> process using ProposedViewSize instances. …
>
> Layout containers typically measure their subviews by proposing several sizes
> and looking at the responses. The container can use this information to decide
> how to allocate space among its subviews. A layout might try the following
> special proposals:
>
> - The zero proposal; the view responds with its minimum size.
> - The infinity proposal; the view responds with its maximum size.
> - The unspecified proposal; the view responds with its ideal size.
>
> A layout might also try special cases for one dimension at a time. For example,
> an HStack might measure the flexibility of its subviews' widths, while using a
> fixed value for the height."

Per-property, verbatim:

- `width` (<https://developer.apple.com/documentation/swiftui/proposedviewsize/width>):
  > "The proposed horizontal size measured in points."
  >
  > "A value of `nil` represents an unspecified width proposal, which a view
  > interprets to mean that it should use its ideal width."

- `unspecified` (<https://developer.apple.com/documentation/swiftui/proposedviewsize/unspecified>):
  > "The proposed size with both dimensions left unspecified."
  >
  > "Both dimensions contain `nil` in this size proposal. Subviews of a custom
  > layout return their ideal size when you propose this value using the
  > `dimensions(in:)` method. A custom layout should also return its ideal size
  > from the `sizeThatFits(proposal:subviews:cache:)` method for this value."

- `zero` (<https://developer.apple.com/documentation/swiftui/proposedviewsize/zero>):
  > "A size proposal that contains zero in both dimensions."
  >
  > "Subviews of a custom layout return their minimum size when you propose this
  > value using the `dimensions(in:)` method. A custom layout should also return
  > its minimum size from the `sizeThatFits(proposal:subviews:cache:)` method for
  > this value."

- `infinity` (<https://developer.apple.com/documentation/swiftui/proposedviewsize/infinity>):
  > "A size proposal that contains infinity in both dimensions."
  >
  > "Both dimensions contain infinity in this size proposal. Subviews of a custom
  > layout return their maximum size when you propose this value using the
  > `dimensions(in:)` method. A custom layout should also return its maximum size
  > from the `sizeThatFits(proposal:subviews:cache:)` method for this value."

The same three probes are restated from the container's side in
`Layout.sizeThatFits(proposal:subviews:cache:)`
(<https://developer.apple.com/documentation/swiftui/layout/sizethatfits(proposal:subviews:cache:)>):

> "The parent might call this method more than once during a layout pass with
> different proposed sizes to test the flexibility of the container, using
> proposals like:
>
> - The `zero` proposal; respond with the layout's minimum size.
> - The `infinity` proposal; respond with the layout's maximum size.
> - The `unspecified` proposal; respond with the layout's ideal size.
>
> The parent might also choose to test flexibility in one dimension at a time.
> For example, a horizontal stack might propose a fixed height and an infinite
> width, and then the same height with a zero width."

And `replacingUnspecifiedDimensions(by:)`
(<https://developer.apple.com/documentation/swiftui/proposedviewsize/replacingunspecifieddimensions(by:)>):

> "Creates a new proposal that replaces unspecified dimensions in this proposal
> with the corresponding dimension of the specified size."
>
> ```swift
> func replacingUnspecifiedDimensions(by size: CGSize = CGSize(width: 10, height: 10)) -> CGSize
> ```
>
> **size**: "A set of concrete values to use for the size proposal in place of
> any unspecified dimensions. The default value is `10` for both dimensions."
>
> Return value: "A new, fully specified size proposal."
>
> Discussion: "Use the default value to prevent a flexible view from
> disappearing into a zero-sized frame, and ensure the unspecified value remains
> visible during debugging."

Note the documented default is **10 × 10**, not zero and not the parent's size.
That matters for Q5: calling `replacingUnspecifiedDimensions()` with no argument
in a scroll-view wrapper answers 10pt for any unspecified axis, which is almost
never what you want for the *height* of a table.

---

## Q4. A view may report a size larger than the proposal; SwiftUI does not clip

**Source:** <https://developer.apple.com/documentation/swiftui/view/clipped(antialiased:)>

> "Use the `clipped(antialiased:)` modifier to hide any content that extends
> beyond the layout bounds of the shape.
>
> By default, a view's bounding frame is used only for layout, so any content
> that extends beyond the edges of the frame is still visible."

The example in that same discussion is exactly the overflow case: a `Text` with
`.fixedSize()` inside `.frame(width: 175, height: 100)`, which renders wider
than the frame until `.clipped()` is applied.

**Source (proposal is a proposal, not a constraint):**
<https://developer.apple.com/documentation/swiftui/proposedviewsize>

> "During layout in SwiftUI, views choose their own size, but they do that in
> response to a size proposal from their parent view."

And WWDC22 session 10056, *Compose custom layouts with SwiftUI*
(<https://developer.apple.com/videos/play/wwdc2022/10056/>):

> "Remember, views pick their own size in SwiftUI, so my layout container will
> get the size that it asks for."

So: the child's returned size wins; the parent places it anyway; nothing clips
it unless an ancestor applies `clipped()`, a `ScrollView`, or another
clipping container. This is the mechanism by which a 430pt-wide representable
inside a 320pt slot renders overflowing and gets cut by whatever ancestor
happens to clip.

Two more documented confirmations that overflow is normal and unclipped:

- `frame(width:height:alignment:)`
  (<https://developer.apple.com/documentation/swiftui/view/frame(width:height:alignment:)>):
  > "In the example above, the text is positioned at the top, leading corner of
  > the frame. If the text is taller than the frame, its bounds may extend beyond
  > the bottom of the frame's bounds."

- `fixedSize(horizontal:vertical:)`
  (<https://developer.apple.com/documentation/swiftui/view/fixedsize(horizontal:vertical:)>):
  > "This can result in the view exceeding the parent's bounds, which may or may
  > not be the effect you want."

**What the parent does with an overflowing child.** For a custom `Layout`, you
place the child yourself; `LayoutSubview.place(at:anchor:proposal:)` is given an
anchor point and the child draws at *its own* chosen size around that anchor,
whatever the bounds are. The `Layout` docs describe `bounds` only as "The region
that the container view's parent allocates to the container view" and instruct
you to "Place all the container's subviews within the region"
(<https://developer.apple.com/documentation/swiftui/layout/placesubviews(in:proposal:subviews:cache:)>) —
placement is a position, not a clip. Nothing in the `Layout` documentation gives
the container any way to *force* a subview to a size.

**NOT VERIFIED:** I found no Apple statement that a `Layout` container clips
overflowing subviews, and no statement that it does not. The `clipped()` wording
("By default, a view's bounding frame is used only for layout, so any content
that extends beyond the edges of the frame is still visible") is the general
rule and is the closest primary source.

Also relevant, from `LayoutSubview.place(at:anchor:proposal:)`
(<https://developer.apple.com/documentation/swiftui/layoutsubview/place(at:anchor:proposal:)>):

> "**proposal**: A proposed size for the subview. In SwiftUI, views choose their
> own size, but can take a size proposal from their parent view into account when
> doing so."
>
> "Include a proposed size that the subview can take into account when sizing
> itself."

"can take into account" — the container has no way to compel a size.

---

## Q5. The practical pattern: making the wrapped `NSScrollView` take the proposed width

### The short answer, and what it rests on

There is **no Apple-documented pattern** for this. I searched Apple's SwiftUI
reference, the WWDC22 sessions on custom layout (10056) and on AppKit interop
(10075), and developer.apple.com forum threads, and found no Apple guidance on
wrapping a scrolling AppKit view in a representable.

What Apple *does* document forces the shape of the fix:

1. The composite view's size is exactly what `sizeThatFits` returns.
   <https://developer.apple.com/documentation/swiftui/nsviewrepresentable/sizethatfits(_:nsview:context:)>:
   > "SwiftUI views choose their own size, so one of the values returned from
   > this function will always be used as the actual size of the composite view."

2. `nil` hands the decision to an algorithm Apple does not describe (Q1/Q2).

Therefore: **implement `sizeThatFits` and return the proposed width.** That is
the only documented lever that puts 320 on the `NSScrollView`'s frame. No
ancestor modifier can do it, because:

- `frame(width:height:)` still lets the child overflow ("its bounds may extend
  beyond the bottom of the frame's bounds" — quoted in Q4). The frame *view*
  reports 320 to its parent, but the scroll view is still 430 wide and still has
  nothing to scroll.
- The flexible frame is even more explicit that the frame's own size is
  independent of the child's:
  <https://developer.apple.com/documentation/swiftui/view/frame(minwidth:idealwidth:maxwidth:minheight:idealheight:maxheight:alignment:)>
  > "If both constraints are specified in a dimension, the frame unconditionally
  > adopts the size proposed for it, clamped to the constraints."
  >
  > "The size proposed to this view is the size proposed to the frame, limited by
  > any constraints specified, and with any ideal dimensions specified replacing
  > any corresponding unspecified dimensions in the proposal."

  So `.frame(maxWidth: .infinity)` fixes what the *ancestor* sees, and changes
  nothing about the child's chosen size. It hides the symptom in the parent's
  arithmetic while the scroll view stays too wide.
- `.clipped()` hides the overflow and still leaves the scroll view unable to
  scroll, because its clip view is as wide as its document view.

### Is `proposal.replacingUnspecifiedDimensions()` "the recommended shape"?

**Not recommended by Apple — Apple never mentions it in the representable
context.** Its documentation is entirely about custom layouts and about
debugging:

<https://developer.apple.com/documentation/swiftui/proposedviewsize/replacingunspecifieddimensions(by:)>

> "Creates a new proposal that replaces unspecified dimensions in this proposal
> with the corresponding dimension of the specified size."
>
> "Use the default value to prevent a flexible view from disappearing into a
> zero-sized frame, and ensure the unspecified value remains visible during
> debugging."

It is nonetheless the right building block, with two caveats that come straight
out of the wording:

- **It only replaces `nil`.** The name and the abstract say "unspecified
  dimensions"; `ProposedViewSize.width` documents `nil` as "an unspecified width
  proposal". An `.infinity` proposal is *specified*, so it passes through
  untouched, and returning an infinite `CGSize` from `sizeThatFits` would hand
  SwiftUI an infinite composite size. You must clamp `.infinity` yourself.
- **The default substitution is 10 × 10** ("The default value is `10` for both
  dimensions"), documented as a debugging aid. Calling it bare in a table
  wrapper answers 10pt for any axis SwiftUI leaves unspecified. Pass your own
  ideal size instead: `proposal.replacingUnspecifiedDimensions(by: idealSize)`.

### What Apple says you should answer for each proposal

The vocabulary is documented for `Layout` containers, and the identical
vocabulary is what a representable is being asked in
`sizeThatFits(_:nsView:context:)` (same `ProposedViewSize` type, same "may be
called more than once with different proposed sizes" discussion):

<https://developer.apple.com/documentation/swiftui/proposedviewsize>

> - The zero proposal; the view responds with its minimum size.
> - The infinity proposal; the view responds with its maximum size.
> - The unspecified proposal; the view responds with its ideal size.

**NOT VERIFIED:** Apple states those three rules for `Layout` conformances and
for `dimensions(in:)` on subviews. I could not find Apple restating them for
`NSViewRepresentable.sizeThatFits`. Applying them there is a reasonable
inference from the shared type and the shared "called more than once with
different proposed sizes" language, not a quoted rule.

For a concrete proposal (the 320pt case), the documented answer is the one the
whole system rests on: the proposal is an offer and you answer it. Returning the
proposed width is what makes the composite view 320pt wide, which sets the
`NSScrollView`'s frame to 320pt, which makes its clip view narrower than its
document view, which is the AppKit precondition for scrolling.

### The AppKit half

`NSViewRepresentable`
(<https://developer.apple.com/documentation/swiftui/nsviewrepresentable>):

> "SwiftUI fully controls the layout of the AppKit view using the view's `frame`
> and `bounds` properties. Don't directly set these layout-related properties on
> the view managed by an `NSViewRepresentable` instance from your own code
> because that conflicts with SwiftUI and results in undefined behavior."

So the `NSScrollView`'s own frame is SwiftUI's to set (via your `sizeThatFits`
answer), while the *document view*'s width is yours — a document view pinned to
the clip view's width can never scroll horizontally regardless of what
`sizeThatFits` returns.

**NOT VERIFIED:** I found no Apple documentation on how an `NSScrollView`'s
Auto Layout `fittingSize` interacts with SwiftUI's default representable sizing.
For reference, `NSView.fittingSize`
(<https://developer.apple.com/documentation/appkit/nsview/fittingsize>) is:
> "The minimum size of the view that satisfies the constraints it holds."
>
> "AppKit sets this property to the best size available for the view,
> considering all of the constraints it and its subviews hold and satisfying a
> preference to make the view as small as possible."

That is Auto Layout's compressed size, not "the size the parent offered". Using
it as your answer means the representable reports content size, which is the
430pt behaviour restated. See Q6.

### Reverse-engineered accounts (NOT primary sources, pre-`sizeThatFits`)

Recorded here only so nobody re-derives them and mistakes them for documentation.

- Andy Finnell, "UIViewRepresentable doesn't respect intrinsicContentSize
  invalidation", 2020-08-22
  (<https://losingfight.com/blog/2020/08/22/uiviewrepresentable-doesnt-respect-intrinsiccontentsize-invalidation/>):
  > "During SwiftUI layout, what `UIViewRepresentable` does is ask the `UIView`
  > for its intrinsic content size before it has set the `UIView`'s frame. It
  > then takes the minimum of the available size from the superview and the
  > `UIView`'s `intrinsicContentSize`, and sets that as the `UIView`'s `frame`."

  The author states this was found by investigation, not from documentation, and
  reports that Apple DTS told him there is "no supported way" to get the
  behaviour he wanted. It predates `sizeThatFits` (macOS 13 / iOS 16) by two
  years and describes UIKit. **Do not treat it as the current rule.**

- Natalia Panferova, "Provide custom size for UIViews wrapped in
  UIViewRepresentable", 2022-11-29
  (<https://nilcoalescing.com/blog/CustomSizeForUIViewsWrappedInUIViewRepresentable/>):
  > "If we return `nil` or don't define this method at all, the system will
  > fallback to the default sizing algorithm."

  This is a restatement of Apple's own sentence; the article does not say what
  the default algorithm is either, and does not mention
  `replacingUnspecifiedDimensions`.

- Samuel Défago, "Understanding SwiftUI Layout Behaviors", 2021-06-03
  (<https://defagos.github.io/understanding_swiftui_layout_behaviors/>) — often
  cited for this question, but it explicitly declines to cover it:
  > "Special considerations are required when considering the sizing behavior of
  > views implemented with `UIViewRepresentable` or
  > `UIViewControllerRepresentable`. Such considerations are outside the scope of
  > this article and will be discussed in a separate article."

I did not find that separate article.

---

## Q6. Answering only one axis

### Confirmed: there is no per-axis "unspecified" in the return value

The declaration is `-> CGSize?`
(<https://developer.apple.com/documentation/swiftui/nsviewrepresentable/sizethatfits(_:nsview:context:)>):

```swift
func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: Self.NSViewType,
    context: Self.Context
) -> CGSize?
```

`CGSize` has two non-optional `CGFloat` fields. The optionality is on the whole
`CGSize`, so the choice is all-or-nothing: either you answer both axes, or you
return `nil` and Apple's undocumented default answers both. **Your premise is
correct — there is no "unspecified" you can put in one axis of the returned
size.** Contrast `ProposedViewSize`, whose `width`/`height` *are* `CGFloat?`
precisely so that the *input* can be unspecified per axis
(<https://developer.apple.com/documentation/swiftui/proposedviewsize/width>:
"A value of `nil` represents an unspecified width proposal").

### Documented guidance on what to return for the axis you do not want to control

**NOT VERIFIED / NOT DOCUMENTED.** I found no Apple guidance addressing this.

The mechanism Apple *does* document, which is the substitute for a per-axis
opt-out, is that the method is a *probe* and is asked repeatedly:

> "This method may be called more than once with different proposed sizes during
> the same layout pass."
> — <https://developer.apple.com/documentation/swiftui/nsviewrepresentable/sizethatfits(_:nsview:context:)>

and, from the `Layout` side, why:

> "The parent might call this method more than once during a layout pass with
> different proposed sizes to test the flexibility of the container… The parent
> might also choose to test flexibility in one dimension at a time. For example,
> a horizontal stack might propose a fixed height and an infinite width, and then
> the same height with a zero width."
> — <https://developer.apple.com/documentation/swiftui/layout/sizethatfits(proposal:subviews:cache:)>

So flexibility in an axis is expressed *across* answers, not inside one. A view
that is flexible in width answers small for a small proposal and large for a
large proposal; a view with a fixed ideal answers the same number every time.
A `sizeThatFits` that ignores `proposal` and returns `nsView.fittingSize` in an
axis is, by that definition, declaring itself **inflexible** in that axis — it
answers the same number for the zero, infinity and concrete proposals. That is
exactly the reported bug: an embedded scroll view answering `fittingSize.height`
reports one fixed tall height for every proposal, gets that height, and never
has a viewport shorter than its content, so it never scrolls vertically.

The documented lever for the axis you genuinely want the *parent* to fix is on
the SwiftUI side, not in the return value:

- `fixedSize(horizontal:vertical:)`
  (<https://developer.apple.com/documentation/swiftui/view/fixedsize(horizontal:vertical:)>):
  > "Fixes this view at its ideal size in the specified dimensions."
  >
  > "the fixing of the axes can be optionally specified in one or both
  > dimensions"

  This is *per axis*, and it works by proposing `nil` in the fixed axis — which
  your `sizeThatFits` then sees as an unspecified proposal and answers with its
  ideal.

- The flexible frame's documented rule (quoted in Q5) also operates per
  dimension: "If no minimum or maximum constraint is specified in a given
  dimension, the frame adopts the sizing behavior of its child in that
  dimension."

**Derived, not quoted:** the shape that expresses "I control neither axis, I
just take what I'm offered" is to answer the proposal in both axes, substituting
your own ideal for `nil` and your own maximum for `.infinity`. Apple documents
each of those three obligations separately (concrete = an offer you answer,
`nil` = ideal, `.infinity` = maximum) but never assembles them into a
representable example.

---

## Q7. Mutating observable state from inside `Layout.sizeThatFits` / `placeSubviews`

### What Apple documents

Apple never writes "do not cause side effects in layout". What it documents is
three facts that make side effects there unsound:

1. **The methods are probes and run an unpredictable number of times per pass.**
   <https://developer.apple.com/documentation/swiftui/layout/sizethatfits(proposal:subviews:cache:)>:
   > "The parent might call this method more than once during a layout pass with
   > different proposed sizes to test the flexibility of the container, using
   > proposals like: the `zero` proposal…; the `infinity` proposal…; the
   > `unspecified` proposal…"

   And the parameter doc restates it:
   > "**proposal**: A size proposal for the container. The container's parent
   > view that calls this method might call the method more than once with
   > different proposals to learn more about the container's flexibility before
   > deciding which proposal to use for placement."

   A side effect in `sizeThatFits` therefore fires on probe proposals. If you
   record a row count from the proposed height, you may be recording the answer
   to `.zero`, to `.infinity`, or to a trial height that was never used — which
   is precisely the shape of the measured "row band computed two rows short"
   defect.

2. **SwiftUI may skip the call entirely and reuse a previous result.**
   <https://developer.apple.com/documentation/swiftui/layout/makecache(subviews:)>:
   > "Many layout types don't need a cache, because SwiftUI automatically reuses
   > both the results of calls into the layout and the values that the layout
   > reads from its subviews."

   A side effect that lives in a method whose *result* SwiftUI is entitled to
   memoize is a side effect that is entitled not to happen.

3. **Apple explicitly demands consistency-for-given-inputs across the layout
   methods.** This is the nearest thing to a written purity requirement:
   <https://developer.apple.com/documentation/swiftui/layout/placesubviews(in:proposal:subviews:cache:)>:
   > "Be sure that you use computations during placement that are consistent
   > with those in your implementation of other protocol methods for a given set
   > of inputs. For example, if you add spacing during placement, make sure your
   > implementation of `sizeThatFits(proposal:subviews:cache:)` accounts for the
   > extra space. Similarly, if the sizing method returns different values for
   > different size proposals, make sure the placement method responds to its
   > `proposal` input in the same way."

   "For a given set of inputs" is a function-of-its-arguments requirement. State
   you mutate and later read is an input that is not in the argument list.

4. **The sanctioned mutable channel is the `cache`, and only the cache.**
   <https://developer.apple.com/documentation/swiftui/layout/makecache(subviews:)>:
   > "You can optionally use a cache to preserve calculated values across calls
   > to a layout container's methods."
   >
   > "The methods of the `Layout` protocol that can access the cache take the
   > cache as an in-out parameter, which enables you to modify the cache anywhere
   > that you can read it."
   >
   > "Only implement a cache if profiling shows that it improves performance."

   The cache is scoped to the layout instance and invalidated by SwiftUI
   (`updateCache(_:subviews:)`), which is exactly what app-visible `@State` is
   not.

**NOT VERIFIED:** I could not find any Apple documentation, release note or WWDC
session that states the rule directly, names the resulting invalidation loop, or
says what happens if you write to `@State`/`@Observable` from a layout method.
WWDC21 "Demystify SwiftUI" (10022) and WWDC23 "Demystify SwiftUI performance"
(10160) do not cover it. The runtime message developers see — "Modifying state
during view update, this will cause undefined behavior" — appears only in
developer-forums threads, not in Apple's documentation, so I cannot quote it
from a primary source.

### The best non-Apple source

Javier Nigro, "The SwiftUI Layout Protocol — Part 2", The SwiftUI Lab,
2022-09-12 (<https://swiftui-lab.com/layout-protocol-part-2/>):

> "It is a well known fact that we must not update a view's state during layout."

> "`sizeThatFits` and `placeSubviews` are part of the layout process."

and, for the case where you must:

> "if we are going to 'cheat' with the technique described in the previous
> section, we must enqueue the update with DispatchQueue"

```swift
DispatchQueue.main.async {
    subview[Rotation.self]?.wrappedValue = .radians(angle)
}
```

The article also warns that a binding update applied from layout must not itself
affect layout, or it loops. This is a well-regarded write-up but it is a blog,
and its "well known fact" is asserted rather than sourced to Apple.

### The documented alternative for "layout told me a number, now update state"

`onGeometryChange(for:of:action:)`
(<https://developer.apple.com/documentation/swiftui/view/ongeometrychange(for:of:action:)>):

> "Adds an action to be performed when a value, created from a geometry proxy,
> changes."
>
> "The geometry of a view can change frequently, especially if the view is
> contained within a ScrollView and that scroll view is scrolling. You should
> avoid updating large parts of your app whenever the scroll geometry changes."

Its own example performs an app-visible side effect
(`video.updateAutoplayingState(isVisible:)`) from geometry — i.e. Apple ships a
modifier whose whole job is "react to geometry with a side effect", separate
from the layout methods. That is the documented place for the effect, even
though Apple does not say in so many words "and not inside `Layout`".

---

## Summary of what could NOT be verified from a primary source

1. **What "the default sizing algorithm" is** for an `NSViewRepresentable` with
   no `sizeThatFits`. Apple names it and never defines it. Whether it consults
   `intrinsicContentSize`, `fittingSize`, Auto Layout, or the proposal is
   undocumented. (Q1, Q2)
2. **What SwiftUI does when `intrinsicContentSize` is `noIntrinsicMetric`** in
   one or both axes for a representable. Undocumented. (Q2)
3. **Whether the zero/infinity/unspecified answer rules apply to
   `NSViewRepresentable.sizeThatFits`.** Documented for `Layout`; only inferable
   for representables. (Q5, Q6)
4. **Any Apple-recommended pattern for a representable-wrapped scroll view**, and
   specifically whether `proposal.replacingUnspecifiedDimensions()` is the
   blessed shape. No Apple source mentions it in that context. (Q5)
5. **Guidance on answering only one axis** from `sizeThatFits`, or on what to
   return for the axis you do not want to control. Undocumented. (Q6)
6. **An Apple statement that mutating state from `Layout` methods is illegal**,
   or a description of the resulting invalidation loop. Only the
   consistency-for-given-inputs sentence and the memoization sentence exist.
   (Q7)
7. **Whether a `Layout` container clips an overflowing subview.** Only the
   general `clipped()` rule is documented. (Q4)

---

## Sources

### Apple primary (documentation)

- NSViewRepresentable — <https://developer.apple.com/documentation/swiftui/nsviewrepresentable>
- NSViewRepresentable.sizeThatFits(_:nsView:context:) — <https://developer.apple.com/documentation/swiftui/nsviewrepresentable/sizethatfits(_:nsview:context:)>
- …default-implementation variant — <https://developer.apple.com/documentation/swiftui/nsviewrepresentable/sizethatfits(_:nsview:context:)-fuqx>
- UIViewRepresentable — <https://developer.apple.com/documentation/swiftui/uiviewrepresentable>
- UIViewRepresentable.sizeThatFits(_:uiView:context:) — <https://developer.apple.com/documentation/swiftui/uiviewrepresentable/sizethatfits(_:uiview:context:)>
- ProposedViewSize — <https://developer.apple.com/documentation/swiftui/proposedviewsize>
- ProposedViewSize.width — <https://developer.apple.com/documentation/swiftui/proposedviewsize/width>
- ProposedViewSize.unspecified — <https://developer.apple.com/documentation/swiftui/proposedviewsize/unspecified>
- ProposedViewSize.zero — <https://developer.apple.com/documentation/swiftui/proposedviewsize/zero>
- ProposedViewSize.infinity — <https://developer.apple.com/documentation/swiftui/proposedviewsize/infinity>
- ProposedViewSize.replacingUnspecifiedDimensions(by:) — <https://developer.apple.com/documentation/swiftui/proposedviewsize/replacingunspecifieddimensions(by:)>
- Layout — <https://developer.apple.com/documentation/swiftui/layout>
- Layout.sizeThatFits(proposal:subviews:cache:) — <https://developer.apple.com/documentation/swiftui/layout/sizethatfits(proposal:subviews:cache:)>
- Layout.placeSubviews(in:proposal:subviews:cache:) — <https://developer.apple.com/documentation/swiftui/layout/placesubviews(in:proposal:subviews:cache:)>
- Layout.makeCache(subviews:) — <https://developer.apple.com/documentation/swiftui/layout/makecache(subviews:)>
- LayoutSubview.sizeThatFits(_:) — <https://developer.apple.com/documentation/swiftui/layoutsubview/sizethatfits(_:)>
- LayoutSubview.place(at:anchor:proposal:) — <https://developer.apple.com/documentation/swiftui/layoutsubview/place(at:anchor:proposal:)>
- Composing custom layouts with SwiftUI (sample) — <https://developer.apple.com/documentation/swiftui/composing-custom-layouts-with-swiftui>
- View.clipped(antialiased:) — <https://developer.apple.com/documentation/swiftui/view/clipped(antialiased:)>
- View.frame(width:height:alignment:) — <https://developer.apple.com/documentation/swiftui/view/frame(width:height:alignment:)>
- View.frame(minWidth:idealWidth:maxWidth:…) — <https://developer.apple.com/documentation/swiftui/view/frame(minwidth:idealwidth:maxwidth:minheight:idealheight:maxheight:alignment:)>
- View.fixedSize(horizontal:vertical:) — <https://developer.apple.com/documentation/swiftui/view/fixedsize(horizontal:vertical:)>
- View.onGeometryChange(for:of:action:) — <https://developer.apple.com/documentation/swiftui/view/ongeometrychange(for:of:action:)>
- NSView.intrinsicContentSize — <https://developer.apple.com/documentation/appkit/nsview/intrinsiccontentsize>
- NSView.noIntrinsicMetric — <https://developer.apple.com/documentation/appkit/nsview/nointrinsicmetric>
- NSView.fittingSize — <https://developer.apple.com/documentation/appkit/nsview/fittingsize>
- AppKit integration (collection) — <https://developer.apple.com/documentation/swiftui/appkit-integration>
- SwiftUI updates — <https://developer.apple.com/documentation/Updates/SwiftUI> (checked; no hits)
- Xcode 14 release notes — <https://developer.apple.com/documentation/xcode-release-notes/xcode-14-release-notes> (checked; no hits)

### Apple primary (WWDC)

- WWDC22 10056, *Compose custom layouts with SwiftUI* — <https://developer.apple.com/videos/play/wwdc2022/10056/>
- WWDC22 10075, *Use SwiftUI with AppKit* — <https://developer.apple.com/videos/play/wwdc2022/10075/> (covers hosting views/`NSHostingSizingOptions`, i.e. SwiftUI-inside-AppKit; nothing on representable sizing)
- WWDC21 10022, *Demystify SwiftUI* — <https://developer.apple.com/videos/play/wwdc2021/10022/> (checked for side-effect guidance; none)
- WWDC23 10160, *Demystify SwiftUI performance* — <https://developer.apple.com/videos/play/wwdc2023/10160/> (checked for layout side-effect guidance; none)

### Secondary (clearly marked as such in the text above)

- The SwiftUI Lab, *The SwiftUI Layout Protocol — Part 2*, Javier Nigro, 2022-09-12 — <https://swiftui-lab.com/layout-protocol-part-2/>
- The SwiftUI Lab, *Part 1* — <https://swiftui-lab.com/layout-protocol-part-1/>
- Nil Coalescing, Natalia Panferova, 2022-11-29 — <https://nilcoalescing.com/blog/CustomSizeForUIViewsWrappedInUIViewRepresentable/>
- Safe from the Losing Fight, Andy Finnell, 2020-08-22 — <https://losingfight.com/blog/2020/08/22/uiviewrepresentable-doesnt-respect-intrinsiccontentsize-invalidation/>
- Samuel Défago, 2021-06-03 — <https://defagos.github.io/understanding_swiftui_layout_behaviors/> (declines the topic)

### Checked and found unhelpful

- Apple forums 767264 (NSTextView horizontal scroll in NSViewRepresentable) — no Apple engineer reply, no `sizeThatFits`.
- Apple forums 815705 (intrinsic/fitting size not propagating to hosting controller, Feb 2026) — zero replies.
- Apple forums 714199 — unrelated (representables must be value types).
- Swift Forums 65247 — question only, moderator redirected to Apple's forums.
- STTextView discussion #83 — <https://github.com/krzyzanowskim/STTextView/discussions/83>; the maintainer's conclusion is "There's no good SwiftUI API for making incremental updates from the State variable", and the attempted fix routes height through `GeometryReader` + `.frame(height:)` rather than `sizeThatFits`.
- fatbobman's layout series — restates that iOS 16 added `sizeThatFits` "consistent with the logic of the Layout protocol", no implementation guidance.


