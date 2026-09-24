{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The scroll-to scene, Haskell port — guests/rust/scrollto.rs,
-- tools/scenes/scrollto.steps. The app scrolls a list of messages to a
-- row by key (docs/scroll-to-plan.md), opening at the newest one before
-- the first layout, jumping to one on a click, staying put on a key no
-- row holds, and following its own send.

import Data.IORef (newIORef, readIORef, writeIORef)
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
  sent <- newIORef (60 :: Int)
  buildTx app $ do
    messages <- collectionOf @Message
    count <- signalText "60 messages"

    -- The For's own container is what a scrollToRow addresses
    -- (docs/scroll-to-plan.md S1): 'forEach' returns it.
    (list, _) <- forEach (recordHandle messages) (label (field @"text" @Message))
    setA11yId list "messages"

    let jumpTo key = submitTx app (scrollToRow list key)
        onSend = do
          n <- (+ 1) <$> readIORef sent
          writeIORef sent n
          submitTx app $ do
            insertRecord messages (msgKey n) (Message ("message " <> tshow n))
            writeSignal count (tshow n <> " messages")
            scrollToRow list (msgKey n)

    root <-
      column
        [ labelBound count [A11yId "count"],
          row
            [ buttonOn "jump" (jumpTo (msgKey 10)) [A11yId "jump"],
              buttonOn "nowhere" (jumpTo (msgKey 999)) [A11yId "nowhere"],
              buttonOn "send" onSend [A11yId "send"]
            ],
          scroll [Grow 1] (pure list)
        ]
    mount root
    mapM_
      (\i -> insertRecord messages (msgKey i) (Message ("message " <> tshow i)))
      [1 .. 60 :: Int]
    scrollToRow list (msgKey 60)
