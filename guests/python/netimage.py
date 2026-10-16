"""The network images affordance scene (tools/scenes/netimage.steps;
docs/network-images-plan.md §5). No HTTP: each "download" is a job a worker
thread holds until a click releases it, background.steps' principle. See
guests/rust/netimage.rs."""

import queue
import sys
import threading
from dataclasses import dataclass

import kaya


@dataclass
class Track:
    title: str
    art_url: str
    art: bytes
    phase: kaya.ImagePhase


ROWS = 300


@dataclass
class Job:
    """A "download" the worker holds: the live image's when `key` is None,
    and `data` None when it fails."""

    key: str | None
    url: str
    data: bytes | None


app = kaya.App()
covers = [kaya.asset(name).bytes() for name in
          ("covers/cover-600.jpg", "covers/cover-320.jpg", "covers/cover-1000.jpg")]
jobs: queue.Queue[list[Job]] = queue.Queue()


def land(job: Job):
    if job.key is not None:
        tracks.patch(job.key, when={"art_url": job.url}, art=job.data,
                     phase=kaya.ImagePhase.SHOWN)
    elif job.data is None:
        phase.set(kaya.ImagePhase.FAILED)
    else:
        art.set(job.data)
        phase.set(kaya.ImagePhase.SHOWN)


def worker():
    while True:
        for job in jobs.get():
            app.post(land, job)


live: Job | None = Job(None, "", covers[0])
pending: list[Job] = []
needed: set[str] = set()
ever: set[str] = set()
twice: str | None = None


def on_release():
    global live
    if live is not None:
        jobs.put([live])
        live = None


def on_refresh():
    global live
    live = Job(None, "", covers[1])
    phase.set(kaya.ImagePhase.LOADING)


def on_junk():
    art.set(b"not an image")
    phase.set(kaya.ImagePhase.SHOWN)


def on_fail():
    global live
    live = Job(None, "", None)
    art.set(b"")
    phase.set(kaya.ImagePhase.LOADING)


def on_needed(row):
    global twice
    key = row.key
    if key in needed and twice is None:
        twice = key
    needed.add(key)
    ever.add(key)
    i = int(key[1:])
    pending.append(Job(key, f"u/{i}", covers[i % 3]))
    band.set("band: partial" if len(ever) < ROWS else f"band: {len(ever)}")
    again.set(f"again: {twice or 'none'}")


def on_released(row):
    needed.discard(row.key)
    pending[:] = [job for job in pending if job.key != row.key]
    released.set("released: some")


def on_rows():
    needed.clear()
    jobs.put(pending[:])
    pending.clear()


def on_delete():
    tracks.remove("t299")


def on_retarget():
    pending.insert(0, Job("t298", "u/298b", covers[2]))
    tracks.patch("t298", art_url="u/298b")


with app.window(title="netimage", width=820, height=640):
    art = kaya.signal(b"")
    phase = kaya.signal(kaya.ImagePhase.LOADING)
    band = kaya.signal("band: -")
    released = kaya.signal("released: none")
    again = kaya.signal("again: none")
    tracks = kaya.collection(Track)
    with kaya.column():
        with kaya.column():
            kaya.image(art, fit=kaya.Fit.COVER, phase=phase) \
                .max_width(96).max_height(96).a11y_id("cover").a11y_label("Cover")
            for pair in ((("release", on_release), ("refresh", on_refresh)),
                         (("junk", on_junk), ("fail", on_fail))):
                with kaya.row():
                    for name, fn in pair:
                        kaya.button(name, on_click=fn).a11y_id(name)
            with kaya.row():
                for name, fn in (("rows", on_rows), ("delete", on_delete),
                                 ("retarget", on_retarget)):
                    kaya.button(name, on_click=fn).a11y_id(name)
            kaya.label(bind=band).a11y_id("band")
            kaya.label(bind=released).a11y_id("released")
            kaya.label(bind=again).a11y_id("again")
        for track in tracks.columns("Art", "Title", grow=1, a11y_id="tracks"):
            with kaya.row():
                kaya.image(track.art, fit=kaya.Fit.COVER, phase=track.phase,
                           shape=kaya.Shape.ROUNDED,
                           on_needed=on_needed, on_released=on_released) \
                    .max_width(40).max_height(40).a11y_id("art")
                kaya.label(bind=track.title)
    for i in range(ROWS):
        tracks.insert(f"t{i:03}", Track(title=f"Track {i}", art_url=f"u/{i}",
                                         art=b"", phase=kaya.ImagePhase.LOADING))

threading.Thread(target=worker, name="netimage-worker", daemon=True).start()
sys.exit(app.run())
