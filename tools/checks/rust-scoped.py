#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die, scratch_dir

import subprocess

dev_shell_or_die()
g = Gate("rust-scoped")
subprocess.run(["cargo", "build", "-p", "kaya", "--lib", "--locked"], cwd=ROOT, check=True)
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
with scratch_dir("rust-scoped-") as tmp:
    population = [(source, case) for case in cases] + [(async_source, case) for case in async_cases]
    for template, (name, body, refusal) in population:
        path = tmp / f"{name}.rs"
        path.write_text(g.doctor(name, template, "BODY", body, want=1), encoding="utf-8")
        result = subprocess.run([
            "rustc", "--edition=2024", "--crate-type=lib", "--emit=metadata", str(path),
            "--extern", f"kaya={ROOT / 'target/debug/deps/libkaya.rlib'}",
            "-L", f"dependency={ROOT / 'target/debug/deps'}", "-o", str(tmp / f"{name}.rmeta")],
            cwd=ROOT, capture_output=True, text=True, encoding="utf-8", timeout=30, check=False)
        if refusal is None and result.returncode:
            g.refuse(f"{name}: valid scoped code failed: {result.stderr}")
        if refusal is not None and (result.returncode == 0 or refusal not in result.stderr):
            g.refuse(f"{name}: missing {refusal}: {result.stderr}")
        print(f"rust-scoped: {name}: exit {result.returncode}; "
              f"expected {'refused: ' + refusal if refusal else 'accepted'}")
print("rust-scoped: 20 compiler cases; fourteen refusals, six accepted controls")
