#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die, scratch_dir

import concurrent.futures
import os
import subprocess
import time

dev_shell_or_die()
g = Gate("rust-scoped")
# No build here: a `-p kaya` build is a different cargo unit from the sweep's
# workspace build and relinks the shared host dylib under every guest and
# probe loading it (docs/traps.md, the sweep-relinked-libkaya entry).
DEPS = ROOT / "target/debug/deps"
RLIB = DEPS / "libkaya.rlib"
BOUND = 60
if not RLIB.is_file():
    print("rust-scoped: build libkaya first (cargo build --locked --lib)")
    sys.exit(1)
source = """#![allow(dead_code, unused_imports)]
use std::future::{Future, pending};
use std::hint::black_box;
use std::rc::Rc;
fn local_task<'a>(_: impl Future<Output = ()> + 'a) {}
fn example(ctx: &kaya::AppCtx) {
    local_task(async move {
        BODY
    });
}
"""
cases = [
    ("owned-result-local-state", """
        let state = Rc::new(7);
        let value = ctx.apply(|tx| { black_box(tx); *state });
        pending::<()>().await;
        black_box(value);
    """, None),
    ("await-in-scope", """
        ctx.apply(|tx| { pending::<()>().await; black_box(tx); });
    """, "E0728"),
    ("return-reference", """
        let tx = ctx.apply(|tx| tx);
        pending::<()>().await;
        black_box(tx);
    """, "lifetime may not live long enough"),
    ("return-future", """
        let future = ctx.apply(|tx| async move {
            pending::<()>().await; black_box(tx);
        });
        future.await;
    """, "lifetime may not live long enough"),
    ("return-boxed-future", """
        let future = ctx.apply(|tx| Box::pin(async move {
            pending::<()>().await; black_box(tx);
        }));
        future.await;
    """, "lifetime may not live long enough"),
    ("store-reference", """
        let mut saved = None;
        ctx.apply(|tx| { saved = Some(tx); });
        pending::<()>().await;
        black_box(saved);
    """, "E0521"),
    ("return-closure", """
        let later = ctx.apply(|tx| move || { black_box(tx); });
        pending::<()>().await;
        later();
    """, "lifetime may not live long enough"),
    ("move-owned-tx", """
        let tx = ctx.apply(|tx| *tx);
        pending::<()>().await;
        tx.commit();
    """, "E0507"),
    ("independent-future", """
        let future = ctx.apply(|tx| {
            black_box(tx);
            async move { pending::<()>().await; }
        });
        future.await;
    """, None),
    ("raw-begin-bypass", """
        let tx = ctx.apply(|_| ctx.begin());
        pending::<()>().await;
        tx.commit();
    """, "E0624"),
    ("nested-manual-poll", """
        ctx.apply(|tx| {
            let mut future = std::pin::pin!(async move {
                pending::<()>().await; black_box(tx);
            });
            let mut cx = std::task::Context::from_waker(std::task::Waker::noop());
            assert!(future.as_mut().poll(&mut cx).is_pending());
        });
    """, None),
]
async_source = """#![allow(dead_code, unused_imports)]
use std::future::{Future, pending, IntoFuture};
use std::rc::Rc;
fn example(ctx: kaya::AppCtx) {
    BODY
}
"""
async_cases = [
    ("task-local-state", """
        let tasks = ctx.tasks();
        let state = Rc::new(7);
        tasks.spawn(async move |app| {
            let value = app.apply(|_| *state);
            app.show_alert().cancel("Keep").await;
            app.apply(|_| std::hint::black_box(value));
        });
    """, None),
    ("task-result", """
        let tasks = ctx.tasks();
        tasks.spawn(async |app| -> Result<(), &'static str> {
            app.pick_file().await;
            Err("failed")
        });
    """, None),
    ("context-escape", """
        let tasks = ctx.tasks();
        drop(ctx);
        tasks.spawn(async |_| {});
    """, "E0505"),
    ("scope-thread", """
        let tasks = ctx.tasks();
        std::thread::scope(|scope| { scope.spawn(move || drop(tasks)); });
    """, "E0277"),
    ("context-thread-after-scope", """
        let tasks = ctx.tasks();
        tasks.spawn(async |_| {});
        drop(tasks);
        std::thread::spawn(move || drop(ctx));
    """, None),
    ("callback-alert-await", """
        ctx.apply(|tx| { let _ = tx.show_alert().cancel("Keep").into_future(); });
    """, "E0599"),
    ("future-alert-callback", """
        let tasks = ctx.tasks();
        let _ = ctx.show_alert().cancel("Keep").show();
    """, "E0599"),
    ("task-tx-escape", """
        let tasks = ctx.tasks();
        tasks.spawn(async |app| {
            let tx = app.apply(|tx| tx);
            app.pick_file().await;
            std::hint::black_box(tx);
        });
    """, "lifetime may not live long enough"),
    ("task-result-unobserved-type", """
        let tasks = ctx.tasks();
        tasks.spawn(async |_| { 7 });
    """, "E0277"),
]


def measure(argv, timeout=10):
    try:
        run = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8",
                             errors="replace", timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        return None, f"{argv[0]} gave no answer in {timeout}s"
    except OSError as error:
        return None, f"{argv[0]} did not start: {error}"
    return run, f"{argv[0]} exited {run.returncode}: {run.stderr.strip()[:200]!r}"


def stall_report(proc, name, began, began_wall, tmp):
    """A stuck rustc is sampled BEFORE it is killed (docs/traps.md, the
    rust-scoped readdir stall)."""
    elapsed = time.monotonic() - began
    out = tmp / f"{name}.sample.txt"
    run, why = measure(["sample", str(proc.pid), "2", "-file", str(out)])
    lines = out.read_text(encoding="utf-8", errors="replace").splitlines() \
        if run is not None and run.returncode == 0 and out.is_file() else []
    if "Sort by top of stack, same collapsed (when >= 5):" in lines:
        at = lines.index("Sort by top of stack, same collapsed (when >= 5):")
        frames = [" ".join(line.split())[:90] for line in lines[at + 1:at + 6]]
        frames = frames[:frames.index("")] if "" in frames else frames
        stack = f"sample's {len(frames)} most frequent top frames were {'; '.join(frames)}"
    else:
        stack = f"sample read no stack ({why})"
    run, why = measure(["lsof", "-p", str(proc.pid), "-Ftn"])
    if run is not None and run.returncode == 0:
        fields = run.stdout.splitlines()
        dirs = [fields[i + 1][1:] for i, f in enumerate(fields[:-1])
                if f == "tDIR" and fields[i + 1] != f"n{ROOT}"]
        regular = fields.count("tREG")
        files = (f"it held {regular} regular files and the directories "
                 f"{dirs or 'none but its cwd'} open")
    else:
        files = f"its open files were not read ({why})"
    run, why = measure(["sysctl", "-n", "kern.memorystatus_level", "vm.swapusage"])
    memory = (f"memorystatus_level {run.stdout.split()[0]}% free, swap "
              f"{' '.join(run.stdout.split()[1:7])}"
              if run is not None and run.returncode == 0 else f"memory not read ({why})")
    rlib = ("was REWRITTEN during this run" if RLIB.stat().st_mtime > began_wall
            else "unchanged since the run began")
    return (f"{name}: rustc ran {elapsed:.0f}s against its {BOUND}s bound and was killed; "
            f"{stack}; {files}; load average {os.getloadavg()[0]:.1f}; {memory}; "
            f"libkaya.rlib {rlib}")


def link_dir(tmp):
    """The crates alone, never deps itself (docs/traps.md, the rust-scoped
    readdir stall)."""
    began = time.monotonic()
    lib = tmp / "deps"
    lib.mkdir()
    linked = 0
    for entry in os.scandir(DEPS):
        if entry.name.endswith((".rlib", ".rmeta", ".dylib", ".so")):
            (lib / entry.name).symlink_to(entry.path)
            linked += 1
    if linked < 50:
        g.refuse(f"only {linked} crate files under {DEPS}; build libkaya first")
    print(f"rust-scoped: {linked} crate files linked out of {DEPS} "
          f"in {time.monotonic() - began:.1f}s")
    return lib


def compile_case(name, tmp, lib, bound=BOUND):
    began, began_wall = time.monotonic(), time.time()
    proc = subprocess.Popen([
        "rustc", "--edition=2024", "--crate-type=lib", "--emit=metadata",
        str(tmp / f"{name}.rs"),
        "--extern", f"kaya={RLIB}",
        "-L", f"dependency={lib}",
        "-o", str(tmp / f"{name}.rmeta")],
        cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8")
    try:
        _out, err = proc.communicate(timeout=bound)
    except subprocess.TimeoutExpired:
        try:
            return None, "", stall_report(proc, name, began, began_wall, tmp)
        finally:
            proc.kill()
            proc.communicate()
    return proc.returncode, err, None


with scratch_dir("rust-scoped-") as tmp:
    lib = link_dir(tmp)
    (tmp / "spin-forever.rs").write_text(
        "#![allow(long_running_const_eval)]\n"
        "pub const SPIN: u64 = { let mut i = 0u64; loop { i = i.wrapping_add(1); } };\n",
        encoding="utf-8")
    code, _err, stall = compile_case("spin-forever", tmp, lib, bound=3)
    if stall is None or "spin-forever: rustc ran 3s" not in stall \
            or "most frequent top frames were" not in stall:
        g.refuse(f"a rustc that never ends did not produce the stall sentence "
                 f"(exit {code}): {stall}")
    print(f"rust-scoped: stall self-test: {stall}")
    population = [(source, case) for case in cases] + [(async_source, case) for case in async_cases]
    for template, (name, body, _refusal) in population:
        (tmp / f"{name}.rs").write_text(
            g.doctor(name, template, "BODY", body, want=1), encoding="utf-8")

    # ONE RUSTC PER CASE, RUN SIX AT A TIME (docs/traps.md, the gate sweep's
    # check-abort tail).
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(lambda case: compile_case(case[1][0], tmp, lib), population))
    stalls = [stall for _code, _err, stall in results if stall]
    if stalls:
        g.refuse("\n".join(stalls))
    for (_t, (name, _body, refusal)), (code, err, _stall) in zip(population, results,
                                                                 strict=True):
        if refusal is None and code:
            g.refuse(f"{name}: valid scoped code failed: {err}")
        if refusal is not None and (code == 0 or refusal not in err):
            g.refuse(f"{name}: missing {refusal}: {err}")
        print(f"rust-scoped: {name}: exit {code}; "
              f"expected {'refused: ' + refusal if refusal else 'accepted'}")
print("rust-scoped: 20 compiler cases; fourteen refusals, six accepted controls")
