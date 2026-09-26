-- kaya runtime for Haskell guests: loading, the direct-ring occurrence
-- loop, submit, and blob registration. KayaWire.hs beside it is
-- generated. Blocking entries are `ccall safe` and the -threaded runtime
-- is REQUIRED; kaya_run must own the process main thread, which GHC's
-- main is bound to.
module KayaRuntime
  ( kayaRun,
    kayaSubmit,
    pollOccurrence,
    waitOccurrences,
    wake,
    registerBlob,
    Asset,
    openAsset,
    assetMissSentence,
    appDataDir,
    fmtDateRaw,
    fmtDateWeekdayRaw,
    fmtTimeRaw,
    fmtDateTimeRaw,
    fmtNumberRaw,
    fmtPercentRaw,
    fmtCurrencyRaw,
    localeLine,
    directionBit,
    textScaleRaw,
    catalogRaw,
    TrArgRaw (..),
    trRaw,
    prefGetString,
    prefGetI64,
    prefGetF64,
    prefGetBool,
    prefSetString,
    prefSetI64,
    prefSetF64,
    prefSetBool,
    prefRemove,
    assetBytes,
    assetBlob,
    assetClose,
    openPicked,
    capabilityBits,
    capAuxWindows,
    capNotifications,
    capBadge,
    Key (..),
    textKey,
    intKey,
    keyText,
    keyInt,
    keyOfWire,
    UndoDelta (..),
    UndoText (..),
    UndoEntry (..),
    UndoOrder (..),
    emptyUndoDelta,
  )
where

import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.ByteString.Builder (Builder, toLazyByteString)
import qualified Data.ByteString.Lazy as BL
import Data.ByteString.Unsafe (unsafeUseAsCStringLen)
import Data.IORef (IORef, mkWeakIORef, newIORef, readIORef, writeIORef)
import Data.String (IsString (..))
import Data.Int (Int32, Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word16, Word32, Word64, Word8)
import Foreign.C.Types (CBool (..), CInt (..), CSize (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes, mallocBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr, plusPtr)
import Foreign.Storable (peek, peekByteOff, poke, pokeByteOff)
import Control.Monad (foldM_)
-- Text's own UTF-8 codec, not Foreign.C.String and not GHC.Foreign: the
-- first marshals through the LOCALE's encoding, so LANG=C would
-- round-trip differently, and the second needs a String to do it.
import GHC.IO.Handle.FD (fdToHandle)
import System.IO (Handle)
import System.IO.Unsafe (unsafePerformIO)

import KayaWire
  ( ClipValues,
    DropValues,
    Value (..),
    occKindRedone,
    occKindUndone,
    parseOccurrence,
    parseValue,
    specHash,
  )

foreign import ccall safe "kaya_run"
  c_kaya_run :: IO Int32

foreign import ccall safe "kaya_wake"
  c_kaya_wake :: IO ()

foreign import ccall unsafe "kaya_occurrence_ring"
  c_kaya_occurrence_ring :: Ptr () -> IO ()

-- | Redeem a picked handle: the OS handle lands in the first out-param
-- and seekability in the second; 0 is success. SAFE, not unsafe: it
-- BLOCKS, possibly for a long time, so the RTS must keep running.
foreign import ccall safe "kaya_open_picked"
  c_kaya_open_picked :: Word64 -> Word32 -> Ptr Int64 -> Ptr Word32 -> IO Int32

foreign import ccall safe "kaya_wait_occurrences"
  c_kaya_wait_occurrences :: IO CBool

foreign import ccall unsafe "kaya_spec_hash"
  c_kaya_spec_hash :: IO Word64

foreign import ccall unsafe "kaya_capabilities"
  c_kaya_capabilities :: IO Word64

-- | The raw capability word; guests read named booleans off
-- @KayaApp.capabilities@ and never see this.
capabilityBits :: IO Word64
capabilityBits = c_kaya_capabilities

-- | The core's @KAYA_CAP_AUX_WINDOWS@ written again: a plain .hs has no
-- header to read it from. tools/check-sugar-surface.py fails if this
-- disagrees with crates/kaya/src/scene.rs.
capAuxWindows :: Word64
capAuxWindows = 1

-- | The core's @KAYA_CAP_NOTIFICATIONS@, the same way.
capNotifications :: Word64
capNotifications = 2

-- | The core's @KAYA_CAP_BADGE@, the same way.
capBadge :: Word64
capBadge = 4

foreign import ccall unsafe "kaya_submit"
  c_kaya_submit :: Ptr Word8 -> CSize -> IO ()

foreign import ccall unsafe "kaya_blob_register"
  c_kaya_blob_register :: Ptr Word8 -> CSize -> IO Word64

-- The asset surface (docs/assets-plan.md). `unsafe` because none of
-- these parks: a map lookup plus at most one file read.
foreign import ccall unsafe "kaya_asset_open"
  c_kaya_asset_open :: Ptr Word8 -> CSize -> IO Word64

foreign import ccall unsafe "kaya_asset_bytes"
  c_kaya_asset_bytes :: Word64 -> Ptr CSize -> IO (Ptr Word8)

foreign import ccall unsafe "kaya_asset_blob"
  c_kaya_asset_blob :: Word64 -> IO Word64

foreign import ccall unsafe "kaya_asset_release"
  c_kaya_asset_release :: Word64 -> IO ()

foreign import ccall unsafe "kaya_asset_why_not"
  c_kaya_asset_why_not :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> IO CSize

-- The app's own places (docs/tasks-s4-plan.md §4): the data directory
-- and the typed preferences store. `unsafe` for the same reason the
-- asset calls are: none of these parks.
foreign import ccall unsafe "kaya_app_data_dir"
  c_kaya_app_data_dir :: Ptr Word8 -> CSize -> IO CSize

-- The formatter door and the catalog (docs/compliance-plan.md §3), the
-- C API's fill shape: ask with cap 0, size, ask again. `unsafe` because
-- none of these parks.
foreign import ccall unsafe "kaya_fmt_date"
  c_kaya_fmt_date :: Int64 -> Int64 -> Ptr Word8 -> CSize -> IO CSize

foreign import ccall unsafe "kaya_fmt_date_weekday"
  c_kaya_fmt_date_weekday :: Int64 -> Ptr Word8 -> CSize -> IO CSize

foreign import ccall unsafe "kaya_fmt_time"
  c_kaya_fmt_time :: Int64 -> Int64 -> Ptr Word8 -> CSize -> IO CSize

foreign import ccall unsafe "kaya_fmt_date_time"
  c_kaya_fmt_date_time :: Int64 -> Int64 -> Int64 -> Ptr Word8 -> CSize -> IO CSize

foreign import ccall unsafe "kaya_fmt_number"
  c_kaya_fmt_number :: Double -> Ptr Word8 -> Ptr Word8 -> CSize -> IO CSize

foreign import ccall unsafe "kaya_fmt_percent"
  c_kaya_fmt_percent :: Double -> Ptr Word8 -> Ptr Word8 -> CSize -> IO CSize

foreign import ccall unsafe "kaya_fmt_currency"
  c_kaya_fmt_currency :: Double -> Ptr Word8 -> Ptr Word8 -> CSize -> IO CSize

foreign import ccall unsafe "kaya_locale"
  c_kaya_locale :: Ptr Word8 -> CSize -> IO CSize

foreign import ccall unsafe "kaya_direction"
  c_kaya_direction :: IO Word32

foreign import ccall unsafe "kaya_text_scale"
  c_kaya_text_scale :: IO Double

foreign import ccall unsafe "kaya_catalog"
  c_kaya_catalog :: Ptr Word8 -> IO ()

foreign import ccall unsafe "kaya_tr"
  c_kaya_tr :: Ptr Word8 -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> IO CSize

foreign import ccall unsafe "kaya_pref_get_string"
  c_kaya_pref_get_string ::
    Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> Ptr CSize -> IO CInt

foreign import ccall unsafe "kaya_pref_get_i64"
  c_kaya_pref_get_i64 :: Ptr Word8 -> CSize -> Ptr Int64 -> IO CInt

foreign import ccall unsafe "kaya_pref_get_f64"
  c_kaya_pref_get_f64 :: Ptr Word8 -> CSize -> Ptr Double -> IO CInt

foreign import ccall unsafe "kaya_pref_get_bool"
  c_kaya_pref_get_bool :: Ptr Word8 -> CSize -> Ptr Word8 -> IO CInt

foreign import ccall unsafe "kaya_pref_set_string"
  c_kaya_pref_set_string :: Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> IO ()

foreign import ccall unsafe "kaya_pref_set_i64"
  c_kaya_pref_set_i64 :: Ptr Word8 -> CSize -> Int64 -> IO ()

foreign import ccall unsafe "kaya_pref_set_f64"
  c_kaya_pref_set_f64 :: Ptr Word8 -> CSize -> Double -> IO ()

foreign import ccall unsafe "kaya_pref_set_bool"
  c_kaya_pref_set_bool :: Ptr Word8 -> CSize -> Word8 -> IO ()

foreign import ccall unsafe "kaya_pref_remove"
  c_kaya_pref_remove :: Ptr Word8 -> CSize -> IO ()

foreign import ccall unsafe "kaya_occurrence_blob"
  c_kaya_occurrence_blob :: Word64 -> Ptr CSize -> IO (Ptr Word8)

foreign import ccall unsafe "kaya_occurrence_blob_release"
  c_kaya_occurrence_blob_release :: Word64 -> IO ()

-- Redeem an occurrence blob for its bytes, and release it. COPY THEN
-- RELEASE, in that order: the pointer borrows core memory that the
-- release frees. Release is idempotent.
occurrenceBlob :: Word64 -> IO BS.ByteString
occurrenceBlob handle =
  alloca $ \lenPtr -> do
    poke lenPtr 0
    dat <- c_kaya_occurrence_blob handle lenPtr
    len <- peek lenPtr
    out <-
      if dat == nullPtr || len == 0
        then return BS.empty
        else BS.packCStringLen (castPtr dat, fromIntegral len)
    c_kaya_occurrence_blob_release handle
    return out

-- The ordered cursor accesses; see kaya_hs_stubs.c.
foreign import ccall unsafe "kaya_hs_load_acquire_u32"
  loadAcquireU32 :: Ptr Word32 -> IO Word32

foreign import ccall unsafe "kaya_hs_store_release_u32"
  storeReleaseU32 :: Ptr Word32 -> Word32 -> IO ()

checkSpec :: IO ()
checkSpec = do
  got <- c_kaya_spec_hash
  if got == specHash
    then return ()
    else
      error
        ("kaya: library speaks spec " ++ show got
           ++ ", this binding was generated from " ++ show specHash
           ++ " — rebuild the library or regenerate bindings")

-- | Enter the core on the calling thread, which must be the process main
-- thread; returns the exit code when the app ends.
kayaRun :: IO Int32
kayaRun = checkSpec >> c_kaya_run

-- | Submit one transaction: the concatenation of packed records (tx*
-- results from KayaWire), applied atomically.
kayaSubmit :: [Builder] -> IO ()
kayaSubmit records =
  unsafeUseAsCStringLen (BL.toStrict (toLazyByteString (mconcat records))) $
    \(p, len) -> c_kaya_submit (castPtr p) (fromIntegral len)

-- | Register bulk payload bytes with the core, returning the u64
-- handle. The handle is CONSUMED by the next submit from this guest,
-- referenced or not.
registerBlob :: BS.ByteString -> IO Word64
registerBlob bytes =
  unsafeUseAsCStringLen bytes $ \(p, len) ->
    c_kaya_blob_register (castPtr p) (fromIntegral len)

-- | An open asset: the bytes kaya read, held by the core until this is
-- released.
data Asset = Asset {assetCell :: IORef Word64}

-- | Open an asset by name; a miss raises with the core's sentence,
-- verbatim. 'errorWithoutStackTrace' rather than 'error': 'error'
-- appends a GHC CallStack, and the scenes compare these bytes across
-- languages.
openAsset :: Text -> IO Asset
openAsset name = do
  handle <- withName name c_kaya_asset_open
  if handle == 0
    then errorWithoutStackTrace . T.unpack =<< assetMissSentence name
    else do
      cell <- newIORef handle
      -- THE FINALIZER CLOSES OVER THE HANDLE NUMBER, NEVER THE CELL: a
      -- finalizer that mentioned `cell` would keep it reachable forever
      -- and never run.
      _ <- mkWeakIORef cell (c_kaya_asset_release handle)
      return (Asset cell)

-- | The core's sentence for why a name would miss, fetched whole. @""@
-- means it resolves; its one author is @asset_why_not@ in
-- crates/kaya/src/assets.rs. SIZED, THEN READ: the C entry returns the
-- sentence's TRUE length, so the first call measures and the second
-- fills.
assetMissSentence :: Text -> IO Text
assetMissSentence name = do
  len <- withName name $ \p n -> c_kaya_asset_why_not p n nullPtr 0
  allocaBytes (fromIntegral len) $ \out -> do
    _ <- withName name $ \p n -> c_kaya_asset_why_not p n out len
    peekUtf8 out len

-- | The app's own writable directory, @""@ before one exists. SIZED,
-- THEN READ, 'assetMissSentence''s two-call shape.
appDataDir :: IO FilePath
appDataDir = do
  len <- c_kaya_app_data_dir nullPtr 0
  if len == 0
    then return ""
    else allocaBytes (fromIntegral len) $ \out -> do
      written <- c_kaya_app_data_dir out len
      T.unpack <$> peekUtf8 out (min written len)

-- The door's answer, 'assetMissSentence''s two-call shape; 'Nothing' is
-- the core's fault (its sentence is on stderr), never an empty answer.
fillDoor :: (Ptr Word8 -> CSize -> IO CSize) -> IO (Maybe Text)
fillDoor ask = do
  len <- ask nullPtr 0
  if len == 0
    then return Nothing
    else allocaBytes (fromIntegral len) $ \out -> do
      written <- ask out len
      Just <$> peekUtf8 out (min written len)

-- A NUL-terminated copy of a Text, for the C API's `const char *` arguments.
withCString0 :: Text -> (Ptr Word8 -> IO a) -> IO a
withCString0 text body =
  let bytes = TE.encodeUtf8 text <> BS.singleton 0
   in unsafeUseAsCStringLen bytes $ \(p, _) -> body (castPtr p)

fmtDateRaw :: Int64 -> Int64 -> IO (Maybe Text)
fmtDateRaw packed len = fillDoor (c_kaya_fmt_date packed len)

fmtDateWeekdayRaw :: Int64 -> IO (Maybe Text)
fmtDateWeekdayRaw packed = fillDoor (c_kaya_fmt_date_weekday packed)

fmtTimeRaw :: Int64 -> Int64 -> IO (Maybe Text)
fmtTimeRaw packed len = fillDoor (c_kaya_fmt_time packed len)

fmtDateTimeRaw :: Int64 -> Int64 -> Int64 -> IO (Maybe Text)
fmtDateTimeRaw date time len = fillDoor (c_kaya_fmt_date_time date time len)

-- KayaNumberOptions by hand: two i32 and a bool, twelve bytes.
withNumberOptions :: Int32 -> Int32 -> Bool -> (Ptr Word8 -> IO a) -> IO a
withNumberOptions minD maxD grouped body =
  allocaBytes 12 $ \o -> do
    pokeByteOff o 0 minD
    pokeByteOff o 4 maxD
    pokeByteOff o 8 (if grouped then 1 else 0 :: Word8)
    body o

fmtNumberRaw :: Double -> Int32 -> Int32 -> Bool -> IO (Maybe Text)
fmtNumberRaw v minD maxD grouped =
  withNumberOptions minD maxD grouped $ \o -> fillDoor (c_kaya_fmt_number v o)

fmtPercentRaw :: Double -> Int32 -> Int32 -> Bool -> IO (Maybe Text)
fmtPercentRaw v minD maxD grouped =
  withNumberOptions minD maxD grouped $ \o -> fillDoor (c_kaya_fmt_percent v o)

fmtCurrencyRaw :: Double -> Text -> IO (Maybe Text)
fmtCurrencyRaw v code = withCString0 code $ \c -> fillDoor (c_kaya_fmt_currency v c)

localeLine :: IO (Maybe Text)
localeLine = fillDoor c_kaya_locale

directionBit :: IO Word32
directionBit = c_kaya_direction

textScaleRaw :: IO Double
textScaleRaw = c_kaya_text_scale

catalogRaw :: Text -> IO ()
catalogRaw app = withCString0 app c_kaya_catalog

-- KayaTrArg's five tags, the packed date and time as the wire packs them.
data TrArgRaw = TrInt Int64 | TrFloat Double | TrStr Text | TrDate Int64 | TrTime Int64

-- Every string alive for the whole call, nested.
withStrings :: [Text] -> ([Ptr Word8] -> IO a) -> IO a
withStrings [] body = body []
withStrings (s : rest) body = withCString0 s $ \p -> withStrings rest $ \ps -> body (p : ps)

-- KayaTrArg by hand: name ptr, u32 tag (padded), i64, f64, s ptr — forty
-- bytes at offsets 0, 8, 16, 24, 32.
trRaw :: Text -> [(Text, TrArgRaw)] -> IO (Maybe Text)
trRaw key args =
  withCString0 key $ \k ->
    withStrings (map fst args) $ \names ->
      withStrings [s | (_, TrStr s) <- args] $ \strs ->
        allocaBytes (max 1 n * 40) $ \records -> do
          let write (i, (name, arg)) rest = do
                let r = records `plusPtr` (i * 40)
                pokeByteOff r 0 name
                pokeByteOff r 16 (0 :: Int64)
                pokeByteOff r 24 (0 :: Double)
                pokeByteOff r 32 (nullPtr :: Ptr Word8)
                case arg of
                  TrInt v -> pokeByteOff r 8 (0 :: Word32) >> pokeByteOff r 16 v >> return rest
                  TrFloat v -> pokeByteOff r 8 (1 :: Word32) >> pokeByteOff r 24 v >> return rest
                  TrStr _ -> case rest of
                    (s : more) -> pokeByteOff r 8 (2 :: Word32) >> pokeByteOff r 32 s >> return more
                    [] -> return []
                  TrDate v -> pokeByteOff r 8 (3 :: Word32) >> pokeByteOff r 16 v >> return rest
                  TrTime v -> pokeByteOff r 8 (4 :: Word32) >> pokeByteOff r 16 v >> return rest
          foldM_ (flip write) strs (zip [0 ..] (zip names (map snd args)))
          fillDoor (c_kaya_tr k records (fromIntegral n))
  where
    n = length args

-- | The stored string, or 'Nothing' when the key is absent or holds
-- another type.
prefGetString :: Text -> IO (Maybe Text)
prefGetString key =
  withName key $ \k n -> alloca $ \lenPtr -> do
    poke lenPtr 0
    present <- c_kaya_pref_get_string k n nullPtr 0 lenPtr
    if present == 0
      then return Nothing
      else do
        len <- peek lenPtr
        if len == 0
          then return (Just T.empty)
          else allocaBytes (fromIntegral len) $ \out -> do
            ok <- c_kaya_pref_get_string k n out len lenPtr
            if ok == 0
              then return Nothing
              else do
                got <- peek lenPtr
                Just <$> peekUtf8 out (min got len)

prefGetI64 :: Text -> IO (Maybe Int64)
prefGetI64 key =
  withName key $ \k n -> alloca $ \out -> do
    poke out 0
    present <- c_kaya_pref_get_i64 k n out
    if present == 0 then return Nothing else Just <$> peek out

prefGetF64 :: Text -> IO (Maybe Double)
prefGetF64 key =
  withName key $ \k n -> alloca $ \out -> do
    poke out 0
    present <- c_kaya_pref_get_f64 k n out
    if present == 0 then return Nothing else Just <$> peek out

prefGetBool :: Text -> IO (Maybe Bool)
prefGetBool key =
  withName key $ \k n -> alloca $ \out -> do
    poke out 0
    present <- c_kaya_pref_get_bool k n out
    if present == 0 then return Nothing else Just . (/= 0) <$> peek out

prefSetString :: Text -> Text -> IO ()
prefSetString key value =
  withName key $ \k n -> withName value $ \v vn -> c_kaya_pref_set_string k n v vn

prefSetI64 :: Text -> Int64 -> IO ()
prefSetI64 key value = withName key $ \k n -> c_kaya_pref_set_i64 k n value

prefSetF64 :: Text -> Double -> IO ()
prefSetF64 key value = withName key $ \k n -> c_kaya_pref_set_f64 k n value

prefSetBool :: Text -> Bool -> IO ()
prefSetBool key value =
  withName key $ \k n -> c_kaya_pref_set_bool k n (if value then 1 else 0)

prefRemove :: Text -> IO ()
prefRemove key = withName key $ \k n -> c_kaya_pref_remove k n

-- The name as UTF-8 bytes plus its length. NOT NUL-terminated: the core
-- reads exactly the length handed to it. Text's own encoder, never the
-- locale-sensitive GHC.Foreign pair: this boundary is UTF-8 by contract.
withName :: Text -> (Ptr Word8 -> CSize -> IO a) -> IO a
withName name body =
  unsafeUseAsCStringLen (TE.encodeUtf8 name) $ \(p, n) ->
    body (castPtr p) (fromIntegral n)

-- The core's answer, decoded: it writes UTF-8 and nothing else.
peekUtf8 :: Ptr Word8 -> CSize -> IO Text
peekUtf8 out len =
  TE.decodeUtf8 <$> BS.packCStringLen (castPtr out, fromIntegral len)

-- | This asset's bytes, copied out of core memory: the pointer the core
-- hands back borrows its buffer only until release.
assetBytes :: Asset -> IO BS.ByteString
assetBytes asset = do
  handle <- liveHandle asset
  alloca $ \lenPtr -> do
    poke lenPtr 0
    dat <- c_kaya_asset_bytes handle lenPtr
    len <- peek lenPtr
    if dat == nullPtr || len == 0
      then return BS.empty
      else BS.packCStringLen (castPtr dat, fromIntegral len)

-- | Register this asset's bytes into the pending table and answer with the
-- handle the record carries.
assetBlob :: Asset -> IO Word64
assetBlob asset = liveHandle asset >>= c_kaya_asset_blob

-- | Let the core drop these bytes. Idempotent.
assetClose :: Asset -> IO ()
assetClose asset = do
  handle <- readIORef (assetCell asset)
  if handle == 0
    then return ()
    else do
      writeIORef (assetCell asset) 0
      c_kaya_asset_release handle

liveHandle :: Asset -> IO Word64
liveHandle asset = do
  handle <- readIORef (assetCell asset)
  if handle == 0
    then
      errorWithoutStackTrace
        "kaya: this asset is closed — an asset's bytes live in the core until \
        \assetClose, and a use after that has nothing to read; open it again \
        \with asset"
    else return handle

data Ring = Ring (Ptr Word8) Word32 (Ptr Word32) (Ptr Word32) Word32

{-# NOINLINE ringRef #-}
ringRef :: IORef (Maybe Ring)
ringRef = unsafePerformIO (newIORef Nothing)

ring :: IO Ring
ring = do
  cached <- readIORef ringRef
  case cached of
    Just r -> return r
    Nothing -> do
      -- KayaRingInfo, as declared in kaya.h:
      -- { u8 *data; u32 capacity; u32 *head; u32 *tail } — offsets
      -- 0/8/16/24.
      info <- mallocBytes 32
      c_kaya_occurrence_ring info
      dat <- peekByteOff info 0 :: IO (Ptr Word8)
      capacity <- peekByteOff info 8 :: IO Word32
      headPtr <- peekByteOff info 16 :: IO (Ptr Word32)
      tailPtr <- peekByteOff info 24 :: IO (Ptr Word32)
      h0 <- loadAcquireU32 headPtr
      let r = Ring dat capacity headPtr tailPtr h0
      writeIORef ringRef (Just r)
      return r

-- | Return the app thread from waitOccurrences. Safe from any thread;
-- guests do not name it.
wake :: IO ()
wake = c_kaya_wake

-- Block until there MAY be something to do: a record arrived, or another
-- thread called wake.
waitOccurrences :: IO Bool
waitOccurrences = do
  more <- c_kaya_wait_occurrences
  return (more /= CBool 0)

-- | What an undo or a redo PUT BACK: the core-authoritative statement of
-- the restored state (docs/undo-plan.md D5). A STATEMENT, NOT A REPLAY —
-- every member says what a thing now IS, so applying one twice is the
-- same as applying it once.
-- | A collection entry's KEY. ONE TYPE A LITERAL ALREADY IS: a string
-- literal is a text key through 'IsString' and an integer literal is the
-- minted I64 kind through 'Num', so @insert c "a" v@ and @remove c 3@
-- need no ascription, and a key read back out of a handler's path is the
-- same type going in. The guest-facing type for every key a guest spells
-- or reads back, so no guest names the wire's own value sum (OCaml's
-- @type key@ with @str_key@\/@int_key@\/@key_text@ is the same decision;
-- tools\/check-sugar-surface.py's wire-tag clause is why). It lives HERE
-- rather than in Kaya.Core because the undo payload below carries key
-- paths and this module is under that one.
--
-- THE CONSTRUCTOR IS NOT EXPORTED PAST Kaya.Core: 'textKey', 'intKey' and
-- the two literal instances are the only ways in, so 'keyText' and
-- 'keyInt' are total by construction.
newtype Key = Key {keyValue :: Value}
  deriving (Eq)

-- A key SHOWS as its own text, never as the wire tag that carries it: a
-- guest's error sentence names the row it could not find.
instance Show Key where
  show = T.unpack . keyText

instance IsString Key where
  fromString = Key . VStr

-- A KEY IS NOT A NUMBER, and 'fromInteger' is the whole reason this
-- instance exists: an integer literal has to be the I64 key
-- 'insertFresh' mints. Num carries five more methods with no meaning on
-- a key and no smaller class to take 'fromInteger' from, so they refuse
-- by name rather than inventing arithmetic.
instance Num Key where
  fromInteger = Key . VI64 . fromInteger
  (+) = notArithmetic "+"
  (-) = notArithmetic "-"
  (*) = notArithmetic "*"
  abs = notArithmetic "abs"
  signum = notArithmetic "signum"
  negate = notArithmetic "negate"

notArithmetic :: String -> a
notArithmetic op =
  errorWithoutStackTrace
    ( "kaya: a collection key is not a number — " ++ op ++ " has no meaning "
        ++ "on one. Num is here so an integer literal is an I64 key." )

-- | A text key from a value the guest computed; the literal form is the
-- 'IsString' instance (OCaml's @str_key@).
textKey :: Text -> Key
textKey = Key . VStr . T.unpack

-- | A minted-number key from a value the guest computed (OCaml's
-- @int_key@).
intKey :: Int64 -> Key
intKey = Key . VI64

-- | A key as text — an Int key renders as its decimal, so a label can
-- name any row (OCaml's @key_text@).
keyText :: Key -> Text
keyText (Key (VStr s)) = T.pack s
keyText (Key (VI64 n)) = T.pack (show n)
keyText (Key other) = T.pack (show other)

-- | A key's minted number, 'Nothing' for a text key.
keyInt :: Key -> Maybe Int64
keyInt (Key (VI64 n)) = Just n
keyInt (Key _) = Nothing

keyOfWire :: Value -> Key
keyOfWire = Key

data UndoDelta = UndoDelta
  { -- | Signal id -> its restored value.
    undoSignals :: ![(Word64, Value)],
    -- | The text fields this step put back, each NAMING itself.
    undoTexts :: ![UndoText],
    -- | Collection entries, present or gone.
    undoEntries :: ![UndoEntry],
    -- | Instance orders, which per-entry statements cannot carry.
    undoOrders :: ![UndoOrder]
  }

-- | One text field's restored text, and the identity that names it.
-- TWO IDENTITIES DECIDED BY THE PATH: an EMPTY 'utPath' means 'utId' is
-- a live widget's id; a non-empty one means 'utId' is the TEMPLATE NODE
-- and the path is the copy's keys, outermost first (docs\/undo-plan.md
-- §3b).
data UndoText = UndoText
  { utId :: !Word64,
    utPath :: ![Key],
    utText :: !Text
  }

-- | One collection entry's restored state; 'ueState' is Nothing when
-- the restored state does not have this entry at all.
data UndoEntry = UndoEntry
  { ueCollection :: !Word64,
    uePath :: ![Key],
    ueKey :: !Key,
    ueState :: !(Maybe (Word32, [Value]))
  }

-- | One collection instance's restored key order.
data UndoOrder = UndoOrder
  { uoCollection :: !Word64,
    uoPath :: ![Key],
    uoKeys :: ![Key]
  }

-- | The empty statement: an occurrence carrying nothing back.
emptyUndoDelta :: UndoDelta
emptyUndoDelta = UndoDelta [] [] [] []

-- Decode an undone\/redone record: u64 window, the four run counts, the
-- Str label, then ONE flat value list read as those four runs in order
-- (kaya.h, KAYA_OCCURRENCE_UNDONE; crates\/kaya\/src\/wire.rs
-- undo_body).
parseUndo :: Ptr Word8 -> IO (Word64, Text, UndoDelta)
parseUndo rec = do
  window <- peekByteOff rec 8 :: IO Word64
  signals <- peekByteOff rec 16 :: IO Word32
  texts <- peekByteOff rec 20 :: IO Word32
  entries <- peekByteOff rec 24 :: IO Word32
  orders <- peekByteOff rec 28 :: IO Word32
  (labelValue, afterLabel) <- parseValue rec 32
  count <- peekByteOff rec afterLabel :: IO Word32
  let readValues 0 _ acc = return (reverse acc)
      readValues n at acc = do
        (v, next) <- parseValue rec at
        -- A restored record's blob field (a document's bytes, an image's)
        -- rides the OCCURRENCE table like a paste's: redeem and release
        -- here, so the model holds the bytes the field readers expect
        -- (crates/kaya/src/wire.rs, undo_body).
        v' <- case v of
          VBlob handle -> VStr . BC.unpack <$> occurrenceBlob handle
          other -> return other
        readValues (n - 1 :: Word32) next (v' : acc)
  -- The Values block's own header is {u32 count, u32 reserved}.
  flat <- readValues count (afterLabel + 8) []
  let label = case labelValue of
        VStr s -> T.pack s
        other -> error ("kaya: undo label is " ++ show other ++ ", wanted a string")
      int (VI64 n) = n
      int other = error ("kaya: undo delta wanted an integer, got " ++ show other)
      takeRun 0 rest acc _ = (reverse acc, rest)
      takeRun n rest acc step = case step rest of
        (one, rest') -> takeRun (n - 1 :: Word32) rest' (one : acc) step
      pair (i : v : rest) = ((fromIntegral (int i) :: Word64, v), rest)
      pair _ = error "kaya: undo delta is truncated"
      -- ARITY-FIRST: `size` counts ITSELF, so a reader takes the head
      -- it knows and `size` decides the rest.
      text (size : ident : pathLen : rest) =
        let body = fromIntegral (int size) - 3
            (mine, rest') = splitAt body rest
            plen = fromIntegral (int pathLen)
            (path, textOnly) = splitAt plen mine
         in case textOnly of
              [VStr s] -> (UndoText (fromIntegral (int ident)) (map keyOfWire path) (T.pack s), rest')
              _ -> error "kaya: undo text is truncated or not a string"
      text _ = error "kaya: undo text is truncated"
      entry (size : collection : present : variant : pathLen : rest) =
        let body = fromIntegral (int size) - 5
            (mine, rest') = splitAt body rest
            plen = fromIntegral (int pathLen)
            (path, keyAndRecord) = splitAt plen mine
         in case keyAndRecord of
              (key : record) ->
                ( UndoEntry
                    (fromIntegral (int collection))
                    (map keyOfWire path)
                    (keyOfWire key)
                    ( if int present /= 0
                        then Just (fromIntegral (int variant), record)
                        else Nothing
                    ),
                  rest'
                )
              [] -> error "kaya: undo entry has no key"
      entry _ = error "kaya: undo entry is truncated"
      order (size : collection : pathLen : rest) =
        let body = fromIntegral (int size) - 3
            (mine, rest') = splitAt body rest
            plen = fromIntegral (int pathLen)
            (path, keys) = splitAt plen mine
         in (UndoOrder (fromIntegral (int collection)) (map keyOfWire path) (map keyOfWire keys), rest')
      order _ = error "kaya: undo order is truncated"
      (signalRun, afterSignals) = takeRun signals flat [] pair
      (textRun, afterTexts) = takeRun texts afterSignals [] text
      (entryRun, afterEntries) = takeRun entries afterTexts [] entry
      (orderRun, leftover) = takeRun orders afterEntries [] order
  if null leftover
    then return (window, label, UndoDelta signalRun textRun entryRun orderRun)
    else error "kaya: undo delta has trailing values"

-- Read the next occurrence if one is ready, WITHOUT blocking; Nothing
-- means the ring is empty. Single consumer. The undo pair rides the same
-- tuple as everything else: the window in the id slot, the label as the
-- payload, the restored state next; the LAST member is the canvas asks'
-- trailing values — the assigned size and a tick's frame time
-- (docs/canvas-plan.md §3.2.1).
pollOccurrence ::
  IO
    ( Maybe
        ( Word16,
          Word64,
          [Value],
          Maybe Value,
          Maybe ClipValues,
          Maybe DropValues,
          Maybe UndoDelta,
          [Value]
        )
    )
pollOccurrence = do
  Ring dat capacity headPtr tailPtr h <- ring
  let mask = capacity - 1
      loop hh = do
        t <- loadAcquireU32 tailPtr -- acquire: records below are visible
        if hh == t
          then return Nothing
          else do
            let at = fromIntegral (hh .&. mask)
            size <- peekByteOff dat at :: IO Word32
            kind <- peekByteOff dat (at + 4) :: IO Word16
            parsed <-
              if kind == occKindUndone || kind == occKindRedone
                then do
                  (w, label, delta) <- parseUndo (dat `plusPtr` at)
                  return (Just (kind, w, [], Just (VStr (T.unpack label)), Nothing, Nothing, Just delta, []))
                else do
                  ordinary <- parseOccurrence occurrenceBlob (dat `plusPtr` at)
                  return
                    ( fmap
                        (\(k, ident, keys, payload, clip, drop_, rest) -> (k, ident, keys, payload, clip, drop_, Nothing, rest))
                        ordinary
                    )
            -- Word32 wraps on its own; hand the space back with release.
            let hh' = hh + size
            storeReleaseU32 headPtr hh'
            cached <- readIORef ringRef
            case cached of
              Just (Ring d c hp tp _) ->
                writeIORef ringRef (Just (Ring d c hp tp hh'))
              Nothing -> return ()
            case parsed of
              Just occ -> return (Just occ)
              Nothing -> loop hh'
  loop h

-- | Redeem a picked handle for a real 'Handle', plus whether it seeks.
-- BLOCKS, possibly for a long time, so call it from a thread you chose
-- and post the result back (DESIGN.md, File dialogs).
--
-- THE DESCRIPTOR BECOMES GHC'S: 'fdToHandle' takes it over, so 'hClose'
-- closes it exactly once and the core keeps no claim.
openPicked :: Word64 -> Word32 -> IO (Handle, Bool)
openPicked handle mode =
  alloca $ \rawPtr -> alloca $ \seekPtr -> do
    rc <- c_kaya_open_picked handle mode rawPtr seekPtr
    if rc /= 0
      then
        ioError
          (userError ("kaya: opening the picked file failed (code " ++ show rc ++ ")"))
      else do
        raw <- peek rawPtr
        seekable <- peek seekPtr
        h <- fdToHandle (fromIntegral raw)
        return (h, seekable /= 0)
