{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

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
-- printf is String by nature (Text.Printf has no Text instance), so the
-- one conversion sits here rather than at every call.
spelled :: Double -> Text
spelled v = T.pack (dropDot (dropZeros (printf "%.6f" v)))
  where
    dropZeros s = if "0" `isSuffixOf` s then dropZeros (init s) else s
    dropDot s = if "." `isSuffixOf` s then init s else s

keyWord :: Key -> Text
keyWord = keyText

main :: IO ()
main = kayaMain $ \app -> do
  commitsRef <- newIORef (0 :: Int)

  (commitText, rowText, master, levelNode) <- buildTx app $ do
    levelText <- signalText "value: 50"
    commitText <- signalText "commits: 0"
    volumeText <- signalText "volume: 0.5"
    rowText <- signalText "row: none"
    pos <- signalDouble 50.0
    tracks <- collectionOf @Track

    let onLevel v =
          submitTx app $ writeSignal levelText ("value: " <> spelled v)
        onVolume v =
          submitTx app $ writeSignal volumeText ("volume: " <> spelled v)
        onReset =
          -- Must NOT come back as a value or a commit occurrence.
          submitTx app $ writeSignal pos (25.0 :: Double)

    master <-
      sliderBoundOn -- slider#0
        0.0
        100.0
        pos
        onLevel
        [Step 5.0, TickSpacing 25.0, A11yId "master", A11yLabel "Level"]

    (trackList, levelNode) <- forEach (recordHandle tracks) $ do
      -- Realized ahead of its row so the central registration has a handle.
      n <-
        withTplAttrs
          [TplStep 10.0, TplA11yId "level"]
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
          sliderOn 0.0 1.0 0.5 onVolume [TickSpacing 0.25, A11yLabel "Volume"], -- slider#1
          buttonOn "reset" onReset, -- button#0
          pure trackList
        ]
    mount root

    insertRecord tracks "a" (Track "a" 70.0)
    insertRecord tracks "b" (Track "b" 20.0)
    return (commitText, rowText, master, levelNode)

  onValueCommitted app master $ \_ -> do
    n <- atomicModifyIORef' commitsRef (\c -> (c + 1, c + 1))
    submitTx app $ writeSignal commitText ("commits: " <> tshow n)

  onValueCommitted app levelNode $ \keys v -> case keys of
    (key : _) ->
      submitTx app $
        writeSignal rowText ("row " <> keyWord key <> ": " <> spelled v)
    [] -> error "kaya: onValueCommitted's key path is never empty"
