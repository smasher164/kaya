{-# LANGUAGE OverloadedStrings #-}

-- The layers scene, Haskell port — guests/rust/layers.rs,
-- tools/scenes/layers.steps, docs/layering-plan.md LY13.

import Data.IORef (atomicModifyIORef', newIORef)
import qualified Data.Text as T

import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  logRef <- newIORef ["taps:" :: T.Text]
  cover <- asset "covers/cover-600.jpg"
  small <- asset "covers/cover-320.jpg"
  buildTx app $ do
    window primary [WTitle "layers", WSize 480 860]
    answered <- signalText "taps:"
    veiled <- signalBool False
    let answer word = do
          line <- atomicModifyIORef' logRef (\ws -> (ws ++ [word], T.unwords (ws ++ [word])))
          submitTx app $ do
            writeSignal answered line
            if word == "hide" then writeSignal veiled True else pure ()
    root <-
      column
        [Spacing 16]
        [ layers
            [Inset 8, A11yId "photostack"]
            [ imageAsset cover [MaxWidth 320, A11yLabel "Kind of Blue cover", A11yId "photo"],
              row [Filled TintAccent, Place PlaceTopTrailing, A11yId "badge"] [labelText "3" [A11yId "badge_text"]],
              row
                [Filled TintOverlayFade, Place PlaceBottom, A11yId "caption"]
                [labelText "Kind of Blue" [A11yId "caption_text"]],
              buttonOn "Share" (answer "share") [Place PlaceBottomTrailing, A11yId "share"]
            ],
          layers
            [A11yId "veilstack"]
            [ buttonOn "Press the base button here" (answer "base") [A11yId "base"],
              column
                [Align AlignCenter, Fill True, HiddenBound veiled, A11yId "busy"]
                [row [Filled TintOverlay] [labelText "Busy"]]
            ],
          layers
            [A11yId "sidestack"]
            [ buttonOn "Open the inbox" (answer "side") [A11yId "side"],
              row [Filled TintAccent, Place PlaceTrailing, A11yId "sidebadge"] [labelText "5"]
            ],
          layers
            [Inset 8, A11yId "flatstack"]
            [ imageAsset small [MaxWidth 200, A11yLabel "Small cover", A11yId "smallphoto"],
              row [Filled TintOverlay, Place PlaceTopLeading, A11yId "flat"] [labelText "Flat panel" [A11yId "flat_text"]]
            ],
          labelBound answered [A11yId "answered"],
          buttonOn "Hide the veil" (answer "hide") [A11yId "hideveil"]
        ]
    mount root
