#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, Gate, dev_shell_or_die

dev_shell_or_die()

# The roadmap page, generated (docs/HACKING.md, Roadmap). Judgment lives in
# docs/roadmap/editorial.toml, research data in docs/roadmap/features.toml.

import argparse
import datetime
import difflib
import html
import html.parser
import os
import re
import subprocess
import tomllib

FEATURES = ROOT / "docs/roadmap/features.toml"
EDITORIAL = ROOT / "docs/roadmap/editorial.toml"
LEDGER = ROOT / "docs/deferred.md"
MEASUREMENTS = ROOT / "docs/measurements"
OUT = ROOT / "target/roadmap"
GITHUB = "https://github.com/smasher164/kaya/blob"

TIERS = ["shipped", "now", "next", "later", "hold"]
TIER_NAME = {t: t.capitalize() for t in TIERS}
COST_RANK = {"S": 1, "M": 2, "L": 3, "XL": 4, "XXL": 5}
COST_LABEL = {
    "S": ("S · about a day",
          "about a day: a prop on existing kinds, or a verb; native on every lane"),
    "M": ("M · one to two days",
          "one to two days: a new kind with a native control on all four backends"),
    "L": ("L · two to four days",
          "two to four days: a system surface with per-platform permission or session models, "
          "or a kind that needs one synthesized tier"),
    "XL": ("XL · four to seven days",
           "four to seven days: a subsystem with core semantics, or several embedders"),
    "XXL": ("XXL · weeks", "weeks: touches packaging on five stores, or embeds the web platform"),
}
LANE_OS = ["macOS", "iOS", "Linux", "Windows", "Android"]
LANE_KIND = {"N": ("n", "native", "N"), "S": ("s", "synthesized", "S"),
             "C": ("c", "carve-out", "C"), "x": ("x", "not applicable", "·")}
FEATURE_FIELDS = {"slug", "name", "group", "need", "parity", "cost", "lanes", "need_why",
                  "parity_why", "shape", "kaya", "shipped", "shipped_note", "tier",
                  "tier_reason", "amended"}
MENU_STATUS = {"shipped", "open", "held", "needs ruling"}
LEDGER_PREFIXES = ["RULING WANTED", "RULING", "BUILD", "DEFECT", "WATCH", "DEFER", "HOLD",
                   "MAYBE", "GAP", "DESIGN", "RESEARCH", "NOTE", "COST", "INVESTIGATE"]
LEDGER_GROUPS = ["BUILD", "DEFECT", "RULING / RULING WANTED", "WATCH", "DEFER", "HOLD",
                 "MAYBE", "GAP", "DESIGN", "RESEARCH", "NOTE", "COST", "INVESTIGATE",
                 "untagged"]
DONE_WORDS = re.compile(r"\b(BUILT|LANDED|COMPLETE|SHIPPED)\b")
HASH = re.compile(r"(?<![\w-])(?=[0-9a-f]*[0-9])(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}(?![\w-])")
PATH = re.compile(r"(?<![\w./~-])((?:docs|tools)/[\w./-]*?\.(?:md|steps|py|toml))(?![\w])")
GH_PATH = re.compile(re.escape(GITHUB) + r"/[^/\s\"']+/([\w./-]+?)(?=[#\"'\s<]|$)")
ITEM = re.compile(r"#item-([\w-]+)")
REVIEW_REF = re.compile(r"\{review:([\w-]+)\}")


def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True,
                          text=True, encoding="utf-8").stdout


def unknown_commits(hashes):
    if not hashes:
        return []
    out = subprocess.run(["git", "-C", str(ROOT), "cat-file", "--batch-check"],
                         input="".join(f"{h}^{{commit}}\n" for h in hashes),
                         capture_output=True, text=True, encoding="utf-8", check=True).stdout
    return [h for h, line in zip(hashes, out.splitlines()) if not line.split()[1:2] == ["commit"]]


def strings(v):
    if isinstance(v, str):
        yield v
    elif isinstance(v, list):
        for x in v:
            yield from strings(x)
    elif isinstance(v, dict):
        for x in v.values():
            yield from strings(x)


def ledger_entries(text):
    lines = text.splitlines()
    heads = [i for i, line in enumerate(lines) if line.startswith("## ")]
    entries = []
    for k, i in enumerate(heads):
        end = heads[k + 1] if k + 1 < len(heads) else len(lines)
        head = lines[i][3:].strip()
        entries.append({"line": i + 1, "head": head, "struck": head.startswith("~~"),
                        "text": "\n".join(lines[i:end])})
    return entries


def plan_status(path):
    lines = (ROOT / path).read_text(encoding="utf-8").splitlines()
    for i, line in enumerate(lines[:20]):
        if line.lstrip("*_ ").startswith("Status:"):
            para = []
            for more in lines[i:]:
                if not more.strip():
                    break
                para.append(more)
            return " ".join(para)
    return ""


def tier_by_rule(f):
    n, c, p = f["need"], COST_RANK[f["cost"]], f["parity"]
    if (n >= 4 and c <= 2) or (n == 5 and c == 3):
        return "now"
    if n == 4 and c <= 4:
        return "next"
    if n == 3 and c <= 2 and p >= 4:
        return "next"
    if n == 3:
        return "later"
    if n <= 2 and (c >= 4 or "C" in f["lanes"]):
        return "hold"
    return "later"


def score(f):
    return 2 * f["need"] + f["parity"] - 1.5 * COST_RANK[f["cost"]]


# ------------------------------------------------------------------ the wall


def check(features_path, editorial_path):
    """Every refusal the page has, as sentences; empty means renderable."""
    bad = []
    feats = tomllib.loads(features_path.read_text(encoding="utf-8")).get("feature", [])
    ed = tomllib.loads(editorial_path.read_text(encoding="utf-8"))
    slugs = {}
    for f in feats:
        s = f.get("slug", "?")
        if s in slugs:
            bad.append(f"feature {s!r} appears twice in {features_path.name}; give one a new "
                       f"slug or delete the copy")
        slugs[s] = f
        missing = {"slug", "name", "group", "need", "parity", "cost", "lanes", "need_why",
                   "parity_why", "shape", "kaya"} - set(f)
        extra = set(f) - FEATURE_FIELDS
        if missing or extra:
            bad.append(f"feature {s!r}: missing {sorted(missing)} / unknown {sorted(extra)} "
                       f"fields; the fields are {sorted(FEATURE_FIELDS)}")
            continue
        if f["cost"] not in COST_RANK or not (1 <= f["need"] <= 5 and 1 <= f["parity"] <= 5):
            bad.append(f"feature {s!r}: cost {f['cost']!r} need {f['need']} parity "
                       f"{f['parity']}; cost is one of {list(COST_RANK)}, need and parity 1-5")
        if len(f["lanes"]) != 5 or set(f["lanes"]) - set(LANE_KIND):
            bad.append(f"feature {s!r}: lanes {f['lanes']!r} must be five of N, S, C, x "
                       f"(macOS iOS Linux Windows Android)")
        if "tier" in f and (f["tier"] not in TIERS[1:] or not f.get("tier_reason")):
            bad.append(f"feature {s!r}: a hand-placed tier needs one of {TIERS[1:]} and a "
                       f"tier_reason saying why")
    for blk in ("menu", "demo", "proposed", "archetype", "calibration", "tier", "source"):
        if not ed.get(blk):
            bad.append(f"{editorial_path.name} has no [[{blk}]] entries; restore them from git")
    reviews = ed.get("reviews", {})
    for name, where in reviews.items():
        if where.startswith("https://"):
            if not where.startswith("https://claude.ai/"):
                bad.append(f"review {name!r} is {where}, not a claude.ai artifact link")
        elif not pathlib.Path(os.path.expanduser(where)).exists():
            bad.append(f"review {name!r} names the local file {where}, which does not exist; "
                       f"publish it and put the artifact link in [reviews]")
    texts = list(strings(ed)) + [t for f in feats for t in strings(f)]
    for t in texts:
        for name in REVIEW_REF.findall(t):
            if name not in reviews:
                bad.append(f"{{review:{name}}} is used but [reviews] has no {name!r}; add it "
                           f"to {editorial_path.name}")
        for slug in ITEM.findall(t):
            if slug not in slugs:
                bad.append(f"#item-{slug} links to a feature features.toml lacks; fix the "
                           f"slug or add the feature")
    paths = set()
    for t in texts:
        paths.update(PATH.findall(t))
        paths.update(GH_PATH.findall(t))
    for e in ed.get("menu", []):
        if e.get("status") not in MENU_STATUS:
            bad.append(f"menu entry {strip(e.get('title', '?'))!r}: status "
                       f"{e.get('status')!r} is not one of {sorted(MENU_STATUS)}")
        if e.get("review") and e["review"] not in reviews:
            bad.append(f"menu entry {strip(e['title'])!r} names review {e['review']!r}, "
                       f"which [reviews] lacks")
        for field in ("plan", "scene"):
            if e.get(field):
                paths.add(e[field])
    for p in sorted(paths):
        if not (ROOT / p).exists():
            bad.append(f"{p} is named in the roadmap data and does not exist; fix the path "
                       f"or strike the reference")
    for a in ed.get("archetype", []):
        for slug in a.get("blockers", []) + a.get("soft", []):
            if slug not in slugs:
                bad.append(f"archetype {a['name']!r} names blocker {slug!r}, which "
                           f"features.toml lacks; use a feature slug or drop it")
    entries = ledger_entries(LEDGER.read_text(encoding="utf-8"))
    for e in ed.get("menu", []):
        key = e.get("key")
        if key and not any(key in x["text"] for x in entries):
            bad.append(f"menu entry {strip(e['title'])!r}: ledger KEY {key!r} is in no "
                       f"docs/deferred.md entry; name a noun the entry carries")
    hashes = sorted({h for t in texts for h in HASH.findall(t)} | {ed.get("base", "")} - {""})
    for h in unknown_commits(hashes):
        bad.append(f"commit {h} is named in the roadmap data and git does not know it; "
                   f"correct the hash")
    if not ed.get("base"):
        bad.append(f"{editorial_path.name} has no base commit; set base to the last read's "
                   f"HEAD")
    links = sum(len(ITEM.findall(t)) for t in texts)
    return bad, {"commits": len(hashes), "paths": len(paths), "links": links}


def staleness(ed, entries):
    out, acked = [], 0
    for e in ed["menu"]:
        if e["status"] == "shipped":
            continue
        title = strip(e["title"])
        if e.get("plan"):
            st = plan_status(e["plan"])
            m = DONE_WORDS.search(st)
            if m:
                if e.get("plan_built_part"):
                    acked += 1
                else:
                    out.append(f"{title}: marked {e['status']}, but {e['plan']}'s Status "
                               f"says {m.group(1)}")
        key = e.get("key")
        if key:
            hits = [x for x in entries if key in x["text"]]
            if hits and all(x["struck"] for x in hits):
                lines = ", ".join(str(x["line"]) for x in hits)
                out.append(f"{title}: marked {e['status']}, but its ledger KEY {key!r} appears "
                           f"only in struck entries (docs/deferred.md:{lines})")
    return out, acked


# ------------------------------------------------------------------ derived


def strip(s):
    return html.unescape(re.sub(r"<[^>]+>", "", s))


def first_sentence(s):
    m = re.match(r"(.+?[.!?])(?=\s+[A-Z(`]|$)", s)
    return m.group(1) if m else s


def changes_since(base):
    out = git("log", "--format=%h%x1f%ad%x1f%s", "--date=short", f"{base}..HEAD")
    days = {}
    for line in out.splitlines():
        h, d, subj = line.split("\x1f", 2)
        days.setdefault(d, []).append((h, first_sentence(subj)))
    return days


def ledger_open(entries):
    groups = {g: [] for g in LEDGER_GROUPS}
    for e in entries:
        if e["struck"]:
            continue
        head = e["head"]
        tag = "untagged"
        for p in LEDGER_PREFIXES:
            if re.match(re.escape(p) + r"\s*(—|:|-)", head):
                tag = "RULING / RULING WANTED" if p.startswith("RULING") else p
                head = re.sub(re.escape(p) + r"\s*(—|:|-)\s*", "", head, count=1)
                break
        groups[tag].append((e["line"], head))
    return groups


def latest_matrix():
    files = sorted(MEASUREMENTS.glob("matrix-wall-*.md"))
    if not files:
        return None
    p = files[-1]
    lines = p.read_text(encoding="utf-8").splitlines()
    title = lines[0].lstrip("# ").strip()
    first = []
    for line in lines[1:]:
        if line.strip():
            if line.startswith("|"):
                break
            first.append(line.strip())
        elif first:
            break
    rows = [[c.strip() for c in line.strip().strip("|").split("|")]
            for line in lines if line.startswith("|") and not re.match(r"^\|[-:| ]+\|$", line)]
    return {"path": str(p.relative_to(ROOT)), "title": title, "first": " ".join(first),
            "rows": rows}


# ------------------------------------------------------------------ render


def md_inline(s):
    s = html.escape(s, quote=False)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", s)


def dots(n):
    cells = "".join(f'<i class="{"on" if i < n else ""}"></i>' for i in range(5))
    return f'<span class="dots" aria-label="{n} of 5">{cells}</span>'


def lanes(code):
    out = []
    for os_name, ch in zip(LANE_OS, code):
        cls, word, glyph = LANE_KIND[ch]
        out.append(f'<i class="ln ln-{cls}" title="{os_name}: {word}">{glyph}</i>')
    return f'<span class="lanes">{"".join(out)}</span>'


def chip_tier(t):
    return f'<span class="tier tier-{t}">{TIER_NAME[t]}</span>'


def fmt_score(x):
    return f"{x:.1f}"


def reviews_sub(text, reviews):
    def one(m):
        where = reviews[m.group(1)]
        return where if where.startswith("https://") else f"the local page <code>{where}</code>"
    return REVIEW_REF.sub(one, text)


def render(feats, ed, derived):
    rv = ed.get("reviews", {})
    R = lambda t: reviews_sub(t, rv)  # noqa: E731
    o = []
    w = o.append
    w('<!doctype html><html lang="en"><head><meta charset="utf-8">')
    w('<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">')
    w("<title>kaya Roadmap</title>")
    w('<link rel="preconnect" href="https://fonts.googleapis.com">')
    w('<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+'
      'Condensed:wght@500;600&family=IBM+Plex+Sans:ital,wght@0,400;0,500;0,600;1,400&family='
      'IBM+Plex+Mono:wght@400;500&display=swap">')
    w(f"<style>\n{CSS}\n</style></head><body>")
    w("<main>")
    w('<header class="top">')
    w(f'  <div class="eyebrow">kaya · roadmap · read against the ledger at {derived["head"]} · '
      f'{derived["today"]}</div>')
    w(f'  <h1>{ed["title"]}</h1>')
    w(f'  <p class="lede">{R(ed["lede"])}</p>')
    w(f'  <div class="eyebrow order-head">State on {derived["today"]}</div>')
    if ed.get("state"):
        w(f'  <p class="lede">{R(ed["state"])}</p>')
    days = derived["changes"]
    n = sum(len(v) for v in days.values())
    w(f'  <div class="eyebrow order-head">Changes since {ed["base"]}: {n} commits</div>')
    w('  <div class="derived">')
    for d, items in days.items():
        w(f'  <details><summary><b class="mono">{d}</b> <span class="count">{len(items)} '
          f'commits</span></summary><ul>')
        for h, subj in items:
            w(f'    <li><span class="mono">{h}</span> {md_inline(subj)}</li>')
        w("  </ul></details>")
    w("  </div>")
    mx = derived["matrix"]
    if mx:
        w(f'  <div class="eyebrow order-head">Latest matrix evidence: {mx["path"]}</div>')
        w(f'  <p class="lede"><b>{md_inline(mx["title"])}.</b> {md_inline(mx["first"])}</p>')
        if mx["rows"]:
            w('  <div class="tablewrap"><table class="plain"><thead><tr>'
              + "".join(f"<th>{md_inline(c)}</th>" for c in mx["rows"][0]) + "</tr></thead><tbody>")
            for r in mx["rows"][1:]:
                w("  <tr>" + "".join(f"<td>{md_inline(c)}</td>" for c in r) + "</tr>")
            w("  </tbody></table></div>")
    lg = derived["ledger"]
    w(f'  <div class="eyebrow order-head">Open on the ledger: {lg["open"]} headlines open, '
      f'{lg["struck"]} struck (docs/deferred.md)</div>')
    w('  <div class="derived">')
    for g in LEDGER_GROUPS:
        items = lg["groups"][g]
        if not items:
            continue
        w(f'  <details><summary><b>{g}</b> <span class="count">{len(items)}</span></summary>'
          f'<ul>')
        for line, head in items:
            w(f'    <li><a class="mono" href="{GITHUB}/{derived["head"]}/docs/deferred.md#L{line}">'
              f'L{line}</a> {md_inline(head)}</li>')
        w("  </ul></details>")
    w("  </div>")
    w(f'  <div class="eyebrow order-head">{ed["menu_heading"]}</div>')
    w(f'  <p class="lede">{R(ed["menu_lede"])}</p>')
    lis = []
    for e in ed["menu"]:
        star = "★ " if e.get("star") else ""
        lis.append(f'<li>{star}{e["title"]} <span class="why">{R(e["text"])}</span></li>')
    w('  <ol class="order">' + "\n".join(lis) + "</ol>")
    if ed.get("recommended_next"):
        w(f'  <p class="lede"><b>Recommended next: {ed["recommended_next"]}.</b> '
          f'{R(ed.get("recommended_note", ""))}</p>')
    else:
        w(f'  <p class="lede">{R(ed["recommended_note"])}</p>')
    w(f'<div class="eyebrow order-head">{ed["demo_heading"]}</div>')
    w('<div class="tablewrap"><table class="plain">')
    w("<thead><tr><th>App</th><th>Already shipped for it</th><th>Waits on</th><th>Then</th>"
      "</tr></thead>")
    w("<tbody>")
    for d in ed["demo"]:
        then = d["then"]
        if d.get("then_tier"):
            then = " ".join(x for x in (chip_tier(d["then_tier"]), then) if x)
        w(f'<tr><td><strong>{d["name"]}</strong><span class="grp">{d["grp"]}</span></td>'
          f'<td>{R(d["shipped"])}</td><td>{R(d["waits"])}</td><td>{then}</td></tr>')
    w("</tbody></table></div>")
    w(f'  <div class="eyebrow order-head">{ed["proposed_heading"]}</div>')
    w(f'  <p class="lede">{R(ed["proposed_lede"])}</p>')
    w('  <div class="tablewrap"><table class="plain">')
    w("  <thead><tr><th>Proposed demo</th><th>What it forces</th><th>Shares with</th>"
      "<th>Size</th></tr></thead>")
    w("  <tbody>")
    for p in ed["proposed"]:
        w(f'  <tr><td><strong>{p["name"]}</strong><span class="grp">{p["grp"]}</span></td>'
          f'<td>{R(p["forces"])}</td><td>{R(p["shares"])}</td><td>{R(p["size"])}</td></tr>')
    w("  </tbody></table></div>")
    for para in ed["proposed_after"]:
        w(f'  <p class="lede">{R(para)}</p>')
    w("</header>")
    w('<div class="axes">')
    for a in ed["axis"]:
        w(f'  <div class="axis"><b>{a["title"]}</b><span>{a["text"]}</span></div>')
    w("</div>")
    w("<h2>The scored list</h2>")
    w(f'<p class="lede">{ed["scored_lede"]}</p>')
    w('<div class="filters" role="group" aria-label="Filter by tier">')
    w('  <button aria-pressed="true" data-filter="all">All</button>')
    for t in TIERS:
        w(f'  <button aria-pressed="false" data-filter="{t}">{TIER_NAME[t]}</button>')
    w("</div>")
    w('<div class="tablewrap">')
    w('<table id="scores">')
    w('<thead><tr>\n  <th data-key="rank" tabindex="0">#</th><th data-key="name" tabindex="0">'
      'Feature</th><th data-key="need" tabindex="0">Need</th><th data-key="parity" '
      'tabindex="0">Parity</th><th data-key="cost" tabindex="0">Cost</th><th>Lanes</th>'
      '<th data-key="score" tabindex="0" data-dir="desc">Score</th><th data-key="tier" '
      'tabindex="0">Tier</th>\n</tr></thead>')
    w("<tbody>")
    for f in feats:
        sc = fmt_score(f["_score"])
        w(f'<tr data-tier="{f["_tier"]}" data-score="{sc}" data-need="{f["need"]}" '
          f'data-parity="{f["parity"]}" data-cost="{COST_RANK[f["cost"]]}" '
          f'data-name="{html.escape(strip(f["name"]))}">')
        w(f'  <td class="num">{f["_rank"]}</td>')
        w(f'  <td><a href="#item-{f["slug"]}">{f["name"]}</a><span class="grp">{f["group"]}'
          f'</span></td>')
        w(f"  <td>{dots(f['need'])}</td>")
        w(f"  <td>{dots(f['parity'])}</td>")
        w(f'  <td><span class="chip cost cost-{f["cost"]}">{f["cost"]}</span></td>')
        w(f"  <td>{lanes(f['lanes'])}</td>")
        w(f'  <td class="num">{sc}</td>')
        w(f"  <td>{chip_tier(f['_tier'])}</td>")
        w("</tr>")
    w("</tbody>\n</table>\n</div>")
    w(LEGEND)
    tier_lede = {t["id"]: t["lede"] for t in ed["tier"]}
    for t in TIERS:
        cards = [f for f in feats if f["_tier"] == t]
        noun = "item" if len(cards) == 1 else "items"
        w(f'<section class="tier-section" id="tier-{t}">')
        w(f'<h3>{chip_tier(t)} <span class="count">{len(cards)} {noun}</span></h3>')
        w(f'<p class="lede">{R(tier_lede[t])}</p>')
        w('<div class="cards">')
        for f in cards:
            label, title = COST_LABEL[f["cost"]]
            w(f'<article class="card tier-{t}" id="item-{f["slug"]}">')
            w("  <header>")
            w(f'    <span class="rank">{f["_rank"]}</span>')
            w(f'    <h4>{f["name"]}</h4>')
            w(f'    <span class="chip cost cost-{f["cost"]}" title="{title}">{label}</span>')
            w("  </header>")
            w("  <dl>")
            w(f'    <div><dt>Need</dt><dd>{dots(f["need"])} <span class="why">{f["need_why"]}'
              f'</span></dd></div>')
            w(f'    <div><dt>Parity</dt><dd>{dots(f["parity"])} <span class="why">'
              f'{f["parity_why"]}</span></dd></div>')
            w(f'    <div><dt>Shape</dt><dd>{f["shape"]} · {lanes(f["lanes"])}</dd></div>')
            w(f'    <div><dt>kaya</dt><dd>{f["kaya"]}</dd></div>')
            if f.get("shipped_note"):
                w(f'    <div><dt>Shipped</dt><dd><span class="why">{f["shipped_note"]}</span>'
                  f'</dd></div>')
            if f.get("tier_reason"):
                w(f'    <div><dt>Tier</dt><dd><span class="why">placed by hand: '
                  f'{f["tier_reason"]}</span></dd></div>')
            if f.get("amended"):
                w(f'    <div><dt>Amended</dt><dd><span class="why">{f["amended"]}</span></dd>'
                  f'</div>')
            w("  </dl>")
            w("</article>")
        w("</div>")
        w("</section>")
    w("<h2>What each tier unlocks</h2>")
    w(f'<p class="lede">{ed["archetypes_lede"]}</p>')
    w('<div class="tablewrap">\n<table class="plain">')
    w("<thead><tr><th>Archetype</th><th>kaya has</th><th>Blocked on</th><th>Clears</th></tr>"
      "</thead>")
    w("<tbody>")
    for a in derived["archetypes"]:
        w(f'<tr><td><strong>{a["name"]}</strong><span class="grp">{a["grp"]}</span></td>')
        w(f'<td>{R(a["has"])}</td><td>{R(a["blocked"])}</td><td>{chip_tier(a["_clears"])}</td>'
          f'</tr>')
    w("</tbody>\n</table>\n</div>")
    w("<h2>The cost calibration</h2>")
    w(f'<p class="lede">{ed["calibration_lede"]}</p>')
    w('<div class="tablewrap">\n<table class="plain">')
    w('<thead><tr><th>Shipped</th><th>Shape</th><th>Dates</th><th class="num">Days</th>'
      "<th>Note</th></tr></thead>")
    w("<tbody>")
    for c in ed["calibration"]:
        w(f'<tr><td>{c["what"]}</td><td>{c["shape"]}</td><td class="mono">{c["dates"]}</td>'
          f'<td class="num">{c["days"]}</td><td>{R(c["note"])}</td></tr>')
    w("</tbody>\n</table>\n</div>")
    w("<h2>Method and caveats</h2>")
    for para in ed["method"]:
        w(f"<p>{para}</p>")
    w("<h2>Sources</h2>")
    w('<ul class="sources">')
    for so in ed["source"]:
        w(f'<li><a href="{so["href"]}">{so["title"]}</a> <span class="why">{so["why"]}</span>'
          f"</li>")
    w("</ul>")
    w("</main>")
    w(f"<script>\n{JS}\n</script>")
    w("</body></html>")
    return "\n".join(o) + "\n"


class Text(html.parser.HTMLParser):
    BLOCK = {"p", "li", "tr", "h1", "h2", "h3", "h4", "div", "article", "section", "header",
             "summary", "ul", "ol", "table", "thead", "tbody", "dl", "main", "title"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("style", "script"):
            self.skip += 1
        elif tag in self.BLOCK:
            self.parts.append("\n")
        elif tag in ("td", "th"):
            self.parts.append(" | ")

    def handle_endtag(self, tag):
        if tag in ("style", "script"):
            self.skip -= 1
        elif tag in self.BLOCK:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)


def as_text(page):
    t = Text()
    t.feed(page)
    t.close()
    lines = (re.sub(r"\s+", " ", ln).strip(" |") for ln in "".join(t.parts).split("\n"))
    return "\n".join(ln for ln in lines if ln) + "\n"


# ------------------------------------------------------------------ main


def derive(features_path, editorial_path):
    feats = tomllib.loads(features_path.read_text(encoding="utf-8"))["feature"]
    ed = tomllib.loads(editorial_path.read_text(encoding="utf-8"))
    for i, f in enumerate(feats):
        f["_score"] = score(f)
        f["_order"] = i
        if f.get("shipped"):
            f["_tier"] = "shipped"
        else:
            f["_tier"] = f.get("tier") or tier_by_rule(f)
    for rank, f in enumerate(sorted(feats, key=lambda f: (-f["_score"], f["_order"])), 1):
        f["_rank"] = rank
    feats.sort(key=lambda f: f["_rank"])
    by_slug = {f["slug"]: f for f in feats}
    archetypes = []
    for a in ed["archetype"]:
        tiers = [by_slug[s]["_tier"] for s in a.get("blockers", [])]
        a = dict(a)
        a["_clears"] = max(tiers, key=TIERS.index) if tiers else "shipped"
        archetypes.append(a)
    text = LEDGER.read_text(encoding="utf-8")
    entries = ledger_entries(text)
    derived = {
        "head": git("rev-parse", "--short=8", "HEAD").strip(),
        "today": datetime.date.today().isoformat(),
        "changes": changes_since(ed["base"]),
        "matrix": latest_matrix(),
        "ledger": {"groups": ledger_open(entries),
                   "open": sum(1 for e in entries if not e["struck"]),
                   "struck": sum(1 for e in entries if e["struck"])},
        "archetypes": archetypes,
        "entries": entries,
    }
    return feats, ed, derived


def self_test():
    gate = Gate("roadmap")
    scratch = gate.scratch()
    real, _ = check(FEATURES, EDITORIAL)
    for line in real:
        gate.finding(f"self-test positive control: the real data refuses: {line}")

    def doctored(label, which, pattern, repl):
        src = FEATURES if which == "features" else EDITORIAL
        text = gate.doctor(label, src.read_text(encoding="utf-8"), pattern, repl)
        p = scratch / f"{label}-{src.name}"
        p.write_text(text, encoding="utf-8")
        f = p if which == "features" else FEATURES
        e = p if which == "editorial" else EDITORIAL
        return lambda: check(f, e)[0]

    cases = [
        ("plan-path", "editorial", r"plan = 'docs/hscroll-plan\.md'",
         "plan = 'docs/hscroll-gone-plan.md'", "docs/hscroll-gone-plan.md is named"),
        ("scene", "editorial", r"scene = 'tools/scenes/timecode\.steps'",
         "scene = 'tools/scenes/timecode-gone.steps'", "tools/scenes/timecode-gone.steps is named"),
        ("text-path", "features", r"docs/capture-plan\.md §8\)",
         "docs/capture-gone-plan.md §8)", "docs/capture-gone-plan.md is named"),
        ("review-file", "editorial", r"review/index\.html'",
         "review/index-gone.html'", "names the local file"),
        ("review-name", "editorial", r"\{review:hscroll\}",
         "{review:hscroll_gone}", "[reviews] has no 'hscroll_gone'"),
        ("commit-editorial", "editorial", r"SHIPPED 2026-10-06 \(f835b14b\)",
         "SHIPPED 2026-10-06 (f835b14e)", "commit f835b14e"),
        ("commit-features", "features", r"\(7b228406, fe1e93e2\)",
         "(7b228406, fe1e93e9)", "commit fe1e93e9"),
        ("base", "editorial", r"\nbase = '955d4106'", "\nbase = '955d4109'",
         "commit 955d4109"),
        ("menu-slug", "editorial", r'href="#item-hscroll"', 'href="#item-hscroll_gone"',
         "#item-hscroll_gone links"),
        ("archetype-slug", "editorial", r"blockers = \['background'\]",
         "blockers = ['background_gone']", "blocker 'background_gone'"),
        ("ledger-key", "editorial", r"key = 'far end'", "key = 'farthest end'",
         "ledger KEY 'farthest end'"),
        ("duplicate-slug", "features", r"slug = 'hyperlink'", "slug = 'search_field'",
         "'search_field' appears twice"),
    ]
    for label, which, pat, repl, want in cases:
        fn = doctored(label, which, pat, repl)
        refusals = fn()
        print(f"roadmap: self-test {label}: {len(refusals)} refusal(s)")
        for line in refusals:
            print(f"roadmap:   REFUSED — {line}")
        gate.negative(label, lambda r=refusals: r, want=want)
    ed = tomllib.loads(gate.doctor(
        "staleness", EDITORIAL.read_text(encoding="utf-8"),
        r"status = 'shipped'\n(size = 'S to M')", r"status = 'open'\n\1"))
    found, _ = staleness(ed, ledger_entries(LEDGER.read_text(encoding="utf-8")))
    for line in found:
        print(f"roadmap: self-test staleness printed: {line}")
    gate.negative("staleness plan Status", lambda: found,
                  want="docs/number-field-plan.md's Status says BUILT")
    gate.negative("staleness struck KEY", lambda: found,
                  want="'timecode formatter' appears only in struck entries")
    gate.negatives_ran(len(cases) + 2)
    gate.verdict(f"{len(cases)} refusal branches and 2 staleness branches watched")


def main():
    ap = argparse.ArgumentParser(description="Render the roadmap page (docs/HACKING.md, Roadmap).")
    ap.add_argument("--diff", action="store_true",
                    help="also write index.txt and print a unified diff against the last one")
    ap.add_argument("--self-test", action="store_true", help="watch every refusal fire")
    args = ap.parse_args()
    if args.self_test:
        self_test()
        return
    bad, seen = check(FEATURES, EDITORIAL)
    if bad:
        for line in bad:
            print(f"roadmap: REFUSED — {line}", file=sys.stderr)
        print(f"roadmap: {len(bad)} refusal(s); nothing written", file=sys.stderr)
        raise SystemExit(1)
    feats, ed, derived = derive(FEATURES, EDITORIAL)
    page = render(feats, ed, derived)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "index.html").write_text(page, encoding="utf-8")
    per = {t: sum(1 for f in feats if f["_tier"] == t) for t in TIERS}
    print(f"roadmap: wrote {(OUT / 'index.html').relative_to(ROOT)} at {derived['head']}")
    print(f"roadmap: features {len(feats)} ({', '.join(f'{t} {n}' for t, n in per.items())}); "
          f"menu {len(ed['menu'])}; archetypes {len(ed['archetype'])}; calibration "
          f"{len(ed['calibration'])}; changes since {ed['base']} "
          f"{sum(len(v) for v in derived['changes'].values())}; ledger open "
          f"{derived['ledger']['open']}, struck {derived['ledger']['struck']}; matrix "
          f"{derived['matrix']['path'] if derived['matrix'] else 'none'}")
    print(f"roadmap: checked {seen['commits']} commits, {seen['paths']} paths and "
          f"{seen['links']} card links named in the data")
    stale, acked = staleness(ed, derived["entries"])
    print(f"roadmap: staleness: {len(stale)} (plus {acked} acknowledged by plan_built_part)")
    for line in stale:
        print(f"roadmap: STALE? {line}")
    if args.diff:
        txt = OUT / "index.txt"
        prev = OUT / "index.prev.txt"
        new = as_text(page)
        if txt.exists():
            os.replace(txt, prev)
            old = prev.read_text(encoding="utf-8")
            diff = list(difflib.unified_diff(old.splitlines(), new.splitlines(),
                                             str(prev.relative_to(ROOT)),
                                             str(txt.relative_to(ROOT)), lineterm=""))
            txt.write_text(new, encoding="utf-8")
            if not diff:
                print("roadmap: the page text is unchanged since the previous run")
            else:
                print(f"roadmap: diff against the previous run, {len(diff)} line(s):")
            for line in diff:
                print(line)
        else:
            txt.write_text(new, encoding="utf-8")
            print(f"roadmap: no previous {txt.relative_to(ROOT)}; this is the first run, "
                  f"nothing to diff")


LEGEND = """<div class="legend">
  <span>Lanes, in order macOS · iOS · Linux · Windows · Android:</span>
  <span class="lanes"><i class="ln ln-n">N</i></span> native control or API
  <span class="lanes"><i class="ln ln-s">S</i></span> kaya synthesizes the tier
  <span class="lanes"><i class="ln ln-c">C</i></span> carve-out, stated uniformly
  <span class="lanes"><i class="ln ln-x">·</i></span> not on that form factor
</div>"""

CSS = """:root {
  --bg:#F2F4F6; --surface:#FFFFFF; --ink:#172029; --muted:#5A6673; --rule:#D6DCE2;
    --rule-soft:#E7EBEF;
  --accent:#0E7C7B; --accent-ink:#0B5F5E; --accent-soft:#D9EFEE;
  --now:#0E7C7B; --shipped: #2FA84F;  --next:#3C55B5; --later:#66768A; --hold:#8B7355;
  --now-soft:#D9EFEE; --shipped-soft: #E6F5EA;  --next-soft:#E1E6F8; --later-soft:#E8ECF1;
    --hold-soft:#F1EBE0;
  --lane-n:#0E7C7B; --lane-s:#B8860B; --lane-c:#B2453E; --lane-x:#AEB8C2;
  --cost-S:#D9EFEE; --cost-M:#E4EEF9; --cost-L:#F6EBD2; --cost-XL:#F7DFD6; --cost-XXL:#EADFF0;
  --cost-ink:#172029;
  --link:#0B5F5E;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg:#0F1418; --surface:#161C23; --ink:#E6EBF0; --muted:#98A4B1; --rule:#2B343E;
      --rule-soft:#222A33;
    --accent:#3FB6B3; --accent-ink:#7ED3D0; --accent-soft:#12312F;
    --now:#3FB6B3; --shipped: #4CC26A;  --next:#8B9BE6; --later:#98A4B1; --hold:#C9A876;
    --now-soft:#12312F; --shipped-soft: #163A22;  --next-soft:#1E2542; --later-soft:#222A33;
      --hold-soft:#2E2820;
    --lane-n:#3FB6B3; --lane-s:#D8A72E; --lane-c:#E0736B; --lane-x:#4A5560;
    --cost-S:#12312F; --cost-M:#1B2A3F; --cost-L:#3A2F16; --cost-XL:#3F2320; --cost-XXL:#2D2238;
    --cost-ink:#E6EBF0; --link:#7ED3D0;
  }
}
:root[data-theme="dark"] {
  --bg:#0F1418; --surface:#161C23; --ink:#E6EBF0; --muted:#98A4B1; --rule:#2B343E;
    --rule-soft:#222A33;
  --accent:#3FB6B3; --accent-ink:#7ED3D0; --accent-soft:#12312F;
  --now:#3FB6B3; --shipped: #4CC26A;  --next:#8B9BE6; --later:#98A4B1; --hold:#C9A876;
  --now-soft:#12312F; --shipped-soft: #163A22;  --next-soft:#1E2542; --later-soft:#222A33;
    --hold-soft:#2E2820;
  --lane-n:#3FB6B3; --lane-s:#D8A72E; --lane-c:#E0736B; --lane-x:#4A5560;
  --cost-S:#12312F; --cost-M:#1B2A3F; --cost-L:#3A2F16; --cost-XL:#3F2320; --cost-XXL:#2D2238;
  --cost-ink:#E6EBF0; --link:#7ED3D0;
}
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--ink);
  font: 15px/1.55 "IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif; }
a { color:var(--link); text-decoration-color: color-mix(in srgb, var(--link) 40%, transparent);
  }
a:focus-visible, button:focus-visible, th:focus-visible { outline:2px solid var(--accent);
  outline-offset:2px; }
main { max-width: 1120px; margin: 0 auto; padding: 32px 24px 72px; }
h1,h2,h3,h4 { font-family:"IBM Plex Sans Condensed", "IBM Plex Sans", system-ui, sans-serif;
  font-weight:600; letter-spacing:-0.01em; text-wrap:balance; margin:0; }
h1 { font-size: 40px; line-height:1.05; }
h2 { font-size: 24px; margin: 56px 0 8px; }
h3 { font-size: 20px; display:flex; align-items:center; gap:12px; margin: 40px 0 6px; }
h4 { font-size: 17px; }
p { max-width: 68ch; }
.eyebrow { font-family:"IBM Plex Mono", ui-monospace, monospace; font-size:12px;
  letter-spacing:0.08em; text-transform:uppercase; color:var(--muted); margin-bottom:10px; }
.lede { color:var(--muted); font-size:16px; margin: 6px 0 0; }
.why { color:var(--muted); }
.mono, .num { font-family:"IBM Plex Mono", ui-monospace, monospace;
  font-variant-numeric: tabular-nums; }
.num { text-align:right; }
header.top { padding-bottom: 28px; border-bottom: 1px solid var(--rule); }
.order-head { margin-top: 28px; }
ol.order { margin: 8px 0 0; padding-left: 22px; columns: 2; column-gap: 40px; }
ol.order li { margin: 0 0 10px; break-inside: avoid; }
ol.order li a { font-weight:600; }
.axes { display:grid; grid-template-columns: repeat(3, 1fr); gap: 16px; margin-top: 28px; }
.axis { background:var(--surface); border:1px solid var(--rule-soft); border-radius: 6px;
  padding: 14px 16px; }
.axis b { display:block; font-family:"IBM Plex Sans Condensed", sans-serif; font-size: 16px;
  margin-bottom: 4px; }
.axis span { color:var(--muted); font-size: 14px; }
.dots { display:inline-flex; gap:3px; vertical-align:middle; }
.dots i { width:9px; height:9px; border-radius:50%; background:var(--rule);
  display:inline-block; }
.dots i.on { background:var(--accent); }
.lanes { display:inline-flex; gap:2px; vertical-align:middle;
  font-family:"IBM Plex Mono", monospace; font-size: 11px; }
.lanes i { width:18px; height:18px; display:inline-grid; place-items:center; font-style:normal;
  border-radius:3px; color:#fff; font-weight:500; }
.ln-n { background:var(--lane-n); } .ln-s { background:var(--lane-s); }
  .ln-c { background:var(--lane-c); } .ln-x { background:var(--lane-x);
  color:var(--bg) !important; }
.chip { display:inline-block; font-family:"IBM Plex Mono", monospace; font-size:12px;
  padding: 2px 8px; border-radius: 4px; white-space:nowrap; color:var(--cost-ink); }
.cost-S { background:var(--cost-S); } .cost-M { background:var(--cost-M); }
  .cost-L { background:var(--cost-L); } .cost-XL { background:var(--cost-XL); }
  .cost-XXL { background:var(--cost-XXL); }
.tier { display:inline-block; font-family:"IBM Plex Sans Condensed", sans-serif;
  font-weight:600; font-size:13px; letter-spacing:0.04em; text-transform:uppercase;
  padding: 2px 8px; border-radius: 4px; }
.tier-shipped { background:var(--shipped-soft); color:var(--shipped); }
  .tier-now { background:var(--now-soft); color:var(--now); }
  .tier-next { background:var(--next-soft); color:var(--next); }
.tier-later { background:var(--later-soft); color:var(--later); }
  .tier-hold { background:var(--hold-soft); color:var(--hold); }
.count { color:var(--muted); font: 14px "IBM Plex Sans", sans-serif; font-weight: 400; }
.filters { display:flex; flex-wrap:wrap; gap:8px; margin: 16px 0 12px; }
.filters button { font: inherit; font-size:13px; padding: 5px 12px; border-radius: 999px;
  border:1px solid var(--rule); background:var(--surface); color:var(--ink); cursor:pointer; }
.filters button[aria-pressed="true"] { background:var(--ink); color:var(--bg);
  border-color:var(--ink); }
.tablewrap { overflow-x:auto; background:var(--surface); border:1px solid var(--rule-soft);
  border-radius: 6px; }
table { border-collapse: collapse; width:100%; min-width: 860px; }
th, td { padding: 9px 12px; text-align:left; vertical-align: middle;
  border-bottom: 1px solid var(--rule-soft); }
thead th { font-family:"IBM Plex Mono", monospace; font-size: 11px; letter-spacing:0.06em;
  text-transform:uppercase; color:var(--muted); font-weight:500; cursor:pointer;
  user-select:none; white-space:nowrap; position:sticky; top:0; background:var(--surface); }
thead th[data-dir]::after { content: " ▴"; } thead th[data-dir="desc"]::after { content:" ▾"; }
tbody tr:last-child td { border-bottom:0; }
td .grp { display:block; color:var(--muted); font-size:12px; }
td a { font-weight: 500; text-decoration:none; }
tr[hidden] { display:none; }
.cards { display:grid; grid-template-columns: repeat(auto-fill, minmax(340px, 1fr)); gap: 14px;
  margin-top: 14px; }
.card { background:var(--surface); border:1px solid var(--rule-soft);
  border-left: 3px solid var(--later); border-radius: 6px; padding: 14px 16px 12px; }
.card.tier-shipped { border-left-color: var(--shipped); }
  .card.tier-now { border-left-color: var(--now); }
  .card.tier-next { border-left-color: var(--next); }
  .card.tier-hold { border-left-color: var(--hold); }
.card header { display:flex; align-items:baseline; gap: 10px; margin-bottom: 8px;
  flex-wrap:wrap; }
.card header h4 { flex: 1 1 auto; }
.rank { font-family:"IBM Plex Mono", monospace; color:var(--muted); font-size:12px; }
.card dl { margin:0; display:grid; gap: 6px; }
.card dl div { display:grid; grid-template-columns: 56px 1fr; gap: 10px; font-size: 14px; }
.card dt { color:var(--muted); font-family:"IBM Plex Mono", monospace; font-size:11px;
  letter-spacing:0.06em; text-transform:uppercase; padding-top:3px; }
.card dd { margin:0; }
.legend { display:flex; flex-wrap:wrap; gap: 14px 22px; color:var(--muted); font-size: 13px;
  margin: 10px 0 0; align-items:center; }
.legend .lanes i { width:16px; height:16px; font-size:10px; }
.plain td { vertical-align: top; font-size: 14px; }
.plain { min-width: 720px; }
ul.sources { padding-left: 20px; } ul.sources li { margin: 4px 0; font-size: 14px; }
@media (max-width: 760px) { ol.order { columns: 1; } .axes { grid-template-columns: 1fr; }
  h1 { font-size: 32px; } }
@media (prefers-reduced-motion: no-preference) { .filters button { transition: background .15s;
  } }
.derived { margin-top: 6px; }
.derived summary { cursor: pointer; font-size: 14px; }
.derived ul { margin: 4px 0 10px; padding-left: 22px; font-size: 14px; }
.derived li { margin: 3px 0; max-width: 100ch; }
.derived .mono { font-size: 12px; color: var(--muted); }"""

JS = """(function() {
  const table = document.getElementById('scores');
  const tbody = table.tBodies[0];
  const rows = Array.from(tbody.rows);
  const tierOrder = {shipped:-1, now:0, next:1, later:2, hold:3};
  function val(row, key) {
    if (key === 'rank') return parseInt(row.cells[0].textContent, 10);
    if (key === 'name') return row.dataset.name.toLowerCase();
    if (key === 'tier') return tierOrder[row.dataset.tier];
    return parseFloat(row.dataset[key]);
  }
  table.tHead.querySelectorAll('th[data-key]').forEach(th => {
    const go = () => {
      const key = th.dataset.key;
      const dir = th.dataset.dir === 'desc' ? 'asc' : 'desc';
      table.tHead.querySelectorAll('th').forEach(o => o.removeAttribute('data-dir'));
      th.dataset.dir = dir;
      rows.sort((a, b) => {
        const x = val(a, key), y = val(b, key);
        const c = (x < y) ? -1 : (x > y) ? 1 : 0;
        return dir === 'asc' ? c : -c;
      });
      rows.forEach(r => tbody.appendChild(r));
    };
    th.addEventListener('click', go);
    th.addEventListener('keydown', e => {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); go(); }
    });
  });
  document.querySelectorAll('.filters button').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.filters button')
        .forEach(b => b.setAttribute('aria-pressed', 'false'));
      btn.setAttribute('aria-pressed', 'true');
      const f = btn.dataset.filter;
      rows.forEach(r => { r.hidden = !(f === 'all' || r.dataset.tier === f); });
    });
  });
})();"""

if __name__ == "__main__":
    main()
