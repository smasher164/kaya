-- The filedialog conformance scene, Haskell port — the picker's
-- request/result grammar and the capability it hands back.
--
-- THE FILE IS THE GUEST'S OWN, written before anything is shown: guest
-- and interpreter are the same process, so they agree on a path with no
-- runner involvement (getTemporaryDirectory honours TMPDIR).
--
-- THE READ RUNS OFF THE APP THREAD because openPicked blocks.
--
-- See guests/rust/filedialog.rs and tools/scenes/filedialog.steps.

import Control.Concurrent (forkIO, newEmptyMVar, takeMVar, tryPutMVar)
import Control.Exception (SomeException, try)
import KayaApp
import KayaWire (Value (..), fileModeRead)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.FilePath ((</>))
import System.IO (hClose, hGetContents')
import System.Posix.Process (getProcessID)

main :: IO ()
main = kayaMain $ \app -> do
  released <- newEmptyMVar

  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let dir = tmp </> ("kaya-picked-" ++ show pid)
  createDirectoryIfMissing True dir
  -- THE DECOY MUST SORT BEFORE "picked.txt", so a backend that skips
  -- selection gets the WRONG file (docs/traps.md, "Pressing Open with
  -- nothing selected still returns a file").
  writeFile (dir </> "picked.txt") "picked bytes"
  writeFile (dir </> "decoy.txt") "decoy"

  _ <- buildTx app $ do
    window 0 [WTitle "filedialog"]
    status <- signal (VStr "no file")

    let picked files = case files of
          -- The empty list IS cancel.
          [] -> buildTx app (writeSignal status (VStr "cancelled"))
          (first : _) -> do
            _ <- forkIO $ do
              -- Redeemed on the WORKER, not in the handler: the handle
              -- crosses a thread boundary and openPicked blocks.
              text <- do
                r <- try (openPicked first fileModeRead)
                case r of
                  Left e -> return ("open failed: " ++ show (e :: SomeException))
                  Right (h, _seekable) -> do
                    body <- hGetContents' h
                    hClose h
                    return body
              -- Parks holding the result, standing in for the tail of a
              -- slow transfer: on the app thread the release click could
              -- never be processed and the scene would deadlock.
              takeMVar released
              post app $
                buildTx
                  app
                  (writeSignal status (VStr (show (length files) ++ " " ++ text)))
            -- The handler RETURNED without reading.
            buildTx app (writeSignal status (VStr "reading"))

    root <-
      column
        []
        [ labelBound status [A11yId "status"], -- label#0
          -- Filters are ADVISORY on every platform, never a guarantee,
          -- so a guest still validates what it got.
          buttonOn "open" (buildTx app (pickFiles [("Text", "txt")] picked)) [], -- button#0
          buttonOn "open one" (buildTx app (pickFile [("Text", "txt")] picked)) [], -- button#1
          -- tryPutMVar, NOT putMVar: putMVar BLOCKS when the MVar is
          -- full, and a second release click would wedge the app thread.
          buttonOn "release" (() <$ tryPutMVar released ()) [] -- button#2
        ]
    mount root
  return ()
