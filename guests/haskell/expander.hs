{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The expander scene, Haskell port — guests/rust/expander.rs,
-- tools/scenes/expander.steps, docs/expander-plan.md §5.

import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import GHC.Generics (Generic)

import Data.Text (Text)
import KayaApp

data Section = Section {name :: Text, open :: Bool}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

word :: Bool -> Text
word True = "open"
word False = "closed"

main :: IO ()
main = kayaMain $ \app -> do
  heardRef <- newIORef (0 :: Int)
  opensRef <- newIORef (Map.fromList [("s01" :: Text, True)])

  (state, heardText, rowsText, details, sections, sectionNode) <- buildTx app $ do
    window primary [WTitle "expander", WSize 520 860]
    state <- signalText "details: closed"
    heardText <- signalText "heard: 0"
    typed <- signalText "name: -"
    rowsText <- signalText "rows: -"
    inside <- signalText "Inside the body"
    sections <- collectionOf @Section

    let onTyped text = submitTx app $ writeSignal typed ("name: " <> text)
        onRebuild = do
          on <- Map.findWithDefault False "s00" <$> readIORef opensRef
          submitTx app $ do
            remove (recordHandle sections) "s00"
            insertRecord sections "s00" (Section "Section 0" on)
            writeSignal rowsText "rebuilt s00"

    -- Built ahead of the tree so the handlers below have a handle to name.
    details <-
      expander
        "Details"
        [Summary "One field", Symbol SymbolInfo, A11yId "details"]
        [ entryOn onTyped [Placeholder "Name", A11yId "name"],
          labelBound inside [A11yId "inside"]
        ]
    let onShow on = submitTx app $ do
          setExpanded details on
          writeSignal state ("details: " <> word on)
    (sectionList, sectionNode) <- forEach (recordHandle sections) $ do
      withTplAttrs
        [TplA11yId "sec"]
        (expanderOf (field @"name" @Section) (field @"open" @Section) [label (field @"name" @Section)])

    root <-
      column
        [ pure details,
          labelBound state [A11yId "state"],
          labelBound heardText [A11yId "heard"],
          labelBound typed [A11yId "typed"],
          row
            [ buttonOn "Show" (onShow True) [A11yId "show"],
              buttonOn "Hide" (onShow False) [A11yId "hide"]
            ],
          column
            [A11yId "form"]
            [ labeled "Sort" [selectOn ["Due", "Name"] 0 (const (return ())) [A11yId "sort"]],
              expander
                "Advanced"
                [A11yId "advanced"]
                [ labeled "Hide badge" [checkboxOn "" (const (return ())) [A11yId "badge"]],
                  labeled "Keep completed" [checkboxOn "" (const (return ())) [A11yId "keep"]]
                ]
            ],
          labelBound rowsText [A11yId "rows"],
          buttonOn "Rebuild" onRebuild [A11yId "rebuild"],
          column [pure sectionList]
        ]
    mount root
    mapM_
      (\i -> insertRecord sections (textKey ("s0" <> tshow i)) (Section ("Section " <> tshow i) (i == (1 :: Int))))
      [0, 1, 2]
    return (state, heardText, rowsText, details, sections, sectionNode)

  onToggle app details $ \on -> do
    heard <- atomicModifyIORef' heardRef (\h -> (h + 1, h + 1))
    submitTx app $ do
      writeSignal state ("details: " <> word on)
      writeSignal heardText ("heard: " <> tshow heard)
  onToggle app sectionNode $ \keys on -> case keys of
    (key : _) -> do
      modifyIORef' opensRef (Map.insert (keyText key) on)
      submitTx app $ do
        patch sections key [set (field @"open" @Section) on]
        writeSignal rowsText ("sec " <> keyText key <> ": " <> word on)
    [] -> error "kaya: onToggle's key path is never empty"
