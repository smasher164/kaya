{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}
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
-- KEEP THE PRAGMA BELOW, moved from KayaApp.hs with the code it guards
-- (the idiom pass's F9 module split, 2026-09-16): 'applyAttr' and
-- 'applyTplAttr' stayed in KayaApp.hs, but GRecord's and GSum's own
-- totality (every constructor's generic derivation arm) needs the same
-- wall — a shape added to KayaRecord/KayaSum's generic machinery without
-- every arm compiles, ships and silently mis-derives.
{-# OPTIONS_GHC -Werror=incomplete-patterns #-}
-- KEEP THIS ONE TOO, same move: 'Declare' is how one name spans both
-- zones, and a method left out of ONE instance is a WARNING in GHC's
-- default set — it compiles, ships, and dies at the use site with "No
-- instance nor default method".
{-# OPTIONS_GHC -Werror=missing-methods #-}

-- | The foundation layer (the idiom pass's F9, ruled in 2026-09-16): the
-- Build\/Tpl DSL, the Declare class both zones share, every widget\/
-- collection\/record\/sum handle type, the typed KayaValue\/KayaFieldType
-- wire-value classes, the App record, and the collection\/record verb
-- family (collectionOf, insert\/update\/remove, insertRecord\/patch\/
-- derive, sumCollectionOf and kin). KayaApp.hs holds everything built ON
-- this — windows, menus, dialogs, rich text's SUGAR, widget sugar,
-- canvas's SUGAR, dnd's SUGAR, prefs, notifications, kayaMain,
-- dispatchLoop — and re-exports this module in full, so `import KayaApp`
-- is unchanged for every guest.
--
-- THE CUT IS BY WHAT THE APP RECORD'S OWN FIELDS NEED, not by feature
-- area: Pending's constructors and App's handler tables carry Edit\/
-- Format (rich text), Representation\/PickedFile (clipboard\/files),
-- Op\/Dropped (dnd) and Viewbox\/DrawOp (canvas) as PAYLOAD types, so
-- those five data declarations live here even though the SUGAR that
-- builds and consumes them stays in KayaApp.hs — Run\/Document\/Edit\/
-- Format's wire encoding (documentBlob\/documentOfBlob\/runValues\/
-- runsOfValues\/utf8Bytes\/utf8Chars) is here too, for the same reason:
-- 'instance KayaFieldType Document' (KayaFieldType is this module's) calls
-- documentBlob\/documentOfBlob directly.
--
-- EVERY TYPE HERE EXPORTS ITS CONSTRUCTOR (a uniform '(..)', even where
-- KayaApp.hs's own former export list kept one abstract from guests):
-- KayaApp.hs's remaining code pattern-matches every one of them directly
-- (@Widget n@, @Build $ \\s -> ...@ and so on, the same way it always
-- could when this was one file) and Haskell has no partial re-export —
-- 'module Kaya.Core' in KayaApp.hs's own export list brings across
-- whatever this module exports, in full, so the guest-facing surface
-- widens by exactly these constructors (Signal, Widget, Node, Build, Tpl,
-- BuildState, Collection, RecordCollection, SumCollection, KField,
-- FieldSet, DrawOp) becoming nameable, never buildable into anything a
-- real transaction accepts, from outside. Recorded as the deliberate
-- trade the coordinator's re-export-in-full design makes, not a missed
-- one.
module Kaya.Core
  ( App (..),
    Build (..),
    Tpl (..),
    BuildState (..),
    Counters (..),
    Instance (..),
    Model,
    Fresh,
    Pending (..),
    Widget (..),
    Node (..),
    Signal (..),
    Collection (..),
    RecordCollection (..),
    SumCollection (..),
    CollectionHandle (..),
    Declare (..),
    KayaValue (..),
    KayaFieldType (..),
    KField (..),
    field,
    element,
    KayaRecord (..),
    KayaSum (..),
    GRecord (..),
    GSum (..),
    FieldSet (..),
    Sort (..),
    sortNone,
    sortAsc,
    sortDesc,
    Run (..),
    Document (..),
    Edit (..),
    EditSource (..),
    Format (..),
    Representation (..),
    PickedFile (..),
    Op (..),
    Dropped (..),
    Viewbox (..),
    DrawOp (..),
    assertRoot,
    modelSet,
    modelRemove,
    modelMove,
    lookupEntries,
    withCounter,
    mintKey,
    absorbKey,
    registerCollection,
    emitB,
    emitBIO,
    emitT,
    emitTIO,
    allocW,
    allocN,
    allocM,
    bracketTpl,
    newCollection,
    newRecordCollection,
    collectionOf,
    signal,
    writeSignal,
    recomputeDerived,
    insertEntry,
    insert,
    update,
    remove,
    moveBefore,
    moveToEnd,
    moveToFront,
    moveAfter,
    moveEntry,
    items,
    count,
    each,
    pendB,
    pendT,
    runValues,
    runsOfValues,
    documentBlob,
    documentOfBlob,
    utf8Bytes,
    utf8Chars,
    sumCollectionOf,
    sumInsert,
    sumUpdate,
    sumItems,
    sumGet,
    sumPatch,
    sumUpdateFieldWire,
    sumDerive,
    SumArm (..),
    sumArm,
    eachSum,
    encodeFieldWire,
    encodeFields,
    packDay,
    packTimeOfDay,
    dayOfPacked,
    timeOfDayOfPacked,
    dateValue,
    timeValue,
    recordHandle,
    insertRecord,
    insertFresh,
    updateRecord,
    updateField,
    updateFieldWire,
    set,
    patch,
    recordItems,
    getRecord,
    derive,
  )
where

import Control.Concurrent.MVar (MVar)
import Data.Bits (shiftL)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.ByteString.Builder (Builder, toLazyByteString)
import qualified Data.ByteString.Lazy as BL
import Data.Int (Int64)
import Data.IORef (IORef)
import Data.List (elemIndex)
import qualified Data.List as List
import GHC.Records (HasField)
import GHC.TypeLits (KnownSymbol, symbolVal)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Functor.Identity (Identity (..))
import Control.Monad.State.Strict (State)
import Control.Monad.Trans.State.Strict (StateT (..))
import Data.Time.Calendar (Day, fromGregorian, toGregorian)
import Data.Time.LocalTime (TimeOfDay (..))
import Data.Word (Word32, Word64, Word8)
import GHC.Generics

import KayaRuntime (UndoDelta (..), registerBlob)
import qualified KayaWire as W

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
  at :: KayaValue k => c -> k -> c

instance CollectionHandle Collection where
  at (Collection cid path) key = Collection cid (path ++ [toWire key])

instance CollectionHandle (RecordCollection a) where
  at (RecordCollection c) key = RecordCollection (at c key)

assertRoot :: Collection -> Word64
assertRoot (Collection cid []) = cid
assertRoot _ = error "kaya: forEach binds the collection itself, not an instance — drop the at"

-- | One representation, arriving — the sum a copy is the record of.
-- 'RImage' may be a RE-ENCODE of what was copied, so compare what the
-- image IS, never the bytes it arrived in.
data Representation
  = RText Text
  | RHtml Text
  | RImage BS.ByteString
  | RFiles [PickedFile]
  | RCustom String BS.ByteString

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

-- | One file the picker answered with: a handle to redeem, a display
-- name, and a re-openable name — EMPTY unless re-opening it actually
-- works, which is the three desktops and neither phone (DESIGN.md, File
-- dialogs).
data PickedFile = PickedFile
  { pickedHandle :: !Word64,
    pickedName :: !String,
    pickedLocalPath :: !String
  }

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
  | PNotification !Word64 (Word32 -> IO ())
  | PFileDialog !Word64 ([PickedFile] -> IO ())
  | PClipboardRead !Word64 (Maybe Representation -> IO ())
  | PEntryPopped !Word64 (IO ())
  | PSectionSelected !Word64 (IO ())
  | PBackRequested !Word64 (IO ())
  | PCloseRequested !Word64 (IO ())
  | PWindowClosed !Word64 (IO ())
  | PUndone !Word64 (Text -> UndoDelta -> IO ())
  | PRedone !Word64 (Text -> UndoDelta -> IO ())
  | PChange !Word64 (Text -> IO ())
  | PToggle !Word64 (Bool -> IO ())
  | PValue !Word64 (Double -> IO ())
  | PToggleNode !Word64 ([W.Value] -> Bool -> IO ())
  -- The template node's document bind, recorded at the transaction
  -- boundary because the collection is BuildState's and the table is
  -- the App's (docs/rich-text-plan.md §19).
  | PDocumentBind !Word64 !Word64 !Word32 !Word32
  | PEditNode !Word64 ([W.Value] -> Edit -> IO ())
  | PFormatNode !Word64 ([W.Value] -> Format -> IO ())
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

-- Build/Tpl over mtl's State (docs/traps.md: the hand-rolled Functor
-- \/Applicative\/Monad instances this replaced predated mtl\/transformers
-- being GHC boot packages on this toolchain). The constructor's own type
-- (BuildState -> (a, BuildState)) is unchanged, so every existing
-- 'Build $ \\s -> ...' \/ 'unBuild' call site keeps working; 'deriving via'
-- only replaces the hand-written instances.
newtype Build a = Build {unBuild :: BuildState -> (a, BuildState)}
  deriving (Functor, Applicative, Monad) via (State BuildState)

newtype Tpl a = Tpl {unTpl :: BuildState -> (a, BuildState)}
  deriving (Functor, Applicative, Monad) via (State BuildState)

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
  setTextProp :: El m -> Text -> m ()
  setChecked :: El m -> Bool -> m ()
  -- | This element's flex weight within its row\/column: 0 is natural
  -- size, positive weights divide the leftover main-axis space.
  setGrow :: El m -> Double -> m ()
  -- | Whether this element spans its container's cross axis — a
  -- column's width, a row's height — whatever the container's align
  -- (docs\/layout-knobs-plan.md §1). Unset, the kind's own default holds.
  setFill :: El m -> Bool -> m ()
  -- | THE GRID THAT FITS (docs\/layout-knobs-plan.md §3): as many columns
  -- as fit this grid's width at that many DIP each, sharing the extra.
  -- An explicit 'columnsWhen' still wins while its class holds.
  setColumnsAuto :: El m -> Double -> m ()
  -- | A ROW THAT FLOWS (docs\/layout-knobs-plan.md §2): the children keep
  -- their natural size and move onto the next line when the row runs out
  -- of width, leading-aligned, the row's spacing on both axes. Rows only,
  -- and no child of a wrapping row may grow.
  setWrap :: El m -> Bool -> m ()
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
  collectionOfProxy :: KayaRecord a => Proxy a -> m (RecordCollection a)
  -- | A For over a collection: the do-block declares the template;
  -- returns the For itself alongside the block's result.
  forEach :: Collection -> Tpl a -> m (El m, a)
  -- | Declare the column header bar on a For's container — the element
  -- 'forEach' returns. One title per column; the row template's root
  -- must be a row of exactly one cell per column, refused loudly
  -- otherwise. Re-call after sorting to move the indicator. IN BOTH
  -- ZONES: a nested table's bar is declared in the parent TEMPLATE
  -- scope (docs\/tables-plan.md). Per-copy indicators are 'columnsAt'.
  columns :: El m -> [Text] -> Sort -> m ()
  -- | A When over a Bool signal: stamps on true, unstamps on false.
  when_ :: Signal -> Tpl a -> m (El m, a)

-- | A collection of a-records; the type is the schema —
-- @collectionOf \@Note@, matching 'field'\'s own TypeApplications spelling.
-- IN BOTH ZONES: a NESTED collection must be declared inside the template
-- scope (docs/tables-plan.md).
collectionOf :: forall a m. (KayaRecord a, Declare m) => m (RecordCollection a)
collectionOf = collectionOfProxy (Proxy @a)

instance Declare Build where
  type El Build = Widget
  widget kind = do
    n <- allocW
    emitB (W.txCreateWidget n kind)
    return (Widget n)
  setTextProp (Widget n) txt = emitB (W.txSetText n (T.unpack txt))
  setChecked (Widget n) checked = emitB (W.txSetChecked n checked)
  setGrow (Widget n) weight = emitB (W.txSetGrow n weight)
  setFill (Widget n) on = emitB (W.txSetFill n on)
  setColumnsAuto (Widget n) minWidth =
    emitB (W.txSetColumns n 0) >> emitB (W.txSetMinColumnWidth n minWidth)
  setWrap (Widget n) on = emitB (W.txSetWrap n on)
  setColumns (Widget n) tracks = emitB (W.txSetColumns n (fromIntegral tracks))
  setIndeterminate (Widget n) on = emitB (W.txSetIndeterminate n on)
  addChild (Widget p) (Widget child) = emitB (W.txAddChild p child)
  collection = Build (newCollection [[W.valueStr]])
  collectionOfProxy p = Build (newRecordCollection p)
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
          (map (W.VStr . T.unpack) titles)
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
  setTextProp (Node n) txt = emitT (W.txSetText n (T.unpack txt))
  setChecked (Node n) checked = emitT (W.txSetChecked n checked)
  setGrow (Node n) weight = emitT (W.txSetGrow n weight)
  setFill (Node n) on = emitT (W.txSetFill n on)
  setColumnsAuto (Node n) minWidth =
    emitT (W.txSetColumns n 0) >> emitT (W.txSetMinColumnWidth n minWidth)
  setWrap (Node n) on = emitT (W.txSetWrap n on)
  setColumns (Node n) tracks = emitT (W.txSetColumns n (fromIntegral tracks))
  setIndeterminate (Node n) on = emitT (W.txSetIndeterminate n on)
  addChild (Node p) (Node child) = emitT (W.txAddChild p child)
  collection = Tpl (newCollection [[W.valueStr]])
  collectionOfProxy p = Tpl (newRecordCollection p)
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
          (map (W.VStr . T.unpack) titles)
      )
  when_ (Signal sid) body =
    Tpl $ \s ->
      let ((self, a), s') =
            bracketTpl (unTpl allocN) (`W.txCreateWhen` sid) Nothing body s
       in ((Node self, a), s')

-- | A Haskell type that can cross the wire as one signal or collection-key
-- value — the shape 'KayaFieldType' already is for record fields, extended
-- past the record layer (docs/deferred.md, the idiom pass's F1).
class KayaValue v where
  toWire :: v -> W.Value
  fromWire :: W.Value -> v

instance KayaValue Text where
  toWire = W.VStr . T.unpack
  fromWire v = case v of W.VStr s -> T.pack s; _ -> error "kaya: value is not a Str"

instance KayaValue Bool where
  toWire = W.VBool
  fromWire v = case v of W.VBool b -> b; _ -> error "kaya: value is not a Bool"

instance KayaValue Int64 where
  toWire = W.VI64
  fromWire v = case v of W.VI64 n -> n; _ -> error "kaya: value is not an I64"

instance KayaValue Double where
  toWire = W.VF64
  fromWire v = case v of W.VF64 x -> x; _ -> error "kaya: value is not an F64"

-- | The wire's own tag, as its own representation — the escape hatch a
-- key read back from 'recordItems'\/'items'\/a keyed handler's path needs
-- to round-trip into a write (insert\/update\/remove\/patch\/move*) without
-- a guest ever spelling the tag itself: opaque in, opaque out, through
-- 'fromWire' at the read and this instance at the write.
instance KayaValue W.Value where
  toWire = id
  fromWire = id

signal :: KayaValue v => v -> Build Signal
signal initial = Build $ \s ->
  let c = bCounters s
      n = cSignal c + 1
      s' = s {bCounters = c {cSignal = n}}
   in (Signal n, s' {bRecords = bRecords s' <> pure (W.txCreateSignal n (toWire initial))})

writeSignal :: KayaValue v => Signal -> v -> Build ()
writeSignal (Signal n) v = emitB (W.txWriteSignal n (toWire v))

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

insert :: (KayaValue k, KayaValue v) => Collection -> k -> v -> Build ()
insert (Collection n path) key value = Build $ \s ->
  let key' = toWire key; value' = toWire value
   in ((), insertEntry n path key' [value'] (pure (W.txCollectionInsert n path key' 0 [value'])) s)

update :: (KayaValue k, KayaValue v) => Collection -> k -> v -> Build ()
update (Collection n path) key value = Build $ \s ->
  let key' = toWire key; value' = toWire value
   in ((), recomputeDerived n path
    s {bRecords = bRecords s <> pure (W.txCollectionUpdate n path key' 0 [value']),
       bModel = modelSet n path key' 0 [value'] (bModel s)})

remove :: KayaValue k => Collection -> k -> Build ()
remove (Collection n path) key = Build $ \s ->
  let key' = toWire key
   in ((), recomputeDerived n path
    s {bRecords = bRecords s <> pure (W.txCollectionRemove n path key'),
       bModel = modelRemove (bChildren s) n path key' (bModel s)})

-- | Reposition an entry before another's.
moveBefore :: KayaValue k => Collection -> k -> k -> Build ()
moveBefore c key anchor = moveEntry c (toWire key) [toWire anchor]

-- | Reposition an entry at the end of its collection.
moveToEnd :: KayaValue k => Collection -> k -> Build ()
moveToEnd c key = moveEntry c (toWire key) []

-- | Reposition an entry at the front.
moveToFront :: KayaValue k => Collection -> k -> Build ()
moveToFront c@(Collection n path) key0 = Build $ \s ->
  let key = toWire key0 in
  case map fst (lookupEntries n path (bModel s)) of
    [] -> error ("kaya: move of missing key " ++ show key)
    (first : _) -> unBuild (moveEntry c key [first]) s

-- | Reposition an entry directly after another's.
moveAfter :: KayaValue k => Collection -> k -> k -> Build ()
moveAfter c@(Collection n path) key0 anchor0 = Build $ \s ->
  let key = toWire key0; anchor = toWire anchor0
      keys = map fst (lookupEntries n path (bModel s))
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
  (map (\(k, (_, vs)) -> (k, scalarValue vs)) (lookupEntries n path (bModel s)), s)
  where
    -- A bare 'collection''s schema is the one-field '[[W.valueStr]]' newCollection
    -- always mints, so every entry's value list is a singleton by construction.
    scalarValue [v] = v
    scalarValue vs = error ("kaya: a scalar collection's entry carries " ++ show (length vs) ++ " values")

count :: Collection -> Build Int
count c = length <$> items c

-- | One attribute over one span; 'runValue' is @\"true\"@ for the flags,
-- a URL for @link@, a kind for @block@.
data Run = Run
  { runStart :: !Int,
    runEnd :: !Int,
    runName :: !Text,
    runValue :: !Text
  }
  deriving (Eq, Show)

-- | A @rich@ textarea's text and runs, kept current by the binding from
-- the edits it delivers.
data Document = Document
  { docText :: !Text,
    docRuns :: ![Run]
  }
  deriving (Eq, Show)

-- | Replace @editStart..editEnd@ with 'editInserted', whose runs carry
-- offsets RELATIVE to the inserted text. 'editSource' is what provoked an
-- edit the widget delivered and 'Nothing' on one the app builds.
data Edit = Edit
  { editStart :: !Int,
    editEnd :: !Int,
    editInserted :: !Text,
    editRuns :: ![Run],
    editSource :: !(Maybe EditSource)
  }
  deriving (Eq, Show)

-- | What provoked an edit the widget reports (docs\/rich-text-plan.md R1;
-- the review page's ruling 3, docs\/deferred.md 2026-09-14).
data EditSource = User | ImeCommit | Paste | NativeUndo | Drop
  deriving (Eq, Show)

-- | A toolbar act over a range; 'formatValue' 'Nothing' is the attribute
-- taken off.
data Format = Format
  { formatStart :: !Int,
    formatEnd :: !Int,
    formatName :: !Text,
    formatValue :: !(Maybe Text)
  }
  deriving (Eq, Show)

-- Four values per run — start, end, name, value — the shape both writes
-- and both occurrences carry.
runValues :: [Run] -> [W.Value]
runValues =
  concatMap
    ( \r ->
        [ W.VI64 (fromIntegral (runStart r)),
          W.VI64 (fromIntegral (runEnd r)),
          W.VStr (T.unpack (runName r)),
          W.VStr (T.unpack (runValue r))
        ]
    )

runsOfValues :: [W.Value] -> [Run]
runsOfValues (W.VI64 start : W.VI64 stop : W.VStr name : W.VStr value : rest) =
  Run (fromIntegral start) (fromIntegral stop) (T.pack name) (T.pack value)
    : runsOfValues rest
runsOfValues _ = []

-- | A stamped copy's document is a record FIELD
-- (docs\/rich-text-plan.md §19): the field's Blob bytes are ONE flat
-- value list — the text, then four values per run — the bytes
-- 'setDocument' already ships (crates\/kaya\/src\/wire.rs,
-- @document_blob@).
documentBlob :: Document -> BS.ByteString
documentBlob doc =
  BL.toStrict
    ( toLazyByteString
        (W.encodeValues (W.VStr (T.unpack (docText doc)) : runValues (docRuns doc)))
    )

-- | @documentBlob@'s inverse, over the same 8-byte-aligned layout
-- (@read_document_blob@). A document blob holds Strs and I64s alone, so
-- any other tag is refused naming it rather than silently read as text.
documentOfBlob :: BS.ByteString -> Document
documentOfBlob bytes
  | BS.length bytes < 8 =
      error
        ( "kaya: a document blob carries its count first; this one is "
            ++ show (BS.length bytes)
            ++ " byte(s)"
        )
  | otherwise = case walk 8 (le32 0) of
      (W.VStr txt : rest) -> Document (T.pack txt) (runsOfValues rest)
      vs ->
        error
          ( "kaya: a document blob starts with its text; this one holds "
              ++ show (length vs)
              ++ " value(s)"
          )
  where
    le32 :: Int -> Int
    le32 i =
      sum [fromIntegral (BS.index bytes (i + k)) `shiftL` (8 * k) | k <- [0 .. 3]]
    le64 :: Int -> Int64
    le64 i =
      sum [fromIntegral (BS.index bytes (i + k)) `shiftL` (8 * k) | k <- [0 .. 7]]
    walk :: Int -> Int -> [W.Value]
    walk _ 0 = []
    walk at n =
      let vlen = le32 (at + 4)
          next = at + 8 + ((vlen + 7) `div` 8) * 8
          tag = fromIntegral (le32 at) :: Word32
          v
            | tag == W.valueI64 = W.VI64 (le64 (at + 8))
            | tag == W.valueStr =
                W.VStr (T.unpack (utf8Chars (BS.unpack (BS.take vlen (BS.drop (at + 8) bytes)))))
            | otherwise =
                error
                  ("kaya: a document blob carries Strs and I64s; this one a "
                     ++ show tag)
       in v : walk next (n - 1)

-- Text's own encoder/decoder, over the byte-offset splice 'foldEdit' and
-- 'rangedActBounds' do — no hand-rolled UTF-8 walk (docs/deferred.md, the
-- idiom pass's F3: this replaced a by-hand decoder the F3 finding named
-- directly).
utf8Bytes :: Text -> [Word8]
utf8Bytes = BS.unpack . TE.encodeUtf8

utf8Chars :: [Word8] -> Text
utf8Chars = TE.decodeUtf8 . BS.pack

pendB :: Pending -> Build ()
pendB pending = Build $ \s -> ((), s {bPending = pending : bPending s})

-- | A canvas's coordinate system AND its natural size in
-- device-independent points (docs/canvas-plan.md §3.2). The op stream is
-- written in these units on every platform and in every language, so a
-- scene can freeze it.
data Viewbox = Viewbox Double Double

-- | One drawing op: an opcode and its operands, already the tagged values
-- the wire carries. Opaque — the constructors below are the vocabulary.
newtype DrawOp = DrawOp [W.Value]

pendT :: Pending -> Tpl ()
pendT pending = Tpl $ \s -> ((), s {bPending = pending : bPending s})

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

-- | A sum collection; the type is the variant vocabulary —
-- @sumCollectionOf \@Feed@, matching 'collectionOf'\/'field'\'s spelling.
sumCollectionOf :: forall a. KayaSum a => Build (SumCollection a)
sumCollectionOf = Build $ \s ->
  let p = Proxy @a
      c = bCounters s
      n = cCollection c + 1
      s' = registerCollection n s {bCounters = c {cCollection = n}}
   in ( SumCollection (Collection n []),
        s' {bRecords = bRecords s' <> pure (W.txCreateCollection n (kayaVariantSchemas p))}
      )

-- | Insert witnesses the value's own constructor onto the wire.
sumInsert :: forall a k. (KayaSum a, KayaValue k) => SumCollection a -> k -> a -> Build ()
sumInsert (SumCollection (Collection n path)) key0 value = Build $ \s ->
  let key = toWire key0
      variant = kayaSumVariant value
      vals = kayaSumToValues value
      tags = kayaVariantSchemas (Proxy :: Proxy a) !! fromIntegral variant
   in ((), recomputeDerived n path
        s {bRecords = bRecords s <> (W.txCollectionInsert n path key variant <$> encodeFields tags vals),
           bModel = modelSet n path key variant vals (bModel s)})

-- | Update replaces a record wholesale; a different constructor than
-- the entry's current one restamps its copy in place.
sumUpdate :: forall a k. (KayaSum a, KayaValue k) => SumCollection a -> k -> a -> Build ()
sumUpdate (SumCollection (Collection n path)) key0 value = Build $ \s ->
  let key = toWire key0
      variant = kayaSumVariant value
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
sumGet :: (KayaValue k, KayaSum a) => SumCollection a -> k -> Build (Maybe a)
sumGet (SumCollection (Collection n path)) key0 = Build $ \s ->
  let key = toWire key0 in
  ( fmap (\(v, vs) -> kayaSumFromParts v vs)
      (lookup key (lookupEntries n path (bModel s))),
    s)

-- | The witnessed patch: the scrutinee the guest just matched is the
-- witness — its constructor names the variant — and the model refuses
-- a drifted entry, so the guard is checked, not trusted.
sumPatch :: (KayaValue k, KayaSum a) => SumCollection a -> k -> a -> [FieldSet v] -> Build ()
sumPatch c key0 witness = mapM_ (\(FieldSet i tag v) -> sumUpdateFieldWire c (toWire key0) (kayaSumVariant witness) i tag v)

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
  forall a v. (KayaSum a, KayaValue v) =>
  SumCollection a -> ([(W.Value, a)] -> v) -> Build Signal
sumDerive (SumCollection (Collection n _)) compute0 = Build $ \s ->
  let compute = toWire . compute0
      wireCompute entries = compute (map (\(k, (v, vs)) -> (k, kayaSumFromParts v vs :: a)) entries)
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

-- | A Haskell type that can be one record field.
class KayaFieldType v where
  fieldTag :: proxy v -> Word32
  toFieldValue :: v -> W.Value
  fromFieldValue :: W.Value -> v

instance KayaFieldType Text where
  fieldTag _ = W.valueStr
  toFieldValue = W.VStr . T.unpack
  fromFieldValue v = case v of W.VStr s -> T.pack s; _ -> error "kaya: field is not a Str"

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

-- | A stamped copy's document is a Blob slot whose bytes are the
-- document's own wire list, so it binds through the template zone as a
-- Text field does (docs/rich-text-plan.md §19).
instance KayaFieldType Document where
  fieldTag _ = W.valueBlob
  toFieldValue = W.VStr . BC.unpack . documentBlob
  fromFieldValue v = case v of
    W.VStr s -> documentOfBlob (BC.pack s)
    _ -> error "kaya: field is not a Document"

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

-- | A date as a signal's value — the packed Int64 'KayaValue' already
-- carries; @signal (dateValue d)@ needs no further wrapping.
dateValue :: Day -> Int64
dateValue = packDay

-- | A time as a signal's value, 'dateValue''s reason.
timeValue :: TimeOfDay -> Int64
timeValue = packTimeOfDay

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
element :: KField Text
element = KField 0

-- | A Collection whose entries are a-records.
newtype RecordCollection a = RecordCollection Collection

-- | The plain handle, for forEach.
recordHandle :: RecordCollection a -> Collection
recordHandle (RecordCollection c) = c

insertRecord :: forall a k. (KayaRecord a, KayaValue k) => RecordCollection a -> k -> a -> Build ()
insertRecord (RecordCollection (Collection n path)) key0 value = Build $ \s ->
  let key = toWire key0
      vals = toValues value
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
insertFresh (RecordCollection (Collection n path)) value = Build $ \s ->
  let (mintedKey, fresh) = mintKey n path (bFresh s)
      key = W.VI64 mintedKey
      vals = toValues value
      s' =
        insertEntry n path key vals
          (W.txCollectionInsert n path key 0 <$> encodeFields (kayaSchema (Proxy :: Proxy a)) vals)
          s {bFresh = fresh}
   in (mintedKey, s')

updateRecord :: forall a k. (KayaRecord a, KayaValue k) => RecordCollection a -> k -> a -> Build ()
updateRecord (RecordCollection (Collection n path)) key0 value = Build $ \s ->
  let key = toWire key0
      vals = toValues value
   in ((), recomputeDerived n path
        s {bRecords = bRecords s <> (W.txCollectionUpdate n path key 0 <$> encodeFields (kayaSchema (Proxy :: Proxy a)) vals),
           bModel = modelSet n path key 0 vals (bModel s)})

-- | One field's delta: the rest of the record never travels; the
-- model's copy updates the same slot.
updateField ::
  forall v a k. (KayaFieldType v, KayaValue k) =>
  RecordCollection a -> k -> KField v -> v -> Build ()
updateField c key0 (KField i) value =
  updateFieldWire c (toWire key0) i (fieldTag (Proxy :: Proxy v)) (toFieldValue value)

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
patch :: KayaValue k => RecordCollection a -> k -> [FieldSet a] -> Build ()
patch c key0 = mapM_ (\(FieldSet i tag v) -> updateFieldWire c (toWire key0) i tag v)

-- | The typed model: what this guest wrote, in insertion order.
recordItems :: KayaRecord a => RecordCollection a -> Build [(W.Value, a)]
recordItems (RecordCollection (Collection n path)) = Build $ \s ->
  (map (\(k, (_, vs)) -> (k, fromValues vs)) (lookupEntries n path (bModel s)), s)

-- | A keyed read of one row, 'Nothing' if the key holds no entry — the
-- single-row twin of 'recordItems' (docs/deferred.md, the idiom pass's
-- keyed-read entry).
getRecord :: (KayaRecord a, KayaValue k) => RecordCollection a -> k -> Build (Maybe a)
getRecord (RecordCollection (Collection n path)) key0 = Build $ \s ->
  (fmap (\(_, vs) -> fromValues vs) (lookup (toWire key0) (lookupEntries n path (bModel s))), s)

-- | A signal the binding recomputes from this collection's entries after
-- every mutation, written into the same transaction — the items-left label
-- with no handler remembering to update it.
derive ::
  forall a v. (KayaRecord a, KayaValue v) =>
  RecordCollection a -> ([(W.Value, a)] -> v) -> Build Signal
derive (RecordCollection (Collection n _)) compute0 = Build $ \s ->
  let compute = toWire . compute0
      wireCompute entries = compute (map (\(k, (_, vs)) -> (k, fromValues vs :: a)) entries)
      initial = wireCompute (lookupEntries n [] (bModel s))
      c = bCounters s
      sid = cSignal c + 1
      s' = s {bCounters = c {cSignal = sid},
              bRecords = bRecords s <> pure (W.txCreateSignal sid initial),
              bDerived = Map.insertWith (flip (++)) n [(sid, wireCompute)] (bDerived s)}
   in (Signal sid, s')

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
    appWidgetChanges :: IORef (Map.Map Word64 (Text -> IO ())),
    appNodeChanges :: IORef (Map.Map Word64 ([W.Value] -> Text -> IO ())),
    -- The rich mirror, one Document per @rich@ textarea
    -- (docs/rich-text-plan.md R1): folded from the two occurrences here
    -- and from the app's own setDocument/applyEdit as they are SENT.
    appDocuments :: IORef (Map.Map Word64 Document),
    -- Template node -> (collection, field, level) for every template
    -- textarea bound to a document, so a copy's act folds into its ROW
    -- (docs/rich-text-plan.md §19).
    appDocumentBinds :: IORef (Map.Map Word64 (Word64, Word32, Word32)),
    appNodeEdits :: IORef (Map.Map Word64 ([W.Value] -> Edit -> IO ())),
    appNodeFormats :: IORef (Map.Map Word64 ([W.Value] -> Format -> IO ())),
    appWidgetEdits :: IORef (Map.Map Word64 (Edit -> IO ())),
    appWidgetFormats :: IORef (Map.Map Word64 (Format -> IO ())),
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
    -- One-shot, keyed by the GUEST's notification id (the alert's
    -- request/result grammar; many may be live at once).
    appNotificationHandlers :: IORef (Map.Map Word64 (Word32 -> IO ())),
    -- NOT one-shot, and not keyed at all: the process-level handler for
    -- a result whose id has none above (docs/tasks-s9-plan.md R1). A
    -- relaunched process never called showNotification.
    appNotificationActivation :: IORef (Maybe (Word64 -> Word32 -> IO ())),
    -- NOT one-shot either: a route declared by 'linkRoute' answers every
    -- URL that matches it, for the life of the process
    -- (docs/app-links-plan.md §4), and the core owns the pattern table —
    -- nothing is kept here but the handler.
    appLinkHandlers :: IORef (Map.Map Word64 (Map.Map String String -> IO ())),
    appNextLinkRoute :: IORef Word64,
    -- 'linkRoute' may be called before the first transaction, so its record
    -- waits here for one ('buildTx' drains it head-first).
    appPendingRoutes :: IORef [Builder],
    -- The undo ledger's two reports, keyed by WINDOW. NOT one-shot: a
    -- user walks a history as often as they like.
    appUndone :: IORef (Map.Map Word64 (Text -> UndoDelta -> IO ())),
    appRedone :: IORef (Map.Map Word64 (Text -> UndoDelta -> IO ())),
    appFileDialogHandlers :: IORef (Map.Map Word64 ([PickedFile] -> IO ())),
    -- Clipboard reads share the alert's request/result grammar and so
    -- its table shape: one-shot, keyed by request id.
    appClipboardReads :: IORef (Map.Map Word64 (Maybe Representation -> IO ())),
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
