{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

-- The drag-and-drop scene, Haskell port — guests/rust/dnd.rs,
-- tools/scenes/dnd.steps. THE ROOT IS A ROW so column#0 is the
-- reorderable For's container.

import qualified Data.ByteString.Char8 as BS
import Data.List (intercalate)
import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)
import Control.Exception (SomeException, try)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.FilePath ((</>))
import System.IO (hClose, hGetContents')
import System.Posix.Process (getProcessID)

import KayaApp
import KayaWire (Value (..), fileModeRead)

data Item = Item {title :: String} deriving (Generic)

instance KayaRecord Item

noteFormat :: String
noteFormat = "dev.kaya/note"

word :: Maybe Op -> String
word (Just OpCopy) = "copy"
word (Just OpMove) = "move"
word Nothing = "none"

keyWord :: [Value] -> String
keyWord (VStr s : _) = s
keyWord _ = ""

-- The file the scene drops as a FOREIGN source (D6), written by the guest
-- at $TMP/kaya-dnd-$PID/dropped.txt — the picker and clipboard scenes'
-- convention.
writeDroppedFile :: IO ()
writeDroppedFile = do
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let dir = tmp </> ("kaya-dnd-" ++ show pid)
  createDirectoryIfMissing True dir
  writeFile (dir </> "dropped.txt") "dropped bytes"

readBack :: PickedFile -> IO String
readBack f = do
  r <- try (openPicked f fileModeRead)
  case r of
    Left e -> return ("open failed: " ++ show (e :: SomeException))
    Right (h, _seekable) -> do
      body <- hGetContents' h
      hClose h
      return body

main :: IO ()
main = kayaMain $ \app -> do
  writeDroppedFile
  (items, items2, list, source, textPair, notePair, filesPair, rowNode, itemNode, dropStatus, dragStatus, sourceText) <-
    buildTx app $ do
      window 0 [WTitle "dnd"]
      items <- collectionOf (Proxy :: Proxy Item)
      items2 <- collectionOf (Proxy :: Proxy Item)
      dropStatus <- signal (VStr "no drop yet")
      dragStatus <- signal (VStr "no drag yet")
      sourceText <- signal (VStr "hello")
      textTarget <- signal (VStr "text target")
      noteTarget <- signal (VStr "note target")
      filesTarget <- signal (VStr "files target")

      (list, rowNode) <-
        forEach (recordHandle items) $
          withTplAttrs [TplA11yId "row"] (label (field @"title" @Item))
      setA11yId list "rows"
      source <- labelBound sourceText []
      textWidget <-
        labelBound textTarget [Accepts [acceptText], DropTarget [OpCopy]]
      noteWidget <-
        labelBound noteTarget [Accepts [noteFormat], DropTarget [OpCopy, OpMove]]
      filesWidget <-
        labelBound filesTarget [Accepts [acceptFiles], DropTarget [OpCopy]]
      dropLabel <- labelBound dropStatus []
      dragLabel <- labelBound dragStatus []
      -- THE TEMPLATE ZONE (docs/dnd-plan.md §4): every stamped item is a
      -- text destination, and its payload IS the row's own field —
      -- resolved per copy, re-declared when the field changes — column#2.
      (itemList, itemNode) <-
        forEach (recordHandle items2) $
          withTplAttrs
            [ TplA11yId "item",
              TplAccepts [acceptText],
              TplDropTarget [OpCopy],
              TplDraggable
                emptyTplClip {tplClipText = Just (TplField (field @"title" @Item))}
                [OpCopy]
            ]
            (label (field @"title" @Item))
      setA11yId itemList "items"
      -- The bound payload follows the row's record (§4).
      renameButton <-
        buttonOn "rename y" (submitTx app (updateRecord items2 (VStr "y") (Item "yy")))
      root <-
        row
          [ pure list,
            column
              []
              [ pure source, -- label#0
                pure textWidget, -- label#1
                pure noteWidget, -- label#2
                pure filesWidget, -- label#3
                pure dropLabel, -- label#4
                pure dragLabel -- label#5
              ],
            pure itemList,
            pure renameButton -- button#0
          ]
      mount root
      setDragSource
        source
        emptyClip
          { clipText = Just "hello",
            clipCustom = [(noteFormat, BS.pack "note!")]
          }
        [OpCopy, OpMove]
      setReorderable list True
      mapM_ (\k -> insertRecord items (VStr k) (Item k)) ["a", "b", "c"]
      mapM_ (\k -> insertRecord items2 (VStr k) (Item k)) ["x", "y"]
      return
        ( items,
          items2,
          list,
          source,
          (textWidget, textTarget),
          (noteWidget, noteTarget),
          (filesWidget, filesTarget),
          rowNode,
          itemNode,
          dropStatus,
          dragStatus,
          sourceText
        )
  let dropped name target d = do
        let op = word (droppedOperation d)
        said <- case droppedClip d of
          Just (RFiles files) -> do
            -- A dropped file IS a picked file (D6): read it back through
            -- the same table the picker fills.
            parts <- mapM (\f -> do
                             body <- readBack f
                             return (pickedName f ++ " " ++ body)) files
            return (Just (name ++ " got " ++ intercalate ", " parts ++ " (" ++ op ++ ")"))
          _ -> return Nothing
        buildTx app $ do
          case (droppedClip d, said) of
            (_, Just line) -> writeSignal dropStatus (VStr line)
            (Just (RText text), _) -> do
              writeSignal
                dropStatus
                (VStr (name ++ " got text " ++ text ++ " (" ++ op ++ ")"))
              writeSignal target (VStr text)
            (Just (RCustom cid body), _) ->
              writeSignal
                dropStatus
                ( VStr
                    ( name
                        ++ " got "
                        ++ cid
                        ++ " "
                        ++ show (BS.length body)
                        ++ " bytes ("
                        ++ op
                        ++ ")"
                    )
                )
            _ -> writeSignal dropStatus (VStr (name ++ " got other (" ++ op ++ ")"))
          -- A same-app MOVE removes its original in the same batch (D2).
          if droppedOperation d == Just OpMove
            then do
              writeSignal sourceText (VStr "moved out")
              setDragSource source emptyClip []
            else return ()

  onDrop app (fst textPair) (dropped "text target" (snd textPair))
  onDrop app (fst notePair) (dropped "note target" (snd notePair))
  onDrop app (fst filesPair) (dropped "files target" (snd filesPair))
  onDragEnded app source $ \op ->
    buildTx app (writeSignal dragStatus (VStr ("drag ended " ++ word op)))
  onDrop app itemNode $ \keys d -> buildTx app $ do
    let op = word (droppedOperation d)
    case droppedClip d of
      Just (RText text) ->
        writeSignal
          dropStatus
          (VStr ("item " ++ keyWord keys ++ " got text " ++ text ++ " (" ++ op ++ ")"))
      _ ->
        writeSignal
          dropStatus
          (VStr ("item " ++ keyWord keys ++ " got other (" ++ op ++ ")"))
  let nodeEnded what keys op =
        buildTx app $
          writeSignal
            dragStatus
            (VStr (what ++ " " ++ keyWord keys ++ " drag ended " ++ word op))
  onDragEnded app itemNode (nodeEnded "item")
  onDragEnded app rowNode (nodeEnded "row")
  -- The moved row's key rides as the kaya-private custom representation;
  -- the anchor is the row it landed on (D8).
  onDrop app list $ \d -> case (droppedClip d, droppedAnchor d) of
    (Just (RCustom _ key), VStr anchor : _) ->
      buildTx app $
        if droppedBefore d
          then moveBefore (recordHandle items) (VStr (BS.unpack key)) (VStr anchor)
          else moveAfter (recordHandle items) (VStr (BS.unpack key)) (VStr anchor)
    _ -> return ()
