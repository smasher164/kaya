-- The save conformance scene, Haskell port — the round trip an editor
-- actually walks: open, edit, save, save-as, reopen.
--
-- EVERY STATUS IS A READ-BACK OFF THE DISK, always through 'openPicked'
-- and never through 'pickedLocalPath', which is empty on both phones.
--
-- THE WORK RUNS OFF THE APP THREAD because 'openPicked' blocks.
--
-- NO EXTENSIONS ON THE NAMES: a save panel hides the extension when the
-- user's Finder preference says so (the NSSavePanel entry in
-- docs/deferred.md).
--
-- Canonical semantics in guests/rust/save.rs; the byte-frozen contract
-- in tools/scenes/save.steps.

import Control.Concurrent (forkIO)
import Control.Exception (SomeException, try)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import KayaApp
import KayaWire (Value (..), fileModeRead, fileModeWrite)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.FilePath ((</>))
import System.IO (hClose, hGetContents', hPutStr)
import System.Posix.Process (getProcessID)

-- | Read a handle back through kaya, with GHC's own IO.
readBack :: PickedFile -> IO String
readBack file = do
  opened <- try (openPicked file fileModeRead)
  case opened of
    Left e -> return ("open failed: " ++ show (e :: SomeException))
    Right (h, _seekable) -> do
      body <- try (hGetContents' h)
      hClose h
      case body of
        Left e -> return ("read failed: " ++ show (e :: SomeException))
        Right text -> return text

-- | Write through a handle and report what the FILE says afterwards.
-- 'fileModeWrite' truncates, on a picked file and on a save destination
-- alike — the destination only adds the create.
writeBack :: PickedFile -> String -> IO String
writeBack file text = do
  opened <- try (openPicked file fileModeWrite)
  case opened of
    Left e -> return ("save failed: " ++ show (e :: SomeException))
    Right (h, _seekable) -> do
      wrote <- try (hPutStr h text)
      -- Closed before the reopen, so what comes back is the FILE's bytes
      -- and not a buffer's.
      hClose h
      case wrote of
        Left e -> return ("write failed: " ++ show (e :: SomeException))
        Right () -> readBack file

-- | The handle a step holds, or Nothing when the dialog that should
-- have filled it never answered (cancelled, or swallowed under load).
-- The caller writes its OWN sentence for that — never an error: a
-- crashed guest masks the real failure (docs/deferred.md, save-jvm
-- WATCH).
held :: IORef (Maybe PickedFile) -> IO (Maybe PickedFile)
held = readIORef

main :: IO ()
main = kayaMain $ \app -> do
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let dir = tmp </> ("kaya-save-" ++ show pid)
  createDirectoryIfMissing True dir
  -- The decoy must SORT BEFORE the real file: with one file in the
  -- directory a dialog completes with it even when nothing was selected
  -- (docs/traps.md, "Pressing Open with nothing selected still returns a
  -- file").
  writeFile (dir </> "draft") "first draft"
  writeFile (dir </> "decoy") "decoy"

  -- The file the user OPENED and the destination they later NAMED, held
  -- as handles and never as paths — the phones have no re-openable path
  -- at all. IORefs without locking: everything that touches them runs on
  -- the app thread.
  sourceRef <- newIORef Nothing
  destRef <- newIORef Nothing

  _ <- buildTx app $ do
    window 0 [WTitle "save"]
    status <- signal (VStr "no file")

    -- Off the app thread, because openPicked blocks; the answer comes
    -- back through the poster.
    let work job = do
          _ <- forkIO $ do
            text <- job
            post app (buildTx app (writeSignal status (VStr text)))
          return ()

        picked files = case files of
          [] -> buildTx app (writeSignal status (VStr "open cancelled"))
          (first : _) -> do
            writeIORef sourceRef (Just first)
            work (("opened " ++) <$> readBack first)

        saved Nothing = buildTx app (writeSignal status (VStr "save cancelled"))
        saved (Just file) = do
          writeIORef destRef (Just file)
          work (("saved " ++) <$> writeBack file "third draft")

    root <-
      column
        []
        [ labelBound status [A11yId "status"], -- label#0
          -- NO FILTERS ON EITHER REQUEST: with allowedContentTypes set a
          -- save panel appends the first allowed extension to an
          -- extension-less name, and the names here carry none.
          buttonOn "open" (buildTx app (pickFile [] picked)) [], -- button#0
          -- Save-back needs no dialog: the handle the open picker handed
          -- over is writable.
          buttonOn -- button#1
            "save"
            ( do
                file <- held sourceRef
                case file of
                  Nothing -> buildTx app (writeSignal status (VStr "nothing open to save"))
                  Just f -> work (("saved " ++) <$> writeBack f "second draft")
            )
            [],
          buttonOn "save as" (buildTx app (saveFile "copy" [] saved)) [], -- button#2
          buttonOn -- button#3
            "reopen"
            ( do
                first <- held sourceRef
                second <- held destRef
                case (first, second) of
                  (Just one', Just two') -> work $ do
                    one <- readBack one'
                    two <- readBack two'
                    return ("reopened " ++ one ++ " " ++ two)
                  _ -> buildTx app (writeSignal status (VStr "nothing to reopen"))
            )
            []
        ]
    mount root
  return ()
