{- Milestone 0 from Haskell through the direct ring tier: Haskell reads
   the occurrence ring with its own loads, crossing the C boundary only
   to start the core, to wait on an empty ring, and to send commands.

   The data path is plain peeks on the ring's memory — GHC inlines them
   to real loads, so no call and no boxing survives a tight loop — with
   ordering carried by two C stubs (milestone0_hs_stubs.c) imported
   `ccall unsafe`, the same cursor recipe as the OCaml example; the
   stubs' header explains why GHC's own Addr# atomics are the wrong
   shape for these two accesses.
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
import Data.Bits ((.&.))
import Data.Int (Int32)
import Data.Word (Word16, Word32, Word64, Word8)
import Foreign.C.String (withCStringLen)
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

foreign import ccall unsafe "kaya_set_text"
  kayaSetText :: Word64 -> Ptr Word8 -> CSize -> IO ()

-- The ordered cursor accesses; see milestone0_hs_stubs.c.
foreign import ccall unsafe "kaya_hs_load_acquire_u32"
  loadAcquireU32 :: Ptr Word32 -> IO Word32

foreign import ccall unsafe "kaya_hs_store_release_u32"
  storeReleaseU32 :: Ptr Word32 -> Word32 -> IO ()

buttonClicked :: Word16
buttonClicked = 1 -- KAYA_OCCURRENCE_BUTTON_CLICKED

label :: Word64
label = 2 -- KAYA_WIDGET_LABEL

setText :: Word64 -> String -> IO ()
setText widget text =
  withCStringLen text $ \(p, len) ->
    kayaSetText widget (castPtr p) (fromIntegral len)

-- Record layout as declared in kaya.h: header { u32 size; u16 kind;
-- u16 flags }, payload inline, 8-byte aligned.
app :: Ptr Word8 -> Word32 -> Ptr Word32 -> Ptr Word32 -> IO ()
app dat capacity headPtr tailPtr = do
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
                setText label ("Clicked " ++ show n ++ " " ++ noun)
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
