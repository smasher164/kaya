"""The references scene (tools/scenes/references.steps,
docs/restoration-plan.md SR11, SR12): a picked file's durable reference
rides the session store across a relaunch and redeems for its bytes; a
foreign token and a deleted file are refused by name."""

import os
import sys
import tempfile
import threading

import kaya

app = kaya.App()

folder = os.path.join(tempfile.gettempdir(), f"kaya-refs-{os.getpid()}")
os.makedirs(folder, exist_ok=True)
with open(os.path.join(folder, "picked.txt"), "wb") as f:
    f.write(b"picked bytes")
with open(os.path.join(folder, "decoy.txt"), "wb") as f:
    f.write(b"decoy")

saved = kaya.app_session().get("doc", "")


def read_back(token: str) -> str:
    """The bytes a token redeems for, or the refusal's branch; the
    sentence goes to stderr, where the leg log keeps it."""
    try:
        redeemed = kaya.redeem(token)
    except kaya.KayaReferenceError as e:
        print(f"references: {e}", file=sys.stderr)
        return e.refusal
    opened, _ = redeemed.file.open()
    with opened:
        return "redeemed: " + opened.read().decode("utf-8")


def reader(token: str) -> None:
    def work() -> None:
        said = read_back(token)
        app.post(status.set, said)
    threading.Thread(target=work, name="references-reader").start()


def picked(files) -> None:
    if not files:
        status.set("cancelled")
        return
    try:
        kaya.app_session().set("doc", files[0].reference())
        status.set("minted")
    except kaya.KayaReferenceError as e:
        print(f"references: {e}", file=sys.stderr)
        status.set(e.refusal)


def delete() -> None:
    try:
        path = kaya.redeem(saved).file.local_path
        if path is not None:
            os.remove(path)
    except kaya.KayaReferenceError:
        pass
    reader(saved)


with app.window(title="references"):
    status = kaya.signal("no reference" if not saved else "redeeming")
    with kaya.column():
        kaya.label(bind=status).a11y_id("status")
        kaya.button("pick", on_click=lambda: kaya.pick_file(
            filters=[("Text", "txt")], on_result=picked)).a11y_id("pick")
        kaya.button("foreign", on_click=lambda: reader(
            "kaya-ref1:beos:AAAA:00000000")).a11y_id("foreign")
        kaya.button("delete", on_click=delete).a11y_id("delete")

if saved:
    reader(saved)

sys.exit(app.run())
