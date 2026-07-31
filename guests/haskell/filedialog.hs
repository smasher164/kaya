-- The filedialog conformance scene, Haskell port — the picker's
-- request/result grammar and the capability it hands back (DESIGN.md,
-- File dialogs).
--
-- WHAT THIS PROVES, and why it goes all the way to the bytes: the
-- design's whole claim is that kaya hands over a CAPABILITY and never
-- moves the data. So the guest does not assert that a dialog closed —
-- it opens the handle it was given, reads the file with an ORDINARY
-- Handle, and writes what it read into a signal.
--
-- THE FILE IS THE GUEST'S OWN, written before anything is shown, so
-- guest and interpreter agree on a path with no runner involvement —
-- they are the same process. getTemporaryDirectory honours TMPDIR,
-- which is what makes both halves land on the same place without
-- either consulting the other.
--
-- THE READ RUNS OFF THE APP THREAD, which is what openPicked tells
-- every caller to do: it blocks, and a cloud provider may download the
-- whole file before it returns. The parking is a plain empty MVar and
-- the worker a plain forkIO, as background.hs's is — kaya supplies no
-- waiting primitive and should not.
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
  -- THE DECOY IS LOAD-BEARING: with one file in the directory,
  -- pressing Open with nothing selected returns that file, so
  -- `file_choose picked.txt` would pass on a backend that ignored the
  -- name entirely. Measured on GTK. "decoy" sorts before "picked", so
  -- a backend that skips selection gets the WRONG file, and its five
  -- bytes fail the byte assertion as well as the name.
  writeFile (dir </> "picked.txt") "picked bytes"
  writeFile (dir </> "decoy.txt") "decoy"

  _ <- buildTx app $ do
    window 0 [WTitle "filedialog"]
    status <- signal (VStr "no file")

    let picked files = case files of
          -- The empty list IS cancel. Nothing to read, so no worker
          -- and no release.
          [] -> buildTx app (writeSignal status (VStr "cancelled"))
          (first : _) -> do
            _ <- forkIO $ do
              -- THE CLAIM, and it is made HERE rather than in the
              -- handler on purpose: the handle crossed a thread
              -- boundary, and it is redeemed and read with GHC's own
              -- IO on the thread that received it. kaya is not in this
              -- data path, and openPicked is documented to block.
              text <- do
                r <- try (openPicked first fileModeRead)
                case r of
                  Left e -> return ("open failed: " ++ show (e :: SomeException))
                  Right (h, _seekable) -> do
                    body <- hGetContents' h
                    hClose h
                    return body
              -- Parks holding the result, standing in for the tail of
              -- a slow transfer. Were this work running on the app
              -- thread, the release click could never be processed and
              -- the whole scene would deadlock — the point.
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
          -- ADVISORY filters on every platform: a default view, never
          -- a guarantee, so a guest still validates what it got.
          buttonOn "open" (buildTx app (pickFiles [("Text", "txt")] picked)) [], -- button#0
          buttonOn "open one" (buildTx app (pickFile [("Text", "txt")] picked)) [], -- button#1
          -- tryPutMVar, NOT putMVar: putMVar BLOCKS when the MVar is
          -- full, and a second release click would then wedge the app
          -- thread (background.hs makes the same point).
          buttonOn "release" (() <$ tryPutMVar released ()) [] -- button#2
        ]
    mount root
  return ()
