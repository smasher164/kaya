import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/lib"))
from kaya_gate import Gate, dev_shell_or_die, scratch_dir

dev_shell_or_die()
gate = Gate("java-async-measure")
source = Path(__file__).resolve().parent
library = ROOT / "target/debug/libkaya.dylib"
sentence = ("kaya: async handler failed; no transaction was rolled back by this reporter; "
            "completed transactions remain committed")


def build(folder):
    classes = folder / "classes"
    result = subprocess.run([
        "javac", "--release", "21", "-encoding", "UTF-8", "-proc:none", "-d", str(classes),
        str(ROOT / "bindings/java-desktop/dev/kaya/KayaRing.java"),
        *map(str, sorted((ROOT / "bindings/java/dev/kaya").glob("*.java"))),
        str(folder / "Probe.java")], cwd=ROOT, capture_output=True, text=True,
        encoding="utf-8", timeout=60, check=False)
    print(f"build exit={result.returncode}\n{result.stdout}{result.stderr}", flush=True)
    if result.returncode:
        raise RuntimeError("probe build failed")
    return classes


def run(classes, mode):
    return subprocess.run(["java", "-cp", str(classes), "dev.kaya.Probe", mode, str(library)],
                          cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
                          timeout=15, check=False)


subprocess.run([str(ROOT / "tools/build-id.py"), "--verify", str(library)],
               cwd=ROOT, check=True)
with scratch_dir("java-async-measure-") as tmp:
    shutil.copyfile(source / "Probe.java", tmp / "Probe.java")
    classes = build(tmp)
    for mode in ("inline", "bare", "parent", "owned", "before", "inside", "caught", "late"):
        result = run(classes, mode)
        print(f"mode={mode} exit={result.returncode}\n{result.stdout}{result.stderr}", flush=True)
        count = 1 if mode in {"owned", "before", "inside"} else 0
        if result.returncode or f"java-async-probe: {mode} " not in result.stdout:
            raise RuntimeError(f"measurement failed: {mode}")
        if result.stderr.count(sentence) != count or result.stderr.count("probe error:") != count:
            raise RuntimeError(f"report count changed: {mode}: {result.stderr!r}")
        if "handler threw (transaction rolled back)" in result.stderr:
            raise RuntimeError(f"synchronous dispatch caught a stage failure: {mode}")
    original = (source / "Probe.java").read_text(encoding="utf-8")
    for name, before, after, mode, expected in (
        ("parent observer", "observe(terminal);", "observe(request);", "owned",
         "report count mismatch"),
        ("inline completion", "else jobs.add(complete);", "else complete.run();", "owned",
         "completion boundary changed"),
        ("completed scope", "first == wantedFirst", "first == wantedFirst + 1", "owned",
         "completed scope changed"),
        ("throwing scope", "second == 0", "second == 1", "inside", "throwing scope committed"),
        ("foreign thread", "KayaApp.claimAppThread();", "", "late", "foreign write was accepted"),
        ("caught failure", 'if (!mode.equals("caught")) throw error;', "throw error;", "caught",
         "terminal fault state changed"),
    ):
        (tmp / "Probe.java").write_text(
            gate.doctor(name, original, re.escape(before), after), encoding="utf-8")
        classes = build(tmp)
        result = run(classes, mode)
        if result.returncode == 0 or expected not in result.stderr:
            raise RuntimeError(f"negative {name} failed to refuse: "
                               f"{result.returncode}\n{result.stdout}{result.stderr}")
        print(f"negative={name} exit={result.returncode} refused: {expected}", flush=True)
    print("java-async-measure: eight observations, six counted negatives refused", flush=True)
