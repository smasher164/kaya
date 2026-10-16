//! A pid LaunchServices still holds another app's record at
//! (docs/traps.md, the Preview a Go guest's checkin relaunched).

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI32, Ordering};

use objc2_app_kit::NSRunningApplication;
use objc2_foundation::NSBundle;

/// `<parent pid>:<depth>`, honoured only when the parent is ours.
const RESPAWN_ENV: &str = "KAYA_LS_RESPAWN";
const MAX_DEPTH: u32 = 3;

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Held {
    pub name: String,
    pub bundle: Option<String>,
    pub exe: Option<PathBuf>,
}

#[derive(Debug, PartialEq)]
pub(crate) enum Verdict {
    Free,
    Own,
    Foreign,
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
}

pub(crate) fn verdict(held: Option<&Held>, own_exe: &Path, own_bundle: Option<&str>) -> Verdict {
    match held {
        None => Verdict::Free,
        Some(h)
            if h.exe.as_deref().is_some_and(|e| same_file(e, own_exe))
                && h.bundle.as_deref() == own_bundle =>
        {
            Verdict::Own
        }
        Some(_) => Verdict::Foreign,
    }
}

fn own_bundle_id() -> Option<String> {
    NSBundle::mainBundle().bundleIdentifier().map(|s| s.to_string())
}

fn record_at(pid: i32) -> Option<Held> {
    let app = NSRunningApplication::runningApplicationWithProcessIdentifier(pid)?;
    Some(Held {
        name: app.localizedName().map(|s| s.to_string()).unwrap_or_default(),
        bundle: app.bundleIdentifier().map(|s| s.to_string()),
        exe: app.executableURL().and_then(|u| u.path()).map(|s| PathBuf::from(s.to_string())),
    })
}

fn describe(h: &Held) -> String {
    format!(
        "{} ({}, {})",
        if h.name.is_empty() { "<no name>" } else { &h.name },
        h.bundle.as_deref().unwrap_or("no bundle id"),
        h.exe.as_deref().map(|p| p.display().to_string()).unwrap_or_else(|| "no executable".into())
    )
}

/// The depth this process was respawned at, when its parent is the one that did it.
fn inherited_depth() -> u32 {
    let Ok(v) = std::env::var(RESPAWN_ENV) else { return 0 };
    let Some((parent, depth)) = v.split_once(':') else { return 0 };
    let ppid = unsafe { libc::getppid() };
    if parent.parse::<i32>().ok() != Some(ppid) {
        return 0;
    }
    let depth = depth.parse().unwrap_or(0);
    watch_parent(ppid);
    depth
}

/// The respawning parent may be SIGKILLed (the lane's `timeout`), and then
/// nothing forwards it; the child leaves with it.
fn watch_parent(ppid: i32) {
    std::thread::Builder::new()
        .name("kaya-ls-parent".into())
        .spawn(move || unsafe {
            let kq = libc::kqueue();
            if kq < 0 {
                return;
            }
            let mut ev: libc::kevent = std::mem::zeroed();
            ev.ident = ppid as usize;
            ev.filter = libc::EVFILT_PROC;
            ev.flags = libc::EV_ADD | libc::EV_ONESHOT;
            ev.fflags = libc::NOTE_EXIT;
            if libc::kevent(kq, &ev, 1, std::ptr::null_mut(), 0, std::ptr::null()) < 0 {
                if libc::getppid() != ppid {
                    libc::_exit(137);
                }
                return;
            }
            let mut out: libc::kevent = std::mem::zeroed();
            if libc::kevent(kq, std::ptr::null(), 0, &mut out, 1, std::ptr::null()) == 1 {
                libc::_exit(137);
            }
        })
        .ok();
}

static CHILD: AtomicI32 = AtomicI32::new(0);

extern "C" fn forward(sig: libc::c_int) {
    let child = CHILD.load(Ordering::SeqCst);
    if child > 0 {
        unsafe { libc::kill(child, sig) };
    }
}

const FORWARDED: [libc::c_int; 4] = [libc::SIGTERM, libc::SIGINT, libc::SIGHUP, libc::SIGQUIT];

/// Before anything checks in with LaunchServices: a check-in is matched to
/// whatever record already sits at this pid, so a process given a dead
/// app's pid takes that app's ASN and bundle id. Such a process runs again
/// as its own child under a fresh pid and never checks in itself.
pub(crate) fn claim_own_identity() {
    let depth = inherited_depth();
    let pid = std::process::id() as i32;
    let held = record_at(pid);
    let Ok(own) = std::env::current_exe() else {
        if let Some(h) = &held {
            panic!(
                "kaya: pid {pid} carries LaunchServices' record of {} and this process \
                 cannot read its own executable path to tell whether that is its own launch",
                describe(h)
            );
        }
        return;
    };
    match verdict(held.as_ref(), &own, own_bundle_id().as_deref()) {
        Verdict::Free | Verdict::Own => return,
        Verdict::Foreign => {}
    }
    let held = held.expect("a Foreign verdict has a record");
    if depth >= MAX_DEPTH {
        panic!(
            "kaya: pid {pid} carries LaunchServices' record of {} after {depth} respawns, each \
             landing on another app's record; refusing to check in as that app",
            describe(&held)
        );
    }
    respawn(pid, depth + 1, &own, &held);
}

fn respawn(pid: i32, depth: u32, own: &Path, held: &Held) -> ! {
    use std::os::unix::process::{CommandExt, ExitStatusExt};
    let mut args = std::env::args_os();
    let arg0 = args.next().unwrap_or_else(|| own.as_os_str().to_owned());
    let mut cmd = std::process::Command::new(own);
    cmd.arg0(arg0)
        .args(args)
        .env(RESPAWN_ENV, format!("{pid}:{depth}"))
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit());
    for sig in FORWARDED {
        unsafe { libc::signal(sig, forward as *const () as libc::sighandler_t) };
    }
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => panic!(
            "kaya: pid {pid} carries LaunchServices' record of {}, and running {} again under a \
             fresh pid failed: {e}",
            describe(held),
            own.display()
        ),
    };
    CHILD.store(child.id() as i32, Ordering::SeqCst);
    eprintln!(
        "kaya: pid {pid} carries LaunchServices' record of {}; checking in here would register \
         this process as that app, so it runs again as pid {} (respawn {depth})",
        describe(held),
        child.id()
    );
    let status = loop {
        match child.wait() {
            Ok(s) => break s,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => panic!("kaya: waiting for the respawned pid {} failed: {e}", child.id()),
        }
    };
    if let Some(code) = status.code() {
        std::process::exit(code);
    }
    let sig = status.signal().unwrap_or(libc::SIGKILL);
    unsafe {
        libc::signal(sig, libc::SIG_DFL);
        libc::raise(sig);
    }
    std::process::exit(128 + sig);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn held(exe: Option<&str>) -> Held {
        Held { name: "Preview".into(), bundle: Some("com.apple.Preview".into()), exe: exe.map(PathBuf::from) }
    }

    #[test]
    fn a_record_at_this_pid_is_ours_only_when_it_names_our_executable() {
        let own = std::env::current_exe().unwrap();
        let preview_id = Some("com.apple.Preview");
        assert_eq!(verdict(None, &own, None), Verdict::Free);
        assert_eq!(verdict(Some(&held(own.to_str())), &own, preview_id), Verdict::Own);
        let preview = "/System/Applications/Preview.app/Contents/MacOS/Preview";
        assert_eq!(verdict(Some(&held(Some(preview))), &own, None), Verdict::Foreign);
        assert_eq!(verdict(Some(&held(None)), &own, None), Verdict::Foreign);
        // A record this executable adopted earlier still names another app's bundle id.
        assert_eq!(verdict(Some(&held(own.to_str())), &own, None), Verdict::Foreign);
    }

    #[test]
    fn this_test_process_holds_no_foreign_record() {
        let pid = std::process::id() as i32;
        let own = std::env::current_exe().unwrap();
        assert_ne!(
            verdict(record_at(pid).as_ref(), &own, own_bundle_id().as_deref()),
            Verdict::Foreign
        );
    }
}
