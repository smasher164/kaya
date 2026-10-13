"""docs/network-images-plan.md N4, N8, N9, N10, N13, N15: the network images
arm's doors, held where no scene can see them go.

netimage.steps reads what each image drew and the size it decoded to, so an
arm that drew the wrong look is red on its lane. But a decode moved back into
the apply arm draws the same pictures (only later frames stutter), a decode
whose late result is installed without its generation passes every scene that
never races two sources, a cache keyed on anything but the bytes' content and
the decode size passes until two albums collide, and a phase read off the prop
agrees with every write. A backend whose `depth_stub("netimage")` goes must
take a row in BACKENDS."""

import importlib
import re

from content_type_routes import flat
from kaya_gate import ROOT
from reveal_routes import blocks

HARNESS = "crates/kaya/src/harness.rs"
SCENE = "crates/kaya/src/scene.rs"
CAPI = "crates/kaya/src/capi.rs"
SWIFT = "swift/KayaSwiftUI.swift"
GTK = "crates/kaya/src/gtk.rs"
WINUI = "crates/kaya/src/winui/mod.rs"
COMPOSE = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
STUBBED = {GTK: 'depth_stub("netimage")', WINUI: 'depth_stub("netimage")', COMPOSE: 'depthStub("netimage")'}
BACKENDS = {SWIFT: "the SwiftUI arm"}
# One module per widget backend's arm, each exporting REL, LABEL,
# findings(text) -> [str] and CUTS [(label, pattern, replacement, want)].
ARM_MODULES = {GTK: "netimage_gtk", WINUI: "netimage_winui", COMPOSE: "netimage_compose"}


def arm_modules():
    return {rel: importlib.import_module(name) for rel, name in ARM_MODULES.items()
            if (ROOT / "tools/lib" / f"{name}.py").exists()}
MODEL = r"node\.phase\b|node\.image\b|node\.imageFailed|node\.imagePending|node\.imageData"
# (label, opener, what the block must hold, what it may never name)
DOORS = [
    ("the source arm", "case (propSource, valueBlob):",
     ["node.imageData = blobs[handle]", "node.imageContentId = kayaBlobIds[handle] ?? 0", "kayaRequestPicture(node)"],
     ["kayaDecodePicture", "kayaDecodeImage", "KayaPlatformImage(data"]),
    ("the request", "func kayaRequestPicture(_ node: KayaNode) {",
     ["guard !node.imageRequested else { return }", "DispatchQueue.main.async {"], ["kayaDecodePicture"]),
    ("the off-main door", "func kayaServePicture(_ node: KayaNode) {",
     ["node.imageGen &+= 1", "let gen = node.imageGen",
      ".init(id: id, pixels: min(long, max(1, kayaPictureTarget(natural, wide, tall, fit, scale)))))",
      "kayaDecodeQueue.async {", "kayaDecodePicture(data) { kayaPictureTarget($0, wide, tall, fit, scale) }",
      "guard let node = kayaScene.nodes[nodeId], node.imageGen == gen else { return }",
      "KayaPictureCache.shared.put(.init(id: id, pixels: picture.pixels), picture)",
      "kayaInstallPicture(node, picture, undecodable: picture == nil)", "kayaWatchMemoryPressure()"], []),
    ("the decode", "func kayaDecodePicture(",
     ["kCGImageSourceShouldCacheImmediately: true", "kCGImageSourceThumbnailMaxPixelSize: pixels",
      "CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)"], ["node."]),
    ("the memory watch", "func kayaWatchMemoryPressure() {",
     ["DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)",
      "source.setEventHandler { KayaPictureCache.shared.empty() }",
      "UIApplication.didReceiveMemoryWarningNotification", ") { _ in KayaPictureCache.shared.empty() }"], []),
    ("the cache's emptying", "func empty() {", ["entries.removeAll()", "kayaEncodedBytes.removeAllObjects()"], []),
    ("the pump", "private func kayaCollectBlobs() -> ([UInt64: Data], [UInt64: UInt64]) {",
     ["let id = KayaHost.blobContentId(handle)",
      "if id != 0, let held = kayaEncodedBytes.object(forKey: NSNumber(value: id)) {"], []),
    ("the boxed image", "private struct KayaImageBox: View {",
     ['if node.phase == imagePhaseFailed || (node.image == nil && node.imageFailed) {',
      'Image(systemName: kayaSFSymbol(symbolImageMissing)!)', '.onAppear { node.imageGlyphs += 1 }',
      '.onAppear { kayaImageAppeared(node, "shown") }', 'KayaImageLook(node: node, word: "loading")'], []),
    ("the looks", "private struct KayaImageLook<Glyph: View>: View {",
     [".onAppear { kayaImageAppeared(node, word) }", ".onDisappear { kayaImageGone(node, word) }",
      "look.accessibilityHidden(true)", ".fill(.quaternary)", ".fill(Color(uiColor: .quaternarySystemFill))"], []),
]
# The harness reads (label, opener, what it must hold): never the model.
READS = [
    ("expect_image_phase's reader", "func kayaImagePhaseRead(_ node: KayaNode) -> String {",
     ["node.imageMounts.filter { $0.value > 0 }.keys", "node.imageGlyphs == 0"]),
    ("expect_image_phase on SwiftUI", 'case "expect_image_phase":', ["kayaImagePhaseRead($0)"]),
]
CALLS = [
    (SWIFT, "the boxed image takes its box in every phase", "} else if kayaImageBoxed(node) {\n KayaImageBox(node: node)"),
    (SWIFT, "the box's frame is the harness's drawn box", "KayaImageBox(node: node)\n .background(KayaLabelFrameReader(id: node.id))"),
    (SWIFT, "a box change re-requests the decode",
     "if kayaScene.nodes[id]!.kind == kindImage {\n kayaScene.nodes[id]!.fitDeclared = true\n kayaRequestPicture(kayaScene.nodes[id]!)"),
    (SWIFT, "the pump's content ids reach the apply", "kayaBlobIds = ids\n kayaApply(batch, blobs)"),
    (SWIFT, "a mac table's scroll to a row stops where the clip can",
     "clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: kayaClipTop(clip, rect.minY)))"),
    (SWIFT, "a mac table's re-park stops where the clip can",
     "let want = kayaClipTop(clip, tableView.rect(ofRow: anchor).minY)"),
    (HARNESS, "harness.rs reads what the backend drew", "let got = stage.image_phase(*t);"),
    (SCENE, "a batch's stamps and teardowns are N8's", "self.settle_video_views(&out);\n self.settle_image_needs(&out);"),
    (SCENE, "a band report decides a seeded site's rows", "self.settle_image_needs(&out);\n self.need_images_on(&site);"),
    (SCENE, "a seeded row waits for the first report", "} else if !row.has_source && !seeded && self.images_needed.insert(row.addr.clone()) {"),
    (SCENE, "the guarded write lowers at the loop's head",
     "if let TxOp::CollectionPatchIf { id, path, key, variant, guard_field, guard, changes } = op {"),
    (SCENE, "an unchanged blob is not sent again", "if same_blob(&before[field as usize], &value) {\n continue;"),
    (SCENE, "N3 holds the live zone", "if let Some(why) = self.image_boxes.get(&id).and_then(|b| b.refusal(&format!(\"image {id:?}\"))) {"),
    (CAPI, "a band move's asks are sent", "let asks = scene.take_asks();\n drop(scene_slot);\n send_occurrences(asks);\n answer"),
    (CAPI, "every batch's blobs carry their content ids", "let ids = out.iter().map(crate::content_id::of).collect();"),
]


def arms(text, opener):
    """A Swift `case` arm has no braces of its own: its body runs to the next
    `case (`, `case .` or `default:` at any depth."""
    out = []
    at = text.find(opener)
    while at >= 0:
        rest = text[at + len(opener):]
        end = re.search(r"\n\s*(case [(.]|default:)", rest)
        out.append(rest[: end.start() if end else len(rest)])
        at = text.find(opener, at + 1)
    return out


def findings(sources, backends=None):
    arms_held = arm_modules()
    backends = {**BACKENDS, **{rel: m.LABEL for rel, m in arms_held.items()}} if backends is None else backends
    out = []
    for rel, mod in arms_held.items():
        if rel in backends:
            out.extend(mod.findings(sources[rel]))
    swift = sources[SWIFT]
    for label, opener, needs, never in DOORS:
        found = (arms if opener.startswith("case ") else blocks)(swift, opener)
        if len(found) != 1:
            out.append(f"netimage: {label} is defined {len(found)} times in {SWIFT}, wanted once ({opener})")
            continue
        for need in needs:
            if flat(need) not in flat(found[0]):
                out.append(f"netimage: {label} lacks {need[:80]} — a decode on the main thread, a late "
                           f"picture installed, or a cache that could paint the wrong bytes")
        for name in never:
            if name in found[0]:
                out.append(f"netimage: {label} names {name} — the decode left its one off-main door")
    decodes = len(re.findall(r"\bkayaDecodePicture\(", swift))
    if decodes != 3:
        out.append(f"netimage: kayaDecodePicture appears {decodes} times, wanted its definition, the door "
                   f"and the probe's synchronous decode — a second caller decodes outside the door")
    for label, opener, needs in READS:
        found = blocks(swift, opener)
        if len(found) != 1:
            out.append(f"netimage: {label} is gone — {SWIFT} lacks {opener}")
            continue
        for need in needs:
            if flat(need) not in flat(found[0]):
                out.append(f"netimage: {label} lacks {need}")
        if re.search(MODEL, found[0]):
            out.append(f"netimage: {label} reaches kaya's model, so it could answer from what the app wrote "
                       f"instead of what the arm drew")
    for rel, label, call in CALLS:
        if flat(call) not in flat(sources[rel]):
            out.append(f"netimage: {label} no longer holds — {rel} lacks {call.splitlines()[0]}")
    for rel, stub in STUBBED.items():
        if stub not in sources[rel] and rel not in backends:
            out.append(f"netimage: {rel} no longer stubs network images and has no row in "
                       f"tools/lib/netimage_routes.py's BACKENDS")
    return out


def run(g):
    sources = {rel: (ROOT / rel).read_text(encoding="utf-8") for rel in [HARNESS, SCENE, CAPI, SWIFT, *STUBBED]}
    still = [rel for rel, stub in STUBBED.items() if stub in sources[rel]]
    g.counted("netimage clauses held",
              sum(len(n) + len(v) + 1 for *_, n, v in DOORS) + 1 + sum(len(n) + 2 for *_, n in READS) + len(CALLS),
              floor=50)
    g.counted("netimage backends still stubbed", len(still), floor=0)
    for line in findings(sources):
        g.finding(line)
    cuts = [
        ("the decode back in the apply arm", SWIFT,
         r"node\.imageContentId = kayaBlobIds\[handle\] \?\? 0\n(\s+)kayaRequestPicture\(node\)",
         r"node.imageContentId = kayaBlobIds[handle] ?? 0\n\1kayaDecodeImage(node.imageData, into: node)",
         "the source arm lacks kayaRequestPicture(node)"),
        ("the late picture installed", SWIFT,
         r"guard let node = kayaScene\.nodes\[nodeId\], node\.imageGen == gen else \{ return \}",
         "guard let node = kayaScene.nodes[nodeId] else { return }", "the off-main door lacks guard let node"),
        ("the generation never moved", SWIFT, r"\n(\s+)node\.imageGen &\+= 1\n", "\n",
         "the off-main door lacks node.imageGen &+= 1"),
        ("the decode on the main queue", SWIFT, r"kayaDecodeQueue\.async \{\n(\s+)let picture",
         r"DispatchQueue.main.async {\n\1let picture", "the off-main door lacks kayaDecodeQueue.async"),
        ("the cache keyed off the content", SWIFT, r"put\(\.init\(id: id, pixels: picture\.pixels\), picture\)",
         "put(.init(id: 0, pixels: picture.pixels), picture)", "the off-main door lacks KayaPictureCache.shared.put"),
        ("the decode at full size", SWIFT, r"kCGImageSourceThumbnailMaxPixelSize: pixels", "kCGImageSourceThumbnailMaxPixelSize: long",
         "the decode lacks kCGImageSourceThumbnailMaxPixelSize: pixels"),
        ("a decode left lazy", SWIFT, r"kCGImageSourceShouldCacheImmediately: true", "kCGImageSourceShouldCacheImmediately: false",
         "the decode lacks kCGImageSourceShouldCacheImmediately: true"),
        ("the cache kept under pressure", SWIFT, r"source\.setEventHandler \{ KayaPictureCache\.shared\.empty\(\) \}",
         "source.setEventHandler { }", "the memory watch"),
        ("the pump copying every blob", SWIFT,
         r"if id != 0, let held = kayaEncodedBytes\.object\(forKey: NSNumber\(value: id\)\) \{",
         "if false, let held = kayaEncodedBytes.object(forKey: NSNumber(value: id)) {",
         "the pump lacks if id != 0, let held"),
        ("undecodable bytes drawn empty", SWIFT,
         r"if node\.phase == imagePhaseFailed \|\| \(node\.image == nil && node\.imageFailed\) \{",
         "if node.phase == imagePhaseFailed {", "the boxed image lacks if node.phase == imagePhaseFailed ||"),
        ("the failed look without its glyph", SWIFT, r'Image\(systemName: kayaSFSymbol\(symbolImageMissing\)!\)',
         'Image(systemName: "")', 'the boxed image lacks Image(systemName: kayaSFSymbol(symbolImageMissing)!)'),
        ("a label-less look announced", SWIFT, r"look\.accessibilityHidden\(true\)", "look",
         "the looks lacks look.accessibilityHidden(true)"),
        ("the phase read off the prop", SWIFT,
         r"(func kayaImagePhaseRead\(_ node: KayaNode\) -> String \{\n)",
         r'\1    if node.phase == imagePhaseLoading { return "loading" }\n', "reaches kaya's model"),
        ("a second decode site", SWIFT, r"(func kayaInstallPicture\()",
         r"func kayaStrayDecode(_ d: Data) { _ = kayaDecodePicture(d) { _ in nil } }\n\n\1",
         "kayaDecodePicture appears 4 times"),
        ("harness.rs reading the model", HARNESS, r"let got = stage\.image_phase\(\*t\);",
         'let got = String::from("shown");', "harness.rs reads what the backend drew"),
        ("a band move's asks left queued", CAPI,
         r"let asks = scene\.take_asks\(\);\n(\s+)drop\(scene_slot\);\n(\s+)send_occurrences\(asks\);\n(\s+)answer",
         r"\3answer", "a band move's asks are sent"),
        ("a mac table scrolled past its end", SWIFT,
         r"y: kayaClipTop\(clip, rect\.minY\)\)\)", "y: rect.minY))",
         "a mac table's scroll to a row stops where the clip can"),
        ("the seed's rows needed before any report", SCENE, r"!row\.has_source && !seeded &&", "!row.has_source &&",
         "a seeded row waits for the first report"),
    ]
    for rel, mod in arm_modules().items():
        cuts.extend((label, rel, pattern, repl, want) for label, pattern, repl, want in mod.CUTS)
    for label, rel, pattern, repl, want in cuts:
        broken = g.doctor(f"netimage: {label}", sources[rel], pattern, repl)
        g.negative(f"netimage: {label}", lambda rel=rel, broken=broken: findings({**sources, rel: broken}),
                   want=want)
    for rel in [rel for rel in STUBBED if rel not in still]:
        g.negative(f"netimage: {rel}'s row withheld", lambda: findings(sources, backends=BACKENDS),
                   want=f"{rel} no longer stubs")
    for rel in still:
        n = sources[rel].count(STUBBED[rel])
        broken = g.doctor(f"netimage: {rel}'s stubs gone without a row", sources[rel],
                          re.escape(STUBBED[rel]), "todo!()", want=n)
        g.negative(f"netimage: {rel}'s stubs gone without a row",
                   lambda rel=rel, broken=broken: findings({**sources, rel: broken}), want="no longer stubs")
