#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()


# The JNI registration gate. JNI's own check runs one way only: it fails
# at attach for a registered native the class lacks, but a
# declared-and-unregistered one waits and throws UnsatisfiedLinkError at
# FIRST USE. So this closes the other direction, statically:
#   - every external fun in android/kaya's KayaRing.kt, KayaPresent.kt
#     and Kaya.kt is on the ANDROID attach path (the shared ring list,
#     the present list) or is a Java_dev_kaya_* export in android.rs;
#   - every native in bindings/java-desktop's KayaRing.java is on the
#     DESKTOP attach path or exported in jvm.rs;
#   - every registered name is declared where its list targets.
#
# Name-level on purpose: a signature mismatch DOES fail at attach. The
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

    # Android attach path.
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

    # Desktop attach path.
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

# ---- Self-tests: perturb a copy, prove the perturbation applied,
# demand red. ----

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
    # The entry vanishes from the shared list while both classes still
    # declare it.
    ("openPicked entry dropped from register_ring_natives",
     perturbed(src, "jvm.rs",
               r'NativeMethod \{\s*name: "openPicked"\.into\(\),.*?\},', ""),
     "openPicked"),
    # The other direction: a declaration vanishes under a live entry.
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

# ---- The real check. ----
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
