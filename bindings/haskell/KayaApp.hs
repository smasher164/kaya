{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
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
    buildTx,
    submitTx,
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
    bindText,
    bindChecked,
    bindTextElement,
    KayaFieldType (..),
    KayaRecord (..),
    KField,
    RecordCollection,
    recordHandle,
    collectionOf,
    field,
    insertRecord,
    updateRecord,
    updateField,
    FieldSet,
    set,
    patch,
    derive,
    recordItems,
    bindTextField,
    bindCheckedField,
    buttonOn,
    entryOn,
    labelText,
    labelBound,
    checkboxOn,
    sliderOn,
    TplTextSource (..),
    TplBoolSource (..),
    label,
    checkbox,
    each,
  )
where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Data.ByteString.Builder (Builder)
import Data.Int (Int64)
import Data.IORef
import Data.List (elemIndex)
import GHC.Records (HasField)
import GHC.TypeLits (KnownSymbol, symbolVal)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
import Data.Word (Word32, Word64)
import GHC.Generics
import System.Exit (ExitCode (..), exitSuccess, exitWith)

import KayaRuntime (kayaRun, kayaSubmit, nextOccurrence)
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

data Counters = Counters
  { cSignal :: !Word64,
    cWidget :: !Word64,
    cCollection :: !Word64,
    cNode :: !Word64
  }

-- One instance of a collection: the table inside the stamped copy
-- selected by its path (the empty path for a live-zone collection).
-- Entries keep insertion order, matching the core's rendering.
data Instance = Instance
  { iPath :: ![W.Value],
    -- One [W.Value] per entry: the record's wire fields (a scalar
    -- collection is the one-field case).
    iEntries :: ![(W.Value, [W.Value])]
  }

-- The collection is the model — the only copy: every mutation op edits
-- it and appends the wire delta in the same state step, so reads
-- (items, count) are exactly the writes. The child map records the
-- declared-inside-a-For edges the model purges along when a parent
-- entry's copy is torn down.
type Model = Map.Map Word64 [Instance]

data BuildState = BuildState
  { bCounters :: !Counters,
    bRecords :: Builder,
    bModel :: !Model,
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
    bDerived :: !(Map.Map Word64 [(Word64, [(W.Value, [W.Value])] -> W.Value)])
  }

data Pending
  = PClick !Word64 (IO ())
  | PChange !Word64 (String -> IO ())
  | PToggle !Word64 (Bool -> IO ())
  | PValue !Word64 (Double -> IO ())
  | PToggleNode !Word64 ([W.Value] -> Bool -> IO ())

modelSet :: Word64 -> [W.Value] -> W.Value -> [W.Value] -> Model -> Model
modelSet cid path key value model = Map.insert cid (go (Map.findWithDefault [] cid model)) model
  where
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

lookupEntries :: Word64 -> [W.Value] -> Model -> [(W.Value, [W.Value])]
lookupEntries cid path model =
  case filter ((== path) . iPath) (Map.findWithDefault [] cid model) of
    (i : _) -> iEntries i
    [] -> []

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
emitB r = Build $ \s -> ((), s {bRecords = bRecords s <> r})

emitT :: Builder -> Tpl ()
emitT r = Tpl $ \s -> ((), s {bRecords = bRecords s <> r})

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

-- Runs a template body inside whichever zone hosts it, bracketing its
-- records with the opener and template_end. A For's collection id is
-- kept open across the body so collections declared inside record
-- their parent edge (Whens pass Nothing).
bracketTpl :: (BuildState -> (Word64, BuildState)) -> (Word64 -> Builder) -> Maybe Word64
           -> Tpl a -> BuildState -> ((Word64, a), BuildState)
bracketTpl alloc opener forCid (Tpl body) s0 =
  let (self, s1) = alloc s0
      s2 = s1
        { bRecords = bRecords s1 <> opener self,
          bOpenFors = maybe (bOpenFors s1) (: bOpenFors s1) forCid
        }
      (a, s3) = body s2
      s4 = s3
        { bRecords = bRecords s3 <> W.txTemplateEnd,
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

  -- | Construction sugar: a container from its children, so the
  -- do-block reads as the tree. Lowers to the same records — children
  -- first, then the container, then the add_childs.
  row :: [m (El m)] -> m (El m)
  row = containerOf W.kindRow
  column :: [m (El m)] -> m (El m)
  column = containerOf W.kindColumn

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
     in (Collection n [], s' {bRecords = bRecords s' <> W.txCreateCollection n [W.valueStr]})
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
     in (Collection n [], s' {bRecords = bRecords s' <> W.txCreateCollection n [W.valueStr]})
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
   in (Signal n, s' {bRecords = bRecords s' <> W.txCreateSignal n initial})

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
       in s {bRecords = bRecords s <> writes}

insert :: Collection -> W.Value -> W.Value -> Build ()
insert (Collection n path) key value = Build $ \s ->
  ((), recomputeDerived n path
    s {bRecords = bRecords s <> W.txCollectionInsert n path key [value],
       bModel = modelSet n path key [value] (bModel s)})

update :: Collection -> W.Value -> W.Value -> Build ()
update (Collection n path) key value = Build $ \s ->
  ((), recomputeDerived n path
    s {bRecords = bRecords s <> W.txCollectionUpdate n path key [value],
       bModel = modelSet n path key [value] (bModel s)})

remove :: Collection -> W.Value -> Build ()
remove (Collection n path) key = Build $ \s ->
  ((), recomputeDerived n path
    s {bRecords = bRecords s <> W.txCollectionRemove n path key,
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
              s {bRecords = bRecords s <> W.txCollectionMove n path key before,
                 bModel = modelMove n path key before (bModel s)})

-- | The model: what this guest wrote, exactly — the fold of every
-- patch so far (this transaction's included), in insertion order.
items :: Collection -> Build [(W.Value, W.Value)]
items (Collection n path) = Build $ \s ->
  (map (\(k, vs) -> (k, head vs)) (lookupEntries n path (bModel s)), s)

count :: Collection -> Build Int
count c = length <$> items c

-- | Mount into the default window; per-window targets arrive with the
-- window vocabulary.
mount :: Widget -> Build ()
mount (Widget n) = emitB (W.txMount 0 n)

bindText :: Widget -> Signal -> Build ()
bindText (Widget w) (Signal s) = emitB (W.txBindText w s)

bindChecked :: Widget -> Signal -> Build ()
bindChecked (Widget w) (Signal s) = emitB (W.txBindChecked w s)

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

buttonOn :: String -> IO () -> Build Widget
buttonOn text handler = do
  w@(Widget n) <- widget W.kindButton
  setText w text
  pendB (PClick n handler)
  return w

entryOn :: (String -> IO ()) -> Build Widget
entryOn handler = do
  w@(Widget n) <- widget W.kindEntry
  pendB (PChange n handler)
  return w

-- | A labeled checkbox with its toggle handler co-located.
checkboxOn :: String -> (Bool -> IO ()) -> Build Widget
checkboxOn text handler = do
  w@(Widget n) <- widget W.kindCheckbox
  setText w text
  pendB (PToggle n handler)
  return w

-- | A slider over min..max at value, with its change handler
-- co-located.
sliderOn :: Double -> Double -> Double -> (Double -> IO ()) -> Build Widget
sliderOn lo hi value handler = do
  w@(Widget n) <- widget W.kindSlider
  emitB (W.txSetMin n lo)
  emitB (W.txSetMax n hi)
  emitB (W.txSetValue n value)
  pendB (PValue n handler)
  return w

labelText :: String -> Build Widget
labelText text = do
  w <- widget W.kindLabel
  setText w text
  return w

labelBound :: Signal -> Build Widget
labelBound sig = do
  w <- widget W.kindLabel
  bindText w sig
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

-- | A For as a child: forEach whose body keeps no handles — the common
-- case once handlers co-locate at their constructors.
each :: Collection -> Tpl a -> Build Widget
each c body = fst <$> forEach c body

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
        s' {bRecords = bRecords s' <> W.txCreateCollection n (kayaSchema p)}
      )

insertRecord :: KayaRecord a => RecordCollection a -> W.Value -> a -> Build ()
insertRecord (RecordCollection (Collection n path)) key value = Build $ \s ->
  ((), recomputeDerived n path
    s {bRecords = bRecords s <> W.txCollectionInsert n path key (toValues value),
       bModel = modelSet n path key (toValues value) (bModel s)})

updateRecord :: KayaRecord a => RecordCollection a -> W.Value -> a -> Build ()
updateRecord (RecordCollection (Collection n path)) key value = Build $ \s ->
  ((), recomputeDerived n path
    s {bRecords = bRecords s <> W.txCollectionUpdate n path key (toValues value),
       bModel = modelSet n path key (toValues value) (bModel s)})

-- | One field's delta: the rest of the record never travels; the
-- model's copy updates the same slot.
updateField ::
  KayaFieldType v =>
  RecordCollection a -> W.Value -> KField v -> v -> Build ()
updateField c key (KField i) value = updateFieldWire c key i (toFieldValue value)

updateFieldWire :: RecordCollection a -> W.Value -> Word32 -> W.Value -> Build ()
updateFieldWire (RecordCollection (Collection n path)) key i wire = Build $ \s ->
  let current = case lookup key (lookupEntries n path (bModel s)) of
        Just vs -> vs
        Nothing -> error "kaya: update of missing key"
      updated = take (fromIntegral i) current ++ [wire] ++ drop (fromIntegral i + 1) current
   in ((), recomputeDerived n path
        s {bRecords = bRecords s <> W.txCollectionUpdateField n path key i wire,
           bModel = modelSet n path key updated (bModel s)})

-- | One recorded field write of an a-record: the value's type checks
-- against the field's at the use site, then the pair travels as
-- (index, wire value).
data FieldSet a = FieldSet !Word32 !W.Value

set :: KayaFieldType v => KField v -> v -> FieldSet a
set (KField i) v = FieldSet i (toFieldValue v)

-- | Typed field writes with the key spelled once:
-- @patch todos key [set (field \@"done" \@Todo) True]@. Each entry
-- records one update_field — a patch is recorded writes, never a diff.
patch :: RecordCollection a -> W.Value -> [FieldSet a] -> Build ()
patch c key = mapM_ (\(FieldSet i v) -> updateFieldWire c key i v)

-- | The typed model: what this guest wrote, in insertion order.
recordItems :: KayaRecord a => RecordCollection a -> Build [(W.Value, a)]
recordItems (RecordCollection (Collection n path)) = Build $ \s ->
  (map (\(k, vs) -> (k, fromValues vs)) (lookupEntries n path (bModel s)), s)

-- | A signal the binding recomputes from this collection's entries
-- after every mutation, written into the same transaction — the
-- items-left label with no handler remembering to update it. The
-- function is pure presentation: entries in, one value out; the core
-- sees an ordinary signal.
derive ::
  forall a. KayaRecord a =>
  RecordCollection a -> ([(W.Value, a)] -> W.Value) -> Build Signal
derive (RecordCollection (Collection n _)) compute = Build $ \s ->
  let wireCompute entries = compute (map (\(k, vs) -> (k, fromValues vs :: a)) entries)
      initial = wireCompute (lookupEntries n [] (bModel s))
      c = bCounters s
      sid = cSignal c + 1
      s' = s {bCounters = c {cSignal = sid},
              bRecords = bRecords s <> W.txCreateSignal sid initial,
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

-- The app: id counters that outlive any one transaction, and the
-- dispatch tables.

data App = App
  { appCounters :: IORef Counters,
    appModel :: IORef (Model, Map.Map Word64 [Word64]),
    appDerived :: IORef (Map.Map Word64 [(Word64, [(W.Value, [W.Value])] -> W.Value)]),
    appWidgetHandlers :: IORef (Map.Map Word64 (IO ())),
    appNodeHandlers :: IORef (Map.Map Word64 ([W.Value] -> IO ())),
    appWidgetChanges :: IORef (Map.Map Word64 (String -> IO ())),
    appNodeChanges :: IORef (Map.Map Word64 ([W.Value] -> String -> IO ())),
    appWidgetToggles :: IORef (Map.Map Word64 (Bool -> IO ())),
    appNodeToggles :: IORef (Map.Map Word64 ([W.Value] -> Bool -> IO ())),
    appWidgetValues :: IORef (Map.Map Word64 (Double -> IO ()))
  }

-- | Run a Build to records, submit them as one transaction, and return
-- the block's result (the handles the app keeps). The model folds
-- inside the Build's pure state and is stored back here, alongside the
-- submit — a transaction that never reaches this point (its Build
-- threw) leaves the model exactly as committed.
buildTx :: App -> Build a -> IO a
buildTx app (Build f) = do
  counters <- readIORef (appCounters app)
  (model, children) <- readIORef (appModel app)
  derived <- readIORef (appDerived app)
  let (a, s) = f (BuildState counters mempty model children [] [] derived)
  writeIORef (appCounters app) (bCounters s)
  writeIORef (appModel app) (bModel s, bChildren s)
  writeIORef (appDerived app) (bDerived s)
  -- Handlers declared at their constructors register alongside the
  -- submit; a Build that threw never reaches here, abandoning them
  -- with its records.
  mapM_ (register app) (reverse (bPending s))
  kayaSubmit [bRecords s]
  return a

register :: App -> Pending -> IO ()
register app pending = case pending of
  PClick n handler -> modifyIORef' (appWidgetHandlers app) (Map.insert n handler)
  PChange n handler -> modifyIORef' (appWidgetChanges app) (Map.insert n handler)
  PToggle n handler -> modifyIORef' (appWidgetToggles app) (Map.insert n handler)
  PValue n handler -> modifyIORef' (appWidgetValues app) (Map.insert n handler)
  PToggleNode n handler -> modifyIORef' (appNodeToggles app) (Map.insert n handler)

-- | buildTx for handlers that keep no handles.
submitTx :: App -> Build () -> IO ()
submitTx app b = buildTx app b

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

-- | Set up (build the scene, register handlers) and run: occurrences
-- dispatch on the app thread while the core owns the calling thread,
-- which must be the process main thread (GHC's main runs bound to it;
-- -threaded is required).
kayaMain :: (App -> IO ()) -> IO ()
kayaMain setup = do
  app <-
    App
      <$> newIORef (Counters 0 0 0 0)
      <*> newIORef (Map.empty, Map.empty)
      <*> newIORef Map.empty
      <*> newIORef Map.empty
      <*> newIORef Map.empty
      <*> newIORef Map.empty
      <*> newIORef Map.empty
      <*> newIORef Map.empty
      <*> newIORef Map.empty
      <*> newIORef Map.empty
  setup app
  done <- newEmptyMVar
  _ <- forkIO (dispatchLoop app >> putMVar done ())
  code <- kayaRun
  takeMVar done
  if code == 0 then exitSuccess else exitWith (ExitFailure (fromIntegral code))

dispatchLoop :: App -> IO ()
dispatchLoop app = do
  occurrence <- nextOccurrence
  case occurrence of
    Nothing -> return () -- shutdown
    Just (kind, ident, keys, payload)
      | kind == W.occKindTextChanged -> do
          let content = case payload of Just (W.VStr s) -> s; _ -> ""
          case keys of
            [] -> do
              handlers <- readIORef (appWidgetChanges app)
              mapM_ ($ content) (Map.lookup ident handlers)
            _ -> do
              handlers <- readIORef (appNodeChanges app)
              mapM_ (\h -> h keys content) (Map.lookup ident handlers)
          dispatchLoop app
      | kind == W.occKindToggled -> do
          let checked = case payload of Just (W.VBool b) -> b; _ -> False
          case keys of
            [] -> do
              handlers <- readIORef (appWidgetToggles app)
              mapM_ ($ checked) (Map.lookup ident handlers)
            _ -> do
              handlers <- readIORef (appNodeToggles app)
              mapM_ (\h -> h keys checked) (Map.lookup ident handlers)
          dispatchLoop app
      | kind == W.occKindValueChanged -> do
          let v = case payload of Just (W.VF64 x) -> x; _ -> 0
          case keys of
            [] -> do
              handlers <- readIORef (appWidgetValues app)
              mapM_ ($ v) (Map.lookup ident handlers)
            _ -> return ()
          dispatchLoop app
    Just (_, ident, [], _) -> do
      handlers <- readIORef (appWidgetHandlers app)
      mapM_ id (Map.lookup ident handlers)
      dispatchLoop app
    Just (_, ident, keys, _) -> do
      handlers <- readIORef (appNodeHandlers app)
      mapM_ ($ keys) (Map.lookup ident handlers)
      dispatchLoop app
