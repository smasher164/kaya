"""docs/network-images-plan.md N4, N5, N9, N10, N13, N15: the Compose arm's
doors, loaded by tools/lib/netimage_routes.py (run from tools/check-verbs.py).

A decode moved back into the apply arm draws the same pictures, a late result
installed without its generation passes every scene that never races two
sources, a cache keyed off the content passes until two albums collide, a
look that announces a label-less image is heard by no scene, a literal fill or
a spinner is drawn by no read, and a phase read off the prop agrees with every
write."""

import re

from content_type_routes import flat
from reveal_routes import blocks

REL = "android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt"
LABEL = "the Compose arm"

# (label, opener, what the block must hold, what it may never name)
DOORS = [
    ("source arm", "PROP_SOURCE -> {",
     ["node.imageData = blobs[handle]", "node.imageContentId = ids[handle] ?: 0L", "node.imageGen += 1"],
     ["kayaDecodePicture", "decodeByteArray", "ImageDecoder"]),
    ("door", "internal fun KayaPictureDoor(node: KayaNode) {",
     ["val gen = node.imageGen", "LaunchedEffect(node.id, node.imageContentId, gen,", "kayaServePicture(node, gen, density)"],
     []),
    ("off-main decode", "internal suspend fun kayaServePicture(node: KayaNode, gen: Int, density: Float) {",
     ["KayaPictureCache.get(KayaPictureCache.Key(id, pixels))",
      "withContext(Dispatchers.Default) {",
      "kayaDecodePicture(data) { w, h -> kayaPictureTarget(w, h, wide, tall, fit, density) }",
      "if (node.imageGen != gen) return",
      "KayaPictureCache.put(KayaPictureCache.Key(id, picture.pixels), picture)",
      "kayaInstallPicture(node, picture, undecodable = picture == null)"], []),
    ("header read", "internal fun kayaHeaderNatural(data: ByteArray): IntArray? {",
     ["inJustDecodeBounds = true"], ["ImageDecoder", "inSampleSize", "asImageBitmap"]),
    ("decode", "internal fun kayaDecodePicture(",
     ["ImageDecoder.decodeBitmap(", "wide = info.size.width", "decoder.setTargetSize(",
      "inJustDecodeBounds = true", "inSampleSize = sample"], ["node."]),
    ("decoded cache", "internal object KayaPictureCache {",
     ["data class Key(val id: Long, val pixels: Int)",
      "override fun sizeOf(key: Key, value: KayaPicture) = value.cost",
      "2 * screen.widthPixels * screen.heightPixels * 4", "entries.evictAll()", "kayaEncodedBytes.evictAll()"], []),
    ("memory watch", "internal fun kayaWatchMemory(context: Context) {",
     ["context.registerComponentCallbacks(",
      "if (running || level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND) KayaPictureCache.empty()",
      "override fun onLowMemory() = KayaPictureCache.empty()"], []),
    ("pump", "private fun collectBlobs(): Pair<Map<Long, ByteArray>, Map<Long, Long>> {",
     ["val id = KayaPresent.blobContentId(handle)", "val held = if (id != 0L) kayaEncodedBytes.get(id) else null",
      "if (held != null) {", "if (id != 0L) kayaEncodedBytes.put(id, it)"], []),
    ("boxed image", "internal fun KayaImageBox(node: KayaNode, a11yTag: Modifier, label: String) {",
     ["if (node.phase == KayaCompose.IMAGE_PHASE_FAILED || (picture == null && node.imageFailed)) {",
      "KayaCompose.symbolIcon(KayaCompose.SYMBOL_IMAGE_MISSING)!!,",
      "tint = MaterialTheme.colorScheme.onSurfaceVariant",
      "minOf(node.maxWidth, node.maxHeight) >= 2 * KAYA_FAILED_GLYPH",
      "node.imageGlyphs += 1", 'KayaImageMounted(node, "shown")',
      "} else if (node.phase == KayaCompose.IMAGE_PHASE_LOADING || node.imagePending) {",
      'KayaImageLook(node, "loading", box, label) {}'],
     ["Icons.", "ProgressIndicator", "kayaDecodePicture"]),
    ("looks", "private fun KayaImageLook(",
     ["if (label.isEmpty()) Modifier else Modifier.semantics {", "role = Role.Image",
      ".background(MaterialTheme.colorScheme.surfaceVariant)", "KayaImageMounted(node, word)"],
     ["Color(", "ProgressIndicator", "animate", "Transition"]),
]
# The harness reads what the arm composed, never the image's state.
READS = [
    ("expect_image_phase's reader", "internal fun kayaImagePhaseRead(node: KayaNode): String {",
     ["node.imageMounts.filter { it.value > 0 }.keys", "node.imageGlyphs == 0"]),
    ("expect_image_phase on Compose", '"expect_image_phase" -> {',
     ["?.let { kayaImagePhaseRead(it) }"]),
]
MODEL = r"node\.phase\b|node\.picture\b|node\.imageFailed|node\.imagePending|node\.imageData|node\.imageSize|IMAGE_PHASE_"
CALLS = [
    ("the source arm reads the header's size (N9's 2026-10-13 amendment: an unboxed image laid out at 0x0 until its pixels land moves everything after it)",
     "node.pendingNatural = node.imageData?.let { kayaHeaderNatural(it) }"),
    ("an installed picture ends the reserved size", "node.imagePending = false\n node.pendingNatural = null"),
    ("an unboxed image takes the header's size while it decodes",
     "val natural = picture?.let { intArrayOf(it.naturalWidth, it.naturalHeight) } ?: node.pendingNatural"),
    ("the reserved size is laid out", "} else if (fit != null) {\n val room = with(LocalDensity.current) { Modifier.size(fit.width.toDp(), fit.height.toDp()) }"),
    ("the render arm goes through the door", "KayaPictureDoor(node)\n val picture = node.picture"),
    ("a boxed image takes its box in every phase",
     "if (kayaImageBoxed(node) && !node.bleed) {\n KayaImageBox(node, a11yTag, node.a11yLabel.ifEmpty { a11yFallback })"),
    ("a picture lays out at its natural size whatever its decode size",
     "override val intrinsicSize = Size(picture.naturalWidth.toFloat(), picture.naturalHeight.toFloat())"),
    ("the pump's content ids reach the apply",
     "val (blobs, ids) = collectBlobs()\n mainThread.post { apply(batch, blobs, ids) }"),
    ("a fit re-decides the decode", "node.fitDeclared = true\n node.imageGen += 1"),
    ("arm's memory watch is registered at mount", "kayaWatchMemory(activity.applicationContext)"),
    ("the phase prop is applied", "PROP_PHASE -> KayaSceneModel.nodes[id]!!.phase = readI64(b)"),
    ("the picture is composition state", "var picture by mutableStateOf<KayaPicture?>(null)"),
    ("the phase is composition state", "var phase by mutableLongStateOf(0L)"),
    ("an undecodable source is composition state", "var imageFailed by mutableStateOf(false)"),
    ("a decode in flight is composition state", "var imagePending by mutableStateOf(false)"),
    ("the generation is composition state", "var imageGen by mutableIntStateOf(0)"),
    ("the failed glyph's one spelling", 'Triple(SYMBOL_IMAGE_MISSING, "image_missing", Icons.Default.BrokenImage),'),
    ("a band is read only from a layout of the core's band (docs/traps.md, the Compose band read from a stale "
     "layout)",
     "val laid = rowTops.size\n if (laidOutFirst != bandStart || laid != bandCount) {\n KayaVTrace.note(\n"
     " \"window\",\n \"stale layout table=${node.id} laid=$laidOutFirst+$laid band=$bandStart+$bandCount: no report\",\n"
     " )\n return\n }\n val (first, count) = visibleRange(scroll)"),
    ("the table window's moves reach the verb trace",
     "KayaVTrace.note(\"window\", \"-> park table=${node.id} row=$row count=$count\")\n"
     " KayaPresent.windowMoved(node.id, row.toLong(), count.toLong())"),
]


def code(text):
    """The text with every `//` comment cut, so prose naming a call is not one."""
    return "\n".join(re.sub(r"//.*", "", line) for line in text.splitlines())


def findings(text):
    out = []
    src = code(text)
    for label, opener, needs, never in DOORS:
        found = blocks(src, opener)
        if len(found) != 1:
            out.append(f"netimage: {LABEL}'s {label} is defined {len(found)} times in {REL}, wanted once ({opener})")
            continue
        for need in needs:
            if flat(need) not in flat(found[0]):
                out.append(f"netimage: {LABEL}'s {label} lacks {need[:80]} — a decode on the main thread, a late "
                           f"picture installed, a cache that could paint the wrong bytes, or a look the user would "
                           f"not see")
        for name in never:
            if name in found[0]:
                out.append(f"netimage: {LABEL}'s {label} names {name}")
    decodes = len(re.findall(r"\bkayaDecodePicture\(", src))
    if decodes != 2:
        out.append(f"netimage: {LABEL}'s kayaDecodePicture appears {decodes} times, wanted its definition and the "
                   f"door's call — a second caller decodes outside the door")
    spelled = len(re.findall(r"\bIcons\.\w+\.BrokenImage\b", src))
    if spelled != 1:
        out.append(f"netimage: {LABEL} spells the failed glyph {spelled} times, wanted only SYMBOLS' row — "
                   f"a second spelling of the failed glyph")
    for label, opener, needs in READS:
        found = blocks(src, opener)
        if len(found) != 1:
            out.append(f"netimage: {LABEL}'s {label} is gone — {REL} lacks {opener}")
            continue
        for need in needs:
            if flat(need) not in flat(found[0]):
                out.append(f"netimage: {LABEL}'s {label} lacks {need}")
        if re.search(MODEL, found[0]):
            out.append(f"netimage: {LABEL}'s {label} reaches the image's state, so it could answer from what "
                       f"the app wrote instead of what the arm composed")
    for label, call in CALLS:
        if flat(call) not in flat(src):
            out.append(f"netimage: {LABEL}: {label} no longer holds — {REL} lacks {call.splitlines()[0]}")
    return out


CUTS = [
    ("Compose: a band read off a layout of another band",
     r"if \(laidOutFirst != bandStart \|\| laid != bandCount\) \{", "if (false) {",
     "a band is read only from a layout of the core's band"),
    ("Compose: the stale read reported anyway", r"(: no report\",\n\s+\)\n)(\s+)return\n", r"\1\2Unit\n",
     "a band is read only from a layout of the core's band"),
    ("Compose: no header read before the decode",
     r"node\.pendingNatural = node\.imageData\?\.let \{ kayaHeaderNatural\(it\) \}", "node.pendingNatural = null",
     "the source arm reads the header's size"),
    ("Compose: the reserved size never laid out", r"\} else if \(fit != null\) \{", "} else if (false) {",
     "the reserved size is laid out"),
    ("Compose: the decode back in the apply arm",
     r"node\.imageContentId = ids\[handle\] \?: 0L\n",
     "node.imageContentId = ids[handle] ?: 0L\n"
     "node.picture = node.imageData?.let { kayaDecodePicture(it) { w, _ -> w } }\n",
     "arm's source arm names kayaDecodePicture"),
    ("Compose: the door's effect not keyed on its node",
     r"LaunchedEffect\(node\.id, node\.imageContentId, gen,", "LaunchedEffect(node.imageContentId, gen,",
     "arm's door lacks LaunchedEffect(node.id"),
    ("Compose: the decode on the main thread", r"withContext\(Dispatchers\.Default\) \{", "run {",
     "arm's off-main decode lacks withContext(Dispatchers.Default)"),
    ("Compose: the late picture installed", r"\n\s+if \(node\.imageGen != gen\) return", "",
     "arm's off-main decode lacks if (node.imageGen != gen) return"),
    ("Compose: the generation never moved",
     r"node\.imageContentId = ids\[handle\] \?: 0L\n\s+node\.imageGen \+= 1",
     "node.imageContentId = ids[handle] ?: 0L", "arm's source arm lacks node.imageGen += 1"),
    ("Compose: the cache keyed off the content",
     r"KayaPictureCache\.put\(KayaPictureCache\.Key\(id, picture\.pixels\)",
     "KayaPictureCache.put(KayaPictureCache.Key(0L, picture.pixels)",
     "arm's off-main decode lacks KayaPictureCache.put"),
    ("Compose: the cache key without its size", r"data class Key\(val id: Long, val pixels: Int\)",
     "data class Key(val id: Long)", "arm's decoded cache lacks data class Key"),
    ("Compose: the decode at full size", r"if \(pixels < long\) \{\n(\s+)decoder\.setTargetSize\(",
     r"if (false) {\n\1decoder.toString(", "arm's decode lacks decoder.setTargetSize("),
    ("Compose: the cache kept under pressure",
     r"if \(running \|\| level >= ComponentCallbacks2\.TRIM_MEMORY_BACKGROUND\) KayaPictureCache\.empty\(\)",
     "if (running) Unit", "arm's memory watch lacks if (running || level"),
    ("Compose: the pump copying every blob",
     r"val held = if \(id != 0L\) kayaEncodedBytes\.get\(id\) else null", "val held: ByteArray? = null",
     "arm's pump lacks val held"),
    ("Compose: undecodable bytes drawn empty",
     r"if \(node\.phase == KayaCompose\.IMAGE_PHASE_FAILED \|\| \(picture == null && node\.imageFailed\)\) \{",
     "if (node.phase == KayaCompose.IMAGE_PHASE_FAILED) {", "arm's boxed image lacks if (node.phase"),
    ("Compose: the failed look with another glyph",
     r"KayaCompose\.symbolIcon\(KayaCompose\.SYMBOL_IMAGE_MISSING\)!!,", "Icons.Default.Close,",
     "arm's boxed image names Icons."),
    ("Compose: the failed glyph spelled twice",
     r"KayaCompose\.symbolIcon\(KayaCompose\.SYMBOL_IMAGE_MISSING\)!!,", "Icons.Default.BrokenImage,",
     "spells the failed glyph 2 times"),
    ("Compose: the glyph drawn in any box",
     r"if \(minOf\(node\.maxWidth, node\.maxHeight\) >= 2 \* KAYA_FAILED_GLYPH\) \{\n(\s+)Icon\(",
     r"if (true) {\n\1Icon(", "arm's boxed image lacks minOf(node.maxWidth"),
    ("Compose: a label-less look announced",
     r"if \(label\.isEmpty\(\)\) Modifier else Modifier\.semantics \{", "Modifier.semantics {",
     "arm's looks lacks if (label.isEmpty())"),
    ("Compose: a literal fill colour", r"\.background\(MaterialTheme\.colorScheme\.surfaceVariant\)",
     ".background(Color(0xFFDDDDDD))", "arm's looks lacks .background(MaterialTheme"),
    ("Compose: a spinner in the loading look",
     r'KayaImageLook\(node, "loading", box, label\) \{\}',
     'KayaImageLook(node, "loading", box, label) { CircularProgressIndicator() }',
     "arm's boxed image lacks KayaImageLook(node, \"loading\""),
    ("Compose: the phase read off the prop",
     r"(internal fun kayaImagePhaseRead\(node: KayaNode\): String \{\n)",
     r'\1    if (node.phase == KayaCompose.IMAGE_PHASE_LOADING) return "loading"\n',
     "reaches the image's state"),
    ("Compose: the harness reading something else", r"\?\.let \{ kayaImagePhaseRead\(it\) \}",
     '?.let { "shown" }', "expect_image_phase on Compose lacks"),
    ("Compose: the phase a plain field", r"var phase by mutableLongStateOf\(0L\)", "var phase = 0L",
     "the phase is composition state"),
    ("Compose: the picture a plain field", r"var picture by mutableStateOf<KayaPicture\?>\(null\)",
     "var picture: KayaPicture? = null", "the picture is composition state"),
    ("Compose: a picture laid out at its decode size",
     r"override val intrinsicSize = Size\(picture\.naturalWidth\.toFloat\(\), picture\.naturalHeight\.toFloat\(\)\)",
     "override val intrinsicSize = picture.bitmap.let { Size(it.width.toFloat(), it.height.toFloat()) }",
     "a picture lays out at its natural size"),
]
