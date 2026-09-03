{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

-- The drag-and-drop scene, Haskell port — guests/rust/dnd.rs,
-- tools/scenes/dnd.steps. THE ROOT IS A ROW so column#0 is the
-- reorderable For's container.

import qualified Data.ByteString.Char8 as BS
import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)

import KayaApp
import KayaWire (Value (..))

data Item = Item {title :: String} deriving (Generic)

instance KayaRecord Item

noteFormat :: String
noteFormat = "dev.kaya/note"

word :: Maybe Op -> String
word (Just OpCopy) = "copy"
word (Just OpMove) = "move"
word Nothing = "none"

main :: IO ()
main = kayaMain $ \app -> do
  (items, list, source, textPair, notePair, dropStatus, dragStatus, sourceText) <-
    buildTx app $ do
      window 0 [WTitle "dnd"]
      items <- collectionOf (Proxy :: Proxy Item)
      dropStatus <- signal (VStr "no drop yet")
      dragStatus <- signal (VStr "no drag yet")
      sourceText <- signal (VStr "hello")
      textTarget <- signal (VStr "text target")
      noteTarget <- signal (VStr "note target")
      filesTarget <- signal (VStr "files target")

      list <-
        each (recordHandle items) $
          withTplAttrs [TplA11yId "row"] (label (field @"title" @Item))
      source <- labelBound sourceText []
      textWidget <-
        labelBound textTarget [Accepts [acceptText], DropTarget [OpCopy]]
      noteWidget <-
        labelBound noteTarget [Accepts [noteFormat], DropTarget [OpCopy, OpMove]]
      filesWidget <-
        labelBound filesTarget [Accepts [acceptFiles], DropTarget [OpCopy]]
      dropLabel <- labelBound dropStatus []
      dragLabel <- labelBound dragStatus []
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
              ]
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
      return
        ( items,
          list,
          source,
          (textWidget, textTarget),
          (noteWidget, noteTarget),
          dropStatus,
          dragStatus,
          sourceText
        )

  let dropped name target d = buildTx app $ do
        let op = word (droppedOperation d)
        case droppedClip d of
          Just (RText text) -> do
            writeSignal
              dropStatus
              (VStr (name ++ " got text " ++ text ++ " (" ++ op ++ ")"))
            writeSignal target (VStr text)
          Just (RCustom cid body) ->
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
  onDragEnded app source $ \op ->
    buildTx app (writeSignal dragStatus (VStr ("drag ended " ++ word op)))
  -- The moved row's key rides as the kaya-private custom representation;
  -- the anchor is the row it landed on (D8).
  onDrop app list $ \d -> case (droppedClip d, droppedAnchor d) of
    (Just (RCustom _ key), VStr anchor : _) ->
      buildTx app $
        if droppedBefore d
          then moveBefore (recordHandle items) (VStr (BS.unpack key)) (VStr anchor)
          else moveAfter (recordHandle items) (VStr (BS.unpack key)) (VStr anchor)
    _ -> return ()
