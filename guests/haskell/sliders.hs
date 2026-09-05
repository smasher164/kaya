{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

-- The sliders scene, Haskell port — guests/rust/sliders.rs,
-- tools/scenes/sliders.steps, docs/slider-plan.md.

import Data.IORef (atomicModifyIORef', newIORef)
import Data.List (isSuffixOf)
import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)
import Text.Printf (printf)

import KayaApp
import KayaWire (Value (..))

data Track = Track {name :: String, level :: Double} deriving (Generic)

instance KayaRecord Track

-- The harness's own slider spelling (crates/kaya/src/harness.rs).
spelled :: Double -> String
spelled v = dropDot (dropZeros (printf "%.6f" v))
  where
    dropZeros s = if "0" `isSuffixOf` s then dropZeros (init s) else s
    dropDot s = if "." `isSuffixOf` s then init s else s

keyWord :: Value -> String
keyWord v = case v of VStr s -> s; other -> show other

main :: IO ()
main = kayaMain $ \app -> do
  commitsRef <- newIORef (0 :: Int)

  (commitText, rowText, master, levelNode) <- buildTx app $ do
    levelText <- signal (VStr "value: 50")
    commitText <- signal (VStr "commits: 0")
    volumeText <- signal (VStr "volume: 0.5")
    rowText <- signal (VStr "row: none")
    pos <- signal (VF64 50.0)
    tracks <- collectionOf (Proxy :: Proxy Track)

    let onLevel v =
          submitTx app $ writeSignal levelText (VStr ("value: " ++ spelled v))
        onVolume v =
          submitTx app $ writeSignal volumeText (VStr ("volume: " ++ spelled v))
        onReset =
          -- Must NOT come back as a value or a commit occurrence.
          submitTx app $ writeSignal pos (VF64 25.0)

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

    insertRecord tracks (VStr "a") (Track "a" 70.0)
    insertRecord tracks (VStr "b") (Track "b" 20.0)
    return (commitText, rowText, master, levelNode)

  onValueCommitted app master $ \_ -> do
    n <- atomicModifyIORef' commitsRef (\c -> (c + 1, c + 1))
    submitTx app $ writeSignal commitText (VStr ("commits: " ++ show n))

  onValueCommitted app levelNode $ \keys v ->
    submitTx app $
      writeSignal rowText (VStr ("row " ++ keyWord (head keys) ++ ": " ++ spelled v))
