"""docs/network-images-plan.md N2, N7, N8, N12, N16; called by check-sugar-surface.

Each row is one surface in one binding, read out of that binding's own file:
the phase type, `phase` in the live and template zones, the conditional
write, the two realization handlers, the helper and, in the six bindings with
a standard client, its default fetch and the `kaya/<version>` User-Agent it
sends (docs/media-player-plan.md M16). `fit` on the image is the video view's
spelling in every binding and is held by the media rows already."""

import re

from kaya_gate import ROOT, Gate

PY = "bindings/python/kaya/__init__.py"
JS = "bindings/js/kaya/index.ts"
GO = "bindings/go/images.go"
CS = "bindings/csharp/KayaApp.cs"
CSI = "bindings/csharp/KayaImages.cs"
CSR = "bindings/csharp/KayaRecords.cs"
JV = "bindings/java/dev/kaya/KayaApp.java"
JVR = "bindings/java/dev/kaya/KayaRecords.java"
SW = "bindings/swift/KayaApp.swift"
SWI = "bindings/swift/KayaImages.swift"
ML = "bindings/ocaml/kaya_app.mli"
HSC = "bindings/haskell/Kaya/Core.hs"
HS = "bindings/haskell/KayaApp.hs"
RS = "crates/kaya/src/app.rs"
RSI = "crates/kaya/src/app/images.rs"

# (label, file, pattern, the name inside it a rename cuts)
ROWS = [
    ("rust phase type", RS, r"^pub struct ImagePhaseKind;", "ImagePhaseKind"),
    ("rust live phase", RS, r"pub fn phase\(self, phase: impl Into<LiveSource<ImagePhaseKind>>\) -> Self", "phase"),
    ("rust template phase", RS, r"pub fn phase\(&mut self, node: TemplateNodeId, src: impl Into<TplSource<ImagePhaseKind>>\)", "phase"),
    ("rust conditional write", RS, r"pub fn patch_if<'t, 'c, K: ValueKind, V: KayaField<Kind = K>>\(", "patch_if"),
    ("rust on_needed", RS, r"pub fn on_needed_node\(&self, n: TemplateNodeId, f: impl Fn\(Path\) -> M \+ 'static\)", "on_needed_node"),
    ("rust on_released", RS, r"pub fn on_released_node\(&self, n: TemplateNodeId, f: impl Fn\(Path\) -> M \+ 'static\)", "on_released_node"),
    ("rust helper", RSI, r"^pub struct RowImages<T: KayaSum \+ Send \+ Sync \+ 'static> \{", "RowImages"),

    ("python phase type", PY, r"^class ImagePhase\(enum\.IntEnum\):", "ImagePhase"),
    ("python phase both zones", PY, r"^def image\(source[^)]*\*, phase: ImagePhase \| str \| Source \| None = None,", "phase"),
    ("python live phase setter", PY, r"^    def phase\(self, phase: ImagePhase \| str \| Source\) -> None:", "phase"),
    ("python conditional write", PY, r"def patch\(self, key: Key, /, \*, when: Mapping\[str, Any\] \| None = None,", "when"),
    ("python on_needed", PY, r"^def image\(source[^)]*\bon_needed: Handler \| None = None,", "on_needed"),
    ("python on_released", PY, r"^def image\(source[^)]*\bon_released: Handler \| None = None,", "on_released"),
    ("python helper", PY, r"^class RowImages\(Generic\[T\]\):", "RowImages"),
    ("python default fetch", PY, r"def default_fetch\(url: str\) -> bytes:", "default_fetch"),
    ("python default fetch user agent", PY, r'def default_fetch\(url: str\) -> bytes:(?:\n[^\n]*){0,6}?\n[^\n]*headers=\{"User-Agent": f"kaya/\{wire\.VERSION\}"\}', "User-Agent"),

    ("js phase type", JS, r"^export class ImagePhase \{", "ImagePhase"),
    ("js phase both zones", JS, r"^\s+phase\?: ImagePhase \| Signal<ImagePhase> \| FieldRef;", "phase"),
    ("js live phase setter", JS, r"^  phase\(phase: ImagePhase \| Signal<ImagePhase>\): this \{", "phase"),
    ("js conditional write", JS, r"^export type PatchOptions<E> = \{ when\?: Partial<E> \};", "when"),
    ("js on_needed", JS, r"^\s+onNeeded\?: Handler;", "onNeeded"),
    ("js on_released", JS, r"^\s+onReleased\?: Handler;", "onReleased"),
    ("js helper", JS, r"^export class RowImages<E> \{", "RowImages"),
    ("js default fetch", JS, r"static async defaultFetch\(url: string, signal: AbortSignal\): Promise<Uint8Array> \{", "defaultFetch"),
    ("js default fetch user agent", JS, r'static async defaultFetch\(url: string, signal: AbortSignal\)[^\n]*\n[^\n]*headers: \{ "User-Agent": `kaya/\$\{wire\.VERSION\}` \}', "User-Agent"),

    ("go phase type", GO, r"^type ImagePhase int64", "ImagePhase"),
    ("go live phase", GO, r"func \(w Widget\) Phase\(phase ImagePhase\) Widget", "Phase"),
    ("go live phase bound", GO, r"func \(w Widget\) BindPhase\(s Signal\[ImagePhase\]\) Widget", "BindPhase"),
    ("go template phase", GO, r"func \(t \*Tpl\) SetPhase\(n Node, phase ImagePhase\)", "SetPhase"),
    ("go template phase bound", GO, r"func \(t \*Tpl\) BindPhase\[S interface \{", "BindPhase"),
    ("go conditional write", GO, r"func \(c RecordCollection\[K, T\]\) PatchIf\[V comparable\]\(tx \*Tx, key K, guard func\(\*T\) \*V, expected V\)", "PatchIf"),
    ("go on_needed", GO, r"func \(n Node\) OnNeeded\(fn func\(\*Tx, \[\]any\)\) Node", "OnNeeded"),
    ("go on_released", GO, r"func \(n Node\) OnReleased\(fn func\(\*Tx, \[\]any\)\) Node", "OnReleased"),
    ("go helper", GO, r"func NewRowImages\[K Key, T any\]\(app \*App, rows RecordCollection\[K, T\],", "NewRowImages"),
    ("go default fetch", GO, r"func FetchHTTP\(ctx context\.Context, url string\)", "FetchHTTP"),
    ("go default fetch user agent", GO, r'func FetchHTTP\(ctx context\.Context, url string\)[^\n]*(?:\n[^\n]*){0,5}?\n\treq\.Header\.Set\("User-Agent", "kaya/"\+Version\)', "User-Agent"),

    ("csharp phase type", CS, r"^enum ImagePhase : long", "ImagePhase"),
    ("csharp live phase", CS, r"public Widget Image\(byte\[\]\? source = null[^)]*ImagePhase\? phase = null[,)]", "phase"),
    ("csharp live phase bound", CS, r"public void SetPhase\(Widget image, Signal s\)", "SetPhase"),
    ("csharp template phase field", CS, r"public void SetPhase\(Node n, Field<ImagePhase> f, uint level = 0\)", "SetPhase"),
    ("csharp conditional write", CSR, r"public bool PatchIf<G>\(Tx tx, object key, Field<G> guard, G expected,", "PatchIf"),
    ("csharp on_needed", CS, r"public void OnNeeded\(Node image, Action<Tx, List<object>> handler\)", "OnNeeded"),
    ("csharp on_released", CS, r"public void OnReleased\(Node image, Action<Tx, List<object>> handler\)", "OnReleased"),
    ("csharp helper", CSI, r"sealed class RowImages<T>", "RowImages"),
    ("csharp default fetch", CSI, r"public static async Task<byte\[\]> HttpFetch\(string url, CancellationToken token\)", "HttpFetch"),
    ("csharp default fetch user agent", CSI, r'public static async Task<byte\[\]> HttpFetch\(string url, CancellationToken token\)(?:\n[^\n]*){0,3}?\n[^\n]*request\.Headers\.UserAgent\.ParseAdd\("kaya/" \+ KayaWire\.Version\)', "UserAgent"),

    ("java phase type", JV, r"public enum ImagePhase \{", "ImagePhase"),
    ("java live phase", JV, r"public Widget phase\(ImagePhase phase\)", "phase"),
    ("java live phase bound", JV, r"public Widget phase\(Signal<ImagePhase> s\)", "phase"),
    ("java template phase field", JV, r"public void setPhase\(Node n, KayaRecords\.Field<ImagePhase> f\)", "setPhase"),
    ("java conditional write", JVR, r"public <V> PatchIf<K, T> patchIf\(KayaApp\.Tx tx, K key,", "patchIf"),
    ("java on_needed", JV, r"public void onNeeded\(Node image, BiConsumer<Tx, List<Object>> handler\)", "onNeeded"),
    ("java on_released", JV, r"public void onReleased\(Node image, BiConsumer<Tx, List<Object>> handler\)", "onReleased"),
    ("java helper", JVR, r"public static final class RowImages<K, T> implements ImageFeed", "RowImages"),
    ("java default fetch", JVR, r"public static Fetch http\(\)", "http"),
    ("java default fetch user agent", JVR, r'public static Fetch http\(\) \{(?:\n[^\n]*){0,12}?\n[^\n]*c\.setRequestProperty\("User-Agent", "kaya/" \+ KayaWire\.VERSION\)', "User-Agent"),

    ("swift phase type", SWI, r"public enum KayaImagePhase: Int64, Sendable", "KayaImagePhase"),
    ("swift live phase", SW, r"public func image\(\s*_ source: Data\? = nil[^)]*phase: KayaImagePhase\? = nil\s*\) -> KayaWidget", "phase"),
    ("swift live phase bound", SWI, r"public func setPhase\(_ w: KayaWidget, _ s: KayaSignal\)", "setPhase"),
    ("swift template phase", SW, r"public func image\(\s*_ f: KayaField<Data>, fit: KayaFit\? = nil, phase: KayaField<KayaImagePhase>\? = nil", "phase"),
    ("swift conditional write", SWI, r"public func patchIf<G>\(", "patchIf"),
    ("swift on_needed", SWI, r"public func onNeeded\(\s*_ image: KayaNodeHandle, _ handler: @escaping", "onNeeded"),
    ("swift on_released", SWI, r"public func onReleased\(\s*_ image: KayaNodeHandle, _ handler: @escaping", "onReleased"),
    ("swift helper", SWI, r"public final class KayaRowImages<T: KayaRecord>", "KayaRowImages"),
    ("swift default fetch", SWI, r"public let kayaURLSessionFetch: KayaImageFetch", "kayaURLSessionFetch"),
    ("swift default fetch user agent", SWI, r'public let kayaURLSessionFetch: KayaImageFetch = \{ url in(?:\n[^\n]*){0,3}?\n[^\n]*request\.setValue\("kaya/\\\(kayaVersion\)", forHTTPHeaderField: "User-Agent"\)', "User-Agent"),

    ("ocaml phase type", ML, r"^module Image_phase : sig\n  type t = Shown \| Loading \| Failed", "Image_phase"),
    ("ocaml live phase", ML, r"^val image :[^\n]*(?:\n  [^\n]*)*?\?phase:Image_phase\.t ->", "phase"),
    ("ocaml template phase field", ML, r"\?phase_field:\('e, Image_phase\.t\) field ->", "phase_field"),
    ("ocaml conditional write", ML, r"^val patch_if :\n  'a record_collection -> key -> guard:\('b, 'v\) field -> equals:'v -> change list -> unit", "patch_if"),
    ("ocaml on_needed", ML, r"\?on_needed:\(key list -> unit\) ->", "on_needed"),
    ("ocaml on_released", ML, r"\?on_released:\(key list -> unit\) ->", "on_released"),
    ("ocaml helper", ML, r"^module Row_images : sig", "Row_images"),

    ("haskell phase type", HSC, r"^data ImagePhase = PhaseShown \| PhaseLoading \| PhaseFailed", "ImagePhase"),
    ("haskell live phase", HS, r"^  Phase :: ImagePhase -> Attr 'LeafW", "Phase"),
    ("haskell live phase bound", HS, r"^  PhaseBound :: Signal ImagePhase -> Attr 'LeafW", "PhaseBound"),
    ("haskell template phase field", HS, r"^  TplPhaseField :: KField ImagePhase -> TplAttr", "TplPhaseField"),
    ("haskell conditional write", HSC, r"^patchIf ::\n  forall v a\. KayaFieldType v =>", "patchIf"),
    ("haskell on_needed", HS, r"^onNeeded :: App -> Node -> \(\[Key\] -> IO \(\)\) -> IO \(\)", "onNeeded"),
    ("haskell on_released", HS, r"^onReleased :: App -> Node -> \(\[Key\] -> IO \(\)\) -> IO \(\)", "onReleased"),
    ("haskell helper", HS, r"^rowImages ::", "rowImages"),
]
FLOOR = 70
LANGS = ("rust", "python", "js", "go", "csharp", "java", "swift", "ocaml", "haskell")
FAKE = "kayaFakeNetimage"


def findings(texts, rows=ROWS):
    if len(rows) < FLOOR:
        return [f"network image census read fewer than {FLOOR} surfaces"]
    out = [f"network image {label} absent in {rel}"
           for label, rel, pattern, _token in rows if not re.search(pattern, texts[rel], re.M)]
    for lang in LANGS:
        mine = [label[len(lang) + 1:] for label, *_ in rows if label.startswith(lang + " ")]
        for part in ("phase", "conditional write", "on_needed", "on_released", "helper"):
            if not any(part in label for label in mine):
                out.append(f"network image census holds no {part} row for {lang}")
        if any(label == "default fetch" for label in mine) and "default fetch user agent" not in mine:
            out.append(f"network image census holds no default fetch user agent row for {lang}")
    return out


def run():
    """Answers its status, as timecode_surface does (docs/traps.md)."""
    gate = Gate("check-netimage-surface")
    texts = {rel: (ROOT / rel).read_text(encoding="utf-8") for _, rel, _, _ in ROWS}
    baseline = findings(texts)
    for problem in baseline:
        gate.finding(problem)
    if baseline:
        print("check-netimage-surface: FINDINGS ABOVE")
        return gate.status
    fake_rows = [(label, rel, pattern.replace(re.escape(token), FAKE).replace(token, FAKE), token)
                 for label, rel, pattern, token in ROWS]
    fired = sum(1 for line in findings(texts, fake_rows) if " absent in " in line)
    print(f"check-netimage-surface: fake names fired {fired}/{len(ROWS)}")
    if fired != len(ROWS):
        gate.finding(f"check-netimage-surface: {len(ROWS) - fired} fake-name rows still matched — a pattern "
                  f"that does not depend on its own name holds nothing")
    for label, rel, pattern, token in ROWS:
        count = len(re.findall(pattern, texts[rel], re.M))
        broken = gate.doctor(label, texts[rel], pattern,
                             lambda m, token=token: m.group(0).replace(token, "kayaCut"),
                             want=count, flags=re.M)
        gate.negative(label, lambda rel=rel, broken=broken: findings({**texts, rel: broken}),
                      want=f"network image {label} absent")
    gate.negative("empty reader", lambda: findings(texts, []), want=f"fewer than {FLOOR}")
    withheld = [row for row in ROWS if row[0] != "go helper"]
    gate.negative("a binding's row withheld", lambda: findings(texts, withheld), want="no helper row for go")
    no_ua = [row for row in ROWS if row[0] != "swift default fetch user agent"]
    gate.negative("a binding's user agent row withheld", lambda: findings(texts, no_ua),
                  want="no default fetch user agent row for swift")
    gate.negatives_ran(len(ROWS) + 3)
    if gate.status == 0:
        print(f"check-netimage-surface: OK ({len(ROWS)} network image surfaces in nine bindings)")
    return gate.status
