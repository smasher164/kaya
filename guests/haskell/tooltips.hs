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
import qualified Data.Text as T
import KayaApp

data Account = Account {name :: Text, note :: Text}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)


main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    nameHelp <- signal (T.pack "Your full name as it appears on the card")
    accounts <- collectionOf @Account

    let onSave =
          submitTx app $ writeSignal nameHelp (T.pack "Your name, as saved")

    (rows, _) <- forEach (recordHandle accounts) $
      withTplAttrs
        [ TplHelp (field @"note" @Account),
          TplA11yId (field @"name" @Account)
        ]
        (label (field @"name" @Account))

    root <-
      column
        [Help ("The settings for this account" :: Text), A11yId ("settings" :: Text)] -- column#0
        [ buttonOn "Save" onSave [Help ("Saves the draft to disk" :: Text), A11yId ("save" :: Text)], -- button#0
          buttonOn -- button#1
            "Discard"
            (return ())
            [ Help ("Throws the draft away" :: Text),
              A11yHint ("discard every change" :: Text),
              A11yId ("discard" :: Text)
            ],
          entryOn (const (return ())) [Help nameHelp, A11yId ("fullname" :: Text)], -- entry#0
          sliderOn 0.0 1.0 0.5 (const (return ())) -- slider#0
            [Help ("How loud the preview plays" :: Text), A11yId ("volume" :: Text)],
          pure rows
        ]
    mount root

    insertRecord accounts (T.pack "a") (Account "a" "The first account, opened in March")
    insertRecord accounts (T.pack "b") (Account "b" "The second account, opened in May")
    return ()
  return ()
