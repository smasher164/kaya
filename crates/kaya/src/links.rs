//! App links: the ONE door a URL takes into a kaya app, and the ONE
//! matcher that turns it into a declared route and its captures
//! (docs/app-links-plan.md §4).
//!
//! Every platform arm — the macOS Apple event, iOS's `onOpenURL`,
//! Android's intent, GApplication's `open`, Windows' protocol activation
//! — calls [`opened`] with the URL as the platform delivered it, and
//! parses nothing itself. The app declares its patterns as
//! `declare_link_route` records; the table lives here, so nine bindings
//! share one grammar instead of writing nine parsers.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use crate::protocol::{OccSink, Occurrence};

/// One segment of a declared pattern.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Seg {
    /// A literal segment, matching itself.
    Literal(String),
    /// `{name}`, capturing one non-empty segment under that name.
    Capture(String),
    /// `*`, the whole pattern: the catch-all, matched LAST whatever order
    /// it was declared in, whose one param `url` is the URL as delivered
    /// (docs/app-links-plan.md §4).
    Wildcard,
}

struct Route {
    id: u64,
    pattern: String,
    segs: Vec<Seg>,
}

static ROUTES: Mutex<Vec<Route>> = Mutex::new(Vec::new());

/// URLs that arrived before the app's routes were declared. THE COLD
/// DOOR IS THE REASON: macOS delivers a link 21 ms into the process,
/// before any window exists (docs/traps.md, 2026-09-09), and Windows
/// hands it to `GetActivatedEventArgs` at startup, so the URL beats the
/// app thread. [`flush_early`] drains it once the app's first
/// transaction has landed — which is where its routes are.
static EARLY: Mutex<Vec<String>> = Mutex::new(Vec::new());
static READY: AtomicBool = AtomicBool::new(false);

/// Where a matched link is emitted. Set by whichever core entry built
/// the process's occurrence channel (crates/kaya/src/lib.rs's `run`,
/// capi's ring, the interpreter platforms' presentation sink), never by
/// a backend.
static SINK: Mutex<Option<OccSink>> = Mutex::new(None);

pub(crate) fn set_sink(sink: OccSink) {
    *SINK.lock().unwrap_or_else(|e| e.into_inner()) = Some(sink);
}

/// The RING is every foreign guest's occurrence channel and is taken by
/// whichever entry starts the core — but on the interpreter platforms a
/// RUST guest has already registered its own mpsc above, and that one
/// wins. capi::take_core_ends is the only caller.
pub(crate) fn set_sink_unless_set(sink: OccSink) {
    let mut held = SINK.lock().unwrap_or_else(|e| e.into_inner());
    if held.is_none() {
        *held = Some(sink);
    }
}

/// Declare one route. A refusal FAULTS, like every other declaration
/// refusal in the core: a pattern nothing can match is a bug in the app,
/// and a link that silently reached no handler is what this whole slice
/// exists to stop.
pub(crate) fn declare(route: u64, pattern: &str) {
    if let Err(why) = try_declare(route, pattern) {
        panic!("kaya: link route \"{pattern}\" is {why}");
    }
    claim_platform_door();
}

/// AN APP THAT DECLARES NO ROUTE CLAIMS NOTHING. Both halves of the
/// Windows door are PER-USER SINGLETONS — the protocol registration's
/// last writer wins, and `FindOrRegisterForKey` hands one key per user —
/// and every kaya guest carries the same declared id, so a claim taken
/// unconditionally at launch would have made five of the pooled windows
/// lane's six legs exit as redirected instances (measured by the windows
/// agent, 2026-09-09). So the claim rides the FIRST declared route.
/// Idempotent on both sides.
fn claim_platform_door() {
    #[cfg(target_os = "windows")]
    {
        static CLAIMED: AtomicBool = AtomicBool::new(false);
        if !CLAIMED.swap(true, Ordering::AcqRel) {
            crate::backend::links_declared();
        }
    }
}

/// The refusal half, testable: `Err` carries the clause that follows
/// `is` in the sentence above.
fn try_declare(route: u64, pattern: &str) -> Result<(), String> {
    let segs = parse_pattern(pattern)?;
    let mut routes = ROUTES.lock().unwrap_or_else(|e| e.into_inner());
    // THE SAME SHAPE, not the same text: `task/{key}` and `task/{other}`
    // are one route spelled twice, and the second could never fire.
    if let Some(other) = routes.iter().find(|r| same_shape(&r.segs, &segs)) {
        return Err(format!(
            "already declared (route {}, \"{}\") — a URL matches the FIRST \
             route that takes it, so the second could never fire",
            other.id, other.pattern
        ));
    }
    routes.push(Route { id: route, pattern: pattern.to_owned(), segs });
    Ok(())
}

fn same_shape(a: &[Seg], b: &[Seg]) -> bool {
    a.len() == b.len()
        && a.iter().zip(b).all(|(x, y)| match (x, y) {
            (Seg::Literal(x), Seg::Literal(y)) => x == y,
            (Seg::Capture(_), Seg::Capture(_)) => true,
            (Seg::Wildcard, Seg::Wildcard) => true,
            _ => false,
        })
}

fn parse_pattern(pattern: &str) -> Result<Vec<Seg>, String> {
    if pattern.is_empty() {
        return Err("empty — a route matches the path a URL carries after \
                    the scheme, and an empty pattern names none"
            .to_string());
    }
    if pattern == "*" {
        return Ok(vec![Seg::Wildcard]);
    }
    let mut segs = Vec::new();
    for raw in pattern.split('/') {
        if raw == "*" {
            return Err(format!(
                "malformed at segment \"*\": the catch-all is the WHOLE pattern \
                 \"*\" or nothing — it takes every URL no other route did, so it \
                 cannot sit inside a path (\"{pattern}\")"
            ));
        }
        if raw.is_empty() {
            return Err(format!(
                "empty in one of its segments (\"{pattern}\" splits on \"/\" \
                 into {} parts and one of them is nothing) — no URL path \
                 carries an empty segment, so nothing could match it",
                pattern.split('/').count()
            ));
        }
        if raw.contains('{') || raw.contains('}') {
            let name = raw.strip_prefix('{').and_then(|r| r.strip_suffix('}'));
            match name {
                Some(name) if !name.is_empty() && !name.contains(['{', '}']) => {
                    segs.push(Seg::Capture(name.to_owned()))
                }
                _ => {
                    return Err(format!(
                        "malformed at segment \"{raw}\": a capture is a WHOLE \
                         segment spelled \"{{name}}\", so a brace anywhere \
                         else in one is an opening this pattern never closes"
                    ))
                }
            }
        } else {
            segs.push(Seg::Literal(raw.to_owned()));
        }
    }
    Ok(segs)
}

/// THE ONE DOOR. Thread-safe: a platform arm may call it from any
/// thread, at any time, including before the app thread exists.
pub(crate) fn opened(url: &str) {
    // The EARLY lock FIRST in both places, so an arrival racing the
    // flush cannot be stranded and the two locks cannot deadlock.
    let mut early = EARLY.lock().unwrap_or_else(|e| e.into_inner());
    if !READY.load(Ordering::Acquire) {
        early.push(url.to_owned());
        return;
    }
    drop(early);
    deliver(url);
}

/// The app's first transaction has landed, so its routes are declared:
/// everything the platform handed over before then is matched now, in
/// arrival order, and is the first thing the app reads. Called once, at
/// the end of the core's first applied batch (crates/kaya/src/scene.rs).
pub(crate) fn flush_early() {
    let mut early = EARLY.lock().unwrap_or_else(|e| e.into_inner());
    if READY.swap(true, Ordering::AcqRel) {
        return;
    }
    let queued: Vec<String> = early.drain(..).collect();
    // The lock is HELD across the deliveries on purpose: an arrival on
    // another thread mid-drain would otherwise overtake the queue.
    for url in queued {
        deliver(&url);
    }
}

fn deliver(url: &str) {
    let (route, params) = match_url(url);
    if route == 0 {
        announce_miss(url);
    }
    let sink = SINK.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(sink) = sink.as_ref() {
        sink.send(Occurrence::LinkOpened { route, url: url.to_owned(), params });
    }
}

/// The standing silent-drop rule (docs/app-links-plan.md L2): a link
/// nothing claimed says so, and says what WAS declared — the reader's
/// question is always "then what did I declare?". ONE WRITE, like
/// app.rs's notification_dropped: an eprintln issues a write per format
/// fragment and another thread's line lands inside it.
fn announce_miss(url: &str) {
    use std::io::Write as _;
    let routes = ROUTES.lock().unwrap_or_else(|e| e.into_inner());
    let line = if routes.is_empty() {
        format!(
            "kaya: link {url} matched no route — no route is declared \
             (Messages::link)\n"
        )
    } else {
        let patterns: Vec<&str> = routes.iter().map(|r| r.pattern.as_str()).collect();
        format!(
            "kaya: link {url} matched no route — {} declared: {}\n",
            patterns.len(),
            patterns.join(", ")
        )
    };
    drop(routes);
    let _ = std::io::stderr().write_all(line.as_bytes());
}

/// The route that takes this URL and the params it carries; route 0 and
/// no params when none does.
fn match_url(url: &str) -> (u64, Vec<(String, String)>) {
    let Some((path, query)) = split_url(url) else { return (0, Vec::new()) };
    let segments: Vec<&str> = path
        .split('/')
        .skip_while(|s| s.is_empty())
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .skip_while(|s| s.is_empty())
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    let routes = ROUTES.lock().unwrap_or_else(|e| e.into_inner());
    for route in routes.iter().filter(|r| r.segs != [Seg::Wildcard]) {
        let Some(mut params) = match_segments(&route.segs, &segments) else { continue };
        // THE QUERY JOINS THE PARAMS, and a CAPTURE WINS A CLASH: the
        // pattern is the app's own statement about the URL and the query
        // is whoever composed the link.
        for (name, value) in query_pairs(query) {
            if !params.iter().any(|(n, _)| *n == name) {
                params.push((name, value));
            }
        }
        return (route.id, params);
    }
    // THE CATCH-ALL LAST, whatever order it was declared in: a `*` declared
    // first must not shadow the routes the app spelled out.
    if let Some(any) = routes.iter().find(|r| r.segs == [Seg::Wildcard]) {
        return (any.id, vec![("url".to_string(), url.to_string())]);
    }
    (0, Vec::new())
}

fn match_segments(segs: &[Seg], segments: &[&str]) -> Option<Vec<(String, String)>> {
    if segs.len() != segments.len() {
        return None;
    }
    let mut params = Vec::new();
    for (seg, got) in segs.iter().zip(segments) {
        match seg {
            Seg::Literal(want) => {
                if want != got {
                    return None;
                }
            }
            Seg::Capture(name) => {
                // A capture takes ONE NON-EMPTY segment: `task//` must
                // not read as a task whose key is nothing.
                if got.is_empty() {
                    return None;
                }
                params.push((name.clone(), percent_decode(got)));
            }
            // Never here: match_url keeps the catch-all out of this pass.
            Seg::Wildcard => return None,
        }
    }
    Some(params)
}

/// The matched string and the query, per §4: everything after
/// `<scheme>://` for the app's own scheme, everything after the HOST for
/// a declared web host, and `None` for a URL this app never claimed. The
/// fragment is dropped.
fn split_url(url: &str) -> Option<(&str, &str)> {
    let url = url.split('#').next().unwrap_or(url);
    let (given, rest) = url.split_once("://")?;
    let ours = scheme();
    let rest = if given.eq_ignore_ascii_case(&ours) {
        rest
    } else if given.eq_ignore_ascii_case("https") || given.eq_ignore_ascii_case("http") {
        let (host, tail) = rest.split_once('/').unwrap_or((rest, ""));
        let host = host.split(':').next().unwrap_or(host);
        if !web_hosts().iter().any(|h| h.eq_ignore_ascii_case(host)) {
            return None;
        }
        tail
    } else {
        return None;
    };
    Some(match rest.split_once('?') {
        Some((path, query)) => (path, query),
        None => (rest, ""),
    })
}

fn query_pairs(query: &str) -> Vec<(String, String)> {
    if query.is_empty() {
        return Vec::new();
    }
    query
        .split('&')
        .filter(|pair| !pair.is_empty())
        .map(|pair| match pair.split_once('=') {
            Some((name, value)) => (percent_decode(name), percent_decode(value)),
            None => (percent_decode(pair), String::new()),
        })
        .collect()
}

/// `%XX` only. `+` STAYS A PLUS: it means a space in an HTML form body,
/// not in a URL, and a route's params come off a path as often as off a
/// query — one rule for both halves rather than two that disagree.
fn percent_decode(s: &str) -> String {
    if !s.contains('%') {
        return s.to_owned();
    }
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok();
            if let Some(byte) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(byte);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    // An undecodable byte sequence is the link's own, not ours: keep the
    // text rather than inventing a refusal the platforms do not have.
    String::from_utf8(out).unwrap_or_else(|_| s.to_owned())
}

/// The scheme this app owns: the manifest's `[links] scheme`, or the
/// DECLARED ID when it says nothing. A reverse-DNS string is a valid URL
/// scheme (RFC 3986) and unique by construction, so an app that declares
/// nothing still has a working link (docs/app-links-plan.md §4).
pub(crate) fn scheme() -> String {
    static SCHEME: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    SCHEME
        .get_or_init(|| {
            crate::scene::declared_links()
                .0
                .or_else(crate::scene::declared_id)
                .unwrap_or_default()
        })
        .clone()
}

/// The web-link hosts the manifest declares. Empty by default: a web
/// link needs a served HTTPS domain to verify against, and no lane has
/// one (docs/app-links-plan.md L6).
pub(crate) fn web_hosts() -> Vec<String> {
    static HOSTS: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();
    HOSTS.get_or_init(|| crate::scene::declared_links().1).clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The table is process-global, so the tests that touch it take one
    /// lock and put it back the way they found it.
    static TEST: Mutex<()> = Mutex::new(());

    fn with_routes<R>(patterns: &[(u64, &str)], body: impl FnOnce() -> R) -> R {
        let _guard = TEST.lock().unwrap_or_else(|e| e.into_inner());
        ROUTES.lock().unwrap_or_else(|e| e.into_inner()).clear();
        for (id, pattern) in patterns {
            declare(*id, pattern);
        }
        let out = body();
        ROUTES.lock().unwrap_or_else(|e| e.into_inner()).clear();
        out
    }

    /// The scene's own URLs: the tree declares no `[links]` table, so the
    /// scheme IS the declared id (docs/app-links-plan.md §4).
    fn params(path: &str) -> (u64, Vec<(String, String)>) {
        match_url(&format!("{}://{path}", scheme()))
    }

    #[test]
    fn literal_segments_match_themselves() {
        with_routes(&[(7, "today"), (8, "projects/all")], || {
            assert_eq!(params("today").0, 7);
            assert_eq!(params("projects/all").0, 8);
            // A trailing slash is the same path.
            assert_eq!(params("today/").0, 7);
            // Neither a prefix nor a suffix of a route matches it.
            assert_eq!(params("projects").0, 0);
            assert_eq!(params("today/all").0, 0);
        })
    }

    #[test]
    fn one_capture_and_several() {
        with_routes(&[(1, "task/{key}"), (2, "project/{project}/task/{key}")], || {
            let (route, got) = params("task/t2");
            assert_eq!(route, 1);
            assert_eq!(got, vec![("key".to_string(), "t2".to_string())]);
            let (route, got) = params("project/kitchen/task/t9");
            assert_eq!(route, 2);
            assert_eq!(
                got,
                vec![
                    ("project".to_string(), "kitchen".to_string()),
                    ("key".to_string(), "t9".to_string()),
                ]
            );
            // A capture takes ONE segment and never an empty one.
            assert_eq!(params("task/a/b").0, 0);
            assert_eq!(params("task//").0, 0);
        })
    }

    #[test]
    fn the_query_joins_the_params_and_a_capture_wins_a_clash() {
        with_routes(&[(1, "task/{key}")], || {
            let (route, got) = params("task/t2?focus=notes&key=NOPE&bare");
            assert_eq!(route, 1);
            assert_eq!(
                got,
                vec![
                    ("key".to_string(), "t2".to_string()),
                    ("focus".to_string(), "notes".to_string()),
                    ("bare".to_string(), String::new()),
                ]
            );
        })
    }

    #[test]
    fn the_fragment_is_dropped_and_percent_escapes_decode() {
        with_routes(&[(1, "task/{key}")], || {
            let (route, got) = params("task/t2#scrollto");
            assert_eq!(route, 1);
            assert_eq!(got[0].1, "t2");
            let (_, got) = params("task/a%20b?q=%C3%A9");
            assert_eq!(got[0].1, "a b");
            assert_eq!(got[1].1, "é");
        })
    }

    #[test]
    fn a_web_host_is_stripped_and_an_undeclared_one_matches_nothing() {
        with_routes(&[(1, "tasks/{key}")], || {
            // No host is declared in the test tree's manifest, so the
            // web form reaches no route at all.
            assert_eq!(match_url("https://example.com/tasks/t1").0, 0);
            // Nor does a scheme this app does not own.
            assert_eq!(match_url("mailto://tasks/t1").0, 0);
            assert_eq!(match_url("not a url at all").0, 0);
        })
    }

    #[test]
    fn a_web_host_strips_to_the_path_after_it() {
        // split_url is what the host rule lives in; drive it directly
        // with a host list this tree's manifest does not have to carry.
        assert_eq!(split_url("https://example.com/tasks/t1?a=1"), None);
        let scheme = scheme();
        let url = format!("{scheme}://tasks/t1?a=1");
        assert_eq!(split_url(&url), Some(("tasks/t1", "a=1")));
        let url = format!("{scheme}://tasks/t1");
        assert_eq!(split_url(&url), Some(("tasks/t1", "")));
    }

    #[test]
    fn a_wildcard_route_takes_what_no_other_route_did_and_is_matched_last() {
        // Declared FIRST on purpose: order must not let it shadow the rest.
        with_routes(&[(9, "*"), (1, "task/{key}"), (2, "{section}")], || {
            assert_eq!(params("task/t2").0, 1);
            assert_eq!(params("today").0, 2);
            let (route, got) = params("nothing/here?x=1");
            assert_eq!(route, 9);
            assert_eq!(
                got,
                vec![("url".to_string(), format!("{}://nothing/here?x=1", scheme()))]
            );
            // A scheme this app never claimed is still nobody's.
            assert_eq!(match_url("other://nothing/here").0, 0);
        })
    }

    #[test]
    fn a_wildcard_inside_a_path_or_declared_twice_is_refused() {
        let _guard = TEST.lock().unwrap_or_else(|e| e.into_inner());
        ROUTES.lock().unwrap_or_else(|e| e.into_inner()).clear();
        assert!(try_declare(1, "task/*").unwrap_err().starts_with("malformed at segment \"*\""));
        assert!(try_declare(1, "*/x").unwrap_err().starts_with("malformed at segment \"*\""));
        try_declare(1, "*").expect("one catch-all stands");
        assert!(try_declare(2, "*").unwrap_err().starts_with("already declared (route 1"));
        ROUTES.lock().unwrap_or_else(|e| e.into_inner()).clear();
    }

    #[test]
    fn a_malformed_or_repeated_pattern_is_refused_by_name() {
        let _guard = TEST.lock().unwrap_or_else(|e| e.into_inner());
        ROUTES.lock().unwrap_or_else(|e| e.into_inner()).clear();
        assert!(try_declare(1, "").unwrap_err().starts_with("empty —"));
        assert!(try_declare(1, "task//{key}").unwrap_err().starts_with("empty in"));
        assert!(try_declare(1, "task/{key").unwrap_err().starts_with("malformed"));
        assert!(try_declare(1, "task/a{key}b").unwrap_err().starts_with("malformed"));
        assert!(try_declare(1, "task/{}").unwrap_err().starts_with("malformed"));
        try_declare(1, "task/{key}").expect("the first declaration stands");
        // A REPEAT IS THE SAME SHAPE, not the same text: a second route
        // spelled with another capture NAME could never fire either.
        let why = try_declare(2, "task/{other}").unwrap_err();
        assert!(why.starts_with("already declared (route 1"), "{why}");
        ROUTES.lock().unwrap_or_else(|e| e.into_inner()).clear();
    }

    /// R3's queue, one platform over (docs/tasks-s9-plan.md): a URL that
    /// arrived before the app declared anything is delivered FIRST, in
    /// arrival order, once the first transaction lands.
    #[test]
    fn the_early_queue_delivers_first_and_in_order() {
        let _guard = TEST.lock().unwrap_or_else(|e| e.into_inner());
        ROUTES.lock().unwrap_or_else(|e| e.into_inner()).clear();
        EARLY.lock().unwrap_or_else(|e| e.into_inner()).clear();
        READY.store(false, Ordering::Release);
        let (tx, rx) = std::sync::mpsc::channel();
        set_sink(OccSink::Mpsc(tx));

        let scheme = scheme();
        opened(&format!("{scheme}://task/first"));
        opened(&format!("{scheme}://task/second"));
        assert!(rx.try_recv().is_err(), "nothing is delivered before the routes are");

        declare(11, "task/{key}");
        flush_early();
        let mut keys = Vec::new();
        while let Ok(crate::protocol::Inbox::Occ(Occurrence::LinkOpened { route, params, .. })) =
            rx.try_recv()
        {
            assert_eq!(route, 11);
            keys.push(params[0].1.clone());
        }
        assert_eq!(keys, vec!["first".to_string(), "second".to_string()]);

        // And once ready, an arrival is delivered at once.
        opened(&format!("{scheme}://task/third"));
        match rx.try_recv() {
            Ok(crate::protocol::Inbox::Occ(Occurrence::LinkOpened { route, params, .. })) => {
                assert_eq!(route, 11);
                assert_eq!(params[0].1, "third");
            }
            Ok(_) => panic!("what arrived after the flush was not a link"),
            Err(e) => panic!("the third link never arrived ({e})"),
        }

        *SINK.lock().unwrap_or_else(|e| e.into_inner()) = None;
        READY.store(false, Ordering::Release);
        ROUTES.lock().unwrap_or_else(|e| e.into_inner()).clear();
    }

    /// The manifest's default rule, the half tools/lib/packaging/
    /// identity.py answers for the BUILD: this tree declares no
    /// `[links]` table, so the scheme IS the declared id.
    #[test]
    fn the_scheme_defaults_to_the_declared_id() {
        assert_eq!(
            scheme(),
            crate::scene::declared_id().expect("the shipped identity.toml"),
        );
        assert!(web_hosts().is_empty());
    }
}
