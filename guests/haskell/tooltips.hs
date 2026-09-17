{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The tooltips scene, Haskell port — guests/rust/tooltips.rs,
-- tools/scenes/tooltips.steps, docs/tooltip-plan.md.

import GHC.Generics (Generic)

import Data.Text (Text)
import KayaApp

data Account = Account {name :: Text, note :: Text}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)


main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    nameHelp <- signalText "Your full name as it appears on the card"
    accounts <- collectionOf @Account

    let onSave =
          submitTx app $ writeSignal nameHelp "Your name, as saved"

    (rows, _) <- forEach (recordHandle accounts) $
      withTplAttrs
        [ TplHelpField (field @"note" @Account),
          TplA11yIdField (field @"name" @Account)
        ]
        (label (field @"name" @Account))

    root <-
      column
        [Help "The settings for this account", A11yId "settings"] -- column#0
        [ buttonOn "Save" onSave [Help "Saves the draft to disk", A11yId "save"], -- button#0
          buttonOn -- button#1
            "Discard"
            (return ())
            [ Help "Throws the draft away",
              A11yHint "discard every change",
              A11yId "discard"
            ],
          entryOn (const (return ())) [HelpBound nameHelp, A11yId "fullname"], -- entry#0
          sliderOn 0.0 1.0 0.5 (const (return ())) -- slider#0
            [Help "How loud the preview plays", A11yId "volume"],
          pure rows
        ]
    mount root

    insertRecord accounts "a" (Account "a" "The first account, opened in March")
    insertRecord accounts "b" (Account "b" "The second account, opened in May")
    return ()
  return ()
