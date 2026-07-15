{-# LANGUAGE TypeFamilies #-}

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
    signal,
    writeSignal,
    insert,
    update,
    remove,
    items,
    count,
    mount,
    bindText,
    bindTextElement,
  )
where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Data.ByteString.Builder (Builder)
import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Word (Word32, Word64)
import System.Exit (ExitCode (..), exitSuccess, exitWith)

import KayaRuntime (kayaRun, kayaSubmit, nextClick)
import qualified KayaWire as W

newtype Signal = Signal Word64

newtype Widget = Widget Word64

newtype Node = Node Word64

newtype Collection = Collection Word64

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
    iEntries :: ![(W.Value, W.Value)]
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
    bOpenFors :: ![Word64]
  }

modelSet :: Word64 -> [W.Value] -> W.Value -> W.Value -> Model -> Model
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

lookupEntries :: Word64 -> [W.Value] -> Model -> [(W.Value, W.Value)]
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
  addChild (Widget p) (Widget child) = emitB (W.txAddChild p child)
  collection = Build $ \s ->
    let c = bCounters s
        n = cCollection c + 1
        s' = registerCollection n s {bCounters = c {cCollection = n}}
     in (Collection n, s' {bRecords = bRecords s' <> W.txCreateCollection n})
  forEach (Collection cid) body =
    Build $ \s ->
      let ((self, a), s') =
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
  addChild (Node p) (Node child) = emitT (W.txAddChild p child)
  collection = Tpl $ \s ->
    let c = bCounters s
        n = cCollection c + 1
        s' = registerCollection n s {bCounters = c {cCollection = n}}
     in (Collection n, s' {bRecords = bRecords s' <> W.txCreateCollection n})
  forEach (Collection cid) body =
    Tpl $ \s ->
      let ((self, a), s') =
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

insert :: Collection -> [W.Value] -> W.Value -> W.Value -> Build ()
insert (Collection n) path key value = Build $ \s ->
  ((), s {bRecords = bRecords s <> W.txCollectionInsert n path key value,
          bModel = modelSet n path key value (bModel s)})

update :: Collection -> [W.Value] -> W.Value -> W.Value -> Build ()
update (Collection n) path key value = Build $ \s ->
  ((), s {bRecords = bRecords s <> W.txCollectionUpdate n path key value,
          bModel = modelSet n path key value (bModel s)})

remove :: Collection -> [W.Value] -> W.Value -> Build ()
remove (Collection n) path key = Build $ \s ->
  ((), s {bRecords = bRecords s <> W.txCollectionRemove n path key,
          bModel = modelRemove (bChildren s) n path key (bModel s)})

-- | The model: what this guest wrote, exactly — the fold of every
-- patch so far (this transaction's included), in insertion order.
items :: Collection -> [W.Value] -> Build [(W.Value, W.Value)]
items (Collection n) path = Build $ \s -> (lookupEntries n path (bModel s), s)

count :: Collection -> [W.Value] -> Build Int
count c path = length <$> items c path

-- | Mount into the default window; per-window targets arrive with the
-- window vocabulary.
mount :: Widget -> Build ()
mount (Widget n) = emitB (W.txMount 0 n)

bindText :: Widget -> Signal -> Build ()
bindText (Widget w) (Signal s) = emitB (W.txBindText w s)

bindTextElement :: Node -> Word32 -> Tpl ()
bindTextElement (Node n) level = emitT (W.txBindTextElement n level)

-- The app: id counters that outlive any one transaction, and the
-- dispatch tables.

data App = App
  { appCounters :: IORef Counters,
    appModel :: IORef (Model, Map.Map Word64 [Word64]),
    appWidgetHandlers :: IORef (Map.Map Word64 (IO ())),
    appNodeHandlers :: IORef (Map.Map Word64 ([W.Value] -> IO ()))
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
  let (a, s) = f (BuildState counters mempty model children [])
  writeIORef (appCounters app) (bCounters s)
  writeIORef (appModel app) (bModel s, bChildren s)
  kayaSubmit [bRecords s]
  return a

-- | buildTx for handlers that keep no handles.
submitTx :: App -> Build () -> IO ()
submitTx app b = buildTx app b

onClick :: App -> Widget -> IO () -> IO ()
onClick app (Widget n) handler =
  modifyIORef' (appWidgetHandlers app) (Map.insert n handler)

onClickNode :: App -> Node -> ([W.Value] -> IO ()) -> IO ()
onClickNode app (Node n) handler =
  modifyIORef' (appNodeHandlers app) (Map.insert n handler)

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
  setup app
  done <- newEmptyMVar
  _ <- forkIO (dispatchLoop app >> putMVar done ())
  code <- kayaRun
  takeMVar done
  if code == 0 then exitSuccess else exitWith (ExitFailure (fromIntegral code))

dispatchLoop :: App -> IO ()
dispatchLoop app = do
  click <- nextClick
  case click of
    Nothing -> return () -- shutdown
    Just (ident, []) -> do
      handlers <- readIORef (appWidgetHandlers app)
      mapM_ id (Map.lookup ident handlers)
      dispatchLoop app
    Just (ident, keys) -> do
      handlers <- readIORef (appNodeHandlers app)
      mapM_ ($ keys) (Map.lookup ident handlers)
      dispatchLoop app
