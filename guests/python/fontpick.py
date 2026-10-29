"""The font picker scene, Python port: guests/rust/fontpick.rs,
tools/scenes/fontpick.steps (docs/font-picker-plan.md §7)."""

import sys

import kaya

MONO = ["Menlo", "DejaVu Sans Mono", "Cascadia Mono", "Consolas", "Courier New",
        "Droid Sans Mono", "monospace"]
DOC = "bold run, italic run, plain run"


def words(weight, italic, width):
    return f"{weight} {'italic' if italic else 'upright'} {width}"


def light_family(faces):
    upright = [f.weight for f in faces if not f.italic and f.width == 5]
    italic = [f.weight for f in faces if f.italic and f.width == 5]
    if len(upright) < 3 or 700 not in upright:
        return None
    light = next((w for w in upright if w < 400 and w in italic), None)
    pair = next(((a, b) for a, b in zip(upright, upright[1:]) if a >= 500 and b > a + 1), None)
    if light is None or pair is None:
        return None
    return light, pair[0], pair[1]


def upright_only(faces):
    if not faces or any(f.italic for f in faces):
        return None
    return next((f.weight for f in faces if f.width == 5), None)


app = kaya.App()
state = {"queue": [], "light": None, "plain": None, "mono": None, "asked": None}


def on_families(families):
    state["mono"] = next((m for m in MONO if m in families), None)
    state["queue"] = list(reversed(families))
    if state["mono"] is not None:
        state["queue"].append(state["mono"])
    if state["queue"]:
        kaya.list_font_faces(state["queue"].pop())


def on_faces(family, faces):
    if family == state["mono"] and state["asked"] is None:
        face = next((f for f in faces if (f.weight, f.italic, f.width) == (700, False, 5)),
                    faces[0] if faces else None)
        if face is not None:
            state["asked"] = kaya.FontChoice(family, face.weight, face.italic, face.width)
    if state["light"] is None:
        found = light_family(faces)
        state["light"] = (family, found) if found else None
    if state["plain"] is None:
        found = upright_only(faces)
        state["plain"] = (family, found) if found is not None else None
    if state["light"] is None or state["plain"] is None:
        if state["queue"]:
            kaya.list_font_faces(state["queue"].pop())
        else:
            ready.set("faces: none suit")
        return
    lf, (lw, a, b) = state["light"]
    pf, pw = state["plain"]
    exact.family(lf).font_weight(lw)
    between.family(lf).font_weight(a + (b - a) // 2)
    synth.family(pf).font_weight(pw).font_italic(True)
    doc.family(lf).font_weight(lw)
    doc.set_document(kaya.Document(DOC).bold(range(0, 4)).italic(range(10, 16)))
    want[0].set(words(lw, False, 5))
    want[1].set(words(b, False, 5))
    want[2].set(f"{words(pw, True, 5)} synthesized")
    want[3].set(words(700, False, 5))
    want[4].set(words(lw, True, 5))
    c = state["asked"]
    if c is not None:
        pick.set(f"{words(c.weight, c.italic, c.width)} {c.family}")
        want[5].set(words(c.weight, c.italic, c.width))
    ready.set("faces: found")


def on_chosen(c):
    if c is None:
        picked.set("picked: cancelled")
        return
    chosen.family(c.family).font_weight(c.weight).font_italic(c.italic).font_width(c.width)
    if c == state["asked"]:
        picked.set("picked: as asked")
    else:
        picked.set(f"picked: {words(c.weight, c.italic, c.width)} {c.family}")


def on_pick():
    kaya.choose_font(code_only=True, faces=True, initial=state["asked"], on_result=on_chosen)


kaya.on_font_families(on_families)
kaya.on_font_faces(on_faces)

with app.window(title="fontpick"):
    ready = kaya.signal("faces: -")
    want = [kaya.signal("-") for _ in range(6)]
    pick = kaya.signal("-")
    picked = kaya.signal("picked: -")
    with kaya.column():
        kaya.label(bind=ready).a11y_id("ready")
        exact = kaya.label("Exact").a11y_id("exact")
        between = kaya.label("Between").a11y_id("between")
        synth = kaya.label("Slanted").a11y_id("synth")
        doc = kaya.textarea(rich=True).a11y_id("doc")
        chosen = kaya.label("Chosen").a11y_id("chosen")
        for signal, ident in zip(want, ["want_exact", "want_between", "want_synth", "want_bold",
                                        "want_italic", "want_pick"]):
            kaya.label(bind=signal).a11y_id(ident)
        kaya.label(bind=pick).a11y_id("pick")
        kaya.label(bind=picked).a11y_id("picked")
        with kaya.row():
            kaya.button("faces", on_click=kaya.list_font_families).a11y_id("faces")
            kaya.button("pick", on_click=on_pick).a11y_id("pick_button")

sys.exit(app.run())
