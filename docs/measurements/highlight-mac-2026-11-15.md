# The highlight mark's dynamic colour inside a TextKit 2 fragment (Mac) — measured 2026-11-15

For docs/highlight-plan.md §3 (H2's first item): a dynamic colour's `cgColor`,
read inside `NSTextLayoutFragment.draw(at:in:)`, resolves to the VIEW's
effective appearance, so `kaya.draw.mark` can carry one `NSColor(name:nil)`
whose provider picks the light or dark value, the route the code ground's
`quaternaryLabelColor` already takes.

**Method.** `highlight-mac-2026-11-15/probe.swift` (macOS 26.6.2, compiled with
`kaya_swiftc -O`): an offscreen `NSTextView(usingTextLayoutManager: true)` with
no window, a layout delegate returning a fragment subclass that fills the
`kaya.draw.mark` sub-range with the attribute's colour before `super.draw`, the
colour `NSColor(name:nil)` choosing `#F7E8AF` (aqua) or `#594C1A` (darkAqua).
The view's `appearance` is set, the view is rendered with `cacheDisplay`, and
the commonest pixel inside the marked word's box is read back. Three fresh
views (aqua, darkAqua, aqua), then ONE view switched aqua, darkAqua, aqua with
no other change between the renders.

**Result** (`highlight-mac-2026-11-15/out.txt`): every render's draw ran with
`NSAppearance.currentDrawing()` equal to the view's appearance, the `cgColor`
read inside the draw was the matching value (0.969,0.910,0.686 and
0.349,0.298,0.102), and the commonest pixel was `F7E8AF` light and `594C19`
dark (the dark value comes back one step off in blue, `1A` to `19`, through
the bitmap's colour conversion). The switched view redrew in the new
appearance each time with nothing invalidated by hand.

So the Mac arm needs no appearance observer for the mark: a dynamic colour in
the attribute is enough, as for the code ground and the document ink. A
pixel read of the mark (`expect_text_ground`) must allow one step per channel.
