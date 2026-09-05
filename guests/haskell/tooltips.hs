{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

-- The tooltips scene, Haskell port — guests/rust/tooltips.rs,
-- tools/scenes/tooltips.steps, docs/tooltip-plan.md.

import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)

import KayaApp
import KayaWire (Value (..))

data Account = Account {name :: String, note :: String} deriving (Generic)

instance KayaRecord Account

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    nameHelp <- signal (VStr "Your full name as it appears on the card")
    accounts <- collectionOf (Proxy :: Proxy Account)

    let onSave =
          submitTx app $ writeSignal nameHelp (VStr "Your name, as saved")

    (rows, _) <- forEach (recordHandle accounts) $
      withTplAttrs
        [ TplHelp (field @"note" @Account),
          TplA11yId (field @"name" @Account)
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
          entryOn (const (return ())) [Help nameHelp, A11yId "fullname"], -- entry#0
          sliderOn 0.0 1.0 0.5 (const (return ())) -- slider#0
            [Help "How loud the preview plays", A11yId "volume"],
          pure rows
        ]
    mount root

    insertRecord accounts (VStr "a") (Account "a" "The first account, opened in March")
    insertRecord accounts (VStr "b") (Account "b" "The second account, opened in May")
    return ()
  return ()
