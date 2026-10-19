{-# LANGUAGE OverloadedStrings #-}

-- The grounds scene, Haskell port — guests/rust/grounds.rs,
-- tools/scenes/grounds.steps, docs/styling-pass-plan.md Y2, Y3.

import Data.Maybe (fromMaybe)

import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  art <- asset "covers/cover-600.jpg" >>= assetBytes
  let colour = fromMaybe (error "the cover decodes") (imageDominant art)
  buildTx app $ do
    window primary [WTitle "grounds", WSize 480 560, WInset 0]
    root <-
      column
        [Spacing 12]
        [ column
            [Inset 24, GroundImage art, A11yId "hero"]
            [row [Filled TintOverlay, A11yId "scrim"] [labelText "Miles Davis"]],
          column
            [Inset 24, GroundGradient colour, A11yId "header"]
            [headingText "Kind of Blue" [A11yId "title"], captionText "Miles Davis · 1959"],
          column [Inset 24, A11yId "plain"] [labelText "Plain"]
        ]
    mount root
