{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# OPTIONS_GHC -Wno-missing-signatures #-}
-- A key path's wire tag (KayaWire.Value) has no spelling a guest may
-- write (tools/check-sugar-surface.py's wire-tag clause) — the
-- fromWire-decoding helper below is left unsigned so its argument
-- type is inferred, never named.

-- The drag-and-drop scene, Haskell port — guests/rust/dnd.rs,
-- tools/scenes/dnd.steps. THE ROOT IS A ROW so column#0 is the
-- reorderable For's container.

import qualified Data.ByteString.Char8 as BS
import Data.List (intercalate)
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


noteFormat :: String
noteFormat = "dev.kaya/note"

word :: Maybe Op -> String
word (Just OpCopy) = "copy"
word (Just OpMove) = "move"
word Nothing = "none"

-- The key path's own wire tag decoded through 'fromWire', never named:
-- the argument's type (the wire's Value) has no spelling a guest may
-- write (tools/check-sugar-surface.py's wire-tag clause).
keyWord (k : _) = fromWire k :: Text
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

readBack :: PickedFile -> IO String
readBack f = do
  r <- try (openPicked f FileModeRead)
  case r of
    Left e -> return ("open failed: " ++ show (e :: SomeException))
    Right (h, _seekable) -> do
      body <- hGetContents' h
      hClose h
      return body

main :: IO ()
main = kayaMain $ \app -> do
  writeDroppedFile
  (items, _items2, list, source, textPair, notePair, filesPair, rowNode, itemNode, dropStatus, dragStatus, sourceText) <-
    buildTx app $ do
      window primary [WTitle "dnd"]
      items <- collectionOf @Item
      items2 <- collectionOf @Item
      dropStatus <- signal (T.pack "no drop yet")
      dragStatus <- signal (T.pack "no drag yet")
      sourceText <- signal (T.pack "hello")
      textTarget <- signal (T.pack "text target")
      noteTarget <- signal (T.pack "note target")
      filesTarget <- signal (T.pack "files target")

      (list, rowNode) <-
        forEach (recordHandle items) $
          withTplAttrs [TplA11yId ("row" :: Text)] (label (field @"title" @Item))
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
            [ TplA11yId ("item" :: Text),
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
        buttonOn "rename y" (submitTx app (updateRecord items2 ("y" :: Text) (Item "yy")))
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
      mapM_ (\k -> insertRecord items k (Item k)) ["a", "b", "c"]
      mapM_ (\k -> insertRecord items2 k (Item k)) ["x", "y"]
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
            return (Just (name <> " got " <> T.pack (intercalate ", " parts) <> " (" <> T.pack op <> ")"))
          _ -> return Nothing
        buildTx app $ do
          case (droppedClip d, said) of
            (_, Just line) -> writeSignal dropStatus line
            (Just (RText text), _) -> do
              writeSignal
                dropStatus
                (name <> " got text " <> text <> " (" <> T.pack op <> ")")
              writeSignal target text
            (Just (RCustom cid body), _) ->
              writeSignal
                dropStatus
                ( name
                    <> " got "
                    <> T.pack cid
                    <> " "
                    <> T.pack (show (BS.length body))
                    <> " bytes ("
                    <> T.pack op
                    <> ")"
                )
            _ -> writeSignal dropStatus (name <> " got other (" <> T.pack op <> ")")
          -- A same-app MOVE removes its original in the same batch (D2).
          if droppedOperation d == Just OpMove
            then do
              writeSignal sourceText ("moved out" :: Text)
              setDragSource source emptyClip []
            else return ()

  onDrop app (fst textPair) (dropped ("text target" :: Text) (snd textPair))
  onDrop app (fst notePair) (dropped "note target" (snd notePair))
  onDrop app (fst filesPair) (dropped "files target" (snd filesPair))
  onDragEnded app source $ \op ->
    buildTx app (writeSignal dragStatus (T.pack ("drag ended " ++ word op)))
  onDrop app itemNode $ \keys d -> buildTx app $ do
    let op = word (droppedOperation d)
    case droppedClip d of
      Just (RText text) ->
        writeSignal
          dropStatus
          ("item " <> keyWord keys <> " got text " <> text <> " (" <> T.pack op <> ")")
      _ ->
        writeSignal
          dropStatus
          ("item " <> keyWord keys <> " got other (" <> T.pack op <> ")")
  let nodeEnded what keys op =
        buildTx app $
          writeSignal
            dragStatus
            (T.pack what <> " " <> keyWord keys <> " drag ended " <> T.pack (word op))
  onDragEnded app itemNode (nodeEnded "item")
  onDragEnded app rowNode (nodeEnded "row")
  -- The moved row's key rides as the kaya-private custom representation;
  -- the anchor is the row it landed on (D8).
  onDrop app list $ \d -> case (droppedClip d, droppedAnchor d) of
    (Just (RCustom _ key), anchorKey : _) ->
      let anchor = fromWire anchorKey :: Text
       in buildTx app $
            if droppedBefore d
              then moveBefore (recordHandle items) (T.pack (BS.unpack key)) anchor
              else moveAfter (recordHandle items) (T.pack (BS.unpack key)) anchor
    _ -> return ()
