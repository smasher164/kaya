{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The hidden-rows scene, Haskell port — guests/rust/hiderows.rs,
-- tools/scenes/hiderows.steps (docs/hidden-plan.md).

import Control.Monad (forM_)
import GHC.Generics (Generic)
import Text.Printf (printf)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

data HiderowsNote = HiderowsNote {title :: Text, unmatched :: Bool}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

data HiderowsFile = HiderowsFile {name :: Text, size :: Text, fileUnmatched :: Bool}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

notes :: [Text]
notes = ["alpha", "beta", "gamma"]

fileName :: Int -> Text
fileName i = T.pack (printf "file %03d" i)

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    window primary [WTitle "hiderows"]
    noteRows <- collectionOf @HiderowsNote
    fileRows <- collectionOf @HiderowsFile
    two <- signalBool False
    let findNotes query = submitTx app $
          forM_ notes $ \t ->
            updateField noteRows (textKey t) (field @"unmatched" @HiderowsNote) (not (query `T.isInfixOf` t))
        findFiles query = submitTx app $
          forM_ [0 .. 299] $ \i ->
            updateField fileRows (textKey (fileName i)) (field @"fileUnmatched" @HiderowsFile)
              (not (query `T.isInfixOf` fileName i))
    findNotesField <- searchOn findNotes [Placeholder "Find notes", A11yId "find_notes"]
    (noteList, _) <-
      forEach (recordHandle noteRows) $
        withTplAttrs
          [TplHiddenField (field @"unmatched" @HiderowsNote)]
          (rowOf [label (field @"title" @HiderowsNote), withTplAttrs [TplA11yId "note"] entry])
    setA11yId noteList "notes"
    tiles <- grid 2 [labelText "one" [], labelText "two" [HiddenBound two], labelText "three" []]
    setA11yId tiles "tiles"
    hideTwo <- checkboxOn "Hide two" (\on -> submitTx app (writeSignal two on)) [A11yId "hide_two"]
    findFilesField <- searchOn findFiles [Placeholder "Find files", A11yId "find_files"]
    (table, _) <-
      forEach (recordHandle fileRows) $
        withTplAttrs
          [TplHiddenField (field @"fileUnmatched" @HiderowsFile)]
          (rowOf [label (field @"name" @HiderowsFile), label (field @"size" @HiderowsFile)])
    setA11yId table "files"
    setGrow table 1
    columns table ["Name", "Size"] sortNone
    root <-
      column
        [ pure findNotesField,
          pure noteList,
          pure tiles,
          pure hideTwo,
          pure findFilesField,
          pure table
        ]
    mount root
    forM_ notes $ \t -> insertRecord noteRows (textKey t) (HiderowsNote t False)
    forM_ [0 .. 299 :: Int] $ \i ->
      insertRecord fileRows (textKey (fileName i)) (HiderowsFile (fileName i) (T.pack (show i) <> " KB") False)
  return ()
