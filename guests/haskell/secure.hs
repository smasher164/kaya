{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The secure field scene, Haskell port — guests/rust/secure.rs,
-- tools/scenes/secure.steps (docs/secure-entry-plan.md §5): a password
-- field whose text the app receives whole and answers only as a length and
-- a match, a clear button, and a stamped field per account whose edits name
-- the row.

import GHC.Generics (Generic)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

data Account = Account {name :: Text}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

password :: Text
password = "Zq7vKeXw9pLm"

status :: Text -> Text
status text
  | n == 0 = "empty"
  | text == password = tshow n <> " characters, match"
  | otherwise = tshow n <> " characters, no match"
  where
    n = T.length text

rowKey :: [Key] -> Text
rowKey (k : _) = keyText k
rowKey [] = ""

main :: IO ()
main = kayaMain $ \app -> do
  (statusText, sentText, pinText, passwordField, clearButton, pin) <- buildTx app $ do
    accounts <- collectionOf @Account
    statusText <- signalText "empty"
    sentText <- signalText "sent: -"
    pinText <- signalText "pin: -"

    -- Built ahead of the tree so the handlers below have handles to name.
    passwordField <- secureField [Placeholder "Password", A11yId "password", A11yLabel "Password"]
    clearButton <- button "Clear" [A11yId "clear"]
    -- 'forEach' rather than 'each': the node escapes the template, so the
    -- change handler is registered centrally against it (bottom of file).
    (rows, pin) <- forEach (recordHandle accounts) $ do
      pinNode <- withTplAttrs [TplA11yId "pin"] secureField
      _ <- rowOf [label (field @"name" @Account), pure pinNode]
      return pinNode

    root <-
      column
        [ pure passwordField,
          labelBound statusText [A11yId "status"],
          labelBound sentText [A11yId "sent"],
          pure clearButton,
          labelBound pinText [A11yId "pin_status"],
          pure rows
        ]
    mount root
    mapM_ (\key -> insertRecord accounts (textKey key) (Account key)) ["a", "b"]
    return (statusText, sentText, pinText, passwordField, clearButton, pin)

  onChange app passwordField $ \text -> submitTx app (writeSignal statusText (status text))
  onSubmit app passwordField $ \text ->
    submitTx app (writeSignal sentText ("sent: " <> status text))
  onClick app clearButton $ submitTx app (clearWidget passwordField)
  onChange app pin $ \path text ->
    submitTx app (writeSignal pinText ("pin " <> rowKey path <> ": " <> tshow (T.length text)))
