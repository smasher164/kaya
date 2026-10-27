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

data RowmenuEntry = RowmenuEntry {title :: Text, mark :: Text, plain :: Bool}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    window primary [WTitle "rowmenu"]
    status <- signalText "ready"
    hide <- signalBool True
    notes <- collectionOf @RowmenuEntry
    files <- collectionOf @RowmenuEntry
    let toggle c on off did undid keys = case keys of
          [key] -> submitTx app $ do
            entry <- getRecord c key
            let set = maybe False (\(RowmenuEntry _ m _) -> m == on) entry
            updateField c key (field @"mark" @RowmenuEntry) (if set then off else on)
            updateField c key (field @"plain" @RowmenuEntry) (not set)
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
        let body =
              columnOf
                [ withTplAttrs [TplA11yId "title"] (label (field @"title" @RowmenuEntry)),
                  withTplAttrs
                    [TplA11yId "flag", TplHiddenField (field @"plain" @RowmenuEntry)]
                    (caption (field @"mark" @RowmenuEntry)),
                  withTplAttrs [TplA11yId "foot"] (caption (field @"title" @RowmenuEntry))
                ]
        line <- withTplAttrs [TplA11yId "note"] (rowOf [body])
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
    let pair =
          row
            [ column
                [ labelText "A" [A11yId "va"],
                  labelText "B" [A11yId "vb", HiddenBound hide],
                  labelText "C" [A11yId "vc"]
                ],
              buttonOn "Show B" (submitTx app (writeSignal hide False)) [A11yId "show"]
            ]
    root <- column [labelBound status [], pair, pure noteList, pure table]
    mount root
    mapM_
      (\(k, t, m) -> insertRecord notes (textKey k) (RowmenuEntry t m (m == "Star")))
      ([("a", "apples", "Star"), ("b", "bread", "Unstar")] :: [(Text, Text, Text)])
    mapM_
      (\(k, t, m) -> insertRecord files (textKey k) (RowmenuEntry t m (m == "Pin")))
      ([("x", "x.txt", "Pin"), ("y", "y.txt", "Unpin")] :: [(Text, Text, Text)])
  return ()
