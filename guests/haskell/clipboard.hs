{- The clipboard conformance scene from Haskell — one clip in several
   representations, and the privileged read that takes one back
   (DESIGN.md, Clipboard; docs/clipboard-plan.md).

   EVERY ASSERTION CROSSES A PROCESS BOUNDARY, which is the whole design
   of this scene. kaya's representation set is closed because the
   LOWERINGS are the hard part — CF_HTML's mandatory offset header,
   Android's content:// URI for an image, CF_HDROP's double-NUL struct —
   and a check where kaya reads what kaya wrote parses its own malformed
   header perfectly happily. That is not merely less coverage: it is a
   check that cannot fail for the reason the design exists.

   THE ONE EXCEPTION IS THE CUSTOM FORMAT, deliberately. No stock tool
   on any platform writes an app-defined type, so the guest copies one
   and reads it back, with the foreign reader confirming from outside
   that the bytes really are there under that id.

   THE IMAGE IS ASSERTED AS A DECODED SIZE, never as bytes: every host
   re-encodes freely between image types, so a byte count would be a
   different number on every lane for one picture.

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
-- through a foreign decoder, so the picture has to be a real encoded
-- image whose size is knowable from the script. Written to disk for the
-- seeding tool AND handed to copy as bytes — the same picture both ways.
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

-- The app-defined format's id: reverse-DNS and space-free, because it
-- reaches every platform's own registry VERBATIM — a UTI on Apple,
-- RegisterClipboardFormat on Windows, a target atom on X11 and Wayland,
-- a MIME type on Android.
noteId :: String
noteId = "dev.kaya/note"

-- NO QUOTES IN THE PAYLOAD, and the reason is the script rather than
-- the clipboard: the step grammar's escapes are \n, \r and \\ in all
-- three interpreters, with no quote escape — so a quoted byte could not
-- be spelled in the expectation.
noteBytes :: BS.ByteString
noteBytes = BC.pack "note=1"

main :: IO ()
main = kayaMain $ \app -> do
  -- Both halves compute this identically, the filedialog rule: guest
  -- and interpreter are the same process, so they agree on a path with
  -- no runner involvement, and the pid keeps parallel legs from
  -- colliding.
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let dir = tmp </> ("kaya-clip-" ++ show pid)
  createDirectoryIfMissing True dir
  BS.writeFile (dir </> "pixel.png") pixelPng
  writeFile (dir </> "pasted.txt") "pasted bytes"

  (status, rich, rowStatus, note) <- buildTx app $ do
    -- THE GESTURE LAYER'S DECLARATION, and an app writes nothing else
    -- for it: the Paste command lowers to the platform's own, acts on
    -- whatever is focused, and works out its own enablement. kaya has
    -- no selection API, which is exactly why copy of a selection has to
    -- be a command rather than something an app assembles out of the
    -- data layer.
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

    -- THE FIELDS ARE BUILT FIRST so the focus buttons can close over
    -- them: Build is a PURE state monad, so there is no IORef trick
    -- available inside it the way the impure bindings use one. Nothing
    -- moves in the scene — a widget's index is its creation order
    -- WITHIN ITS KIND, so these are still entry#0 and entry#1 and the
    -- buttons below are still button#0 through button#6 — and `pure`
    -- places them in the column at the position every other language
    -- puts them.
    --
    -- DECLARES WHAT IT TAKES, so a paste lands in the hook and this app
    -- decides what to do with it.
    rich <- entryOn (const (return ())) [A11yId "rich", Accepts [acceptText]]
    -- DECLARES NOTHING, so the platform's own insertion happens and the
    -- field's ordinary change path reports it — which is what a plain
    -- text editor gets for free.
    plain <- entryOn (const (return ())) [A11yId "plain"]

    -- THE SAME TWO DOORS ONE TIER DOWN, on a STAMPED copy. The accept
    -- list is declared on the TEMPLATE, and that declaration is what
    -- turns the node hook on: every backend hands the gesture to the
    -- platform when the focused widget's accept list is empty, so until
    -- a template could carry one, 'onPasteNode' registered a handler
    -- that was dispatched to and could never fire — in seven bindings,
    -- silently (docs/tpl-props-plan.md §1). This is the leg that fires
    -- it.
    --
    -- The For keeps its result, the milestone2 rule: a central
    -- registration needs a handle to name, so 'forEach' hands the
    -- body's node back and 'each' — which drops it — is the wrong
    -- combinator here.
    --
    -- The row's value is empty and nothing displays it. The stamped
    -- entry is uncontrolled like its live siblings ('entry', not
    -- 'entryBound'), and staying empty through the paste is the
    -- assertion: kaya delivered the content to the hook INSTEAD of
    -- letting the platform insert it.
    notes <- collection
    (noteList, note) <-
      forEach notes $
        withTplAttrs [TplAccepts [acceptText]] entry

    let readWith kinds = buildTx app (readClipboard kinds (reader app status))

    root <-
      column
        []
        [ labelBound status [A11yId "status"], -- label#0
          -- ONE CLIP, FOUR REPRESENTATIONS. kaya derives none of them
          -- from any other: whether list bullets survive html-to-text
          -- is this app's decision, so it spells out both. The order
          -- they go on the wire is kaya's, not this record's —
          -- descending richness, which is preference order on every
          -- host that has one.
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
    -- The one row, stamped after every live widget is created — so its
    -- copy of the template entry is entry#2, wherever the For's own
    -- column landed in the registry.
    insert notes (VStr "r1") (VStr "")
    return (status, rich, rowStatus, note)

  -- Registered in IO after the build, the way onChange is: the handler
  -- is not part of the scene's records.
  onPaste app rich $ \clip -> case clip of
    -- THE SAME SHAPE THE READ ANSWERS WITH, and free where the read is
    -- not: a gesture is its own authorisation, so no platform charges a
    -- prompt for this one.
    RText text -> buildTx app (writeSignal status (VStr ("pasted " ++ text)))
    _ -> buildTx app (writeSignal status (VStr "pasted other"))

  -- The stamped copy's paste, registered the same way against the node
  -- the template handed out. ONE record kind, the key path deciding:
  -- the copy's own key arrives WITH the payload, and printing it is
  -- what tells an instance occurrence from a live one.
  onPasteNode app note $ \keys clip ->
    let key = case keys of
          VStr k : _ -> k
          other -> show other
     in case clip of
          RText text ->
            buildTx app (writeSignal rowStatus (VStr ("row " ++ key ++ " pasted " ++ text)))
          _ -> buildTx app (writeSignal rowStatus (VStr ("row " ++ key ++ " pasted other")))

-- The privileged read's one answer. A pasted FILE goes all the way to
-- its bytes, off the app thread, because openPicked blocks — and a
-- pasted file is no different from a picked one: it IS a picked one,
-- the same capability arriving through a second door.
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
    -- STRAIGHT BACK OUT, because the assertion that matters is a
    -- foreign DECODER's: the byte count differs per host for one
    -- picture, and the decoded size does not.
    buildTx app $ do
      copy emptyClip {clipImage = Just bytes}
      writeSignal status (VStr "image")
