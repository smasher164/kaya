"""check-app-identity's C15: every `[links] hosts` entry is a verified web
link AND a saved-login domain on Apple and Android, from one declaration
(docs/app-links-plan.md L1, docs/autofill-plan.md A8 as ruled
2026-10-07). No lane serves a domain, so the generated claims are run
over a fixture declaring two hosts and read back; the APK's compiled
manifest is read on the lane by run-emulator's web_declaration."""

import importlib.util
import json
import os
import pathlib
import sys
import tempfile

FIXTURE_HOSTS = ("example.com", "*.example.org")
TEAM = "ABCDE12345"
CERT = ":".join(["AB"] * 32)


def _arms(root, tag):
    pkg = f"_webclaims_{tag}"
    base = pathlib.Path(root) / "tools/lib/packaging"
    spec = importlib.util.spec_from_file_location(
        pkg, base / "__init__.py", submodule_search_locations=[str(base)])
    mod = importlib.util.module_from_spec(spec)
    sys.modules[pkg] = mod
    spec.loader.exec_module(mod)
    out = {}
    for name in ("identity", "android", "site"):
        sub = importlib.util.spec_from_file_location(
            f"{pkg}.{name}", base / f"{name}.py")
        m = importlib.util.module_from_spec(sub)
        sys.modules[f"{pkg}.{name}"] = m
        sub.loader.exec_module(m)
        out[name] = m
    return out


def _fixture(root, scratch, hosts_line):
    root = pathlib.Path(root)
    fx = pathlib.Path(tempfile.mkdtemp(prefix="webclaims-", dir=scratch))
    text = (root / "guests/assets/identity.toml").read_text(encoding="utf-8")
    (fx / "guests/assets").mkdir(parents=True)
    (fx / "guests/assets/identity.toml").write_text(
        text + "\n[links]\n" + hosts_line + "\n", encoding="utf-8")
    for line in text.splitlines():
        if line.startswith("icon"):
            rel = line.split("=", 1)[1].strip().strip('"')
            (fx / rel).parent.mkdir(parents=True, exist_ok=True)
            os.symlink(root / rel, fx / rel)
    return fx


def check(root, scratch, tag):
    """Findings for the arms under `root`."""
    bad = []
    root = pathlib.Path(root)
    try:
        arms = _arms(root, tag)
    except Exception as exc:                              # noqa: BLE001
        return [f"C15: the packaging arms under {root} do not import: "
                f"{exc}"]
    ident, android, site = arms["identity"], arms["android"], arms["site"]
    hosts_line = "hosts = [" + ", ".join(f'"{h}"' for h in FIXTURE_HOSTS) \
        + "]"
    fx = _fixture(root, scratch, hosts_line)
    declared = ident.load(fx)

    domains = ident.associated_domains(declared)
    for h in FIXTURE_HOSTS:
        for kind in ("applinks", "webcredentials"):
            if f"{kind}:{h}" not in domains:
                bad.append(f"C15: associated_domains answers {domains} "
                           f"for host {h!r}, missing `{kind}:{h}` — the "
                           f"Apple claim for its "
                           f"{'links' if kind == 'applinks' else 'saved logins'}")
    ent = ident.apple_entitlements(declared) or ""
    if "com.apple.developer.associated-domains" not in ent or not all(
            f"<string>{d}</string>" in ent for d in domains):
        bad.append("C15: apple_entitlements does not carry every "
                   "associated domain under "
                   "com.apple.developer.associated-domains")
    if ident.apple_entitlements(ident.load(root)) is not None \
            and not ident.load(root).hosts:
        bad.append("C15: apple_entitlements answers an entitlement for a "
                   "declaration with no hosts; an ad-hoc bundle carrying "
                   "it is killed at exec (docs/traps.md)")

    overlay = android.links_overlay(declared)
    if 'android:autoVerify="true"' not in overlay:
        bad.append("C15: the APK overlay's https filter is not "
                   "autoVerify, so Android never checks assetlinks.json")
    for h in FIXTURE_HOSTS:
        if f'android:host="{h}"' not in overlay:
            bad.append(f"C15: the APK overlay does not claim {h}")
    if 'android:name="asset_statements"' not in overlay:
        bad.append("C15: the APK overlay declares no asset_statements "
                   "meta-data, which Android's password manager needs to "
                   "find a host's get_login_creds statement (docs/"
                   "autofill-plan.md A8)")
    values = android.links_values(declared)
    for h in FIXTURE_HOSTS:
        url = f"https://{h.removeprefix('*.')}/.well-known/assetlinks.json"
        if url not in values.replace('\\"', '"'):
            bad.append(f"C15: the asset_statements string does not "
                       f"include {url}")
    empty = android.links_overlay(ident.load(root)) \
        if not ident.load(root).hosts else ""
    if "<application" in empty:
        bad.append("C15: the APK overlay claims something with no hosts "
                   "declared")

    out = pathlib.Path(tempfile.mkdtemp(prefix="site-", dir=scratch))
    try:
        site.write(fx, out, TEAM, "dev.kaya.example", [CERT])
    except SystemExit as exc:
        return bad + [f"C15: the site arm refused the fixture: {exc}"]
    app = f"{TEAM}.{declared.id}"
    for h in FIXTURE_HOSTS:
        wk = out / h.removeprefix("*.") / ".well-known"
        try:
            aasa = json.loads((wk / "apple-app-site-association")
                              .read_text(encoding="utf-8"))
            links = json.loads((wk / "assetlinks.json")
                               .read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            bad.append(f"C15: the site files for {h} are unreadable: {exc}")
            continue
        if aasa.get("webcredentials", {}).get("apps") != [app]:
            bad.append(f"C15: {h}'s apple-app-site-association names no "
                       f"webcredentials app {app}")
        if app not in aasa.get("applinks", {}).get("details", [{}])[0] \
                .get("appIDs", []):
            bad.append(f"C15: {h}'s apple-app-site-association names no "
                       f"applinks app {app}")
        rels = {r for s in links
                if s.get("target", {}).get("namespace") == "android_app"
                for r in s.get("relation", [])}
        for want in ("delegate_permission/common.get_login_creds",
                     "delegate_permission/common.handle_all_urls"):
            if want not in rels:
                bad.append(f"C15: {h}'s assetlinks.json grants the app no "
                           f"{want}")

    for line, why in (('hosts = [\n  "example.com",\n]', "several lines"),
                      ('hosts = ["https://example.com"]', "not a domain")):
        try:
            ident.load(_fixture(root, scratch, line))
            bad.append(f"C15: the reader accepted `{line!r}`, which it "
                       f"must refuse ({why})")
        except SystemExit:
            pass

    gradle = (root / "android/build.gradle.kts").read_text(encoding="utf-8")
    for build_type in ("debug", "release"):
        if f'sourceSets.getByName("{build_type}").manifest.srcFile(' \
                f'linksOverlay)' not in gradle:
            bad.append(f"C15: android/build.gradle.kts does not lay the "
                       f"links overlay over the {build_type} build")
    runner = (root / "tools/android/run-emulator.py").read_text(
        encoding="utf-8")
    if "link_declaration(tree, package, want, hosts)" not in runner:
        bad.append("C15: run-emulator's apk_link_verify no longer hands "
                   "the declared hosts to the compiled-manifest reader")
    mac = (root / "tools/lib/packaging/mac.py").read_text(encoding="utf-8")
    if "write_entitlements(declared, app)" not in mac:
        bad.append("C15: the mac arm writes no entitlements for the "
                   "declared hosts")
    if "--entitlements" in mac.replace("--entitlements {path}", ""):
        bad.append("C15: the mac arm signs an entitlement in ad hoc; the "
                   "kernel kills such a bundle at exec (docs/traps.md)")
    return bad
