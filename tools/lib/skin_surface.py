"""docs/styling-pass-plan.md Y2-Y8, Y10; called by check-sugar-surface.

Each row is one skin surface in one binding, read out of that binding's own
file: the two grounds, an image's shape, a label's tint, `selected` and
`on_activate` and `on_select` in the live and template zones, the dock in the window
construct, the binding's dispatch of the `activated` and `selection_changed`
occurrences, the core's
dominant colour and palette, and the Tint `none`/`overlay` and Shape vocabularies. The
wire records reach every binding through the generator whether or not a
guest can spell a part, so only these rows see one missing."""

import re

from kaya_gate import ROOT, Gate

RS = "crates/kaya/src/app.rs"
RSD = "crates/kaya/src/dominant.rs"
PY = "bindings/python/kaya/__init__.py"
JS = "bindings/js/kaya/index.ts"
GO = "bindings/go/skin.go"
GOA = "bindings/go/app.go"
GOW = "bindings/go/kaya_wire.go"
CS = "bindings/csharp/KayaApp.cs"
CSK = "bindings/csharp/Kaya.cs"
JV = "bindings/java/dev/kaya/KayaApp.java"
SW = "bindings/swift/KayaApp.swift"
ML = "bindings/ocaml/kaya_app.mli"
MLI = "bindings/ocaml/kaya_app.ml"
HS = "bindings/haskell/KayaApp.hs"

# (label, file, pattern, the name inside it a rename cuts)
ROWS = [
    ("rust ground gradient", RS, r"pub fn ground_gradient\(self, color: impl Into<LiveSource<ColorKind>>\) -> Self", "ground_gradient"),
    ("rust ground image", RS, r"pub fn ground_image\(self, bytes: impl Into<LiveSource<BlobKind>>\) -> Self", "ground_image"),
    ("rust image shape", RS, r"pub fn shape\(self, shape: Shape\) -> Self", "shape"),
    ("rust label tint", RS, r"pub fn tint\(self, tint: impl Into<LiveSource<TintKind>>\) -> Self", "tint"),
    ("rust selected", RS, r"pub fn selected\(self, on: impl Into<LiveSource<BoolKind>>\) -> Self", "selected"),
    ("rust on_activate", RS, r"pub fn on_activate<M: Clone \+ 'static>\(self, msgs: &Messages<M>, msg: M\) -> Self", "on_activate"),
    ("rust template ground gradient", RS, r"pub fn ground_gradient\(&mut self, node: TemplateNodeId, src: impl Into<TplSource<ColorKind>>\)", "ground_gradient"),
    ("rust template ground image", RS, r"pub fn ground_image\(&mut self, node: TemplateNodeId, src: impl Into<TplSource<BlobKind>>\)", "ground_image"),
    ("rust template image shape", RS, r"pub fn shape\(&mut self, node: TemplateNodeId, shape: Shape\)", "shape"),
    ("rust template label tint", RS, r"pub fn tint\(&mut self, node: TemplateNodeId, src: impl Into<TplSource<TintKind>>\)", "tint"),
    ("rust template selected", RS, r"pub fn selected\(&mut self, node: TemplateNodeId, src: impl Into<TplSource<BoolKind>>\)", "selected"),
    ("rust template on_activate", RS, r"pub fn on_activate<M: 'static>\(\n\s+&mut self,\n\s+node: TemplateNodeId,", "on_activate"),
    ("rust dock", RS, r"pub fn dock<R>\(self, dock: WindowId, build: impl FnOnce\(&mut Tx<'_>\) -> \(WidgetId, R\)\) -> R", "dock"),
    ("rust activated dispatch", RS, r"Occurrence::Activated \{ \.\. \} => Some\(msg\.clone\(\)\),", "Activated"),
    ("rust on_select", RS, r"pub fn on_select<M: Clone \+ 'static>\(self, msgs: &Messages<M>, msg: M\) -> Self", "on_select"),
    ("rust template on_select", RS, r"pub fn on_select<M: 'static>\(\n\s+&mut self,\n\s+node: TemplateNodeId,", "on_select"),
    ("rust selection dispatch", RS, r"Occurrence::InstanceSelectionChanged \{ path, \.\. \} => Some\(f\(path\.clone\(\)\)\),", "InstanceSelectionChanged"),
    ("rust image_dominant", RSD, r"^pub fn image_dominant\(bytes: &\[u8\]\) -> Option<crate::Color>", "image_dominant"),
    ("rust image_palette", RSD, r"^pub fn image_palette\(bytes: &\[u8\], n: usize\) -> Option<Vec<PaletteColor>>", "image_palette"),
    ("rust tint none", RS, r"Tint::None => 0,", "None"),
    ("rust tint overlay", RS, r"Tint::Overlay => 6,", "Overlay"),
    ("rust shape vocabulary", RS, r"^pub enum Shape \{\n    Rect,\n    Rounded,\n    Circle,", "Shape"),

    ("python ground gradient", PY, r"^\s+ground_gradient: Color \| Source \| None = None,", "ground_gradient"),
    ("python ground image", PY, r"^\s+ground_image: bytes \| bytearray \| memoryview \| Asset \| Source \| None = None,", "ground_image"),
    ("python image shape", PY, r"^\s+shape: Shape \| str \| None = None\) -> Widget:", "shape"),
    ("python label tint", PY, r"tint: Tint \| str \| Source \| None = None\) -> Widget:", "tint"),
    ("python selected", PY, r"^\s+selected: FlagSource \| None = None,\n\s+on_activate", "selected"),
    ("python on_activate", PY, r"^\s+on_activate: Handler \| None = None,\n\s+on_select: Handler \| None = None\) -> _Container:", "on_activate"),
    ("python template ground gradient", PY, r"elif isinstance\(ground_gradient, FieldRef\):", "ground_gradient"),
    ("python template ground image", PY, r"elif isinstance\(ground_image, FieldRef\):", "ground_image"),
    ("python template image shape", PY, r"^def image\(source: [^)]*\bshape: Shape \| str \| None = None\)", "shape"),
    ("python template label tint", PY, r"_picker_field\(\"a label's tint\", tint, Tint\)", "tint"),
    ("python template selected", PY, r"^def _set_skin\([^)]*\bselected: FlagSource \| None,", "selected"),
    ("python template on_activate", PY, r"^def _set_skin\([^)]*\bon_activate: Handler \| None,", "on_activate"),
    ("python dock", PY, r"def dock\(self, dock_id: int, \*, window: int = 0\) -> _TxScope:", "dock"),
    ("python activated dispatch", PY, r"_app\._register\(handle, wire\.OCC_ACTIVATED, on_activate\)", "OCC_ACTIVATED"),
    ("python on_select", PY, r"^\s+on_activate: Handler \| None = None,\n\s+on_select: Handler \| None = None\) -> _Container:", "on_select"),
    ("python template on_select", PY, r"^def _set_skin\([^)]*\bon_select: Handler \| None\)", "on_select"),
    ("python selection dispatch", PY, r"_app\._register\(handle, wire\.OCC_SELECTION_CHANGED, on_select\)", "OCC_SELECTION_CHANGED"),
    ("python image_dominant", PY, r"^def image_dominant\(data: bytes \| bytearray \| memoryview \| Asset\) -> Color \| None:", "image_dominant"),
    ("python image_palette", PY, r"^def image_palette\(data: bytes \| bytearray \| memoryview \| Asset, n: int\) -> list\[PaletteColor\] \| None:", "image_palette"),
    ("python tint none", PY, r"^    NONE = wire\.TINT_NONE", "TINT_NONE"),
    ("python tint overlay", PY, r"^    OVERLAY = wire\.TINT_OVERLAY", "TINT_OVERLAY"),
    ("python shape vocabulary", PY, r"^class Shape\(enum\.IntEnum\):", "Shape"),

    ("js ground gradient", JS, r"^  groundGradient\?: Color \| Signal<Color> \| FieldRef;", "groundGradient"),
    ("js ground image", JS, r"^  groundImage\?: ImageSource;", "groundImage"),
    ("js image shape", JS, r"^\s+shape\?: ShapeValue \| ShapeName;", "shape"),
    ("js label tint", JS, r"^  tint\(tint: TintValue \| TintName\): this \{", "tint"),
    ("js selected", JS, r"^  selected\?: boolean \| Signal<boolean> \| FieldRef;", "selected"),
    ("js on_activate", JS, r"^export type SkinOptions = \{[^}]*\bonActivate\?: Handler;", "onActivate"),
    ("js template ground gradient", JS, r"^  groundGradient\?: Color \| Signal<Color> \| FieldRef;", "FieldRef"),
    ("js template ground image", JS, r"^export type ImageSource = [^\n]*FieldRef", "FieldRef"),
    ("js template image shape", JS, r"^export type ImageOptions = GrowOption &\s*BleedOption & \{[^}]*\bshape\?: ShapeValue \| ShapeName;", "shape"),
    ("js template label tint", JS, r"tint\?: TintValue \| TintName \| FieldRef \}", "tint"),
    ("js template selected", JS, r"^  selected\?: boolean \| Signal<boolean> \| FieldRef;", "FieldRef"),
    ("js template on_activate", JS, r"app\(\)\._register\(handle, wire\.OCC_ACTIVATED, opts\.onActivate\);", "onActivate"),
    ("js dock", JS, r"^  dock<T = void>\(dockId: number, optsOrBody: DockOptions \| \(\(\) => T\), body\?: \(\) => T\): T \{", "dock"),
    ("js activated dispatch", JS, r"app\(\)\._register\(handle, wire\.OCC_ACTIVATED,", "OCC_ACTIVATED"),
    ("js on_select", JS, r"^export type SkinOptions = \{[^}]*\bonSelect\?: Handler;", "onSelect"),
    ("js template on_select", JS, r"app\(\)\._register\(handle, wire\.OCC_SELECTION_CHANGED, opts\.onSelect\);", "onSelect"),
    ("js selection dispatch", JS, r"app\(\)\._register\(handle, wire\.OCC_SELECTION_CHANGED,", "OCC_SELECTION_CHANGED"),
    ("js image_dominant", JS, r"^export function imageDominant\(bytes: Uint8Array \| Asset\): Color \| null \{", "imageDominant"),
    ("js image_palette", JS, r"^export function imagePalette\(bytes: Uint8Array \| Asset, n: number\): PaletteColor\[\] \| null \{", "imagePalette"),
    ("js tint none", JS, r"^  NONE: wire\.TINT_NONE,", "TINT_NONE"),
    ("js tint overlay", JS, r"^  OVERLAY: wire\.TINT_OVERLAY,", "TINT_OVERLAY"),
    ("js shape vocabulary", JS, r"^export const Shape = Object\.freeze\(\{ RECT: wire\.SHAPE_RECT, ROUNDED: wire\.SHAPE_ROUNDED, CIRCLE: wire\.SHAPE_CIRCLE \}\);", "Shape"),

    ("go ground gradient", GO, r"^func \(w Widget\) GroundGradient\(color Color\) Widget \{", "GroundGradient"),
    ("go ground gradient bound", GO, r"^func \(w Widget\) BindGroundGradient\(s Signal\[Color\]\) Widget \{", "BindGroundGradient"),
    ("go ground image", GO, r"^func \(w Widget\) GroundImage\(source \[\]byte\) Widget \{", "GroundImage"),
    ("go image shape", GO, r"^func \(w Widget\) Shape\(shape Shape\) Widget \{", "Shape"),
    ("go label tint", GO, r"^func \(w Widget\) Tint\(tint Tint\) Widget \{", "Tint"),
    ("go selected", GO, r"^func \(w Widget\) Selected\(on bool\) Widget \{", "Selected"),
    ("go on_activate", GO, r"^func \(w Widget\) OnActivate\(fn func\(\*Tx\)\) Widget \{", "OnActivate"),
    ("go template ground gradient", GO, r"^func \(t \*Tpl\) BindGroundGradient\[S interface \{", "BindGroundGradient"),
    ("go template ground image", GO, r"^func \(t \*Tpl\) BindGroundImage\[S interface \{", "BindGroundImage"),
    ("go template image shape", GO, r"^func \(t \*Tpl\) SetShape\(n Node, shape Shape\)", "SetShape"),
    ("go template label tint", GO, r"^func \(t \*Tpl\) BindTint\[S interface \{", "BindTint"),
    ("go template selected", GO, r"^func \(t \*Tpl\) BindSelected\[S interface \{", "BindSelected"),
    ("go template on_activate", GO, r"^func \(n Node\) OnActivate\(fn func\(\*Tx, \[\]any\)\) Node \{", "OnActivate"),
    ("go dock", GO, r"^func \(w WindowRef\) Dock\(dock uint64, build func\(\) Widget\) WindowRef \{", "Dock"),
    ("go activated dispatch", GOA, r"case kind == occActivated:\n\s+if fn := a\.nodeActivates\[id\]; fn != nil \{", "nodeActivates"),
    ("go on_select", GO, r"^func \(w Widget\) OnSelect\(fn func\(\*Tx\)\) Widget \{", "OnSelect"),
    ("go template on_select", GO, r"^func \(n Node\) OnSelect\(fn func\(\*Tx, \[\]any\)\) Node \{", "OnSelect"),
    ("go selection dispatch", GOA, r"case kind == occSelectionChanged:\n\s+if fn := a\.nodeSelects\[id\]; fn != nil \{", "nodeSelects"),
    ("go image_dominant", GO, r"^func ImageDominant\(bytes \[\]byte\) \(Color, bool\) \{", "ImageDominant"),
    ("go image_palette", GO, r"^func ImagePalette\(bytes \[\]byte, n int\) \(\[\]PaletteColor, bool\) \{", "ImagePalette"),
    ("go tint none", GOW, r"^\tTintNone Tint = 0", "TintNone"),
    ("go tint overlay", GOW, r"^\tTintOverlay Tint = 6", "TintOverlay"),
    ("go shape vocabulary", GO, r"^type Shape int64", "Shape"),

    ("csharp ground gradient", CS, r"Tint\? filled = null, Color\? groundGradient = null,", "groundGradient"),
    ("csharp ground gradient bound", CS, r"public void SetGroundGradient\(Widget w, Signal s\)", "SetGroundGradient"),
    ("csharp ground image", CS, r"Color\? groundGradient = null, byte\[\]\? groundImage = null,", "groundImage"),
    ("csharp image shape", CS, r"ImagePhase\? phase = null, Shape\? shape = null\)", "shape"),
    ("csharp label tint", CS, r"Role\? role = null, bool rich = false, Tint\? tint = null\)", "tint"),
    ("csharp selected", CS, r"public void SetSelected\(Widget w, Signal s\)", "SetSelected"),
    ("csharp on_activate", CS, r"byte\[\]\? groundImage = null, Action<Tx>\? onActivate = null, Action<Tx>\? onSelect = null\)", "onActivate"),
    ("csharp on_select", CS, r"Action<Tx>\? onActivate = null, Action<Tx>\? onSelect = null\)", "onSelect"),
    ("csharp template ground gradient", CS, r"public void SetGroundGradient\(Node n, Field<Color> f, uint level = 0\)", "SetGroundGradient"),
    ("csharp template ground image", CS, r"public void SetGroundImage\(Node n, Field<byte\[\]> f, uint level = 0\)", "SetGroundImage"),
    ("csharp template image shape", CS, r"public void SetShape\(Node n, Shape shape\) =>", "SetShape"),
    ("csharp template label tint", CS, r"public void SetTint\(Node n, Field<Tint> f, uint level = 0\) =>", "SetTint"),
    ("csharp template selected", CS, r"public void SetSelected\(Node n, Field<bool> f, uint level = 0\) =>", "SetSelected"),
    ("csharp template on_activate", CS, r"public void OnActivate\(Node n, Action<Tx, List<object>> handler\)", "OnActivate"),
    ("csharp dock", CS, r"public T Dock<T>\(ulong dock, Func<\(Widget Root, T Value\)> body, ulong window = 0\)", "Dock"),
    ("csharp activated dispatch", CS, r"case Activated activeRow\n\s+when nodeActivates\.TryGetValue\(activeRow\.Id, out var onActivateRow\):", "nodeActivates"),
    ("csharp template on_select", CS, r"public void OnSelect\(Node n, Action<Tx, List<object>> handler\)", "OnSelect"),
    ("csharp selection dispatch", CS, r"case SelectionChanged pickRow\n\s+when nodeSelects\.TryGetValue\(pickRow\.Id, out var onSelectRow\):", "nodeSelects"),
    ("csharp image_dominant", CSK, r"public static Color\? ImageDominant\(byte\[\] bytes\) =>", "ImageDominant"),
    ("csharp image_palette", CSK, r"public static PaletteColor\[\]\? ImagePalette\(byte\[\] bytes, int n\)", "ImagePalette"),
    ("csharp tint none", CS, r"^    None = KayaWire\.TintNone,", "TintNone"),
    ("csharp tint overlay", CS, r"^    Overlay = KayaWire\.TintOverlay,", "TintOverlay"),
    ("csharp shape vocabulary", CS, r"^enum Shape : long\n\{\n    Rect = KayaWire\.ShapeRect,", "Shape"),

    ("java ground gradient", JV, r"public Widget groundGradient\(Color color\) \{", "groundGradient"),
    ("java ground gradient bound", JV, r"public Widget groundGradient\(Signal<Color> s\) \{", "groundGradient"),
    ("java ground image", JV, r"public Widget groundImage\(byte\[\] bytes\) \{", "groundImage"),
    ("java image shape", JV, r"public Widget shape\(Shape shape\) \{", "shape"),
    ("java label tint", JV, r"public Widget tint\(Signal<Tint> s\) \{", "tint"),
    ("java selected", JV, r"public Widget selected\(Signal<Boolean> s\) \{", "selected"),
    ("java on_activate", JV, r"public Widget onActivate\(Consumer<Tx> handler\) \{", "onActivate"),
    ("java template ground gradient", JV, r"public void setGroundGradient\(Node n, KayaRecords\.Field<Color> f\) \{", "setGroundGradient"),
    ("java template ground image", JV, r"public void setGroundImage\(Node n, KayaRecords\.Field<byte\[\]> f\) \{", "setGroundImage"),
    ("java template image shape", JV, r"public void setShape\(Node n, Shape shape\) \{", "setShape"),
    ("java template label tint", JV, r"public void setTint\(Node n, KayaRecords\.Field<Tint> f\) \{", "setTint"),
    ("java template selected", JV, r"public void setSelected\(Node n, KayaRecords\.Field<Boolean> f\) \{", "setSelected"),
    ("java template on_activate", JV, r"public void onActivate\(Node n, BiConsumer<Tx, List<Object>> handler\) \{", "onActivate"),
    ("java dock", JV, r"public <R> R dock\(long dock, java\.util\.function\.Supplier<Built<R>> body\) \{", "dock"),
    ("java activated dispatch", JV, r"\} else if \(occ\.kind == KayaWire\.OCC_KIND_ACTIVATED\) \{\n\s+BiConsumer<Tx, List<Object>> handler = nodeActivates\.get\(occ\.id\);", "nodeActivates"),
    ("java on_select", JV, r"public Widget onSelect\(Consumer<Tx> handler\) \{", "onSelect"),
    ("java template on_select", JV, r"public void onSelect\(Node n, BiConsumer<Tx, List<Object>> handler\) \{", "onSelect"),
    ("java selection dispatch", JV, r"\} else if \(occ\.kind == KayaWire\.OCC_KIND_SELECTION_CHANGED\) \{\n\s+BiConsumer<Tx, List<Object>> handler = nodeSelects\.get\(occ\.id\);", "nodeSelects"),
    ("java image_dominant", JV, r"public static java\.util\.Optional<Color> imageDominant\(byte\[\] bytes\) \{", "imageDominant"),
    ("java image_palette", JV, r"public static java\.util\.Optional<List<PaletteColor>> imagePalette\(byte\[\] bytes, int n\) \{", "imagePalette"),
    ("java tint none", JV, r"^        NONE\(KayaWire\.TINT_NONE\),", "TINT_NONE"),
    ("java tint overlay", JV, r"^        OVERLAY\(KayaWire\.TINT_OVERLAY\);", "TINT_OVERLAY"),
    ("java shape vocabulary", JV, r"public enum Shape \{\n\s+RECT\(KayaWire\.SHAPE_RECT\), ROUNDED\(KayaWire\.SHAPE_ROUNDED\), CIRCLE\(KayaWire\.SHAPE_CIRCLE\);", "Shape"),

    ("swift ground gradient", SW, r"public func setGroundGradient\(_ w: KayaWidget, _ color: KayaColor\) \{", "setGroundGradient"),
    ("swift ground gradient bound", SW, r"public func setGroundGradient\(_ w: KayaWidget, _ s: KayaSignal\) \{", "setGroundGradient"),
    ("swift ground image", SW, r"public func setGroundImage\(_ w: KayaWidget, _ data: Data\) \{", "setGroundImage"),
    ("swift image shape", SW, r"public func setShape\(_ w: KayaWidget, _ shape: KayaShape\) \{", "setShape"),
    ("swift label tint", SW, r"public func setTint\(_ w: KayaWidget, _ s: KayaSignal\) \{", "setTint"),
    ("swift selected", SW, r"public func setSelected\(_ w: KayaWidget, _ s: KayaSignal\) \{", "setSelected"),
    ("swift on_activate", SW, r"public func onActivate\(_ w: KayaWidget, _ handler: @escaping \(KayaAppTx\) throws -> Void\) \{", "onActivate"),
    ("swift on_activate on the container", SW, r"^\s+onActivate: \(\(KayaAppTx\) throws -> Void\)\? = nil,", "onActivate"),
    ("swift template ground gradient", SW, r"public func setGroundGradient\(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<KayaColor>\) \{", "setGroundGradient"),
    ("swift template ground image", SW, r"public func setGroundImage\(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<Data>\) \{", "setGroundImage"),
    ("swift template image shape", SW, r"public func setShape\(_ n: KayaNodeHandle, _ shape: KayaShape\) \{", "setShape"),
    ("swift template label tint", SW, r"public func setTint\(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<KayaTint>\) \{", "setTint"),
    ("swift template selected", SW, r"public func setSelected\(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<Bool>\) \{", "setSelected"),
    ("swift template on_activate", SW, r"public func onActivate\(_ n: KayaNodeHandle, _ handler: @escaping \(KayaAppTx, \[KayaValue\]\) throws -> Void\) \{", "onActivate"),
    ("swift dock", SW, r"public func dock<R>\(", "dock"),
    ("swift activated dispatch", SW, r"case \(UInt16\(KAYA_OCCURRENCE_ACTIVATED\), false\):", "KAYA_OCCURRENCE_ACTIVATED"),
    ("swift on_select", SW, r"public func onSelect\(_ w: KayaWidget, _ handler: @escaping \(KayaAppTx\) throws -> Void\) \{", "onSelect"),
    ("swift on_select on the container", SW, r"^\s+onSelect: \(\(KayaAppTx\) throws -> Void\)\? = nil,", "onSelect"),
    ("swift template on_select", SW, r"public func onSelect\(_ n: KayaNodeHandle, _ handler: @escaping \(KayaAppTx, \[KayaValue\]\) throws -> Void\) \{", "onSelect"),
    ("swift selection dispatch", SW, r"case \(UInt16\(KAYA_OCCURRENCE_SELECTION_CHANGED\), false\):", "KAYA_OCCURRENCE_SELECTION_CHANGED"),
    ("swift image_dominant", SW, r"public static func imageDominant\(_ bytes: Data\) -> KayaColor\? \{", "imageDominant"),
    ("swift image_palette", SW, r"public static func imagePalette\(_ bytes: Data, _ n: Int\) -> \[KayaPaletteColor\]\? \{", "imagePalette"),
    ("swift tint none", SW, r"^    case none = 0\n(?:    case [a-z]+ = [1-5]\n){5}", "none"),
    ("swift tint overlay", SW, r"^    case overlay = 6", "overlay"),
    ("swift shape vocabulary", SW, r"^public enum KayaShape: Int64, Sendable \{", "KayaShape"),

    ("ocaml ground gradient", ML, r"^  \?ground_gradient:color ->\n  \?ground_gradient_bind:color signal ->", "ground_gradient"),
    ("ocaml ground image", ML, r"^  \?ground_image:bytes ->\n  \?ground_image_bind:bytes signal ->", "ground_image"),
    ("ocaml image shape", ML, r"^  \?shape:shape ->", "shape"),
    ("ocaml label tint", ML, r"^  \?tint:Tint\.t ->", "tint"),
    ("ocaml selected", ML, r"^  \?on_activate:\(unit -> unit\) ->\n  \?on_select:\(unit -> unit\) ->\n  \?selected:bool ->", "selected"),
    ("ocaml on_activate", ML, r"^  \?on_activate:\(unit -> unit\) ->\n  \?on_select:\(unit -> unit\) ->\n  \?selected:bool ->", "on_activate"),
    ("ocaml on_select", ML, r"^  \?on_activate:\(unit -> unit\) ->\n  \?on_select:\(unit -> unit\) ->\n  \?selected:bool ->", "on_select"),
    ("ocaml template ground gradient", ML, r"^    \?ground_gradient_field:\('g, color\) field ->", "ground_gradient_field"),
    ("ocaml template ground image", ML, r"^  val bind_ground_image_field : \?level:int -> node -> \('e, bytes\) field -> unit", "bind_ground_image_field"),
    ("ocaml template image shape", ML, r"^  val set_shape : node -> shape -> unit", "set_shape"),
    ("ocaml template label tint", ML, r"^    \?tint_field:\('f, Tint\.t\) field ->", "tint_field"),
    ("ocaml template selected", ML, r"^  val bind_selected_field : \?level:int -> node -> \('e, bool\) field -> unit", "bind_selected_field"),
    ("ocaml template on_activate", ML, r"^  val on_activate : node -> \(key list -> unit\) -> unit", "on_activate"),
    ("ocaml dock", ML, r"^val dock : \?window:int64 -> int64 -> \(unit -> widget \* 'a\) -> 'a", "dock"),
    ("ocaml activated dispatch", MLI, r"Hashtbl\.replace tx\.app\.widget_handlers id handler;\n\s+emit tx \(Kaya_wire\.tx_set_activatable id true\)", "tx_set_activatable"),
    ("ocaml template on_select", ML, r"^  val on_select : node -> \(key list -> unit\) -> unit", "on_select"),
    ("ocaml selection dispatch", MLI, r"else if kind = Kaya_wire\.occ_kind_selection_changed then\n(?:.*\n){0,4}\s+\(match Hashtbl\.find_opt app\.widget_selects id with", "widget_selects"),
    ("ocaml image_dominant", ML, r"^val image_dominant : bytes -> color option", "image_dominant"),
    ("ocaml image_palette", ML, r"^val image_palette : bytes -> int -> palette_color list option", "image_palette"),
    ("ocaml tint none", ML, r"^  type t = None \| Accent \| Success \| Warning \| Critical \| Neutral \| Overlay", "None"),
    ("ocaml tint overlay", ML, r"^  type t = None \| Accent \| Success \| Warning \| Critical \| Neutral \| Overlay", "Overlay"),
    ("ocaml shape vocabulary", ML, r"^type shape = \[ `Rect \| `Rounded \| `Circle \]", "shape"),

    ("haskell ground gradient", HS, r"^  GroundGradient :: Color -> Attr 'BoxW", "GroundGradient"),
    ("haskell ground gradient bound", HS, r"^  GroundGradientBound :: Signal Color -> Attr 'BoxW", "GroundGradientBound"),
    ("haskell ground image", HS, r"^  GroundImage :: BS\.ByteString -> Attr 'BoxW", "GroundImage"),
    ("haskell image shape", HS, r"^  ShapeAs :: Shape -> Attr 'LeafW", "ShapeAs"),
    ("haskell label tint", HS, r"^  TintAs :: Tint -> Attr 'LeafW", "TintAs"),
    ("haskell selected", HS, r"^  SelectedBound :: Signal Bool -> Attr 'BoxW", "SelectedBound"),
    ("haskell on_activate", HS, r"^  OnActivate :: IO \(\) -> Attr 'BoxW", "OnActivate"),
    ("haskell template ground gradient", HS, r"^  TplGroundGradientField :: KField Color -> TplAttr", "TplGroundGradientField"),
    ("haskell template ground image", HS, r"^  TplGroundImageField :: KField BS\.ByteString -> TplAttr", "TplGroundImageField"),
    ("haskell template image shape", HS, r"^  TplShapeAs :: Shape -> TplAttr", "TplShapeAs"),
    ("haskell template label tint", HS, r"^  TplTintField :: KField Tint -> TplAttr", "TplTintField"),
    ("haskell template selected", HS, r"^  TplSelectedField :: KField Bool -> TplAttr", "TplSelectedField"),
    ("haskell template on_activate", HS, r"^  TplOnActivate :: \(\[Key\] -> IO \(\)\) -> TplAttr", "TplOnActivate"),
    ("haskell dock", HS, r"^dock :: Word64 -> Word64 -> Build \(Widget, a\) -> Build a", "dock"),
    ("haskell activated dispatch", HS, r"^applyAttr \(OnActivate handler\) \(Widget n\) = do\n  emitB \(W\.txSetActivatable n True\)\n  pendB \(PClick n handler\)", "OnActivate"),
    ("haskell on_select", HS, r"^  OnSelect :: IO \(\) -> Attr 'BoxW", "OnSelect"),
    ("haskell template on_select", HS, r"^  TplOnSelect :: \(\[Key\] -> IO \(\)\) -> TplAttr", "TplOnSelect"),
    ("haskell selection dispatch", HS, r"\| kind == W\.occKindSelectionChanged -> do\n\s+case keys of\n\s+\[\] -> do\n\s+handlers <- readIORef \(app\.appWidgetSelects\)", "appWidgetSelects"),
    ("haskell image_dominant", HS, r"^imageDominant :: BS\.ByteString -> Maybe Color", "imageDominant"),
    ("haskell image_palette", HS, r"^imagePalette :: BS\.ByteString -> Int -> Maybe \[PaletteColor\]", "imagePalette"),
    ("haskell tint none", HS, r"^  TintNone -> W\.tintNone", "TintNone"),
    ("haskell tint overlay", HS, r"^  TintOverlay -> W\.tintOverlay", "TintOverlay"),
    ("haskell shape vocabulary", HS, r"^data Shape = ShapeRect \| ShapeRounded \| ShapeCircle", "Shape"),
]
FLOOR = 150
LANGS = ("rust", "python", "js", "go", "csharp", "java", "swift", "ocaml", "haskell")
PARTS = ("ground gradient", "ground image", "image shape", "label tint", "selected", "on_activate",
         "template ground gradient", "template ground image", "template image shape", "template label tint",
         "template selected", "template on_activate", "dock", "activated dispatch", "image_dominant",
         # M15, RULED 2026-10-18: the picture's main colours beside the dominant.
         "image_palette",
         "tint none", "tint overlay", "shape vocabulary",
         # Y4, AMENDED 2026-10-17: the user's pick, beside the activation.
         "on_select", "template on_select", "selection dispatch")
FAKE = "kayaFakeSkin"


def findings(texts, rows=ROWS):
    if len(rows) < FLOOR:
        return [f"skin census read fewer than {FLOOR} surfaces"]
    out = [f"skin {label} absent in {rel}"
           for label, rel, pattern, _token in rows if not re.search(pattern, texts[rel], re.M)]
    for lang in LANGS:
        mine = [label[len(lang) + 1:] for label, *_ in rows if label.startswith(lang + " ")]
        for part in PARTS:
            if not any(label == part or label.startswith(part + " ") for label in mine):
                out.append(f"skin census holds no {part} row for {lang}")
    return out


def run():
    """Answers its status, as netimage_surface does."""
    gate = Gate("check-skin-surface")
    texts = {rel: (ROOT / rel).read_text(encoding="utf-8") for _, rel, _, _ in ROWS}
    baseline = findings(texts)
    for problem in baseline:
        gate.finding(problem)
    if baseline:
        print("check-skin-surface: FINDINGS ABOVE")
        return gate.status
    fake_rows = [(label, rel, pattern.replace(re.escape(token), FAKE).replace(token, FAKE), token)
                 for label, rel, pattern, token in ROWS]
    fired = sum(1 for line in findings(texts, fake_rows) if " absent in " in line)
    print(f"check-skin-surface: fake names fired {fired}/{len(ROWS)}")
    if fired != len(ROWS):
        gate.finding(f"check-skin-surface: {len(ROWS) - fired} fake-name rows still matched — a pattern "
                  f"that does not depend on its own name holds nothing")
    for label, rel, pattern, token in ROWS:
        count = len(re.findall(pattern, texts[rel], re.M))
        broken = gate.doctor(label, texts[rel], pattern,
                             lambda m, token=token: m.group(0).replace(token, "kayaCut"),
                             want=count, flags=re.M)
        gate.negative(label, lambda rel=rel, broken=broken: findings({**texts, rel: broken}),
                      want=f"skin {label} absent")
    gate.negative("empty reader", lambda: findings(texts, []), want=f"fewer than {FLOOR}")
    withheld = [row for row in ROWS if row[0] != "go dock"]
    gate.negative("a binding's row withheld", lambda: findings(texts, withheld), want="no dock row for go")
    gate.negatives_ran(len(ROWS) + 2)
    if gate.status == 0:
        print(f"check-skin-surface: OK ({len(ROWS)} skin surfaces in nine bindings)")
    return gate.status
