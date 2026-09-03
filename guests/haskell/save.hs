-- The save scene, Haskell port — guests/rust/save.rs, tools/scenes/save.steps.

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
-- 'fileModeWrite' truncates; a destination only adds the create.
writeBack :: PickedFile -> String -> IO String
writeBack file text = do
  opened <- try (openPicked file fileModeWrite)
  case opened of
    Left e -> return ("save failed: " ++ show (e :: SomeException))
    Right (h, _seekable) -> do
      wrote <- try (hPutStr h text)
      -- Closed before the reopen, so the bytes are the FILE's.
      hClose h
      case wrote of
        Left e -> return ("write failed: " ++ show (e :: SomeException))
        Right () -> readBack file

-- | The handle a step holds, or Nothing when the dialog never answered. The
-- caller writes its OWN sentence — never an error, which masks the real
-- failure (docs/deferred.md, save-jvm WATCH).
held :: IORef (Maybe PickedFile) -> IO (Maybe PickedFile)
held = readIORef

main :: IO ()
main = kayaMain $ \app -> do
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let dir = tmp </> ("kaya-save-" ++ show pid)
  createDirectoryIfMissing True dir
  -- The decoy must SORT BEFORE the real file (docs/traps.md, "Pressing Open
  -- with nothing selected still returns a file").
  writeFile (dir </> "draft") "first draft"
  writeFile (dir </> "decoy") "decoy"

  -- Handles, never paths — the phones have no re-openable path. IORefs
  -- without locking: everything that touches them runs on the app thread.
  sourceRef <- newIORef Nothing
  destRef <- newIORef Nothing

  _ <- buildTx app $ do
    window 0 [WTitle "save"]
    status <- signal (VStr "no file")

    -- Off the app thread, because openPicked blocks.
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
          -- NO FILTERS: with allowedContentTypes set a save panel appends the
          -- first allowed extension to an extension-less name.
          buttonOn "open" (buildTx app (pickFile [] picked)) [], -- button#0
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
