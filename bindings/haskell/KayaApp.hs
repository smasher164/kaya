{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- kaya's idiomatic surface for Haskell: the structural core, and the
-- monad-sugar experiment the roster promised — scene declaration as a
-- builder monad, with When and For as combinators taking do-blocks.
--
-- The zone rule is in the types: Build is the live zone and its
-- elements are Widgets (each exactly one thing on screen); Tpl is a
-- template body and its elements are Nodes (blueprint entries, stamped
-- per collection entry). The shared vocabulary lives in the Declare
-- class, whose associated element type keeps the two id spaces from
-- ever mixing — addChild across zones is a type error, which is the
-- design's "declaring is not instantiating" made compiler-checked.
--
-- Dispatch: handlers register per button; the app loop routes each
-- click, handing template-node handlers the stamped copy's key path.
-- The core never calls into the guest — dispatch runs on the app
-- thread after it pulls from the ring.
module KayaApp
  ( App,
    Build,
    Tpl,
    Widget,
    Node,
    Signal,
    Collection,
    Declare (..),
    kayaMain,
    newApp,
    post,
    buildTx,
    submitTx,
    undoableTx,
    undoableTxIn,
    UndoDelta (..),
    UndoEntry (..),
    UndoOrder (..),
    dispatch,
    onClick,
    onClickNode,
    onChange,
    onChangeNode,
    onToggle,
    onToggleNode,
    onValueChanged,
    signal,
    writeSignal,
    at,
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
    selectSection,
    window,
    SectionAttr (..),
    popEntry,
    EntryAttr (..),
    destroyWindow,
    WindowAttr (..),
    AlertAttr (..),
    showAlert,
    PickedFile (..),
    openPicked,
    pickFiles,
    pickFile,
    clearWidget,
    focusWidget,
    bindText,
    bindChecked,
    bindValue,
    bindSource,
    setGrow,
    setSpacing,
    setAlign,
    setA11yId,
    setA11yLabel,
    setA11yHint,
    Align (..),
    Attr (..),
    WClass (..),
    RowCol,
    LeafArgs,
    row,
    column,
    scroll,
    progress,
    progressIndeterminate,
    bindTextElement,
    KayaFieldType (..),
    KayaRecord (..),
    KField,
    RecordCollection,
    recordHandle,
    collectionOf,
    field,
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
    bindSourceField,
    buttonOn,
    entryOn,
    textareaOn,
    labelText,
    labelBound,
    checkboxOn,
    sliderOn,
    selectOn,
    radioOn,
    gridOf,
    spacer,
    imageBytes,
    imageBound,
    TplTextSource (..),
    TplBoolSource (..),
    TplImageSource (..),
    label,
    checkbox,
    image,
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
    setMenuPrimary,
    setMenuShortcut,
    setMenuRole,
    copy,
    emptyClip,
    Clip (..),
    Representation (..),
    readClipboard,
    setAccepts,
    onPaste,
    onPasteNode,
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
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.ByteString.Builder (Builder)
import Data.Int (Int64)
import Data.IORef
import Data.List (elemIndex)
import GHC.Records (HasField)
import GHC.TypeLits (KnownSymbol, symbolVal)
import qualified Data.Map.Strict as Map
import qualified Data.List as List
import Data.Proxy (Proxy (..))
import Data.Word (Word32, Word64)
import GHC.Generics
import System.Exit (ExitCode (..), exitSuccess, exitWith)

import Control.Exception (SomeException, catch, evaluate)
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)

import KayaRuntime
  ( UndoDelta (..),
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

newtype Signal = Signal Word64

newtype Widget = Widget Word64

newtype Node = Node Word64

-- | A collection instance handle: the collection plus the key path
-- selecting one stamped copy's table. 'collection' returns the root
-- (empty-path, live-zone) handle; 'at' steps into a copy, one key per
-- enclosing For. Mutations and reads take the handle, so the target is
-- spelled once.
data Collection = Collection Word64 [W.Value]

-- | The instance of this collection inside the copy keyed by @key@ of
-- the next enclosing For; chain for deeper nesting.
at :: Collection -> W.Value -> Collection
at (Collection cid path) key = Collection cid (path ++ [key])

-- A For binds the collection itself — its template stamps per entry of
-- every instance — so handing it an 'at' handle is a bug.
assertRoot :: Collection -> Word64
assertRoot (Collection cid []) = cid
assertRoot _ = error "kaya: forEach binds the collection itself, not an instance — drop the at"

-- | One file the picker answered with: a handle to redeem, a display
-- name, and a re-openable name — EMPTY unless re-opening it actually
-- works, which measurement puts at the three desktops and neither
-- phone (DESIGN.md, File dialogs).
-- | One representation, arriving — the sum a copy is the record of.
--
-- YOU OFFER MANY AND YOU RECEIVE ONE, and the two shapes say so: a
-- record here would invite a guest to check five fields where four are
-- structurally always empty. Constructors carry the type's initial,
-- the convention 'AlignCenter' and 'AMessage' already follow.
--
-- 'RImage' may be a RE-ENCODE of what was copied — the hosts convert
-- freely between image types — so compare what the image IS, never the
-- bytes it arrived in. 'RFiles' is plural INSIDE one representation,
-- the same nesting text/uri-list and CF_HDROP already have.
data Representation
  = RText String
  | RHtml String
  | RImage BS.ByteString
  | RFiles [PickedFile]
  | RCustom String BS.ByteString

-- | One clip, offered in as many representations as the app fills in.
--
-- A RECORD AND NOT AN ATTRIBUTE LIST, and this is the one place the
-- binding departs from the @showAlert [attrs]@ shape beside it. The
-- departure is the DESIGN's, not taste: at most one per kind has to be
-- structural, and a list of attributes cannot say that — @[CText "a",
-- CText "b"]@ would typecheck. A record with optional fields makes the
-- second one impossible to write.
--
-- kaya DERIVES NOTHING between representations: whether list bullets
-- survive html-to-text is the app's decision, so an app that wants
-- plain text beside html fills in both.
data Clip = Clip
  { clipText :: Maybe String,
    clipHtml :: Maybe String,
    clipImage :: Maybe BS.ByteString,
    -- | Picked-file handles: copying a file and picking one are the
    -- same currency, so a picked file goes straight on and the bytes
    -- never move through kaya.
    clipFiles :: [PickedFile],
    -- | The one plural field with names, since several app-defined
    -- formats are legitimate. Each id reaches every platform's own
    -- registry verbatim, so it carries no spaces.
    clipCustom :: [(String, BS.ByteString)]
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

data PickedFile = PickedFile
  { pickedHandle :: !Word64,
    pickedName :: !String,
    pickedLocalPath :: !String
  }

-- | Redeem the handle for a real 'Handle', plus whether it seeks.
--
-- BLOCKS, and may block for a long time — a cloud provider can download
-- the file before it answers — so call it from a thread you chose and
-- post the result back. kaya is not in the data path: what comes back
-- is an ordinary handle.
openPicked :: PickedFile -> Word32 -> IO (Handle, Bool)
openPicked f = R.openPicked (pickedHandle f)

data Counters = Counters
  { cSignal :: !Word64,
    cWidget :: !Word64,
    cCollection :: !Word64,
    cNode :: !Word64,
    cAlert :: !Word64,
    cFileDialog :: !Word64,
    cClipboardRead :: !Word64,
    cMenuItem :: !Word64
  }

-- One instance of a collection: the table inside the stamped copy
-- selected by its path (the empty path for a live-zone collection).
-- Entries keep insertion order, matching the core's rendering.
data Instance = Instance
  { iPath :: ![W.Value],
    -- One [W.Value] per entry: the record's wire fields (a scalar
    -- collection is the one-field case).
    -- (key, (variant, fields)): the discriminant rides with the
    -- record, so refined reads and witnessed writes see the same fold
    -- the core holds.
    iEntries :: ![(W.Value, (Word32, [W.Value]))]
  }

-- The collection is the model — the only copy: every mutation op edits
-- it and appends the wire delta in the same state step, so reads
-- (items, count) are exactly the writes. The child map records the
-- declared-inside-a-For edges the model purges along when a parent
-- entry's copy is torn down.
type Model = Map.Map Word64 [Instance]

-- The minter's counters, one per collection INSTANCE, keyed the way
-- the model is: collection id to a list of (path, counter). A path is
-- a [W.Value] and W.Value carries a Double, so it is compared rather
-- than hashed or ordered — 'lookupEntries' does the same.
--
-- DELIBERATELY BESIDE THE MODEL AND NOT INSIDE IT. 'absorbUndo'
-- rebuilds Instances from the core's payload, so a counter living in
-- an Instance would be rewritten by every history walk — which is the
-- one thing 'insertFresh' promises can never happen.
type Fresh = Map.Map Word64 [([W.Value], Int64)]

data BuildState = BuildState
  { bCounters :: !Counters,
    -- The transaction under construction: IO Builder, not Builder.
    -- Record construction stays pure (the Build fold below), but
    -- serialization runs at buildTx's IO boundary — which is where
    -- blob-carrying records (image sources, ByteString record fields)
    -- register their bytes with the core. Handles are core-issued and
    -- single-submit, so they cannot exist earlier; the Semigroup on IO
    -- runs left-to-right, so registrations interleave in exact record
    -- order, immediately before the submit that consumes them. Pure
    -- records enter as `pure builder`.
    bRecords :: IO Builder,
    bModel :: !Model,
    -- The fresh-key counters, threaded through the same fold as the
    -- model and stored back beside it: a monotonic per-instance
    -- sequence has to outlive the transaction that advanced it.
    bFresh :: !Fresh,
    bChildren :: !(Map.Map Word64 [Word64]),
    bOpenFors :: ![Word64],
    -- Handlers declared at their constructors (buttonOn, entryOn,
    -- checkbox ...): pure data until buildTx registers them with
    -- the app alongside the submit — an abandoned Build abandons its
    -- handlers with its records.
    bPending :: ![Pending],
    -- Signals recomputed from a collection after each of its
    -- mutations, written into the same transaction; stored back at
    -- buildTx like the model, so an abandoned Build abandons its
    -- registrations too. The compute is wire-level: entries in, one
    -- value out.
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

-- One instance's counter, made if this is the first anyone has asked.
-- Split out because both the mint and the absorb want the same lookup.
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

-- The next fresh key for one instance: counter+1, and the counter
-- keeps it. Monotonic by construction — nothing else writes it
-- downwards (see 'insertFresh').
mintKey :: Word64 -> [W.Value] -> Fresh -> (Int64, Fresh)
mintKey cid path = withCounter cid path (\n -> (n + 1, n + 1))

-- An explicit key, shown to the minter on its way into the table. A
-- numeric key at or above the counter carries it up so the next mint
-- clears it; anything else moves nothing, having no way to collide
-- with an I64.
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

-- Pure records enter the transaction as `pure builder`; blob-carrying
-- records enter through the IO variants as the action that registers
-- their bytes and then builds — run in record order at buildTx.
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
      n = cNode c + 1
   in (n, s {bCounters = c {cNode = n}})

-- Menu items get their OWN id space (the c_menu_item counter) —
-- never a widget, node, or surface id. Build-only: menu items are
-- live, so the type system itself is the "no items in a template
-- body" guard every closure-language binding carries at runtime.
allocM :: Build Word64
allocM = Build $ \s ->
  let c = bCounters s
      n = cMenuItem c + 1
   in (n, s {bCounters = c {cMenuItem = n}})

-- Runs a template body inside whichever zone hosts it, bracketing its
-- records with the opener and template_end. A For's collection id is
-- kept open across the body so collections declared inside record
-- their parent edge (Whens pass Nothing).
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

-- | The declaration vocabulary, shared by both zones. El names the
-- zone's element type: live Widgets or template Nodes.
class Monad m => Declare m where
  type El m
  widget :: Word32 -> m (El m)
  setText :: El m -> String -> m ()
  setChecked :: El m -> Bool -> m ()
  addChild :: El m -> El m -> m ()
  collection :: m Collection
  -- | A For over a collection: the do-block declares the template;
  -- returns the For itself alongside the block's result.
  forEach :: Collection -> Tpl a -> m (El m, a)
  -- | A When over a Bool signal: stamps on true, unstamps on false.
  when_ :: Signal -> Tpl a -> m (El m, a)


instance Declare Build where
  type El Build = Widget
  widget kind = do
    n <- allocW
    emitB (W.txCreateWidget n kind)
    return (Widget n)
  setText (Widget n) text = emitB (W.txSetText n text)
  setChecked (Widget n) checked = emitB (W.txSetChecked n checked)
  addChild (Widget p) (Widget child) = emitB (W.txAddChild p child)
  collection = Build $ \s ->
    let c = bCounters s
        n = cCollection c + 1
        s' = registerCollection n s {bCounters = c {cCollection = n}}
     in (Collection n [], s' {bRecords = bRecords s' <> pure (W.txCreateCollection n [[W.valueStr]])})
  forEach coll body =
    Build $ \s ->
      let cid = assertRoot coll
          ((self, a), s') =
            bracketTpl (unBuild allocW) (`W.txCreateFor` cid) (Just cid) body s
       in ((Widget self, a), s')
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
  setText (Node n) text = emitT (W.txSetText n text)
  setChecked (Node n) checked = emitT (W.txSetChecked n checked)
  addChild (Node p) (Node child) = emitT (W.txAddChild p child)
  collection = Tpl $ \s ->
    let c = bCounters s
        n = cCollection c + 1
        s' = registerCollection n s {bCounters = c {cCollection = n}}
     in (Collection n [], s' {bRecords = bRecords s' <> pure (W.txCreateCollection n [[W.valueStr]])})
  forEach coll body =
    Tpl $ \s ->
      let cid = assertRoot coll
          ((self, a), s') =
            bracketTpl (unTpl allocN) (`W.txCreateFor` cid) (Just cid) body s
       in ((Node self, a), s')
  when_ (Signal sid) body =
    Tpl $ \s ->
      let ((self, a), s') =
            bracketTpl (unTpl allocN) (`W.txCreateWhen` sid) Nothing body s
       in ((Node self, a), s')

-- Live-zone-only vocabulary.

signal :: W.Value -> Build Signal
signal initial = Build $ \s ->
  let c = bCounters s
      n = cSignal c + 1
      s' = s {bCounters = c {cSignal = n}}
   in (Signal n, s' {bRecords = bRecords s' <> pure (W.txCreateSignal n initial)})

writeSignal :: Signal -> W.Value -> Build ()
writeSignal (Signal n) v = emitB (W.txWriteSignal n v)

-- Every derived signal rooted at this collection, recomputed from the
-- new model and written into the same transaction. Deriveds hang off
-- root handles, so nested-instance mutations cannot change their
-- input.
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

-- THE ONE INSERT PATH EVERY KEY TRAVELS, scalar or record: the model
-- fold, the wire record, the derived recompute — and ABSORPTION,
-- which is why it is one function and not two. A numeric key at or
-- above the minter's counter carries it up, so hand-chosen and minted
-- keys share one space safely and in either order ('insertFresh').
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

-- | Reposition an entry before another's: order is collection data,
-- so the model reorders and the wire carries the same keys-only
-- delta. Keys, never indices. A missing key or anchor fails here, at
-- the call site — the same check the scene makes; moving an entry
-- before itself is a no-op, and nothing travels.
moveBefore :: Collection -> W.Value -> W.Value -> Build ()
moveBefore c key anchor = moveEntry c key [anchor]

-- | Reposition an entry at the end of its collection.
moveToEnd :: Collection -> W.Value -> Build ()
moveToEnd c key = moveEntry c key []

-- | Reposition an entry at the front: sugar for moveBefore the
-- current first key, lowering to the same wire op.
moveToFront :: Collection -> W.Value -> Build ()
moveToFront c@(Collection n path) key = Build $ \s ->
  case map fst (lookupEntries n path (bModel s)) of
    [] -> error ("kaya: move of missing key " ++ show key)
    (first : _) -> unBuild (moveEntry c key [first]) s

-- | Reposition an entry directly after another's: sugar for
-- moveBefore the anchor's successor (moveToEnd when the anchor is
-- last), lowering to the same wire op.
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

-- The same checks the scene makes, made where the guest can see the
-- stack: a missing key or anchor is a guest bug, never a fallback.
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

-- | Mount into the default window; per-window targets arrive with the
-- window vocabulary.
-- | Window construction attributes — the config-list spelling. The
-- handler attrs ride the declaration (per-window — handlers scope to
-- the thing that creates them): 'WOnCloseRequested' fires per chrome
-- close while veto_close is armed (answer with 'destroyWindow' to
-- agree); 'WOnClosed' fires when the non-veto auxiliary is
-- chrome-closed and retires with it; 'WOnUndone' and 'WOnRedone' hear
-- this window's undo ledger.
data WindowAttr
  = WTitle String
  | WSize Double Double
  | WVetoClose Bool
  | -- | Present this window's entry stack as list-detail where the
    -- size class allows; the platform decides which way.
    WListDetail Bool
  | WSectionsPresentation Int64
  | WOnCloseRequested (IO ())
  | WOnClosed (IO ())
  | -- | Hear an undo kaya routed in this window: the step's label —
    -- EMPTY for a typing episode, since kaya invents no user-facing
    -- strings — and what the core put back. The ledger is per window,
    -- so its observer is a window attribute like any other, and the
    -- handler reads no id to learn which window it is (the same reason
    -- 'EOnPopped' rides the push).
    --
    -- NOT ONE-SHOT, the 'addSection' stance rather than the alert's: a
    -- history is walked as often as the user likes, so the registration
    -- outlives every step.
    --
    -- THE DELTA IS THE ONLY NOTIFICATION. Applying an inverse is a
    -- programmatic write, so the echo doctrine silences every occurrence
    -- it would otherwise cause — no text_changed for the text it
    -- restored, no value_changed for the signals. This binding has
    -- already folded the payload into its own collection model before
    -- the handler runs (so 'count' and 'recordItems' answer about the
    -- restored state); this is where an app folds it into ITS own state.
    WOnUndone (String -> UndoDelta -> IO ())
  | -- | The 'WOnUndone' twin. A frontier typing episode redoes on the
    -- platform's own stack and reports itself as an ordinary edit, so
    -- that one does not arrive here.
    WOnRedone (String -> UndoDelta -> IO ())
  | -- | The menubar rides the window construct (the window-attribute
    -- unification rule): 'WMenus' realizes its inline Build actions in
    -- order and appends each top-level grouping node ('menu' or
    -- 'radioGroup') to this window's command catalog — append-only, at
    -- any time. A retained handle re-enters through 'pure'.
    WMenus [Build (MItem 'BarM)]

-- | Set a window's attributes in one construct — the attribute set
-- is EXACTLY 'createWindow''s (a window's attributes ride its window
-- construct; the primary differs only in having no creation moment —
-- the process owns it): @window 0 [WTitle "sections",
-- WSectionsPresentation 1]@.
window :: Word64 -> [WindowAttr] -> Build ()
window n = mapM_ apply
  where
    apply (WTitle t) = emitB (W.txSetWindowTitle n t)
    apply (WSize w h) = do
      emitB (W.txSetWindowWidth n w)
      emitB (W.txSetWindowHeight n h)
    apply (WVetoClose v) = emitB (W.txSetWindowVetoClose n v)
    apply (WListDetail v) = emitB (W.txSetWindowListDetail n v)
    apply (WSectionsPresentation p) = emitB (W.txSetWindowSectionsPresentation n p)
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
-- spelling. The handler attrs ride the push (per-entry, the
-- 'showAlert' handler precedent — no id inspection anywhere):
-- 'EOnPopped' fires when the user's back affordance pops THIS entry
-- natively (post-fact; a programmatic 'popEntry' does not fire it —
-- its caller already knows) and retires with the one pop; 'EOnBack'
-- fires per back request while intercept_back is armed — nothing has
-- popped; answer with 'popEntry' to agree.
data EntryAttr
  = ETitle String
  | EInterceptBack Bool
  | EOnPopped (IO ())
  | EOnBack (IO ())

data SectionAttr
  = STitle String
  | SOnSelected (IO ())

-- | Push a navigation entry onto the primary surface's stack (entry
-- ids are guest-allocated in the shared surface namespace, the
-- 'createWindow' discipline); materializes covered, 'mountIn'
-- presents it:
-- @pushEntry 7 [ETitle "detail", EOnPopped (…)]@. Handler
-- registrations ride 'bPending': an abandoned Build abandons them
-- with its records.
pushEntry :: Word64 -> [EntryAttr] -> Build ()
pushEntry n attrs = do
  emitB (W.txPushEntry 0 n)
  mapM_ apply attrs
  where
    apply (ETitle t) = emitB (W.txSetEntryTitle n t)
    apply (EInterceptBack v) = emitB (W.txSetEntryInterceptBack n v)
    apply (EOnPopped handler) = pendB (PEntryPopped n handler)
    apply (EOnBack handler) = pendB (PBackRequested n handler)

-- | Pop the primary stack's top navigation entry and forget its tree
-- — also the back-veto grammar's confirmation after
-- 'onBackRequested'. Popping an empty stack is a scene error.
popEntry :: Build ()
popEntry = emitB (W.txPopEntry 0)

-- | Append a section to the primary window's section set (section
-- ids are guest-allocated in the shared surface namespace); the set
-- is append-only — sections have no destruction grammar, and every
-- section's root is retained while covered (switching is SELECTION,
-- not lifecycle). 'mountIn' fills its pane:
-- @addSection 7 [STitle "Feed", SOnSelected (…)]@. 'SOnSelected'
-- rides the add (per-section): fires each time the USER switches to
-- it — post-fact and NOT one-shot; a programmatic 'selectSection'
-- does not fire it (the echo doctrine).
addSection :: Word64 -> [SectionAttr] -> Build ()
addSection n attrs = do
  emitB (W.txAddSection 0 n)
  mapM_ apply attrs
  where
    apply (STitle t) = emitB (W.txSetSectionTitle n t)
    apply (SOnSelected handler) = pendB (PSectionSelected n handler)

-- | Select a section programmatically: configuration, never echoes
-- 'SOnSelected' (the echo doctrine).
selectSection :: Word64 -> Build ()
selectSection n = emitB (W.txSelectSection 0 n)

-- --- Menus: the command vocabulary (DESIGN.md, Menus) ---------------

-- | The anchor scope a catalog belongs to, as a phantom index: 'BarM
-- is a window catalog (a shortcut home), 'CtxM a context anchor.
-- 'IShortcut' is typed @IAttr 'BarM@ and the node-flavor handlers
-- @IAttr 'CtxM@, so a shortcut on a context item — or a keyed handler
-- on a bar item — is a TYPE error where the anchor is known; the
-- runtime guard at the root remains the floor beneath.
data MScope = BarM | CtxM

-- | A live menu item: its OWN id space behind its own type (indexed
-- by anchor scope), so cross-use with 'Widget'/'Node' handles is a
-- type error. One command identity: exactly one parent or anchor,
-- forever (append-only; nothing is removed in v1). The handle is
-- durable — the dynamic tier ('setMenuLabel', 'menuAppend', ...)
-- reopens it in any later transaction.
newtype MItem (s :: MScope) = MItem Word64

-- | A radio option: its own type, so an option outside a 'radioGroup'
-- children list — or a non-option inside one — is a type error (the
-- closed parent/child grammar, compile-checked).
newtype MOption (s :: MScope) = MOption Word64

-- | A context catalog built UNANCHORED ('contextCatalog') for a
-- template node: menu items are live and shared across stamped
-- copies, so the catalog is built in the live zone and
-- 'nodeContextMenu' attaches it inside the template, where each
-- activation carries the copy's key path. An item takes exactly one
-- anchor — the root rejects a second attach.
newtype Catalog = Catalog [Word64]

-- | The closed standard-command vocabulary (DESIGN.md, Menus): macOS
-- places this one in the application menu, and every other host leaves
-- the item where the app declared it.
-- | A NAMED VOCABULARY FOR THE CLOSED HALF, exactly as the menu roles
-- are. The accept list is open-ended — a custom format id is any
-- app-chosen string — so the four closed kinds cannot be a mask; but
-- they can be spelled once here instead of quoted at every call site.
-- A MISTYPED BARE STRING IS SILENT: it becomes a custom format id no
-- clipboard will ever offer, so Paste stays dead and the paste hook
-- never fires, with nothing to see anywhere. A custom id has no
-- constant by nature — the app that defines it names it.
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
--
-- GESTURES ARE COMMANDS BECAUSE KAYA HAS NO SELECTION API: only the
-- widget knows what is selected, so an app cannot assemble the payload
-- for "copy the selected text" out of the data layer. Copy of a
-- selection is therefore necessarily a command, and Paste is its
-- mirror. 'copy' and 'readClipboard' are for overriding that default
-- and for targets with no native behaviour.
roleCut :: String
roleCut = "cut"

roleCopy :: String
roleCopy = "copy"

rolePaste :: String
rolePaste = "paste"

-- | The two history commands — the same gesture layer one tier deeper
-- (docs/undo-plan.md D6). They ask the FOCUSED widget first: a text
-- field whose own edit history has something to give answers before the
-- app's ledger does, which is what an editor user expects — mid-typing,
-- Undo means the typing; after a structural action, Undo means the
-- action. Enablement is that same question, asked live at activation.
--
-- AN APP OPTS IN TO THE OTHER TIER BY NAMING ITS STEPS ('undoableTx')
-- and hears the result through 'WOnUndone'. An app that names none still
-- gets working text undo from these two items, because the first tier
-- is the platform's own.
roleUndo :: String
roleUndo = "undo"

roleRedo :: String
roleRedo = "redo"

-- | Menu item construction attributes — the config-list spelling over
-- a closed GADT indexed by anchor scope. Label and enablement are
-- signal-bindable ('ILabel'/'IEnabledBy'); 'IChecked'/'IValue' bind
-- both ways under the Checkbox/Choice contracts (programmatic writes
-- are QUIET — the echo doctrine); icon, primary, and shortcut are
-- const-only. Handlers ride the declaration — no app-global menu
-- dispatcher exists; the @Node@ flavors receive the stamped copy's
-- key path (the keys ARE the noun).
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
  IPrimary :: Bool -> IAttr s
  -- | Any window-anchored LEAF command — an action, a toggle, or one
  -- option of a group: a chord needs a window catalog as its native
  -- dispatch home, and the type carries that rule (the root carries
  -- the kind rule).
  IShortcut :: String -> IAttr 'BarM
  -- | Window-anchored actions only: a role names a standard command in
  -- the window catalog. Uniform declaration, per-host placement —
  -- macOS shows 'roleSettings' in the application menu, everyone else
  -- leaves the item where it was declared.
  IRole :: String -> IAttr 'BarM
  IOnActivate :: IO () -> IAttr s
  IOnActivateNode :: ([W.Value] -> IO ()) -> IAttr 'CtxM
  IOnToggle :: (Bool -> IO ()) -> IAttr s
  IOnToggleNode :: ([W.Value] -> Bool -> IO ()) -> IAttr 'CtxM
  IOnSelect :: (Int -> IO ()) -> IAttr s
  IOnSelectNode :: ([W.Value] -> Int -> IO ()) -> IAttr 'CtxM

-- The total interpreter: an attr without an arm is a compile failure
-- (the capi-completeness tripwire's type-level twin).
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
-- occurrence (menu click OR its shortcut: ONE occurrence, one
-- dispatch path; 'IOnActivate' rides the declaration and covers
-- both): @item "Save" [IShortcut "primary+s", IOnActivate h]@.
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

-- | A menu grouping node — a bar root through the window construct's
-- 'WMenus', or nested as an inline Build action in a parent's child
-- list (one nested grouping level is the cap, root-checked):
-- @menu "File" [IEnabledBy canExport] [item "Save" [...], ...]@.
-- Children are inline Build actions (the todos.hs container shape);
-- a realized handle re-enters through 'pure'. Disabling a menu
-- disables its subtree (the inherited-disabled contract).
menu :: String -> [IAttr s] -> [Build (MItem s)] -> Build (MItem s)
menu label attrs children = do
  n <- newMenuItem W.menuKindMenu (Just label) []
  mapM_ (\child -> child >>= \(MItem c) -> emitB (W.txMenuItemAppend n c)) children
  mapM_ (applyIAttr n) attrs
  return (MItem n)

-- | A radio group — the Choice contract with the platform's checkmark
-- idiom, admissible wherever a menu grouping node is. The children
-- are 'option's ONLY (their type holds the closed grammar); 'IValue'
-- /'IValueBy' is the selected 0-based index, applied AFTER the
-- options so the index has options to address; 'IOnSelect' receives
-- each USER pick's new index.
radioGroup :: String -> [IAttr s] -> [Build (MOption s)] -> Build (MItem s)
radioGroup label attrs options = do
  n <- newMenuItem W.menuKindRadioGroup (Just label) []
  mapM_ (\child -> child >>= \(MOption c) -> emitB (W.txMenuItemAppend n c)) options
  mapM_ (applyIAttr n) attrs
  return (MItem n)

-- | A context menu on a LIVE widget: the same item vocabulary scoped
-- to a NOUN, with the platform's own gesture (right-click,
-- long-press). Calling it again appends more roots. The editable text
-- controls (entry, textarea) reject attachment at the root; the
-- 'CtxM index rejects shortcuts at compile time.
contextMenu :: Widget -> [Build (MItem 'CtxM)] -> Build ()
contextMenu (Widget w) roots =
  mapM_ (\root -> root >>= \(MItem n) -> emitB (W.txContextAttach w n)) roots

-- | Build a context catalog UNANCHORED — free root items for a
-- template-node anchor (menu items are live and shared across stamped
-- copies): 'nodeContextMenu' attaches it inside the template, and
-- each activation carries the copy's key path.
contextCatalog :: [Build (MItem 'CtxM)] -> Build Catalog
contextCatalog roots =
  Catalog <$> mapM (\root -> (\(MItem n) -> n) <$> root) roots

-- | Attach a live-built context catalog to a template node: every
-- stamped copy shows the same catalog, and each activation carries
-- that copy's key path — the keys ARE the noun (received by the
-- @...Node@ attr handlers). An item takes exactly one anchor; the
-- root rejects a second attach.
nodeContextMenu :: Node -> Catalog -> Tpl ()
nodeContextMenu (Node n) (Catalog roots) =
  mapM_ (emitT . W.txContextAttachNode n) roots

-- The dynamic tier for a RETAINED item — every mutable prop, each
-- judged by the root against the item's kind and anchor, plus
-- 'menuAppend'/'menuOptions', the reopening of a grouping node
-- (append-at-any-time). Label and enablement writes never emit
-- anything; programmatic checked/value writes are configuration and
-- stay QUIET (the echo doctrine).

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

-- | The phone-bar promotion hint (actions only — root-checked).
-- Flipping it recomputes the promoted set deterministically; INERT on
-- desktops — not a toolbar grammar.
setMenuPrimary :: MItem s -> Bool -> Build ()
setMenuPrimary (MItem n) v = emitB (W.txSetMenuPrimary n v)

-- | The action's shortcut (window-anchored actions only).
-- Canonicalized by the binding's one parser
-- ('W.canonicalizeShortcut'); the shortcut is another affordance of
-- the same item — it fires the SAME menu_activated occurrence as a
-- click.
setMenuShortcut :: MItem s -> String -> Build ()
setMenuShortcut (MItem n) spelling = emitB (W.txSetMenuShortcut n spelling)

-- | Declare a retained action a standard command (actions only —
-- root-checked). Uniform declaration, per-host placement; a role never
-- invents a chord. Const-only.
setMenuRole :: MItem 'BarM -> String -> Build ()
setMenuRole (MItem n) name = emitB (W.txSetMenuRole n name)

-- | Reopen a RETAINED grouping node and append more children — the
-- append-at-any-time discipline: @menuAppend file [item "Publish"
-- [IPrimary True, IOnActivate h]]@. The scope index rides the
-- retained handle, so appends inherit the anchor's compile-time
-- rules; the root re-validates the appended subtree (depth,
-- shortcuts, duplicates).
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
-- riding the request like 'buttonOn':
-- @showAlert [ATitle "delete item?", AMessage "…", AAction "Delete",
-- AAction "Archive", ACancel "Keep"] $ \choice -> …@. The handler
-- fires exactly once — choice is an action index (0 or 1) or
-- 'W.alertChoiceCancel', every platform-native dismissal — and its
-- registration retires with the result. Ids are binding-allocated.
-- At most two AActions (the platform floor) and exactly one ACancel
-- — required, the slot every native dismissal resolves to (no
-- binding invents a default label). One alert may be live per
-- process; show the next from the handler.
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

-- | Ask the platform for files. THE PICK, NOT THE OPEN — the result
-- carries handles you redeem later, so the name says @pick@
-- (DESIGN.md, File dialogs).
--
-- The filters are (label, space-separated extensions) pairs, ADVISORY
-- on every platform: a default view rather than a guarantee, so the
-- guest still validates what it got.
--
-- The handler fires exactly once and retires with its answer. CANCEL
-- IS THE EMPTY LIST, faithfully: no platform can confirm an empty
-- selection. One dialog may be live per process; show the next from
-- the handler.
-- | Check one accept-list entry and return it.
--
-- Ids reach every platform's own registry verbatim, so they carry no
-- spaces — which is what makes the space-separated join unambiguous,
-- and what this refuses to let you break.
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
--
-- A LIST AND NOT A MASK, because half the set is open-ended. A custom
-- format that could be written and never accepted would be an escape
-- hatch that only opens outward, and round-tripping an app's own data
-- is the whole reason to have one.
acceptList :: [String] -> String
acceptList = unwords . map acceptToken

-- | Put ONE clip on the system clipboard:
-- @copy emptyClip { clipText = Just "kaya clip" }@.
--
-- The blob registrations ride the deferred record action, which is why
-- this is one 'emitBIO' rather than a sequence: 'Build' is pure, and
-- the bytes reach the core when the transaction submits.
--
-- The wire order is kaya's, not this record's — descending richness,
-- which is preference order on every host that has one, so a backend
-- writes what it is handed in the order it is handed. (@W.clipText@
-- below is the wire MASK; @clipText@ is this record's field.)
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

-- | Read the clipboard OUTSIDE any paste gesture — THE PRIVILEGED ONE,
-- named for what it is rather than for pasting.
--
-- A user's paste arrives at the widget's hook and costs nothing; this
-- asks without a gesture, which the platforms have deliberately made
-- expensive: iOS 16 PROMPTS when the content came from another app and
-- blocks until the user answers, Android returns nothing unless the app
-- has focus, and Wayland delivers no offer to an unfocused client.
-- Reach for this to detect a URL or import from the clipboard, never to
-- implement Paste — that is the Paste command, and it is free.
--
-- The handler fires exactly once, with @Just rep@ or @Nothing@, and the
-- registration retires with it — the alert's grammar.
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
        (concatMap (\(label, exts) -> [W.VStr label, W.VStr exts]) filters)
    )


mount :: Widget -> Build ()
mount (Widget n) = emitB (W.txMount 0 n)

-- One-shot commands: momentary verbs into widget-owned state, riding
-- the open transaction like any record — the insert and the clear
-- beside it submit together or not at all. Fire-and-forget: no model
-- state, nothing to journal; the widget answers through its normal
-- occurrence path (a clear arrives back as text_changed "" and the
-- app's draft fold empties itself). Build-zone Widgets only — a Node
-- is a blueprint, and a blueprint has nothing to clear (the
-- type-level arm of the scene's own template rejection).

-- | Drop an entry's content now (the field stays authoritative).
clearWidget :: Widget -> Build ()
clearWidget (Widget n) = emitB (W.txWidgetCommand n W.commandClear)

-- | Give this widget the keyboard focus.
focusWidget :: Widget -> Build ()
focusWidget (Widget n) = emitB (W.txWidgetCommand n W.commandFocus)

bindText :: Widget -> Signal -> Build ()
bindText (Widget w) (Signal s) = emitB (W.txBindText w s)

-- | Set a widget's flex weight within its row\/column: 0 is natural
-- size, positive weights divide the container's leftover main-axis
-- space in proportion (see Prop::Grow in the core). The dynamic path;
-- 'grow' is the declarative spelling. Build-only on purpose: no
-- language has template grow yet, so it stays off 'Declare' until all
-- of them do.
setGrow :: Widget -> Double -> Build ()
setGrow (Widget w) weight = emitB (W.txSetGrow w weight)

-- | A container's inter-child gap (main axis, DIP; the normalized
-- default is 8). Containers only — held by 'BoxCfg' here and by the
-- scene core everywhere. 'setSpacing' is the dynamic path.
setSpacing :: Widget -> Double -> Build ()
setSpacing (Widget w) gap = emitB (W.txSetSpacing w gap)

-- Construction props are a closed GADT indexed by widget class: the
-- attr list admits exactly kaya's vocabulary (no forged config
-- actions — uniform semantics, in types), 'applyAttr' is a total
-- match (a new prop cannot ship without its arm — the compiler's
-- version of the capi completeness tripwire), and container-only
-- props on a leaf are type errors before they are scene errors.
data WClass = BoxW | LeafW

-- | A container's cross-axis child placement (the align spec enum;
-- the normalized default is 'AlignStart'). 'AlignBaseline' is
-- rows-only — the scene rejects it on columns at the root.
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

-- | A widget's accessibility IDENTIFIER: a stable authored key that
-- assistive tooling and UI automation address it by, and which is
-- NEVER spoken. Universal — every kind carries one. The dynamic path;
-- the declarative spelling is the 'A11yId' attr.
setA11yId :: Widget -> String -> Build ()
setA11yId (Widget w) i = emitB (W.txSetA11yId w i)

-- | What an assistive client SPEAKS for a widget. Universal, and
-- deliberately separate from the identifier — an automation key is not
-- a spoken name. Leave it unset to keep whatever the platform derives
-- from the control's own content; setting it OVERRIDES that. The
-- dynamic path; the declarative spelling is the 'A11yLabel' attr.
setA11yLabel :: Widget -> String -> Build ()
setA11yLabel (Widget w) l = emitB (W.txSetA11yLabel w l)

-- | What ACTIVATING this widget does — the platforms' hint (Apple
-- defines it as the result of performing an action; Android carries it
-- as the click action's label). Write a VERB PHRASE. Activation kinds
-- only; the root rejects it elsewhere. The dynamic path; the
-- declarative spelling is the 'A11yHint' attr.
setA11yHint :: Widget -> String -> Build ()
setA11yHint (Widget w) h = emitB (W.txSetA11yHint w h)

data Attr (c :: WClass) where
  -- | This widget's flex weight — any widget class.
  Grow :: Double -> Attr c
  -- | This container's inter-child gap (main axis, DIP; the
  -- normalized default is 8). Containers only, held by the index.
  Spacing :: Double -> Attr 'BoxW
  -- | This container's cross-axis child placement. Containers only,
  -- held by the index like 'Spacing'.
  Align :: Align -> Attr 'BoxW
  -- | This widget's accessibility identifier — any widget class, like
  -- 'Grow': the two accessibility props are universal, so the index
  -- must not narrow them.
  A11yId :: String -> Attr c
  -- | What an assistive client speaks for this widget — any widget
  -- class, for the same reason.
  A11yLabel :: String -> Attr c
  -- | What ACTIVATING this widget does. Leaf-class only, unlike the
  -- other two: a hint needs an activation to describe, and the root
  -- admits it on button, checkbox, select and radio alone.
  A11yHint :: String -> Attr 'LeafW
  -- | What this widget takes from a paste — the closed kinds by name
  -- ('acceptText' and friends) plus any custom format ids. Any widget
  -- class, like 'Grow'.
  --
  -- ONE DECLARATION, THREE JOBS: it drives whether the Paste command is
  -- live while this widget is focused, it filters what can reach the
  -- paste hook, and on Android it IS the native registration
  -- (setOnReceiveContentListener takes the mime types on the view).
  -- Per-widget because whether Paste should be enabled is the
  -- INTERSECTION of what the clipboard offers and what the FOCUSED
  -- target takes.
  --
  -- DECLARING IS HOW AN APP OVERRIDES THE DEFAULT. A widget that
  -- declares nothing gets the platform's own insertion and reports it
  -- through the ordinary change path, which is why a plain text editor
  -- writes none of this and has working cut, copy and paste.
  Accepts :: [String] -> Attr c

applyAttr :: Attr c -> Widget -> Build ()
applyAttr (Grow weight) w = setGrow w weight
applyAttr (Spacing gap) w = setSpacing w gap
applyAttr (Align a) w = setAlign w a
applyAttr (A11yId i) w = setA11yId w i
applyAttr (A11yLabel l) w = setA11yLabel w l
applyAttr (A11yHint h) w = setA11yHint w h
applyAttr (Accepts kinds) w = setAccepts w kinds

withAttrs :: [Attr c] -> Build Widget -> Build Widget
withAttrs attrs act = do
  w <- act
  mapM_ (`applyAttr` w) attrs
  return w

-- One name, both arities, both zones — the lucid Term idiom over the
-- GADT: `row [kids]`, `row [Grow 2, Spacing 12] [kids]`, and the
-- template zone's `row [nodes]` all dispatch on the RESULT type,
-- which is always constructor-known (a do-bind pins the zone monad,
-- application to a second list pins the function shape) even when
-- its argument is not — a discarded template bind, an empty attr or
-- children list. The equality-constrained general heads are what
-- make that selection fire before the element types are known, and
-- then push them top-down into the lists. An attr list in template
-- position has no instance: template-zone props do not exist, and
-- the compiler says so.
class RowCol a r where
  rowish :: Word32 -> [a] -> r

instance (a ~ Build Widget, b ~ Widget) => RowCol a (Build b) where
  rowish = containerOf

instance (a ~ Tpl Node, b ~ Node) => RowCol a (Tpl b) where
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

-- | A grid from its children, laid out row-major into N columns —
-- each column takes its NATURAL width, aligned across rows (the
-- thing nested rows cannot express). The columns record lands before
-- the addChilds (backends re-flow either way).
gridOf :: Int -> [Build Widget] -> Build Widget
gridOf columns children = do
  handles <- sequence children
  parent@(Widget n) <- widget W.kindGrid
  emitB (W.txSetColumns n (fromIntegral columns))
  mapM_ (addChild parent) handles
  return parent

-- | A spacer: PURE SUGAR for an empty grown column — it consumes the
-- leftover main-axis space between its siblings.
spacer :: Build Widget
spacer = do
  w@(Widget n) <- widget W.kindColumn
  emitB (W.txSetGrow n 1.0)
  return w

-- The leaf half of the same idiom: every leaf constructor's result is
-- either the widget or a function awaiting its attr list —
-- `labelBound probe` and `labelBound probe [Grow 1]` under one name.
-- The equality-constrained head keeps matching eager, so empty attr
-- lists type without annotation.
class LeafArgs r where
  leafish :: Build Widget -> r

instance (b ~ Widget) => LeafArgs (Build b) where
  leafish = id

instance (a ~ Attr 'LeafW, r ~ Build Widget) => LeafArgs ([a] -> r) where
  leafish act attrs = withAttrs attrs act

bindChecked :: Widget -> Signal -> Build ()
bindChecked (Widget w) (Signal s) = emitB (W.txBindChecked w s)

-- | Bind a slider's position to a float signal — the programmatic
-- write path (writeSignal fans out to the control; property writes
-- never echo an occurrence, so a handler's own writes cannot loop
-- back at it).
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

-- Construction sugar, live zone: props and handlers at the
-- constructor. The handler is pure state until buildTx registers it.
pendB :: Pending -> Build ()
pendB pending = Build $ \s -> ((), s {bPending = pending : bPending s})

buttonOn :: (LeafArgs r) => String -> IO () -> r
buttonOn text handler = leafish $ do
  w@(Widget n) <- widget W.kindButton
  setText w text
  pendB (PClick n handler)
  return w

entryOn :: (LeafArgs r) => (String -> IO ()) -> r
entryOn handler = leafish $ do
  w@(Widget n) <- widget W.kindEntry
  pendB (PChange n handler)
  return w

-- | A labeled checkbox with its toggle handler co-located.
-- | A multi-line text editor with its change handler co-located:
-- the entry's uncontrolled contract over the platform's real
-- multi-line editor.
textareaOn :: (LeafArgs r) => (String -> IO ()) -> r
textareaOn handler = leafish $ do
  w@(Widget n) <- widget W.kindTextarea
  pendB (PChange n handler)
  return w

checkboxOn :: (LeafArgs r) => String -> (Bool -> IO ()) -> r
checkboxOn text handler = leafish $ do
  w@(Widget n) <- widget W.kindCheckbox
  setText w text
  pendB (PToggle n handler)
  return w

-- | A progress bar: display-only, like label and image — the
-- determinate fraction (0..=1).
progress :: (LeafArgs r) => Double -> r
progress fraction = leafish $ do
  w <- widget W.kindProgress
  let (Widget n) = w
  emitB (W.txSetValue n fraction)
  return w

-- | A progress bar in the platform's activity mode (no fraction).
progressIndeterminate :: (LeafArgs r) => r
progressIndeterminate = leafish $ do
  w <- widget W.kindProgress
  let (Widget n) = w
  emitB (W.txSetIndeterminate n True)
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

-- | A dropdown select over fixed options — each option becomes a
-- label child (labels only, scene-checked) — at the given initial
-- 0-based index (domain-checked at the root against the option
-- count), with its pick handler co-located: the handler receives
-- each USER pick's new 0-based index (programmatic writes never
-- echo) — the slider's uncontrolled contract.
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

-- | An image displaying constant encoded bytes (PNG, JPEG, ...): the
-- toolkit decodes natively, and decode failure renders the
-- placeholder, never a crash. One registration copy into core memory,
-- made at the boundary of the transaction this Build submits through;
-- the handle is consumed by that submit, and the caller's bytes are
-- free to drop the moment buildTx returns. Text belongs on labels —
-- image bytes have their own channel.
imageBytes :: (LeafArgs r) => BS.ByteString -> r
imageBytes bytes = leafish $ do
  w@(Widget n) <- widget W.kindImage
  emitBIO (W.txSetSource n <$> registerBlob bytes)
  return w

-- | An image whose source follows a Blob signal.
imageBound :: (LeafArgs r) => Signal -> r
imageBound sig = leafish $ do
  w <- widget W.kindImage
  bindSource w sig
  return w

-- Construction sugar, template flavor: one name per widget, and the
-- argument's type picks the addressable source — a constant, a signal,
-- or an element field. The protocol's closed union, as a class per
-- prop type; handlers receive the stamped copy's keys first.
pendT :: Pending -> Tpl ()
pendT pending = Tpl $ \s -> ((), s {bPending = pending : bPending s})

-- | What a template label's text can bind to.
class TplTextSource s where
  bindLabelSource :: Node -> s -> Tpl ()

instance TplTextSource String where
  bindLabelSource (Node n) text = emitT (W.txSetText n text)

instance TplTextSource Signal where
  bindLabelSource (Node n) (Signal s) = emitT (W.txBindText n s)

instance TplTextSource (KField String) where
  bindLabelSource n fd = bindTextField n 0 fd

-- | What a template checkbox's state can bind to.
class TplBoolSource s where
  bindCheckedSource :: Node -> s -> Tpl ()

instance TplBoolSource Bool where
  bindCheckedSource (Node n) checked = emitT (W.txSetChecked n checked)

instance TplBoolSource Signal where
  bindCheckedSource (Node n) (Signal s) = emitT (W.txBindChecked n s)

instance TplBoolSource (KField Bool) where
  bindCheckedSource n fd = bindCheckedField n 0 fd

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

label :: TplTextSource s => s -> Tpl Node
label src = do
  n <- widget W.kindLabel
  bindLabelSource n src
  return n

checkbox :: TplBoolSource s => s -> ([W.Value] -> Bool -> IO ()) -> Tpl Node
checkbox src handler = do
  n@(Node i) <- widget W.kindCheckbox
  bindCheckedSource n src
  pendT (PToggleNode i handler)
  return n

-- | A template image; decode failure renders the placeholder, never a
-- crash, on every backend.
image :: TplImageSource s => s -> Tpl Node
image src = do
  n <- widget W.kindImage
  bindImageSource n src
  return n

-- | A For as a child: forEach whose body keeps no handles — the common
-- case once handlers co-locate at their constructors.
each :: Collection -> Tpl a -> Build Widget
each c body = fst <$> forEach c body

-- Sums: the data declaration is the sum. KayaSum derives everything
-- from the Generic representation — one schema per constructor (each
-- constructor's fields walked by the same GRecord machinery records
-- use), the discriminant, both conversions — so `deriving Generic` +
-- an empty instance is the whole obligation, exactly as with records.
-- Elimination is Haskell-shaped where the guest holds the value (case
-- / pattern matches); the template takes a product of arms checked
-- complete at declaration, with the scene as the second check.
-- Mutation is witnessed by the scrutinee the guest just matched.

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
-- type (PNote Note | PTodo Todo), so the constructor's schema is the
-- inner record's, and the per-constructor field tokens are the inner
-- record's own (field @"done" @Todo) — nothing new to declare.
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

-- | The template eliminator: a product of arms, one per constructor,
-- handed over whole. Completeness is checked here at declaration (one
-- arm per constructor, any order) and again by the scene — an omitted
-- constructor never waits for its first insert to fail.
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

-- Records: the type is the schema. KayaRecord derives everything from
-- the Generic representation — one field tag, one conversion each way,
-- and the selector names for field tokens — so schema, insert order,
-- and indexes cannot drift from the data declaration. Every field must
-- be wire-typed (String, Bool, Int64, Double); Haskell keeps handlers
-- out of records by idiom, so there is no guest-only skipping here.

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

-- | Encoded image bytes are a wire type: the schema slot is Blob, and
-- every encode registers the bytes with the core right then — handles
-- are single-submit, so insert, update, and update_field all
-- re-register (one copy into core memory per write). The model keeps
-- the guest's own bytes, never a consumed handle: W.Value is generated
-- and closed, so the model's copy rides a byte-per-Char VStr carrier
-- (Char8 pack/unpack, lossless over 0..255) that encodeFieldWire
-- converts to a fresh VBlob handle on every trip to the wire.
instance KayaFieldType BS.ByteString where
  fieldTag _ = W.valueBlob
  toFieldValue = W.VStr . BC.unpack
  fromFieldValue v = case v of W.VStr s -> BC.pack s; _ -> error "kaya: field is not a Blob"

-- Model form to wire form for one field, at the transaction's IO
-- boundary: scalar slots pass through; a Blob slot's bytes register
-- with the core now, yielding the handle the submit consumes.
encodeFieldWire :: Word32 -> W.Value -> IO W.Value
encodeFieldWire tag v
  | tag == W.valueBlob, W.VStr s <- v = W.VBlob <$> registerBlob (BC.pack s)
  | otherwise = pure v

-- One record's fields, schema tags in parallel.
encodeFields :: [Word32] -> [W.Value] -> IO [W.Value]
encodeFields tags = sequence . zipWith encodeFieldWire tags

-- The Generic walker: one pass shape for schema, names, and both
-- conversions, over the product of selectors.
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

-- | A typed projection: one field of a record type, by wire position.
-- The phantom pins the Haskell type, so bindCheckedField rejects a
-- KField String at compile time.
newtype KField v = KField Word32

-- | The field token for a's field, by type-level name:
-- `field @"done" @Todo`. GHC's HasField constraint makes both the
-- membership and the field's type a compile-time fact (its functional
-- dependency pins v), so a wrong name or type is a type error at the
-- use site — no strings restating what the record already declares.
field ::
  forall name a v.
  (KayaRecord a, KayaFieldType v, HasField name a v, KnownSymbol name) =>
  KField v
field = case elemIndex (symbolVal (Proxy :: Proxy name)) (kayaFieldNames (Proxy :: Proxy a)) of
  Just i -> KField (fromIntegral i)
  -- Unreachable: HasField holds and every KayaRecord field is
  -- wire-typed, so the name is always in the derived list.
  Nothing -> error ("kaya: field " ++ symbolVal (Proxy :: Proxy name) ++ " has no wire slot")

-- | A Collection whose entries are a-records.
newtype RecordCollection a = RecordCollection Collection

-- | The plain handle, for forEach.
recordHandle :: RecordCollection a -> Collection
recordHandle (RecordCollection c) = c

-- | Declare a collection of a-records; the type is the schema.
collectionOf :: forall a. KayaRecord a => Proxy a -> Build (RecordCollection a)
collectionOf p = Build $ \s ->
  let c = bCounters s
      n = cCollection c + 1
      s' = registerCollection n s {bCounters = c {cCollection = n}}
   in ( RecordCollection (Collection n []),
        s' {bRecords = bRecords s' <> pure (W.txCreateCollection n [kayaSchema p])}
      )

insertRecord :: forall a. KayaRecord a => RecordCollection a -> W.Value -> a -> Build ()
insertRecord (RecordCollection (Collection n path)) key value = Build $ \s ->
  let vals = toValues value
   in ( (),
        insertEntry n path key vals
          (W.txCollectionInsert n path key 0 <$> encodeFields (kayaSchema (Proxy :: Proxy a)) vals)
          s
      )

-- | Insert a record under a key the binding authors, and hand the key
-- back.
--
-- FOR DATA THAT HAS NO IDENTITY OF ITS OWN. Keys are domain identity
-- and guest-chosen (DESIGN.md, the update algebra), so anything that
-- already HAS a name passes it to 'insertRecord' — today and always.
-- This is the other case, and it is the common one in a form: the app
-- has a title and nothing else, and the alternative is a hand-spelled
-- counter beside the collection, which in this language is an IORef
-- the Build cannot even see and whose safety rests on a never-rewind
-- rule nobody wrote down.
--
-- ONE COUNTER PER COLLECTION INSTANCE, starting at 0; the minted key
-- is 'W.VI64' and is counter+1. An instance is a table — the live-zone
-- collection, or one stamped copy selected by 'at' — and keys are
-- unique within one, so that is what the counter is per.
--
-- MIXING IS SAFE BY ABSORPTION: an explicit 'insertRecord' (or
-- 'insert') whose key is an I64 at or above the counter carries it up,
-- so a later mint clears every hand-chosen numeric key already in the
-- table. A non-numeric key cannot collide with an I64 at all and moves
-- nothing.
--
-- NO DECREMENT IS EXPRESSIBLE, and that is the whole safety argument.
-- Undo and redo replay captured keys inside the core and never re-enter
-- this path ('absorbUndo' folds the model and touches no counter), so a
-- history walk never moves the minter and a fresh key is fresh forever.
-- A Build that THROWS abandons its counters with everything else it
-- held — records, model, handlers — because in this binding an
-- abandoned transaction is a transaction that never happened at all;
-- the key it minted reached no core and no guest, so re-minting it
-- names nothing twice.
--
-- THE KEY IS THE RESULT even where a scene discards it: an app that
-- selects the row it just added takes the name from here rather than
-- inventing a second one for the same datum.
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

-- | One recorded field write of an a-record: the value's type checks
-- against the field's at the use site, then the triple travels as
-- (index, schema tag, model value) — the tag tells the boundary
-- whether the value is a Blob slot that must register its bytes.
data FieldSet a = FieldSet !Word32 !Word32 !W.Value

set :: forall v a. KayaFieldType v => KField v -> v -> FieldSet a
set (KField i) v = FieldSet i (fieldTag (Proxy :: Proxy v)) (toFieldValue v)

-- | Typed field writes with the key spelled once:
-- @patch todos key [set (field \@"done" \@Todo) True]@. Each entry
-- records one update_field — a patch is recorded writes, never a diff.
patch :: RecordCollection a -> W.Value -> [FieldSet a] -> Build ()
patch c key = mapM_ (\(FieldSet i tag v) -> updateFieldWire c key i tag v)

-- | The typed model: what this guest wrote, in insertion order.
recordItems :: KayaRecord a => RecordCollection a -> Build [(W.Value, a)]
recordItems (RecordCollection (Collection n path)) = Build $ \s ->
  (map (\(k, (_, vs)) -> (k, fromValues vs)) (lookupEntries n path (bModel s)), s)

-- | A signal the binding recomputes from this collection's entries
-- after every mutation, written into the same transaction — the
-- items-left label with no handler remembering to update it. The
-- function is pure presentation: entries in, one value out; the core
-- sees an ordinary signal.
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

-- | Bind a checkbox's state to one field of the element; KField Bool
-- only.
bindCheckedField :: Node -> Word32 -> KField Bool -> Tpl ()
bindCheckedField (Node n) level (KField i) = emitT (W.txBindCheckedElement n level i)

-- | Bind an image's source to one Blob field of the element; KField
-- ByteString only.
bindSourceField :: Node -> Word32 -> KField BS.ByteString -> Tpl ()
bindSourceField (Node n) level (KField i) = emitT (W.txBindSourceElement n level i)

-- The app: id counters that outlive any one transaction, and the
-- dispatch tables.

data App = App
  { -- Work handed over by other threads, waiting to run as
    -- transactions on the app thread. THE ONLY FIELD HERE TOUCHED FROM
    -- ANOTHER THREAD, and the only reason this record carries an MVar
    -- at all — every IORef below is app-thread-only by construction.
    appPosted :: MVar [IO ()],
    appCounters :: IORef Counters,
    appModel :: IORef (Model, Map.Map Word64 [Word64]),
    -- The minter's counters, outliving any one transaction exactly as
    -- the id counters above do. Never written by 'absorbUndo': a
    -- history walk replays keys the core captured and mints nothing.
    appFresh :: IORef Fresh,
    appDerived :: IORef (Map.Map Word64 [(Word64, [(W.Value, (Word32, [W.Value]))] -> W.Value)]),
    appWidgetHandlers :: IORef (Map.Map Word64 (IO ())),
    appNodeHandlers :: IORef (Map.Map Word64 ([W.Value] -> IO ())),
    appWidgetChanges :: IORef (Map.Map Word64 (String -> IO ())),
    appNodeChanges :: IORef (Map.Map Word64 ([W.Value] -> String -> IO ())),
    appWidgetToggles :: IORef (Map.Map Word64 (Bool -> IO ())),
    appNodeToggles :: IORef (Map.Map Word64 ([W.Value] -> Bool -> IO ())),
    appWidgetValues :: IORef (Map.Map Word64 (Double -> IO ())),
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
    -- The undo ledger's two reports, keyed by WINDOW: a history is
    -- per window, and so is the registration that hears it walked.
    -- NOT one-shot (the section_selected stance): a user walks a
    -- history as often as they like.
    appUndone :: IORef (Map.Map Word64 (String -> UndoDelta -> IO ())),
    appRedone :: IORef (Map.Map Word64 (String -> UndoDelta -> IO ())),
    appFileDialogHandlers :: IORef (Map.Map Word64 ([PickedFile] -> IO ())),
    -- Clipboard reads share the alert's request/result grammar and so
    -- its table shape: one-shot, keyed by request id.
    appClipboardReads :: IORef (Map.Map Word64 (Maybe Representation -> IO ())),
    appNextClipboardRead :: IORef Word64,
    appWidgetPastes :: IORef (Map.Map Word64 (Representation -> IO ())),
    appNodePastes :: IORef (Map.Map Word64 ([W.Value] -> Representation -> IO ())),
    -- Menu dispatch tables, keyed by MENU ITEM id — their own id
    -- space, separate from every widget/node table ("two tables,
    -- always" — now N tables, still always). The node flavors receive
    -- the stamped copy's key path (the keys ARE the noun).
    appMenuActivated :: IORef (Map.Map Word64 (IO ())),
    appMenuActivatedNode :: IORef (Map.Map Word64 ([W.Value] -> IO ())),
    appMenuToggled :: IORef (Map.Map Word64 (Bool -> IO ())),
    appMenuToggledNode :: IORef (Map.Map Word64 ([W.Value] -> Bool -> IO ())),
    appMenuSelected :: IORef (Map.Map Word64 (Int -> IO ())),
    appMenuSelectedNode :: IORef (Map.Map Word64 ([W.Value] -> Int -> IO ()))
  }

-- | Run a Build to records, submit them as one transaction, and return
-- the block's result (the handles the app keeps). The model folds
-- inside the Build's pure state and is stored back here, alongside the
-- submit — a transaction that never reaches this point (its Build
-- threw) leaves the model exactly as committed.
-- | The app thread, learned when the dispatch loop starts. Nothing
-- before then, which is the single-threaded construction phase.
--
-- A process-wide fact gets a process-wide ref, which is also how Python
-- and OCaml spell it -- the three bindings whose transaction is ambient
-- rather than a handle say this the same way.
appThreadRef :: IORef (Maybe ThreadId)
appThreadRef = unsafePerformIO (newIORef Nothing)
{-# NOINLINE appThreadRef #-}

-- | The Haskell spelling of a rule the handle bindings get from a
-- stale-transaction check.
--
-- A Build is a pure state function, so there is no handle to invalidate
-- -- but 'buildTx' reads and writes the app's IORefs and submits to the
-- ring, and a background thread doing that races the app thread on both.
-- Rust makes the equivalent a compile error (its Tx is !Send); Go, Java,
-- C# and Swift raise on a transaction that has closed; Haskell, like
-- Python and OCaml, has nothing to check but the thread.
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

buildTx :: App -> Build a -> IO a
buildTx app (Build f) = do
  requireAppThread
  counters <- readIORef (appCounters app)
  (model, children) <- readIORef (appModel app)
  fresh <- readIORef (appFresh app)
  derived <- readIORef (appDerived app)
  let (a, s) = f (BuildState counters mempty model fresh children [] [] derived)
  -- Force the Build's final state before the first store-back: a
  -- Build that throws must throw HERE, where the boundary abandons
  -- everything — never later, from a poisoned thunk inside an IORef
  -- (the catch-and-continue dispatch would trip on it transactions
  -- after the guilty one).
  _ <- evaluate s
  -- Serialize now, before any store-back: this runs the records' IO,
  -- which is where image sources and Blob record fields register
  -- their bytes with the core — in record order, immediately before
  -- the submit whose handle table they fill. A Build whose records
  -- throw still abandons everything (no store-back has run), and
  -- registrations already made are harmless: the next submit drains
  -- the pending table, referenced or not.
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
-- D2): @undoableTx app ("add " ++ draft) $ do insertRecord ...@.
--
-- THE ENTRY POINT TAKES THE NAME because this binding's transaction is
-- AMBIENT — a 'Build' is a pure state function with no handle to hang a
-- name on, so the three ambient bindings each spell the group at the
-- scope that opens it (Python a keyword argument, OCaml a labelled
-- optional, Haskell this variant) while the five handle bindings spell
-- it on the transaction object. Same semantics everywhere; the idiom
-- decides only the spelling. It also makes the wire's head-of-batch
-- rule unfalsifiable here: the marker is emitted before @body@ runs, so
-- no call order can put it anywhere but first.
--
-- THE UNIT OF UNDO IS A NAMED GROUP, NOT EVERY TRANSACTION. Handlers
-- fire per-gesture transactions constantly and most of them are
-- consequences rather than intents, and a per-keystroke editor would
-- earn one step per character — the exact problem grouping exists to
-- solve. So a group is opt-in, which is also what keeps a collaborative
-- app free to own its own history (D8).
--
-- WHAT A GROUP MAY HOLD is the reactive half — signal writes and
-- collection deltas, whose inverse the core derives from state it
-- already keeps. Focus is permitted and simply not restored. Anything
-- else (a const property write, creating a widget, 'clearWidget',
-- showing a dialog) fails at apply, naming the op: undo restores STATE,
-- and state is signals plus collections. An app that wants a widget
-- property undoable binds it to a signal. The label must be non-empty —
-- the empty one is how a typing EPISODE names itself on the same
-- occurrence. The result comes back through 'WOnUndone'.
undoableTx :: App -> String -> Build a -> IO a
undoableTx app = undoableTxIn app 0

-- | 'undoableTx' against an auxiliary window's ledger. Each window has
-- its own history, because Undo in one window has never meant "revert
-- what happened in another".
undoableTxIn :: App -> Word64 -> String -> Build a -> IO a
undoableTxIn app windowId label body =
  buildTx app (emitB (W.txUndoGroup windowId (W.VStr label)) >> body)

-- Fold an undo's payload into the collection model.
--
-- The rollback journal in reverse: an abandoned Build restores nothing
-- because nothing was shipped, while an undo restores a delta because
-- everything WAS — the core already moved, and the model is what would
-- otherwise be left behind. The payload is core-authoritative, so
-- nothing here re-derives anything. Signals and text are not mirrored
-- by this binding (there is no read-back for either, by doctrine), so
-- those two runs pass straight to the app's handler.
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
          -- not name at the end: the delta describes one instance's
          -- whole order, and an entry it never mentions is one this
          -- undo did not move.
          let named = [(k, v) | k <- uoKeys o, Just v <- [lookup k (iEntries i)]]
              rest = filter ((`notElem` uoKeys o) . fst) (iEntries i)
           in i {iEntries = named ++ rest}
      | otherwise = i

onClick :: App -> Widget -> IO () -> IO ()
onClick app (Widget n) handler =
  modifyIORef' (appWidgetHandlers app) (Map.insert n handler)

onClickNode :: App -> Node -> ([W.Value] -> IO ()) -> IO ()
onClickNode app (Node n) handler =
  modifyIORef' (appNodeHandlers app) (Map.insert n handler)

-- | Register a change handler for a live entry: the widget owns its
-- text and reports each edit here; the app folds the text into its own
-- state — there is no read-back, by doctrine.
onChange :: App -> Widget -> (String -> IO ()) -> IO ()
onChange app (Widget n) handler =
  modifyIORef' (appWidgetChanges app) (Map.insert n handler)

-- | Take pasted content at a live widget.
--
-- COSTS NOTHING ON ANY PLATFORM, unlike 'readClipboard': a paste is a
-- user gesture, so it is its own authorisation — iOS raises no prompt
-- and the focus rules are satisfied by construction. Only fires for a
-- widget that declared what it 'Accepts'.
onPaste :: App -> Widget -> (Representation -> IO ()) -> IO ()
onPaste app (Widget n) handler =
  modifyIORef' (appWidgetPastes app) (Map.insert n handler)

-- | A paste onto a stamped copy: the handler also receives the copy's
-- key path, outermost first. One record kind, the path deciding —
-- exactly as a click on a stamped row is one record with a click on a
-- live widget.
onPasteNode :: App -> Node -> ([W.Value] -> Representation -> IO ()) -> IO ()
onPasteNode app (Node n) handler =
  modifyIORef' (appNodePastes app) (Map.insert n handler)

-- | Register a change handler for a template entry; it also receives
-- the stamped copy's keys, outermost first.
onChangeNode :: App -> Node -> ([W.Value] -> String -> IO ()) -> IO ()
onChangeNode app (Node n) handler =
  modifyIORef' (appNodeChanges app) (Map.insert n handler)

-- | Register a toggle handler for a live checkbox: the box owns its
-- checked bit and reports each flip here; the app folds it into its
-- own state.
-- | Register a change handler for a live slider: the bar owns its
-- position and reports each move with the new value — the entry's
-- uncontrolled contract, with a Double.
onValueChanged :: App -> Widget -> (Double -> IO ()) -> IO ()
onValueChanged app (Widget n) handler =
  modifyIORef' (appWidgetValues app) (Map.insert n handler)

onToggle :: App -> Widget -> (Bool -> IO ()) -> IO ()
onToggle app (Widget n) handler =
  modifyIORef' (appWidgetToggles app) (Map.insert n handler)

-- | Register a toggle handler for a template checkbox; it also
-- receives the stamped copy's keys, outermost first.
onToggleNode :: App -> Node -> ([W.Value] -> Bool -> IO ()) -> IO ()
onToggleNode app (Node n) handler =
  modifyIORef' (appNodeToggles app) (Map.insert n handler)

-- | Turn the decoder's kind-and-parts into the sum, or Nothing.
--
-- EMPTY IS THE UNIVERSAL NO: Nothing covers a denied prompt on iOS, an
-- unfocused reader on Android or Wayland, an empty clipboard, and
-- content in no representation this read accepted. The guest is not
-- told which, because the platforms deliberately do not say.
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
-- tables. kayaMain starts from one; headless checks use it directly,
-- without ever entering the core.
newApp :: IO App
newApp =
  App
    <$> newMVar []
    <*> newIORef (Counters 0 0 0 0 0 0 0 0)
    <*> newIORef (Map.empty, Map.empty)
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef 0
    <*> newIORef Map.empty -- appUndone
    <*> newIORef Map.empty -- appRedone
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef 0
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty

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

-- | One handler dispatch: an exception crosses the build boundary
-- (the pure Build's store-back and submit never ran, so the model
-- shows exactly what was shipped), is logged, and the loop moves to
-- the next occurrence — the uniform dispatch discipline across every
-- binding.
dispatch :: IO () -> IO ()
dispatch body =
  body `catch` \e ->
    hPutStrLn stderr ("kaya: handler threw (transaction rolled back): " ++ show (e :: SomeException))

-- | Run @body@ as a transaction on the app thread, soon. THE ONE
-- action safe to call from another thread, and the answer to "how does
-- background work reach the UI".
--
-- @build app@ is a transaction NOW on the calling thread; @post app@ is
-- the same transaction SOON on the app thread — so a background thread
-- writes ordinary blocking Haskell and hands back only the result:
--
-- > _ <- forkIO $ do
-- >   text <- readFile path            -- blocks this thread
-- >   post app (set content text)      -- back on the app thread
--
-- Signals are ids and are meant to be captured; that is how the posted
-- action names what to write. A posted action runs in its OWN
-- transaction, after whatever is running now, so posting from inside a
-- handler queues for after and never nests.
post :: App -> IO () -> IO ()
post app body = do
  modifyMVar_ (appPosted app) (return . (++ [body]))
  -- The app thread may be parked in C waiting on the ring. Posted work
  -- is not an occurrence and never enters that ring, so this is the
  -- only way it hears about it.
  wake

-- | Run everything posted, each as its own transaction, in order.
--
-- The batch is taken and the MVar put back BEFORE any of it runs, so an
-- action that posts again lands in the NEXT batch. Holding the MVar
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
    Just (kind, ident, keys, payload, clip, undone)
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
            _ -> return ()
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
          -- NOT one-shot: sections never die, and the user can
          -- return any number of times (ident is the section; the
          -- window rides as the payload). A programmatic
          -- selectSection never lands here (the echo doctrine).
          handlers <- readIORef (appSectionSelected app)
          dispatch (mapM_ id (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindClipboardResult -> do
          -- One-shot like the alert, and the request retires with it.
          -- EMPTY IS THE UNIVERSAL NO and arrives as Nothing — denied,
          -- unfocused, absent and nothing-we-accept alike, because no
          -- platform says which.
          handlers <- readIORef (appClipboardReads app)
          writeIORef (appClipboardReads app) (Map.delete ident handlers)
          dispatch (mapM_ ($ representationOf clip) (Map.lookup ident handlers))
          dispatchLoop app
      | kind == W.occKindPasted -> do
          -- A paste rides a click tag verbatim, so it arrives on the
          -- ordinary widget/node split — one record kind, the key path
          -- deciding. Never empty: a paste that delivered nothing is not
          -- an occurrence.
          case (representationOf clip, keys) of
            (Nothing, _) -> return ()
            (Just rep, []) -> do
              handlers <- readIORef (appWidgetPastes app)
              dispatch (mapM_ ($ rep) (Map.lookup ident handlers))
            (Just rep, ks) -> do
              handlers <- readIORef (appNodePastes app)
              dispatch (mapM_ (\h -> h ks rep) (Map.lookup ident handlers))
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
      -- the label rides as the payload). NOT one-shot — a history is
      -- walked as often as the user likes.
      --
      -- THE MODEL IS RECONCILED FIRST, and unconditionally: the core
      -- moved without a transaction, so an app reading `count` inside
      -- the handler must see the restored state, and an app with no
      -- handler at all must not be left with a stale model.
      | kind == W.occKindUndone || kind == W.occKindRedone -> do
          let delta = maybe emptyUndoDelta id undone
              label = case payload of Just (W.VStr s) -> s; _ -> ""
          absorbUndo app delta
          handlers <-
            readIORef
              (if kind == W.occKindUndone then appUndone app else appRedone app)
          dispatch (mapM_ (\h -> h label delta) (Map.lookup ident handlers))
          dispatchLoop app
      -- Menu occurrences key the menu-item tables — their own id
      -- space, so neither widget nor node ids can collide with them.
      -- Node-anchored context items carry the stamped copy's keys
      -- (the keys ARE the noun); toggles carry the new state, radio
      -- groups the new 0-based index.
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
    Just (_, ident, [], _, _, _) -> do
      handlers <- readIORef (appWidgetHandlers app)
      dispatch (mapM_ id (Map.lookup ident handlers))
      dispatchLoop app
    Just (_, ident, keys, _, _, _) -> do
      handlers <- readIORef (appNodeHandlers app)
      dispatch (mapM_ ($ keys) (Map.lookup ident handlers))
      dispatchLoop app
