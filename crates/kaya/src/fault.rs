//! The legible way to lose.
//!
//! Every caller here sits in a frame that CANNOT UNWIND — an
//! `extern "C"` entry, a DispatcherQueue callback, a glib idle source —
//! so a panic in one is `fatal runtime error: failed to initiate panic`
//! and the leg dies with a bare exit code, taking the harness's failure
//! list with it (docs/deferred.md, "A GUARD THAT ABORTS THE PROCESS IS
//! THE WRONG SHAPE"). The rule this module holds: an app-misuse guard
//! or a failed apply REDDENS THE LEG with its sentence intact, and only
//! genuinely unrecoverable state aborts.
//!
//! `fault::tests` is the wall — a source census over the four files
//! whose nounwind bodies this covers, run by `cargo test -p kaya`.

use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

/// The first sentence, and how many faults followed it. FIRST WINS: the
/// first is the cause and the rest are its wreckage — but the count is
/// on the record, because "one op failed" and "every op since has
/// failed" are different diagnoses and only the number tells them apart.
static FAULT: Mutex<Option<(String, u32)>> = Mutex::new(None);

/// Whether a HARNESS is driving this process — set once, at the top of
/// each of the three script runners, never cleared. The flag decides
/// `report`'s second half: watched, the latch is the harness's to turn
/// into a red leg; UNWATCHED — a real app misusing the API, or the
/// bindings' corpse-reading child processes (bindings/go/internal/
/// rootprobe) — the process must die legibly, sentence first, because
/// "report and keep going" means a pump that blocks forever (ratified
/// 2026-08-21; the fault census below holds all three runners to the
/// call).
static WATCHED: AtomicBool = AtomicBool::new(false);

/// The harness's declaration that it is watching the latch.
pub(crate) fn watch() {
    WATCHED.store(true, Ordering::Release);
}

/// Report a failure the process cannot continue past. The sentence
/// reaches stderr AT ONCE (it has to survive a kill); then the fork:
/// WATCHED (a harness declared itself via `watch`) it is latched and
/// this RETURNS — the caller abandons its own frame and the harness
/// turns the latch into a red leg; UNWATCHED the process exits 1,
/// because for a real app "report and keep going" means a pump that
/// blocks forever.
pub(crate) fn report(sentence: String) {
    eprintln!("{sentence}");
    // A poisoned latch is still a latch: the point of this module is
    // that no path out of here may panic.
    {
        let mut slot = FAULT.lock().unwrap_or_else(|e| e.into_inner());
        match slot.as_mut() {
            Some((_, more)) => *more += 1,
            None => *slot = Some((sentence, 0)),
        }
    }
    // UNWATCHED, the process dies here, sentence already on stderr —
    // exit(1), not abort: the corpse-readers check death and words, and
    // a mid-run exit releases XAML TLS handles into a LIVE apartment
    // (the docs/traps.md dead-apartment entry is about exit AFTER
    // Application::Start returns, which this is not).
    if !WATCHED.load(Ordering::Acquire) {
        std::process::exit(1);
    }
}

/// The latched sentence, or `None`. A PEEK, not a take: the harness
/// consults it once per step and once after the last one, and a
/// consuming read would let the second look report a green leg.
pub(crate) fn latched() -> Option<String> {
    let slot = FAULT.lock().unwrap_or_else(|e| e.into_inner());
    slot.as_ref().map(|(sentence, more)| match more {
        0 => sentence.clone(),
        n => format!("{sentence} (and {n} further faults after it)"),
    })
}

/// Run `f` with unwinding stopped here: a panic inside becomes a fault
/// and `None`, instead of an abort. `what` names the frame, since the
/// panic's own message names only the assertion.
///
/// THE PAYLOAD'S TEXT IS THE SENTENCE — the default hook has already
/// printed it with its location, and this is the copy the verdict list
/// carries.
pub(crate) fn guard<R>(what: &str, f: impl FnOnce() -> R) -> Option<R> {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(value) => Some(value),
        Err(payload) => {
            let said = payload
                .downcast_ref::<&'static str>()
                .map(|s| (*s).to_owned())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "a panic with no message".to_owned());
            report(format!("kaya: {what}: {said}"));
            None
        }
    }
}

#[cfg(test)]
mod tests {
    /// The nounwind chokepoints, each read from the file it lives in by
    /// `include_str!` — so this test cannot read a stale copy, and the
    /// Windows-only body is censused on every platform's `cargo test`.
    const CAPI: &str = include_str!("capi.rs");
    const SCENE: &str = include_str!("scene.rs");
    const WINUI: &str = include_str!("winui/mod.rs");
    const GTK: &str = include_str!("gtk.rs");

    /// A top-level function's own body: from its `fn NAME` to the
    /// closing brace in column 0. Every function named below is
    /// top-level, which is what makes that delimiter exact.
    fn body(src: &str, name: &str, file: &str) -> String {
        let head = format!("fn {name}(");
        let start = src
            .find(&head)
            .unwrap_or_else(|| panic!("kaya: {file} no longer defines `{name}` — this census names a function that has been renamed or deleted, so it is reading nothing"));
        let rest = &src[start..];
        let end = rest
            .find("\n}\n")
            .unwrap_or_else(|| panic!("kaya: {file}'s `{name}` has no column-0 closing brace"));
        rest[..end].to_owned()
    }

    /// A METHOD's body, closed at the `impl`'s indentation rather than
    /// column 0. Its own read is checked: `must_contain` names something
    /// only the intended method has, so a delimiter that ran long and
    /// swallowed a neighbour cannot make the clause pass on the
    /// neighbour's guard.
    fn method_body(src: &str, name: &str, file: &str, must_contain: &str) -> String {
        let head = format!("fn {name}(");
        let start = src
            .find(&head)
            .unwrap_or_else(|| panic!("kaya: {file} no longer defines `{name}` — this census names a function that has been renamed or deleted, so it is reading nothing"));
        let rest = &src[start..];
        let end = rest
            .find("\n    }\n")
            .unwrap_or_else(|| panic!("kaya: {file}'s `{name}` has no method-level closing brace"));
        let body = rest[..end].to_owned();
        assert!(
            body.contains(must_contain),
            "kaya: the census read {} bytes for {file}'s `{name}` and they do not contain \
             `{must_contain}` — it is reading the wrong function",
            body.len()
        );
        body
    }

    /// The panic-shaped calls. `.unwrap()` is deliberately NOT here:
    /// these bodies lock process-global mutexes and an `unwrap` on a
    /// `LockResult` is the idiom everywhere else in the crate — the
    /// shape this census is about is a guard that DECIDES to die.
    const PANICKING: [&str; 4] = ["panic!(", ".expect(", "unreachable!(", "assert!("];

    /// THE SINGLETON GUARDS MAY NOT PANIC. Each of these catches an app
    /// or backend misuse from inside `Scene::apply`, which every backend
    /// runs in a frame that cannot unwind; a panic here is the abort
    /// recorded in docs/deferred.md, and it takes the verdict list with
    /// it.
    #[test]
    fn the_singleton_guards_report_rather_than_panic() {
        for name in [
            "file_dialog_shown",
            "file_dialog_retire",
            "alert_shown",
            "alert_retire",
        ] {
            let body = body(CAPI, name, "capi.rs");
            for bad in PANICKING {
                assert!(
                    !body.contains(bad),
                    "kaya: capi.rs's `{name}` contains `{bad}` — it runs inside \
                     Scene::apply, which every backend drives from a frame that \
                     cannot unwind, so a panic there aborts the process with no \
                     verdict list. Report it through crate::fault::report and \
                     answer the caller instead (docs/deferred.md, \"A GUARD THAT \
                     ABORTS THE PROCESS IS THE WRONG SHAPE\")."
                );
            }
            assert!(
                body.contains("crate::fault::report(") || body.contains("fault::report("),
                "kaya: capi.rs's `{name}` never reports a fault — a guard that \
                 catches a misuse and says nothing is worse than one that aborts"
            );
        }
    }

    /// AND EVERY NOUNWIND BOUNDARY STOPS THE UNWIND. `Scene::apply` is
    /// one long wall of app-misuse assertions (scene.rs), and every one
    /// of them fires inside one of these frames.
    ///
    /// THE LIST IS DERIVED, NOT REMEMBERED: the clause under this one
    /// finds the boundaries by looking for `Scene::apply` callers, which
    /// is what found gtk.rs's SECOND drain — a copy of the first inside
    /// `type_text`'s quiescence wait, missed by the naming clause
    /// because nobody thought to name it.
    #[test]
    fn every_nounwind_boundary_names_the_guard() {
        for (src, file, name) in [
            (CAPI, "capi.rs", "kaya_next_commands"),
            (WINUI, "winui/mod.rs", "drain_transactions"),
            (WINUI, "winui/mod.rs", "deliver_undo"),
            (GTK, "gtk.rs", "drain_transactions"),
        ] {
            let body = body(src, name, file);
            assert!(
                body.contains("fault::guard("),
                "kaya: {file}'s `{name}` does not run its apply under \
                 crate::fault::guard — it is called from a frame that cannot \
                 unwind, so an assertion inside Scene::apply aborts the process \
                 instead of reddening the leg (docs/deferred.md)"
            );
        }
        // The method-shaped one, read at the impl's indentation.
        let typed = method_body(GTK, "type_text", "gtk.rs", "core.scene.apply(");
        assert!(
            typed.contains("fault::guard("),
            "kaya: gtk.rs's `type_text` drains transactions inside \
             `on_main_mut`, which runs its closure from `glib::idle_add` — a C \
             callback that cannot unwind — without crate::fault::guard \
             (docs/deferred.md)"
        );
    }

    /// AND THE LIST ABOVE IS NOT THE AUTHORITY — this is. Every place a
    /// BACKEND drives `Scene::apply` is a nounwind frame by
    /// construction (that is what a backend's pump is), so the sites are
    /// FOUND rather than named, and a new one arrives red instead of
    /// arriving unguarded. Measured 2026-08-21: gtk.rs's `type_text`
    /// carries a SECOND copy of the drain inside its quiescence wait,
    /// under `on_main_mut` (`glib::idle_add`), and the named list had
    /// missed it — this clause is what a list cannot do.
    #[test]
    fn every_scene_apply_caller_sits_under_a_guard() {
        // Generous, because a guard is always a few lines up; a guard 40
        // lines away is worth a red saying "put it nearer".
        const WINDOW: usize = 40;
        let mut sites = 0;
        for (src, file) in [(CAPI, "capi.rs"), (WINUI, "winui/mod.rs"), (GTK, "gtk.rs")] {
            let lines: Vec<&str> = src.split('\n').collect();
            for (i, line) in lines.iter().enumerate() {
                if !line.contains("scene.apply(") && !line.contains(".as_mut().unwrap().apply(") {
                    continue;
                }
                sites += 1;
                let from = i.saturating_sub(WINDOW);
                assert!(
                    lines[from..=i].iter().any(|l| l.contains("fault::guard(")),
                    "kaya: {file}:{} drives Scene::apply with no crate::fault::guard \
                     within {WINDOW} lines above it — a backend's pump is a frame that \
                     cannot unwind, so every app-misuse assertion in scene.rs aborts \
                     the process from there instead of reddening the leg \
                     (docs/deferred.md, \"A GUARD THAT ABORTS THE PROCESS IS THE \
                     WRONG SHAPE\")",
                    i + 1
                );
            }
        }
        assert!(
            sites >= 4,
            "kaya: the census found only {sites} Scene::apply callers across capi.rs, \
             winui/mod.rs and gtk.rs — it used to find 4, so it is now reading past \
             them and agreeing with everything"
        );
    }

    /// AND THE PUMP'S OWN FRAME MAY NOT DECIDE TO DIE. `fault::guard`
    /// wraps `Scene::apply` inside `kaya_next_commands`; everything else
    /// in that function is outside it, so a panic there is the abort with
    /// no verdict list AND no transaction to blame. It shipped one: an
    /// `assert!` that the resolved batch fit the caller's 64 KiB buffer
    /// killed macOS, iOS and Android at 161 table rows in one transaction
    /// (docs/deferred.md, the 64 KiB pump wall).
    #[test]
    fn the_pump_frame_never_decides_to_die() {
        let body = body(CAPI, "kaya_next_commands", "capi.rs");
        for bad in PANICKING {
            assert!(
                !body.contains(bad),
                "kaya: capi.rs's `kaya_next_commands` contains `{bad}` — the pump's \
                 frame cannot unwind, and what it hands out is sized by the CORE, so \
                 there is nothing here left to refuse. Whatever this is about, report \
                 it through crate::fault::report (docs/deferred.md, the 64 KiB pump \
                 wall)"
            );
        }
    }

    /// AND NO PUMP SIZES ITS OWN BUFFER. The core owns the batch's bytes
    /// and states their length; a reader that allocates a fixed buffer
    /// instead puts a cap back on how many rows one transaction may
    /// build, which is invisible until a real app crosses it — 161 rows
    /// on macOS/iOS, 157 on Android, and not at all on GTK or WinUI,
    /// whose backends never cross this ABI (docs/measurements/
    /// choke-macos-2026-08-24.txt).
    #[test]
    fn no_pump_sizes_its_own_buffer() {
        let swift = include_str!("../../../swift/KayaSwiftUI.swift");
        let kotlin =
            include_str!("../../../android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt");
        for (src, opener, closer, names, file) in [
            (
                swift,
                "func kayaStartCommandPump() {",
                "\n}\n",
                "KayaHost.nextCommands(",
                "KayaSwiftUI.swift",
            ),
            (
                kotlin,
                "private fun startPump(",
                "\n    }\n",
                "KayaPresent.nextCommands(",
                "KayaCompose.kt",
            ),
        ] {
            let start = src.find(opener).unwrap_or_else(|| {
                panic!("kaya: {file} no longer defines `{opener}` — this census is reading nothing")
            });
            let rest = &src[start..];
            let end = rest
                .find(closer)
                .unwrap_or_else(|| panic!("kaya: {file}'s pump has no closing brace"));
            let pump = &rest[..end];
            // The read is checked before it is believed: the pump asks
            // the core for the batch, so a body without that call is the
            // wrong body.
            assert!(
                pump.contains(names),
                "kaya: the census read {} bytes for {file}'s pump and they do not call \
                 `{names}` — it is reading the wrong function",
                pump.len()
            );
            for size in size_literals(pump) {
                assert!(
                    size < 256,
                    "kaya: {file}'s pump names the size {size} — the batch is sized by \
                     the core (kaya_next_commands writes the length), and a buffer sized \
                     here is a cap on how many rows one transaction may build \
                     (docs/deferred.md, the 64 KiB pump wall)"
                );
            }
        }
    }

    /// The integer literals in a body, ignoring the digits inside
    /// identifiers (`UInt8`, `runOnUiThread2`) — those name a type, not
    /// an amount.
    fn size_literals(body: &str) -> Vec<u64> {
        let bytes = body.as_bytes();
        let mut out = Vec::new();
        let mut i = 0;
        while i < bytes.len() {
            if !bytes[i].is_ascii_digit() {
                i += 1;
                continue;
            }
            let start = i;
            while i < bytes.len() && bytes[i].is_ascii_digit() {
                i += 1;
            }
            let joined = start > 0
                && (bytes[start - 1].is_ascii_alphanumeric() || bytes[start - 1] == b'_');
            if !joined {
                out.push(body[start..i].parse().unwrap_or(u64::MAX));
            }
        }
        out
    }

    /// EVERY SCRIPT RUNNER DECLARES ITSELF WATCHED, before its first
    /// step — the other half of `report`'s fork: a runner that forgot
    /// this dies at its first fault instead of reddening the leg, and
    /// nothing else would notice until a fault actually fired there.
    #[test]
    fn every_harness_runner_watches() {
        let rust = include_str!("harness.rs");
        let swift = include_str!("../../../swift/KayaSwiftUI.swift");
        let kotlin =
            include_str!("../../../android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt");
        for (src, opener, call, file) in [
            (rust, "fn run_with_log(", "crate::fault::watch();", "harness.rs"),
            (swift, "private func kayaRunScript(", "KayaHost.api.fault_watch()", "KayaSwiftUI.swift"),
            (kotlin, "private fun runScript(", "KayaPresent.faultWatch()", "KayaCompose.kt"),
        ] {
            let at = src.find(opener).unwrap_or_else(|| {
                panic!("kaya: {file} no longer defines `{opener}` — this census is reading nothing")
            });
            let head = &src[at..at + 600.min(src.len() - at)];
            assert!(
                head.contains(call),
                "kaya: {file}'s script runner does not call `{call}` in its first                  lines — unwatched, its process DIES at the first fault instead of                  reddening the leg (crates/kaya/src/fault.rs)"
            );
        }
    }

    /// The census reads what it claims to read. A `find` that matched
    /// nothing would make every clause above vacuous, and this is the
    /// same refusal tools/tpl-surfaces.py makes for the same reason.
    #[test]
    fn the_census_read_all_four_files() {
        for (src, file) in [
            (CAPI, "capi.rs"),
            (SCENE, "scene.rs"),
            (WINUI, "winui/mod.rs"),
            (GTK, "gtk.rs"),
        ] {
            assert!(
                src.len() > 10_000,
                "kaya: the fault census read only {} bytes of {file} — a census \
                 that reads nothing agrees with everything",
                src.len()
            );
        }
        // Scene::apply is the reason the boundaries exist: if it ever
        // stops asserting, the boundaries are still right but this
        // file's premise has changed and the next reader should know.
        assert!(
            SCENE.matches("assert!(").count() > 20,
            "kaya: scene.rs no longer holds the app-misuse assertions this \
             module's premise is built on"
        );
    }
}
