import os, random, subprocess, sys, threading, time
CHILD = r'''
import os, random, sys, threading, time
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst
Gst.init(None)
uri, n, seed, settle = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == "settle"
def looping():
    c = 0
    for tid in os.listdir("/proc/self/task"):
        try:
            if open(f"/proc/self/task/{tid}/comm").read().strip() == "adaptive-downlo" and \
                    open(f"/proc/self/task/{tid}/syscall").read().split()[0] == "73":
                c += 1
        except OSError:
            pass
    return c
def demuxers(p):
    it = p.iterate_recurse(); c = 0
    while True:
        r, e = it.next()
        if r != Gst.IteratorResult.OK: break
        f = e.get_factory()
        if f and "Demuxer/Adaptive" in (f.get_metadata("klass") or "") and int(e.get_state(0)[1]) >= int(Gst.State.PAUSED): c += 1
    return c
random.seed(seed)
for i in range(n):
    p = Gst.ElementFactory.make("playbin3")
    p.set_property("uri", uri)
    p.set_property("video-sink", Gst.ElementFactory.make("fakesink"))
    p.set_property("audio-sink", Gst.ElementFactory.make("fakesink"))
    p.set_state(Gst.State.PAUSED)
    time.sleep(random.uniform(0, 0.04))
    done = threading.Event()
    if settle:
        n_d, t0 = demuxers(p), time.monotonic()
        while n_d and looping() < n_d and time.monotonic() - t0 < 2: time.sleep(0.002)
    def stop():
        p.set_state(Gst.State.NULL); done.set()
    threading.Thread(target=stop, daemon=True).start()
    if not done.wait(15):
        print(f"HANG {i}", flush=True)
        os.system(f"eu-stack -p {os.getpid()} > /tmp/hang-{seed}-{i}.txt 2>&1")
        os._exit(3)
    print(f"OK {i}", flush=True)
'''
uri, total, batch, mode = sys.argv[1], int(sys.argv[2]), 100, sys.argv[4]
ok = hang = crash = 0
seed = 0
deadline = time.time() + float(sys.argv[3])
while ok + hang + crash < total and time.time() < deadline:
    seed += 1
    r = subprocess.run([sys.executable, "-c", CHILD, uri, str(min(batch, total - ok - hang - crash)), str(seed), mode],
                       capture_output=True, text=True, timeout=1200)
    ok += r.stdout.count("OK ")
    if "HANG" in r.stdout: hang += 1
    elif r.returncode != 0: crash += 1; sys.stderr.write(r.stderr[-300:] + "\n")
    print(f"batch {seed}: rc={r.returncode} ok={ok} hang={hang} crash={crash}", flush=True)
print(f"TOTAL ok={ok} hang={hang} crash={crash}")
