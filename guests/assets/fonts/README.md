# Vendored fonts

`sora-wght.ttf` (upstream name Sora[wght].ttf — renamed because BRACKETS ARE GLOB CHARACTERS and nine guests plus lane scripts name this path; the OFL reserves the FAMILY name, not the filename) — SIL Open Font License 1.1 (`OFL.txt` beside it),
Reserved Font Name "Sora". Fetched UNMODIFIED from the canonical
Google Fonts repository (ofl/sora, 2026-08-16). A VARIABLE font on
purpose: one 108 KB file carries the whole wght 200..800 axis with
named instances, so every tier of each platform's type ramp resolves
to a real weight — a single static weight would faux-bold the heading
tiers, and the full static family would be megabytes. Chosen over the
(smaller) Figtree variable because Sora's name table carries ONE
family string; a legacy dual-name table is exactly the cross-lane
frozen-string hazard the bundled font exists to remove. The OFL's
Reserved Font Name term is why it ships whole: subsetting would be a
modification requiring a rename, and the family name IS the scene's
frozen observable.

Why it exists: the typeface scene requests these BYTES over the wire
blob channel, so the resolved family is the same one string ("Sora")
on every lane — expect_typeface stays byte-frozen with no per-lane
machinery, the register-then-resolve path is exercised on all five
platforms, and no platform preinstalls the family, so a failed
registration can never render as a false pass
(docs/styling-plan.md, Slice 2b).

## How to regenerate it

You do not, and that is the point. `sora-wght.ttf` is a VENDORED
upstream release, not something this tree produces: it is the variable
`Sora[wght].ttf` from the Sora repository, renamed only because square
brackets are glob characters. To take a newer one, download that
release, rename it, and check the name table still reports the family
`Sora` — the family string is the typeface scene's frozen observable, so
a release that renamed the family would turn `expect_typeface` red on
five lanes at once, which is exactly the signal you want.

Subsetting, instancing and any other transformation are REFUSED, not
merely unimplemented: the OFL's Reserved Font Name term makes a modified
file something that may not be called Sora, and the name is the thing
the scene reads.
