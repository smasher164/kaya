"""Backend sentences a LEG PARSES, in the one place both sides read.

A diagnostic is prose until something greps it, and then it is an
interface with nothing marking it as one. MEASURED 2026-09-08: the GTK
identity lowering's own sentence was reworded to carry a scale note, and
tools/linux/identity-wayland-witness.sh — which greps it to tell a
lowering that RAN and cannot be read back on wayland from one that was
SKIPPED, the difference between a version note and a carve-out
(docs/app-identity-plan.md I4a) — correctly reported a skip and reddened
the leg.

So the phrase lives here, the witness reads it from here, and
tools/check-app-identity.py holds the backend to still printing it. The
gate rather than tools/check-gtk.py because check-gtk needs docker and
sits OUTSIDE the fast sweep: a wall you have to remember to walk into is
barely a wall (CLAUDE.md invariant 3).
"""

# crates/kaya/src/gtk.rs, IdentityIcon::lowering's Texture arm. Reword
# AROUND it, never through it.
GTK_ICON_LOWERED = "gdk_toplevel_set_icon_list with it on window"
