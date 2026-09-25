{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
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
    AlertChoice (..),
    alertChoiceOfWire,
    NotificationOutcome (..),
    notificationOutcomeOfWire,
    Widget (..),
    Node (..),
    Signal (..),
    Collection (..),
    RecordCollection (..),
    SumCollection (..),
    CollectionHandle (..),
    Declare (..),
    -- The constructor stops here: 'textKey', 'intKey' and the literal
    -- instances are the only ways to make one, which is what keeps
    -- 'keyText' and 'keyInt' total.
    Key,
    keyValue,
    textKey,
    intKey,
    keyText,
    keyInt,
    keyOfWire,
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
    MarkValue (..),
    markSpelling,
    markValueOf,
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
    rootOf,
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
    signalText,
    signalBool,
    signalInt,
    signalDouble,
    signalDate,
    signalTime,
    signalImage,
    writeSignal,
    tshow,
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
import Control.Monad.State.Strict (MonadState, State, gets, modify', runState, state)
import Control.Monad.Trans.State.Strict (StateT (..))
import Data.Time.Calendar (Day, fromGregorian, toGregorian)
import Data.Time.LocalTime (TimeOfDay (..))
import Data.Word (Word32, Word64, Word8)
import GHC.Generics

import KayaRuntime
  ( Key,
    UndoDelta (..),
    intKey,
    keyInt,
    keyOfWire,
    keyText,
    keyValue,
    registerBlob,
    textKey,
  )
import qualified KayaWire as W

-- | A signal, carrying the type it holds: the phantom is what lets
-- 'writeSignal' and every @*Bound@ constructor infer a bare literal
-- (docs\/deferred.md, the Haskell text-surface entry).
newtype Signal v = Signal Word64

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
  at :: c -> Key -> c

instance CollectionHandle Collection where
  at (Collection cid path) key = Collection cid (path ++ [keyValue key])

instance CollectionHandle (RecordCollection a) where
  at (RecordCollection c) key = RecordCollection (at c key)

-- | The collection ITSELF, or 'Nothing' for one of its stamped
-- instances: a For binds a whole collection, never the copy-keyed table
-- inside one, and this is how a caller asks which it holds.
rootOf :: Collection -> Maybe Word64
rootOf (Collection cid []) = Just cid
rootOf _ = Nothing

-- The three For-openers' shared refusal, in the one place that can name
-- the verb. A TYPE would say this instead and is the ruling to take: a
-- phantom on Collection\/RecordCollection\/SumCollection that 'at' moves
-- from root to stamped, so 'forEach' takes only the root and the write
-- verbs take either. That is 94 Collection mentions in this file; it was
-- out of this pass's budget and is recorded on the ledger.
forRoot :: String -> Collection -> Word64
forRoot verb coll = case rootOf coll of
  Just cid -> cid
  Nothing ->
    errorWithoutStackTrace
      ( "kaya: " ++ verb ++ " binds the collection itself, not an instance "
          ++ "— drop the at" )

-- | One representation, arriving — the sum a copy is the record of.
-- 'RImage' may be a RE-ENCODE of what was copied, so compare what the
-- image IS, never the bytes it arrived in.
data Representation
  = RText Text
  | RHtml Text
  | RImage BS.ByteString
  | RFiles [PickedFile]
  | RCustom Text BS.ByteString

-- | A drag operation (docs\/dnd-plan.md D3): copy and move, nothing
-- else; 'Nothing' is the outcome of a cancelled or refused drag.
data Op = OpCopy | OpMove
  deriving (Eq, Show)

-- | What a drop delivered (docs\/dnd-plan.md D1): the representation a
-- paste already delivers, the point in the destination's own
-- coordinates, the operation the core settled on, and — for a reorder —
-- the anchor row and the side it landed on.
data Dropped = Dropped
  { point :: (Double, Double),
    operation :: Maybe Op,
    anchor :: [Key],
    before :: Bool,
    clip :: Maybe Representation
  }

-- | One file the picker answered with: a handle to redeem, a display
-- name, and a re-openable name — EMPTY unless re-opening it actually
-- works, which is the three desktops and neither phone (DESIGN.md, File
-- dialogs).
data PickedFile = PickedFile
  { handle :: !Word64,
    name :: !Text,
    -- | A 'FilePath' and not 'Text': this is what @openFile@,
    -- @removeFile@ and @(\<\/\>)@ take.
    localPath :: !FilePath
  }

-- | WHAT THE USER DID WITH AN ALERT: an action by its 0-based index, or
-- the dismissal that names none.
data AlertChoice = AlertAction !Int | AlertCancel
  deriving (Eq, Show)

alertChoiceOfWire :: Word32 -> AlertChoice
alertChoiceOfWire c
  | c == W.alertChoiceCancel = AlertCancel
  | otherwise = AlertAction (fromIntegral c)

-- | WHAT BECAME OF A NOTIFICATION (spec enum @notification_outcome@).
data NotificationOutcome = NotificationActivated | NotificationRefused
  deriving (Eq, Show)

notificationOutcomeOfWire :: Word32 -> NotificationOutcome
notificationOutcomeOfWire o
  | o == W.notificationOutcomeActivated = NotificationActivated
  | otherwise = NotificationRefused

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
  | PAlert !Word64 (AlertChoice -> IO ())
  | PNotification !Word64 (NotificationOutcome -> IO ())
  | PFileDialog !Word64 ([PickedFile] -> IO ())
  | PClipboardRead !Word64 (Maybe Representation -> IO ())
  | PEntryPopped !Word64 (IO ())
  | PSectionSelected !Word64 (IO ())
  | PBackRequested !Word64 (IO ())
  | PSheetDismissed !Word64 (IO ())
  | PDismissRequested !Word64 (IO ())
  | PCloseRequested !Word64 (IO ())
  | PWindowClosed !Word64 (IO ())
  | PUndone !Word64 (Text -> UndoDelta -> IO ())
  | PRedone !Word64 (Text -> UndoDelta -> IO ())
  | PChange !Word64 (Text -> IO ())
  | PToggle !Word64 (Bool -> IO ())
  | PValue !Word64 (Double -> IO ())
  | PToggleNode !Word64 ([Key] -> Bool -> IO ())
  -- The template node's document bind, recorded at the transaction
  -- boundary because the collection is BuildState's and the table is
  -- the App's (docs/rich-text-plan.md §19).
  | PDocumentBind !Word64 !Word64 !Word32 !Word32
  | PEditNode !Word64 ([Key] -> Edit -> IO ())
  | PFormatNode !Word64 ([Key] -> Format -> IO ())
  | PDate !Word64 (Day -> IO ())
  | PTime !Word64 (TimeOfDay -> IO ())
  | PDateNode !Word64 ([Key] -> Day -> IO ())
  | PTimeNode !Word64 ([Key] -> TimeOfDay -> IO ())
  | PMenuActivated !Word64 (IO ())
  | PMenuActivatedNode !Word64 ([Key] -> IO ())
  | PMenuToggled !Word64 (Bool -> IO ())
  | PMenuToggledNode !Word64 ([Key] -> Bool -> IO ())
  | PMenuSelected !Word64 (Int -> IO ())
  | PMenuSelectedNode !Word64 ([Key] -> Int -> IO ())

modelSet :: Word64 -> [W.Value] -> W.Value -> Word32 -> [W.Value] -> Model -> Model
modelSet cid path key variant fields model =
  Map.insert cid (go (Map.findWithDefault [] cid model)) model
  where
    value = (variant, fields)
    go [] = [Instance path [(key, value)]]
    go (i : rest)
      | i.iPath == path = i {iEntries = upsert (i.iEntries)} : rest
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
      | i.iPath == path = i {iEntries = filter ((/= key) . fst) (i.iEntries)}
      | otherwise = i
    purge c pre m =
      foldr
        (\kid acc -> purge kid pre (Map.adjust (filter (not . startsWith pre . (.iPath))) kid acc))
        m
        (Map.findWithDefault [] c children)
    startsWith pre p = take (length pre) p == pre

-- The mechanical reorder; moveEntry validates key and anchor first,
-- so the anchor is always present here when given.
modelMove :: Word64 -> [W.Value] -> W.Value -> [W.Value] -> Model -> Model
modelMove cid path key before = Map.adjust (map go) cid
  where
    go i
      | i.iPath == path,
        Just value <- lookup key (i.iEntries) =
          i {iEntries = place (key, value) (filter ((/= key) . fst) (i.iEntries))}
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
  case filter ((== path) . (.iPath)) (Map.findWithDefault [] cid model) of
    (i : _) -> i.iEntries
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
registerCollection cid s = case s.bOpenFors of
  parent : _ -> s {bChildren = Map.insertWith (flip (++)) parent [cid] (s.bChildren)}
  [] -> s

-- Build and Tpl ARE mtl's State (docs/traps.md: the hand-rolled Functor
-- \/Applicative\/Monad instances this replaced predated mtl\/transformers
-- being GHC boot packages on this toolchain). Newtype-derived down to
-- 'MonadState', so this file writes 'state', 'gets' and 'modify'' rather
-- than threading a BuildState by hand; 'runState' is how the two places
-- that need the raw function get it.
newtype Build a = Build {unBuild :: State BuildState a}
  deriving newtype (Functor, Applicative, Monad, MonadState BuildState)

newtype Tpl a = Tpl {unTpl :: State BuildState a}
  deriving newtype (Functor, Applicative, Monad, MonadState BuildState)

emitB :: Builder -> Build ()
emitB = emitBIO . pure

emitBIO :: IO Builder -> Build ()
emitBIO r = modify' $ \s -> s {bRecords = s.bRecords <> r}

emitT :: Builder -> Tpl ()
emitT = emitTIO . pure

emitTIO :: IO Builder -> Tpl ()
emitTIO r = modify' $ \s -> s {bRecords = s.bRecords <> r}

allocW :: Build Word64
allocW = state $ \s ->
  let c = s.bCounters
      n = c.cWidget + 1
   in (n, s {bCounters = c {cWidget = n}})

allocN :: Tpl Word64
allocN = state $ \s ->
  let c = s.bCounters
      n = c.cWidget + 1
   in (n, s {bCounters = c {cWidget = n}})

-- Menu items get their OWN id space (the c_menu_item counter) — never a
-- widget, node, or surface id.
allocM :: Build Word64
allocM = state $ \s ->
  let c = s.bCounters
      n = c.cMenuItem + 1
   in (n, s {bCounters = c {cMenuItem = n}})

bracketTpl :: (BuildState -> (Word64, BuildState)) -> (Word64 -> Builder) -> Maybe Word64
           -> Tpl a -> BuildState -> ((Word64, a), BuildState)
bracketTpl alloc opener forCid body0 s0 =
  let body = runState body0.unTpl
      (self, s1) = alloc s0
      s2 = s1
        { bRecords = s1.bRecords <> pure (opener self),
          bOpenFors = maybe (s1.bOpenFors) (: s1.bOpenFors) forCid
        }
      (a, s3) = body s2
      s4 = s3
        { bRecords = s3.bRecords <> pure W.txTemplateEnd,
          bOpenFors = maybe (s3.bOpenFors) (const (drop 1 (s3.bOpenFors))) forCid
        }
   in ((self, a), s4)

newCollection :: [[Word32]] -> BuildState -> (Collection, BuildState)
newCollection variants s =
  let c = s.bCounters
      n = c.cCollection + 1
      s' = registerCollection n s {bCounters = c {cCollection = n}}
   in (Collection n [], s' {bRecords = s'.bRecords <> pure (W.txCreateCollection n variants)})

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
  -- | A container's cross-axis child placement, as its wire number
  -- (KayaApp's 'Align' spells it); rows centre by default (R5).
  setAlignWire :: El m -> Int64 -> m ()
  -- | A container's fill, as its tint's wire number (KayaApp's 'Tint').
  setFilledWire :: El m -> Int64 -> m ()
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
  when_ :: Signal Bool -> Tpl a -> m (El m, a)

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
  setAlignWire (Widget n) a = emitB (W.txSetAlign n a)
  setFilledWire (Widget n) t = emitB (W.txSetFilled n t)
  setColumnsAuto (Widget n) minWidth =
    emitB (W.txSetColumns n 0) >> emitB (W.txSetMinColumnWidth n minWidth)
  setWrap (Widget n) on = emitB (W.txSetWrap n on)
  setColumns (Widget n) tracks = emitB (W.txSetColumns n (fromIntegral tracks))
  setIndeterminate (Widget n) on = emitB (W.txSetIndeterminate n on)
  addChild (Widget p) (Widget child) = emitB (W.txAddChild p child)
  collection = state (newCollection [[W.valueStr]])
  collectionOfProxy p = state (newRecordCollection p)
  forEach coll body =
    state $ \s ->
      let cid = forRoot "forEach" coll
          ((self, a), s') =
            bracketTpl (runState allocW.unBuild) (`W.txCreateFor` cid) (Just cid) body s
       in ((Widget self, a), s')
  -- pathLen 0 against a LIVE container: the flat table's bar.
  columns (Widget n) titles sort =
    emitB
      ( W.txSetColumnHeaders
          n
          (sort.sortColumn)
          (sort.sortDirection)
          (fromIntegral (length titles))
          0
          (map (W.VStr . T.unpack) titles)
      )
  when_ (Signal sid) body =
    state $ \s ->
      let ((self, a), s') =
            bracketTpl (runState allocW.unBuild) (`W.txCreateWhen` sid) Nothing body s
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
  setAlignWire (Node n) a = emitT (W.txSetAlign n a)
  setFilledWire (Node n) t = emitT (W.txSetFilled n t)
  setColumnsAuto (Node n) minWidth =
    emitT (W.txSetColumns n 0) >> emitT (W.txSetMinColumnWidth n minWidth)
  setWrap (Node n) on = emitT (W.txSetWrap n on)
  setColumns (Node n) tracks = emitT (W.txSetColumns n (fromIntegral tracks))
  setIndeterminate (Node n) on = emitT (W.txSetIndeterminate n on)
  addChild (Node p) (Node child) = emitT (W.txAddChild p child)
  collection = state (newCollection [[W.valueStr]])
  collectionOfProxy p = state (newRecordCollection p)
  forEach coll body =
    state $ \s ->
      let cid = forRoot "forEach" coll
          ((self, a), s') =
            bracketTpl (runState allocN.unTpl) (`W.txCreateFor` cid) (Just cid) body s
       in ((Node self, a), s')
  -- pathLen 0 against a TEMPLATE NODE: every copy's bar.
  columns (Node n) titles sort =
    emitT
      ( W.txSetColumnHeaders
          n
          (sort.sortColumn)
          (sort.sortDirection)
          (fromIntegral (length titles))
          0
          (map (W.VStr . T.unpack) titles)
      )
  when_ (Signal sid) body =
    state $ \s ->
      let ((self, a), s') =
            bracketTpl (runState allocN.unTpl) (`W.txCreateWhen` sid) Nothing body s
       in ((Node self, a), s')

-- | A Haskell type that can cross the wire as one signal or collection-key
-- value — the shape 'KayaFieldType' already is for record fields, extended
-- past the record layer (docs/deferred.md, the idiom pass's F1).
class KayaValue v where
  toWire :: v -> W.Value
  fromWire :: W.Value -> v

  -- | The TRANSACTION BOUNDARY's encode, where a Blob-tagged value
  -- registers its bytes with the core in record order —
  -- 'encodeFieldWire' is the record-field twin. Everything else travels
  -- as 'toWire' says.
  toWireIO :: v -> IO W.Value
  toWireIO = pure . toWire

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

-- | A civil date as a signal's value: the packed I64 a date picker binds
-- to (docs\/datetime-plan.md D2), so @signalDate@ and a picker's
-- @Signal Day@ are one type.
instance KayaValue Day where
  toWire = W.VI64 . packDay
  fromWire v = case v of W.VI64 n -> dayOfPacked n; _ -> error "kaya: value is not a Date"

instance KayaValue TimeOfDay where
  toWire = W.VI64 . packTimeOfDay
  fromWire v = case v of W.VI64 n -> timeOfDayOfPacked n; _ -> error "kaya: value is not a Time"

-- | Encoded image bytes, the 'KayaFieldType' Blob instance one slot over:
-- the model's mirror holds the bytes as a Str and the boundary registers
-- them, which is what 'toWireIO' exists for.
instance KayaValue BS.ByteString where
  toWire = W.VStr . BC.unpack
  fromWire v = case v of W.VStr s -> BC.pack s; _ -> error "kaya: value is not a Blob"
  toWireIO = fmap W.VBlob . registerBlob

-- | The wire's own tag, as its own representation — kept for the
-- binding's own round trips; a guest reaches for 'Key'.
instance KayaValue W.Value where
  toWire = id
  fromWire = id

-- ONE CREATOR PER VALUE TYPE, deliberately: a class-polymorphic
-- @signal@ cannot infer @signal "idle"@ under OverloadedStrings, so
-- every guest paid an ascription or a 'T.pack' for it (docs/deferred.md,
-- the Haskell text-surface entry). The phantom carries the type on from
-- here, so 'writeSignal' and every @*Bound@ site infer their literals.
newSignal :: KayaValue v => v -> Build (Signal v)
newSignal initial = state $ \s ->
  let c = s.bCounters
      n = c.cSignal + 1
      s' = s {bCounters = c {cSignal = n}}
   in (Signal n, s' {bRecords = s'.bRecords <> (W.txCreateSignal n <$> toWireIO initial)})

-- | A text signal: a label's caption, a menu item's label, an a11y prop.
signalText :: Text -> Build (Signal Text)
signalText = newSignal

-- | A boolean signal: a When's condition, an item's enablement or check.
signalBool :: Bool -> Build (Signal Bool)
signalBool = newSignal

-- | A whole-number signal.
signalInt :: Int64 -> Build (Signal Int64)
signalInt = newSignal

-- | A fractional signal: a slider's position, a progress fraction, a
-- choice's 0-based index, a badge's count.
signalDouble :: Double -> Build (Signal Double)
signalDouble = newSignal

-- | A civil-date signal, for a bound date picker (docs\/datetime-plan.md
-- D2): the packing is the instance's.
signalDate :: Day -> Build (Signal Day)
signalDate = newSignal

-- | A civil-time signal, for a bound time picker.
signalTime :: TimeOfDay -> Build (Signal TimeOfDay)
signalTime = newSignal

-- | An image signal: the bytes register with the core at the
-- transaction boundary, as a record's Blob field does.
signalImage :: BS.ByteString -> Build (Signal BS.ByteString)
signalImage = newSignal

writeSignal :: KayaValue v => Signal v -> v -> Build ()
writeSignal (Signal n) v = emitBIO (W.txWriteSignal n <$> toWireIO v)

-- | @show@ into 'Text', which is what a Text-first program writes where
-- a display string is assembled: @tshow n \<\> " items left"@.
tshow :: Show a => a -> Text
tshow = T.pack . show

recomputeDerived :: Word64 -> [W.Value] -> BuildState -> BuildState
recomputeDerived cid path s
  | not (null path) = s
  | otherwise =
      let entries = lookupEntries cid [] (s.bModel)
          writes =
            foldMap
              (\(sid, f) -> W.txWriteSignal sid (f entries))
              (Map.findWithDefault [] cid (s.bDerived))
       in s {bRecords = s.bRecords <> pure writes}

insertEntry :: Word64 -> [W.Value] -> W.Value -> [W.Value] -> IO Builder -> BuildState -> BuildState
insertEntry n path key vals record s0 =
  let s = s0 {bFresh = absorbKey n path key (s0.bFresh)}
   in recomputeDerived n path
        s {bRecords = s.bRecords <> record,
           bModel = modelSet n path key 0 vals (s.bModel)}

-- | THE VALUE SLOT IS 'Text' AND THE KEY SLOT IS NOT: a bare
-- 'collection''s schema is one Str field, so a value literal infers,
-- while a key is a Text the guest authored or an 'insertFresh' I64.
insert :: Collection -> Key -> Text -> Build ()
insert (Collection n path) key value = state $ \s ->
  let key' = keyValue key; value' = toWire value
   in ((), insertEntry n path key' [value'] (pure (W.txCollectionInsert n path key' 0 [value'])) s)

update :: Collection -> Key -> Text -> Build ()
update (Collection n path) key value = state $ \s ->
  let key' = keyValue key; value' = toWire value
   in ((), recomputeDerived n path
    s {bRecords = s.bRecords <> pure (W.txCollectionUpdate n path key' 0 [value']),
       bModel = modelSet n path key' 0 [value'] (s.bModel)})

remove :: Collection -> Key -> Build ()
remove (Collection n path) key = state $ \s ->
  let key' = keyValue key
   in ((), recomputeDerived n path
    s {bRecords = s.bRecords <> pure (W.txCollectionRemove n path key'),
       bModel = modelRemove (s.bChildren) n path key' (s.bModel)})

-- | Reposition an entry before another's.
moveBefore :: Collection -> Key -> Key -> Build ()
moveBefore c key anchor = moveEntry c (keyValue key) [keyValue anchor]

-- | Reposition an entry at the end of its collection.
moveToEnd :: Collection -> Key -> Build ()
moveToEnd c key = moveEntry c (keyValue key) []

-- | Reposition an entry at the front.
moveToFront :: Collection -> Key -> Build ()
moveToFront c@(Collection n path) key0 = state $ \s ->
  let key = keyValue key0 in
  case map fst (lookupEntries n path (s.bModel)) of
    [] -> error ("kaya: move of missing key " ++ show key)
    (first : _) -> runState (moveEntry c key [first]).unBuild s

-- | Reposition an entry directly after another's.
moveAfter :: Collection -> Key -> Key -> Build ()
moveAfter c@(Collection n path) key0 anchor0 = state $ \s ->
  let key = keyValue key0; anchor = keyValue anchor0
      keys = map fst (lookupEntries n path (s.bModel))
   in if key `notElem` keys
        then error ("kaya: move of missing key " ++ show key)
        else case dropWhile (/= anchor) keys of
          [] -> error ("kaya: move after missing key " ++ show anchor)
          _ | key == anchor -> ((), s)
          [_] -> runState (moveEntry c key []).unBuild s
          (_ : succKey : _)
            | succKey == key -> ((), s) -- already directly after the anchor
            | otherwise -> runState (moveEntry c key [succKey]).unBuild s

moveEntry :: Collection -> W.Value -> [W.Value] -> Build ()
moveEntry (Collection n path) key before = state $ \s ->
  let keys = map fst (lookupEntries n path (s.bModel))
   in if key `notElem` keys
        then error ("kaya: move of missing key " ++ show key)
        else case before of
          (anchor : _)
            | anchor `notElem` keys ->
                error ("kaya: move before missing key " ++ show anchor)
            | anchor == key -> ((), s) -- moving before itself: no-op
          _ ->
            ((), recomputeDerived n path
              s {bRecords = s.bRecords <> pure (W.txCollectionMove n path key before),
                 bModel = modelMove n path key before (s.bModel)})

-- | The model: what this guest wrote, exactly — the fold of every
-- patch so far (this transaction's included), in insertion order.
items :: Collection -> Build [(Key, Text)]
items (Collection n path) =
  gets (map (\(k, (_, vs)) -> (keyOfWire k, fromWire (scalarValue vs)))
          . lookupEntries n path
          . (.bModel))
  where
    -- A bare 'collection''s schema is the one-field '[[W.valueStr]]' newCollection
    -- always mints, so every entry's value list is a singleton by construction.
    scalarValue [v] = v
    scalarValue vs = error ("kaya: a scalar collection's entry carries " ++ show (length vs) ++ " values")

count :: Collection -> Build Int
count c = length <$> items c

-- | WHAT A MARK IS WORTH: the five flags are BOOLEANS, and link and block
-- carry text. The wire spells a flag @\"true\"@ and spells OFF by leaving
-- the run out, which is a thing no guest should have to know (the idiom
-- review's X2).
data MarkValue = Flag !Bool | Spelled !Text
  deriving (Eq, Show)

-- The wire's own spelling of a mark value, and its inverse.
markSpelling :: MarkValue -> Text
markSpelling (Flag on) = if on then "true" else "false"
markSpelling (Spelled t) = t

markValueOf :: Text -> MarkValue
markValueOf "true" = Flag True
markValueOf "false" = Flag False
markValueOf t = Spelled t

-- | One attribute over one RANGE of UTF-8 byte offsets, half-open — the
-- same @(start, stop)@ pair the ranges sugar takes everywhere
-- (docs\/ranges-units.md), so a second range type would be one spelling
-- too many.
data Run = Run
  { range :: !(Int, Int),
    name :: !Text,
    value :: !MarkValue
  }
  deriving (Eq, Show)

-- | A @rich@ textarea's text and runs, kept current by the binding from
-- the edits it delivers.
data Document = Document
  { text :: !Text,
    runs :: ![Run]
  }
  deriving (Eq, Show)

-- | Replace @editStart..editEnd@ with 'editInserted', whose runs carry
-- offsets RELATIVE to the inserted text. 'editSource' is what provoked an
-- edit the widget delivered and 'Nothing' on one the app builds.
data Edit = Edit
  { range :: !(Int, Int),
    inserted :: !Text,
    runs :: ![Run],
    source :: !(Maybe EditSource)
  }
  deriving (Eq, Show)

-- | What provoked an edit the widget reports (docs\/rich-text-plan.md R1;
-- the review page's ruling 3, docs\/deferred.md 2026-09-14).
data EditSource = User | ImeCommit | Paste | NativeUndo | Drop
  deriving (Eq, Show)

-- | A toolbar act over a range; 'formatValue' 'Nothing' is the attribute
-- taken off.
data Format = Format
  { range :: !(Int, Int),
    name :: !Text,
    value :: !(Maybe MarkValue)
  }
  deriving (Eq, Show)

-- Four values per run — start, end, name, value — the shape both writes
-- and both occurrences carry.
runValues :: [Run] -> [W.Value]
runValues =
  concatMap
    ( \r ->
        let (from, to) = r.range
         in [ W.VI64 (fromIntegral from),
              W.VI64 (fromIntegral to),
              W.VStr (T.unpack r.name),
              W.VStr (T.unpack (markSpelling r.value))
            ]
    )

runsOfValues :: [W.Value] -> [Run]
runsOfValues (W.VI64 from : W.VI64 to : W.VStr n : W.VStr v : rest) =
  Run (fromIntegral from, fromIntegral to) (T.pack n) (markValueOf (T.pack v))
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
        (W.encodeValues (W.VStr (T.unpack doc.text) : runValues doc.runs))
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
pendB pending = modify' $ \s -> s {bPending = pending : s.bPending}

-- | A canvas's coordinate system AND its natural size in
-- device-independent points (docs/canvas-plan.md §3.2). The op stream is
-- written in these units on every platform and in every language, so a
-- scene can freeze it.
data Viewbox = Viewbox Double Double

-- | One drawing op: an opcode and its operands, already the tagged values
-- the wire carries. Opaque — the constructors below are the vocabulary.
newtype DrawOp = DrawOp [W.Value]

pendT :: Pending -> Tpl ()
pendT pending = modify' $ \s -> s {bPending = pending : s.bPending}

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
sumCollectionOf = state $ \s ->
  let p = Proxy @a
      c = s.bCounters
      n = c.cCollection + 1
      s' = registerCollection n s {bCounters = c {cCollection = n}}
   in ( SumCollection (Collection n []),
        s' {bRecords = s'.bRecords <> pure (W.txCreateCollection n (kayaVariantSchemas p))}
      )

-- | Insert witnesses the value's own constructor onto the wire.
sumInsert :: forall a. KayaSum a => SumCollection a -> Key -> a -> Build ()
sumInsert (SumCollection (Collection n path)) key0 value = state $ \s ->
  let key = keyValue key0
      variant = kayaSumVariant value
      vals = kayaSumToValues value
      tags = kayaVariantSchemas (Proxy :: Proxy a) !! fromIntegral variant
   in ((), recomputeDerived n path
        s {bRecords = s.bRecords <> (W.txCollectionInsert n path key variant <$> encodeFields tags vals),
           bModel = modelSet n path key variant vals (s.bModel)})

-- | Update replaces a record wholesale; a different constructor than
-- the entry's current one restamps its copy in place.
sumUpdate :: forall a. KayaSum a => SumCollection a -> Key -> a -> Build ()
sumUpdate (SumCollection (Collection n path)) key0 value = state $ \s ->
  let key = keyValue key0
      variant = kayaSumVariant value
      vals = kayaSumToValues value
      tags = kayaVariantSchemas (Proxy :: Proxy a) !! fromIntegral variant
   in ((), recomputeDerived n path
        s {bRecords = s.bRecords <> (W.txCollectionUpdate n path key variant <$> encodeFields tags vals),
           bModel = modelSet n path key variant vals (s.bModel)})

-- | The typed model, in insertion order; `case` eliminates the values.
sumItems :: KayaSum a => SumCollection a -> Build [(Key, a)]
sumItems (SumCollection (Collection n path)) =
  gets (map (\(k, (v, vs)) -> (keyOfWire k, kayaSumFromParts v vs))
          . lookupEntries n path
          . (.bModel))

-- | The entry's current value — the scrutinee for the match that
-- precedes a patch.
sumGet :: KayaSum a => SumCollection a -> Key -> Build (Maybe a)
sumGet (SumCollection (Collection n path)) key0 =
  gets (fmap (\(v, vs) -> kayaSumFromParts v vs)
          . lookup (keyValue key0)
          . lookupEntries n path
          . (.bModel))

-- | The witnessed patch: the scrutinee the guest just matched is the
-- witness — its constructor names the variant — and the model refuses
-- a drifted entry, so the guard is checked, not trusted.
sumPatch :: KayaSum a => SumCollection a -> Key -> a -> [FieldSet v] -> Build ()
sumPatch c key0 witness = mapM_ (\(FieldSet i tag v) -> sumUpdateFieldWire c (keyValue key0) (kayaSumVariant witness) i tag v)

sumUpdateFieldWire :: SumCollection a -> W.Value -> Word32 -> Word32 -> Word32 -> W.Value -> Build ()
sumUpdateFieldWire (SumCollection (Collection n path)) key variant i tag value = state $ \s ->
  let (stored, current) = case lookup key (lookupEntries n path (s.bModel)) of
        Just (v, vs) -> (v, vs)
        Nothing -> error "kaya: update of missing key"
      updated = take (fromIntegral i) current ++ [value] ++ drop (fromIntegral i + 1) current
   in if stored /= variant
        then error "kaya: update_field witnessed a constructor the entry no longer holds"
        else
          ((), recomputeDerived n path
            s {bRecords = s.bRecords <> (W.txCollectionUpdateField n path key i variant <$> encodeFieldWire tag value),
               bModel = modelSet n path key variant updated (s.bModel)})

-- | The collection-derived signal, over the sum's entries.
sumDerive ::
  forall a v. (KayaSum a, KayaValue v) =>
  SumCollection a -> ([(Key, a)] -> v) -> Build (Signal v)
sumDerive (SumCollection (Collection n _)) compute0 = state $ \s ->
  let compute = toWire . compute0
      wireCompute entries = compute (map (\(k, (v, vs)) -> (keyOfWire k, kayaSumFromParts v vs :: a)) entries)
      initial = wireCompute (lookupEntries n [] (s.bModel))
      c = s.bCounters
      sid = c.cSignal + 1
      s' = s {bCounters = c {cSignal = sid},
              bRecords = s.bRecords <> pure (W.txCreateSignal sid initial),
              bDerived = Map.insertWith (flip (++)) n [(sid, wireCompute)] (s.bDerived)}
   in (Signal sid, s')

-- | One arm of the template eliminator: the prototype value names the
-- constructor, the Tpl program is its blueprint.
data SumArm = SumArm !Word32 (Tpl ())

sumArm :: KayaSum a => a -> Tpl () -> SumArm
sumArm prototype = SumArm (kayaSumVariant prototype)

-- | The template eliminator: a product of arms, one per constructor, handed
-- over whole.
eachSum :: forall a. KayaSum a => SumCollection a -> [SumArm] -> Build Widget
eachSum (SumCollection coll) arms = state $ \s ->
  let count = length (kayaVariantSchemas (Proxy :: Proxy a))
      variants = map (\(SumArm v _) -> v) arms
      _checked
        | length arms /= count =
            error ("kaya: the eliminator needs " ++ show count ++ " arms, got " ++ show (length arms))
        | length (List.nub variants) /= length variants =
            error "kaya: two arms for one constructor"
        | otherwise = ()
      -- Each arm opens with its own variant_case record.
      body = mapM_ (\(SumArm v arm) -> modify' (caseOf v) >> arm) arms
      caseOf v st = st {bRecords = st.bRecords <> pure (W.txVariantCase v)}
      ((self, _), s') =
        _checked `seq`
        bracketTpl (runState allocW.unBuild) (`W.txCreateFor` cid) (Just cid) body s
      cid = forRoot "eachSum" coll
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

insertRecord :: forall a. KayaRecord a => RecordCollection a -> Key -> a -> Build ()
insertRecord (RecordCollection (Collection n path)) key0 value = state $ \s ->
  let key = keyValue key0
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
insertFresh (RecordCollection (Collection n path)) value = state $ \s ->
  let (mintedKey, fresh) = mintKey n path (s.bFresh)
      key = W.VI64 mintedKey
      vals = toValues value
      s' =
        insertEntry n path key vals
          (W.txCollectionInsert n path key 0 <$> encodeFields (kayaSchema (Proxy :: Proxy a)) vals)
          s {bFresh = fresh}
   in (mintedKey, s')

updateRecord :: forall a. KayaRecord a => RecordCollection a -> Key -> a -> Build ()
updateRecord (RecordCollection (Collection n path)) key0 value = state $ \s ->
  let key = keyValue key0
      vals = toValues value
   in ((), recomputeDerived n path
        s {bRecords = s.bRecords <> (W.txCollectionUpdate n path key 0 <$> encodeFields (kayaSchema (Proxy :: Proxy a)) vals),
           bModel = modelSet n path key 0 vals (s.bModel)})

-- | One field's delta: the rest of the record never travels; the
-- model's copy updates the same slot.
updateField ::
  forall v a. KayaFieldType v =>
  RecordCollection a -> Key -> KField v -> v -> Build ()
updateField c key0 (KField i) value =
  updateFieldWire c (keyValue key0) i (fieldTag (Proxy :: Proxy v)) (toFieldValue value)

updateFieldWire :: RecordCollection a -> W.Value -> Word32 -> Word32 -> W.Value -> Build ()
updateFieldWire (RecordCollection (Collection n path)) key i tag value = state $ \s ->
  let current = case lookup key (lookupEntries n path (s.bModel)) of
        Just (_, vs) -> vs
        Nothing -> error "kaya: update of missing key"
      updated = take (fromIntegral i) current ++ [value] ++ drop (fromIntegral i + 1) current
   in ((), recomputeDerived n path
        s {bRecords = s.bRecords <> (W.txCollectionUpdateField n path key i 0 <$> encodeFieldWire tag value),
           bModel = modelSet n path key 0 updated (s.bModel)})

-- | One recorded field write of an a-record: the triple travels as
-- (index, schema tag, model value) — the tag tells the boundary whether
-- the value is a Blob slot that must register its bytes.
data FieldSet a = FieldSet !Word32 !Word32 !W.Value

set :: forall v a. KayaFieldType v => KField v -> v -> FieldSet a
set (KField i) v = FieldSet i (fieldTag (Proxy :: Proxy v)) (toFieldValue v)

-- | Typed field writes with the key spelled once: @patch todos key [set
-- (field \@"done" \@Todo) True]@.
patch :: RecordCollection a -> Key -> [FieldSet a] -> Build ()
patch c key0 = mapM_ (\(FieldSet i tag v) -> updateFieldWire c (keyValue key0) i tag v)

-- | The typed model: what this guest wrote, in insertion order.
recordItems :: KayaRecord a => RecordCollection a -> Build [(Key, a)]
recordItems (RecordCollection (Collection n path)) =
  gets (map (\(k, (_, vs)) -> (keyOfWire k, fromValues vs))
          . lookupEntries n path
          . (.bModel))

-- | A keyed read of one row, 'Nothing' if the key holds no entry — the
-- single-row twin of 'recordItems' (docs/deferred.md, the idiom pass's
-- keyed-read entry).
getRecord :: KayaRecord a => RecordCollection a -> Key -> Build (Maybe a)
getRecord (RecordCollection (Collection n path)) key0 =
  gets (fmap (\(_, vs) -> fromValues vs)
          . lookup (keyValue key0)
          . lookupEntries n path
          . (.bModel))

-- | A signal the binding recomputes from this collection's entries after
-- every mutation, written into the same transaction — the items-left label
-- with no handler remembering to update it.
derive ::
  forall a v. (KayaRecord a, KayaValue v) =>
  RecordCollection a -> ([(Key, a)] -> v) -> Build (Signal v)
derive (RecordCollection (Collection n _)) compute0 = state $ \s ->
  let compute = toWire . compute0
      wireCompute entries = compute (map (\(k, (_, vs)) -> (keyOfWire k, fromValues vs :: a)) entries)
      initial = wireCompute (lookupEntries n [] (s.bModel))
      c = s.bCounters
      sid = c.cSignal + 1
      s' = s {bCounters = c {cSignal = sid},
              bRecords = s.bRecords <> pure (W.txCreateSignal sid initial),
              bDerived = Map.insertWith (flip (++)) n [(sid, wireCompute)] (s.bDerived)}
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
    appNodeSorts :: IORef (Map.Map Word64 ([Key] -> Int -> IO ())),
    appNodeHandlers :: IORef (Map.Map Word64 ([Key] -> IO ())),
    appWidgetChanges :: IORef (Map.Map Word64 (Text -> IO ())),
    appNodeChanges :: IORef (Map.Map Word64 ([Key] -> Text -> IO ())),
    -- The submit gesture's own tables (docs/submit-plan.md S7).
    appWidgetSubmits :: IORef (Map.Map Word64 (Text -> IO ())),
    appNodeSubmits :: IORef (Map.Map Word64 ([Key] -> Text -> IO ())),
    -- The rich mirror, one Document per @rich@ textarea
    -- (docs/rich-text-plan.md R1): folded from the two occurrences here
    -- and from the app's own setDocument/applyEdit as they are SENT.
    appDocuments :: IORef (Map.Map Word64 Document),
    -- Template node -> (collection, field, level) for every template
    -- textarea bound to a document, so a copy's act folds into its ROW
    -- (docs/rich-text-plan.md §19).
    appDocumentBinds :: IORef (Map.Map Word64 (Word64, Word32, Word32)),
    appNodeEdits :: IORef (Map.Map Word64 ([Key] -> Edit -> IO ())),
    appNodeFormats :: IORef (Map.Map Word64 ([Key] -> Format -> IO ())),
    appWidgetEdits :: IORef (Map.Map Word64 (Edit -> IO ())),
    appWidgetFormats :: IORef (Map.Map Word64 (Format -> IO ())),
    appWidgetToggles :: IORef (Map.Map Word64 (Bool -> IO ())),
    appNodeToggles :: IORef (Map.Map Word64 ([Key] -> Bool -> IO ())),
    appWidgetValues :: IORef (Map.Map Word64 (Double -> IO ())),
    -- The node twin of the line above: without it a stamped control's
    -- Occurrence::InstanceValueChanged matches nothing and is dropped
    -- with no error anywhere.
    appNodeValues :: IORef (Map.Map Word64 ([Key] -> Double -> IO ())),
    appWidgetCommits :: IORef (Map.Map Word64 (Double -> IO ())),
    appNodeCommits :: IORef (Map.Map Word64 ([Key] -> Double -> IO ())),
    -- The pickers' committed values (docs/datetime-plan.md D7).
    appWidgetDates :: IORef (Map.Map Word64 (Day -> IO ())),
    appNodeDates :: IORef (Map.Map Word64 ([Key] -> Day -> IO ())),
    appWidgetTimes :: IORef (Map.Map Word64 (TimeOfDay -> IO ())),
    appNodeTimes :: IORef (Map.Map Word64 ([Key] -> TimeOfDay -> IO ())),
    -- Per-window lifecycle handlers, keyed by window id — handlers
    -- scope to the thing that creates them.
    appCloseRequested :: IORef (Map.Map Word64 (IO ())),
    appWindowClosed :: IORef (Map.Map Word64 (IO ())),
    -- Per-entry navigation handlers, keyed by entry surface id (the
    -- request-bound alert precedent).
    appEntryPopped :: IORef (Map.Map Word64 (IO ())),
    appSectionSelected :: IORef (Map.Map Word64 (IO ())),
    appBackRequested :: IORef (Map.Map Word64 (IO ())),
    -- Per-sheet handlers, keyed by sheet surface id (docs/sheet-plan.md).
    appSheetDismissed :: IORef (Map.Map Word64 (IO ())),
    appDismissRequested :: IORef (Map.Map Word64 (IO ())),
    appAlertHandlers :: IORef (Map.Map Word64 (AlertChoice -> IO ())),
    -- One-shot, keyed by the GUEST's notification id (the alert's
    -- request/result grammar; many may be live at once).
    appNotificationHandlers :: IORef (Map.Map Word64 (NotificationOutcome -> IO ())),
    -- NOT one-shot, and not keyed at all: the process-level handler for
    -- a result whose id has none above (docs/tasks-s9-plan.md R1). A
    -- relaunched process never called showNotification.
    appNotificationActivation :: IORef (Maybe (Word64 -> NotificationOutcome -> IO ())),
    -- NOT one-shot either: a route declared by 'linkRoute' answers every
    -- URL that matches it, for the life of the process
    -- (docs/app-links-plan.md §4), and the core owns the pattern table —
    -- nothing is kept here but the handler.
    appLinkHandlers :: IORef (Map.Map Word64 (Map.Map Text Text -> IO ())),
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
    appNodePastes :: IORef (Map.Map Word64 ([Key] -> Representation -> IO ())),
    appWidgetDrops :: IORef (Map.Map Word64 (Dropped -> IO ())),
    appNodeDrops :: IORef (Map.Map Word64 ([Key] -> Dropped -> IO ())),
    appDragEnded :: IORef (Map.Map Word64 (Maybe Op -> IO ())),
    appNodeDragEnded :: IORef (Map.Map Word64 ([Key] -> Maybe Op -> IO ())),
    -- Menu dispatch tables, keyed by MENU ITEM id — their own id space,
    -- separate from every widget/node table. The node flavors receive
    -- the stamped copy's key path.
    appMenuActivated :: IORef (Map.Map Word64 (IO ())),
    appMenuActivatedNode :: IORef (Map.Map Word64 ([Key] -> IO ())),
    appMenuToggled :: IORef (Map.Map Word64 (Bool -> IO ())),
    appMenuToggledNode :: IORef (Map.Map Word64 ([Key] -> Bool -> IO ())),
    appMenuSelected :: IORef (Map.Map Word64 (Int -> IO ())),
    appMenuSelectedNode :: IORef (Map.Map Word64 ([Key] -> Int -> IO ())),
    -- The canvas's drawing-as-a-function-of-size (docs/canvas-plan.md
    -- §3.2.1), keyed by the canvas's widget id. 'dispatchLoop' answers
    -- the ask itself and the guest never sees it. ONE STORED SHAPE for
    -- both policies, so the answer path has one call shape and the frame
    -- time is 0 for a plain redraw.
    appDraws :: IORef (Map.Map Word64 (Viewbox -> Double -> [DrawOp]))
  }
