#!/usr/bin/env python3
"""Send one driver verb while FILMING the device with `simctl io
screenshot`, because the thing being measured — a permission prompt —
may live only for the duration of the verb.

  gesture.py <udid> <shots-dir> <stem> <seconds-after> <verb…>

Prints the response, then the list of shots taken. A shot every ~350ms
from before the request until `seconds-after` past the response.
"""
import pathlib
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import drive  # noqa: E402


def main():
    udid, shots, stem, after = (sys.argv[1], pathlib.Path(sys.argv[2]),
                                sys.argv[3], float(sys.argv[4]))
    verb = " ".join(sys.argv[5:])
    shots.mkdir(parents=True, exist_ok=True)
    stop = threading.Event()
    taken = []

    def film():
        i = 0
        t0 = time.monotonic()
        while not stop.is_set():
            p = shots / f"{stem}-{i:03d}.png"
            subprocess.run(["xcrun", "simctl", "io", udid, "screenshot",
                            str(p)], check=False, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
            taken.append((round(time.monotonic() - t0, 2), p.name))
            i += 1
            time.sleep(0.05)

    th = threading.Thread(target=film)
    th.start()
    time.sleep(0.6)
    t0 = time.monotonic()
    ok, body = drive.send(udid, verb, timeout=120)
    dur = round(time.monotonic() - t0, 2)
    time.sleep(after)
    stop.set()
    th.join()
    print(f"verb={verb!r} ok={ok} {dur}s")
    print(body)
    print("shots: " + ", ".join(f"{t}s {n}" for t, n in taken))


if __name__ == "__main__":
    main()
