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
import KayaApp hiding (Frame (..))

data Message = Message {text :: Text}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

data Frame = Frame {name :: Text}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

msgKey :: Int -> Key
msgKey i = textKey ("m" <> tshow i)

frameKey :: Int -> Key
frameKey i = textKey ("f" <> tshow i)

frameOf :: Int -> Frame
frameOf i = Frame ("frame " <> tshow i)

main :: IO ()
main = kayaMain $ \app -> do
  sent <- newIORef (60 :: Int)
  framed <- newIORef (30 :: Int)
  buildTx app $ do
    messages <- collectionOf @Message
    frames <- collectionOf @Frame
    count <- signalText "60 messages"

    -- The For's own container is what a scrollToRow addresses
    -- (docs/scroll-to-plan.md S1): 'forEach' returns it.
    (list, _) <- forEach (recordHandle messages) (label (field @"text" @Message))
    setA11yId list "messages"
    -- A filmstrip that runs sideways (docs/hscroll-plan.md): the same
    -- scrollToRow and followsEnd, along its own axis.
    (strip, _) <- forEach (recordHandle frames) (label (field @"name" @Frame))
    setAxis strip AxisHorizontal
    setA11yId strip "frames"

    let jumpTo key = submitTx app (scrollToRow list key)
        jumpStrip key = submitTx app (scrollToRow strip key)
        onSend = do
          n <- (+ 1) <$> readIORef sent
          writeIORef sent n
          submitTx app $ do
            insertRecord messages (msgKey n) (Message ("message " <> tshow n))
            writeSignal count (tshow n <> " messages")
            scrollToRow list (msgKey n)
        onAddFrame = do
          n <- (+ 1) <$> readIORef framed
          writeIORef framed n
          submitTx app (insertRecord frames (frameKey n) (frameOf n))

    root <-
      column
        [ labelBound count [A11yId "count"],
          row
            [ buttonOn "jump" (jumpTo (msgKey 10)) [A11yId "jump"],
              buttonOn "nowhere" (jumpTo (msgKey 999)) [A11yId "nowhere"],
              buttonOn "send" onSend [A11yId "send"],
              buttonOn "frame" (jumpStrip (frameKey 10)) [A11yId "frame"],
              buttonOn "add frame" onAddFrame [A11yId "add_frame"]
            ],
          scroll [Grow 1, A11yId "list"] (pure list),
          scroll [Axis AxisHorizontal, FollowsEnd, A11yId "strip"] (pure strip)
        ]
    mount root
    mapM_ (\i -> insertRecord frames (frameKey i) (frameOf i)) [1 .. 30 :: Int]
    mapM_
      (\i -> insertRecord messages (msgKey i) (Message ("message " <> tshow i)))
      [1 .. 60 :: Int]
    scrollToRow list (msgKey 60)
