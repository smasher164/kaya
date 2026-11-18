{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The restoration scene, Haskell port — guests/rust/restore.rs,
-- tools/scenes/restore.steps (docs/restoration-plan.md SR15): the draft
-- lives in the session store and comes back through the ordinary build;
-- the list's scroll and the text's caret come back on their own.

import GHC.Generics (Generic)

import Data.Text (Text)
import KayaApp

data Message = Message {text :: Text}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

msgKey :: Int -> Key
msgKey i = textKey ("m" <> tshow i)

main :: IO ()
main = kayaMain $ \app -> do
  launch <- restored
  draft <- session.prefGetString "draft" ""
  buildTx app $ do
    window primary [WTitle "restore"]
    messages <- collectionOf @Message
    status <- signalText ("launch " <> launch)
    (list, _) <- forEach (recordHandle messages) (label (field @"text" @Message))
    setA11yId list "messages"
    field' <- entryOn (session.prefSetString "draft") []
    setText field' draft
    doc <- textarea [A11yId "doc"]
    setText doc "the quick brown fox"
    root <-
      column
        [ labelBound status [],
          pure field',
          row
            [ buttonOn "jump" (submitTx app (scrollToRow list (msgKey 30))) [A11yId "jump"],
              buttonOn "select" (submitTx app (selectRange doc (4, 9))) [A11yId "select"]
            ],
          pure doc,
          scroll [Grow 1, A11yId "list"] (pure list)
        ]
    mount root
    mapM_
      (\i -> insertRecord messages (msgKey i) (Message ("message " <> tshow i)))
      [1 .. 60 :: Int]
