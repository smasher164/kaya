{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The range scene, Haskell port — guests/rust/range.rs,
-- tools/scenes/range.steps, docs/range-plan.md.

import Data.IORef (atomicModifyIORef', newIORef)
import Data.List (isSuffixOf)
import GHC.Generics (Generic)
import Text.Printf (printf)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp hiding (Clip (..))

data Clip = Clip {name :: Text, trimIn :: Double, trimOut :: Double}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

-- The harness's own slider spelling (crates/kaya/src/harness.rs).
spelled :: Double -> Text
spelled v = T.pack (dropDot (dropZeros (printf "%.6f" v)))
  where
    dropZeros s = if "0" `isSuffixOf` s then dropZeros (init s) else s
    dropDot s = if "." `isSuffixOf` s then init s else s

pair :: Double -> Double -> Text
pair low high = spelled low <> " " <> spelled high

main :: IO ()
main = kayaMain $ \app -> do
  commitsRef <- newIORef (0 :: Int)

  (commitText, clipText, trim, trimNode) <- buildTx app $ do
    liveText <- signalText "live: 2 8"
    commitText <- signalText "commits: 0"
    volumeText <- signalText "volume: 0.25"
    clipText <- signalText "clip: none"
    lowSig <- signalDouble 2.0
    highSig <- signalDouble 8.0
    clips <- collectionOf @Clip

    let onMoved low high =
          submitTx app $ writeSignal liveText ("live: " <> pair low high)
        onVolume v =
          submitTx app $ writeSignal volumeText ("volume: " <> spelled v)
        onReset =
          -- Must NOT come back as a move or a commit.
          submitTx app $ writeSignal lowSig (1.0 :: Double)
        onLate =
          -- Crosses a high thumb the user moved; the core clamps it (docs/range-plan.md §3).
          submitTx app $ writeSignal lowSig (6.0 :: Double)

    trim <-
      rangeBoundOn -- range#0
        0.0
        10.0
        lowSig
        highSig
        onMoved
        [ Step 0.5,
          TickSpacing 1.0,
          MinGap 1.0,
          A11yLabel "Trim",
          LowLabel "In",
          HighLabel "Out",
          A11yId "trim"
        ]

    (clipList, trimNode) <- forEach (recordHandle clips) $ do
      -- Realized ahead of its row so the central registration has a handle.
      n <-
        withTplAttrs
          [TplStep 0.5, TplMinGap 1.0, TplA11yId "clip"]
          (range 0.0 10.0 (field @"trimIn" @Clip) (field @"trimOut" @Clip))
      _ <- rowOf [label (field @"name" @Clip), pure n]
      return n

    root <-
      column
        [ labelBound liveText, -- label#0
          labelBound commitText, -- label#1
          labelBound volumeText, -- label#2
          labelBound clipText, -- label#3
          pure trim,
          rangeOn 0.0 10.0 4.0 6.0 (\_ _ -> return ()) -- range#1
            [Step 0.5, TickSpacing 1.0, MinGap 0.0, A11yLabel "Tie"],
          sliderOn 0.0 10.0 5.0 (\_ -> return ()) [A11yLabel "Playhead"], -- slider#0
          sliderOn -- slider#1
            0.0
            1.0
            0.25
            onVolume
            [Step 0.25, Axis AxisVertical, A11yLabel "Volume", A11yId "volume"],
          buttonOn "reset" onReset, -- button#0
          buttonOn "late" onLate, -- button#1
          pure clipList
        ]
    mount root

    insertRecord clips "a" (Clip "a" 1.0 4.0)
    insertRecord clips "b" (Clip "b" 3.0 7.0)
    return (commitText, clipText, trim, trimNode)

  onRangeCommitted app trim $ \low high -> do
    n <- atomicModifyIORef' commitsRef (\c -> (c + 1, c + 1))
    submitTx app $
      writeSignal commitText ("commits: " <> tshow n <> " at " <> pair low high)

  onRangeCommitted app trimNode $ \keys low high -> case keys of
    (key : _) ->
      submitTx app $
        writeSignal clipText ("clip " <> keyText key <> ": " <> pair low high)
    [] -> error "kaya: onRangeCommitted's key path is never empty"
