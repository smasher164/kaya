"""The shapes scene (tools/scenes/shapes.steps; docs/styling-pass-plan.md
Y6): one picture clipped three ways, a wider one in a circle, and a stamped
avatar that is round while it loads. See guests/rust/shapes.rs."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Person:
    name: str
    face: bytes
    phase: kaya.ImagePhase


app = kaya.App()
art = kaya.asset("covers/cover-600.jpg").bytes()
photo = kaya.asset("images/photo.jpg").bytes()

with app.window(title="shapes", width=420, height=360):
    people = kaya.collection(Person)
    with kaya.column(spacing=16):
        with kaya.row(spacing=16):
            for name, shape in (("rect", kaya.Shape.RECT), ("rounded", kaya.Shape.ROUNDED),
                                ("circle", kaya.Shape.CIRCLE)):
                kaya.image(art, fit=kaya.Fit.COVER, shape=shape) \
                    .max_width(48).max_height(48).a11y_id(name)
            kaya.image(photo, shape=kaya.Shape.CIRCLE).max_width(48).max_height(48).a11y_id("wide")
        for person in people:
            with kaya.row():
                kaya.image(person.face, fit=kaya.Fit.COVER, phase=person.phase,
                           shape=kaya.Shape.CIRCLE).max_width(48).max_height(48).a11y_id("avatar")
                kaya.label(bind=person.name)
    people.insert("a1", Person(name="Ada", face=b"", phase=kaya.ImagePhase.LOADING))

sys.exit(app.run())
