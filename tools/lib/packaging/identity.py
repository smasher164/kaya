"""THE ONE MANIFEST READER IN tools/ (docs/packaging-plan.md P1).

guests/assets/identity.toml is where the app's name, mark, reverse-DNS
id and launch slot are spelled, and every packaging step reads them from
here — the mac bundle's plist, the Linux desktop entry, the MSIX
manifest, the APK's mipmaps, the iOS bundle. Five readers is how one
mark on five platforms breaks quietly, so there is one, and
tools/check-app-identity.py refuses a second (a tools/ file that parses
the manifest itself).

The RUNNING app's reader is crates/kaya/src/scene.rs `declared_identity`
— the same three values off the same file, one before any program has
run and one at startup. The refusals below are kept parallel to that
one's on purpose: the same missing key must read the same way whichever
half of the declaration noticed it.
"""

import pathlib
import re
import tomllib

MANIFEST = "guests/assets/identity.toml"
ASSET_ROOT = "guests/assets/"
# Two or more dot-separated lowercase labels. Apple refuses a bundle
# identifier outside that shape and GNOME attributes a notification to
# nothing it does not recognise, so a flat id fails on two platforms and
# nowhere else (docs/tasks-s3-plan.md N4).
REVERSE_DNS = re.compile(r"[a-z][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*){1,}")
# RFC 3986's scheme: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ). A
# reverse-DNS id matches it, which is what lets `[links] scheme` default
# to the declared id (docs/app-links-plan.md §4).
LINK_SCHEME = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*")


class Undeclared(SystemExit):
    """A declaration a packaging step cannot proceed from.

    A SystemExit subclass so a script that never catches it leaves with
    the sentence and rc 1, and a gate that wants a FINDING can catch it
    and print the same words.
    """


class Identity:
    """The declaration, resolved against one tree."""

    def __init__(self, root, name, icon, app_id, launch_background,
                 launch_image, scheme, hosts):
        self.root = pathlib.Path(root)
        self.name = name
        self.icon = icon
        self.id = app_id
        self.launch_background = launch_background
        self.launch_image = launch_image
        # `[links] scheme`, or the declared id (docs/app-links-plan.md
        # L1): resolved here so no consumer has to know the default.
        self.scheme = scheme
        # `[links] hosts`, the web links this app claims — EMPTY unless
        # declared, since a web link needs a served HTTPS domain to
        # verify against and no lane has one (L6). The mac and iOS
        # bundles' CFBundleURLTypes and associated-domains entitlement
        # are written from these two together.
        self.hosts = hosts

    @property
    def icon_path(self):
        return self.root / self.icon

    @property
    def launch_image_path(self):
        return self.root / self.launch_image

    @property
    def asset_name(self):
        """The icon's name UNDER the asset root — what a guest opens and
        what the core resolves; derived, never a second spelling."""
        return self.icon[len(ASSET_ROOT):]

    def __repr__(self):
        return (f"Identity(name={self.name!r}, icon={self.icon!r}, "
                f"id={self.id!r}, launch_background="
                f"{self.launch_background!r}, "
                f"launch_image={self.launch_image!r}, "
                f"scheme={self.scheme!r}, hosts={self.hosts!r})")


def load(root):
    """The declaration in `root`'s tree, or Undeclared naming the file."""
    root = pathlib.Path(root)
    path = root / MANIFEST
    rel = MANIFEST
    if not path.is_file():
        raise Undeclared(
            f"kaya: {rel} is missing — the app's identity is declared "
            f"there and the BUILD reads it before any program has run "
            f"(docs/app-identity-plan.md ruling 4); nothing here can "
            f"guess a name, a picture or an id")
    try:
        table = tomllib.loads(path.read_text(encoding="utf-8"))
    except (tomllib.TOMLDecodeError, UnicodeDecodeError) as exc:
        raise Undeclared(f"kaya: {rel} does not parse as TOML: {exc}")

    def want(key):
        value = table.get(key)
        if not isinstance(value, str) or not value.strip():
            raise Undeclared(
                f"kaya: {rel} declares no `{key}` — an app's identity is "
                f"`name`, `icon` and `id` together, declared once in that "
                f"file and spelled in no guest, and a packaging step has "
                f"nothing to write without all three "
                f"(docs/tasks-s3-plan.md N4)")
        return value

    name, icon, app_id = want("name"), want("icon"), want("id")
    if not REVERSE_DNS.fullmatch(app_id):
        raise Undeclared(
            f"kaya: {rel} declares id \"{app_id}\", which is not a "
            f"reverse-DNS name — two or more dot-separated lowercase "
            f"labels (\"dev.kaya.aurora\"). Apple refuses a bundle "
            f"identifier outside that shape and GNOME attributes a "
            f"notification to nothing it does not recognise, so the post "
            f"fails on two platforms and nowhere else")
    icon = icon.replace("\\", "/")
    if not icon.startswith(ASSET_ROOT):
        raise Undeclared(
            f"kaya: {rel} declares icon \"{icon}\", which is not under "
            f"the asset root {ASSET_ROOT} — the build reads that path and "
            f"the running app opens the same picture as an ASSET, so a "
            f"mark outside the root has no asset name to open")
    if not (root / icon).is_file():
        raise Undeclared(
            f"kaya: {rel} names icon \"{icon}\", which is not a file in "
            f"this tree. That file's BYTES are what a package carries and "
            f"what the running app sends over the wire — the same file, "
            f"on purpose")

    launch = table.get("launch")
    if not isinstance(launch, dict):
        raise Undeclared(
            f"kaya: {rel} declares no `[launch]` table — the platforms "
            f"with a slot draw it between the tap and the first frame, "
            f"and an app that declares nothing gets the system's plain "
            f"ground on every one (docs/tasks-s2-plan.md T4)")
    background = launch.get("background")
    if not isinstance(background, str) or not re.fullmatch(
            r"#[0-9A-Fa-f]{6}", background):
        raise Undeclared(
            f"kaya: {rel} declares `[launch] background = "
            f"{background!r}`, which is not #RRGGBB — it becomes an "
            f"Android colour resource, an iOS colour asset and an MSIX "
            f"manifest attribute, and no reader can guess what a "
            f"half-spelled one meant")
    # `image` DEFAULTS TO `icon` (T4): one picture stands for the app in
    # the launcher and on the way in.
    launch_image = launch.get("image", icon)
    if not isinstance(launch_image, str) or not launch_image.strip():
        raise Undeclared(
            f"kaya: {rel} declares an empty `[launch] image`; leave it "
            f"out to take the declared icon")
    launch_image = launch_image.replace("\\", "/")
    if not (root / launch_image).is_file():
        raise Undeclared(
            f"kaya: {rel} names the launch image \"{launch_image}\", "
            f"which is not a file in this tree (leave `image` out to take "
            f"the declared icon)")
    # THE LINK SCHEME, WHICH DEFAULTS TO THE DECLARED ID
    # (docs/app-links-plan.md L1, §4). A reverse-DNS string is a valid URL
    # scheme by RFC 3986 and unique by construction, so an app that
    # declares no `[links]` table still owns `<id>://…`. The other two
    # readers of this rule are crates/kaya/src/links.rs `scheme()` (the
    # running app) and android/build.gradle.kts (the APK build, which
    # runs before any python); tools/check-jni.py holds this one and
    # gradle's to the same decisions and the same answers.
    links = table.get("links")
    scheme = None
    if links is not None:
        if not isinstance(links, dict):
            raise Undeclared(
                f"kaya: {rel} declares `links` as something other than a "
                f"table — `[links]` holds the app's `scheme` and its web "
                f"`hosts`")
        scheme = links.get("scheme")
        if scheme is not None:
            if not isinstance(scheme, str) or not scheme.strip():
                raise Undeclared(
                    f"kaya: {rel} declares an empty `[links] scheme`; "
                    f"leave it out to take the declared id, which is a "
                    f"valid URL scheme on its own")
            if not re.fullmatch(LINK_SCHEME, scheme):
                raise Undeclared(
                    f"kaya: {rel} declares `[links] scheme = {scheme!r}`, "
                    f"which is not a URL scheme — RFC 3986 wants a letter "
                    f"and then letters, digits, `+`, `-` or `.`. Every "
                    f"package's registration claims this string, and a "
                    f"malformed one claims nothing at all")
    hosts = []
    if links is not None:
        hosts = links.get("hosts", [])
        if not isinstance(hosts, list) or not all(
                isinstance(h, str) and h.strip() for h in hosts):
            raise Undeclared(
                f"kaya: {rel} declares `[links] hosts = {hosts!r}` — it is "
                f"a list of domain names the app claims web links for "
                f"(docs/app-links-plan.md L1), and every entry must be a "
                f"non-empty string")
    return Identity(root, name, icon, app_id, background, launch_image,
                    scheme or app_id, hosts)
