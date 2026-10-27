#!/usr/bin/env python3
# docs/traps.md, "cargo keeps an artifact a restore with an old mtime made stale".
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
STAMP = ".kaya-sources.json"


def _core_id():
    spec = importlib.util.spec_from_file_location("kaya_build_id", ROOT / "tools/build-id.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.build_id("core")


def _age(path):
    os.utime(path, (0, 0))


def age_stale_core(profile, want):
    """Every kaya build-script run under `profile` whose baked id is not `want` is aged, with the
    derive crate's reference, so cargo reruns it and recompiles the core from these bytes."""
    stale = []
    for out in sorted(profile.glob("build/kaya-*/output")):
        m = re.search(r"KAYA_BUILD_ID=([0-9a-f]{16})", out.read_text(encoding="utf-8", errors="replace"))
        if m and m.group(1) != want:
            stale.append(out)
    if not stale:
        return []
    for out in stale:
        _age(out)
    for ref in profile.glob(".fingerprint/kaya-derive-*/dep-lib-kaya_derive"):
        _age(ref)
    return stale


def examples_in(cmd):
    names = []
    for i, arg in enumerate(cmd):
        if arg == "--example" and i + 1 < len(cmd):
            names.append(cmd[i + 1])
        elif arg.startswith("--example="):
            names.append(arg.split("=", 1)[1])
    return names


def dep_files(text):
    """The inputs a cargo dep-info file names for its first target."""
    first = text.replace("\\\n", " ").split("\n", 1)[0]
    _, _, deps = first.partition(": ")
    return [p.replace("\\ ", " ") for p in re.split(r"(?<!\\) ", deps) if p]


def _digest(dep_info, memo):
    h = hashlib.sha256()
    for name in dep_files(dep_info.read_text(encoding="utf-8", errors="replace")):
        p = os.path.normpath(name)
        if p not in memo:
            try:
                memo[p] = hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() if os.path.isfile(p) else (
                    "dir" if os.path.isdir(p) else "missing")
            except OSError:
                memo[p] = "unreadable"
        h.update(f"{p}\0{memo[p]}\0".encode())
    return h.hexdigest()[:16]


def _identity(path):
    st = path.stat()
    return [st.st_size, st.st_mtime_ns]


def _load(stamp):
    try:
        return json.loads(stamp.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _save(stamp, data):
    tmp = stamp.with_name(f"{stamp.name}.{os.getpid()}")
    tmp.write_text(json.dumps(data, indent=1, sort_keys=True), encoding="utf-8")
    os.replace(tmp, stamp)


def cargo(run, profile, examples=(), artifact="{name}", who="content_fresh", core_id=None):
    """`run()` is the lane's cargo call and returns its exit status. Each example's artifact must
    either be written by this build or match the sources the stamp beside it was taken from;
    one that does neither is aged and built again, and a second miss refuses."""
    profile = pathlib.Path(profile)
    aged = age_stale_core(profile, core_id or _core_id())
    if aged:
        print(f"{who}: the core's build script under {profile} baked another tree's id "
              f"({len(aged)} run(s)); cargo reruns it", flush=True)
    start = time.time_ns()
    rc = run()
    if rc != 0 or not examples:
        return rc
    stamp = profile / "examples" / STAMP
    known = _load(stamp)
    memo = {}

    def check(name, since):
        art = profile / "examples" / artifact.format(name=name)
        if not art.is_file():
            return art, None, "missing"
        dep = art.with_suffix(".d")
        if not dep.is_file():
            return art, None, f"no dep-info {dep.name}"
        ident, src = _identity(art), _digest(dep, memo)
        if ident[1] >= since:
            return art, {"exe": ident, "sources": src}, None
        was = known.get(name)
        if was == {"exe": ident, "sources": src}:
            return art, was, None
        why = ("no record of the sources it was built from" if was is None else
               "it was written by a build that did not go through this check" if was["exe"] != ident else
               "its sources' bytes changed since it was built, under an older mtime")
        return art, None, why

    fresh, stale = {}, {}
    for name in examples:
        art, rec, why = check(name, start)
        if rec is not None:
            fresh[name] = rec
        else:
            stale[name] = (art, why)
    if stale:
        for name, (art, why) in sorted(stale.items()):
            print(f"{who}: {art.relative_to(profile)} is stale ({why}); building it again", flush=True)
            for ref in profile.glob(f".fingerprint/*/dep-example-{name}"):
                _age(ref)
        memo.clear()
        again = time.time_ns()
        rc = run()
        if rc != 0:
            return rc
        for name in list(stale):
            art, rec, why = check(name, again)
            if rec is None:
                print(f"{who}: REFUSED — cargo kept {art} after its fingerprint was aged ({why}), "
                      f"so it was not built from the sources in this tree. Run `cargo clean -p "
                      f"kaya` with this build's --target and profile flags and build again.",
                      file=sys.stderr, flush=True)
                return 1
            fresh[name] = rec
    known.update(fresh)
    _save(stamp, known)
    return 0


def _tree_digest(roots, skip):
    h = hashlib.sha256()
    for root in roots:
        base = ROOT / root
        for f in sorted(p for p in base.rglob("*") if p.is_file()):
            rel = f.relative_to(base)
            if skip & set(rel.parts):
                continue
            h.update(f"{root}/{rel}\0".encode())
            h.update(hashlib.sha256(f.read_bytes()).digest())
    return h.hexdigest()[:16]


def by_content(run, inputs, outputs, stamp, skip=frozenset(), who="content_fresh"):
    """For a builder that skips work by mtime ordering (make, MSBuild): `run(full)` builds, and
    full is True unless the inputs' bytes and the outputs' identities are the ones the stamp
    recorded after this function's last build."""
    stamp = pathlib.Path(stamp)
    now = {"sources": _tree_digest(inputs, set(skip)),
           "outputs": [_identity(o) if o.is_file() else None for o in outputs]}
    full = _load(stamp) != now
    if full:
        print(f"{who}: the sources or outputs moved since {stamp.name} was taken; a full build",
              flush=True)
    rc = run(full)
    if rc != 0:
        return rc
    missing = [str(o) for o in outputs if not o.is_file()]
    if missing:
        print(f"{who}: the build left no {', '.join(missing)}", file=sys.stderr, flush=True)
        return 1
    stamp.parent.mkdir(parents=True, exist_ok=True)
    _save(stamp, {"sources": now["sources"], "outputs": [_identity(o) for o in outputs]})
    return 0


def clean_for(cmd, package):
    """The `cargo clean` that drops `package`'s artifacts from the profile `cmd` builds into."""
    out = ["cargo", "clean", "--locked", "-p", package]
    for i, arg in enumerate(cmd):
        if arg == "--release":
            out.append(arg)
        elif arg in ("--target", "--target-dir", "--manifest-path", "--profile") and i + 1 < len(cmd):
            out += [arg, cmd[i + 1]]
        elif arg.split("=", 1)[0] in ("--target", "--target-dir", "--manifest-path", "--profile"):
            out.append(arg)
    return out


def package_of(crate):
    m = re.search(r'^\[package\][^\[]*?^name\s*=\s*"([^"]+)"',
                  (pathlib.Path(crate) / "Cargo.toml").read_text(encoding="utf-8"), re.M | re.S)
    if not m:
        raise SystemExit(f"content_fresh: {crate}/Cargo.toml names no [package]")
    return m.group(1)


def nested(cmd, crate, outputs, who="content_fresh", env=None):
    """A crate in a workspace of its own: when its sources' bytes or its outputs moved since the
    last build through here, its package is cleaned first, so cargo cannot keep an artifact by
    mtime."""
    crate = pathlib.Path(crate).resolve()
    outputs = [pathlib.Path(o) for o in outputs]
    package = package_of(crate)

    def run(full):
        if full:
            rc = subprocess.run(clean_for(cmd, package), cwd=crate, env=env, check=False).returncode
            if rc != 0:
                return rc
        return subprocess.run(cmd, cwd=crate, env=env, check=False).returncode

    return by_content(run, [str(crate)], outputs, outputs[0].parent / f".kaya-sources-{package}.json",
                      skip={"target"}, who=who)


USAGE = ("usage: content_fresh.py --profile DIR [--artifact PATTERN] -- CARGO-COMMAND...\n"
         "       content_fresh.py --crate DIR --outputs FILE[,FILE] -- CARGO-COMMAND...")


def main(argv):
    if "--" not in argv:
        sys.exit(USAGE)
    opts, cmd = argv[: argv.index("--")], argv[argv.index("--") + 1:]
    args = dict(zip(opts[::2], opts[1::2]))
    if set(args) == {"--crate", "--outputs"}:
        return nested(cmd, args["--crate"], args["--outputs"].split(","), "content_fresh")
    if "--profile" not in args or set(args) - {"--profile", "--artifact"}:
        sys.exit(USAGE)
    return cargo(lambda: subprocess.run(cmd, check=False).returncode, args["--profile"],
                 examples_in(cmd), args.get("--artifact", "{name}"))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
