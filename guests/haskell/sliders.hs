{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# OPTIONS_GHC -Wno-missing-signatures #-}
-- A key path's wire tag (KayaWire.Value) has no spelling a guest may
-- write (tools/check-sugar-surface.py's wire-tag clause) — the
-- fromWire-decoding helper below is left unsigned so its argument
-- type is inferred, never named.

-- The sliders scene, Haskell port — guests/rust/sliders.rs,
-- tools/scenes/sliders.steps, docs/slider-plan.md.

import Data.IORef (atomicModifyIORef', newIORef)
import Data.List (isSuffixOf)
import GHC.Generics (Generic)
import Text.Printf (printf)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

data Track = Track {name :: Text, level :: Double}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)


-- The harness's own slider spelling (crates/kaya/src/harness.rs).
spelled :: Double -> String
spelled v = dropDot (dropZeros (printf "%.6f" v))
  where
    dropZeros s = if "0" `isSuffixOf` s then dropZeros (init s) else s
    dropDot s = if "." `isSuffixOf` s then init s else s

-- The key path's own wire tag decoded through 'fromWire', never named:
-- the argument's type (the wire's Value) has no spelling a guest may
-- write (tools/check-sugar-surface.py's wire-tag clause).
keyWord v = T.unpack (fromWire v :: Text)

main :: IO ()
main = kayaMain $ \app -> do
  commitsRef <- newIORef (0 :: Int)

  (commitText, rowText, master, levelNode) <- buildTx app $ do
    levelText <- signal (T.pack "value: 50")
    commitText <- signal (T.pack "commits: 0")
    volumeText <- signal (T.pack "volume: 0.5")
    rowText <- signal (T.pack "row: none")
    pos <- signal (50.0 :: Double)
    tracks <- collectionOf @Track

    let onLevel v =
          submitTx app $ writeSignal levelText (T.pack ("value: " ++ spelled v))
        onVolume v =
          submitTx app $ writeSignal volumeText (T.pack ("volume: " ++ spelled v))
        onReset =
          -- Must NOT come back as a value or a commit occurrence.
          submitTx app $ writeSignal pos (25.0 :: Double)

    master <-
      sliderBoundOn -- slider#0
        0.0
        100.0
        pos
        onLevel
        [Step 5.0, TickSpacing 25.0, A11yId ("master" :: Text), A11yLabel ("Level" :: Text)]

    (trackList, levelNode) <- forEach (recordHandle tracks) $ do
      -- Realized ahead of its row so the central registration has a handle.
      n <-
        withTplAttrs
          [TplStep 10.0, TplA11yId ("level" :: Text)]
          (slider 0.0 100.0 (field @"level" @Track))
      _ <- rowOf [label (field @"name" @Track), pure n]
      return n

    root <-
      column
        [ labelBound levelText, -- label#0
          labelBound commitText, -- label#1
          labelBound volumeText, -- label#2
          labelBound rowText, -- label#3
          pure master,
          sliderOn 0.0 1.0 0.5 onVolume [TickSpacing 0.25, A11yLabel ("Volume" :: Text)], -- slider#1
          buttonOn "reset" onReset, -- button#0
          pure trackList
        ]
    mount root

    insertRecord tracks (T.pack "a") (Track "a" 70.0)
    insertRecord tracks (T.pack "b") (Track "b" 20.0)
    return (commitText, rowText, master, levelNode)

  onValueCommitted app master $ \_ -> do
    n <- atomicModifyIORef' commitsRef (\c -> (c + 1, c + 1))
    submitTx app $ writeSignal commitText (T.pack ("commits: " ++ show n))

  onValueCommitted app levelNode $ \keys v -> case keys of
    (key : _) ->
      submitTx app $
        writeSignal rowText (T.pack ("row " ++ keyWord key ++ ": " ++ spelled v))
    [] -> error "kaya: onValueCommitted's key path is never empty"
