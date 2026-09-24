{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The submit scene, Haskell port — guests/rust/submit.rs,
-- tools/scenes/submit.steps. Return in an entry, a search field and a
-- 'Submits' textarea publishes the field's text (docs/submit-plan.md); a
-- plain textarea's Return is its newline. The app writes each submit into
-- one label.

import GHC.Generics (Generic)

import Data.Text (Text)
import KayaApp

data Thread = Thread {title :: Text}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)


rowKey :: [Key] -> Text
rowKey (k : _) = keyText k
rowKey [] = ""

main :: IO ()
main = kayaMain $ \app -> do
  (sent, name, find, plain, compose, reply) <- buildTx app $ do
    threads <- collectionOf @Thread
    sentText <- signalText "sent: -"

    -- Built ahead of the tree so the handlers below have handles to name.
    name <- entry [Placeholder "Name", A11yId "name"]
    find <- search [Placeholder "Search", A11yId "find"]
    plain <- textarea [A11yId "plain"]
    compose <- textarea [Submits True, A11yId "compose"]
    -- 'forEach' rather than 'each': the node escapes the template, so the
    -- submit handler is registered centrally against it (bottom of file).
    (rows, reply) <- forEach (recordHandle threads) $ do
      replyNode <- withTplAttrs [TplA11yId "reply"] entry
      _ <- rowOf [label (field @"title" @Thread), pure replyNode]
      return replyNode

    root <-
      column
        [ labelBound sentText [A11yId "sent"],
          pure name,
          pure find,
          pure plain,
          pure compose,
          pure rows
        ]
    mount root
    mapM_
      (\(key, t) -> insertRecord threads (textKey key) (Thread t))
      [("r1", "First"), ("r2", "Second")]
    return (sentText, name, find, plain, compose, reply)

  let wrote text = submitTx app (writeSignal sent ("sent: " <> text))
  mapM_ (\w -> onSubmit app w wrote) [name, find, plain, compose]
  onSubmit app reply $ \path text ->
    submitTx app (writeSignal sent ("sent: " <> rowKey path <> ": " <> text))
