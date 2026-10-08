{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The reveal toggle scene, Haskell port — guests/rust/reveal.rs,
-- tools/scenes/reveal.steps (docs/reveal-plan.md §5): a password field
-- with its own show/hide toggle, the app's own Show and Hide buttons, and a
-- stamped field each row reveals by its own field.

import GHC.Generics (Generic)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

data Account = Account {name :: Text, shown :: Bool}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

password :: Text
password = "Rv4tNbHy2mQc"

status :: Text -> Text
status text
  | n == 0 = "empty"
  | text == password = tshow n <> " characters, match"
  | otherwise = tshow n <> " characters, no match"
  where
    n = T.length text

shownText :: Bool -> Text
shownText True = "shown"
shownText False = "hidden"

rowKey :: [Key] -> Text
rowKey (k : _) = keyText k
rowKey [] = ""

main :: IO ()
main = kayaMain $ \app -> do
  (statusText, sentText, heardText, pinText, passwordField, showButton, hideButton, clearButton, pin) <- buildTx app $ do
    accounts <- collectionOf @Account
    statusText <- signalText "empty"
    sentText <- signalText "sent: -"
    heardText <- signalText "heard: -"
    pinText <- signalText "pin: -"

    -- Built ahead of the tree so the handlers below have handles to name.
    passwordField <-
      secureField
        [ Placeholder "Password",
          ContentType ContentTypePassword,
          Revealable,
          A11yId "password",
          A11yLabel "Password"
        ]
    showButton <- button "Show" [A11yId "show"]
    hideButton <- button "Hide" [A11yId "hide"]
    clearButton <- button "Clear" [A11yId "clear"]
    -- 'forEach' rather than 'each': the node escapes the template, so the
    -- handlers are registered centrally against it (bottom of file).
    (rows, pin) <- forEach (recordHandle accounts) $ do
      pinNode <-
        withTplAttrs
          [TplA11yId "pin", TplRevealable, TplRevealedField (field @"shown" @Account)]
          secureField
      _ <- rowOf [label (field @"name" @Account), pure pinNode]
      return pinNode

    root <-
      column
        [ pure passwordField,
          labelBound statusText [A11yId "status"],
          labelBound sentText [A11yId "sent"],
          labelBound heardText [A11yId "heard"],
          pure showButton,
          pure hideButton,
          pure clearButton,
          labelBound pinText [A11yId "pin_status"],
          pure rows
        ]
    mount root
    insertRecord accounts (textKey "b") (Account "b" True)
    return (statusText, sentText, heardText, pinText, passwordField, showButton, hideButton, clearButton, pin)

  onChange app passwordField $ \text -> submitTx app (writeSignal statusText (status text))
  onSubmit app passwordField $ \text ->
    submitTx app (writeSignal sentText ("sent: " <> status text))
  onToggle app passwordField $ \on ->
    submitTx app (writeSignal heardText ("heard: " <> shownText on))
  onClick app showButton $ submitTx app (setRevealed passwordField True)
  onClick app hideButton $ submitTx app (setRevealed passwordField False)
  onClick app clearButton $ submitTx app (clearWidget passwordField)
  onChange app pin $ \path text ->
    submitTx app (writeSignal pinText ("pin " <> rowKey path <> ": " <> tshow (T.length text)))
  onToggle app pin $ \path on ->
    submitTx app (writeSignal pinText ("pin " <> rowKey path <> ": " <> shownText on))
