-- The save conformance scene, Haskell port — the ROUND TRIP an editor
-- actually walks (docs/save-plan.md D5): open, edit, save, save-as,
-- reopen.
--
-- WHAT THIS PROVES, and why none of it is about a dialog closing:
--
-- 1. Save-BACK works. Writing through the handle the OPEN picker handed
--    over — the thing DESIGN.md has claimed since the picker landed and
--    that no scene, leg or test has ever driven.
-- 2. A save destination is OPENABLE AT ALL. The desktops answer a save
--    dialog with a name for a file nobody has made, so opening it would
--    fail with "No such file or directory"; the core's save source
--    creates, and this is where that shows.
-- 3. The two files stay DIFFERENT. The last step reopens both handles
--    and reports both contents, so a save-as that quietly wrote back
--    into the original — the plausible bug, since the guest is holding
--    two handles that look alike — fails here and nowhere else.
-- 4. Cancel is nothing, and the dialog id RETIRES. The scene shows a
--    save dialog, cancels it, and shows another; a cancel that leaked
--    the live slot would abort on the second show.
--
-- EVERY STATUS IS A READ-BACK OFF THE DISK, never what the guest hoped
-- it wrote: write, close, reopen through the handle kaya gave us, read
-- with an ORDINARY GHC Handle. A write that returned successfully and
-- landed nowhere is exactly the failure "save" has, and only reopening
-- can see it. The reopen goes through 'openPicked' and never through
-- 'pickedLocalPath', which is empty on both phones.
--
-- THE WORK RUNS OFF THE APP THREAD, which is what 'openPicked' tells
-- every caller to do: it blocks, and a cloud provider may download the
-- whole file first. The worker is a plain forkIO and the answer comes
-- back through 'post', as background.hs's does — kaya supplies no
-- concurrency primitive and should not. The PARKING dance that proves
-- the thread hop belongs to filedialog.hs; this scene owns the round
-- trip.
--
-- NO EXTENSIONS ON THE NAMES, deliberately. A save panel publishes its
-- name field with the extension hidden when the user's preference says
-- so, which would make `expect_save_dialog` read the stem on one machine
-- and the whole name on another. A name with no extension has no stem to
-- differ from, on any platform.
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

-- | Read a handle back through kaya, with GHC's own IO. THE READ-BACK IS
-- THE ASSERTION in every step of this scene.
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
    -- THE FAILURE D1 EXISTS TO PREVENT reaches the label verbatim:
    -- without the create, a save destination answers "No such file or
    -- directory" right here.
    Left e -> return ("save failed: " ++ show (e :: SomeException))
    Right (h, _seekable) -> do
      wrote <- try (hPutStr h text)
      -- Closed before the reopen, so what comes back is the FILE's bytes
      -- and not a buffer's.
      hClose h
      case wrote of
        Left e -> return ("write failed: " ++ show (e :: SomeException))
        Right () -> readBack file

-- | The handle a step needs and the scene guarantees. Reaching this
-- means the script ran out of order, which is a broken scene rather than
-- a state an app should branch on — the Rust guest's `expect` verbatim.
required :: String -> IORef (Maybe PickedFile) -> IO PickedFile
required what ref = do
  held <- readIORef ref
  case held of
    Just file -> return file
    Nothing -> error ("the save scene " ++ what)

main :: IO ()
main = kayaMain $ \app -> do
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let dir = tmp </> ("kaya-save-" ++ show pid)
  createDirectoryIfMissing True dir
  -- The file the scene opens, written before anything is shown, plus the
  -- decoy the picker needs: with ONE file in the directory a dialog
  -- completes with it when nothing is selected, so `file_choose` would
  -- pass on a backend that never selected anything. "decoy" sorts first,
  -- so that backend gets the WRONG file and its five bytes fail the byte
  -- assertion too.
  writeFile (dir </> "draft") "first draft"
  writeFile (dir </> "decoy") "decoy"

  -- The two capabilities the scene carries: the file the user OPENED and
  -- the destination the user later NAMED. Held as handles, never as
  -- paths — the phones have no re-openable path at all. IORefs suffice
  -- without locking: everything that touches them runs on the app
  -- thread.
  sourceRef <- newIORef Nothing
  destRef <- newIORef Nothing

  _ <- buildTx app $ do
    window 0 [WTitle "save"]
    status <- signal (VStr "no file")

    -- Every file operation runs on a thread of the guest's own, because
    -- openPicked blocks; the answer comes back through the poster.
    let work job = do
          _ <- forkIO $ do
            text <- job
            post app (buildTx app (writeSignal status (VStr text)))
          return ()

        picked files = case files of
          -- The empty list IS cancel: nothing was chosen, so nothing is
          -- read and no source is remembered.
          [] -> buildTx app (writeSignal status (VStr "open cancelled"))
          (first : _) -> do
            writeIORef sourceRef (Just first)
            work (("opened " ++) <$> readBack first)

        -- CANCEL IS Nothing, narrowed by the binding rather than by a
        -- length here. Nothing was named, so nothing is written and no
        -- destination is remembered.
        saved Nothing = buildTx app (writeSignal status (VStr "save cancelled"))
        saved (Just file) = do
          writeIORef destRef (Just file)
          work (("saved " ++) <$> writeBack file "third draft")

    root <-
      column
        []
        [ labelBound status [A11yId "status"], -- label#0
          -- NO FILTERS ON EITHER REQUEST. With allowedContentTypes set, a
          -- save panel appends the first allowed extension to an
          -- extension-less name, and the names here carry none.
          buttonOn "open" (buildTx app (pickFile [] picked)) [], -- button#0
          -- SAVE-BACK NEEDS NO DIALOG. The user already chose this file,
          -- and the handle they chose it with is writable — the claim
          -- this button exists to drive.
          buttonOn -- button#1
            "save"
            ( do
                file <- required "opens a file before saving" sourceRef
                work (("saved " ++) <$> writeBack file "second draft")
            )
            [],
          -- "copy" is the name the dialog OPENS with; the harness types
          -- over it, which is what a save dialog is for.
          buttonOn "save as" (buildTx app (saveFile "copy" [] saved)) [], -- button#2
          -- BOTH, in order: the file that was opened must still hold the
          -- save-back, and the destination must hold the save-as. A save
          -- that went to the wrong handle passes every earlier step and
          -- fails here.
          buttonOn -- button#3
            "reopen"
            ( do
                first <- required "opens a file" sourceRef
                second <- required "saves as" destRef
                work $ do
                  one <- readBack first
                  two <- readBack second
                  return ("reopened " ++ one ++ " " ++ two)
            )
            []
        ]
    mount root
  return ()
