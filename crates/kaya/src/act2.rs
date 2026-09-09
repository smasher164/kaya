//! THE SECOND ACT's door-side half (docs/tasks-s9-plan.md R6/R6a): the
//! process the platform starts on a notification tap has NO environment,
//! so the marker act one left is the only source of the scene — and the
//! guest picks its scene from KAYA_SELFTEST, which means the adoption has
//! to happen before the app thread exists. Hence a module the core's
//! entry calls, not something a harness can do for itself.
//!
//! THE CORE CONSUMES THE MARKER, so no interpreter copies the path or the
//! format: the three harnesses read `KAYA_ACT2_DIR` (where act one writes
//! `marker`) and `KAYA_ACT2_VERDICT` (act two's verdict file) out of the
//! environment and spell `<state>/act2/<id>` nowhere.

use std::path::{Path, PathBuf};

/// Where act one writes `marker`; exported in both acts.
pub(crate) const ENV_DIR: &str = "KAYA_ACT2_DIR";
/// Set in the SECOND process only: where its ordinary verdict line goes
/// beside stdout, which is what the runner polls.
pub(crate) const ENV_VERDICT: &str = "KAYA_ACT2_VERDICT";
pub(crate) const MARKER: &str = "marker";
pub(crate) const VERDICT: &str = "act2.verdict";

/// `<state>/act2/<id>`. `state_root` is the platform's answer where only
/// the platform has one (Android's files directory, handed in at attach);
/// elsewhere it is `None` and the arm below computes it.
fn dir(state_root: Option<&Path>) -> Option<PathBuf> {
    let root = match state_root {
        Some(root) => root.to_path_buf(),
        None => state_home()?,
    };
    let id = crate::scene::declared_identity().ok()?.id;
    Some(root.join("act2").join(id))
}

#[cfg(target_os = "ios")]
fn state_home() -> Option<PathBuf> {
    // The one directory an iOS app may write and a runner may read back.
    Some(PathBuf::from(std::env::var_os("HOME")?).join("Documents"))
}

#[cfg(target_os = "windows")]
fn state_home() -> Option<PathBuf> {
    Some(PathBuf::from(std::env::var_os("LOCALAPPDATA")?).join("kaya"))
}

/// macOS and Linux: the state home every lane already writes to
/// (tools/lib/exclusive.py, tools/lib/flightrec.py).
#[cfg(not(any(target_os = "ios", target_os = "windows", target_os = "android")))]
fn state_home() -> Option<PathBuf> {
    if let Some(state) = std::env::var_os("XDG_STATE_HOME") {
        if !state.is_empty() {
            return Some(PathBuf::from(state).join("kaya"));
        }
    }
    Some(PathBuf::from(std::env::var_os("HOME")?).join(".local/state/kaya"))
}

/// Android has no computable answer: `HOME` is not the app's files
/// directory and only a Context knows it, so attach hands it in. Nothing
/// else may guess.
#[cfg(target_os = "android")]
fn state_home() -> Option<PathBuf> {
    use std::io::Write as _;
    let line = format!(
        "kaya: attach was handed no state root, so the second act has \
nowhere to look for its marker and a relaunched scene cannot continue \
— dev.kaya.Kaya.attach and dev.kaya.KayaRing.attach take \
context.filesDir as their second argument \
(docs/tasks-s9-plan.md R6a)\n"
    );
    let _ = std::io::stderr().write_all(line.as_bytes());
    None
}

/// Called by the core's entry BEFORE the app thread is spawned. Act one
/// learns where to leave its marker; act two adopts one and becomes a
/// scene run with no environment of its own.
pub(crate) fn arm(state_root: Option<&Path>) {
    if std::env::var_os("KAYA_SELFTEST").is_some() {
        if let Some(dir) = dir(state_root) {
            // SAFETY: single-threaded — the app thread does not exist yet.
            unsafe { std::env::set_var(ENV_DIR, dir) };
        }
        return;
    }
    // On Apple the lane's door is the carve-out variable (R6a), so a
    // shipped app leaves here without touching the disk at all; the other
    // three are relaunched by the platform with nothing set, and this
    // module is behind `feature = "harness"` there.
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    if std::env::var_os("KAYA_LAUNCH_NOTIFICATION").is_none() {
        return;
    }
    let Some(dir) = dir(state_root) else { return };
    let marker = dir.join(MARKER);
    let Ok(text) = std::fs::read_to_string(&marker) else { return };
    // CONSUMED ON READ, so a stale marker cannot serve a later run.
    let _ = std::fs::remove_file(&marker);
    let Some((scene, steps)) = text.split_once('\n') else { return };
    let scene = scene.trim();
    if scene.is_empty() || steps.trim().is_empty() {
        return;
    }
    // THE LINE A RED ACT TWO NEEDS FIRST: what was adopted, and from
    // where. One write, like gtk.rs's kaya_diag.
    {
        use std::io::Write as _;
        let statements = steps
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .count();
        let line = format!(
            "KAYA_ACT2: the marker names scene {scene:?} with {statements} \
statement(s); consumed from {}\n",
            marker.display()
        );
        let _ = std::io::stderr().write_all(line.as_bytes());
    }
    // SAFETY: single-threaded — the app thread does not exist yet.
    unsafe {
        std::env::set_var("KAYA_SELFTEST", scene);
        std::env::set_var("KAYA_SELFTEST_SCRIPT", steps);
        std::env::set_var(ENV_DIR, &dir);
        std::env::set_var(ENV_VERDICT, dir.join(VERDICT));
    }
}
