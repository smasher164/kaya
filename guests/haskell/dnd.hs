{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The drag-and-drop scene, Haskell port — guests/rust/dnd.rs,
-- tools/scenes/dnd.steps. THE ROOT IS A ROW so column#0 is the
-- reorderable For's container.

import qualified Data.ByteString.Char8 as BS
import GHC.Generics (Generic)
import Control.Exception (SomeException, try)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.FilePath ((</>))
import System.IO (hClose, hGetContents')
import System.Posix.Process (getProcessID)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

data Item = Item {title :: Text}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)


noteFormat :: Text
noteFormat = "dev.kaya/note"

word :: Maybe Op -> Text
word (Just OpCopy) = "copy"
word (Just OpMove) = "move"
word Nothing = "none"

keyWord :: [Key] -> Text
keyWord (k : _) = keyText k
keyWord [] = ""

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

readBack :: PickedFile -> IO Text
readBack f = do
  r <- try (openPicked f FileModeRead)
  case r of
    Left e -> return ("open failed: " <> tshow (e :: SomeException))
    Right (h, _seekable) -> do
      body <- hGetContents' h
      hClose h
      return (T.pack body)

main :: IO ()
main = kayaMain $ \app -> do
  writeDroppedFile
  (items, _items2, list, source, textPair, notePair, filesPair, rowNode, itemNode, dropStatus, dragStatus, sourceText) <-
    buildTx app $ do
      window primary [WTitle "dnd"]
      items <- collectionOf @Item
      items2 <- collectionOf @Item
      dropStatus <- signalText "no drop yet"
      dragStatus <- signalText "no drag yet"
      sourceText <- signalText "hello"
      textTarget <- signalText "text target"
      noteTarget <- signalText "note target"
      filesTarget <- signalText "files target"

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
                emptyTplClip {tplText = Just (TplField (field @"title" @Item))}
                [OpCopy]
            ]
            (label (field @"title" @Item))
      setA11yId itemList "items"
      -- The bound payload follows the row's record (§4).
      renameButton <-
        buttonOn "rename y" (submitTx app (updateRecord items2 "y" (Item "yy")))
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
          { text = Just "hello",
            custom = [(noteFormat, BS.pack "note!")]
          }
        [OpCopy, OpMove]
      setReorderable list True
      mapM_ (\k -> insertRecord items (textKey k) (Item k)) ["a", "b", "c"]
      mapM_ (\k -> insertRecord items2 (textKey k) (Item k)) ["x", "y"]
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
        let op = word d.operation
        said <- case d.clip of
          Just (RFiles files) -> do
            -- A dropped file IS a picked file (D6): read it back through
            -- the same table the picker fills.
            parts <- mapM (\f -> do
                             body <- readBack f
                             return (f.name <> " " <> body)) files
            return (Just (name <> " got " <> T.intercalate ", " parts <> " (" <> op <> ")"))
          _ -> return Nothing
        buildTx app $ do
          case (d.clip, said) of
            (_, Just line) -> writeSignal dropStatus line
            (Just (RText text), _) -> do
              writeSignal
                dropStatus
                (name <> " got text " <> text <> " (" <> op <> ")")
              writeSignal target text
            (Just (RCustom cid body), _) ->
              writeSignal
                dropStatus
                ( name
                    <> " got "
                    <> cid
                    <> " "
                    <> tshow (BS.length body)
                    <> " bytes ("
                    <> op
                    <> ")"
                )
            _ -> writeSignal dropStatus (name <> " got other (" <> op <> ")")
          -- A same-app MOVE removes its original in the same batch (D2).
          if d.operation == Just OpMove
            then do
              writeSignal sourceText "moved out"
              setDragSource source emptyClip []
            else return ()

  onDrop app (fst textPair) (dropped "text target" (snd textPair))
  onDrop app (fst notePair) (dropped "note target" (snd notePair))
  onDrop app (fst filesPair) (dropped "files target" (snd filesPair))
  onDragEnded app source $ \op ->
    buildTx app (writeSignal dragStatus ("drag ended " <> word op))
  onDrop app itemNode $ \keys d -> buildTx app $ do
    let op = word d.operation
    case d.clip of
      Just (RText text) ->
        writeSignal
          dropStatus
          ("item " <> keyWord keys <> " got text " <> text <> " (" <> op <> ")")
      _ ->
        writeSignal
          dropStatus
          ("item " <> keyWord keys <> " got other (" <> op <> ")")
  let nodeEnded what keys op =
        buildTx app $
          writeSignal
            dragStatus
            (what <> " " <> keyWord keys <> " drag ended " <> word op)
  onDragEnded app itemNode (nodeEnded "item")
  onDragEnded app rowNode (nodeEnded "row")
  -- The moved row's key rides as the kaya-private custom representation;
  -- the anchor is the row it landed on (D8).
  onDrop app list $ \d -> case (d.clip, d.anchor) of
    (Just (RCustom _ key), anchor : _) ->
      buildTx app $
        let moved = textKey (T.pack (BS.unpack key))
         in if d.before
              then moveBefore (recordHandle items) moved anchor
              else moveAfter (recordHandle items) moved anchor
    _ -> return ()
