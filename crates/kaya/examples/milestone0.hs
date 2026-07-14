{- Milestone 1 from Haskell through the direct ring tier: Haskell reads
   the occurrence ring with its own loads, and answers with packed
   transaction records through kaya_submit. The scene arrives as one
   transaction; the label's text is a signal binding this guest writes
   on every click. The C boundary is crossed only to start the core, to
   wait on an empty ring, and to submit.

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
  )
import qualified Data.ByteString.Lazy as BL
import Data.ByteString.Unsafe (unsafeUseAsCStringLen)
import Data.Int (Int32)
import Data.Word (Word16, Word32, Word64, Word8)
import Foreign.C.Types (CBool (..), CSize (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
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
txCreateSignal = 1
txWriteSignal = 2
txCreateWidget = 3
txSetProperty = 4
txAddChild = 5
txMount = 6

kindColumn, kindButton, kindLabel :: Word32
kindColumn = 1
kindButton = 2
kindLabel = 3

propText, sourceConst, sourceSignal, valueStr :: Word32
propText = 1
sourceConst = 0
sourceSignal = 1
valueStr = 4

-- Guest-allocated ids, counted from 1 per space.
sigText, wColumn, wButton, wLabel :: Word64
sigText = 1
wColumn = 1
wButton = 2
wLabel = 3

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

strValue :: String -> Builder
strValue text =
  let utf8 = BL.toStrict (toLazyByteString (stringUtf8 text))
   in word32LE valueStr
        <> word32LE (fromIntegral (BS.length utf8))
        <> byteString utf8

submit :: Builder -> IO ()
submit tx =
  unsafeUseAsCStringLen (BL.toStrict (toLazyByteString tx)) $ \(p, len) ->
    kayaSubmit (castPtr p) (fromIntegral len)

sceneTx :: IO ()
sceneTx =
  submit $
    record txCreateSignal (word64LE sigText <> strValue "Clicked 0 times")
      <> record txCreateWidget (word64LE wColumn <> word32LE kindColumn <> word32LE 0)
      <> record txCreateWidget (word64LE wButton <> word32LE kindButton <> word32LE 0)
      <> record
        txSetProperty
        (word64LE wButton <> word32LE propText <> word32LE sourceConst <> strValue "Click me")
      <> record txCreateWidget (word64LE wLabel <> word32LE kindLabel <> word32LE 0)
      <> record
        txSetProperty
        (word64LE wLabel <> word32LE propText <> word32LE sourceSignal <> word64LE sigText)
      <> record txAddChild (word64LE wColumn <> word64LE wButton)
      <> record txAddChild (word64LE wColumn <> word64LE wLabel)
      <> record txMount (word64LE 0 <> word64LE wColumn) -- window 0: the default

writeTx :: String -> IO ()
writeTx text = submit (record txWriteSignal (word64LE sigText <> strValue text))

-- Record layout as declared in kaya.h: header { u32 size; u16 kind;
-- u16 flags }, payload inline, 8-byte aligned.
app :: Ptr Word8 -> Word32 -> Ptr Word32 -> Ptr Word32 -> IO ()
app dat capacity headPtr tailPtr = do
  sceneTx
  h0 <- loadAcquireU32 headPtr
  loop h0 (0 :: Int)
  where
    mask = capacity - 1
    loop h count = do
      t <- loadAcquireU32 tailPtr -- acquire: records below are visible
      if h == t
        then do
          more <- kayaWaitOccurrences
          when (more /= CBool 0) (loop h count) -- CBool 0 is shutdown
        else do
          let at = fromIntegral (h .&. mask)
          size <- peekByteOff dat at :: IO Word32
          kind <- peekByteOff dat (at + 4) :: IO Word16
          count' <-
            if kind == buttonClicked
              then do
                let n = count + 1
                    noun = if n == 1 then "time" else "times"
                writeTx ("Clicked " ++ show n ++ " " ++ noun)
                return n
              else return count
          -- Word32 wraps on its own; hand the space back with release.
          let h' = h + size
          storeReleaseU32 headPtr h'
          loop h' count'

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
