{- The clipboard conformance scene from Haskell — one clip in several
   representations, and the privileged read that takes one back.

   Canonical semantics in guests/rust/clipboard.rs; the byte-frozen
   contract in tools/scenes/clipboard.steps. -}

import Control.Concurrent (forkIO)
import Control.Exception (SomeException, try)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import KayaApp
import KayaWire (Value (..), fileModeRead)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.FilePath ((</>))
import System.IO (hClose, hGetContents')
import System.Posix.Process (getProcessID)

-- A 4x4 PNG, spelled out rather than generated: the scene asserts "4x4"
-- through a foreign decoder, so it has to be a real encoded image whose
-- size is knowable from the script.
pixelPng :: BS.ByteString
pixelPng =
  BS.pack
    [ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, -- signature
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, -- IHDR length + type
      0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, -- 4 x 4
      0x08, 0x02, 0x00, 0x00, 0x00, 0x26, 0x93, 0x09, -- 8-bit rgb + crc
      0x29, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41, -- IDAT length + type
      0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
      0x47, 0x48, 0x4C, 0x74, 0xDE, 0x7F, 0x24, 0x00,
      0x00, 0xD2, 0x6F, 0x17, 0xE9, 0x51, 0xBB, 0x23,
      0x2D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
      0x44, 0xAE, 0x42, 0x60, 0x82 -- IEND + crc
    ]

-- Reverse-DNS and space-free: the id reaches every platform's own
-- registry VERBATIM (a UTI, RegisterClipboardFormat, an X11 atom, a
-- MIME type).
noteId :: String
noteId = "dev.kaya/note"

-- NO QUOTES IN THE PAYLOAD: the step grammar escapes \n, \r and \\ and
-- nothing else, so a quoted byte cannot be spelled in the expectation.
noteBytes :: BS.ByteString
noteBytes = BC.pack "note=1"

main :: IO ()
main = kayaMain $ \app -> do
  -- Guest and interpreter are the same process and compute this path
  -- identically, with no runner involvement; the pid keeps parallel legs
  -- from colliding.
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let dir = tmp </> ("kaya-clip-" ++ show pid)
  createDirectoryIfMissing True dir
  BS.writeFile (dir </> "pixel.png") pixelPng
  writeFile (dir </> "pasted.txt") "pasted bytes"

  (status, rich, rowStatus, note) <- buildTx app $ do
    window
      0
      [ WTitle "clipboard",
        WMenus
          [ menu
              "Edit"
              []
              [ item "Cut" [IRole roleCut],
                item "Copy" [IRole roleCopy],
                item "Paste" [IRole rolePaste]
              ]
          ]
      ]
    status <- signal (VStr "ready")
    rowStatus <- signal (VStr "")

    -- Built before the focus buttons that close over them: Build is a
    -- PURE state monad, so nothing can reach back for them later, and
    -- `pure` places them in the column where every language puts them.
    --
    -- An accept list is what turns the paste hook on; a field that
    -- declares none gets the platform's own insertion instead.
    rich <- entryOn (const (return ())) [A11yId "rich", Accepts [acceptText]]
    plain <- entryOn (const (return ())) [A11yId "plain"]

    -- The same door one tier down: the accept list is declared on the
    -- TEMPLATE, and that declaration is what turns the node hook on
    -- (docs/tpl-props-plan.md §1). 'forEach' rather than 'each' because
    -- the central registration below needs the node it hands back.
    notes <- collection
    (noteList, note) <-
      forEach notes $
        withTplAttrs [TplAccepts [acceptText]] entry

    let readWith kinds = buildTx app (readClipboard kinds (reader app status))

    root <-
      column
        []
        [ labelBound status [A11yId "status"], -- label#0
          -- One clip, four representations; kaya derives none of them
          -- from any other, so the app spells out each.
          buttonOn
            "copy"
            ( buildTx app $ do
                copy
                  emptyClip
                    { clipText = Just "kaya clip",
                      clipHtml = Just "<b>kaya</b> clip",
                      clipImage = Just pixelPng,
                      clipCustom = [(noteId, noteBytes)]
                    }
                writeSignal status (VStr "copied")
            )
            [], -- button#0
          buttonOn "read custom" (readWith [noteId]) [], -- button#1
          buttonOn "read text" (readWith [acceptText]) [], -- button#2
          buttonOn "read image" (readWith [acceptImage]) [], -- button#3
          buttonOn "read files" (readWith [acceptFiles]) [], -- button#4
          buttonOn "focus rich" (buildTx app (focusWidget rich)) [], -- button#5
          buttonOn "focus plain" (buildTx app (focusWidget plain)) [], -- button#6
          pure rich, -- entry#0
          pure plain, -- entry#1
          labelBound rowStatus [A11yId "row-status"], -- label#1
          pure noteList
        ]
    mount root
    -- Stamped after every live widget is created, so the copy of the
    -- template entry is entry#2.
    insert notes (VStr "r1") (VStr "")
    return (status, rich, rowStatus, note)

  -- Registered in IO after the build, the way onChange is.
  onPaste app rich $ \clip -> case clip of
    RText text -> buildTx app (writeSignal status (VStr ("pasted " ++ text)))
    _ -> buildTx app (writeSignal status (VStr "pasted other"))

  -- The stamped copy's paste, against the node the template handed out;
  -- the copy's own key arrives with the payload.
  onPasteNode app note $ \keys clip ->
    let key = case keys of
          VStr k : _ -> k
          other -> show other
     in case clip of
          RText text ->
            buildTx app (writeSignal rowStatus (VStr ("row " ++ key ++ " pasted " ++ text)))
          _ -> buildTx app (writeSignal rowStatus (VStr ("row " ++ key ++ " pasted other")))

-- The privileged read's one answer. A pasted FILE is read OFF THE APP
-- THREAD, because openPicked blocks.
reader :: App -> Signal -> Maybe Representation -> IO ()
reader app status clip = case clip of
  Just (RFiles (first : _)) -> do
    _ <- forkIO $ do
      text <- do
        r <- try (openPicked first fileModeRead)
        case r of
          Left e -> return ("open failed: " ++ show (e :: SomeException))
          Right (h, _seekable) -> do
            body <- hGetContents' h
            hClose h
            return body
      post app $
        buildTx
          app
          (writeSignal status (VStr ("files " ++ pickedName first ++ " " ++ text)))
    buildTx app (writeSignal status (VStr "reading"))
  Just (RFiles []) -> buildTx app (writeSignal status (VStr "files none"))
  Nothing -> buildTx app (writeSignal status (VStr "empty"))
  Just (RText text) -> buildTx app (writeSignal status (VStr ("text " ++ text)))
  Just (RHtml html) -> buildTx app (writeSignal status (VStr ("html " ++ html)))
  Just (RCustom i body) ->
    buildTx app (writeSignal status (VStr ("custom " ++ i ++ " " ++ BC.unpack body)))
  Just (RImage bytes) ->
    -- Straight back out: the image is asserted as a foreign decoder's
    -- SIZE, never as bytes, since every host re-encodes freely.
    buildTx app $ do
      copy emptyClip {clipImage = Just bytes}
      writeSignal status (VStr "image")
