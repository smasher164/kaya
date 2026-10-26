{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The row menu scene, Haskell port — guests/rust/rowmenu.rs,
-- tools/scenes/rowmenu.steps (docs/media-player-plan.md M26).

import GHC.Generics (Generic)

import Data.Text (Text)
import KayaApp

data RowmenuEntry = RowmenuEntry {title :: Text, mark :: Text}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    window primary [WTitle "rowmenu"]
    status <- signalText "ready"
    notes <- collectionOf @RowmenuEntry
    files <- collectionOf @RowmenuEntry
    let toggle c on off did undid keys = case keys of
          [key] -> submitTx app $ do
            entry <- getRecord c key
            let set = maybe False (\(RowmenuEntry _ m) -> m == on) entry
            updateField c key (field @"mark" @RowmenuEntry) (if set then off else on)
            writeSignal status ((if set then did else undid) <> " " <> keyText key)
          _ -> return ()
        openRow keys = case keys of
          [key] -> submitTx app (writeSignal status ("opened " <> keyText key))
          _ -> return ()
    star <- item "Star" [IOnActivateNode (toggle notes "Star" "Unstar" "starred" "unstarred")]
    noteMenu <- contextCatalog [pure star, separator, item "Open" [IOnActivateNode openRow]]
    pin <- item "Pin" [IOnActivateNode (toggle files "Pin" "Unpin" "pinned" "unpinned")]
    fileMenu <- contextCatalog [pure pin, separator, item "Open" [IOnActivateNode openRow]]
    (noteList, _) <-
      forEach (recordHandle notes) $ do
        line <- withTplAttrs [TplA11yId "note"] (rowOf [label (field @"title" @RowmenuEntry)])
        nodeContextMenu line noteMenu
        nodeContextLabel line star (field @"mark" @RowmenuEntry)
        return line
    (table, _) <-
      forEach (recordHandle files) $ do
        line <- withTplAttrs [TplA11yId "file"] (rowOf [label (field @"title" @RowmenuEntry)])
        nodeContextMenu line fileMenu
        nodeContextLabel line pin (field @"mark" @RowmenuEntry)
        return line
    setGrow table 1
    columns table ["Name"] sortNone
    root <- column [labelBound status [], pure noteList, pure table]
    mount root
    mapM_
      (\(k, t, m) -> insertRecord notes (textKey k) (RowmenuEntry t m))
      ([("a", "apples", "Star"), ("b", "bread", "Unstar")] :: [(Text, Text, Text)])
    mapM_
      (\(k, t, m) -> insertRecord files (textKey k) (RowmenuEntry t m))
      ([("x", "x.txt", "Pin"), ("y", "y.txt", "Unpin")] :: [(Text, Text, Text)])
  return ()
