"""The Windows arm: an MSIX staging directory, generated from the one
declaration (docs/packaging-plan.md P1/P3).

WHAT A PACKAGE IS FOR HERE. A kaya app is a LIBRARY's process, and a
process is either running from an installed package or it is not
(P3). PACKAGED, the identity — the taskbar group, the toast
attribution, the tile and the launch screen — comes from the manifest
this writes and the library registers nothing; UNPACKAGED, the library
writes its own AUMID key at startup (crates/kaya/src/winui/mod.rs).
The lane runs the Rust guests BOTH ways because users will do both.

ONE PACKAGE, ONE IDENTITY, N ENTRY POINTS. `Identity/@Name` is the
declared reverse-DNS id and every exe handed to `stage()` becomes an
`<Application>` under it, `Id` = the exe's stem, so a lane that packages
several scenes still ships ONE app the way a user's would. The AUMID an
entry point runs under is `<PackageFamilyName>!<Id>`, which is why the
notification arm must not take an AUMID of its own when packaged.

`makeappx pack` and the install are the GUEST's half (tools/guest/
pkg-install.ps1, driven by tools/deploy-win.py): both are Windows SDK
tools, and this module runs on the mac where the lane's exes are
cross-built.
"""

import pathlib
import shutil
import uuid

try:
    from . import identity, mark
except ImportError:  # imported flat, off tools/lib on sys.path
    import identity
    import mark

# The subject the unsigned dev-mode route accepts anything for, and the
# one a real certificate's subject must equal in part 2 (§0: signing for
# other people's machines is part 2 and does not change the artifact).
PUBLISHER = "CN=kaya"
VERSION = "1.0.0.0"
# Windows 10 1809, the floor WinUI 3 itself carries.
MIN_WINDOWS = "10.0.17763.0"

# THE FRAMEWORK A PACKAGED PROCESS GETS FROM ITS PACKAGE GRAPH instead of
# from the bootstrapper, which refuses to run in one (0x80070032,
# ERROR_NOT_SUPPORTED, measured 2026-09-08). The major.minor here IS
# crates/kaya/src/winui/mod.rs's WASDK_MAJOR_MINOR, and tools/check-steps.py
# holds the two equal: bump one and the packaged app finds no runtime.
RUNTIME_NAME = "Microsoft.WindowsAppRuntime.2"
RUNTIME_MIN_VERSION = "2.2.0.0"
RUNTIME_PUBLISHER = ("CN=Microsoft Corporation, O=Microsoft Corporation, "
                     "L=Redmond, S=Washington, C=US")

MANIFEST_NAME = "AppxManifest.xml"
IMAGE_DIR = "Images"

# THE LOGO SET, EVERY SIZE DRAWN DOWN FROM THE DECLARED FILE (P2): the tiles
# come from `icon` and the splash from the launch slot's own image, never one
# from the other and never a small picture blown up.
SQUARE_LOGOS = {
    "Square44x44Logo.png": 44,
    "Square150x150Logo.png": 150,
    "StoreLogo.png": 50,
}
# The two canvases no square picture fills: the declared image centred on the
# declared launch background. SplashScreen is the launch SLOT — the same
# picture the phones draw between the tap and the first frame — and the wide
# tile is the icon's.
GROUND_LOGOS = {
    "Wide310x150Logo.png": (310, 150, "icon"),
    "SplashScreen.png": (620, 300, "launch"),
}


def application_id(exe):
    """The `<Application Id>` for an executable: its stem. The schema
    wants a name that starts with a letter, which every scene name is."""
    stem = pathlib.Path(exe).stem
    if not stem or not stem[0].isalpha() or not stem.isalnum():
        raise ValueError(
            f"packaging/windows: {exe} has no usable Application Id — the "
            f"MSIX schema wants an alphanumeric name starting with a letter, "
            f"and an AUMID is <PackageFamilyName>!<Id>")
    return stem


def _escape(text):
    return (text.replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


# THE COM ACTIVATOR'S ARGUMENT, the same one the library writes into an
# unpackaged LocalServer32 (crates/kaya/src/winui/mod.rs's
# TOAST_ACTIVATED_ARG). COM appends -Embedding of its own.
TOAST_ACTIVATED_ARG = "-ToastActivated"


def activator_clsid(app_id, entry_point=None):
    """THE CLASS ID A TAP ON THIS APP'S TOAST REACHES
    (docs/tasks-s9-plan.md R4), derived and never typed: RFC 4122 version 5
    (SHA-1, name-based) in the DNS namespace over the AUMID the process
    posts under. UNPACKAGED (`entry_point` None) that is the declared id
    alone; PACKAGED it is `<id>!<Application Id>` — one package carries N
    entry points and a CLSID names ONE server, and keying the derivation
    this way is also what stops the library's own unpackaged HKCU
    registration shadowing the package's (both measured 2026-09-08).
    crates/kaya/src/winui/mod.rs's `activator_clsid` is the same derivation
    in Rust; tools/check-steps.py holds the two to one sentence and the
    guest unit test pins both against frozen values.

    Upper case and UNBRACED, which is the MSIX schema's spelling for both
    `ToastActivatorCLSID` and `com:Class/@Id`; the registry's is braced."""
    name = app_id if entry_point is None else f"{app_id}!{entry_point}"
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, name)).upper()


def activator_clsid_braced(app_id, entry_point=None):
    """The registry's and `CoCreateInstance`'s spelling of the same id."""
    return "{" + activator_clsid(app_id, entry_point) + "}"


def protocol_extension(decl, mine):
    """THE LINK DOOR, PACKAGED (docs/app-links-plan.md L1). A packaged process
    registers NOTHING at run time — its HKCU is virtualized and this element is
    its whole declaration, which is why crates/kaya/src/winui/mod.rs's
    `links_declared` skips its own registration when `packaged()`.

    ONE PACKAGE MAY CLAIM A SCHEME ONCE, measured on the VM 2026-09-09: with
    the extension on both of this lane's entry points, `makeappx pack` refuses
    the manifest with `'dev.kaya.aurora.notes' is a duplicate key for the
    unique Identity Constraint 'Extension_Protocol'` — the constraint is over
    the whole Package, not the Application. The DOTTED scheme itself is
    accepted (the schema complained about the duplicate and not about the
    dots), which is what L1's default needed. A real kaya app has ONE entry
    point and never meets this; the lane packages several scenes as one app,
    so the claim goes on the entry `manifest()` was told is the link's."""
    if not mine:
        return ""
    return (f'        <uap:Extension Category="windows.protocol">\n'
            f'          <uap:Protocol Name="{_escape(decl.scheme)}">\n'
            f'            <uap:Logo>{IMAGE_DIR}\\Square44x44Logo.png</uap:Logo>\n'
            f'            <uap:DisplayName>{_escape(decl.name)}</uap:DisplayName>\n'
            f'          </uap:Protocol>\n'
            f'        </uap:Extension>\n')


def manifest(decl, exes, arch="arm64", version=VERSION, publisher=PUBLISHER,
             links_entry=None):
    """AppxManifest.xml for the declaration and these entry points.

    Nothing here is typed twice: the name, the id and the launch
    background all come from `identity.load`, and the logo file names are
    the ones `stage()` writes.

    `links_entry` is the `<Application Id>` that claims the declared URL
    scheme, and NAMING IT IS THE CALLER'S JOB: a package may claim a scheme
    exactly once (`protocol_extension`'s measurement), so there is no entry a
    multi-entry package could be guessed to mean. `None` claims nothing, which
    is what a machine that already holds another claimant wants
    (tools/deploy-win.py's package phase says why this lane is one)."""
    exes = list(exes)
    apps = []
    for exe in exes:
        app_id = application_id(exe)
        exe_name = pathlib.Path(exe).name
        clsid = activator_clsid(decl.id, app_id)
        apps.append(
            f'    <Application Id="{app_id}" '
            f'Executable="{exe_name}" '
            f'EntryPoint="Windows.FullTrustApplication">\n'
            f'      <uap:VisualElements DisplayName="{_escape(decl.name)}"\n'
            f'          Description="{_escape(decl.name)}"\n'
            f'          BackgroundColor="{decl.launch_background}"\n'
            f'          Square150x150Logo="{IMAGE_DIR}\\Square150x150Logo.png"\n'
            f'          Square44x44Logo="{IMAGE_DIR}\\Square44x44Logo.png">\n'
            f'        <uap:DefaultTile '
            f'Wide310x150Logo="{IMAGE_DIR}\\Wide310x150Logo.png" />\n'
            f'        <uap:SplashScreen '
            f'Image="{IMAGE_DIR}\\SplashScreen.png" />\n'
            f'      </uap:VisualElements>\n'
            # THE CLOSED-APP DOOR, PACKAGED (docs/tasks-s9-plan.md R4). BOTH
            # extensions are required and neither works alone: the desktop one
            # tells the toast platform which class a tap on this entry point's
            # notification goes to, the com one tells COM which exe serves that
            # class. The library registers the same pair under HKCU when the
            # process finds itself unpackaged.
            f'      <Extensions>\n'
            f'        <desktop:Extension '
            f'Category="windows.toastNotificationActivation">\n'
            f'          <desktop:ToastNotificationActivation '
            f'ToastActivatorCLSID="{clsid}" />\n'
            f'        </desktop:Extension>\n'
            f'        <com:Extension Category="windows.comServer">\n'
            f'          <com:ComServer>\n'
            f'            <com:ExeServer Executable="{exe_name}" '
            f'Arguments="{TOAST_ACTIVATED_ARG}" '
            f'DisplayName="{_escape(decl.name)}">\n'
            f'              <com:Class Id="{clsid}" '
            f'DisplayName="{_escape(decl.name)}" />\n'
            f'            </com:ExeServer>\n'
            f'          </com:ComServer>\n'
            f'        </com:Extension>\n'
            + protocol_extension(decl, app_id == links_entry)
            + '      </Extensions>\n'
            '    </Application>')
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<Package\n'
        '    xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"\n'
        '    xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"\n'
        '    xmlns:desktop="http://schemas.microsoft.com/appx/manifest/desktop/'
        'windows10"\n'
        '    xmlns:com="http://schemas.microsoft.com/appx/manifest/com/windows10"\n'
        '    xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/'
        'windows10/restrictedcapabilities"\n'
        '    IgnorableNamespaces="uap desktop com rescap">\n'
        f'  <Identity Name="{decl.id}" Publisher="{publisher}" '
        f'Version="{version}" ProcessorArchitecture="{arch}" />\n'
        '  <Properties>\n'
        f'    <DisplayName>{_escape(decl.name)}</DisplayName>\n'
        f'    <PublisherDisplayName>'
        f'{_escape(publisher.partition("=")[2] or publisher)}'
        f'</PublisherDisplayName>\n'
        f'    <Logo>{IMAGE_DIR}\\StoreLogo.png</Logo>\n'
        '  </Properties>\n'
        '  <Dependencies>\n'
        f'    <TargetDeviceFamily Name="Windows.Desktop" '
        f'MinVersion="{MIN_WINDOWS}" MaxVersionTested="{MIN_WINDOWS}" />\n'
        f'    <PackageDependency Name="{RUNTIME_NAME}" '
        f'MinVersion="{RUNTIME_MIN_VERSION}" '
        f'Publisher="{RUNTIME_PUBLISHER}" />\n'
        '  </Dependencies>\n'
        '  <Resources>\n'
        '    <Resource Language="en-us" />\n'
        '  </Resources>\n'
        '  <Capabilities>\n'
        '    <rescap:Capability Name="runFullTrust" />\n'
        '  </Capabilities>\n'
        '  <Applications>\n'
        + "\n".join(apps) + "\n"
        '  </Applications>\n'
        '</Package>\n')


# The cross-build target each package architecture's payload comes out of —
# the same directory tools/deploy-win.py ships from.
TRIPLE = {"arm64": "aarch64-pc-windows-msvc", "x64": "x86_64-pc-windows-msvc"}
# The App SDK's own loader, which the backend loads BY NAME out of the
# executable's directory: a packaged app needs its own copy exactly as an
# unpackaged one does, and without it kaya_run panics on its first line.
BOOTSTRAP = ("third_party/winappsdk/Microsoft.WindowsAppSDK.Foundation-2.1.0/"
             "extracted/runtimes/win-{arch}/native/"
             "Microsoft.WindowsAppRuntime.Bootstrap.dll")


def default_beside(root, arch, lib=None):
    """What a COMPLETE app needs in the executable's own directory: the
    library, by the loader's directory rule; the App SDK's bootstrap; and an
    MRT index, without which the XAML parser fail-fasts at 0xC000027B
    (docs/traps.md)."""
    root = pathlib.Path(root)
    triple = TRIPLE.get(arch)
    if triple is None:
        raise ValueError(
            f"packaging/windows: no cross-build target for {arch!r} — "
            f"the architectures with one are {', '.join(sorted(TRIPLE))}")
    lib = pathlib.Path(lib) if lib else (
        root / "target" / triple / "release" / "kaya.dll")
    if not lib.is_file():
        raise SystemExit(
            f"packaging/windows: {lib} is not built, and a package without "
            f"kaya.dll beside its exe is not an app — build it with "
            f"`cargo xwin build --locked --release --target {triple} "
            f"-p kaya`, or name another copy with --lib")
    bootstrap = root / BOOTSTRAP.format(arch=arch)
    if not bootstrap.is_file():
        raise SystemExit(
            f"packaging/windows: {bootstrap} is not unpacked, so the app "
            f"would panic at startup with `Microsoft.WindowsAppRuntime."
            f"Bootstrap.dll not found next to the executable` — run "
            f"tools/fetch-winappsdk.sh")
    return [lib, bootstrap,
            (root / "guests/assets/win/minimal-resources.pri",
             "resources.pri")]


def stage(root, exes, out, arch="arm64", beside=None, assets=True,
          lib=None, links_entry=None):
    """Write the whole package layout under `out` and return it.

    `exes` are the entry points, copied in beside each other; `beside`
    is every other file the process needs in its own directory, each a
    path or a `(path, name-in-the-package)` pair, and DEFAULTS to
    `default_beside(root, arch, lib)` — a package with no kaya.dll is not
    an app, and `lib` names another copy of it without losing the rest. `assets` puts the declared asset ROOT at `assets/`, which is
    assets.rs's "beside the executable" route, so a packaged process
    needs no KAYA_ASSET_DIR at all."""
    decl = identity.load(root)
    if beside is None:
        beside = default_beside(root, arch, lib)
    out = pathlib.Path(out)
    if out.exists():
        shutil.rmtree(out)
    (out / IMAGE_DIR).mkdir(parents=True)
    icon = decl.icon_path.read_bytes()
    launch = decl.launch_image_path.read_bytes()
    for name, px in SQUARE_LOGOS.items():
        (out / IMAGE_DIR / name).write_bytes(mark.resample(icon, px))
    for name, (w, h, source) in GROUND_LOGOS.items():
        (out / IMAGE_DIR / name).write_bytes(
            mark.fit_on(icon if source == "icon" else launch, w, h,
                        decl.launch_background))
    exes = [pathlib.Path(e) for e in exes]
    for exe in exes:
        shutil.copy2(exe, out / exe.name)
    for extra in beside:
        source, name = extra if isinstance(extra, tuple) else (extra, None)
        source = pathlib.Path(source)
        shutil.copy2(source, out / (name or source.name))
    if assets:
        shutil.copytree(pathlib.Path(root) / "guests/assets", out / "assets")
    (out / MANIFEST_NAME).write_text(
        manifest(decl, exes, arch=arch, links_entry=links_entry),
        encoding="utf-8")
    return out
