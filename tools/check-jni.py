#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die, scratch_dir
from packaging import android as packaging_android
from packaging import identity as app_identity

dev_shell_or_die()


# The JNI registration gate (CLAUDE.md's gate list: JNI fails at attach
# for a registered native the class lacks, while a declared-and-
# unregistered one throws only at FIRST USE).
# Name-level on purpose: a signature mismatch DOES fail at attach; the
# silent hole is coverage.

import re

FILES = {
    "jvm.rs":         ROOT / "crates/kaya/src/jvm.rs",
    "android.rs":     ROOT / "crates/kaya/src/android.rs",
    "KayaRing.kt":    ROOT / "android/kaya/src/main/kotlin/dev/kaya/KayaRing.kt",
    "KayaPresent.kt": ROOT / "android/kaya/src/main/kotlin/dev/kaya/KayaPresent.kt",
    "Kaya.kt":        ROOT / "android/kaya/src/main/kotlin/dev/kaya/Kaya.kt",
    "KayaRing.java":  ROOT / "bindings/java-desktop/dev/kaya/KayaRing.java",
}

def kotlin_externals(text):
    return set(re.findall(r"external fun (\w+)", text))

def java_natives(text):
    # The identifier right before the parameter list, on the `native`
    # line or a continuation of it.
    return set(re.findall(r"\bnative\b[^(;=]*?(\w+)\s*\(", text))

def fn_registration_names(text, fnname):
    """The `name: "..."` entries inside `fn <fnname>`'s braces, or None
    if the function is missing (which the caller treats as failure —
    a regex that matches nothing must never read as a clean bill)."""
    m = re.search(r"\bfn " + fnname + r"\b", text)
    if not m:
        return None
    start = text.find("{", m.end())
    if start < 0:
        return None
    depth = 0
    for j in range(start, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return set(re.findall(r'name: "(\w+)"\.into\(\)', text[start:j + 1]))
    return None

def exports(text, klass):
    # Method names start lowercase, so `Kaya` cannot swallow
    # `KayaRing_attach`.
    return set(re.findall(r"Java_dev_kaya_" + klass + r"_([a-z]\w*)", text))

# THE CENSUS THAT KEEPS FILES HONEST: the table above is hand-listed, so a
# NEW class declaring a native is read by NOTHING and the gate still says
# OK — the same hole one level up from the one it exists for. Every Kotlin
# class in the interpreter's package and every Java class in the desktop
# binding's either appears above or declares no native at all.
CLASS_DIRS = [
    (ROOT / "android/kaya/src/main/kotlin/dev/kaya", "*.kt", "kotlin"),
    (ROOT / "bindings/java-desktop/dev/kaya", "*.java", "java"),
]

# Natives libkaya does NOT register, each with the library that exports
# them by name instead. Held to still existing and to still declaring one,
# because a stale exemption is the next stale audit.
UNREGISTERED = {
    "KayaGo.kt": "the Go guest's own c-shared library exports "
                 "Java_dev_kaya_KayaGo_attach by name (docs/go-mobile-plan.md)",
    "KayaPy.kt": "tools/android/pyhost-jni.c, the python host's shim .so, "
                 "exports it by name (docs/python-mobile-plan.md D2)",
}


def class_natives():
    """(file name, declared native names) for every class file on disk."""
    out = []
    for directory, glob, lang in CLASS_DIRS:
        reader = kotlin_externals if lang == "kotlin" else java_natives
        for entry in sorted(directory.glob(glob)):
            out.append((entry.name, reader(entry.read_text(encoding="utf-8"))))
    return out


def unread_classes(found):
    errs = []
    named = set(FILES) | set(UNREGISTERED)
    declaring = {name for name, natives in found if natives}
    for name, natives in found:
        if natives and name not in named:
            errs.append(f"{name} declares native(s) {sorted(natives)} and is in "
                        f"neither this gate's FILES table nor UNREGISTERED, so "
                        f"nothing checks that they are registered — a native "
                        f"nobody registers throws at FIRST USE, not at attach")
    for name, why in sorted(UNREGISTERED.items()):
        if name not in dict(found):
            errs.append(f"UNREGISTERED names {name}, which is not on disk — a "
                        f"stale exemption ({why})")
        elif name not in declaring:
            errs.append(f"UNREGISTERED exempts {name}, which declares no native "
                        f"at all — the exemption reads as covered ({why})")
    if len(found) < 6:
        errs.append(f"{len(found)} class file(s) read, under the floor of 6 — a "
                    f"census that reads nothing agrees with everything")
    return errs


def check(src):
    """src: dict name -> text. Returns the list of failures."""
    errs = []
    kt_ring    = kotlin_externals(src["KayaRing.kt"])
    kt_present = kotlin_externals(src["KayaPresent.kt"])
    kt_kaya    = kotlin_externals(src["Kaya.kt"])
    java_ring  = java_natives(src["KayaRing.java"])

    ring    = fn_registration_names(src["jvm.rs"], "register_ring_natives")
    desktop = fn_registration_names(src["jvm.rs"], "register_desktop_natives")
    present = fn_registration_names(src["android.rs"], "register_present_natives")

    # Vacuity pins: a pattern that stops matching must fail the gate.
    for label, got, sentinel in [
        ("KayaRing.kt externals", kt_ring, "submit"),
        ("KayaPresent.kt externals", kt_present, "emitClicked"),
        ("Kaya.kt externals", kt_kaya, "attach"),
        ("KayaRing.java natives", java_ring, "submit"),
    ]:
        if sentinel not in got:
            errs.append(f"vacuous parse: {label} did not yield '{sentinel}' "
                        f"(got {sorted(got)})")
    for label, got, sentinel in [
        ("register_ring_natives", ring, "submit"),
        ("register_desktop_natives", desktop, "run"),
        ("register_present_natives", present, "emitClicked"),
    ]:
        if got is None:
            errs.append(f"vacuous parse: fn {label} not found")
        elif sentinel not in got:
            errs.append(f"vacuous parse: {label} did not yield '{sentinel}' "
                        f"(got {sorted(got)})")
    if errs:
        return errs
    exp_android_ring    = exports(src["android.rs"], "KayaRing")
    exp_android_present = exports(src["android.rs"], "KayaPresent")
    exp_android_kaya    = exports(src["android.rs"], "Kaya")
    exp_jvm_ring        = exports(src["jvm.rs"], "KayaRing")

    for name in sorted(kt_ring - ring - exp_android_ring):
        errs.append(f"KayaRing.kt declares external fun {name} but the android "
                    f"attach path never registers it (register_ring_natives in "
                    f"jvm.rs, or a Java_dev_kaya_KayaRing_* export in android.rs)")
    for name in sorted(kt_present - present - exp_android_present):
        errs.append(f"KayaPresent.kt declares external fun {name} but "
                    f"register_present_natives in android.rs never registers it")
    for name in sorted(kt_kaya - exp_android_kaya):
        errs.append(f"Kaya.kt declares external fun {name} with no "
                    f"Java_dev_kaya_Kaya_* export in android.rs")

    for name in sorted(java_ring - ring - desktop - exp_jvm_ring):
        errs.append(f"KayaRing.java declares native {name} but the desktop "
                    f"attach path never registers it (register_ring_natives or "
                    f"register_desktop_natives in jvm.rs)")

    # Reverse: a registered name the class lacks fails at attach on ONE
    # platform — catch it here, for both.
    for name in sorted(ring - kt_ring):
        errs.append(f"register_ring_natives registers {name} which "
                    f"KayaRing.kt does not declare (the shared list serves "
                    f"BOTH classes)")
    for name in sorted(ring - java_ring):
        errs.append(f"register_ring_natives registers {name} which "
                    f"KayaRing.java does not declare (the shared list serves "
                    f"BOTH classes)")
    for name in sorted(desktop - java_ring):
        errs.append(f"register_desktop_natives registers {name} which "
                    f"KayaRing.java does not declare")
    for name in sorted(ring & desktop):
        errs.append(f"{name} is registered in BOTH register_ring_natives and "
                    f"register_desktop_natives — one list owns each name")
    for name in sorted(present - kt_present):
        errs.append(f"register_present_natives registers {name} which "
                    f"KayaPresent.kt does not declare")
    return errs

src = {name: path.read_text(encoding="utf-8") for name, path in FILES.items()}

# Self-tests: perturb a copy, prove the perturbation applied, demand red.

def perturbed(base, name, pattern, repl):
    text, n = re.subn(pattern, repl, base[name], flags=re.S)
    if n != 1:
        print(f"check-jni: SELF-TEST BROKEN — perturbation of {name} matched "
              f"{n} times, wanted exactly 1 ({pattern!r})", file=sys.stderr)
        sys.exit(1)
    out = dict(base)
    out[name] = text
    return out

selftests = [
    ("openPicked entry dropped from register_ring_natives",
     perturbed(src, "jvm.rs",
               r'NativeMethod \{\s*name: "openPicked"\.into\(\),.*?\},', ""),
     "openPicked"),
    ("emitPasted declaration dropped from KayaPresent.kt",
     perturbed(src, "KayaPresent.kt",
               r"external fun emitPasted", "fun emitPastedGone"),
     "emitPasted"),
    ("run declaration dropped from KayaRing.java",
     perturbed(src, "KayaRing.java",
               r"native int run\(", "native int runGone("),
     "run"),
    # An emptied jvm.rs must be a loud parse failure, not a clean pass.
    ("jvm.rs emptied",
     {**src, "jvm.rs": ""},
     "vacuous"),
]
for label, mutated, needle in selftests:
    errs = check(mutated)
    hits = [e for e in errs if needle in e]
    if not hits:
        print(f"check-jni: SELF-TEST FAILED — '{label}' produced no failure "
              f"mentioning '{needle}' (got {errs})", file=sys.stderr)
        sys.exit(1)
print(f"check-jni: self-tests OK ({len(selftests)} perturbations, all red)")

# The census's own negatives, watched on every run: a new class with a
# native, a stale exemption, and a reader that found nothing.
_found = class_natives()
for _label, _doctored, _needle in (
    ("a new class declaring a native",
     [*_found, ("KayaNew.kt", {"someNative"})], "KayaNew.kt"),
    ("an exemption for a file that is gone",
     [(n, v) for n, v in _found if n != "KayaGo.kt"], "stale exemption"),
    ("an exemption for a file that declares nothing",
     [(n, set() if n == "KayaPy.kt" else v) for n, v in _found],
     "declares no native at all"),
    ("a reader that found two files", _found[:2], "under the floor"),
):
    _out = unread_classes(_doctored)
    if not any(_needle in e for e in _out):
        print(f"check-jni: SELF-TEST FAILED — the class census passed "
              f"{_label} (wanted a finding naming {_needle!r}; got {_out})",
              file=sys.stderr)
        sys.exit(1)
_census = unread_classes(_found)
if _census:
    for e in _census:
        print(f"check-jni: {e}", file=sys.stderr)
    sys.exit(1)
print(f"check-jni: the class census read {len(_found)} file(s), "
      f"{len(UNREGISTERED)} exempt (4 watched negatives, all red)")

# --- THE APP-LINK DOOR, ON EVERY HOST APK -----------------------------
# The JNI census above is about a native nobody registered; this one is
# about a DOOR nobody opened, and it lives here because both are the same
# shape — a declaration in one file that another file has to answer, with
# nothing at run time to say it did not.
#
# Three things no gate could otherwise see (docs/app-links-plan.md §4):
#
#   THE FILTER. An APK with no VIEW filter resolves no link at all, and
#   the only witness is a leg on a suite that runs the links scene — one
#   of the four hosts. The other three would ship the arm with no door.
#
#   THE SCHEME'S SPELLING. It is declared once in guests/assets/
#   identity.toml and reaches the manifests as a placeholder; a literal
#   typed into four manifests is "one mark, five files" again, and it goes
#   wrong silently, in the direction where the app claims a scheme nobody
#   links to.
#
#   THE ENVIRONMENT MAPPING, WHICH `singleTask` BROKE. The KAYA_* extras
#   are mapped in onCreate, and under `launchMode="singleTask"` a warm
#   explicit start arrives at onNewIntent instead — measured 2026-09-09 on
#   the probe. The lane force-stops before every `am start`, so it takes
#   the COLD path and no leg can see the loss. The mapping is one function
#   now and both doors call it.

# THE SCHEME RULE HAS THREE READERS AND THEY MUST AGREE. crates/kaya/src/
# links.rs `scheme()` answers for the running app; android/build.gradle.kts
# answers for the APK build, and it cannot ask python because it runs
# before any python has; tools/lib/packaging/android.py answers for every
# packaging step. The clause below reads gradle's four decisions OUT OF
# ITS OWN TEXT — the table, the key, the fallback key and the validity
# pattern, never retyped — and then runs BOTH readers over three
# declarations: none, an override, and a malformed scheme.
MANIFESTS = sorted((ROOT / "android").glob("*/src/main/AndroidManifest.xml"))
# The library's manifest declares no activity of its own; every OTHER
# module under android/ is a host APK and owes the door.
LIBRARY_MANIFEST = "kaya"
HOST_FLOOR = 4


def module_of(path):
    return path.parent.parent.parent.name


def link_inputs():
    """{module: (manifest text, MainActivity text)} for the host APKs, and
    the gradle build text beside them."""
    hosts = {}
    for path in MANIFESTS:
        module = module_of(path)
        if module == LIBRARY_MANIFEST:
            continue
        activities = sorted(
            (ROOT / "android" / module / "src/main/kotlin").rglob("MainActivity.kt"))
        hosts[module] = (
            path.read_text(encoding="utf-8"),
            "\n".join(a.read_text(encoding="utf-8") for a in activities),
        )
    return hosts, (ROOT / "android/build.gradle.kts").read_text(encoding="utf-8")


def kotlin_fun_body(text, name):
    """The brace-balanced body of `fun <name>(`, or None."""
    m = re.search(r"\bfun " + name + r"\b", text)
    if not m:
        return None
    start = text.find("{", m.end())
    if start < 0:
        return None
    depth = 0
    for j in range(start, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[start:j + 1]
    return None


def gradle_link_rule(gradle):
    """(table, key, fallback key, validity pattern), READ OUT OF
    android/build.gradle.kts. None for any part it cannot find — a
    reader that found nothing must never read as agreement."""
    table = re.search(r'val links = table\("([^"]*)"\)', gradle)
    pick = re.search(r'links\["([^"]*)"\] \?: value\("([^"]*)"\)', gradle)
    pattern = re.search(r'Regex\("([^"]*)"\)\.matches\(scheme\)', gradle)
    if table is None or pick is None or pattern is None:
        return None
    return (table.group(1), pick.group(1), pick.group(2), pattern.group(1))


# The declarations both readers are run over: what `[links] scheme` says
# (None = no table at all), and what the rule must then answer —
# DECLARED_ID for the default, REFUSED for a sentence, or the literal.
DECLARED_ID = object()
REFUSED = object()
LINK_INPUTS = (
    ("no [links] table at all", None, DECLARED_ID),
    ("an override", "kaya", "kaya"),
    ("a malformed scheme", "1bad", REFUSED),
    # identity.py's own two beyond the rule's three: a table that
    # declares nothing, and an empty override, which must NOT read as
    # "take the default" — an app that wants the id leaves the key out.
    ("a [links] table with no scheme", "", REFUSED),
    ("a dotted override", "kaya.notes", "kaya.notes"),
)


def python_link_answer(links_table, declared_id):
    """packaging/android.py's answer for one declaration, through a
    scratch tree the shared reader parses — never a second parse here."""
    manifest = (ROOT / app_identity.MANIFEST).read_text(encoding="utf-8")
    declared = app_identity.load(ROOT)
    if links_table is not None:
        manifest += (f'\n[{packaging_android.LINK_TABLE}]\n'
                     f'{packaging_android.LINK_KEY} = "{links_table}"\n')
    with scratch_dir("kaya-links-") as scratch:
        path = scratch / app_identity.MANIFEST
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(manifest, encoding="utf-8")
        for rel in {declared.icon, declared.launch_image}:
            dst = scratch / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes((ROOT / rel).read_bytes())
        try:
            return packaging_android.link_scheme(scratch)
        except app_identity.Undeclared:
            return None


def gradle_link_answer(rule, links_table, declared_id):
    """The same declaration through GRADLE's own decisions. Only reached
    once the four decisions above are known equal, so the key and the
    fallback are the shared ones here."""
    _table, _key, _fallback, pattern = rule
    scheme = links_table if links_table is not None else declared_id
    return scheme if re.fullmatch(pattern, scheme) else None


def link_rule_agreement(gradle):
    errs = []
    rule = gradle_link_rule(gradle)
    if rule is None:
        errs.append("android/build.gradle.kts's link-scheme rule is "
                    "unreadable — this gate holds it equal to "
                    "tools/lib/packaging/android.py's, and a reader that "
                    "found nothing agrees with everything")
        return errs
    table, key, fallback, pattern = rule
    # THE FOUR DECISIONS, compared as the literals each file spells.
    for what, theirs, mine in (
        ("reads the scheme out of the table", table,
         packaging_android.LINK_TABLE),
        ("takes the key", key, packaging_android.LINK_KEY),
        ("falls back to the key", fallback,
         packaging_android.LINK_DEFAULT_KEY),
        ("validates the scheme with", pattern,
         packaging_android.LINK_SCHEME_PATTERN),
    ):
        if theirs != mine:
            errs.append(f"android/build.gradle.kts {what} {theirs!r} and "
                        f"tools/lib/packaging/android.py {what} {mine!r} — "
                        f"one rule, and the build reads the manifest before "
                        f"any python has (docs/app-links-plan.md L1; "
                        f"crates/kaya/src/links.rs `scheme()` is the third "
                        f"reader)")
    if errs:
        return errs
    # AND THE SAME ANSWER, RUN, on the three declarations that matter.
    declared_id = app_identity.load(ROOT).id
    for label, declared, _want in LINK_INPUTS:
        if declared == "":
            # gradle's `table()` reader cannot spell an empty value the
            # way identity.py refuses it; that input is the python
            # reader's own, checked by identity_scheme_answers below.
            continue
        mine = python_link_answer(declared, declared_id)
        theirs = gradle_link_answer(rule, declared, declared_id)
        if mine == theirs:
            continue
        if declared is not None and mine == declared_id:
            errs.append(
                f"with {label} the APK's build claims {theirs!r} and "
                f"tools/lib/packaging/android.py answers the declared id: "
                f"tools/lib/packaging/identity.py carries no `"
                f"{packaging_android.LINK_KEY}` on Identity, so the "
                f"override has no python reader at all. Add it there — "
                f"the `[{packaging_android.LINK_TABLE}] "
                f"{packaging_android.LINK_KEY}` key, defaulting to `"
                f"{packaging_android.LINK_DEFAULT_KEY}`, refused by "
                f"{packaging_android.LINK_SCHEME_PATTERN!r} — and this "
                f"clause closes with no other edit")
        else:
            errs.append(f"with {label} android/build.gradle.kts answers "
                        f"{theirs!r} and tools/lib/packaging/android.py "
                        f"answers {mine!r}")
    return errs


def identity_scheme_answers():
    """tools/lib/packaging/identity.py's OWN answers for the five
    declarations — the shared reader's unit test, run here because this
    gate already builds the scratch trees the agreement above needs. The
    empty override is the one worth spelling out: an app that wants the
    declared id leaves the key OUT, and an empty string must be a
    sentence rather than a silent default."""
    errs = []
    declared_id = app_identity.load(ROOT).id
    for label, declared, want in LINK_INPUTS:
        got = python_link_answer(declared, declared_id)
        wanted = declared_id if want is DECLARED_ID else (
            None if want is REFUSED else want)
        if got != wanted:
            errs.append(
                f"identity.py answers {got!r} for {label}, and the rule "
                f"says {'a refusal' if want is REFUSED else repr(wanted)} "
                f"(docs/app-links-plan.md §4)")
    return errs


def link_census(hosts, gradle):
    errs = []
    if len(hosts) < HOST_FLOOR:
        errs.append(f"{len(hosts)} host module(s) read, under the floor of "
                    f"{HOST_FLOOR} — a census that reads nothing agrees with "
                    f"everything")
    if 'manifestPlaceholders["kayaLinkScheme"] = kayaIdentity.linkScheme' \
            not in gradle:
        errs.append("android/build.gradle.kts sets no kayaLinkScheme "
                    "placeholder from the declared identity, so the scheme "
                    "every manifest below claims is not the declared one "
                    "(docs/app-links-plan.md §4)")
    for module, (manifest, activity) in sorted(hosts.items()):
        block = re.search(r"<activity\b.*?</activity>", manifest, re.S)
        if block is None:
            errs.append(f"{module}'s manifest declares no <activity> at all")
            continue
        block = block.group(0)
        if 'android:launchMode="singleTask"' not in block:
            errs.append(f"{module}'s MainActivity is not "
                        f"android:launchMode=\"singleTask\", so a link tapped "
                        f"while the app runs stacks a SECOND activity instead "
                        f"of re-entering the live one (docs/app-links-plan.md "
                        f"L3)")
        view = [f for f in re.findall(r"<intent-filter>.*?</intent-filter>",
                                      block, re.S)
                if "android.intent.action.VIEW" in f]
        if not view:
            errs.append(f"{module}'s MainActivity has no VIEW intent-filter, "
                        f"so this APK resolves no app link at all — only a leg "
                        f"on a suite that runs the links scene would ever say "
                        f"so, and three of these four hosts run none")
            continue
        one = view[0]
        for want, why in (
            ("android.intent.category.DEFAULT",
             "an implicit intent is matched against DEFAULT, so a filter "
             "without it matches no link"),
            ("android.intent.category.BROWSABLE",
             "a link followed from a browser or another app carries "
             "BROWSABLE"),
        ):
            if want not in one:
                errs.append(f"{module}'s VIEW filter declares no {want} — "
                            f"{why}")
        if '<data android:scheme="${kayaLinkScheme}" />' not in one:
            errs.append(f"{module}'s VIEW filter does not claim "
                        f"${{kayaLinkScheme}} — the scheme is declared once in "
                        f"guests/assets/identity.toml and placed by "
                        f"android/build.gradle.kts, and a literal here is one "
                        f"more copy of a value declared once")
        create = kotlin_fun_body(activity, "onCreate")
        new_intent = kotlin_fun_body(activity, "onNewIntent")
        if create is None or new_intent is None:
            errs.append(f"{module}'s MainActivity has no readable onCreate "
                        f"and onNewIntent pair")
            continue
        for door, body in (("onCreate", create), ("onNewIntent", new_intent)):
            if "KayaEnv.fromIntent(intent)" not in body:
                errs.append(f"{module}'s MainActivity.{door} does not map the "
                            f"KAYA_* extras (KayaEnv.fromIntent) — under "
                            f"singleTask a warm start arrives at onNewIntent "
                            f"and a cold one at onCreate, so a scene started "
                            f"through the door this one misses reads no "
                            f"KAYA_SELFTEST")
        if re.search(r'startsWith\("KAYA_"\)', activity):
            errs.append(f"{module}'s MainActivity maps the KAYA_* extras "
                        f"itself; the mapping is KayaEnv.fromIntent, one copy, "
                        f"because it has to run from both doors")
        if "KayaCompose.linkIntent(intent)" not in new_intent:
            errs.append(f"{module}'s MainActivity.onNewIntent hands no intent "
                        f"to KayaCompose.linkIntent, so a link that arrives "
                        f"while this app runs reaches nothing")
        order = [new_intent.find("setIntent(intent)"),
                 new_intent.find("KayaEnv.fromIntent(intent)"),
                 new_intent.find("KayaCompose.linkIntent(intent)")]
        if -1 not in order and sorted(order) != order:
            errs.append(f"{module}'s MainActivity.onNewIntent reads the intent "
                        f"before setIntent — getIntent() answers the LAUNCH "
                        f"intent until setIntent is called (docs/traps.md, "
                        f"measured 2026-09-09)")
    return errs


_hosts, _gradle = link_inputs()


def _without(hosts, module, old, new, where):
    """One host's manifest (where=0) or MainActivity (where=1), doctored."""
    out = dict(hosts)
    text = out[module][where]
    doctored, n = re.subn(re.escape(old), new, text)
    if n != 1:
        print(f"check-jni: SELF-TEST BROKEN — doctoring {module} matched "
              f"{n} times, wanted 1 ({old!r})", file=sys.stderr)
        sys.exit(1)
    print(f"check-jni: link census negative — {module} {old[:40]!r} x{n}")
    pair = list(out[module])
    pair[where] = doctored
    out[module] = tuple(pair)
    return out


for _label, _hosts_d, _gradle_d, _needle in (
    ("the launch mode gone",
     _without(_hosts, "rusthost", 'android:launchMode="singleTask"',
              'android:excludeFromRecents="false"', 0), _gradle, "singleTask"),
    ("the VIEW filter gone",
     _without(_hosts, "javahost", "android.intent.action.VIEW",
              "android.intent.action.SEND", 0), _gradle,
     "no VIEW intent-filter"),
    ("BROWSABLE gone",
     _without(_hosts, "gohost", "android.intent.category.BROWSABLE",
              "android.intent.category.APP_BROWSER", 0), _gradle,
     "BROWSABLE"),
    ("a hand-typed scheme",
     _without(_hosts, "pyhost", '<data android:scheme="${kayaLinkScheme}" />',
              '<data android:scheme="kaya" />', 0), _gradle,
     "does not claim"),
    ("the warm env door gone",
     _without(_hosts, "rusthost",
              """        KayaEnv.fromIntent(intent)
        KayaCompose.notificationIntent(intent)""",
              "        KayaCompose.notificationIntent(intent)", 1), _gradle,
     "onNewIntent does not map"),
    ("the link arm gone",
     _without(_hosts, "gohost", "        KayaCompose.linkIntent(intent)\n",
              "", 1), _gradle, "linkIntent"),
    ("a host mapping KAYA_* itself",
     _without(_hosts, "javahost", "        installSplashScreen()",
              '        for (k in i) { if (k.startsWith("KAYA_")) Os.setenv(k) }',
              1), _gradle, "maps the KAYA_* extras itself"),
    ("the gradle placeholder gone", _hosts,
     _gradle.replace('manifestPlaceholders["kayaLinkScheme"] = '
                     'kayaIdentity.linkScheme', ""), "no kayaLinkScheme"),
    ("a census that read one host", dict(list(_hosts.items())[:1]), _gradle,
     "under the floor"),
):
    _out = link_census(_hosts_d, _gradle_d)
    if not any(_needle in e for e in _out):
        print(f"check-jni: SELF-TEST FAILED — the link census passed "
              f"{_label} (wanted a finding naming {_needle!r}; got {_out})",
              file=sys.stderr)
        sys.exit(1)
_links = link_census(_hosts, _gradle)
if _links:
    for e in _links:
        print(f"check-jni: {e}", file=sys.stderr)
    sys.exit(1)
print(f"check-jni: the link census read {len(_hosts)} host module(s) "
      f"(9 watched negatives, all red)")

# The agreement's own negatives: each doctors ONE of gradle's four
# decisions in its own text, and every one must move an answer.
for _label, _doctored, _needle in (
    ("a different table",
     _gradle.replace('val links = table("links")',
                     'val links = table("applinks")'),
     "reads the scheme out of the table"),
    ("a different key",
     _gradle.replace('links["scheme"] ?: value("id")',
                     'links["url"] ?: value("id")'), "takes the key"),
    ("a different fallback",
     _gradle.replace('links["scheme"] ?: value("id")',
                     'links["scheme"] ?: value("name")'),
     "falls back to the key"),
    ("a looser pattern",
     _gradle.replace('Regex("^[A-Za-z][A-Za-z0-9+.-]*$").matches(scheme)',
                     'Regex("^.*$").matches(scheme)'),
     "validates the scheme with"),
    ("the rule unreadable", "", "unreadable"),
):
    if _doctored == _gradle:
        print(f"check-jni: SELF-TEST BROKEN — the agreement negative "
              f"{_label!r} changed nothing in android/build.gradle.kts",
              file=sys.stderr)
        sys.exit(1)
    print(f"check-jni: link rule negative — {_label}, 1 substitution")
    _out = link_rule_agreement(_doctored)
    if not any(_needle in e for e in _out):
        print(f"check-jni: SELF-TEST FAILED — the scheme-rule agreement "
              f"passed {_label} (wanted a finding naming {_needle!r}; got "
              f"{_out})", file=sys.stderr)
        sys.exit(1)
# identity.py's own answers, watched: the reader as it stood BEFORE the
# `[links]` clause — every declaration answering the declared id, which
# is what tools/lib/packaging/android.py did while `Identity` had no
# `scheme` at all. Substituted at the one call, count printed.
_real_answer = python_link_answer
python_link_answer = lambda _declared, declared_id: declared_id  # noqa: E731
print("check-jni: identity.py negative — the pre-`[links]` reader "
      "(every declaration answers the declared id), 1 substitution")
_pre = identity_scheme_answers()
python_link_answer = _real_answer
for _needle in ("an override", "a malformed scheme"):
    if not any(_needle in e for e in _pre):
        print(f"check-jni: SELF-TEST FAILED — identity.py's answers passed "
              f"the pre-`[links]` reader for {_needle!r} (got {_pre})",
              file=sys.stderr)
        sys.exit(1)

_agreement = link_rule_agreement(_gradle) + identity_scheme_answers()
if _agreement:
    for e in _agreement:
        print(f"check-jni: {e}", file=sys.stderr)
    sys.exit(1)
print(f"check-jni: the scheme rule agrees across its readers, and "
      f"identity.py answers {len(LINK_INPUTS)} declaration(s) as the rule "
      f"says (6 watched negatives, all red)")

errs = check(src)
if errs:
    for e in errs:
        print(f"check-jni: {e}", file=sys.stderr)
    sys.exit(1)
counts = (len(kotlin_externals(src['KayaRing.kt'])),
          len(kotlin_externals(src['KayaPresent.kt'])),
          len(java_natives(src['KayaRing.java'])))
print(f"check-jni: OK (KayaRing.kt {counts[0]}, KayaPresent.kt {counts[1]}, "
      f"KayaRing.java {counts[2]} natives, all registered)")
