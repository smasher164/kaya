{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
-- KEEP THE PRAGMA BELOW: 'applyAttr' and 'applyTplAttr' must be TOTAL,
-- and a prop added to either GADT without its arm compiles, ships and
-- silently does nothing. -Wincomplete-patterns is not in GHC's default
-- set and this package sets no -Wall.
{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- KEEP THIS ONE TOO: 'Declare' is how one name spans both zones, and a
-- method left out of ONE instance is a WARNING in GHC's default set —
-- it compiles, ships, and dies at the use site with "No instance
-- nor default method". That is exactly how 'collectionOf' could be
-- live-zone-only again (docs/deferred.md, the nested RECORD collection
-- entry).
{-# OPTIONS_GHC -Werror=missing-methods #-}

-- kaya's idiomatic surface for Haskell: scene declaration as a builder
-- monad, with When and For as combinators taking do-blocks. THE ZONE
-- RULE IS IN THE TYPES: Build's elements are Widgets, Tpl's are Nodes,
-- so `grep '-> Tpl Node'` is the template zone's whole surface — except
-- 'Declare', 'HandlerTarget' and 'CollectionHandle', which dispatch on a
-- SCOPE (tools/tpl-surfaces.py reads it both ways).
module KayaApp
  ( App,
    Build,
    Tpl,
    Widget,
    Node,
    Signal,
    Collection,
    Capabilities (..),
    capabilities,
    Declare (..),
    kayaMain,
    newApp,
    post,
    buildTx,
    submitTx,
    undoableTx,
    undoableTxIn,
    UndoDelta (..),
    UndoText (..),
    UndoEntry (..),
    UndoOrder (..),
    dispatch,
    HandlerTarget (..),
    -- `columns` rides 'Declare (..)' above: it stands in both zones.
    columnsAt,
    Sort (..),
    sortNone,
    sortAsc,
    sortDesc,
    signal,
    writeSignal,
    CollectionHandle (..),
    insert,
    update,
    remove,
    moveBefore,
    moveToEnd,
    moveToFront,
    moveAfter,
    items,
    count,
    mount,
    mountIn,
    createWindow,
    pushEntry,
    addSection,
    addSectionIn,
    selectSection,
    window,
    SectionAttr (..),
    Symbol (..),
    popEntry,
    EntryAttr (..),
    destroyWindow,
    WindowAttr (..),
    brandAccent,
    BrandAttr (..),
    brandTypeface,
    TypefaceAttr (..),
    appIdentity,
    appIdentityAsset,
    appIdentityNamed,
    Asset,
    asset,
    assetMissSentence,
    assetBytes,
    assetClose,
    Platform (..),
    AlertAttr (..),
    showAlert,
    PickedFile (..),
    openPicked,
    pickFiles,
    pickFile,
    saveFile,
    clearWidget,
    focusWidget,
    highlightRanges,
    selectRange,
    revealRange,
    setText,
    bindText,
    bindA11yId,
    bindA11yLabel,
    bindA11yHint,
    bindHelp,
    LiveStrSource (..),
    bindChecked,
    bindValue,
    bindSource,
    setSpacing,
    setInset,
    setAlign,
    setAxis,
    stackWhen,
    columnsWhen,
    setA11yId,
    setA11yLabel,
    setA11yHint,
    setHelp,
    setRole,
    Align (..),
    Axis (..),
    SizeClass (..),
    Role (..),
    Attr (..),
    WClass (..),
    RowCol,
    LeafArgs,
    BothZones,
    BrandArgs,
    TypefaceArgs,
    row,
    column,
    scroll,
    grid,
    labeled,
    progress,
    progressIndeterminate,
    bindTextElement,
    KayaFieldType (..),
    KayaRecord (..),
    KField,
    RecordCollection,
    recordHandle,
    -- `collectionOf` rides 'Declare (..)' above: it stands in both zones.
    field,
    element,
    insertRecord,
    insertFresh,
    updateRecord,
    updateField,
    FieldSet,
    set,
    patch,
    derive,
    recordItems,
    bindTextField,
    bindCheckedField,
    bindValueField,
    bindSourceField,
    button,
    buttonOn,
    entry,
    entryOn,
    textarea,
    textareaOn,
    labelText,
    labelBound,
    headingText,
    headingBound,
    captionText,
    captionBound,
    checkboxOn,
    datePickerOn,
    datePickerBoundOn,
    timePickerOn,
    timePickerBoundOn,
    packDay,
    packTimeOfDay,
    dayOfPacked,
    timeOfDayOfPacked,
    dateValue,
    timeValue,
    sliderOn,
    sliderBoundOn,
    selectOn,
    radioOn,
    spacer,
    imageBytes,
    imageAsset,
    imageBound,
    Viewbox (..),
    Paint (..),
    FillRule (..),
    TextAlign (..),
    TextBaseline (..),
    DrawOp,
    moveTo,
    lineTo,
    close,
    polyline,
    stroke,
    fill,
    font,
    text,
    canvas,
    canvasOf,
    drawAt,
    -- The size policy, LIVE CANVASES ONLY (docs/canvas-plan.md §3.2.1);
    -- `scale` is spelled by writing none of these three.
    fixed,
    onDraw,
    onTick,
    TplStrSource,
    bindTextSource,
    TplBoolSource (..),
    TplDateSource (..),
    TplTimeSource (..),
    TplNumberSource (..),
    TplImageSource (..),
    TplAttr (..),
    withTplAttrs,
    label,
    heading,
    caption,
    checkbox,
    datePicker,
    timePicker,
    bindDateField,
    bindTimeField,
    image,
    rowOf,
    columnOf,
    scrollOf,
    gridOf,
    labeledOf,
    buttonBound,
    entryBound,
    textareaBound,
    progressBound,
    slider,
    select,
    radio,
    each,
    KayaSum (..),
    SumCollection,
    sumHandle,
    sumCollectionOf,
    sumInsert,
    sumUpdate,
    sumItems,
    sumGet,
    sumPatch,
    sumDerive,
    sumArm,
    eachSum,
    MScope (..),
    MItem,
    MOption,
    Catalog,
    IAttr (..),
    item,
    toggle,
    option,
    separator,
    menu,
    radioGroup,
    contextMenu,
    contextCatalog,
    nodeContextMenu,
    setMenuLabel,
    bindMenuLabel,
    setMenuEnabled,
    bindMenuEnabled,
    setMenuChecked,
    bindMenuChecked,
    setMenuValue,
    bindMenuValue,
    setMenuIcon,
    setMenuSymbol,
    setMenuPrimary,
    setMenuShortcut,
    setMenuRole,
    copy,
    emptyClip,
    Clip (..),
    emptyTplClip,
    TplClip (..),
    TplRep (..),
    Representation (..),
    readClipboard,
    setAccepts,
    -- `onPaste` rides 'HandlerTarget (..)' above: it stands in both zones.
    Op (..),
    Dropped (..),
    setDragSource,
    setDropTarget,
    setDragSourceAt,
    setDropTargetAt,
    setNodeDragSource,
    setNodeDropTarget,
    setReorderable,
    onDrop,
    onDragEnded,
    acceptText,
    acceptHtml,
    acceptImage,
    acceptFiles,
    roleSettings,
    roleCut,
    roleCopy,
    rolePaste,
    roleUndo,
    roleRedo,
    menuAppend,
    menuOptions,
  )
where

import Control.Concurrent (ThreadId, forkIO, myThreadId, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.ByteString.Builder (Builder)
import Data.Int (Int64)
import Data.IORef
import Data.List (elemIndex)
import Data.Maybe (fromMaybe, listToMaybe)
import GHC.Records (HasField)
import GHC.TypeLits (ErrorMessage (..), KnownSymbol, TypeError, symbolVal)
import qualified Data.Map.Strict as Map
import qualified Data.List as List
import Data.Proxy (Proxy (..))
import Data.Time.Calendar (Day, fromGregorian, toGregorian)
import Data.Time.LocalTime (TimeOfDay (..))
import Data.Word (Word32, Word64)
import GHC.Generics
import System.Exit (ExitCode (..), exitSuccess, exitWith)

import Control.Exception (SomeException, catch, evaluate)
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)

import KayaRuntime
  ( UndoDelta (..),
    UndoText (..),
    UndoEntry (..),
    UndoOrder (..),
    emptyUndoDelta,
    kayaRun,
    kayaSubmit,
    pollOccurrence,
    registerBlob,
    wake,
    waitOccurrences,
  )
import qualified KayaRuntime as R
import System.IO (Handle)
import qualified KayaWire as W

-- | WHAT THIS HOST CAN DO — see crates/kaya/src/app.rs for the
-- canonical note, which every binding's copy of this surface shortens.
newtype Capabilities = Capabilities
  { -- | The host can materialize a surface beside the primary one
    -- ('createWindow', 'mountIn'). 'False' on iOS and Android.
    auxWindows :: Bool
  }
  deriving (Eq, Show)

-- | This host's capabilities. Constant for the life of the process, so
-- asking once and remembering is fine.
capabilities :: IO Capabilities
capabilities = do
  bits <- R.capabilityBits
  pure (Capabilities ((bits .&. R.capAuxWindows) /= 0))

newtype Signal = Signal Word64

newtype Widget = Widget Word64

newtype Node = Node Word64

-- | A collection instance handle: the collection plus the key path selecting
-- one stamped copy's table.
data Collection = Collection Word64 [W.Value]

-- | A collection handle that can be narrowed to one stamped copy. ONE
-- NAME DISPATCHING ON THE HANDLE (the module header's rule).
class CollectionHandle c where
  -- | The instance of this collection inside the copy keyed by @key@ of
  -- the next enclosing For; chain for deeper nesting.
  at :: c -> W.Value -> c

instance CollectionHandle Collection where
  at (Collection cid path) key = Collection cid (path ++ [key])

instance CollectionHandle (RecordCollection a) where
  at (RecordCollection c) key = RecordCollection (at c key)

assertRoot :: Collection -> Word64
assertRoot (Collection cid []) = cid
assertRoot _ = error "kaya: forEach binds the collection itself, not an instance — drop the at"

-- | One representation, arriving — the sum a copy is the record of.
-- 'RImage' may be a RE-ENCODE of what was copied, so compare what the
-- image IS, never the bytes it arrived in.
data Representation
  = RText String
  | RHtml String
  | RImage BS.ByteString
  | RFiles [PickedFile]
  | RCustom String BS.ByteString

-- | One clip, offered in as many representations as the app fills in.
data Clip = Clip
  { clipText :: Maybe String,
    clipHtml :: Maybe String,
    clipImage :: Maybe BS.ByteString,
    -- | Picked-file handles: copying a file and picking one are the
    -- same currency, so the bytes never move through kaya.
    clipFiles :: [PickedFile],
    -- | The one plural field with names, since several app-defined formats
    -- are legitimate.
    clipCustom :: [(String, BS.ByteString)]
  }

-- | A drag operation (docs\/dnd-plan.md D3): copy and move, nothing
-- else; 'Nothing' is the outcome of a cancelled or refused drag.
data Op = OpCopy | OpMove
  deriving (Eq, Show)

-- | What a drop delivered (docs\/dnd-plan.md D1): the representation a
-- paste already delivers, the point in the destination's own
-- coordinates, the operation the core settled on, and — for a reorder —
-- the anchor row and the side it landed on.
data Dropped = Dropped
  { droppedPoint :: (Double, Double),
    droppedOperation :: Maybe Op,
    droppedAnchor :: [W.Value],
    droppedBefore :: Bool,
    droppedClip :: Maybe Representation
  }

-- | The empty clip, to fill in: @copy emptyClip { clipText = Just "hi" }@.
emptyClip :: Clip
emptyClip =
  Clip
    { clipText = Nothing,
      clipHtml = Nothing,
      clipImage = Nothing,
      clipFiles = [],
      clipCustom = []
    }

-- | ONE REPRESENTATION of a TEMPLATE drag payload (docs/dnd-plan.md §4):
-- a constant, or the ROW'S OWN FIELD, which every stamped copy resolves
-- from its own record — @TplField (field \@"title" \@Item)@ binds the way
-- @label (field \@"title" \@Item)@ does.
data TplRep v = TplConst v | TplField (KField v)

-- | 'Clip' one zone up: what a TEMPLATE node hands over, each
-- representation a constant or the row's own field. A file never binds —
-- a picked handle is not a field.
data TplClip = TplClip
  { tplClipText :: Maybe (TplRep String),
    tplClipHtml :: Maybe (TplRep String),
    tplClipImage :: Maybe (TplRep BS.ByteString),
    tplClipFiles :: [PickedFile],
    tplClipCustom :: [(String, TplRep BS.ByteString)]
  }

-- | The empty template clip, to fill in:
-- @TplDraggable emptyTplClip { tplClipText = Just (TplField (field \@"title" \@Item)) } [OpCopy]@.
emptyTplClip :: TplClip
emptyTplClip =
  TplClip
    { tplClipText = Nothing,
      tplClipHtml = Nothing,
      tplClipImage = Nothing,
      tplClipFiles = [],
      tplClipCustom = []
    }

-- | One file the picker answered with: a handle to redeem, a display
-- name, and a re-openable name — EMPTY unless re-opening it actually
-- works, which is the three desktops and neither phone (DESIGN.md, File
-- dialogs).
data PickedFile = PickedFile
  { pickedHandle :: !Word64,
    pickedName :: !String,
    pickedLocalPath :: !String
  }

-- | Redeem the handle for a real 'Handle', plus whether it seeks.
-- BLOCKS, possibly for a long time, so call it from a thread you chose
-- and post the result back.
openPicked :: PickedFile -> Word32 -> IO (Handle, Bool)
openPicked f = R.openPicked (pickedHandle f)

-- | AN ASSET — a file this app's own BUILD put where the running
-- program can find it (docs\/assets-plan.md).
type Asset = R.Asset

-- | Open an asset by its relative path under the asset root, spelled
-- with @\/@ — @asset "fonts\/sora-wght.ttf"@ (docs\/assets-plan.md;
-- tools/check-assets.py refuses a guest that resolves one itself).
--
-- IO, AND CALLED OUTSIDE THE TRANSACTION: 'Build' is a pure state monad,
-- so a scene opens its assets in the IO around 'buildTx'. A miss raises
-- with the core's sentence verbatim, and EACH CALL READS — no cache.
asset :: String -> IO Asset
asset = R.openAsset

-- | Why 'asset' would raise for this name — the sentence it would carry,
-- handed over without raising. @""@ means the name resolves. LINE 1 is
-- the same on every platform and is the line a scene freezes; line 2
-- names the resolved place. Authored by @asset_why_not@ in
-- crates\/kaya\/src\/assets.rs.
assetMissSentence :: String -> IO String
assetMissSentence = R.assetMissSentence

-- | THE BYTES REDEMPTION: this asset's bytes, copied out of core memory.
assetBytes :: Asset -> IO BS.ByteString
assetBytes = R.assetBytes

-- | Let the core drop these bytes. Idempotent, and a guest that never
-- calls it still leaks nothing.
assetClose :: Asset -> IO ()
assetClose = R.assetClose

data Counters = Counters
  { cSignal :: !Word64,
    -- Live widgets AND template nodes, ONE sequence (DESIGN.md, Binding
    -- conventions). No cNode: a second node counter must not compile.
    cWidget :: !Word64,
    cCollection :: !Word64,
    cAlert :: !Word64,
    cFileDialog :: !Word64,
    cClipboardRead :: !Word64,
    cMenuItem :: !Word64
  }

-- One collection instance: the table inside the stamped copy its path
-- selects; the empty path is a live-zone collection.
data Instance = Instance
  { iPath :: ![W.Value],
    -- One [W.Value] per entry: the record's wire fields (a scalar collection
    -- is the one-field case).
    iEntries :: ![(W.Value, (Word32, [W.Value]))]
  }

type Model = Map.Map Word64 [Instance]

-- BESIDE THE MODEL AND NOT INSIDE IT: 'absorbUndo' rebuilds Instances
-- from the core's payload, so a counter living in an Instance would be
-- rewritten by every history walk.
type Fresh = Map.Map Word64 [([W.Value], Int64)]

data BuildState = BuildState
  { bCounters :: !Counters,
    bRecords :: IO Builder,
    bModel :: !Model,
    bFresh :: !Fresh,
    bChildren :: !(Map.Map Word64 [Word64]),
    bOpenFors :: ![Word64],
    bPending :: ![Pending],
    bDerived :: !(Map.Map Word64 [(Word64, [(W.Value, (Word32, [W.Value]))] -> W.Value)])
  }

data Pending
  = PClick !Word64 (IO ())
  | PAlert !Word64 (Word32 -> IO ())
  | PFileDialog !Word64 ([PickedFile] -> IO ())
  | PClipboardRead !Word64 (Maybe Representation -> IO ())
  | PEntryPopped !Word64 (IO ())
  | PSectionSelected !Word64 (IO ())
  | PBackRequested !Word64 (IO ())
  | PCloseRequested !Word64 (IO ())
  | PWindowClosed !Word64 (IO ())
  | PUndone !Word64 (String -> UndoDelta -> IO ())
  | PRedone !Word64 (String -> UndoDelta -> IO ())
  | PChange !Word64 (String -> IO ())
  | PToggle !Word64 (Bool -> IO ())
  | PValue !Word64 (Double -> IO ())
  | PToggleNode !Word64 ([W.Value] -> Bool -> IO ())
  | PDate !Word64 (Day -> IO ())
  | PTime !Word64 (TimeOfDay -> IO ())
  | PDateNode !Word64 ([W.Value] -> Day -> IO ())
  | PTimeNode !Word64 ([W.Value] -> TimeOfDay -> IO ())
  | PMenuActivated !Word64 (IO ())
  | PMenuActivatedNode !Word64 ([W.Value] -> IO ())
  | PMenuToggled !Word64 (Bool -> IO ())
  | PMenuToggledNode !Word64 ([W.Value] -> Bool -> IO ())
  | PMenuSelected !Word64 (Int -> IO ())
  | PMenuSelectedNode !Word64 ([W.Value] -> Int -> IO ())

modelSet :: Word64 -> [W.Value] -> W.Value -> Word32 -> [W.Value] -> Model -> Model
modelSet cid path key variant fields model =
  Map.insert cid (go (Map.findWithDefault [] cid model)) model
  where
    value = (variant, fields)
    go [] = [Instance path [(key, value)]]
    go (i : rest)
      | iPath i == path = i {iEntries = upsert (iEntries i)} : rest
      | otherwise = i : go rest
    upsert [] = [(key, value)]
    upsert ((k, v) : rest)
      | k == key = (k, value) : rest
      | otherwise = (k, v) : upsert rest

-- The core tears down a removed entry's copy, taking descendant
-- collection instances with it; the model follows the same edges.
modelRemove :: Map.Map Word64 [Word64] -> Word64 -> [W.Value] -> W.Value -> Model -> Model
modelRemove children cid path key model =
  purge cid prefix (Map.adjust (map dropKey) cid model)
  where
    prefix = path ++ [key]
    dropKey i
      | iPath i == path = i {iEntries = filter ((/= key) . fst) (iEntries i)}
      | otherwise = i
    purge c pre m =
      foldr
        (\kid acc -> purge kid pre (Map.adjust (filter (not . startsWith pre . iPath)) kid acc))
        m
        (Map.findWithDefault [] c children)
    startsWith pre p = take (length pre) p == pre

-- The mechanical reorder; moveEntry validates key and anchor first,
-- so the anchor is always present here when given.
modelMove :: Word64 -> [W.Value] -> W.Value -> [W.Value] -> Model -> Model
modelMove cid path key before = Map.adjust (map go) cid
  where
    go i
      | iPath i == path,
        Just value <- lookup key (iEntries i) =
          i {iEntries = place (key, value) (filter ((/= key) . fst) (iEntries i))}
      | otherwise = i
    place entry rest = case before of
      (anchor : _) -> insertAt anchor entry rest
      [] -> rest ++ [entry]
    insertAt anchor entry ((k, v) : rest)
      | k == anchor = entry : (k, v) : rest
      | otherwise = (k, v) : insertAt anchor entry rest
    insertAt _ entry [] = [entry]

lookupEntries :: Word64 -> [W.Value] -> Model -> [(W.Value, (Word32, [W.Value]))]
lookupEntries cid path model =
  case filter ((== path) . iPath) (Map.findWithDefault [] cid model) of
    (i : _) -> iEntries i
    [] -> []

withCounter :: Word64 -> [W.Value] -> (Int64 -> (a, Int64)) -> Fresh -> (a, Fresh)
withCounter cid path body fresh =
  let instances = Map.findWithDefault [] cid fresh
      (a, instances') = go instances
   in (a, Map.insert cid instances' fresh)
  where
    go [] = let (a, n) = body 0 in (a, [(path, n)])
    go ((p, n) : rest)
      | p == path = let (a, n') = body n in (a, (path, n') : rest)
      | otherwise = let (a, rest') = go rest in (a, (p, n) : rest')

mintKey :: Word64 -> [W.Value] -> Fresh -> (Int64, Fresh)
mintKey cid path = withCounter cid path (\n -> (n + 1, n + 1))

absorbKey :: Word64 -> [W.Value] -> W.Value -> Fresh -> Fresh
absorbKey cid path key fresh = case key of
  W.VI64 n -> snd (withCounter cid path (\c -> ((), max c n)) fresh)
  _ -> fresh

-- A collection declared inside a For's template is torn down with its
-- copies: record the edge so the model purges along it.
registerCollection :: Word64 -> BuildState -> BuildState
registerCollection cid s = case bOpenFors s of
  parent : _ -> s {bChildren = Map.insertWith (flip (++)) parent [cid] (bChildren s)}
  [] -> s

-- A minimal state monad, hand-rolled so the bindings depend on nothing
-- beyond GHC's boot libraries.
newtype Build a = Build {unBuild :: BuildState -> (a, BuildState)}

newtype Tpl a = Tpl {unTpl :: BuildState -> (a, BuildState)}

instance Functor Build where
  fmap f (Build g) = Build $ \s -> let (a, s') = g s in (f a, s')

instance Applicative Build where
  pure a = Build (a,)
  Build f <*> Build g = Build $ \s ->
    let (h, s') = f s
        (a, s'') = g s'
     in (h a, s'')

instance Monad Build where
  Build g >>= f = Build $ \s -> let (a, s') = g s in unBuild (f a) s'

instance Functor Tpl where
  fmap f (Tpl g) = Tpl $ \s -> let (a, s') = g s in (f a, s')

instance Applicative Tpl where
  pure a = Tpl (a,)
  Tpl f <*> Tpl g = Tpl $ \s ->
    let (h, s') = f s
        (a, s'') = g s'
     in (h a, s'')

instance Monad Tpl where
  Tpl g >>= f = Tpl $ \s -> let (a, s') = g s in unTpl (f a) s'

emitB :: Builder -> Build ()
emitB = emitBIO . pure

emitBIO :: IO Builder -> Build ()
emitBIO r = Build $ \s -> ((), s {bRecords = bRecords s <> r})

emitT :: Builder -> Tpl ()
emitT = emitTIO . pure

emitTIO :: IO Builder -> Tpl ()
emitTIO r = Tpl $ \s -> ((), s {bRecords = bRecords s <> r})

allocW :: Build Word64
allocW = Build $ \s ->
  let c = bCounters s
      n = cWidget c + 1
   in (n, s {bCounters = c {cWidget = n}})

allocN :: Tpl Word64
allocN = Tpl $ \s ->
  let c = bCounters s
      n = cWidget c + 1
   in (n, s {bCounters = c {cWidget = n}})

-- Menu items get their OWN id space (the c_menu_item counter) — never a
-- widget, node, or surface id.
allocM :: Build Word64
allocM = Build $ \s ->
  let c = bCounters s
      n = cMenuItem c + 1
   in (n, s {bCounters = c {cMenuItem = n}})

bracketTpl :: (BuildState -> (Word64, BuildState)) -> (Word64 -> Builder) -> Maybe Word64
           -> Tpl a -> BuildState -> ((Word64, a), BuildState)
bracketTpl alloc opener forCid (Tpl body) s0 =
  let (self, s1) = alloc s0
      s2 = s1
        { bRecords = bRecords s1 <> pure (opener self),
          bOpenFors = maybe (bOpenFors s1) (: bOpenFors s1) forCid
        }
      (a, s3) = body s2
      s4 = s3
        { bRecords = bRecords s3 <> pure W.txTemplateEnd,
          bOpenFors = maybe (bOpenFors s3) (const (drop 1 (bOpenFors s3))) forCid
        }
   in ((self, a), s4)

newCollection :: [[Word32]] -> BuildState -> (Collection, BuildState)
newCollection variants s =
  let c = bCounters s
      n = cCollection c + 1
      s' = registerCollection n s {bCounters = c {cCollection = n}}
   in (Collection n [], s' {bRecords = bRecords s' <> pure (W.txCreateCollection n variants)})

newRecordCollection ::
  KayaRecord a => Proxy a -> BuildState -> (RecordCollection a, BuildState)
newRecordCollection p s =
  let (c, s') = newCollection [kayaSchema p] s in (RecordCollection c, s')

-- | The declaration vocabulary, shared by both zones. El names the
-- zone's element type: live Widgets or template Nodes.
class Monad m => Declare m where
  type El m
  widget :: Word32 -> m (El m)
  -- | Write Prop::Text on this element, in whichever zone — the FLOOR
  -- spelling, deliberately apart from the 'setText' VERB below
  -- (docs/tpl-props-plan.md F3).
  setTextProp :: El m -> String -> m ()
  setChecked :: El m -> Bool -> m ()
  -- | This element's flex weight within its row\/column: 0 is natural
  -- size, positive weights divide the leftover main-axis space.
  setGrow :: El m -> Double -> m ()
  -- | Whether this element spans its container's cross axis — a
  -- column's width, a row's height — whatever the container's align
  -- (docs\/layout-knobs-plan.md §1). Unset, the kind's own default holds.
  setFill :: El m -> Bool -> m ()
  -- | A grid's column count: its children lay out row-major into this
  -- many columns. Describes the PROTOTYPE, so it is a constant.
  setColumns :: El m -> Int -> m ()
  -- | Put a progress bar in the platform's activity mode: no fraction,
  -- so nothing to source.
  setIndeterminate :: El m -> Bool -> m ()
  addChild :: El m -> El m -> m ()
  collection :: m Collection
  -- | A collection of a-records; the type is the schema. IN BOTH ZONES:
  -- a NESTED collection must be declared inside the template scope
  -- (docs/tables-plan.md).
  collectionOf :: KayaRecord a => Proxy a -> m (RecordCollection a)
  -- | A For over a collection: the do-block declares the template;
  -- returns the For itself alongside the block's result.
  forEach :: Collection -> Tpl a -> m (El m, a)
  -- | Declare the column header bar on a For's container — the element
  -- 'forEach' returns. One title per column; the row template's root
  -- must be a row of exactly one cell per column, refused loudly
  -- otherwise. Re-call after sorting to move the indicator. IN BOTH
  -- ZONES: a nested table's bar is declared in the parent TEMPLATE
  -- scope (docs\/tables-plan.md). Per-copy indicators are 'columnsAt'.
  columns :: El m -> [String] -> Sort -> m ()
  -- | A When over a Bool signal: stamps on true, unstamps on false.
  when_ :: Signal -> Tpl a -> m (El m, a)


instance Declare Build where
  type El Build = Widget
  widget kind = do
    n <- allocW
    emitB (W.txCreateWidget n kind)
    return (Widget n)
  setTextProp (Widget n) text = emitB (W.txSetText n text)
  setChecked (Widget n) checked = emitB (W.txSetChecked n checked)
  setGrow (Widget n) weight = emitB (W.txSetGrow n weight)
  setFill (Widget n) on = emitB (W.txSetFill n on)
  setColumns (Widget n) tracks = emitB (W.txSetColumns n (fromIntegral tracks))
  setIndeterminate (Widget n) on = emitB (W.txSetIndeterminate n on)
  addChild (Widget p) (Widget child) = emitB (W.txAddChild p child)
  collection = Build (newCollection [[W.valueStr]])
  collectionOf p = Build (newRecordCollection p)
  forEach coll body =
    Build $ \s ->
      let cid = assertRoot coll
          ((self, a), s') =
            bracketTpl (unBuild allocW) (`W.txCreateFor` cid) (Just cid) body s
       in ((Widget self, a), s')
  -- pathLen 0 against a LIVE container: the flat table's bar.
  columns (Widget n) titles sort =
    emitB
      ( W.txSetColumnHeaders
          n
          (sortColumn sort)
          (sortDirection sort)
          (fromIntegral (length titles))
          0
          (map W.VStr titles)
      )
  when_ (Signal sid) body =
    Build $ \s ->
      let ((self, a), s') =
            bracketTpl (unBuild allocW) (`W.txCreateWhen` sid) Nothing body s
       in ((Widget self, a), s')

instance Declare Tpl where
  type El Tpl = Node
  widget kind = do
    n <- allocN
    emitT (W.txCreateWidget n kind)
    return (Node n)
  setTextProp (Node n) text = emitT (W.txSetText n text)
  setChecked (Node n) checked = emitT (W.txSetChecked n checked)
  setGrow (Node n) weight = emitT (W.txSetGrow n weight)
  setFill (Node n) on = emitT (W.txSetFill n on)
  setColumns (Node n) tracks = emitT (W.txSetColumns n (fromIntegral tracks))
  setIndeterminate (Node n) on = emitT (W.txSetIndeterminate n on)
  addChild (Node p) (Node child) = emitT (W.txAddChild p child)
  collection = Tpl (newCollection [[W.valueStr]])
  collectionOf p = Tpl (newRecordCollection p)
  forEach coll body =
    Tpl $ \s ->
      let cid = assertRoot coll
          ((self, a), s') =
            bracketTpl (unTpl allocN) (`W.txCreateFor` cid) (Just cid) body s
       in ((Node self, a), s')
  -- pathLen 0 against a TEMPLATE NODE: every copy's bar.
  columns (Node n) titles sort =
    emitT
      ( W.txSetColumnHeaders
          n
          (sortColumn sort)
          (sortDirection sort)
          (fromIntegral (length titles))
          0
          (map W.VStr titles)
      )
  when_ (Signal sid) body =
    Tpl $ \s ->
      let ((self, a), s') =
            bracketTpl (unTpl allocN) (`W.txCreateWhen` sid) Nothing body s
       in ((Node self, a), s')

-- Live-zone-only vocabulary. (tools/check-sugar-surface.py scans the Tpl
-- instance up to THIS line, so the sentence is load-bearing.)

signal :: W.Value -> Build Signal
signal initial = Build $ \s ->
  let c = bCounters s
      n = cSignal c + 1
      s' = s {bCounters = c {cSignal = n}}
   in (Signal n, s' {bRecords = bRecords s' <> pure (W.txCreateSignal n initial)})

writeSignal :: Signal -> W.Value -> Build ()
writeSignal (Signal n) v = emitB (W.txWriteSignal n v)

recomputeDerived :: Word64 -> [W.Value] -> BuildState -> BuildState
recomputeDerived cid path s
  | not (null path) = s
  | otherwise =
      let entries = lookupEntries cid [] (bModel s)
          writes =
            foldMap
              (\(sid, f) -> W.txWriteSignal sid (f entries))
              (Map.findWithDefault [] cid (bDerived s))
       in s {bRecords = bRecords s <> pure writes}

insertEntry :: Word64 -> [W.Value] -> W.Value -> [W.Value] -> IO Builder -> BuildState -> BuildState
insertEntry n path key vals record s0 =
  let s = s0 {bFresh = absorbKey n path key (bFresh s0)}
   in recomputeDerived n path
        s {bRecords = bRecords s <> record,
           bModel = modelSet n path key 0 vals (bModel s)}

insert :: Collection -> W.Value -> W.Value -> Build ()
insert (Collection n path) key value = Build $ \s ->
  ((), insertEntry n path key [value] (pure (W.txCollectionInsert n path key 0 [value])) s)

update :: Collection -> W.Value -> W.Value -> Build ()
update (Collection n path) key value = Build $ \s ->
  ((), recomputeDerived n path
    s {bRecords = bRecords s <> pure (W.txCollectionUpdate n path key 0 [value]),
       bModel = modelSet n path key 0 [value] (bModel s)})

remove :: Collection -> W.Value -> Build ()
remove (Collection n path) key = Build $ \s ->
  ((), recomputeDerived n path
    s {bRecords = bRecords s <> pure (W.txCollectionRemove n path key),
       bModel = modelRemove (bChildren s) n path key (bModel s)})

-- | Reposition an entry before another's.
moveBefore :: Collection -> W.Value -> W.Value -> Build ()
moveBefore c key anchor = moveEntry c key [anchor]

-- | Reposition an entry at the end of its collection.
moveToEnd :: Collection -> W.Value -> Build ()
moveToEnd c key = moveEntry c key []

-- | Reposition an entry at the front.
moveToFront :: Collection -> W.Value -> Build ()
moveToFront c@(Collection n path) key = Build $ \s ->
  case map fst (lookupEntries n path (bModel s)) of
    [] -> error ("kaya: move of missing key " ++ show key)
    (first : _) -> unBuild (moveEntry c key [first]) s

-- | Reposition an entry directly after another's.
moveAfter :: Collection -> W.Value -> W.Value -> Build ()
moveAfter c@(Collection n path) key anchor = Build $ \s ->
  let keys = map fst (lookupEntries n path (bModel s))
   in if key `notElem` keys
        then error ("kaya: move of missing key " ++ show key)
        else case dropWhile (/= anchor) keys of
          [] -> error ("kaya: move after missing key " ++ show anchor)
          _ | key == anchor -> ((), s)
          [_] -> unBuild (moveEntry c key []) s
          (_ : succKey : _)
            | succKey == key -> ((), s) -- already directly after the anchor
            | otherwise -> unBuild (moveEntry c key [succKey]) s

moveEntry :: Collection -> W.Value -> [W.Value] -> Build ()
moveEntry (Collection n path) key before = Build $ \s ->
  let keys = map fst (lookupEntries n path (bModel s))
   in if key `notElem` keys
        then error ("kaya: move of missing key " ++ show key)
        else case before of
          (anchor : _)
            | anchor `notElem` keys ->
                error ("kaya: move before missing key " ++ show anchor)
            | anchor == key -> ((), s) -- moving before itself: no-op
          _ ->
            ((), recomputeDerived n path
              s {bRecords = bRecords s <> pure (W.txCollectionMove n path key before),
                 bModel = modelMove n path key before (bModel s)})

-- | The model: what this guest wrote, exactly — the fold of every
-- patch so far (this transaction's included), in insertion order.
items :: Collection -> Build [(W.Value, W.Value)]
items (Collection n path) = Build $ \s ->
  (map (\(k, (_, vs)) -> (k, head vs)) (lookupEntries n path (bModel s)), s)

count :: Collection -> Build Int
count c = length <$> items c

-- | One per-appearance override of the brand accent, for a brand book that
-- specifies a dark variant.
data BrandAttr
  = -- | The accent to use while the platform is in its LIGHT appearance.
    BLight Word32
  | -- | The accent to use while it is in its DARK one.
    BDark Word32

-- | REQUEST this app's brand accent (docs/styling-plan.md D1/D2): one
-- packed sRGB hex, @0xRRGGBB@, is the whole call, and the
-- per-appearance form adds the attribute list.
--
-- SET ONCE, BEFORE THE FIRST MOUNT: the root refuses a second write or
-- a late one. The app never writes a foreground or a contrast variant.
brandAccent :: (BrandArgs r) => Word32 -> r
brandAccent = brandish

class BrandArgs r where
  brandish :: Word32 -> r

instance (a ~ ()) => BrandArgs (Build a) where
  brandish seed = emitBrand seed []

instance (a ~ BrandAttr, r ~ Build ()) => BrandArgs ([a] -> r) where
  brandish = emitBrand

emitBrand :: Word32 -> [BrandAttr] -> Build ()
emitBrand seed attrs = emitB (W.txSetBrandAccent seed mask (pack light) (pack dark))
  where
    lastOf p = foldl (\held a -> maybe held Just (p a)) Nothing attrs
    light = lastOf (\a -> case a of BLight c -> Just c; _ -> Nothing)
    dark = lastOf (\a -> case a of BDark c -> Just c; _ -> Nothing)
    -- The wire's presence mask: bit 0 light, bit 1 dark; an absent cell
    -- rides as 0 and the core fills it from the seed.
    mask = maybe 0 (const 1) light + maybe 0 (const 2) dark
    pack = fromMaybe 0

-- | WHICH PLATFORM A PER-PLATFORM BRAND VALUE IS FOR (spec enum
-- @platform@; docs/styling-plan.md Slice 2b).
--
-- AN APP NAMES THESE, IT NEVER ASKS WHICH ONE IT IS. There is no
-- @currentPlatform@: GHC's @System.Info.os@ reports the COMPILE TARGET
-- and says @darwin@ for both macOS and iOS.
data Platform
  = PlatformMac
  | PlatformIos
  | PlatformLinux
  | PlatformWindows
  | PlatformAndroid
  deriving (Eq, Show)

-- From the generated table, never literals (as 'symbolWire'): the
-- discriminants are spec facts and a hand-typed copy here would drift.
platformWire :: Platform -> Int64
platformWire p = fromIntegral $ case p of
  PlatformMac -> W.platformMac
  PlatformIos -> W.platformIos
  PlatformLinux -> W.platformLinux
  PlatformWindows -> W.platformWindows
  PlatformAndroid -> W.platformAndroid

-- | The optional halves of a brand typeface request, for an app whose
-- default family is not the right name on every platform, or which
-- ships the font itself.
data TypefaceAttr
  = -- | The family to use ON one platform, overriding the default name
    -- for that platform alone: @TFor PlatformLinux "DejaVu Serif"@.
    TFor Platform String
  | -- | A font FILE, as bytes: the backend hands them to its platform's
    -- app-font API, reads back the family that registration named, and uses
    -- it in preference to any name above.
    TFont BS.ByteString
  | -- | The same font slot with the file NAMED rather than read:
    -- @TFontAsset =<< asset "fonts\/sora-wght.ttf"@ opened in the IO
    -- around 'buildTx'. THE BYTES NEVER ENTER THE HASKELL HEAP: the core
    -- hands the same buffer to the blob table.
    TFontAsset Asset

-- | REQUEST this app's brand typeface (docs/styling-plan.md Slice 2b):
-- @brandTypeface "Georgia"@. THE FAMILY, NEVER THE SCALE.
--
-- SET ONCE, BEFORE THE FIRST MOUNT, like 'brandAccent'. A FAMILY A
-- PLATFORM DOES NOT HAVE LEAVES THAT PLATFORM'S OWN TYPEFACE IN PLACE,
-- deliberately and silently.
brandTypeface :: (TypefaceArgs r) => String -> r
brandTypeface = typefacish

class TypefaceArgs r where
  typefacish :: String -> r

instance (a ~ ()) => TypefaceArgs (Build a) where
  typefacish family = emitTypeface family []

instance (a ~ TypefaceAttr, r ~ Build ()) => TypefaceArgs ([a] -> r) where
  typefacish = emitTypeface

emitTypeface :: String -> [TypefaceAttr] -> Build ()
emitTypeface family attrs =
  emitBIO (W.txSetBrandTypeface mask (W.VStr family) rows <$> slot)
  where
    -- THE ROWS ARE A LIST AND THE FONT IS A CELL: a repeated 'TFont' is
    -- last-wins, while the 'TFor' rows are NOT folded and NOT
    -- deduplicated — a platform named twice must reach the root and die.
    rows =
      concatMap
        ( \a -> case a of
            TFor p f -> [W.VI64 (platformWire p), W.VStr f]
            TFont _ -> []
            TFontAsset _ -> []
        )
        attrs
    -- ONE SLOT, TWO WAYS TO FILL IT: they fold together, last written
    -- wins.
    font =
      foldl
        ( \held a -> case a of
            TFont b -> Just (Left b)
            TFontAsset s -> Just (Right s)
            _ -> held
        )
        Nothing
        attrs
    -- The wire's presence mask: bit 0 says a font blob rides the slot.
    mask = maybe 0 (const 1) font
    -- The slot is written either way — an empty Str stands in — so the
    -- record's field count never varies with the payload.
    slot = case font of
      Nothing -> pure (W.VStr "")
      Just (Left b) -> W.VBlob <$> registerBlob b
      Just (Right s) -> W.VBlob <$> R.assetBlob s

-- | DECLARE this app's identity (docs/app-identity-plan.md): the name it
-- goes by and the picture that stands for it, as the bytes of one image
-- file. Send a PNG; each lowering converts.
--
-- SET ONCE, BEFORE THE FIRST MOUNT: the root refuses a second write, a
-- late one and an empty name.
appIdentity :: String -> BS.ByteString -> Build ()
appIdentity name icon =
  emitBIO (W.txSetAppIdentity 1 (W.VStr name) . W.VBlob <$> registerBlob icon)

-- | The ASSET form of the icon slot: the same declaration, with the mark
-- NAMED rather than read.
appIdentityAsset :: String -> Asset -> Build ()
appIdentityAsset name icon =
  emitBIO (W.txSetAppIdentity 1 (W.VStr name) . W.VBlob <$> R.assetBlob icon)

-- | The NAME-ONLY form, for an app that has a name and no mark yet.
appIdentityNamed :: String -> Build ()
appIdentityNamed name =
  emitB (W.txSetAppIdentity 0 (W.VStr name) (W.VStr ""))

-- | Window construction attributes — the config-list spelling. The
-- handler attrs ride the declaration: 'WOnCloseRequested' fires per
-- chrome close while veto_close is armed (answer with 'destroyWindow'
-- to agree); 'WOnClosed' fires when the non-veto auxiliary is
-- chrome-closed and retires with it.
data WindowAttr
  = WTitle String
  | WSize Double Double
  | WVetoClose Bool
  | -- | The CEILING on how many of this window's stack entries present
    -- side by side: 1 is the serial stack, 2 and 3 are columns on a
    -- window wide enough, the shallowest shed first as it narrows
    -- (docs/multicolumn-plan.md). The live count is the platform's own
    -- judgment where it has one; the root refuses 0 and anything above 3.
    WPanes Word32
  | WSectionsPresentation Int64
  | -- | Whether this surface holds unsaved work (docs/dirty-plan.md
    -- D1). 'WTitle' IS NEVER TOUCHED BY IT — kaya's titles are
    -- byte-compared across platforms.
    WDirty Bool
  | -- | The space kaya's own interpreters put around this window's
    -- mounted root, in layout units — LAYOUT, not appearance
    -- (docs/styling-plan.md D3).
    WInset Double
  | WOnCloseRequested (IO ())
  | WOnClosed (IO ())
  | -- | Hear an undo kaya routed in this window: the step's label —
    -- EMPTY for a typing episode — and what the core put back. THE
    -- DELTA IS THE ONLY NOTIFICATION (the echo doctrine).
    WOnUndone (String -> UndoDelta -> IO ())
  | -- | The 'WOnUndone' twin. A frontier typing episode redoes on the
    -- platform's own stack and reports itself as an ordinary edit, so
    -- that one does not arrive here.
    WOnRedone (String -> UndoDelta -> IO ())
  | -- | The menubar rides the window construct: 'WMenus' realizes its
    -- inline Build actions in order and appends each top-level grouping
    -- node to this window's catalog — append-only, at any time.
    WMenus [Build (MItem 'BarM)]

-- | Set a window's attributes in one construct — the attribute set is
-- EXACTLY 'createWindow''s: @window 0 [WTitle "sections",
-- WSectionsPresentation 1]@.
window :: Word64 -> [WindowAttr] -> Build ()
window n = mapM_ apply
  where
    apply (WTitle t) = emitB (W.txSetWindowTitle n t)
    apply (WSize w h) = do
      emitB (W.txSetWindowWidth n w)
      emitB (W.txSetWindowHeight n h)
    apply (WVetoClose v) = emitB (W.txSetWindowVetoClose n v)
    apply (WPanes ceiling') = emitB (W.txSetWindowPanes n (fromIntegral ceiling'))
    apply (WSectionsPresentation p) = emitB (W.txSetWindowSectionsPresentation n p)
    apply (WDirty v) = emitB (W.txSetWindowDirty n v)
    apply (WInset units) = emitB (W.txSetWindowInset n units)
    apply (WOnCloseRequested handler) = pendB (PCloseRequested n handler)
    apply (WOnClosed handler) = pendB (PWindowClosed n handler)
    apply (WOnUndone handler) = pendB (PUndone n handler)
    apply (WOnRedone handler) = pendB (PRedone n handler)
    apply (WMenus menus) =
      mapM_ (\m -> m >>= \(MItem i) -> emitB (W.txMenubarAppend n i)) menus

-- | Create an auxiliary window (capability-gated: phone hosts reject
-- at the root); materializes hidden, 'mountIn' presents:
-- @createWindow 1 [WTitle "inspector", WSize 480 320, WVetoClose True]@.
createWindow :: Word64 -> [WindowAttr] -> Build ()
createWindow n attrs = do
  emitB (W.txCreateWindow n)
  window n attrs

-- | Close and forget an auxiliary window — also the veto grammar's
-- confirmation and the reconciliation after a chrome close.
destroyWindow :: Word64 -> Build ()
destroyWindow n = emitB (W.txDestroyWindow n)

-- | Mount a root into a specific window; mounting presents.
mountIn :: Word64 -> Widget -> Build ()
mountIn window (Widget n) = emitB (W.txMount window n)

-- | Navigation-entry construction attributes — the config-list
-- spelling. 'EOnPopped' fires when the user's back affordance pops THIS
-- entry natively (a programmatic 'popEntry' does not fire it) and
-- retires with the one pop; 'EOnBack' fires per back request while
-- intercept_back is armed — nothing has popped, answer with 'popEntry'
-- to agree.
data EntryAttr
  = ETitle String
  | EInterceptBack Bool
  | EOnPopped (IO ())
  | EOnBack (IO ())

data SectionAttr
  = STitle String
  | -- | The switcher item's SEMANTIC ICON ('Symbol'): a concept each
    -- backend draws in its own platform's symbol set.
    SSymbol Symbol
  | SOnSelected (IO ())

-- | Push a navigation entry onto the primary surface's stack (entry ids
-- are guest-allocated in the shared surface namespace); materializes
-- covered, 'mountIn' presents it.
pushEntry :: Word64 -> [EntryAttr] -> Build ()
pushEntry n attrs = do
  emitB (W.txPushEntry 0 n)
  mapM_ apply attrs
  where
    apply (ETitle t) = emitB (W.txSetEntryTitle n t)
    apply (EInterceptBack v) = emitB (W.txSetEntryInterceptBack n v)
    apply (EOnPopped handler) = pendB (PEntryPopped n handler)
    apply (EOnBack handler) = pendB (PBackRequested n handler)

-- | Pop the primary stack's top navigation entry and forget its tree — also
-- the back-veto grammar's confirmation after 'onBackRequested'.
popEntry :: Build ()
popEntry = emitB (W.txPopEntry 0)

-- | Append a section to the primary window's section set; the set is
-- append-only — sections have no destruction grammar, and every
-- section's root is retained while covered (switching is SELECTION, not
-- lifecycle). 'SOnSelected' fires each time the USER switches to it —
-- NOT one-shot; a programmatic 'selectSection' does not fire it (the
-- echo doctrine).
addSection :: Word64 -> [SectionAttr] -> Build ()
addSection = addSectionIn 0

-- | 'addSection' with the HOST WINDOW said out loud — 0 is the primary, an
-- aux window's id otherwise.
addSectionIn :: Word64 -> Word64 -> [SectionAttr] -> Build ()
addSectionIn w n attrs = do
  emitB (W.txAddSection w n)
  mapM_ apply attrs
  where
    apply (STitle t) = emitB (W.txSetSectionTitle n t)
    apply (SSymbol s) = emitB (W.txSetSectionSymbol n (symbolWire s))
    apply (SOnSelected handler) = pendB (PSectionSelected n handler)

-- | Select a section programmatically: configuration, never echoes
-- 'SOnSelected' (the echo doctrine).
selectSection :: Word64 -> Build ()
selectSection n = emitB (W.txSelectSection 0 n)

-- | THE SEMANTIC ICON VOCABULARY (spec enum @symbol@; DESIGN.md "Icons
-- want names, not bytes"; docs/styling-plan.md D6), shared by 'SSymbol'
-- on a section and 'ISymbol' on a menu item.
data Symbol
  = SymbolAdd
  | SymbolRemove
  | -- | Destroying something, the wastebasket idiom — distinct from
    -- 'SymbolRemove', which takes an item out of a list.
    SymbolDelete
  | SymbolEdit
  | -- | Confirmation, the checkmark idiom.
    SymbolDone
  | -- | Dismissal, the ✕ idiom — not 'SymbolDelete'.
    SymbolClose
  | SymbolSearch
  | SymbolSettings
  | SymbolRefresh
  | SymbolInfo
  | SymbolWarning
  | -- | The direction-relative pair: every platform mirrors these under
    -- a right-to-left layout, so they mean BACKWARD and FORWARD in
    -- reading order, never "left" and "right".
    SymbolBack
  | SymbolForward
  | -- | The overflow affordance (the ellipsis idiom).
    SymbolMore
  | SymbolCopy
  | SymbolPaste
  | -- | Favourite.
    SymbolStar
  | SymbolLock
  | -- | A person or account.
    SymbolPerson
  | SymbolHome
  deriving (Eq, Show)

-- From the generated table, never literals: the discriminants are spec
-- facts, append-only, and a hand-typed copy here would drift.
symbolWire :: Symbol -> Int64
symbolWire s = fromIntegral $ case s of
  SymbolAdd -> W.symbolAdd
  SymbolRemove -> W.symbolRemove
  SymbolDelete -> W.symbolDelete
  SymbolEdit -> W.symbolEdit
  SymbolDone -> W.symbolDone
  SymbolClose -> W.symbolClose
  SymbolSearch -> W.symbolSearch
  SymbolSettings -> W.symbolSettings
  SymbolRefresh -> W.symbolRefresh
  SymbolInfo -> W.symbolInfo
  SymbolWarning -> W.symbolWarning
  SymbolBack -> W.symbolBack
  SymbolForward -> W.symbolForward
  SymbolMore -> W.symbolMore
  SymbolCopy -> W.symbolCopy
  SymbolPaste -> W.symbolPaste
  SymbolStar -> W.symbolStar
  SymbolLock -> W.symbolLock
  SymbolPerson -> W.symbolPerson
  SymbolHome -> W.symbolHome

-- --- Menus: the command vocabulary (DESIGN.md, Menus) ---------------

-- | The anchor scope a catalog belongs to, as a phantom index: 'BarM
-- is a window catalog (a shortcut home), 'CtxM a context anchor. A
-- shortcut on a context item — or a keyed handler on a bar item — is a
-- TYPE error; the runtime guard at the root remains the floor beneath.
data MScope = BarM | CtxM

-- | A live menu item: its OWN id space behind its own type (indexed by anchor
-- scope), so cross-use with 'Widget'/'Node' handles is a type error.
newtype MItem (s :: MScope) = MItem Word64

-- | A radio option: its own type, so an option outside a 'radioGroup'
-- children list — or a non-option inside one — is a type error (the
-- closed parent/child grammar, compile-checked).
newtype MOption (s :: MScope) = MOption Word64

-- | A context catalog built UNANCHORED ('contextCatalog') for a template
-- node: menu items are live and shared across stamped copies, so the
-- catalog is built in the live zone and 'nodeContextMenu' attaches it.
newtype Catalog = Catalog [Word64]

-- | A named vocabulary for the accept list's closed half. A MISTYPED
-- BARE STRING IS SILENT: it becomes a custom format id no clipboard will
-- ever offer, so Paste stays dead and the paste hook never fires.
acceptText :: String
acceptText = "text"
acceptHtml :: String
acceptHtml = "html"
acceptImage :: String
acceptImage = "image"
acceptFiles :: String
acceptFiles = "files"

roleSettings :: String
roleSettings = "settings"

-- | The three clipboard commands. They lower to the platform's own, act
-- on the FOCUSED widget, and work out their own enablement from what
-- the clipboard offers and what that widget accepts.
roleCut :: String
roleCut = "cut"

roleCopy :: String
roleCopy = "copy"

rolePaste :: String
rolePaste = "paste"

-- | The two history commands (docs/undo-plan.md D6). They ask the
-- FOCUSED widget first — a text field with its own edit history answers
-- before the app's ledger does — and enablement is that same question,
-- asked live at activation.
roleUndo :: String
roleUndo = "undo"

roleRedo :: String
roleRedo = "redo"

-- | Menu item construction attributes — the config-list spelling over
-- a closed GADT indexed by anchor scope. Label and enablement are
-- signal-bindable; 'IChecked'/'IValue' bind both ways (programmatic
-- writes are QUIET — the echo doctrine); icon, primary and shortcut are
-- const-only. The @Node@ flavors receive the stamped copy's key path.
data IAttr (s :: MScope) where
  -- | Bind the label to a Str signal (constant labels are the
  -- creator's positional argument).
  ILabel :: Signal -> IAttr s
  IEnabled :: Bool -> IAttr s
  IEnabledBy :: Signal -> IAttr s
  IChecked :: Bool -> IAttr s
  ICheckedBy :: Signal -> IAttr s
  IValue :: Int -> IAttr s
  IValueBy :: Signal -> IAttr s
  IIcon :: BS.ByteString -> IAttr s
  -- | The item's SEMANTIC ICON ('Symbol'). BESIDE 'IIcon', not instead
  -- of it: app-specific art still rides the blob. Const-only, so there
  -- is no bind flavor.
  ISymbol :: Symbol -> IAttr s
  IPrimary :: Bool -> IAttr s
  -- | Any window-anchored LEAF command: a chord needs a window catalog
  -- as its native dispatch home, and the type carries that rule.
  IShortcut :: String -> IAttr 'BarM
  -- | Window-anchored actions only: a role names a standard command in the
  -- window catalog.
  IRole :: String -> IAttr 'BarM
  IOnActivate :: IO () -> IAttr s
  IOnActivateNode :: ([W.Value] -> IO ()) -> IAttr 'CtxM
  IOnToggle :: (Bool -> IO ()) -> IAttr s
  IOnToggleNode :: ([W.Value] -> Bool -> IO ()) -> IAttr 'CtxM
  IOnSelect :: (Int -> IO ()) -> IAttr s
  IOnSelectNode :: ([W.Value] -> Int -> IO ()) -> IAttr 'CtxM

applyIAttr :: Word64 -> IAttr s -> Build ()
applyIAttr n attr = case attr of
  ILabel (Signal s) -> emitB (W.txBindMenuLabel n s)
  IEnabled v -> emitB (W.txSetMenuEnabled n v)
  IEnabledBy (Signal s) -> emitB (W.txBindMenuEnabled n s)
  IChecked v -> emitB (W.txSetMenuChecked n v)
  ICheckedBy (Signal s) -> emitB (W.txBindMenuChecked n s)
  IValue v -> emitB (W.txSetMenuValue n (fromIntegral v))
  IValueBy (Signal s) -> emitB (W.txBindMenuValue n s)
  IIcon bytes -> emitBIO (W.txSetMenuIcon n <$> registerBlob bytes)
  ISymbol s -> emitB (W.txSetMenuSymbol n (symbolWire s))
  IPrimary v -> emitB (W.txSetMenuPrimary n v)
  IShortcut spelling -> emitB (W.txSetMenuShortcut n spelling)
  IRole name -> emitB (W.txSetMenuRole n name)
  IOnActivate handler -> pendB (PMenuActivated n handler)
  IOnActivateNode handler -> pendB (PMenuActivatedNode n handler)
  IOnToggle handler -> pendB (PMenuToggled n handler)
  IOnToggleNode handler -> pendB (PMenuToggledNode n handler)
  IOnSelect handler -> pendB (PMenuSelected n handler)
  IOnSelectNode handler -> pendB (PMenuSelectedNode n handler)

newMenuItem :: Word32 -> Maybe String -> [IAttr s] -> Build Word64
newMenuItem kind label attrs = do
  n <- allocM
  emitB (W.txMenuItemCreate n kind)
  mapM_ (emitB . W.txSetMenuLabel n) label
  mapM_ (applyIAttr n) attrs
  return n

-- | An action — a leaf command firing exactly one menu_activated
-- occurrence (menu click OR its shortcut: ONE occurrence, one dispatch
-- path): @item "Save" [IShortcut "primary+s", IOnActivate h]@.
item :: String -> [IAttr s] -> Build (MItem s)
item label attrs = MItem <$> newMenuItem W.menuKindAction (Just label) attrs

-- | A toggle — a stateful leaf reusing the Checkbox contract: user
-- flips emit menu_toggled ('IOnToggle' receives the new state);
-- programmatic 'IChecked' writes are QUIET.
toggle :: String -> [IAttr s] -> Build (MItem s)
toggle label attrs = MItem <$> newMenuItem W.menuKindToggle (Just label) attrs

-- | One labeled radio option, appended in declaration order — the
-- order IS the index vocabulary the group's value selects over.
option :: String -> [IAttr s] -> Build (MOption s)
option label attrs = MOption <$> newMenuItem W.menuKindRadioOption (Just label) attrs

-- | Native grouping chrome: no label, no props, no handler.
separator :: Build (MItem s)
separator = MItem <$> newMenuItem W.menuKindSeparator Nothing []

-- | A menu grouping node — a bar root through 'WMenus', or nested
-- inline in a parent's child list (one nested grouping level is the cap,
-- root-checked).
menu :: String -> [IAttr s] -> [Build (MItem s)] -> Build (MItem s)
menu label attrs children = do
  n <- newMenuItem W.menuKindMenu (Just label) []
  mapM_ (\child -> child >>= \(MItem c) -> emitB (W.txMenuItemAppend n c)) children
  mapM_ (applyIAttr n) attrs
  return (MItem n)

-- | A radio group — the Choice contract with the platform's checkmark
-- idiom. The children are 'option's ONLY (their type holds the closed
-- grammar); 'IValue'\/'IValueBy' is the selected 0-based index, applied
-- AFTER the options so the index has options to address.
radioGroup :: String -> [IAttr s] -> [Build (MOption s)] -> Build (MItem s)
radioGroup label attrs options = do
  n <- newMenuItem W.menuKindRadioGroup (Just label) []
  mapM_ (\child -> child >>= \(MOption c) -> emitB (W.txMenuItemAppend n c)) options
  mapM_ (applyIAttr n) attrs
  return (MItem n)

-- | A context menu on a LIVE widget: the same item vocabulary scoped to a
-- NOUN, with the platform's own gesture (right-click, long-press).
contextMenu :: Widget -> [Build (MItem 'CtxM)] -> Build ()
contextMenu (Widget w) roots =
  mapM_ (\root -> root >>= \(MItem n) -> emitB (W.txContextAttach w n)) roots

-- | Build a context catalog UNANCHORED — free root items for a
-- template-node anchor; 'nodeContextMenu' attaches it inside the
-- template, and each activation carries the copy's key path.
contextCatalog :: [Build (MItem 'CtxM)] -> Build Catalog
contextCatalog roots =
  Catalog <$> mapM (\root -> (\(MItem n) -> n) <$> root) roots

-- | Attach a live-built context catalog to a template node: each
-- activation carries that copy's key path — the keys ARE the noun.
nodeContextMenu :: Node -> Catalog -> Tpl ()
nodeContextMenu (Node n) (Catalog roots) =
  mapM_ (emitT . W.txContextAttachNode n) roots

setMenuLabel :: MItem s -> String -> Build ()
setMenuLabel (MItem n) text = emitB (W.txSetMenuLabel n text)

bindMenuLabel :: MItem s -> Signal -> Build ()
bindMenuLabel (MItem n) (Signal s) = emitB (W.txBindMenuLabel n s)

setMenuEnabled :: MItem s -> Bool -> Build ()
setMenuEnabled (MItem n) v = emitB (W.txSetMenuEnabled n v)

bindMenuEnabled :: MItem s -> Signal -> Build ()
bindMenuEnabled (MItem n) (Signal s) = emitB (W.txBindMenuEnabled n s)

setMenuChecked :: MItem s -> Bool -> Build ()
setMenuChecked (MItem n) v = emitB (W.txSetMenuChecked n v)

bindMenuChecked :: MItem s -> Signal -> Build ()
bindMenuChecked (MItem n) (Signal s) = emitB (W.txBindMenuChecked n s)

setMenuValue :: MItem s -> Int -> Build ()
setMenuValue (MItem n) v = emitB (W.txSetMenuValue n (fromIntegral v))

bindMenuValue :: MItem s -> Signal -> Build ()
bindMenuValue (MItem n) (Signal s) = emitB (W.txBindMenuValue n s)

setMenuIcon :: MItem s -> BS.ByteString -> Build ()
setMenuIcon (MItem n) bytes = emitBIO (W.txSetMenuIcon n <$> registerBlob bytes)

-- | The item's SEMANTIC ICON, dynamic path — the declarative spelling is the
-- 'ISymbol' attr.
setMenuSymbol :: MItem s -> Symbol -> Build ()
setMenuSymbol (MItem n) s = emitB (W.txSetMenuSymbol n (symbolWire s))

-- | The phone-bar promotion hint (actions only — root-checked).
-- Flipping it recomputes the promoted set deterministically; INERT on
-- desktops — not a toolbar grammar.
setMenuPrimary :: MItem s -> Bool -> Build ()
setMenuPrimary (MItem n) v = emitB (W.txSetMenuPrimary n v)

-- | The action's shortcut (window-anchored actions only), canonicalized
-- by 'W.canonicalizeShortcut'. The shortcut fires the SAME
-- menu_activated occurrence as a click.
setMenuShortcut :: MItem s -> String -> Build ()
setMenuShortcut (MItem n) spelling = emitB (W.txSetMenuShortcut n spelling)

-- | Declare a retained action a standard command (actions only — root-
-- checked).
setMenuRole :: MItem 'BarM -> String -> Build ()
setMenuRole (MItem n) name = emitB (W.txSetMenuRole n name)

-- | Reopen a RETAINED grouping node and append more children — the
-- append-at-any-time discipline.
menuAppend :: MItem s -> [Build (MItem s)] -> Build ()
menuAppend (MItem n) children =
  mapM_ (\child -> child >>= \(MItem c) -> emitB (W.txMenuItemAppend n c)) children

-- | The option-flavored reopening, for a retained radio group.
menuOptions :: MItem s -> [Build (MOption s)] -> Build ()
menuOptions (MItem n) options =
  mapM_ (\child -> child >>= \(MOption c) -> emitB (W.txMenuItemAppend n c)) options



-- | Alert construction attributes — the config-list spelling.
data AlertAttr
  = ATitle String
  | AMessage String
  | AAction String
  | ACancel String

-- | Request a modal alert (the request/result grammar), the handler
-- riding the request. The handler fires exactly once — choice is an
-- action index (0 or 1) or 'W.alertChoiceCancel' — and its registration
-- retires with the result. AT MOST TWO AActions (the platform floor)
-- and EXACTLY ONE ACancel, required.
showAlert :: [AlertAttr] -> (Word32 -> IO ()) -> Build ()
showAlert attrs handler = do
  let titles = [t | ATitle t <- attrs]
      messages = [m | AMessage m <- attrs]
      actions = [a | AAction a <- attrs]
      cancels = [c | ACancel c <- attrs]
  case () of
    _
      | length actions > 2 ->
          error "kaya: an alert carries at most 2 actions (the platform floor)"
      | null cancels || any null cancels ->
          error "kaya: the cancel slot always exists and needs a name — add ACancel"
      | otherwise -> do
          n <- Build $ \s ->
            let c = bCounters s
                next = cAlert c + 1
             in (next, s {bCounters = c {cAlert = next}})
          pendB (PAlert n handler)
          emitB
            ( W.txShowAlert
                0
                n
                (fromIntegral (length actions))
                (W.VStr (concat (take 1 titles)))
                (W.VStr (concat (take 1 messages)))
                (W.VStr (concat (take 1 actions)))
                (W.VStr (concat (take 1 (drop 1 actions))))
                (W.VStr (concat (take 1 cancels)))
            )

-- | Check one accept-list entry and return it. Ids reach every
-- platform's own registry verbatim, so they carry no spaces.
acceptToken :: String -> String
acceptToken kind
  | null kind || ' ' `elem` kind =
      error
        ( "kaya: "
            ++ show kind
            ++ " is not an accept-list entry — the closed kinds are "
            ++ "acceptText, acceptHtml, acceptImage and acceptFiles, and a "
            ++ "custom format id reaches the platform's own registry "
            ++ "verbatim, so it carries no spaces"
        )
  | otherwise = kind

-- | Join an accept list: the closed kinds by name plus any custom ids,
-- space separated.
acceptList :: [String] -> String
acceptList = unwords . map acceptToken

-- | Put ONE clip on the system clipboard:
-- @copy emptyClip { clipText = Just "kaya clip" }@.
copy :: Clip -> Build ()
copy clip = emitBIO $ do
  customValues <-
    concat
      <$> mapM
        ( \(ident, bytes) -> do
            h <- registerBlob bytes
            return [W.VStr (acceptToken ident), W.VBlob h]
        )
        (clipCustom clip)
  imageValue <- case clipImage clip of
    Nothing -> return []
    Just bytes -> (: []) . W.VBlob <$> registerBlob bytes
  let present =
        maybe 0 (const W.clipText) (clipText clip)
          + maybe 0 (const W.clipHtml) (clipHtml clip)
          + maybe 0 (const W.clipImage) (clipImage clip)
      files = map (W.VI64 . fromIntegral . pickedHandle) (clipFiles clip)
      values =
        customValues
          ++ files
          ++ imageValue
          ++ maybe [] (\h -> [W.VStr h]) (clipHtml clip)
          ++ maybe [] (\t -> [W.VStr t]) (clipText clip)
  return
    ( W.txCopy
        present
        (fromIntegral (length (clipFiles clip)))
        (fromIntegral (length (clipCustom clip)))
        values
    )

-- | Read the clipboard OUTSIDE any paste gesture — THE PRIVILEGED ONE. The
-- platforms have deliberately made it expensive (DESIGN.md, and
-- docs/clipboard-plan.md): reach for it to detect a URL or import, never to
-- implement Paste — that is the Paste command, and it is free.
readClipboard :: [String] -> (Maybe Representation -> IO ()) -> Build ()
readClipboard accepting handler = do
  n <- Build $ \st ->
    let c = bCounters st
        next = cClipboardRead c + 1
     in (next, st {bCounters = c {cClipboardRead = next}})
  pendB (PClipboardRead n handler)
  emitB (W.txReadClipboard n (W.VStr (acceptList accepting)))

-- | Declare what a widget takes from a paste — the dynamic path; the
-- declarative spelling is the 'Accepts' attribute at construction.
setAccepts :: Widget -> [String] -> Build ()
setAccepts (Widget w) kinds = emitB (W.txSetAccepts w (acceptList kinds))

-- | The drag_op mask a guest's operations name; the empty list
-- withdraws the declaration.
operationMask :: [Op] -> Word32
operationMask = foldr (\o m -> m + opMask o) 0
  where
    opMask OpCopy = W.dragOpCopy
    opMask OpMove = W.dragOpMove

-- | The drag_op word, or 'Nothing' for a cancelled or refused drag.
operationOf :: Word32 -> Maybe Op
operationOf m
  | m == W.dragOpCopy = Just OpCopy
  | m == W.dragOpMove = Just OpMove
  | otherwise = Nothing

-- | DECLARE what a widget hands over when dragged: a clip in 'copy''s
-- own shapes plus the operations it allows (docs\/dnd-plan.md D1) — the
-- dynamic path; the declarative spelling is the 'Draggable' attribute
-- at construction. An EMPTY clip withdraws the declaration, which is
-- how a same-app move removes its source (D2).
--
-- LIVE WIDGETS ONLY, and the argument type is the refusal: the template
-- zone lands with its own slice (docs\/dnd-plan.md §4).
setDragSource :: Widget -> Clip -> [Op] -> Build ()
setDragSource (Widget w) clip ops = emitBIO (dragSourceRecord w [] clip ops)

-- | The TEMPLATE builder (docs/dnd-plan.md §4): the reps in canonical
-- order, a bound slot carrying the i64 @level << 32 | field@ under the
-- @bound@ mask. Level 0 is the row this template is stamped for, as it
-- is in every bind*Field binder.
tplDragSourceRecord :: Word64 -> TplClip -> [Op] -> IO Builder
tplDragSourceRecord w clip ops = do
  customValues <-
    concat
      <$> mapM
        ( \(ident, rep) -> case rep of
            TplField (KField i) ->
              return [W.VStr (acceptToken ident), W.VI64 (fromIntegral i)]
            TplConst bytes -> do
              h <- registerBlob bytes
              return [W.VStr (acceptToken ident), W.VBlob h]
        )
        (tplClipCustom clip)
  imageValue <- case tplClipImage clip of
    Nothing -> return []
    Just (TplField (KField i)) -> return [W.VI64 (fromIntegral i)]
    Just (TplConst bytes) -> (: []) . W.VBlob <$> registerBlob bytes
  let strValue rep = case rep of
        TplField (KField i) -> W.VI64 (fromIntegral i)
        TplConst text -> W.VStr text
      present =
        maybe 0 (const W.clipText) (tplClipText clip)
          + maybe 0 (const W.clipHtml) (tplClipHtml clip)
          + maybe 0 (const W.clipImage) (tplClipImage clip)
      files = map (W.VI64 . fromIntegral . pickedHandle) (tplClipFiles clip)
      values =
        customValues
          ++ files
          ++ imageValue
          ++ maybe [] ((: []) . strValue) (tplClipHtml clip)
          ++ maybe [] ((: []) . strValue) (tplClipText clip)
      -- The bound slots BY POSITION, canonical order: a custom pair's
      -- second half, then the image, the html and the text.
      afterCustom = 2 * length (tplClipCustom clip) + length (tplClipFiles clip)
      afterImage = afterCustom + length imageValue
      afterHtml = afterImage + maybe 0 (const 1) (tplClipHtml clip)
      slots =
        [2 * i + 1 | (i, (_, TplField _)) <- zip [0 :: Int ..] (tplClipCustom clip)]
          ++ [afterCustom | isTplField (tplClipImage clip)]
          ++ [afterImage | isTplField (tplClipHtml clip)]
          ++ [afterHtml | isTplField (tplClipText clip)]
      bound = sum [2 ^ s | s <- slots] :: Word32
      empty =
        present == 0 && null (tplClipFiles clip) && null (tplClipCustom clip)
  return
    ( W.txSetDragSource
        w
        present
        (fromIntegral (length (tplClipFiles clip)))
        (fromIntegral (length (tplClipCustom clip)))
        (if empty then 0 else operationMask ops)
        0
        bound
        values
    )

isTplField :: Maybe (TplRep v) -> Bool
isTplField (Just (TplField _)) = True
isTplField _ = False

-- | The one set_drag_source builder the live, template and keyed forms
-- share: KEYS FIRST, then the reps (set_column_headers' convention).
dragSourceRecord :: Word64 -> [W.Value] -> Clip -> [Op] -> IO Builder
dragSourceRecord w keys clip ops = do
  customValues <-
    concat
      <$> mapM
        ( \(ident, bytes) -> do
            h <- registerBlob bytes
            return [W.VStr (acceptToken ident), W.VBlob h]
        )
        (clipCustom clip)
  imageValue <- case clipImage clip of
    Nothing -> return []
    Just bytes -> (: []) . W.VBlob <$> registerBlob bytes
  let present =
        maybe 0 (const W.clipText) (clipText clip)
          + maybe 0 (const W.clipHtml) (clipHtml clip)
          + maybe 0 (const W.clipImage) (clipImage clip)
      files = map (W.VI64 . fromIntegral . pickedHandle) (clipFiles clip)
      values =
        customValues
          ++ files
          ++ imageValue
          ++ maybe [] (\h -> [W.VStr h]) (clipHtml clip)
          ++ maybe [] (\t -> [W.VStr t]) (clipText clip)
      empty = present == 0 && null (clipFiles clip) && null (clipCustom clip)
  return
    ( W.txSetDragSource
        w
        present
        (fromIntegral (length (clipFiles clip)))
        (fromIntegral (length (clipCustom clip)))
        (if empty then 0 else operationMask ops)
        (fromIntegral (length keys))
        0
        (keys ++ values)
    )

-- | DECLARE that a widget receives drops, performing these operations;
-- naming NONE withdraws it. WHAT it takes is its 'setAccepts' list,
-- which must be declared first — a destination has one vocabulary, not
-- two (docs\/dnd-plan.md D1).
setDropTarget :: Widget -> [Op] -> Build ()
setDropTarget (Widget w) ops =
  emitB (W.txSetDropTarget w (operationMask ops) 0 [])

-- | ONE STAMPED COPY's drag declaration (docs\/dnd-plan.md §4): the
-- template node and the copy's keys, outermost first. The per-row
-- payload an app declares after the row's insert; it overrides the
-- template's own for that copy and follows it through a re-stamp.
setDragSourceAt :: Node -> [W.Value] -> Clip -> [Op] -> Build ()
setDragSourceAt (Node n) keys clip ops =
  emitBIO (dragSourceRecord n keys clip ops)

-- | 'setDragSourceAt''s twin: ONE stamped copy receives drops with these
-- operations, taking what the template's 'TplAccepts' names.
setDropTargetAt :: Node -> [W.Value] -> [Op] -> Build ()
setDropTargetAt (Node n) keys ops =
  emitB (W.txSetDropTarget n (operationMask ops) (fromIntegral (length keys)) keys)

-- | Rows of this live For drag within their own collection
-- (docs\/dnd-plan.md D8): the landing arrives at 'onDrop' on the For's
-- own container — the element 'forEach' returns — and the app confirms
-- with a move.
setReorderable :: Widget -> Bool -> Build ()
setReorderable (Widget w) enabled =
  emitB (W.txSetReorderable w (if enabled then 1 else 0))

-- | Ask the platform for files. THE PICK, NOT THE OPEN — the result
-- carries handles you redeem later (DESIGN.md, File dialogs). The
-- filters are (label, space-separated extensions) pairs, ADVISORY on
-- every platform. The handler fires exactly once and retires with its
-- answer; CANCEL IS THE EMPTY LIST, and one dialog may be live per
-- process.
pickFiles :: [(String, String)] -> ([PickedFile] -> IO ()) -> Build ()
pickFiles = pick True

-- | The single-file spelling. The floor always returns a LIST; this
-- only asks the platform for one, so the handler receives zero or one.
pickFile :: [(String, String)] -> ([PickedFile] -> IO ()) -> Build ()
pickFile = pick False

pick :: Bool -> [(String, String)] -> ([PickedFile] -> IO ()) -> Build ()
pick multiple filters handler = do
  n <- Build $ \s ->
    let c = bCounters s
        next = cFileDialog c + 1
     in (next, s {bCounters = c {cFileDialog = next}})
  pendB (PFileDialog n handler)
  emitB
    ( W.txShowFileDialog
        0
        n
        (if multiple then 1 else 0)
        (filterValues filters)
    )

-- | Ask the platform WHERE TO SAVE — the picker's twin, on the same
-- request\/result grammar and out of the same one-live-dialog slot; the
-- handler fires exactly once and CANCEL IS 'Nothing'. Read the name you
-- GOT ('pickedName'), never the one you asked for: no platform promises
-- the suggested one. WHAT YOU GET BACK OPENS EMPTY
-- (docs\/save-plan.md D1; DESIGN.md).
saveFile :: String -> [(String, String)] -> (Maybe PickedFile -> IO ()) -> Build ()
saveFile suggested filters handler = do
  -- THE PICKER'S COUNTER AND THE PICKER'S TABLE, deliberately: the core
  -- has one dialog id space, one live slot and one retire gate, so a
  -- save minting ids of its own could collide with a pick.
  n <- Build $ \s ->
    let c = bCounters s
        next = cFileDialog c + 1
     in (next, s {bCounters = c {cFileDialog = next}})
  pendB (PFileDialog n (handler . listToMaybe))
  emitB (W.txShowSaveDialog 0 n (W.VStr suggested) (filterValues filters))

-- (label, space-separated extensions) pairs, flattened the way the wire
-- carries them.
filterValues :: [(String, String)] -> [W.Value]
filterValues = concatMap (\(label, exts) -> [W.VStr label, W.VStr exts])

-- | Mount a root into the default window; mounting presents.
mount :: Widget -> Build ()
mount (Widget n) = emitB (W.txMount 0 n)

-- | Drop an entry's content now (the field stays authoritative).
clearWidget :: Widget -> Build ()
clearWidget (Widget n) = emitB (W.txWidgetCommand n W.commandClear)

-- | Give this widget the keyboard focus.
focusWidget :: Widget -> Build ()
focusWidget (Widget n) = emitB (W.txWidgetCommand n W.commandFocus)

-- The three text-range verbs (docs\/ranges-plan.md D1). Textarea only.
--
-- A RANGE IS A PAIR OF UTF-8 BYTE OFFSETS, half-open, and HASKELL'S OWN
-- UNIT IS NOT BYTES: a 'String' is a list of 'Char', so @findIndex@ over
-- one counts SCALARS and every offset it returns is wrong for a
-- non-ASCII document, silently. Search the UTF-8 encoding instead —
-- @Data.ByteString.breakSubstring@ over @toLazyByteString . stringUtf8@.

-- | Declare the decorated ranges of a textarea, replacing whatever was
-- declared before; @[]@ is the clear. APP-OWNED AND NEVER TRACKED: the
-- first edit of any kind drops the set, and kaya adjusts no range across
-- an edit (docs\/ranges-plan.md §3).
highlightRanges :: Widget -> [(Int, Int)] -> Build ()
highlightRanges (Widget n) ranges =
  emitB (W.txHighlightRanges n (fromIntegral (length ranges)) (concatMap pair ranges))
  where
    -- One flat Values list read IN PAIRS by the core, start then end;
    -- the count travels beside it and the two must agree.
    pair (start, stop) = [W.VI64 (fromIntegral start), W.VI64 (fromIntegral stop)]

-- | Put the textarea's selection at one range (an empty range is a caret).
-- Same offsets, same validation as 'highlightRanges'. REFUSED WHILE THE USER
-- IS COMPOSING through an input method, in every backend, and the refusal is
-- a no-op rather than an error (docs\/deferred.md).
selectRange :: Widget -> (Int, Int) -> Build ()
selectRange (Widget n) (start, stop) =
  emitB (W.txSelectRange n (fromIntegral start) (fromIntegral stop))

-- | Scroll the textarea so a range is inside the viewport. A pure effect: it
-- moves no state, leaves the selection alone, and undo does not put the
-- scroll position back (undo restores state, not where you were looking).
revealRange :: Widget -> (Int, Int) -> Build ()
revealRange (Widget n) (start, stop) =
  emitB (W.txRevealRange n (fromIntegral start) (fromIntegral stop))

-- | Write a live widget's text: seed an editor's document, re-caption a
-- label. LIVE WIDGETS ONLY — the same write on a template Node is the
-- floor spelling 'setTextProp' (docs\/tpl-props-plan.md F3).
setText :: Widget -> String -> Build ()
setText = setTextProp

bindText :: Widget -> Signal -> Build ()
bindText (Widget w) (Signal s) = emitB (W.txBindText w s)

-- | A container's inter-child gap (main axis, DIP; the normalized default is
-- 8).
setSpacing :: Widget -> Double -> Build ()
setSpacing (Widget w) gap = emitB (W.txSetSpacing w gap)

-- | A container's OWN padding: the DIP between its bounds and its
-- children, uniform on all four sides (docs\/styling-plan.md D3).
-- Containers only, and the ROOT is what says so: a leaf, a negative or
-- a non-finite pad dies at declare time naming the prop. The dynamic
-- path; the declarative spelling is the 'Inset' attr.
setInset :: Widget -> Double -> Build ()
setInset (Widget w) pad = emitB (W.txSetInset w pad)

-- Construction props are a closed GADT indexed by widget class:
-- container-only props on a leaf are type errors before they are scene
-- errors.
data WClass = BoxW | LeafW

-- | A container's cross-axis child placement (the align spec enum; the
-- normalized default is 'AlignStart').
data Align
  = AlignStart
  | AlignCenter
  | AlignEnd
  | AlignStretch
  | AlignBaseline
  deriving (Eq, Show)

alignWire :: Align -> Int64
alignWire AlignStart = 0
alignWire AlignCenter = 1
alignWire AlignEnd = 2
alignWire AlignStretch = 3
alignWire AlignBaseline = 4

-- | The dynamic path; the declarative spelling is the 'Align' attr.
setAlign :: Widget -> Align -> Build ()
setAlign (Widget w) a = emitB (W.txSetAlign w (alignWire a))

-- | A container's arrangement direction: row and column are ONE node
-- this parameterizes, and the creation kind's own is the default
-- (docs\/adaptive-layout-plan.md D1).
data Axis
  = AxisHorizontal
  | AxisVertical
  deriving (Eq, Show)

axisWire :: Axis -> Int64
axisWire AxisHorizontal = fromIntegral W.axisHorizontal
axisWire AxisVertical = fromIntegral W.axisVertical

-- | The user-driven orientation toggle (docs\/adaptive-layout-plan.md
-- D2). Row\/column only; the widget stays what its creation kind made it
-- and only its presentation moves.
setAxis :: Widget -> Axis -> Build ()
setAxis (Widget w) a = emitB (W.txSetAxis w (axisWire a))

-- | A window's named SIZE CLASS (spec enum "size_class"): what
-- 'stackWhen' speaks in place of an author-invented width. 'Compact' is
-- the whole surface today — the platform's own class on iOS, narrower
-- than 600 points everywhere else. An app names a class, it never asks
-- which one the window is.
data SizeClass = Compact

sizeClassWire :: SizeClass -> Int64
sizeClassWire Compact = fromIntegral W.sizeClassCompact

-- | Stack this row's children vertically while the window's SIZE CLASS
-- is the named one, reverting on leaving the class — ONE core-evaluated
-- breakpoint record (docs\/adaptive-layout-plan.md D3). The declarative
-- spelling is the 'StackWhen' attr; taking a 'Widget' is the template
-- zone's refusal, since a breakpoint's setters name live widgets.
stackWhen :: Widget -> SizeClass -> Build ()
stackWhen (Widget w) when =
  emitB
    ( W.txCreateBreakpoint
        0
        (W.VI64 (sizeClassWire when))
        1
        [ W.VI64 (fromIntegral w),
          W.VI64 (fromIntegral W.propAxis),
          W.VI64 (fromIntegral W.axisVertical)
        ]
    )

-- | Lay this grid out in the named number of columns while the window's
-- SIZE CLASS is the named one, restoring the authored count on leaving
-- it (docs\/adaptive-layout-plan.md D6.2). Taking a 'Widget' is the
-- template zone's refusal, as 'stackWhen'\'s is.
columnsWhen :: Widget -> SizeClass -> Int -> Build ()
columnsWhen (Widget w) when columns =
  emitB
    ( W.txCreateBreakpoint
        0
        (W.VI64 (sizeClassWire when))
        1
        [ W.VI64 (fromIntegral w),
          W.VI64 (fromIntegral W.propColumns),
          W.VF64 (fromIntegral columns)
        ]
    )

-- | The role vocabulary (docs/styling-plan.md D4): SEMANTIC EMPHASIS — what a
-- widget MEANS, never how it looks.
data Role
  = -- | An action whose press destroys something. Buttons only.
    Destructive
  | -- | THE primary action, one per dialog's worth of emphasis: the
    -- platform's default-button treatment. Buttons only.
    Prominent
  | -- | A text hierarchy heading — the platform's heading text style AND
    -- the heading trait assistive users skim by. Labels only.
    Heading
  | -- | The heading's counterpart one tier down: the platform's footnote
    -- text, under the content it explains. Labels only.
    Caption
  | -- | An action at low emphasis: a row's accessory (Details, Open).
    -- Buttons only.
    Plain
  deriving (Eq, Show)

roleWire :: Role -> Int64
roleWire Destructive = 1
roleWire Prominent = 2
roleWire Heading = 3
roleWire Caption = 4
roleWire Plain = 5

-- | The dynamic path; the declarative spelling is the 'Role' attr.
setRole :: Widget -> Role -> Build ()
setRole (Widget w) r = emitB (W.txSetRole w (roleWire r))

-- | A widget's accessibility IDENTIFIER: a stable authored key that assistive
-- tooling and UI automation address it by, and which is NEVER spoken.
setA11yId :: Widget -> String -> Build ()
setA11yId (Widget w) i = emitB (W.txSetA11yId w i)

-- | What an assistive client SPEAKS for a widget. Universal, and deliberately
-- separate from the identifier — an automation key is not a spoken name.
-- Leave it unset to keep whatever the platform derives from the control's own
-- content; setting it OVERRIDES that.
setA11yLabel :: Widget -> String -> Build ()
setA11yLabel (Widget w) l = emitB (W.txSetA11yLabel w l)

-- | What ACTIVATING this widget does — the platforms' hint (Apple defines it
-- as the result of performing an action; Android carries it as the click
-- action's label). Write a VERB PHRASE.
setA11yHint :: Widget -> String -> Build ()
setA11yHint (Widget w) h = emitB (W.txSetA11yHint w h)

-- | The SIGNAL-SOURCED forms of the trio, spelled as 'bindText' is.
bindA11yId, bindA11yLabel, bindA11yHint :: Widget -> Signal -> Build ()
bindA11yId (Widget w) (Signal s) = emitB (W.txBindA11yId w s)
bindA11yLabel (Widget w) (Signal s) = emitB (W.txBindA11yLabel w s)
bindA11yHint (Widget w) (Signal s) = emitB (W.txBindA11yHint w s)

-- | A widget's HELP TEXT: one short sentence saying what the control is
-- or does (docs/tooltip-plan.md T1). Universal. The platform picks the
-- surface — a tooltip on the desktops, nothing visible on the iPhone —
-- and hands the text to its assistive reader; an authored hint wins the
-- hint slot (T3).
setHelp :: Widget -> String -> Build ()
setHelp (Widget w) h = emitB (W.txSetHelp w h)

bindHelp :: Widget -> Signal -> Build ()
bindHelp (Widget w) (Signal s) = emitB (W.txBindHelp w s)

-- | What a LIVE widget's Str a11y prop can take: a constant or a signal —
-- the attr picks the setter by the argument's type, as the template
-- zone's 'TplStrSource' does with the row field arm left out.
class LiveStrSource s where
  liveStr :: (Widget -> String -> Build ()) -> (Widget -> Signal -> Build ())
          -> Widget -> s -> Build ()

instance LiveStrSource String where
  liveStr setter _ w v = setter w v

instance LiveStrSource Signal where
  liveStr _ binder w s = binder w s

data Attr (c :: WClass) where
  -- | This widget's flex weight — any widget class.
  Grow :: Double -> Attr c
  -- | Whether this widget spans its container's cross axis — a column's
  -- width, a row's height — whatever the container's 'Align'
  -- (docs\/layout-knobs-plan.md §1). Any widget class, like 'Grow';
  -- unset, the kind's own default holds.
  Fill :: Bool -> Attr c
  -- | This container's inter-child gap (main axis, DIP; the normalized
  -- default is 8).
  Spacing :: Double -> Attr 'BoxW
  -- | This container's own padding, between its bounds and its children — the
  -- window inset one level down.
  Inset :: Double -> Attr 'BoxW
  -- | This container's cross-axis child placement. Containers only,
  -- held by the index like 'Spacing'.
  Align :: Align -> Attr 'BoxW
  -- | Stack this row's children vertically while the window's size
  -- class is the named one. Containers only, and LIVE ZONE ONLY —
  -- 'TplAttr' has no counterpart.
  StackWhen :: SizeClass -> Attr 'BoxW
  -- | This widget's accessibility identifier — any widget class, like
  -- 'Grow': the two accessibility props are universal, so the index
  -- must not narrow them.
  A11yId :: LiveStrSource s => s -> Attr c
  -- | What an assistive client speaks for this widget — any widget
  -- class, for the same reason. A 'String' or a 'Signal'.
  A11yLabel :: LiveStrSource s => s -> Attr c
  -- | What ACTIVATING this widget does. Leaf-class only, unlike the
  -- other two: a hint needs an activation to describe, and the root
  -- admits it on button, checkbox, select and radio alone.
  A11yHint :: LiveStrSource s => s -> Attr 'LeafW
  -- | This widget's HELP TEXT — any widget class, as the two a11y props
  -- are: one short sentence saying what the control is or does. A
  -- 'String' or a 'Signal'.
  Help :: LiveStrSource s => s -> Attr c
  -- | A date picker's inclusive lower bound (docs/datetime-plan.md D4);
  -- a pick past it lands on the bound.
  MinDate :: Day -> Attr 'LeafW
  -- | A date picker's inclusive upper bound.
  MaxDate :: Day -> Attr 'LeafW
  -- | A time picker's minute granularity: 1, 5, 10, 15 or 30 (D3).
  MinuteStep :: Int -> Attr 'LeafW
  -- | The granularity a slider's thumb rests on: min + k * step
  -- (docs\/slider-plan.md S1). Divides the range evenly; 0 is continuous.
  Step :: Double -> Attr 'LeafW
  -- | The distance between a slider's drawn ticks, in value units
  -- (docs\/slider-plan.md S5): divides the range evenly, a multiple of the
  -- step when one is declared; 0 draws none.
  TickSpacing :: Double -> Attr 'LeafW
  -- | What this widget MEANS (docs/styling-plan.md D4) — semantic emphasis,
  -- never appearance.
  Role :: Role -> Attr 'LeafW
  -- | What this widget takes from a paste — the closed kinds by name
  -- ('acceptText' and friends) plus any custom format ids.
  Accepts :: [String] -> Attr c
  -- | What this widget hands over when dragged, and the operations it
  -- allows (docs\/dnd-plan.md D1). 'setDragSource' re-declares it.
  Draggable :: Clip -> [Op] -> Attr c
  -- | This widget receives drops, performing these operations; what it
  -- TAKES is its 'Accepts' list, which must be declared first.
  DropTarget :: [Op] -> Attr c

applyAttr :: Attr c -> Widget -> Build ()
applyAttr (Grow weight) w = setGrow w weight
applyAttr (Fill on) w = setFill w on
applyAttr (Spacing gap) w = setSpacing w gap
applyAttr (Inset pad) w = setInset w pad
applyAttr (Align a) w = setAlign w a
applyAttr (StackWhen when) w = stackWhen w when
applyAttr (A11yId i) w = liveStr setA11yId bindA11yId w i
applyAttr (A11yLabel l) w = liveStr setA11yLabel bindA11yLabel w l
applyAttr (A11yHint h) w = liveStr setA11yHint bindA11yHint w h
applyAttr (Help h) w = liveStr setHelp bindHelp w h
applyAttr (MinDate d) (Widget n) =
  let (y, m, dd) = toGregorian d
   in emitB (W.txSetMinDate n (fromIntegral y) m dd)
applyAttr (MaxDate d) (Widget n) =
  let (y, m, dd) = toGregorian d
   in emitB (W.txSetMaxDate n (fromIntegral y) m dd)
applyAttr (MinuteStep minutes) (Widget n) =
  emitB (W.txSetMinuteStep n (fromIntegral minutes))
applyAttr (Step step) (Widget n) = emitB (W.txSetStep n step)
applyAttr (TickSpacing spacing) (Widget n) = emitB (W.txSetTickSpacing n spacing)
applyAttr (Role r) w = setRole w r
applyAttr (Accepts kinds) w = setAccepts w kinds
applyAttr (Draggable clip ops) w = setDragSource w clip ops
applyAttr (DropTarget ops) w = setDropTarget w ops

withAttrs :: [Attr c] -> Build Widget -> Build Widget
withAttrs attrs act = do
  w <- act
  mapM_ (`applyAttr` w) attrs
  return w

-- One name, both arities — `row [kids]` and `row [Grow 2] [kids]`
-- dispatch on the RESULT type. LIVE ZONE ONLY: an 'Attr' list in
-- template position has no instance, since template props take SOURCES.
class RowCol a r where
  rowish :: Word32 -> [a] -> r

instance (a ~ Build Widget, b ~ Widget) => RowCol a (Build b) where
  rowish = containerOf

-- The wall where someone walks into it: `row [...]` inside a forEach
-- body is the natural thing to write. GHC prints this instead, and the
-- instance body is unreachable because selecting it IS the error.
instance
  ( TypeError
      ( 'Text "kaya: a template row is `rowOf` and a template column is `columnOf`."
          ':$$: 'Text "row/column build in the LIVE zone (Build Widget); the template"
          ':$$: 'Text "zone's containers take Nodes, so they carry their own names."
          ':$$: 'Text "    forEach items $ do { … ; _ <- rowOf [label element, pure b] ; … }"
      ),
    a ~ Tpl Node,
    b ~ Node
  ) =>
  RowCol a (Tpl b)
  where
  rowish = containerOf

instance (a ~ Attr 'BoxW, k ~ Build Widget, r ~ Build Widget) => RowCol a ([k] -> r) where
  rowish kind attrs = withAttrs attrs . containerOf kind

row :: (RowCol a r) => [a] -> r
row = rowish W.kindRow

column :: (RowCol a r) => [a] -> r
column = rowish W.kindColumn

-- | A vertical scroll viewport over EXACTLY ONE child — the signature
-- says so (the scene enforces it too): @scroll [Grow 1] (column
-- [...])@. Give it 'Grow' so the enclosing track CONSTRAINS it — an
-- unconstrained viewport hugs its content and nothing overflows.
scroll :: [Attr 'BoxW] -> Build Widget -> Build Widget
scroll attrs child = withAttrs attrs (containerOf W.kindScroll [child])

-- | A grid from its children, laid out row-major into N columns — each column
-- takes its NATURAL width, aligned across rows (the thing nested rows cannot
-- express).
grid :: Int -> [Build Widget] -> Build Widget
grid = gridWith

gridWith :: (Declare m) => Int -> [m (El m)] -> m (El m)
gridWith columns children = do
  handles <- sequence children
  parent <- widget W.kindGrid
  setColumns parent columns
  mapM_ (addChild parent) handles
  return parent

-- | A LABELLED ROW (docs\/forms-plan.md): the first argument names the one
-- control the children declare, with an optional trailing button after
-- it. A column of nothing but these renders as the platform's form.
labeled :: (LiveStrSource s) => s -> [Build Widget] -> Build Widget
labeled src children = containerOf W.kindLabeled (name : children)
  where
    name = do
      w <- widget W.kindLabel
      liveStr setText bindText w src
      return w

-- | A spacer: PURE SUGAR for an empty grown column — it consumes the
-- leftover main-axis space between its siblings. In EITHER zone.
spacer :: (Declare m) => m (El m)
spacer = do
  w <- widget W.kindColumn
  setGrow w 1.0
  return w

-- The leaf half of the same idiom: every leaf constructor's result is
-- either the widget or a function awaiting its attr list.
class LeafArgs r where
  leafish :: Build Widget -> r

instance (b ~ Widget) => LeafArgs (Build b) where
  leafish = id

instance (a ~ Attr 'LeafW, r ~ Build Widget) => LeafArgs ([a] -> r) where
  leafish act attrs = withAttrs attrs act

bindChecked :: Widget -> Signal -> Build ()
bindChecked (Widget w) (Signal s) = emitB (W.txBindChecked w s)

-- | Bind a slider's position to a float signal — the programmatic write
-- path (property writes never echo an occurrence, so a handler's own
-- writes cannot loop back at it).
bindValue :: Widget -> Signal -> Build ()
bindValue (Widget w) (Signal s) = emitB (W.txBindValue w s)

-- | Bind an image's source to a Blob signal.
bindSource :: Widget -> Signal -> Build ()
bindSource (Widget w) (Signal s) = emitB (W.txBindSource w s)

containerOf :: (Declare m) => Word32 -> [m (El m)] -> m (El m)
containerOf kind children = do
  handles <- sequence children
  parent <- widget kind
  mapM_ (addChild parent) handles
  return parent

pendB :: Pending -> Build ()
pendB pending = Build $ \s -> ((), s {bPending = pending : bPending s})

buttonOn :: (LeafArgs r) => String -> IO () -> r
buttonOn text handler = leafish $ do
  w@(Widget n) <- widget W.kindButton
  setText w text
  pendB (PClick n handler)
  return w

-- The handler-free siblings, with the event slot empty. THE LEAVES THAT
-- STAND IN BOTH ZONES are exactly the ones whose arguments are the same
-- in both — a constant caption, or nothing.
class BothZones r where
  bothish :: (forall m. Declare m => m (El m)) -> r

instance (b ~ Widget) => BothZones (Build b) where
  bothish act = act

instance (b ~ Node) => BothZones (Tpl b) where
  bothish act = act

instance (a ~ Attr 'LeafW, r ~ Build Widget) => BothZones ([a] -> r) where
  bothish act attrs = withAttrs attrs act

captionedButton :: (Declare m) => String -> m (El m)
captionedButton text = do
  w <- widget W.kindButton
  setTextProp w text
  return w

button :: (BothZones r) => String -> r
button text = bothish (captionedButton text)

-- | An uncontrolled single-line field, in either zone. Handler-free by
-- construction: the field owns its text and reports each edit. A
-- template copy that should OPEN holding the row's own text is
-- 'entryBound'.
entry :: (BothZones r) => r
entry = bothish (widget W.kindEntry)

entryOn :: (LeafArgs r) => (String -> IO ()) -> r
entryOn handler = leafish $ do
  w@(Widget n) <- widget W.kindEntry
  pendB (PChange n handler)
  return w

-- | A multi-line editor, in either zone: the entry's uncontrolled
-- contract over the platform's real multi-line control.
textarea :: (BothZones r) => r
textarea = bothish (widget W.kindTextarea)

-- | A multi-line text editor with its change handler co-located:
-- the entry's uncontrolled contract over the platform's real
-- multi-line editor.
textareaOn :: (LeafArgs r) => (String -> IO ()) -> r
textareaOn handler = leafish $ do
  w@(Widget n) <- widget W.kindTextarea
  pendB (PChange n handler)
  return w

-- | A labeled checkbox with its toggle handler co-located.
checkboxOn :: (LeafArgs r) => String -> (Bool -> IO ()) -> r
checkboxOn text handler = leafish $ do
  w@(Widget n) <- widget W.kindCheckbox
  setText w text
  pendB (PToggle n handler)
  return w

-- | A date picker over civil dates holding @day@, with its pick handler
-- co-located (docs/datetime-plan.md): the compact field that opens the
-- platform's calendar. UNCONTROLLED — the control owns its value and
-- reports each COMMITTED pick. 'MinDate' and 'MaxDate' are the range.
datePickerOn :: (LeafArgs r) => Day -> (Day -> IO ()) -> r
datePickerOn day handler = leafish $ do
  w@(Widget n) <- widget W.kindDatePicker
  let (y, m, d) = toGregorian day
  emitB (W.txSetDate n (fromIntegral y) m d)
  pendB (PDate n handler)
  return w

-- | A date picker whose VALUE follows a signal — the programmatic write
-- path; property writes never echo.
datePickerBoundOn :: (LeafArgs r) => Signal -> (Day -> IO ()) -> r
datePickerBoundOn (Signal s) handler = leafish $ do
  w@(Widget n) <- widget W.kindDatePicker
  emitB (W.txBindDate n s)
  pendB (PDate n handler)
  return w

-- | A time picker over civil times: hours and minutes, no seconds.
-- 'MinuteStep' is the granularity and a pick snaps to it.
timePickerOn :: (LeafArgs r) => TimeOfDay -> (TimeOfDay -> IO ()) -> r
timePickerOn t handler = leafish $ do
  w@(Widget n) <- widget W.kindTimePicker
  emitB (W.txSetTime n (todHour t) (todMin t))
  pendB (PTime n handler)
  return w

-- | A time picker whose value follows a signal.
timePickerBoundOn :: (LeafArgs r) => Signal -> (TimeOfDay -> IO ()) -> r
timePickerBoundOn (Signal s) handler = leafish $ do
  w@(Widget n) <- widget W.kindTimePicker
  emitB (W.txBindTime n s)
  pendB (PTime n handler)
  return w

-- | A progress bar: display-only, like label and image — the
-- determinate fraction (0..=1).
progress :: (LeafArgs r) => Double -> r
progress fraction = leafish $ do
  w <- widget W.kindProgress
  let (Widget n) = w
  emitB (W.txSetValue n fraction)
  return w

-- | A progress bar in the platform's activity mode (no fraction), in
-- either zone — with no fraction there is nothing to source, so this is
-- one of the constructors whose two zones take the same nothing.
progressIndeterminate :: (BothZones r) => r
progressIndeterminate =
  bothish $ do
    w <- widget W.kindProgress
    setIndeterminate w True
    return w

-- | A slider over min..max at value, with its change handler
-- co-located.
sliderOn :: (LeafArgs r) => Double -> Double -> Double -> (Double -> IO ()) -> r
sliderOn lo hi value handler = leafish $ do
  w@(Widget n) <- widget W.kindSlider
  emitB (W.txSetMin n lo)
  emitB (W.txSetMax n hi)
  emitB (W.txSetValue n value)
  pendB (PValue n handler)
  return w

-- | A slider whose POSITION follows a float signal, with its change handler
-- co-located: 'sliderOn' with the value bound instead of constant.
sliderBoundOn :: (LeafArgs r) => Double -> Double -> Signal -> (Double -> IO ()) -> r
sliderBoundOn lo hi sig handler = leafish $ do
  w@(Widget n) <- widget W.kindSlider
  emitB (W.txSetMin n lo)
  emitB (W.txSetMax n hi)
  bindValue w sig
  pendB (PValue n handler)
  return w

-- | A dropdown select over fixed options — each option becomes a label
-- child (labels only, scene-checked) — at the given initial 0-based
-- index (domain-checked at the root), with its pick handler co-located:
-- the handler receives each USER pick's new index (programmatic writes
-- never echo).
selectOn :: (LeafArgs r) => [String] -> Int -> (Int -> IO ()) -> r
selectOn options selected handler = leafish $ do
  w@(Widget n) <- widget W.kindSelect
  mapM_
    ( \optionText -> do
        o <- widget W.kindLabel
        setText o optionText
        addChild w o
    )
    options
  emitB (W.txSetValue n (fromIntegral selected))
  pendB (PValue n (handler . round))
  return w

-- | A radio group over fixed options — the choice contract
-- ('selectOn') in its inline presentation: same option children,
-- same 0-based index, same pick handler.
radioOn :: (LeafArgs r) => [String] -> Int -> (Int -> IO ()) -> r
radioOn options selected handler = leafish $ do
  w@(Widget n) <- widget W.kindRadio
  mapM_
    ( \optionText -> do
        o <- widget W.kindLabel
        setText o optionText
        addChild w o
    )
    options
  emitB (W.txSetValue n (fromIntegral selected))
  pendB (PValue n (handler . round))
  return w

labelText :: (LeafArgs r) => String -> r
labelText text = leafish $ do
  w <- widget W.kindLabel
  setText w text
  return w

labelBound :: (LeafArgs r) => Signal -> r
labelBound sig = leafish $ do
  w <- widget W.kindLabel
  bindText w sig
  return w

-- | A label wearing 'Heading', in one word (the h1 tradition): the
-- platform's heading text style AND the trait assistive users skim by,
-- and on a grouped screen the section-header seat.
headingText :: (LeafArgs r) => String -> r
headingText text = leafish $ do
  w <- labelText text
  setRole w Heading
  return w

-- | 'headingText' with the text bound, as 'labelBound' is to 'labelText'.
headingBound :: (LeafArgs r) => Signal -> r
headingBound sig = leafish $ do
  w <- labelBound sig
  setRole w Heading
  return w

-- | A label wearing 'Caption': the platform's footnote tier under the
-- content it explains, and the section-footer seat. The heading's
-- counterpart.
captionText :: (LeafArgs r) => String -> r
captionText text = leafish $ do
  w <- labelText text
  setRole w Caption
  return w

-- | 'captionText' with the text bound.
captionBound :: (LeafArgs r) => Signal -> r
captionBound sig = leafish $ do
  w <- labelBound sig
  setRole w Caption
  return w

-- | An image displaying constant encoded bytes (PNG, JPEG, ...): the toolkit
-- decodes natively, and decode failure renders the placeholder, never a
-- crash.
imageBytes :: (LeafArgs r) => BS.ByteString -> r
imageBytes bytes = leafish $ do
  w@(Widget n) <- widget W.kindImage
  emitBIO (W.txSetSource n <$> registerBlob bytes)
  return w

-- | The ASSET form of the source slot: the same image, with the picture
-- NAMED rather than read. THE BYTES NEVER ENTER THIS GUEST'S HEAP: the
-- core clones one refcount into the blob table.
imageAsset :: (LeafArgs r) => Asset -> r
imageAsset src = leafish $ do
  w@(Widget n) <- widget W.kindImage
  emitBIO (W.txSetSource n <$> R.assetBlob src)
  return w

-- | An image whose source follows a Blob signal.
imageBound :: (LeafArgs r) => Signal -> r
imageBound sig = leafish $ do
  w <- widget W.kindImage
  bindSource w sig
  return w

-- THE CANVAS (docs/canvas-plan.md §2.2): 'DrawOp' holds one opcode and
-- its operands already encoded, which is what the wire carries anyway.

-- | A canvas's coordinate system AND its natural size in
-- device-independent points (docs/canvas-plan.md §3.2). The op stream is
-- written in these units on every platform and in every language, so a
-- scene can freeze it.
data Viewbox = Viewbox Double Double

-- | The paint ROLE an op names. Never RGB: the roles resolve in the core
-- per appearance (§3.4).
data Paint = Series | SeriesFill | Grid | Axis | Ground

paintWire :: Paint -> Int64
paintWire p = fromIntegral $ case p of
  Series -> W.paintSeries
  SeriesFill -> W.paintSeriesFill
  Grid -> W.paintGrid
  Axis -> W.paintAxis
  Ground -> W.paintGround

-- | Which way a fill resolves its own crossings.
data FillRule = Nonzero | EvenOdd

fillRuleWire :: FillRule -> Int64
fillRuleWire r = fromIntegral $ case r of
  Nonzero -> W.fillRuleNonzero
  EvenOdd -> W.fillRuleEvenOdd

-- | SVG's @text-anchor@: which end of the run sits at the anchor point.
-- Spelled @Anchor*@ because @AlignStart@ and @AlignEnd@ are 'Align''s.
data TextAlign = AnchorStart | AnchorMiddle | AnchorEnd

textAlignWire :: TextAlign -> Int64
textAlignWire a = fromIntegral $ case a of
  AnchorStart -> W.textAlignStart
  AnchorMiddle -> W.textAlignMiddle
  AnchorEnd -> W.textAlignEnd

-- | SVG's @dominant-baseline@: which horizontal line of the run sits at
-- the anchor point.
data TextBaseline
  = BaselineAlphabetic
  | BaselineMiddle
  | BaselineTop
  | BaselineBottom

textBaselineWire :: TextBaseline -> Int64
textBaselineWire b = fromIntegral $ case b of
  BaselineAlphabetic -> W.textBaselineAlphabetic
  BaselineMiddle -> W.textBaselineMiddle
  BaselineTop -> W.textBaselineTop
  BaselineBottom -> W.textBaselineBottom

-- | One drawing op: an opcode and its operands, already the tagged values
-- the wire carries. Opaque — the constructors below are the vocabulary.
newtype DrawOp = DrawOp [W.Value]

drawOp :: Word32 -> [W.Value] -> DrawOp
drawOp code operands = DrawOp (W.VI64 (fromIntegral code) : operands)

-- | Start a subpath at (x, y).
moveTo :: Double -> Double -> DrawOp
moveTo x y = drawOp W.drawOpMoveTo [W.VF64 x, W.VF64 y]

-- | Extend the current subpath to (x, y).
lineTo :: Double -> Double -> DrawOp
lineTo x y = drawOp W.drawOpLineTo [W.VF64 x, W.VF64 y]

-- | Close the current subpath.
close :: DrawOp
close = drawOp W.drawOpClose []

-- | 'moveTo' the first point and 'lineTo' the rest — the chart's own
-- shape, spelled once.
polyline :: [(Double, Double)] -> [DrawOp]
polyline points =
  [if i == (0 :: Int) then moveTo x y else lineTo x y | (i, (x, y)) <- zip [0 ..] points]

-- | Stroke the built path and clear it. The width is in
-- device-independent points and does NOT carry the viewbox stretch, so a
-- 1pt gridline is 1pt at every canvas size (§3.2).
stroke :: Paint -> Double -> DrawOp
stroke paint width = drawOp W.drawOpStroke [W.VI64 (paintWire paint), W.VF64 width]

-- | Fill the built path and clear it.
fill :: Paint -> FillRule -> DrawOp
fill paint rule =
  drawOp W.drawOpFill [W.VI64 (paintWire paint), W.VI64 (fillRuleWire rule)]

-- | Select the face for subsequent text ops. The asset is an ordinary
-- asset name; @""@ is kaya's own embedded default face, which is why a
-- canvas can always draw text (§4.2). The size is in device-independent
-- points.
font :: String -> Double -> Int64 -> DrawOp
font src size weight =
  drawOp W.drawOpFont [W.VStr src, W.VF64 size, W.VI64 weight]

-- | Draw ONE LINE with its anchor at (x, y). A line break in the string
-- is refused by the core (§3.3).
text :: Double -> Double -> String -> Paint -> TextAlign -> TextBaseline -> DrawOp
text x y s paint align baseline =
  drawOp
    W.drawOpText
    [ W.VF64 x,
      W.VF64 y,
      W.VI64 (paintWire paint),
      W.VI64 (textAlignWire align),
      W.VI64 (textBaselineWire baseline),
      W.VStr s
    ]

-- One drawing, framed: KEYS FIRST, then the op stream — TX 46's Values
-- order (docs/canvas-plan.md §3.1).
drawingRecord :: Word64 -> [W.Value] -> Viewbox -> [DrawOp] -> Builder
drawingRecord n keys (Viewbox w h) ops =
  W.txSetDrawing
    n
    (W.VF64 w)
    (W.VF64 h)
    (fromIntegral (length flat))
    (fromIntegral (length keys))
    (keys ++ flat)
  where
    flat = concat [vs | DrawOp vs <- ops]

-- | A drawing surface, and the whole drawing with it: the op list
-- replaces whatever was declared before, never patches it. The viewbox
-- is the coordinate system the ops are written in AND the canvas's
-- natural size in points (§3.2).
canvas :: (LeafArgs r) => Viewbox -> [DrawOp] -> r
canvas vb ops = leafish $ do
  w@(Widget n) <- widget W.kindCanvas
  emitB (drawingRecord n [] vb ops)
  return w

-- | THIS CANVAS REFUSES COERCION: it draws at its viewbox and is placed
-- in whatever track layout gives it (docs\/canvas-plan.md §3.2.1). A
-- canvas that declares none of 'fixed', 'onDraw' and 'onTick' is
-- @scale@.
fixed :: Widget -> Build ()
fixed (Widget w) = emitB (W.txSetSizePolicy w W.sizePolicyFixed)

-- | THIS CANVAS'S DRAWING IS A FUNCTION OF ITS SIZE (docs\/canvas-plan.md
-- §3.2.1): registering IS the declaration, so this also puts the policy
-- on the wire, and the size handed over IS the drawing's viewbox. The
-- ask never reaches the guest as an occurrence — 'dispatchLoop' answers
-- it in a transaction the BINDING opens (tools\/check-ambient-tx.py).
-- LIVE CANVASES ONLY; the argument type is the refusal.
onDraw :: App -> Widget -> (Viewbox -> [DrawOp]) -> IO ()
onDraw app w f = registerDraw app w W.sizePolicyRedraw (\size _ -> f size)

-- | The same, on the platform's FRAME CLOCK: the function is handed the
-- assigned size and the frame's time in seconds; a ticking canvas is
-- asked as a plain redraw once before its first frame and answers at
-- time 0. THE TIME IS THE PLATFORM'S — a guest that reads its own clock
-- re-imports the frame jitter frame times exist to remove.
onTick :: App -> Widget -> (Viewbox -> Double -> [DrawOp]) -> IO ()
onTick app w f = registerDraw app w W.sizePolicyTick f

-- REGISTERING AND DECLARING ARE ONE ACT: a handler without its policy
-- record is a drawing function nothing ever calls (docs/canvas-plan.md
-- §3.2.1's ruling 1). The handler is widened HERE, so the answer path
-- never asks which policy it holds.
registerDraw :: App -> Widget -> Word32 -> (Viewbox -> Double -> [DrawOp]) -> IO ()
registerDraw app (Widget n) policy f = do
  modifyIORef' (appDraws app) (Map.insert n f)
  submitTx app (emitB (W.txSetSizePolicy n policy))

pendT :: Pending -> Tpl ()
pendT pending = Tpl $ \s -> ((), s {bPending = pending : bPending s})

-- One Str prop's three generated emitters: const, signal, element.
data StrProp = StrProp
  { strConst :: Word64 -> String -> Builder,
    strSignal :: Word64 -> Word64 -> Builder,
    strElement :: Word64 -> Word32 -> Word32 -> Builder
  }

textProp, a11yIdProp, a11yLabelProp, a11yHintProp, helpProp :: StrProp
textProp = StrProp W.txSetText W.txBindText W.txBindTextElement
a11yIdProp = StrProp W.txSetA11yId W.txBindA11yId W.txBindA11yIdElement
a11yLabelProp = StrProp W.txSetA11yLabel W.txBindA11yLabel W.txBindA11yLabelElement
a11yHintProp = StrProp W.txSetA11yHint W.txBindA11yHint W.txBindA11yHintElement
helpProp = StrProp W.txSetHelp W.txBindHelp W.txBindHelpElement

-- | What a template Str prop can bind to: a constant, a signal, or the
-- ROW'S OWN field. Named for the prop's VALUE TYPE, the wire's
-- @ValueType::Str@.
class TplStrSource s where
  bindStrSource :: StrProp -> Node -> s -> Tpl ()

instance TplStrSource String where
  bindStrSource p (Node n) text = emitT (strConst p n text)

instance TplStrSource Signal where
  bindStrSource p (Node n) (Signal s) = emitT (strSignal p n s)

-- The LEVEL IS 0, as it is in the four bind*Field binders: reaching
-- past the innermost For has no sugar spelling in this binding.
instance TplStrSource (KField String) where
  bindStrSource p (Node n) (KField i) = emitT (strElement p n 0 i)

-- | The text prop's binder, which every text-carrying constructor in
-- this zone goes through.
bindTextSource :: TplStrSource s => Node -> s -> Tpl ()
bindTextSource = bindStrSource textProp

-- | What a template checkbox's state can bind to.
class TplBoolSource s where
  bindCheckedSource :: Node -> s -> Tpl ()

instance TplBoolSource Bool where
  bindCheckedSource (Node n) checked = emitT (W.txSetChecked n checked)

instance TplBoolSource Signal where
  bindCheckedSource (Node n) (Signal s) = emitT (W.txBindChecked n s)

instance TplBoolSource (KField Bool) where
  bindCheckedSource n fd = bindCheckedField n 0 fd

-- | What a template date picker's value can bind to: a constant, a
-- signal, or the row's own Date field (docs/datetime-plan.md D10). The
-- 'KField' instance is 'KField Day' and not 'KField Int64', which is
-- what keeps a picker off the integer field it shares a tag with.
class TplDateSource s where
  bindDateSource :: Node -> s -> Tpl ()

instance TplDateSource Day where
  bindDateSource (Node n) day =
    let (y, m, d) = toGregorian day in emitT (W.txSetDate n (fromIntegral y) m d)

instance TplDateSource Signal where
  bindDateSource (Node n) (Signal s) = emitT (W.txBindDate n s)

instance TplDateSource (KField Day) where
  bindDateSource n fd = bindDateField n 0 fd

-- | The time picker's three sources.
class TplTimeSource s where
  bindTimeSource :: Node -> s -> Tpl ()

instance TplTimeSource TimeOfDay where
  bindTimeSource (Node n) t = emitT (W.txSetTime n (todHour t) (todMin t))

instance TplTimeSource Signal where
  bindTimeSource (Node n) (Signal s) = emitT (W.txBindTime n s)

instance TplTimeSource (KField TimeOfDay) where
  bindTimeSource n fd = bindTimeField n 0 fd

-- | What a template image's source can bind to: constant bytes (the
-- registration runs at the transaction boundary, inside the template
-- scope's records), a Blob signal, or an element's Blob field.
class TplImageSource s where
  bindImageSource :: Node -> s -> Tpl ()

instance TplImageSource BS.ByteString where
  bindImageSource (Node n) bytes = emitTIO (W.txSetSource n <$> registerBlob bytes)

instance TplImageSource Signal where
  bindImageSource (Node n) (Signal s) = emitT (W.txBindSource n s)

instance TplImageSource (KField BS.ByteString) where
  bindImageSource n fd = bindSourceField n 0 fd

-- | What a template F64 prop can bind to: a progress bar's fraction, a
-- slider's position, a choice's selected index. The 'KField' instance is
-- Double-ONLY, because Prop::Value is an F64 slot. A NUMERIC LITERAL
-- NEEDS ITS TYPE SAID OUT LOUD here and nowhere else — @progressBound
-- (0.5 :: Double)@ — since GHC defaults only when every class in the
-- constraint set is standard.
class TplNumberSource s where
  bindValueSource :: Node -> s -> Tpl ()

instance TplNumberSource Double where
  bindValueSource (Node n) x = emitT (W.txSetValue n x)

instance TplNumberSource Signal where
  bindValueSource (Node n) (Signal s) = emitT (W.txBindValue n s)

instance TplNumberSource (KField Double) where
  bindValueSource n fd = bindValueField n 0 fd

-- | Props on a TEMPLATE node — the live 'Attr' one zone down, attached by
-- 'withTplAttrs'. WHERE 'Attr' TAKES A VALUE, THIS TAKES A SOURCE, because
-- each stamped copy's prop can come from its own row.
data TplAttr where
  -- | This stamped element's flex weight within its row\/column. A
  -- CONSTANT and not a source: every copy of one blueprint divides its
  -- parent the same way.
  TplGrow :: Double -> TplAttr
  -- | Whether this stamped element spans its container's cross axis. A
  -- CONSTANT and not a source, for 'TplGrow''s reason.
  TplFill :: Bool -> TplAttr
  -- | This stamped CONTAINER's own padding, in layout units — the
  -- window inset two levels up and the live 'Inset' one zone down, the
  -- same number and the same prop.
  TplInset :: Double -> TplAttr
  -- | This stamped copy's accessibility IDENTIFIER — the authored key
  -- automation addresses it by, never spoken.
  TplA11yId :: TplStrSource s => s -> TplAttr
  -- | What an assistive client SPEAKS for this stamped copy. THE
  -- ROW-FIELD CASE IS WHY THIS PROP EXISTS: @TplA11yLabel (field
  -- \@"title" \@Task)@ makes every row announce its own name.
  TplA11yLabel :: TplStrSource s => s -> TplAttr
  -- | What ACTIVATING this stamped copy does — a verb phrase.
  -- ACTIVATION KINDS ONLY (button, checkbox, select, radio); the refusal
  -- is the ROOT'S, at declare time, naming the kind it refused.
  TplA11yHint :: TplStrSource s => s -> TplAttr
  -- | This stamped copy's HELP TEXT. THE ROW-FIELD CASE IS WHY THIS PROP
  -- REACHES THE ZONE: @TplHelp (field \@"note" \@Account)@ explains every
  -- copy in its own words.
  TplHelp :: TplStrSource s => s -> TplAttr
  -- | What this stamped copy MEANS — semantic emphasis, never
  -- appearance. A CONSTANT; which role fits which kind is the ROOT'S
  -- call.
  TplRole :: Role -> TplAttr
  -- | A stamped slider's granularity (docs\/slider-plan.md S1): constant
  -- across the copies, like the range.
  TplStep :: Double -> TplAttr
  -- | A stamped slider's tick spacing (docs\/slider-plan.md S5), constant
  -- for 'TplStep''s reason.
  TplTickSpacing :: Double -> TplAttr
  -- | What this stamped copy takes from a paste — the closed kinds by
  -- name plus any custom format ids. A CONSTANT LIST AND NOT A SOURCE.
  -- Every backend gates the paste occurrence on the focused widget's
  -- accept list, so without this 'onPaste' at a Node could never fire
  -- (docs\/tpl-props-plan.md §1).
  TplAccepts :: [String] -> TplAttr
  -- | What every stamped copy of this node hands over when dragged, and
  -- the operations it allows, carried with each copy's own identity —
  -- each representation a constant or the ROW'S OWN FIELD
  -- (docs\/dnd-plan.md §4). A copy's OWN payload, constants only, is
  -- 'setDragSourceAt' after its insert.
  TplDraggable :: TplClip -> [Op] -> TplAttr
  -- | Every stamped copy of this node receives drops, performing these
  -- operations; what it TAKES is its 'TplAccepts' list. The landing
  -- arrives at 'onDrop' on the Node, with the copy's keys.
  TplDropTarget :: [Op] -> TplAttr

applyTplAttr :: TplAttr -> Node -> Tpl ()
applyTplAttr (TplGrow weight) n = setGrow n weight
applyTplAttr (TplFill on) n = setFill n on
applyTplAttr (TplInset pad) n = setNodeInset n pad
applyTplAttr (TplA11yId src) n = bindStrSource a11yIdProp n src
applyTplAttr (TplA11yLabel src) n = bindStrSource a11yLabelProp n src
applyTplAttr (TplA11yHint src) n = bindStrSource a11yHintProp n src
applyTplAttr (TplHelp src) n = bindStrSource helpProp n src
applyTplAttr (TplRole r) n = setNodeRole n r
applyTplAttr (TplStep step) (Node n) = emitT (W.txSetStep n step)
applyTplAttr (TplTickSpacing spacing) (Node n) = emitT (W.txSetTickSpacing n spacing)
applyTplAttr (TplAccepts kinds) n = setNodeAccepts n kinds
applyTplAttr (TplDraggable clip ops) n = setNodeDragSource n clip ops
applyTplAttr (TplDropTarget ops) n = setNodeDropTarget n ops

setNodeAccepts :: Node -> [String] -> Tpl ()
setNodeAccepts (Node n) kinds = emitT (W.txSetAccepts n (acceptList kinds))

-- | The dynamic path under 'TplDraggable'; a withdraw needs it.
setNodeDragSource :: Node -> TplClip -> [Op] -> Tpl ()
setNodeDragSource (Node n) clip ops = emitTIO (tplDragSourceRecord n clip ops)

-- | The dynamic path under 'TplDropTarget'.
setNodeDropTarget :: Node -> [Op] -> Tpl ()
setNodeDropTarget (Node n) ops =
  emitT (W.txSetDropTarget n (operationMask ops) 0 [])

setNodeInset :: Node -> Double -> Tpl ()
setNodeInset (Node n) pad = emitT (W.txSetInset n pad)

setNodeRole :: Node -> Role -> Tpl ()
setNodeRole (Node n) r = emitT (W.txSetRole n (roleWire r))

-- | Props on a template node. A COMBINATOR AND NOT AN EXTRA ARITY: a
-- second 'BothZones' instance at the @[a] -> r@ head is GHC-59692
-- "Duplicate instance declarations", and every constructor's
-- @-> Tpl Node@ signature is what tools\/tpl-surfaces.py reads.
withTplAttrs :: [TplAttr] -> Tpl Node -> Tpl Node
withTplAttrs attrs act = do
  n <- act
  mapM_ (`applyTplAttr` n) attrs
  return n

label :: TplStrSource s => s -> Tpl Node
label src = do
  n <- widget W.kindLabel
  bindTextSource n src
  return n

-- | A stamped label wearing 'Heading', in one word: the row's own
-- section title, styled and announced as a heading.
heading :: TplStrSource s => s -> Tpl Node
heading src = do
  n <- label src
  setNodeRole n Heading
  return n

-- | Its counterpart, stamped: the footnote under the content it
-- explains.
caption :: TplStrSource s => s -> Tpl Node
caption src = do
  n <- label src
  setNodeRole n Caption
  return n

checkbox :: TplBoolSource s => s -> ([W.Value] -> Bool -> IO ()) -> Tpl Node
checkbox src handler = do
  n@(Node i) <- widget W.kindCheckbox
  bindCheckedSource n src
  pendT (PToggleNode i handler)
  return n

-- | A template image; decode failure renders the placeholder, never a
-- crash, on every backend.
-- | A stamped date picker over an addressable source, with its pick
-- handler co-located; the handler receives the copy's keys first.
datePicker :: TplDateSource s => s -> ([W.Value] -> Day -> IO ()) -> Tpl Node
datePicker src handler = do
  n@(Node i) <- widget W.kindDatePicker
  bindDateSource n src
  pendT (PDateNode i handler)
  return n

-- | A stamped time picker; the date picker's contract, hours and minutes.
timePicker :: TplTimeSource s => s -> ([W.Value] -> TimeOfDay -> IO ()) -> Tpl Node
timePicker src handler = do
  n@(Node i) <- widget W.kindTimePicker
  bindTimeSource n src
  pendT (PTimeNode i handler)
  return n

image :: TplImageSource s => s -> Tpl Node
image src = do
  n <- widget W.kindImage
  bindImageSource n src
  return n

-- | A stamped button whose caption comes from an addressable source — a
-- signal, or the ROW'S OWN field, which is the thing @button "text"@ cannot
-- say and the thing a list of named actions wants ("Delete <title>").
buttonBound :: TplStrSource s => s -> Tpl Node
buttonBound src = do
  n <- widget W.kindButton
  bindTextSource n src
  return n

-- | A stamped entry SEEDED from an addressable source: the copy opens
-- holding the row's own text. STILL UNCONTROLLED — the field owns its
-- text from the first keystroke and the source keeps writing, so seed
-- from a field the app does NOT write back to, or the caret moves while
-- the user types.
entryBound :: TplStrSource s => s -> Tpl Node
entryBound src = do
  n <- widget W.kindEntry
  bindTextSource n src
  return n

-- | A stamped textarea seeded from an addressable source;
-- 'entryBound''s contract over the multi-line control.
textareaBound :: TplStrSource s => s -> Tpl Node
textareaBound src = do
  n <- widget W.kindTextarea
  bindTextSource n src
  return n

-- | A template row: the live 'row' one zone down, taking NODES.
rowOf :: [Tpl Node] -> Tpl Node
rowOf = containerOf W.kindRow

-- | A template column.
columnOf :: [Tpl Node] -> Tpl Node
columnOf = containerOf W.kindColumn

-- | A template scroll viewport over EXACTLY ONE child — the signature says
-- so, as the live 'scroll''s does.
scrollOf :: Tpl Node -> Tpl Node
scrollOf child = containerOf W.kindScroll [child]

-- | A template grid, laying each stamped copy's children row-major into
-- @columns@ columns. The count describes the PROTOTYPE and stays a
-- constant.
gridOf :: Int -> [Tpl Node] -> Tpl Node
gridOf = gridWith

-- | A LABELLED ROW per stamped copy — the live 'labeled' one zone down,
-- taking Nodes: the source names the one control the children declare,
-- with an optional trailing button after it.
labeledOf :: TplStrSource s => s -> [Tpl Node] -> Tpl Node
labeledOf src children = containerOf W.kindLabeled (label src : children)

-- | A canvas per stamped copy — a sparkline in a table cell, the case
-- set_drawing grew its keys-first addressing for (docs/canvas-plan.md
-- §3.1). The drawing is declared with the node, so every copy is born
-- with it; 'drawAt' re-declares one copy's afterwards.
--
-- NO SIZE POLICY HERE, and the type is the refusal: a stamped copy keeps
-- @scale@ (docs/deferred.md, the size-policy entry).
canvasOf :: Viewbox -> [DrawOp] -> Tpl Node
canvasOf vb ops = do
  n@(Node i) <- widget W.kindCanvas
  emitT (drawingRecord i [] vb ops)
  return n

-- | A stamped progress bar whose fraction follows an addressable source — the
-- per-row case this zone exists for, @progressBound (field \@"done" \@Task)@.
progressBound :: TplNumberSource s => s -> Tpl Node
progressBound src = do
  n <- widget W.kindProgress
  bindValueSource n src
  return n

-- | A stamped slider over @lo@..@hi@ whose POSITION comes from a source.
slider :: TplNumberSource s => Double -> Double -> s -> Tpl Node
slider lo hi src = do
  n@(Node i) <- widget W.kindSlider
  emitT (W.txSetMin i lo)
  emitT (W.txSetMax i hi)
  bindValueSource n src
  return n

-- | A stamped dropdown over fixed options — each option becomes a label child
-- — with the SELECTED 0-based index from a source.
select :: TplNumberSource s => [String] -> s -> Tpl Node
select = choiceWith W.kindSelect

-- | A stamped radio group: 'select''s contract in its inline
-- presentation — same option children, same index, same registrar.
radio :: TplNumberSource s => [String] -> s -> Tpl Node
radio = choiceWith W.kindRadio

-- The options are built CHILDREN-FIRST — declare the label, set its
-- text, then addChild. gtk.rs reads an option's text AT the AddChild, so
-- a text set afterwards arrives too late (docs/traps.md, "prop writes
-- before AddChild").
choiceWith :: TplNumberSource s => Word32 -> [String] -> s -> Tpl Node
choiceWith kind options src = do
  n <- widget kind
  mapM_
    ( \optionText -> do
        o <- widget W.kindLabel
        setTextProp o optionText
        addChild n o
    )
    options
  bindValueSource n src
  return n

-- | A For as a child: forEach whose body keeps no handles — the common
-- case once handlers co-locate at their constructors.
each :: Declare m => Collection -> Tpl a -> m (El m)
each c body = fst <$> forEach c body

-- | The header bar's sort indicator (docs/tables-plan.md): which column
-- shows it, in which direction — re-sent with the new state after the
-- guest handles a sort request. The platform never sorts; a header click
-- only asks.
data Sort = Sort {sortColumn :: Word32, sortDirection :: Word32}

sortNone :: Sort
sortNone = Sort 0xFFFFFFFF 0

sortAsc :: Int -> Sort
sortAsc column = Sort (fromIntegral column) 0

sortDesc :: Int -> Sort
sortDesc column = Sort (fromIntegral column) 1

-- | Re-declare ONE stamped copy's drawing: the canvas template Node plus
-- that copy's keys, outermost first. An empty key list re-declares the
-- drawing every copy is born with, which is what 'canvasOf' spells at
-- declaration time (docs/canvas-plan.md §3.1).
drawAt :: Node -> [W.Value] -> Viewbox -> [DrawOp] -> Build ()
drawAt (Node n) keys vb ops = emitB (drawingRecord n keys vb ops)

-- | Re-declare ONE stamped copy's header bar: the table's template Node
-- plus that copy's keys, outermost first. An empty key list re-declares
-- the bar for every copy. The core walls the template bar being declared
-- first.
columnsAt :: Node -> [W.Value] -> [String] -> Sort -> Build ()
columnsAt (Node n) keys titles sort =
  emitB
    ( W.txSetColumnHeaders
        n
        (sortColumn sort)
        (sortDirection sort)
        (fromIntegral (length titles))
        (fromIntegral (length keys))
        -- Keys FIRST, then the titles (the record's own convention).
        (keys ++ map W.VStr titles)
    )

-- Sums: the data declaration is the sum. (tools/check-sugar-surface.py
-- scans columnsAt up to THIS line, so the sentence is load-bearing.)

class GSum f where
  gsCount :: proxy f -> Word32
  gsSchemas :: proxy f -> [[Word32]]
  gsVariant :: f p -> Word32
  gsToValues :: f p -> [W.Value]
  gsFromParts :: Word32 -> [W.Value] -> f p

instance GSum f => GSum (M1 D c f) where
  gsCount _ = gsCount (Proxy :: Proxy f)
  gsSchemas _ = gsSchemas (Proxy :: Proxy f)
  gsVariant (M1 x) = gsVariant x
  gsToValues (M1 x) = gsToValues x
  gsFromParts v vs = M1 (gsFromParts v vs)

instance (GSum a, GSum b) => GSum (a :+: b) where
  gsCount _ = gsCount (Proxy :: Proxy a) + gsCount (Proxy :: Proxy b)
  gsSchemas _ = gsSchemas (Proxy :: Proxy a) ++ gsSchemas (Proxy :: Proxy b)
  gsVariant (L1 x) = gsVariant x
  gsVariant (R1 x) = gsCount (Proxy :: Proxy a) + gsVariant x
  gsToValues (L1 x) = gsToValues x
  gsToValues (R1 x) = gsToValues x
  gsFromParts v vs
    | v < gsCount (Proxy :: Proxy a) = L1 (gsFromParts v vs)
    | otherwise = R1 (gsFromParts (v - gsCount (Proxy :: Proxy a)) vs)

-- The sum-of-records shape: each constructor wraps exactly one record
-- type, so the constructor's schema is the inner record's and the
-- per-constructor field tokens are the inner record's own.
instance KayaRecord inner => GSum (M1 C c (M1 S sc (K1 R inner))) where
  gsCount _ = 1
  gsSchemas _ = [kayaSchema (Proxy :: Proxy inner)]
  gsVariant _ = 0
  gsToValues (M1 (M1 (K1 r))) = toValues r
  gsFromParts 0 vs = M1 (M1 (K1 (fromValues vs)))
  gsFromParts _ _ = error "kaya: variant out of range"

-- | A sum element type; `deriving Generic` is the whole obligation.
class KayaSum a where
  kayaVariantSchemas :: proxy a -> [[Word32]]
  default kayaVariantSchemas :: (Generic a, GSum (Rep a)) => proxy a -> [[Word32]]
  kayaVariantSchemas _ = gsSchemas (Proxy :: Proxy (Rep a))
  kayaSumVariant :: a -> Word32
  default kayaSumVariant :: (Generic a, GSum (Rep a)) => a -> Word32
  kayaSumVariant = gsVariant . from
  kayaSumToValues :: a -> [W.Value]
  default kayaSumToValues :: (Generic a, GSum (Rep a)) => a -> [W.Value]
  kayaSumToValues = gsToValues . from
  kayaSumFromParts :: Word32 -> [W.Value] -> a
  default kayaSumFromParts :: (Generic a, GSum (Rep a)) => Word32 -> [W.Value] -> a
  kayaSumFromParts v vs = to (gsFromParts v vs)

newtype SumCollection a = SumCollection {sumHandle :: Collection}

sumCollectionOf :: forall a. KayaSum a => Proxy a -> Build (SumCollection a)
sumCollectionOf p = Build $ \s ->
  let c = bCounters s
      n = cCollection c + 1
      s' = registerCollection n s {bCounters = c {cCollection = n}}
   in ( SumCollection (Collection n []),
        s' {bRecords = bRecords s' <> pure (W.txCreateCollection n (kayaVariantSchemas p))}
      )

-- | Insert witnesses the value's own constructor onto the wire.
sumInsert :: forall a. KayaSum a => SumCollection a -> W.Value -> a -> Build ()
sumInsert (SumCollection (Collection n path)) key value = Build $ \s ->
  let variant = kayaSumVariant value
      vals = kayaSumToValues value
      tags = kayaVariantSchemas (Proxy :: Proxy a) !! fromIntegral variant
   in ((), recomputeDerived n path
        s {bRecords = bRecords s <> (W.txCollectionInsert n path key variant <$> encodeFields tags vals),
           bModel = modelSet n path key variant vals (bModel s)})

-- | Update replaces a record wholesale; a different constructor than
-- the entry's current one restamps its copy in place.
sumUpdate :: forall a. KayaSum a => SumCollection a -> W.Value -> a -> Build ()
sumUpdate (SumCollection (Collection n path)) key value = Build $ \s ->
  let variant = kayaSumVariant value
      vals = kayaSumToValues value
      tags = kayaVariantSchemas (Proxy :: Proxy a) !! fromIntegral variant
   in ((), recomputeDerived n path
        s {bRecords = bRecords s <> (W.txCollectionUpdate n path key variant <$> encodeFields tags vals),
           bModel = modelSet n path key variant vals (bModel s)})

-- | The typed model, in insertion order; `case` eliminates the values.
sumItems :: KayaSum a => SumCollection a -> Build [(W.Value, a)]
sumItems (SumCollection (Collection n path)) = Build $ \s ->
  (map (\(k, (v, vs)) -> (k, kayaSumFromParts v vs)) (lookupEntries n path (bModel s)), s)

-- | The entry's current value — the scrutinee for the match that
-- precedes a patch.
sumGet :: KayaSum a => SumCollection a -> W.Value -> Build (Maybe a)
sumGet (SumCollection (Collection n path)) key = Build $ \s ->
  ( fmap (\(v, vs) -> kayaSumFromParts v vs)
      (lookup key (lookupEntries n path (bModel s))),
    s)

-- | The witnessed patch: the scrutinee the guest just matched is the
-- witness — its constructor names the variant — and the model refuses
-- a drifted entry, so the guard is checked, not trusted.
sumPatch :: KayaSum a => SumCollection a -> W.Value -> a -> [FieldSet v] -> Build ()
sumPatch c key witness = mapM_ (\(FieldSet i tag v) -> sumUpdateFieldWire c key (kayaSumVariant witness) i tag v)

sumUpdateFieldWire :: SumCollection a -> W.Value -> Word32 -> Word32 -> Word32 -> W.Value -> Build ()
sumUpdateFieldWire (SumCollection (Collection n path)) key variant i tag value = Build $ \s ->
  let (stored, current) = case lookup key (lookupEntries n path (bModel s)) of
        Just (v, vs) -> (v, vs)
        Nothing -> error "kaya: update of missing key"
      updated = take (fromIntegral i) current ++ [value] ++ drop (fromIntegral i + 1) current
   in if stored /= variant
        then error "kaya: update_field witnessed a constructor the entry no longer holds"
        else
          ((), recomputeDerived n path
            s {bRecords = bRecords s <> (W.txCollectionUpdateField n path key i variant <$> encodeFieldWire tag value),
               bModel = modelSet n path key variant updated (bModel s)})

-- | The collection-derived signal, over the sum's entries.
sumDerive ::
  forall a. KayaSum a =>
  SumCollection a -> ([(W.Value, a)] -> W.Value) -> Build Signal
sumDerive (SumCollection (Collection n _)) compute = Build $ \s ->
  let wireCompute entries = compute (map (\(k, (v, vs)) -> (k, kayaSumFromParts v vs :: a)) entries)
      initial = wireCompute (lookupEntries n [] (bModel s))
      c = bCounters s
      sid = cSignal c + 1
      s' = s {bCounters = c {cSignal = sid},
              bRecords = bRecords s <> pure (W.txCreateSignal sid initial),
              bDerived = Map.insertWith (flip (++)) n [(sid, wireCompute)] (bDerived s)}
   in (Signal sid, s')

-- | One arm of the template eliminator: the prototype value names the
-- constructor, the Tpl program is its blueprint.
data SumArm = SumArm !Word32 (Tpl ())

sumArm :: KayaSum a => a -> Tpl () -> SumArm
sumArm prototype = SumArm (kayaSumVariant prototype)

-- | The template eliminator: a product of arms, one per constructor, handed
-- over whole.
eachSum :: forall a. KayaSum a => SumCollection a -> [SumArm] -> Build Widget
eachSum (SumCollection coll) arms = Build $ \s ->
  let count = length (kayaVariantSchemas (Proxy :: Proxy a))
      variants = map (\(SumArm v _) -> v) arms
      _checked
        | length arms /= count =
            error ("kaya: the eliminator needs " ++ show count ++ " arms, got " ++ show (length arms))
        | length (List.nub variants) /= length variants =
            error "kaya: two arms for one constructor"
        | otherwise = ()
      body = mapM_ (\(SumArm v (Tpl arm)) -> Tpl (\st ->
        ((), snd (arm st {bRecords = bRecords st <> pure (W.txVariantCase v)})))) arms
      ((self, _), s') =
        _checked `seq`
        bracketTpl (unBuild allocW) (`W.txCreateFor` cid) (Just cid) body s
      cid = assertRoot coll
   in (Widget self, s')

bindTextElement :: Node -> Word32 -> Tpl ()
bindTextElement (Node n) level = emitT (W.txBindTextElement n level 0)

-- | A Haskell type that can be one record field.
class KayaFieldType v where
  fieldTag :: proxy v -> Word32
  toFieldValue :: v -> W.Value
  fromFieldValue :: W.Value -> v

instance KayaFieldType String where
  fieldTag _ = W.valueStr
  toFieldValue = W.VStr
  fromFieldValue v = case v of W.VStr s -> s; _ -> error "kaya: field is not a Str"

instance KayaFieldType Bool where
  fieldTag _ = W.valueBool
  toFieldValue = W.VBool
  fromFieldValue v = case v of W.VBool b -> b; _ -> error "kaya: field is not a Bool"

instance KayaFieldType Int64 where
  fieldTag _ = W.valueI64
  toFieldValue = W.VI64
  fromFieldValue v = case v of W.VI64 n -> n; _ -> error "kaya: field is not an I64"

instance KayaFieldType Double where
  fieldTag _ = W.valueF64
  toFieldValue = W.VF64
  fromFieldValue v = case v of W.VF64 x -> x; _ -> error "kaya: field is not an F64"

-- | A Date record field (docs/datetime-plan.md D10): the schema slot is
-- I64 in packed decimal and the app holds a 'Day' everywhere.
instance KayaFieldType Day where
  fieldTag _ = W.valueI64
  toFieldValue = W.VI64 . packDay
  fromFieldValue v = case v of W.VI64 n -> dayOfPacked n; _ -> error "kaya: field is not a Date"

instance KayaFieldType TimeOfDay where
  fieldTag _ = W.valueI64
  toFieldValue = W.VI64 . packTimeOfDay
  fromFieldValue v = case v of W.VI64 n -> timeOfDayOfPacked n; _ -> error "kaya: field is not a Time"

-- | Encoded image bytes are a wire type: the schema slot is Blob, and
-- every encode registers the bytes with the core right then — handles
-- are single-submit, so insert, update and update_field all re-register.
instance KayaFieldType BS.ByteString where
  fieldTag _ = W.valueBlob
  toFieldValue = W.VStr . BC.unpack
  fromFieldValue v = case v of W.VStr s -> BC.pack s; _ -> error "kaya: field is not a Blob"

encodeFieldWire :: Word32 -> W.Value -> IO W.Value
encodeFieldWire tag v
  | tag == W.valueBlob, W.VStr s <- v = W.VBlob <$> registerBlob (BC.pack s)
  | otherwise = pure v

encodeFields :: [Word32] -> [W.Value] -> IO [W.Value]
encodeFields tags = sequence . zipWith encodeFieldWire tags

class GRecord f where
  gSchema :: proxy f -> [Word32]
  gNames :: proxy f -> [String]
  gTo :: f p -> [W.Value]
  gFrom :: [W.Value] -> (f p, [W.Value])

instance GRecord f => GRecord (M1 D c f) where
  gSchema _ = gSchema (Proxy :: Proxy f)
  gNames _ = gNames (Proxy :: Proxy f)
  gTo (M1 x) = gTo x
  gFrom vs = let (x, rest) = gFrom vs in (M1 x, rest)

instance GRecord f => GRecord (M1 C c f) where
  gSchema _ = gSchema (Proxy :: Proxy f)
  gNames _ = gNames (Proxy :: Proxy f)
  gTo (M1 x) = gTo x
  gFrom vs = let (x, rest) = gFrom vs in (M1 x, rest)

instance (GRecord a, GRecord b) => GRecord (a :*: b) where
  gSchema _ = gSchema (Proxy :: Proxy a) ++ gSchema (Proxy :: Proxy b)
  gNames _ = gNames (Proxy :: Proxy a) ++ gNames (Proxy :: Proxy b)
  gTo (a :*: b) = gTo a ++ gTo b
  gFrom vs =
    let (a, rest) = gFrom vs
        (b, rest') = gFrom rest
     in (a :*: b, rest')

instance (Selector c, KayaFieldType v) => GRecord (M1 S c (K1 R v)) where
  gSchema _ = [fieldTag (Proxy :: Proxy v)]
  gNames _ = [selName (undefined :: M1 S c (K1 R v) p)]
  gTo (M1 (K1 v)) = [toFieldValue v]
  gFrom (v : rest) = (M1 (K1 (fromFieldValue v)), rest)
  gFrom [] = error "kaya: record arity mismatch"

-- | A collection element type; `deriving Generic` is the whole
-- obligation.
class KayaRecord a where
  kayaSchema :: proxy a -> [Word32]
  default kayaSchema :: (Generic a, GRecord (Rep a)) => proxy a -> [Word32]
  kayaSchema _ = gSchema (Proxy :: Proxy (Rep a))

  kayaFieldNames :: proxy a -> [String]
  default kayaFieldNames :: (Generic a, GRecord (Rep a)) => proxy a -> [String]
  kayaFieldNames _ = gNames (Proxy :: Proxy (Rep a))

  toValues :: a -> [W.Value]
  default toValues :: (Generic a, GRecord (Rep a)) => a -> [W.Value]
  toValues = gTo . from

  fromValues :: [W.Value] -> a
  default fromValues :: (Generic a, GRecord (Rep a)) => [W.Value] -> a
  fromValues = to . fst . gFrom

-- | A civil date as the wire's I64, in packed decimal
-- (docs/datetime-plan.md D2).
packDay :: Day -> Int64
packDay d = let (y, m, dd) = toGregorian d in W.packDate (fromIntegral y) m dd

-- | A civil time as the wire's I64; seconds are not a picker value (D3).
packTimeOfDay :: TimeOfDay -> Int64
packTimeOfDay t = W.packTime (todHour t) (todMin t)

dayOfPacked :: Int64 -> Day
dayOfPacked packed =
  let (y, m, d) = W.unpackDate packed in fromGregorian (fromIntegral y) m d

timeOfDayOfPacked :: Int64 -> TimeOfDay
timeOfDayOfPacked packed =
  let (h, m) = W.unpackTime packed in TimeOfDay h m 0

-- | A date as a signal's value.
dateValue :: Day -> W.Value
dateValue = W.VI64 . packDay

-- | A time as a signal's value.
timeValue :: TimeOfDay -> W.Value
timeValue = W.VI64 . packTimeOfDay

-- | A typed projection: one field of a record type, by wire position.
newtype KField v = KField Word32

-- | The field token for a's field, by type-level name:
-- `field @"done" @Todo`. GHC's HasField constraint makes both the
-- membership and the field's type a compile-time fact, so a wrong name
-- or type is a type error at the use site.
field ::
  forall name a v.
  (KayaRecord a, KayaFieldType v, HasField name a v, KnownSymbol name) =>
  KField v
field = case elemIndex (symbolVal (Proxy :: Proxy name)) (kayaFieldNames (Proxy :: Proxy a)) of
  Just i -> KField (fromIntegral i)
  -- Unreachable: HasField holds and every KayaRecord field is
  -- wire-typed, so the name is always in the derived list.
  Nothing -> error ("kaya: field " ++ symbolVal (Proxy :: Proxy name) ++ " has no wire slot")

-- | The ELEMENT ITSELF as an addressable source: a scalar collection (the
-- plain 'collection') carries exactly one field and the element is it, so
-- there is no name to give.
element :: KField String
element = KField 0

-- | A Collection whose entries are a-records.
newtype RecordCollection a = RecordCollection Collection

-- | The plain handle, for forEach.
recordHandle :: RecordCollection a -> Collection
recordHandle (RecordCollection c) = c

insertRecord :: forall a. KayaRecord a => RecordCollection a -> W.Value -> a -> Build ()
insertRecord (RecordCollection (Collection n path)) key value = Build $ \s ->
  let vals = toValues value
   in ( (),
        insertEntry n path key vals
          (W.txCollectionInsert n path key 0 <$> encodeFields (kayaSchema (Proxy :: Proxy a)) vals)
          s
      )

-- | Insert a record under a key the binding authors, and hand the key
-- back. ONE COUNTER PER COLLECTION INSTANCE, starting at 0; the minted
-- key is 'W.VI64' and is counter+1. MIXING IS SAFE BY ABSORPTION — an
-- explicit numeric key at or above the counter carries it up — and NO
-- DECREMENT IS EXPRESSIBLE, so a history walk never moves the minter.
insertFresh :: forall a. KayaRecord a => RecordCollection a -> a -> Build Int64
insertFresh c@(RecordCollection (Collection n path)) value = Build $ \s ->
  let (key, fresh) = mintKey n path (bFresh s)
      (_, s') = unBuild (insertRecord c (W.VI64 key) value) s {bFresh = fresh}
   in (key, s')

updateRecord :: forall a. KayaRecord a => RecordCollection a -> W.Value -> a -> Build ()
updateRecord (RecordCollection (Collection n path)) key value = Build $ \s ->
  let vals = toValues value
   in ((), recomputeDerived n path
        s {bRecords = bRecords s <> (W.txCollectionUpdate n path key 0 <$> encodeFields (kayaSchema (Proxy :: Proxy a)) vals),
           bModel = modelSet n path key 0 vals (bModel s)})

-- | One field's delta: the rest of the record never travels; the
-- model's copy updates the same slot.
updateField ::
  forall v a. KayaFieldType v =>
  RecordCollection a -> W.Value -> KField v -> v -> Build ()
updateField c key (KField i) value =
  updateFieldWire c key i (fieldTag (Proxy :: Proxy v)) (toFieldValue value)

updateFieldWire :: RecordCollection a -> W.Value -> Word32 -> Word32 -> W.Value -> Build ()
updateFieldWire (RecordCollection (Collection n path)) key i tag value = Build $ \s ->
  let current = case lookup key (lookupEntries n path (bModel s)) of
        Just (_, vs) -> vs
        Nothing -> error "kaya: update of missing key"
      updated = take (fromIntegral i) current ++ [value] ++ drop (fromIntegral i + 1) current
   in ((), recomputeDerived n path
        s {bRecords = bRecords s <> (W.txCollectionUpdateField n path key i 0 <$> encodeFieldWire tag value),
           bModel = modelSet n path key 0 updated (bModel s)})

-- | One recorded field write of an a-record: the triple travels as
-- (index, schema tag, model value) — the tag tells the boundary whether
-- the value is a Blob slot that must register its bytes.
data FieldSet a = FieldSet !Word32 !Word32 !W.Value

set :: forall v a. KayaFieldType v => KField v -> v -> FieldSet a
set (KField i) v = FieldSet i (fieldTag (Proxy :: Proxy v)) (toFieldValue v)

-- | Typed field writes with the key spelled once: @patch todos key [set
-- (field \@"done" \@Todo) True]@.
patch :: RecordCollection a -> W.Value -> [FieldSet a] -> Build ()
patch c key = mapM_ (\(FieldSet i tag v) -> updateFieldWire c key i tag v)

-- | The typed model: what this guest wrote, in insertion order.
recordItems :: KayaRecord a => RecordCollection a -> Build [(W.Value, a)]
recordItems (RecordCollection (Collection n path)) = Build $ \s ->
  (map (\(k, (_, vs)) -> (k, fromValues vs)) (lookupEntries n path (bModel s)), s)

-- | A signal the binding recomputes from this collection's entries after
-- every mutation, written into the same transaction — the items-left label
-- with no handler remembering to update it.
derive ::
  forall a. KayaRecord a =>
  RecordCollection a -> ([(W.Value, a)] -> W.Value) -> Build Signal
derive (RecordCollection (Collection n _)) compute = Build $ \s ->
  let wireCompute entries = compute (map (\(k, (_, vs)) -> (k, fromValues vs :: a)) entries)
      initial = wireCompute (lookupEntries n [] (bModel s))
      c = bCounters s
      sid = cSignal c + 1
      s' = s {bCounters = c {cSignal = sid},
              bRecords = bRecords s <> pure (W.txCreateSignal sid initial),
              bDerived = Map.insertWith (flip (++)) n [(sid, wireCompute)] (bDerived s)}
   in (Signal sid, s')

-- | Bind a label's text to one field of the element; KField String
-- only — the phantom pins it at compile time.
bindTextField :: Node -> Word32 -> KField String -> Tpl ()
bindTextField (Node n) level (KField i) = emitT (W.txBindTextElement n level i)

-- | Bind a date picker's value to one field of the element; KField Day
-- only (docs/datetime-plan.md D10).
bindDateField :: Node -> Word32 -> KField Day -> Tpl ()
bindDateField (Node n) level (KField i) = emitT (W.txBindDateElement n level i)

-- | Bind a time picker's value to one field of the element.
bindTimeField :: Node -> Word32 -> KField TimeOfDay -> Tpl ()
bindTimeField (Node n) level (KField i) = emitT (W.txBindTimeElement n level i)

-- | Bind a checkbox's state to one field of the element; KField Bool
-- only.
bindCheckedField :: Node -> Word32 -> KField Bool -> Tpl ()
bindCheckedField (Node n) level (KField i) = emitT (W.txBindCheckedElement n level i)

-- | Bind an F64 prop — a progress fraction, a slider position, a
-- choice's index — to one field of the element; KField Double only,
-- because the slot is F64 and an I64 field would be a scene error at
-- declaration rather than a compile error here.
bindValueField :: Node -> Word32 -> KField Double -> Tpl ()
bindValueField (Node n) level (KField i) = emitT (W.txBindValueElement n level i)

-- | Bind an image's source to one Blob field of the element; KField
-- ByteString only.
bindSourceField :: Node -> Word32 -> KField BS.ByteString -> Tpl ()
bindSourceField (Node n) level (KField i) = emitT (W.txBindSourceElement n level i)

data App = App
  { -- THE ONLY FIELD HERE TOUCHED FROM ANOTHER THREAD, and the only
    -- reason this record carries an MVar at all — every IORef below is
    -- app-thread-only by construction.
    appPosted :: MVar [IO ()],
    appCounters :: IORef Counters,
    appModel :: IORef (Model, Map.Map Word64 [Word64]),
    appFresh :: IORef Fresh,
    appDerived :: IORef (Map.Map Word64 [(Word64, [(W.Value, (Word32, [W.Value]))] -> W.Value)]),
    appWidgetHandlers :: IORef (Map.Map Word64 (IO ())),
    -- Table sort requests, keyed by the For container's widget id
    -- (docs/tables-plan.md): the handler receives the 0-based column.
    appSortHandlers :: IORef (Map.Map Word64 (Int -> IO ())),
    -- The node twin: a NESTED table's sort request names the template
    -- node and the copy's key path, so each stamped table sorts alone.
    appNodeSorts :: IORef (Map.Map Word64 ([W.Value] -> Int -> IO ())),
    appNodeHandlers :: IORef (Map.Map Word64 ([W.Value] -> IO ())),
    appWidgetChanges :: IORef (Map.Map Word64 (String -> IO ())),
    appNodeChanges :: IORef (Map.Map Word64 ([W.Value] -> String -> IO ())),
    appWidgetToggles :: IORef (Map.Map Word64 (Bool -> IO ())),
    appNodeToggles :: IORef (Map.Map Word64 ([W.Value] -> Bool -> IO ())),
    appWidgetValues :: IORef (Map.Map Word64 (Double -> IO ())),
    -- The node twin of the line above: without it a stamped control's
    -- Occurrence::InstanceValueChanged matches nothing and is dropped
    -- with no error anywhere.
    appNodeValues :: IORef (Map.Map Word64 ([W.Value] -> Double -> IO ())),
    appWidgetCommits :: IORef (Map.Map Word64 (Double -> IO ())),
    appNodeCommits :: IORef (Map.Map Word64 ([W.Value] -> Double -> IO ())),
    -- The pickers' committed values (docs/datetime-plan.md D7).
    appWidgetDates :: IORef (Map.Map Word64 (Day -> IO ())),
    appNodeDates :: IORef (Map.Map Word64 ([W.Value] -> Day -> IO ())),
    appWidgetTimes :: IORef (Map.Map Word64 (TimeOfDay -> IO ())),
    appNodeTimes :: IORef (Map.Map Word64 ([W.Value] -> TimeOfDay -> IO ())),
    -- Per-window lifecycle handlers, keyed by window id — handlers
    -- scope to the thing that creates them.
    appCloseRequested :: IORef (Map.Map Word64 (IO ())),
    appWindowClosed :: IORef (Map.Map Word64 (IO ())),
    -- Per-entry navigation handlers, keyed by entry surface id (the
    -- request-bound alert precedent).
    appEntryPopped :: IORef (Map.Map Word64 (IO ())),
    appSectionSelected :: IORef (Map.Map Word64 (IO ())),
    appBackRequested :: IORef (Map.Map Word64 (IO ())),
    appAlertHandlers :: IORef (Map.Map Word64 (Word32 -> IO ())),
    appNextAlert :: IORef Word64,
    -- The undo ledger's two reports, keyed by WINDOW. NOT one-shot: a
    -- user walks a history as often as they like.
    appUndone :: IORef (Map.Map Word64 (String -> UndoDelta -> IO ())),
    appRedone :: IORef (Map.Map Word64 (String -> UndoDelta -> IO ())),
    appFileDialogHandlers :: IORef (Map.Map Word64 ([PickedFile] -> IO ())),
    -- Clipboard reads share the alert's request/result grammar and so
    -- its table shape: one-shot, keyed by request id.
    appClipboardReads :: IORef (Map.Map Word64 (Maybe Representation -> IO ())),
    appNextClipboardRead :: IORef Word64,
    appWidgetPastes :: IORef (Map.Map Word64 (Representation -> IO ())),
    appNodePastes :: IORef (Map.Map Word64 ([W.Value] -> Representation -> IO ())),
    appWidgetDrops :: IORef (Map.Map Word64 (Dropped -> IO ())),
    appNodeDrops :: IORef (Map.Map Word64 ([W.Value] -> Dropped -> IO ())),
    appDragEnded :: IORef (Map.Map Word64 (Maybe Op -> IO ())),
    appNodeDragEnded :: IORef (Map.Map Word64 ([W.Value] -> Maybe Op -> IO ())),
    -- Menu dispatch tables, keyed by MENU ITEM id — their own id space,
    -- separate from every widget/node table. The node flavors receive
    -- the stamped copy's key path.
    appMenuActivated :: IORef (Map.Map Word64 (IO ())),
    appMenuActivatedNode :: IORef (Map.Map Word64 ([W.Value] -> IO ())),
    appMenuToggled :: IORef (Map.Map Word64 (Bool -> IO ())),
    appMenuToggledNode :: IORef (Map.Map Word64 ([W.Value] -> Bool -> IO ())),
    appMenuSelected :: IORef (Map.Map Word64 (Int -> IO ())),
    appMenuSelectedNode :: IORef (Map.Map Word64 ([W.Value] -> Int -> IO ())),
    -- The canvas's drawing-as-a-function-of-size (docs/canvas-plan.md
    -- §3.2.1), keyed by the canvas's widget id. 'dispatchLoop' answers
    -- the ask itself and the guest never sees it. ONE STORED SHAPE for
    -- both policies, so the answer path has one call shape and the frame
    -- time is 0 for a plain redraw.
    appDraws :: IORef (Map.Map Word64 (Viewbox -> Double -> [DrawOp]))
  }

-- | The app thread, learned when the dispatch loop starts. Nothing
-- before then, which is the single-threaded construction phase.
appThreadRef :: IORef (Maybe ThreadId)
appThreadRef = unsafePerformIO (newIORef Nothing)
{-# NOINLINE appThreadRef #-}

-- | The Haskell spelling of a rule the handle bindings get from a
-- stale-transaction check.
requireAppThread :: IO ()
requireAppThread = do
  owner <- readIORef appThreadRef
  case owner of
    Just expected -> do
      here <- myThreadId
      if here /= expected
        then
          error
            ( "kaya: a transaction belongs to the app thread -- this is thread "
                ++ show here
                ++ ", the app thread is "
                ++ show expected
                ++ ". To mutate from a background thread use post, which runs your "
                ++ "action as a transaction over there."
            )
        else return ()
    Nothing -> return ()

-- | Run a Build to records, submit them as one transaction, and return
-- the block's result. The model folds inside the Build's pure state and
-- is stored back here alongside the submit — a transaction that never
-- reaches this point (its Build threw) leaves the model as committed.
buildTx :: App -> Build a -> IO a
buildTx app (Build f) = do
  requireAppThread
  counters <- readIORef (appCounters app)
  (model, children) <- readIORef (appModel app)
  fresh <- readIORef (appFresh app)
  derived <- readIORef (appDerived app)
  let (a, s) = f (BuildState counters mempty model fresh children [] [] derived)
  -- Force the Build's final state before the first store-back: a Build
  -- that throws must throw HERE, where the boundary abandons everything
  -- — never later, from a poisoned thunk inside an IORef.
  _ <- evaluate s
  -- Serialize now, before any store-back: this runs the records' IO, which is
  -- where image sources and Blob record fields register their bytes with the
  -- core — in record order, immediately before the submit whose handle table
  -- they fill.
  records <- bRecords s
  writeIORef (appCounters app) (bCounters s)
  writeIORef (appModel app) (bModel s, bChildren s)
  writeIORef (appFresh app) (bFresh s)
  writeIORef (appDerived app) (bDerived s)
  -- Handlers declared at their constructors register alongside the
  -- submit; a Build that threw never reaches here, abandoning them
  -- with its records.
  mapM_ (register app) (reverse (bPending s))
  kayaSubmit [records]
  return a

register :: App -> Pending -> IO ()
register app pending = case pending of
  PClick n handler -> modifyIORef' (appWidgetHandlers app) (Map.insert n handler)
  PAlert n handler -> modifyIORef' (appAlertHandlers app) (Map.insert n handler)
  PFileDialog n handler ->
    modifyIORef' (appFileDialogHandlers app) (Map.insert n handler)
  PClipboardRead n handler ->
    modifyIORef' (appClipboardReads app) (Map.insert n handler)
  PEntryPopped n handler -> modifyIORef' (appEntryPopped app) (Map.insert n handler)
  PSectionSelected n handler -> modifyIORef' (appSectionSelected app) (Map.insert n handler)
  PBackRequested n handler -> modifyIORef' (appBackRequested app) (Map.insert n handler)
  PCloseRequested n handler -> modifyIORef' (appCloseRequested app) (Map.insert n handler)
  PWindowClosed n handler -> modifyIORef' (appWindowClosed app) (Map.insert n handler)
  -- The undo pair keys the same per-WINDOW tables the dispatch loop
  -- reads; n is the window construct's id.
  PUndone n handler -> modifyIORef' (appUndone app) (Map.insert n handler)
  PRedone n handler -> modifyIORef' (appRedone app) (Map.insert n handler)
  PChange n handler -> modifyIORef' (appWidgetChanges app) (Map.insert n handler)
  PToggle n handler -> modifyIORef' (appWidgetToggles app) (Map.insert n handler)
  PValue n handler -> modifyIORef' (appWidgetValues app) (Map.insert n handler)
  PToggleNode n handler -> modifyIORef' (appNodeToggles app) (Map.insert n handler)
  PDate n handler -> modifyIORef' (appWidgetDates app) (Map.insert n handler)
  PTime n handler -> modifyIORef' (appWidgetTimes app) (Map.insert n handler)
  PDateNode n handler -> modifyIORef' (appNodeDates app) (Map.insert n handler)
  PTimeNode n handler -> modifyIORef' (appNodeTimes app) (Map.insert n handler)
  PMenuActivated n handler -> modifyIORef' (appMenuActivated app) (Map.insert n handler)
  PMenuActivatedNode n handler -> modifyIORef' (appMenuActivatedNode app) (Map.insert n handler)
  PMenuToggled n handler -> modifyIORef' (appMenuToggled app) (Map.insert n handler)
  PMenuToggledNode n handler -> modifyIORef' (appMenuToggledNode app) (Map.insert n handler)
  PMenuSelected n handler -> modifyIORef' (appMenuSelected app) (Map.insert n handler)
  PMenuSelectedNode n handler -> modifyIORef' (appMenuSelectedNode app) (Map.insert n handler)

-- | buildTx for handlers that keep no handles.
submitTx :: App -> Build () -> IO ()
submitTx app b = buildTx app b

-- | 'buildTx' as ONE undoable step, named @label@ (docs/undo-plan.md
-- D2). The marker is emitted before @body@ runs, so no call order can
-- put it anywhere but first. WHAT A GROUP MAY HOLD is the reactive half
-- — signal writes and collection deltas; anything else fails at apply,
-- naming the op. The label must be NON-EMPTY: the empty one is how a
-- typing episode names itself.
undoableTx :: App -> String -> Build a -> IO a
undoableTx app = undoableTxIn app 0

-- | 'undoableTx' against an auxiliary window's ledger; each window has
-- its own history.
undoableTxIn :: App -> Word64 -> String -> Build a -> IO a
undoableTxIn app windowId label body =
  buildTx app (emitB (W.txUndoGroup windowId (W.VStr label)) >> body)

-- Fold an undo's payload into the collection model; the payload is
-- core-authoritative.
--
-- NO DERIVED RECOMPUTE HERE, DELIBERATELY: a derived signal's write rode
-- the SAME transaction as the mutation that caused it, so the core has
-- already restored it by the time this runs.
absorbUndo :: App -> UndoDelta -> IO ()
absorbUndo app delta = modifyIORef' (appModel app) fold
  where
    fold (model, children) = (foldl order (foldl entry model (undoEntries delta)) (undoOrders delta), children)
    entry model e = case ueState e of
      Just (variant, record) -> modelSet (ueCollection e) (uePath e) (ueKey e) variant record model
      -- The entry is gone in the restored state. Its own instance
      -- only: the payload states what each entry IS, and an instance
      -- it never names is one this undo did not touch.
      Nothing -> Map.adjust (map (drop1 (uePath e) (ueKey e))) (ueCollection e) model
    drop1 path key i
      | iPath i == path = i {iEntries = filter ((/= key) . fst) (iEntries i)}
      | otherwise = i
    order model o = Map.adjust (map (place o)) (uoCollection o) model
    place o i
      | iPath i == uoPath o =
          -- Positioned by the payload's list, keeping anything it does
          -- not name at the end: an entry the delta never mentions is
          -- one this undo did not move.
          let named = [(k, v) | k <- uoKeys o, Just v <- [lookup k (iEntries i)]]
              rest = filter ((`notElem` uoKeys o) . fst) (iEntries i)
           in i {iEntries = named ++ rest}
      | otherwise = i

-- | The registration vocabulary, shared by both zones: a handler is
-- registered at the element that produced the occurrence. ONE CLASS, NOT
-- ONE PER VERB — -Werror=missing-methods fires only for a method missing
-- from an EXISTING instance, so six one-method classes would turn a
-- skipped zone into a MISSING INSTANCE, an error only where a guest
-- calls it (docs/deferred.md, the nested RECORD collection entry).
class HandlerTarget e where
  -- | What this zone hands a handler ahead of the payload @p@: nothing in
  -- the live zone, the stamped copy's key path (outermost first) in a
  -- template. ONE STATEMENT OF THAT RULE for every verb — a handler type
  -- written out per verb can promise the template arm the LIVE shape and
  -- still compile.
  type Keyed e p

  onClick :: App -> e -> Keyed e (IO ()) -> IO ()

  -- | The field owns its text and reports each edit here; the app folds
  -- the text into its own state — there is no read-back, by doctrine.
  onChange :: App -> e -> Keyed e (String -> IO ()) -> IO ()

  -- | The box owns its checked bit and reports each flip here; the app
  -- folds it into its own state.
  onToggle :: App -> e -> Keyed e (Bool -> IO ()) -> IO ()

  -- | A slider, select or radio reports each move with the new value —
  -- the entry's uncontrolled contract, with a Double.
  onValueChanged :: App -> e -> Keyed e (Double -> IO ()) -> IO ()

  -- | The value a slider gesture SETTLED ON — once per release or key
  -- move, after that gesture's 'onValueChanged' moves
  -- (docs\/slider-plan.md S2).
  onValueCommitted :: App -> e -> Keyed e (Double -> IO ()) -> IO ()

  -- | Take pasted content. COSTS NOTHING ON ANY PLATFORM, unlike
  -- 'readClipboard': a paste is a user gesture, so it is its own
  -- authorisation.
  onPaste :: App -> e -> Keyed e (Representation -> IO ()) -> IO ()

  -- | The table's header-click handler, registered at its For; the
  -- payload is the 0-based column of a sort REQUEST. Nothing has changed
  -- on screen: reorder the collection by key and re-declare the header —
  -- 'columns' live, 'columnsAt' per stamped copy (docs\/tables-plan.md).
  onSort :: App -> e -> Keyed e (Int -> IO ()) -> IO ()

  -- | Take dropped content here (docs\/dnd-plan.md D8): a live widget's
  -- own drops or a reorderable For's landings, and at a Node the drops on
  -- every stamped copy, the copy's keys first. Only fires for a widget
  -- that declared 'DropTarget' over an accept list.
  onDrop :: App -> e -> Keyed e (Dropped -> IO ()) -> IO ()

  -- | A drag that began here has ended: 'Nothing' is a cancelled or
  -- refused drag, not an error. At a Node — a reorderable row is one —
  -- the copy's keys come first.
  onDragEnded :: App -> e -> Keyed e (Maybe Op -> IO ()) -> IO ()

instance HandlerTarget Widget where
  type Keyed Widget p = p
  onClick app (Widget n) handler =
    modifyIORef' (appWidgetHandlers app) (Map.insert n handler)
  onChange app (Widget n) handler =
    modifyIORef' (appWidgetChanges app) (Map.insert n handler)
  onToggle app (Widget n) handler =
    modifyIORef' (appWidgetToggles app) (Map.insert n handler)
  onValueChanged app (Widget n) handler =
    modifyIORef' (appWidgetValues app) (Map.insert n handler)
  onValueCommitted app (Widget n) handler =
    modifyIORef' (appWidgetCommits app) (Map.insert n handler)
  onPaste app (Widget n) handler =
    modifyIORef' (appWidgetPastes app) (Map.insert n handler)
  onSort app (Widget n) handler =
    modifyIORef' (appSortHandlers app) (Map.insert n handler)
  onDrop app (Widget n) handler =
    modifyIORef' (appWidgetDrops app) (Map.insert n handler)
  onDragEnded app (Widget n) handler =
    modifyIORef' (appDragEnded app) (Map.insert n handler)

instance HandlerTarget Node where
  type Keyed Node p = [W.Value] -> p
  onClick app (Node n) handler =
    modifyIORef' (appNodeHandlers app) (Map.insert n handler)
  onChange app (Node n) handler =
    modifyIORef' (appNodeChanges app) (Map.insert n handler)
  onToggle app (Node n) handler =
    modifyIORef' (appNodeToggles app) (Map.insert n handler)
  onValueChanged app (Node n) handler =
    modifyIORef' (appNodeValues app) (Map.insert n handler)
  onValueCommitted app (Node n) handler =
    modifyIORef' (appNodeCommits app) (Map.insert n handler)
  onPaste app (Node n) handler =
    modifyIORef' (appNodePastes app) (Map.insert n handler)
  onSort app (Node n) handler =
    modifyIORef' (appNodeSorts app) (Map.insert n handler)
  onDrop app (Node n) handler =
    modifyIORef' (appNodeDrops app) (Map.insert n handler)
  onDragEnded app (Node n) handler =
    modifyIORef' (appNodeDragEnded app) (Map.insert n handler)

-- | Turn the decoder's kind-and-parts into the sum, or Nothing. EMPTY
-- IS THE UNIVERSAL NO: Nothing covers a denied prompt, an unfocused
-- reader, an empty clipboard and content in no accepted representation
-- alike, because the platforms deliberately do not say which.
representationOf :: Maybe W.ClipValues -> Maybe Representation
representationOf Nothing = Nothing
representationOf (Just cv)
  | kind == W.clipText = Just (RText (str 0))
  | kind == W.clipHtml = Just (RHtml (str 0))
  | kind == W.clipImage = Just (RImage (bytes 0))
  | kind == W.clipCustom = Just (RCustom (str 0) (bytes 1))
  -- The picker's own three-per-file grouping, so a guest that decodes a
  -- dialog result decodes this with the same loop.
  | kind == W.clipFiles = Just (RFiles (regroup (W.clipValues cv)))
  | otherwise = Nothing
  where
    kind = W.clipKind cv
    part i = case drop i (W.clipValues cv) of p : _ -> Just p; [] -> Nothing
    str i = case part i of Just (W.CStr t) -> t; _ -> ""
    bytes i = case part i of Just (W.CBytes b) -> b; _ -> BS.empty
    regroup (W.CI64 h : W.CStr n : W.CStr p : rest) =
      PickedFile (fromIntegral h) n p : regroup rest
    regroup _ = []

-- | A fresh app: zeroed id counters, an empty model, empty dispatch
-- tables. kayaMain starts from one; headless checks use it directly.
--
-- EVERY LINE BELOW NAMES ITS FIELD, because this chain is POSITIONAL and
-- most fields are @IORef (Map …)@ filled with the same polymorphic
-- @Map.empty@: a new table inserted one line off would typecheck and
-- silently swap two dispatch tables.
newApp :: IO App
newApp =
  App
    <$> newMVar [] -- appPosted
    <*> newIORef (Counters 0 0 0 0 0 0 0) -- appCounters
    <*> newIORef (Map.empty, Map.empty) -- appModel
    <*> newIORef Map.empty -- appFresh
    <*> newIORef Map.empty -- appDerived
    <*> newIORef Map.empty -- appWidgetHandlers
    <*> newIORef Map.empty -- appSortHandlers
    <*> newIORef Map.empty -- appNodeSorts
    <*> newIORef Map.empty -- appNodeHandlers
    <*> newIORef Map.empty -- appWidgetChanges
    <*> newIORef Map.empty -- appNodeChanges
    <*> newIORef Map.empty -- appWidgetToggles
    <*> newIORef Map.empty -- appNodeToggles
    <*> newIORef Map.empty -- appWidgetValues
    <*> newIORef Map.empty -- appNodeValues
    <*> newIORef Map.empty -- appWidgetCommits
    <*> newIORef Map.empty -- appNodeCommits
    <*> newIORef Map.empty -- appWidgetDates
    <*> newIORef Map.empty -- appNodeDates
    <*> newIORef Map.empty -- appWidgetTimes
    <*> newIORef Map.empty -- appNodeTimes
    <*> newIORef Map.empty -- appCloseRequested
    <*> newIORef Map.empty -- appWindowClosed
    <*> newIORef Map.empty -- appEntryPopped
    <*> newIORef Map.empty -- appSectionSelected
    <*> newIORef Map.empty -- appBackRequested
    <*> newIORef Map.empty -- appAlertHandlers
    <*> newIORef 0 -- appNextAlert
    <*> newIORef Map.empty -- appUndone
    <*> newIORef Map.empty -- appRedone
    <*> newIORef Map.empty -- appFileDialogHandlers
    <*> newIORef Map.empty -- appClipboardReads
    <*> newIORef 0 -- appNextClipboardRead
    <*> newIORef Map.empty -- appWidgetPastes
    <*> newIORef Map.empty -- appNodePastes
    <*> newIORef Map.empty -- appWidgetDrops
    <*> newIORef Map.empty -- appNodeDrops
    <*> newIORef Map.empty -- appDragEnded
    <*> newIORef Map.empty -- appNodeDragEnded
    <*> newIORef Map.empty -- appMenuActivated
    <*> newIORef Map.empty -- appMenuActivatedNode
    <*> newIORef Map.empty -- appMenuToggled
    <*> newIORef Map.empty -- appMenuToggledNode
    <*> newIORef Map.empty -- appMenuSelected
    <*> newIORef Map.empty -- appMenuSelectedNode
    <*> newIORef Map.empty -- appDraws

-- | Set up (build the scene, register handlers) and run: occurrences
-- dispatch on the app thread while the core owns the calling thread,
-- which must be the process main thread (GHC's main runs bound to it;
-- -threaded is required).
kayaMain :: (App -> IO ()) -> IO ()
kayaMain setup = do
  app <- newApp
  setup app
  done <- newEmptyMVar
  _ <- forkIO (dispatchLoop app >> putMVar done ())
  code <- kayaRun
  takeMVar done
  if code == 0 then exitSuccess else exitWith (ExitFailure (fromIntegral code))

-- | One handler dispatch: an exception crosses the build boundary (the
-- pure Build's store-back and submit never ran, so the model shows
-- exactly what was shipped), is logged, and the loop moves on.
dispatch :: IO () -> IO ()
dispatch body =
  body `catch` \e ->
    hPutStrLn stderr ("kaya: handler threw (transaction rolled back): " ++ show (e :: SomeException))

-- | Run @body@ as a transaction on the app thread, soon. THE ONE action
-- safe to call from another thread. A posted action runs in its OWN
-- transaction, after whatever is running now, so posting from inside a
-- handler queues for after and never nests.
post :: App -> IO () -> IO ()
post app body = do
  modifyMVar_ (appPosted app) (return . (++ [body]))
  -- The app thread may be parked in C waiting on the ring. Posted work
  -- is not an occurrence and never enters that ring, so this is the
  -- only way it hears about it.
  wake

-- | Run everything posted, each as its own transaction, in order. The
-- batch is taken and the MVar put back BEFORE any of it runs, so an
-- action that posts again lands in the NEXT batch; holding the MVar
-- across the calls would deadlock the moment one of them posted.
drainPosted :: App -> IO ()
drainPosted app = do
  batch <- modifyMVar (appPosted app) (\queued -> return ([], queued))
  mapM_ dispatch batch

dispatchLoop :: App -> IO ()
dispatchLoop app = do
  -- Claim the thread before the first occurrence: every build after
  -- this point must happen here.
  myThreadId >>= \here -> writeIORef appThreadRef (Just here)
  -- Posted work first, then the ring, then park. Draining at the TOP is
  -- what makes a wake sufficient: whatever brought this thread back, it
  -- looks here before anywhere else.
  drainPosted app
  occurrence <- pollOccurrence
  case occurrence of
    Nothing -> do
      more <- waitOccurrences
      if more then dispatchLoop app else return () -- shutdown
    Just (kind, ident, keys, payload, clip, drop_, undone, askTail)
      -- THE CANVAS'S TWO ASKS ARE ANSWERED HERE AND NEVER MAPPED
      -- (docs/canvas-plan.md §3.2.1): this calls the registered function
      -- for the size the core asked about and submits the one
      -- set_drawing itself, in a transaction the BINDING opens
      -- (tools/check-ambient-tx.py). The size the ask carried IS the new
      -- viewbox.
      | kind == W.occKindDrawRequested || kind == W.occKindTick -> do
          draws <- readIORef (appDraws app)
          case Map.lookup ident draws of
            Nothing -> return ()
            Just f ->
              dispatch $ do
                let (box, time) = askSize askTail
                submitTx app (emitB (drawingRecord ident [] box (f box time)))
          dispatchLoop app
      | kind == W.occKindSortRequested -> do
          let column = case payload of Just (W.VI64 n) -> fromIntegral n; _ -> 0
          case keys of
            [] -> do
              handlers <- readIORef (appSortHandlers app)
              dispatch (mapM_ ($ column) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (appNodeSorts app)
              dispatch (mapM_ (\h -> h keys column) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindTextChanged -> do
          let content = case payload of Just (W.VStr s) -> s; _ -> ""
          case keys of
            [] -> do
              handlers <- readIORef (appWidgetChanges app)
              dispatch (mapM_ ($ content) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (appNodeChanges app)
              dispatch (mapM_ (\h -> h keys content) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindToggled -> do
          let checked = case payload of Just (W.VBool b) -> b; _ -> False
          case keys of
            [] -> do
              handlers <- readIORef (appWidgetToggles app)
              dispatch (mapM_ ($ checked) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (appNodeToggles app)
              dispatch (mapM_ (\h -> h keys checked) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindValueChanged -> do
          let v = case payload of Just (W.VF64 x) -> x; _ -> 0
          case keys of
            [] -> do
              handlers <- readIORef (appWidgetValues app)
              dispatch (mapM_ ($ v) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (appNodeValues app)
              dispatch (mapM_ (\h -> h keys v) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindValueCommitted -> do
          let v = case payload of Just (W.VF64 x) -> x; _ -> 0
          case keys of
            [] -> do
              handlers <- readIORef (appWidgetCommits app)
              dispatch (mapM_ ($ v) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (appNodeCommits app)
              dispatch (mapM_ (\h -> h keys v) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindDateChanged -> do
          let packed = case payload of Just (W.VI64 n) -> n; _ -> 0
          case keys of
            [] -> do
              handlers <- readIORef (appWidgetDates app)
              dispatch (mapM_ ($ dayOfPacked packed) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (appNodeDates app)
              dispatch (mapM_ (\h -> h keys (dayOfPacked packed)) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindTimeChanged -> do
          let packed = case payload of Just (W.VI64 n) -> n; _ -> 0
          case keys of
            [] -> do
              handlers <- readIORef (appWidgetTimes app)
              dispatch (mapM_ ($ timeOfDayOfPacked packed) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (appNodeTimes app)
              dispatch (mapM_ (\h -> h keys (timeOfDayOfPacked packed)) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindCloseRequested -> do
          handlers <- readIORef (appCloseRequested app)
          dispatch (mapM_ id (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindWindowClosed -> do
          -- One-shot: the window is gone; both registrations retire
          -- with it.
          modifyIORef' (appCloseRequested app) (Map.delete ident)
          handlers <- readIORef (appWindowClosed app)
          modifyIORef' (appWindowClosed app) (Map.delete ident)
          dispatch (mapM_ id (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindEntryPopped -> do
          -- One-shot: the entry is gone; both registrations retire
          -- with it.
          modifyIORef' (appBackRequested app) (Map.delete ident)
          handlers <- readIORef (appEntryPopped app)
          modifyIORef' (appEntryPopped app) (Map.delete ident)
          dispatch (mapM_ id (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindBackRequested -> do
          handlers <- readIORef (appBackRequested app)
          dispatch (mapM_ id (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindSectionSelected -> do
          -- NOT one-shot: sections never die, and the user can return any
          -- number of times (ident is the section; the window rides as the
          -- payload).
          handlers <- readIORef (appSectionSelected app)
          dispatch (mapM_ id (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindClipboardResult -> do
          -- One-shot like the alert, and the request retires with it.
          -- EMPTY IS THE UNIVERSAL NO and arrives as Nothing, because no
          -- platform says which cause it was.
          handlers <- readIORef (appClipboardReads app)
          writeIORef (appClipboardReads app) (Map.delete ident handlers)
          dispatch (mapM_ ($ representationOf clip) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindPasted -> do
          -- A paste rides a click tag verbatim, so it arrives on the ordinary
          -- widget/node split — one record kind, the key path deciding.
          case (representationOf clip, keys) of
            (Nothing, _) -> return ()
            (Just rep, []) -> do
              handlers <- readIORef (appWidgetPastes app)
              dispatch (mapM_ ($ rep) (Map.lookup ident handlers))
            (Just rep, ks) -> do
              handlers <- readIORef (appNodePastes app)
              dispatch (mapM_ (\h -> h ks rep) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindDropped -> do
          -- A drop rides the same tag with four more words
          -- (docs/dnd-plan.md D1), so it arrives on the ordinary
          -- widget/node split — a stamped copy's landing and a
          -- reorderable row's own drag_ended carry the copy's keys (§4).
          case drop_ of
            Nothing -> return ()
            Just d -> do
              let answer =
                    Dropped
                      { droppedPoint = (W.dropX d, W.dropY d),
                        droppedOperation = operationOf (W.dropOperation d),
                        droppedAnchor = W.dropAnchor d,
                        droppedBefore = W.dropBefore d,
                        droppedClip = representationOf (Just (W.dropClip d))
                      }
              case keys of
                [] -> do
                  handlers <- readIORef (appWidgetDrops app)
                  dispatch (mapM_ ($ answer) (Map.lookup ident handlers))
                ks -> do
                  handlers <- readIORef (appNodeDrops app)
                  dispatch (mapM_ (\h -> h ks answer) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindDragEnded -> do
          case payload of
            Just (W.VI64 mask) -> do
              let answer = operationOf (fromIntegral mask)
              case keys of
                [] -> do
                  handlers <- readIORef (appDragEnded app)
                  dispatch (mapM_ ($ answer) (Map.lookup ident handlers))
                ks -> do
                  handlers <- readIORef (appNodeDragEnded app)
                  dispatch (mapM_ (\h -> h ks answer) (Map.lookup ident handlers))
            _ -> return ()
          dispatchLoop app
      | kind == W.occKindFileDialogResult -> do
          -- One-shot like the alert, and the id retires with it. The
          -- parser flattens three values per file into the values slot
          -- (no single Value can carry a list), so they are regrouped
          -- in threes here. EMPTY IS CANCEL.
          let regroup (W.VI64 h : W.VStr n : W.VStr p : rest) =
                PickedFile (fromIntegral h) n p : regroup rest
              regroup _ = []
              files = regroup keys
          handlers <- readIORef (appFileDialogHandlers app)
          writeIORef (appFileDialogHandlers app) (Map.delete ident handlers)
          dispatch (mapM_ ($ files) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindAlertResult -> do
          -- The parser boxes the u32 choice as VI64. One-shot: the
          -- registration retires with the result.
          let choice = case payload of
                Just (W.VI64 c) -> fromIntegral c :: Word32
                _ -> 0
          handlers <- readIORef (appAlertHandlers app)
          writeIORef (appAlertHandlers app) (Map.delete ident handlers)
          dispatch (mapM_ ($ choice) (Map.lookup ident handlers))
          dispatchLoop app
      -- The undo pair keys the per-WINDOW tables (ident is the window;
      -- the label rides as the payload). NOT one-shot. THE MODEL IS
      -- RECONCILED FIRST, and unconditionally: the core moved without a
      -- transaction, so an app reading `count` in the handler must see
      -- the restored state.
      | kind == W.occKindUndone || kind == W.occKindRedone -> do
          let delta = maybe emptyUndoDelta id undone
              label = case payload of Just (W.VStr s) -> s; _ -> ""
          absorbUndo app delta
          handlers <-
            readIORef
              (if kind == W.occKindUndone then appUndone app else appRedone app)
          dispatch (mapM_ (\h -> h label delta) (Map.lookup ident handlers))
          dispatchLoop app
      -- Menu occurrences key the menu-item tables — their own id space.
      -- Node-anchored context items carry the stamped copy's keys;
      -- toggles carry the new state, radio groups the new 0-based index.
      | kind == W.occKindMenuActivated -> do
          case keys of
            [] -> do
              handlers <- readIORef (appMenuActivated app)
              dispatch (mapM_ id (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (appMenuActivatedNode app)
              dispatch (mapM_ ($ keys) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindMenuToggled -> do
          let checked = case payload of Just (W.VBool b) -> b; _ -> False
          case keys of
            [] -> do
              handlers <- readIORef (appMenuToggled app)
              dispatch (mapM_ ($ checked) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (appMenuToggledNode app)
              dispatch (mapM_ (\h -> h keys checked) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindMenuValueChanged -> do
          let index = case payload of Just (W.VF64 x) -> truncate x; _ -> 0
          case keys of
            [] -> do
              handlers <- readIORef (appMenuSelected app)
              dispatch (mapM_ ($ index) (Map.lookup ident handlers))
            _ -> do
              handlers <- readIORef (appMenuSelectedNode app)
              dispatch (mapM_ (\h -> h keys index) (Map.lookup ident handlers))
          dispatchLoop app
    Just (_, ident, [], _, _, _, _, _) -> do
      handlers <- readIORef (appWidgetHandlers app)
      dispatch (mapM_ id (Map.lookup ident handlers))
      dispatchLoop app
    Just (_, ident, keys, _, _, _, _, _) -> do
      handlers <- readIORef (appNodeHandlers app)
      dispatch (mapM_ ($ keys) (Map.lookup ident handlers))
      dispatchLoop app

-- The canvas ask's trailing values: the size the core is asking about,
-- and a tick's frame time in seconds. TIME 0 FOR A PLAIN REDRAW — a
-- ticking canvas is asked once as a draw_requested before its first
-- frame, and the stored function takes the time either way.
askSize :: [W.Value] -> (Viewbox, Double)
askSize (W.VF64 w : W.VF64 h : rest) =
  (Viewbox w h, case rest of W.VF64 t : _ -> t; _ -> 0)
askSize other =
  errorWithoutStackTrace
    ( "kaya: a canvas ask carries "
        ++ show other
        ++ ", wanted the assigned width and height as f64"
    )
