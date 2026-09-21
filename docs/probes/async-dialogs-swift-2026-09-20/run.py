import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/lib"))
from kaya_gate import Gate, dev_shell_or_die, scratch_dir

dev_shell_or_die()
gate = Gate("swift-async-measure")
source = Path(__file__).resolve().parent
sentence = ("kaya: async handler failed; no transaction was rolled back by this reporter; "
            "completed transactions remain committed")
compile_args = [
    "bash", "-c",
    'source "$1/tools/lib/swift-toolchain.sh" && shift && kaya_swift_guestc "$@"',
    "_", str(ROOT), "-I", str(ROOT / "bindings/swift/CKaya"),
    "-L", str(ROOT / "target/debug"), "-lkaya", "-Xlinker", "-rpath", "-Xlinker",
    str(ROOT / "target/debug"),
    *map(str, sorted((ROOT / "bindings/swift").glob("*.swift"))),
]


def build(folder):
    binary = folder / "probe"
    result = subprocess.run(compile_args + [str(folder / "main.swift"), "-o", str(binary)],
                            cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
                            timeout=120, check=False)
    print(f"build exit={result.returncode}\n{result.stdout}{result.stderr}", flush=True)
    if result.returncode != 0:
        raise RuntimeError("probe build failed")
    return binary


def run(binary, mode):
    return subprocess.run([str(binary), mode], cwd=ROOT, capture_output=True,
                          text=True, encoding="utf-8", timeout=10, check=False)


subprocess.run([str(ROOT / "tools/build-id.py"), "--verify",
                str(ROOT / "target/debug/libkaya.dylib")], cwd=ROOT, check=True)
with scratch_dir("swift-async-measure-") as tmp:
    shutil.copyfile(source / "main.swift", tmp / "main.swift")
    binary = build(tmp)
    for mode in ("bare", "result", "owned", "inside"):
        result = run(binary, mode)
        print(f"mode={mode} exit={result.returncode}\n{result.stdout}{result.stderr}", flush=True)
        count = 0 if mode == "bare" else 1
        marker = (f"swift-async-probe: mode={mode} same-thread=true ambient-tx=false "
                  f"first=1 second=0 reports={count} unwound=true")
        if result.returncode != 0 or marker not in result.stdout:
            raise RuntimeError(f"measurement failed: {mode}")
        if result.stderr.count(sentence) != count:
            raise RuntimeError(f"failure sentence count changed: {mode}: {result.stderr!r}")
        if result.stderr.count("probe error:") != count:
            raise RuntimeError(f"exception count changed: {mode}: {result.stderr!r}")
        if "handler threw (transaction rolled back)" in result.stderr:
            raise RuntimeError(f"synchronous reporter caught an async task: {mode}")
    original = (source / "main.swift").read_text(encoding="utf-8")
    for name, before, after, mode, expected in (
        ("unobserved task", "observedTask(body, report: report)",
         "Task { try await body() }", "owned", "report count mismatch"),
        ("completed scope rollback", "app.signalMirrors[first.id] == .i64(1)",
         "app.signalMirrors[first.id] == .i64(0)", "owned", "completed scope was rolled back"),
        ("throwing scope commit", "app.signalMirrors[second.id] == .i64(0)",
         "app.signalMirrors[second.id] == .i64(2)", "inside", "throwing scope was committed"),
    ):
        (tmp / "main.swift").write_text(
            gate.doctor(name, original, re.escape(before), after), encoding="utf-8")
        binary = build(tmp)
        result = run(binary, mode)
        if result.returncode == 0 or expected not in result.stderr:
            raise RuntimeError(f"negative {name} failed to refuse: "
                               f"{result.returncode}\n{result.stdout}{result.stderr}")
        print(f"negative={name} exit={result.returncode} refused: {expected}", flush=True)
    print("swift-async-measure: four observations, three counted negatives refused", flush=True)
