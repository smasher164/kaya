import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/lib"))
from kaya_gate import Gate, dev_shell_or_die, scratch_dir

dev_shell_or_die()
gate = Gate("rust-async-boundary")
source = Path(__file__).with_name("probe.rs").read_text(encoding="utf-8")
subprocess.run(["cargo", "build", "-p", "kaya", "--lib", "--locked"], cwd=ROOT, check=True)
subprocess.run(["rustc", "--version"], check=True)

held = gate.doctor("hold Tx across await", source,
                   r"let \(\) = ctx.apply\(\|_\| \{\}\);\s*pending::<\(\)>\(\).await;\s*ctx.apply\(\|_\| \{\}\);",
                   "let tx = ctx.begin();\n        pending::<()>().await;\n        tx.commit();", want=1)
cases = [("explicit-scopes", source, None), ("held-transaction", held, "E0624")]
for name, text in [("explicit-scopes", source), ("held-transaction", held)]:
    changed = gate.doctor(f"Send {name}", text, r"Future<Output = \(\)> \+ 'a",
                          "Future<Output = ()> + Send + 'a", want=1)
    refusal = "E0624" if name == "held-transaction" else "future cannot be sent between threads safely"
    cases.append((f"send-{name}", changed, refusal))
changed = gate.doctor("await inside apply", source,
                      r"let \(\) = ctx.apply\(\|_\| \{\}\);",
                      "let () = ctx.apply(|_| { pending::<()>().await; });", want=1)
cases.append(("await-inside-apply", changed, "E0728"))

with scratch_dir("rust-async-boundary-") as tmp:
    for name, text, refusal in cases:
        path = tmp / f"{name}.rs"
        path.write_text(text, encoding="utf-8")
        result = subprocess.run([
            "rustc", "--edition=2024", "--crate-type=lib", "--emit=metadata", str(path),
            "--extern", f"kaya={ROOT / 'target/debug/deps/libkaya.rlib'}",
            "-L", f"dependency={ROOT / 'target/debug/deps'}", "-o", str(tmp / f"{name}.rmeta")],
            cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=30, check=False)
        print(f"{name}: exit {result.returncode}; expected {'refusal' if refusal else 'accepted'}", flush=True)
        if refusal is None:
            if result.returncode:
                raise RuntimeError(result.stderr)
        elif result.returncode == 0 or refusal not in result.stderr:
            raise RuntimeError(f"missing {refusal}: {result.stderr}")
        if name == "send-explicit-scopes" and "AppCtx` is not `Sync" not in result.stderr:
            raise RuntimeError(f"Send failed for another reason: {result.stderr}")
print("rust-async-boundary: five compiler cases, four counted mutations; no runtime execution")
