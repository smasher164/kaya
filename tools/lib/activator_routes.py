"""The WinUI toast activator is revoked before the process leaves (docs/traps.md,
the toast activator a terminating process kept).

Every guest declares one id, so every guest registers one class id, and a guest
held in termination after its verdict kept that class in the SCM's table: the
next COM door was routed to the corpse and failed 0x8007000E after ~39 s. Only
a leg ordering that puts a lingering guest before a relaunch shows it, so this
reads the withdrawal on every exit path, and the door's record of the guests
alive at the push."""

from content_type_routes import flat
from kaya_gate import ROOT
from reveal_routes import blocks

WINUI = "crates/kaya/src/winui/mod.rs"
LIB = "crates/kaya/src/lib.rs"
DOOR = "tools/guest/relaunch-com.ps1"
INSTALL = "fn activator_install() -> Result<String, String> {"
WITHDRAW = "pub(crate) fn withdraw_activator() {"
RUN_CORE = "pub(crate) fn run_core(occ_tx: OccSink, tx_rx: Receiver<Transaction>) -> i32 {"
EXIT_HARD = "pub(crate) fn exit_hard(code: i32) -> ! {"
NEEDS = [
    (WINUI, INSTALL, "the registration keeps its cookie",
     "ACTIVATOR_COOKIE.store(cookie, std::sync::atomic::Ordering::SeqCst);"),
    (WINUI, WITHDRAW, "the withdrawal takes the cookie once",
     "let cookie = ACTIVATOR_COOKIE.swap(0, Ordering::SeqCst);"),
    (WINUI, WITHDRAW, "the withdrawal runs in the MTA",
     "unsafe { CoInitializeEx(std::ptr::null(), COINIT_MULTITHREADED) };"),
    (WINUI, WITHDRAW, "the withdrawal revokes the class",
     "windows::Win32::System::Com::CoRevokeClassObject(cookie)"),
    (WINUI, WITHDRAW, "the withdrawal is bounded",
     "rx.recv_timeout(std::time::Duration::from_secs(2))"),
]
ORDER = [
    (WINUI, RUN_CORE, "the orderly exit withdraws once Application::Start returns",
     'Application::Start(&callback).expect("Application::Start failed");', "withdraw_activator();"),
    (LIB, EXIT_HARD, "exit_hard withdraws before TerminateProcess",
     "winui::withdraw_activator();", "TerminateProcess(GetCurrentProcess(), code as u32);"),
]
DOOR_ORDER = [
    ("the door records the guests alive at the push",
     "Write-Guests 'at the push'", "$answer = [KayaRelaunchDoor]::Push("),
    ("the door records the guests alive at a refusal",
     "if ($answer -ne 'OK') {", "Write-Guests 'at the refusal'"),
]


def _ordered(text, first, then):
    a = text.find(flat(first))
    return a >= 0 and text.find(flat(then), a + len(flat(first))) >= 0


def findings(sources):
    out = []
    for rel, opener, label, need in NEEDS:
        body = blocks(sources[rel], opener)
        if len(body) != 1:
            out.append(f"toast activator: {opener} is defined {len(body)} times in {rel}, wanted once")
        elif flat(need) not in flat(body[0]):
            out.append(f"toast activator: {label} no longer holds — {opener} lacks {need}")
    for rel, opener, label, first, then in ORDER:
        body = blocks(sources[rel], opener)
        if len(body) != 1 or not _ordered(flat(body[0]), first, then):
            out.append(f"toast activator: {label} no longer holds in {rel} — a guest held in "
                       f"termination keeps the shared class and the next COM door fails 0x8007000E")
    door = flat(sources[DOOR])
    for label, first, then in DOOR_ORDER:
        if not _ordered(door, first, then):
            out.append(f"toast activator: {label} no longer holds in {DOOR}")
    return out


def run(g):
    sources = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in (WINUI, LIB, DOOR)}
    g.counted("toast activator clauses held", len(NEEDS) + len(ORDER) + len(DOOR_ORDER), floor=9)
    for line in findings(sources):
        g.finding(line)
    cuts = [
        (WINUI, "the cookie dropped, as shipped",
         r"\n\s+ACTIVATOR_COOKIE\.store\(cookie, std::sync::atomic::Ordering::SeqCst\);", "",
         "the registration keeps its cookie"),
        (LIB, "exit_hard leaving with the class registered",
         r"\n\s+#\[cfg\(windows\)\]\n\s+winui::withdraw_activator\(\);", "",
         "exit_hard withdraws before TerminateProcess"),
        (WINUI, "the orderly exit leaving with the class registered",
         r"(Application::Start\(&callback\)\.expect\(\"Application::Start failed\"\);)\n\s+withdraw_activator\(\);",
         r"\1", "the orderly exit withdraws"),
        (WINUI, "the revoke on the caller's apartment",
         r"\n\s+unsafe \{ CoInitializeEx\(std::ptr::null\(\), COINIT_MULTITHREADED\) \};\n(\s+let _ = tx\.send)",
         r"\n\1", "the withdrawal runs in the MTA"),
        (DOOR, "the door's refusal naming no guest",
         r"\n\s+Write-Guests 'at the refusal'", "", "alive at a refusal"),
    ]
    for rel, label, pattern, repl, want in cuts:
        broken = dict(sources)
        broken[rel] = g.doctor(f"toast activator: {label}", sources[rel], pattern, repl)
        g.negative(f"toast activator: {label}", lambda broken=broken: findings(broken), want=want)
