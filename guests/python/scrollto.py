"""The scroll-to scene, Python port (tools/scenes/scrollto.steps): the app
scrolls a list of messages to a row by key (docs/scroll-to-plan.md),
opening at the newest one before the first layout, jumping to one on a
click, staying put on a key no row holds, and following its own send.
See guests/rust/scrollto.rs."""

import sys
from dataclasses import dataclass

import kaya


@dataclass
class Message:
    text: str


@dataclass
class Frame:
    name: str


app = kaya.App()
sent = 60
framed = 30


def on_jump():
    messages.container().scroll_to_row("m10")


def on_nowhere():
    messages.container().scroll_to_row("m999")


def on_send():
    global sent
    sent += 1
    messages.insert(f"m{sent}", Message(text=f"message {sent}"))
    count.set(f"{sent} messages")
    messages.container().scroll_to_row(f"m{sent}")


def on_frame():
    frames.container().scroll_to_row("f10")


def on_add_frame():
    global framed
    framed += 1
    frames.insert(f"f{framed}", Frame(name=f"frame {framed}"))


with app.window():
    messages = kaya.collection(Message)
    frames = kaya.collection(Frame)
    count = kaya.signal("60 messages")

    with kaya.column():
        kaya.label(bind=count).a11y_id("count")
        with kaya.row():
            kaya.button("jump", on_click=on_jump).a11y_id("jump")
            kaya.button("nowhere", on_click=on_nowhere).a11y_id("nowhere")
            kaya.button("send", on_click=on_send).a11y_id("send")
            kaya.button("frame", on_click=on_frame).a11y_id("frame")
            kaya.button("add frame", on_click=on_add_frame).a11y_id("add_frame")
        with kaya.scroll(grow=1) as list_scroll:
            # The For's own container is what a scroll_to_row addresses
            # (docs/scroll-to-plan.md S1): container() names it.
            for message in messages.rows(a11y_id="messages"):
                kaya.label(bind=message.text)
        list_scroll.a11y_id("list")
        # A filmstrip that runs sideways (docs/hscroll-plan.md): the same
        # scroll_to_row and follows_end, along its own axis.
        with kaya.scroll(axis=kaya.Axis.HORIZONTAL, follows_end=True) as strip:
            for frame in frames.rows(a11y_id="frames"):
                kaya.label(bind=frame.name)
            frames.container().axis(kaya.Axis.HORIZONTAL)
        strip.a11y_id("strip")

    for i in range(1, 31):
        frames.insert(f"f{i}", Frame(name=f"frame {i}"))
    for i in range(1, 61):
        messages.insert(f"m{i}", Message(text=f"message {i}"))
    messages.container().scroll_to_row("m60")

sys.exit(app.run())
