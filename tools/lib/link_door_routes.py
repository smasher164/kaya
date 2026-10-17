"""The WinUI link door's single-instance redirect (docs/traps.md, the link
redirect that exited before its owner read it).

links.steps passes with a redirector that leaves the instant its call returns
whenever the owner is quick, which is every unloaded run; under matrix load the
link was lost and the owner then died in the SDK. No scene can hold the wait, so
this reads it: the redirect is joined on the MTA before the process leaves, and
both halves write a verb-trace line past the ring, since the owner that dies
there never dumps its ring and the redirector has no log a runner keeps."""

from content_type_routes import flat
from kaya_gate import ROOT
from reveal_routes import blocks

WINUI = "crates/kaya/src/winui/mod.rs"
STARTUP = "fn links_startup_once() {"
OWNER = "fn become_owner() -> Option<&'static AppInstance> {"
REDIRECT = [
    ("the redirect is joined on the MTA",
     "let handed = on_notify(move || {\ntarget\n.RedirectActivationToAsync(&args)\n.and_then(|action| action.join())"),
    ("the redirector writes what it did past the ring",
     'crate::vtrace::line(&format!("link_redirect pid={} {text}", std::process::id()));'),
    ("the redirector says how the redirect ended",
     "Some(Ok(())) => said(format!(\"redirected {url} to pid {owner}; the redirect completed in {ms}ms\")),"),
]
ACTIVATED = [
    ("the owner writes each activation past the ring",
     'crate::vtrace::line(&format!("link_activated pid={} url={url}", std::process::id()));'),
]


def findings(src):
    out = []
    for opener, needs in ((STARTUP, REDIRECT), (OWNER, ACTIVATED)):
        body = blocks(src, opener)
        if len(body) != 1:
            out.append(f"link door: {opener} is defined {len(body)} times in {WINUI}, wanted once")
            continue
        for label, need in needs:
            if flat(need) not in flat(body[0]):
                out.append(f"link door: {label} no longer holds — {opener} lacks {need.splitlines()[0]}")
    body = blocks(src, STARTUP)
    if len(body) == 1:
        text = flat(body[0])
        joined, leaves = text.find(flat("let handed = on_notify(")), text.find(flat("crate::exit_hard(0);"))
        if joined < 0 or leaves < 0 or leaves < joined:
            out.append("link door: the redirector leaves before its redirect is joined — under load the "
                       "owner never reads the link")
    return out


def run(g):
    src = (ROOT / WINUI).read_text(encoding="utf-8")
    g.counted("link door clauses held", len(REDIRECT) + len(ACTIVATED) + 1, floor=5)
    for line in findings(src):
        g.finding(line)
    cuts = [
        ("the redirector leaving at the call's return, as shipped",
         r"\.and_then\(\|action\| action\.join\(\)\)", ".map(|_action| ())", "the redirect is joined"),
        ("the redirector leaving before the join",
         r"(\n\s+let started = std::time::Instant::now\(\);)", r"\n        crate::exit_hard(0);\1",
         "leaves before its redirect is joined"),
        ("the redirector's line kept in the ring",
         r'crate::vtrace::line\(&format!\("link_redirect pid=\{\} \{text\}", std::process::id\(\)\)\);',
         'crate::vtrace::note("link_redirect", format_args!("{text}"));', "writes what it did past the ring"),
        ("the owner's activation unrecorded",
         r'\n\s+crate::vtrace::line\(&format!\("link_activated pid=\{\} url=\{url\}", std::process::id\(\)\)\);',
         "", "writes each activation past the ring"),
    ]
    for label, pattern, repl, want in cuts:
        broken = g.doctor(f"link door: {label}", src, pattern, repl)
        g.negative(f"link door: {label}", lambda broken=broken: findings(broken), want=want)
