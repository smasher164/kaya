{-# LANGUAGE OverloadedStrings #-}

-- The filedialog scene, Haskell port — guests/rust/filedialog.rs,
-- tools/scenes/filedialog.steps.

import Control.Concurrent (forkIO, newEmptyMVar, takeMVar, tryPutMVar)
import Control.Exception (SomeException, try)
import Data.Text (Text)
import qualified Data.Text as T
import KayaApp
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
  -- THE DECOY MUST SORT BEFORE "picked.txt" (docs/traps.md, "Pressing Open
  -- with nothing selected still returns a file").
  writeFile (dir </> "picked.txt") "picked bytes"
  writeFile (dir </> "decoy.txt") "decoy"

  _ <- buildTx app $ do
    window primary [WTitle "filedialog"]
    status <- signal (T.pack "no file")

    let picked files = case files of
          -- The empty list IS cancel.
          [] -> buildTx app (writeSignal status (T.pack "cancelled"))
          (first : _) -> do
            _ <- forkIO $ do
              -- Redeemed on the WORKER: openPicked blocks.
              text <- do
                r <- try (openPicked first FileModeRead)
                case r of
                  Left e -> return ("open failed: " ++ show (e :: SomeException))
                  Right (h, _seekable) -> do
                    body <- hGetContents' h
                    hClose h
                    return body
              -- Parks holding the result, standing in for a slow transfer.
              takeMVar released
              post app $
                buildTx
                  app
                  (writeSignal status (T.pack (show (length files) ++ " " ++ text)))
            buildTx app (writeSignal status (T.pack "reading"))

    root <-
      column
        []
        [ labelBound status [A11yId ("status" :: Text)], -- label#0
          buttonOn "open" (buildTx app (pickFiles [("Text", "txt")] picked)) [], -- button#0
          buttonOn "open one" (buildTx app (pickFile [("Text", "txt")] picked)) [], -- button#1
          -- tryPutMVar, NOT putMVar: a second release click would wedge the
          -- app thread.
          buttonOn "release" (() <$ tryPutMVar released ()) [] -- button#2
        ]
    mount root
  return ()
