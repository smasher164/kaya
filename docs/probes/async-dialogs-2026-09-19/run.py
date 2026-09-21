import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/lib"))
from kaya_gate import Gate, dev_shell_or_die, scratch_dir

dev_shell_or_die()
gate = Gate("async-dialogs-measure")
source = Path(__file__).resolve().parent
env = dict(os.environ, KAYA_LIB=str(ROOT / "target/debug/libkaya.dylib"))


def build(folder):
    result = subprocess.run(
        ["dotnet", "build", str(folder / "probe.csproj"),
         f"-p:KayaRoot={ROOT}", "--nologo", "-v", "quiet"],
        capture_output=True, text=True, encoding="utf-8", timeout=120,
        check=False)
    print(result.stdout + result.stderr)
    if result.returncode != 0:
        raise RuntimeError("probe build failed")
    return folder / "bin/Debug/net10.0/probe.dll"


def run(binary, mode):
    result = subprocess.run(["dotnet", str(binary), mode], env=env,
                            capture_output=True, text=True, encoding="utf-8",
                            timeout=15, check=False)
    print(f"mode={mode} exit={result.returncode}\n{result.stdout}{result.stderr}")
    return result


with scratch_dir("async-dialogs-measure-") as tmp:
    for name in ("probe.csproj", "Probe.cs"):
        shutil.copyfile(source / name, tmp / name)
    binary = build(tmp)
    for mode in ("ambient", "explicit", "inside", "raw"):
        result = run(binary, mode)
        if result.returncode != 0 or "probe: measured" not in result.stdout:
            raise RuntimeError(f"measurement failed: {mode}")
    probe = tmp / "Probe.cs"
    probe.write_text(gate.doctor(
        "demand the proposed continuation rollback", probe.read_text(encoding="utf-8"),
        re.escape('mode == "inside" ? "before" : "after"'), '"before"'),
        encoding="utf-8")
    binary = build(tmp)
    result = run(binary, "ambient")
    if result.returncode != 1 or "probe: observation mismatch, want final=before" not in result.stdout:
        raise RuntimeError("the false rollback expectation was not refused")
    print("async-dialogs-measure: four observations, one counted negative refused")
