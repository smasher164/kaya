{- The milestone-2 scene from Haskell through the direct ring tier:
   Haskell reads the occurrence ring with its own loads, and answers with
   packed transaction records through kaya_submit. The scene declares a
   When (the extras banner) and a nested For (groups holding items);
   clicks on stamped remove buttons come back as a template node id plus
   key path, and the app answers by removing that entry. The C boundary
   is crossed only to start the core, to wait on an empty ring, and to
   submit.

   The data path is plain peeks on the ring's memory — GHC inlines them
   to real loads, so no call and no boxing survives a tight loop — with
   ordering carried by two C stubs (milestone0_hs_stubs.c) imported
   `ccall unsafe`, the same cursor recipe as the OCaml example; the
   stubs' header explains why GHC's own Addr# atomics are the wrong
   shape for these two accesses. The transaction side needs no atomics
   at all: pack records with a ByteString Builder (bytestring ships with
   GHC), one submit per batch.
   The blocking entries are imported `ccall safe`, which releases the
   capability so the runtime keeps scheduling while C blocks; the
   -threaded runtime is required for that.

   Build the library first (cargo build), then:
       ghc -threaded -O -o milestone0-hs \
           milestone0_hs_stubs.c milestone0.hs \
           -L target/debug -lkaya -optl-Wl,-rpath,<abs path to target/debug>

   Linked against libkaya at build time; kaya_run must own the process
   main thread, and GHC's main runs bound to it. -}

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (when)
import Data.Bits (complement, (.&.))
import qualified Data.ByteString as BS
import Data.ByteString.Builder
  ( Builder,
    byteString,
    stringUtf8,
    toLazyByteString,
    word16LE,
    word32LE,
    word64LE,
    word8,
  )
import qualified Data.ByteString.Lazy as BL
import Data.ByteString.Unsafe (unsafeUseAsCStringLen)
import Data.Char (chr)
import Data.Int (Int32)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Word (Word16, Word32, Word64, Word8)
import Foreign.C.Types (CBool (..), CSize (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (peekArray)
import Foreign.Ptr (Ptr, castPtr, plusPtr)
import Foreign.Storable (peekByteOff)
import System.Exit (ExitCode (..), exitSuccess, exitWith)

foreign import ccall safe "kaya_run"
  kayaRun :: IO Int32

foreign import ccall unsafe "kaya_occurrence_ring"
  kayaOccurrenceRing :: Ptr () -> IO ()

foreign import ccall safe "kaya_wait_occurrences"
  kayaWaitOccurrences :: IO CBool

foreign import ccall unsafe "kaya_submit"
  kayaSubmit :: Ptr Word8 -> CSize -> IO ()

-- The ordered cursor accesses; see milestone0_hs_stubs.c.
foreign import ccall unsafe "kaya_hs_load_acquire_u32"
  loadAcquireU32 :: Ptr Word32 -> IO Word32

foreign import ccall unsafe "kaya_hs_store_release_u32"
  storeReleaseU32 :: Ptr Word32 -> Word32 -> IO ()

buttonClicked :: Word16
buttonClicked = 1 -- KAYA_OCCURRENCE_BUTTON_CLICKED

-- KAYA_TX_* record kinds and value/source tags from kaya.h.
txCreateSignal, txWriteSignal, txCreateWidget :: Word16
txSetProperty, txAddChild, txMount :: Word16
txCreateCollection, txCollectionInsert, txCollectionUpdate :: Word16
txCollectionRemove, txCreateFor, txCreateWhen, txTemplateEnd :: Word16
txCreateSignal = 1
txWriteSignal = 2
txCreateWidget = 3
txSetProperty = 4
txAddChild = 5
txMount = 6
txCreateCollection = 7
txCollectionInsert = 8
txCollectionUpdate = 9
txCollectionRemove = 10
txCreateFor = 11
txCreateWhen = 12
txTemplateEnd = 13

kindColumn, kindButton, kindLabel :: Word32
kindColumn = 1
kindButton = 2
kindLabel = 3

propText, sourceConst, sourceSignal, sourceElement :: Word32
propText = 1
sourceConst = 0
sourceSignal = 1
sourceElement = 2

valueBool, valueStr :: Word32
valueBool = 1
valueStr = 4

-- Guest-allocated ids, counted from 1 per space.
sigStatus, sigExtras :: Word64
sigStatus = 1
sigExtras = 2

wColumn, wStep, wStatus, wWhen, wGroups :: Word64
wColumn = 1
wStep = 2
wStatus = 3
wWhen = 4
wGroups = 5

cGroups, cItems :: Word64
cGroups = 1
cItems = 2

nBanner, nGroupCol, nGroupLbl, nItemsFor, nItemRow, nItemText, nRemove :: Word64
nBanner = 1
nGroupCol = 2
nGroupLbl = 3
nItemsFor = 4
nItemRow = 5
nItemText = 6
nRemove = 7

-- --- Transaction packing (KAYA_TX_* layouts from kaya.h) --------------

-- One packed record: {u32 size, u16 kind, u16 flags}, body, pad to 8.
-- The body is packed first so the size is known up front.
record :: Word16 -> Builder -> Builder
record kind body =
  let bytes = BL.toStrict (toLazyByteString body)
      size = 8 + BS.length bytes
      padded = (size + 7) .&. complement 7
   in word32LE (fromIntegral padded)
        <> word16LE kind
        <> word16LE 0
        <> byteString bytes
        <> byteString (BS.replicate (padded - size) 0)

-- Values are self-padded to 8: they concatenate inside record bodies.
strValue :: String -> Builder
strValue text =
  let utf8 = BL.toStrict (toLazyByteString (stringUtf8 text))
      len = BS.length utf8
      padded = (len + 7) .&. complement 7
   in word32LE valueStr
        <> word32LE (fromIntegral len)
        <> byteString utf8
        <> byteString (BS.replicate (padded - len) 0)

boolValue :: Bool -> Builder
boolValue v =
  word32LE valueBool
    <> word32LE 1
    <> word8 (if v then 1 else 0)
    <> byteString (BS.replicate 7 0)

-- A key path: {u32 count, u32 reserved, count values}.
pathOf :: [String] -> Builder
pathOf keys =
  word32LE (fromIntegral (length keys)) <> word32LE 0 <> foldMap strValue keys

submit :: Builder -> IO ()
submit tx =
  unsafeUseAsCStringLen (BL.toStrict (toLazyByteString tx)) $ \(p, len) ->
    kayaSubmit (castPtr p) (fromIntegral len)

widget :: Word64 -> Word32 -> Builder
widget i kind = record txCreateWidget (word64LE i <> word32LE kind <> word32LE 0)

textConst :: Word64 -> String -> Builder
textConst i text =
  record txSetProperty (word64LE i <> word32LE propText <> word32LE sourceConst <> strValue text)

textElement :: Word64 -> Word32 -> Builder
textElement i level =
  record
    txSetProperty
    (word64LE i <> word32LE propText <> word32LE sourceElement <> word32LE level <> word32LE 0)

twoU64 :: Word16 -> Word64 -> Word64 -> Builder
twoU64 kind a b = record kind (word64LE a <> word64LE b)

insertB :: Word64 -> [String] -> String -> String -> Builder
insertB coll at key value =
  record txCollectionInsert (word64LE coll <> pathOf at <> strValue key <> strValue value)

updateB :: Word64 -> [String] -> String -> String -> Builder
updateB coll at key value =
  record txCollectionUpdate (word64LE coll <> pathOf at <> strValue key <> strValue value)

removeB :: Word64 -> [String] -> String -> Builder
removeB coll at key =
  record txCollectionRemove (word64LE coll <> pathOf at <> strValue key)

writeStr :: Word64 -> String -> Builder
writeStr sig text = record txWriteSignal (word64LE sig <> strValue text)

writeBool :: Word64 -> Bool -> Builder
writeBool sig v = record txWriteSignal (word64LE sig <> boolValue v)

sceneTx :: IO ()
sceneTx =
  submit $
    record txCreateSignal (word64LE sigStatus <> strValue "step 0")
      <> record txCreateSignal (word64LE sigExtras <> boolValue False)
      <> widget wColumn kindColumn
      <> widget wStep kindButton
      <> textConst wStep "step"
      <> widget wStatus kindLabel
      <> record
        txSetProperty
        (word64LE wStatus <> word32LE propText <> word32LE sourceSignal <> word64LE sigStatus)
      -- When(extras): a banner label. The scope brackets the blueprint.
      <> twoU64 txCreateWhen wWhen sigExtras
      <> widget nBanner kindLabel
      <> textConst nBanner "extras on"
      <> record txTemplateEnd mempty
      -- For over groups, nesting a For over items.
      <> record txCreateCollection (word64LE cGroups)
      <> twoU64 txCreateFor wGroups cGroups
      <> widget nGroupCol kindColumn
      <> widget nGroupLbl kindLabel
      <> textElement nGroupLbl 0
      <> twoU64 txAddChild nGroupCol nGroupLbl
      <> record txCreateCollection (word64LE cItems)
      <> twoU64 txCreateFor nItemsFor cItems
      <> widget nItemRow kindColumn
      <> widget nItemText kindLabel
      <> textElement nItemText 0
      <> widget nRemove kindButton
      <> textConst nRemove "remove"
      <> twoU64 txAddChild nItemRow nItemText
      <> twoU64 txAddChild nItemRow nRemove
      <> record txTemplateEnd mempty
      <> twoU64 txAddChild nGroupCol nItemsFor
      <> record txTemplateEnd mempty
      <> twoU64 txAddChild wColumn wStep
      <> twoU64 txAddChild wColumn wStatus
      <> twoU64 txAddChild wColumn wWhen
      <> twoU64 txAddChild wColumn wGroups
      <> twoU64 txMount 0 wColumn -- window 0: the default

-- One click record: header, u64 id, u32 path_len, u32 pad, values.
parseClick :: Ptr Word8 -> Int -> IO (Word64, [String])
parseClick dat at = do
  ident <- peekByteOff dat (at + 8) :: IO Word64
  pathLen <- peekByteOff dat (at + 16) :: IO Word32
  let go p 0 acc = return (ident, reverse acc)
      go p n acc = do
        vlen <- peekByteOff dat (p + 4) :: IO Word32
        bytes <- peekArray (fromIntegral vlen) (dat `plusPtr` (p + 8)) :: IO [Word8]
        let key = map (chr . fromIntegral) bytes
            next = p + 8 + fromIntegral ((vlen + 7) .&. complement 7)
        go next (n - 1 :: Word32) (key : acc)
  go (at + 24) pathLen []

-- Record layout as declared in kaya.h: header { u32 size; u16 kind;
-- u16 flags }, payload inline, 8-byte aligned.
app :: Ptr Word8 -> Word32 -> Ptr Word32 -> Ptr Word32 -> IO ()
app dat capacity headPtr tailPtr = do
  sceneTx
  steps <- newIORef (0 :: Int)
  h0 <- loadAcquireU32 headPtr
  loop steps h0
  where
    mask = capacity - 1
    loop steps h = do
      t <- loadAcquireU32 tailPtr -- acquire: records below are visible
      if h == t
        then do
          more <- kayaWaitOccurrences
          when (more /= CBool 0) (loop steps h) -- CBool 0 is shutdown
        else do
          let at = fromIntegral (h .&. mask)
          size <- peekByteOff dat at :: IO Word32
          kind <- peekByteOff dat (at + 4) :: IO Word16
          when (kind == buttonClicked) $ do
            (ident, keys) <- parseClick dat at
            case (ident, keys) of
              (i, []) | i == wStep -> do
                modifyIORef' steps (+ 1)
                n <- readIORef steps
                let changes = case n of
                      1 ->
                        insertB cGroups [] "g1" "Work"
                          <> insertB cItems ["g1"] "a" "send report"
                          <> insertB cItems ["g1"] "b" "buy milk"
                      2 ->
                        insertB cGroups [] "g2" "Home"
                          <> insertB cItems ["g2"] "a" "water plants"
                          <> updateB cGroups [] "g1" "Office"
                      _ -> mempty
                submit $
                  changes
                    <> writeBool sigExtras (n == 1)
                    <> writeStr sigStatus ("step " ++ show n)
              (i, [group, item]) | i == nRemove ->
                submit $
                  removeB cItems [group] item
                    <> writeStr sigStatus ("removed " ++ group ++ "/" ++ item)
              _ -> return ()
          -- Word32 wraps on its own; hand the space back with release.
          let h' = h + size
          storeReleaseU32 headPtr h'
          loop steps h'

main :: IO ()
main = do
  -- KayaRingInfo, as declared in kaya.h:
  -- { u8 *data; u32 capacity; u32 *head; u32 *tail } — offsets 0/8/16/24.
  (dat, capacity, headPtr, tailPtr) <- allocaBytes 32 $ \info -> do
    kayaOccurrenceRing info
    dat <- peekByteOff info 0 :: IO (Ptr Word8)
    capacity <- peekByteOff info 8 :: IO Word32
    headPtr <- peekByteOff info 16 :: IO (Ptr Word32)
    tailPtr <- peekByteOff info 24 :: IO (Ptr Word32)
    return (dat, capacity, headPtr, tailPtr)

  -- Joined, not abandoned: after kaya_run returns, the core has
  -- signalled Shutdown, so the app loop ends and the join completes.
  done <- newEmptyMVar
  _ <- forkIO (app dat capacity headPtr tailPtr >> putMVar done ())
  code <- kayaRun -- takes over the main thread until the app exits
  takeMVar done
  if code == 0 then exitSuccess else exitWith (ExitFailure (fromIntegral code))
