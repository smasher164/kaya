{-# LANGUAGE OverloadedStrings #-}

-- The dock scene, Haskell port — guests/rust/dock.rs, tools/scenes/dock.steps,
-- docs/styling-pass-plan.md Y8.

import Data.Text (Text)

import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  art <- asset "covers/cover-600.jpg" >>= assetBytes
  buildTx app $ do
    playing <- signalBool True
    window primary [WTitle "dock", WSize 720 480]
    dock primary 40 $ do
      (bar, _) <-
        when_ playing $
          withTplAttrs
            [TplA11yId "bar"]
            ( rowOf
                [ withTplAttrs [TplFitAs FitCover, TplMaxWidth 40, TplMaxHeight 40, TplShapeAs ShapeRounded] (image art),
                  columnOf [labelText "Blue in Green", caption ("Miles Davis" :: Text)],
                  withTplAttrs [TplA11yId "progress"] (slider 0 1 (0.4 :: Double)),
                  withTplAttrs [TplA11yId "pause"] (button "Pause")
                ]
            )
      root <- column [pure bar]
      return (root, ())
    root <-
      column
        [ labelText "Library",
          buttonOn "stop" (submitTx app (writeSignal playing False)) [A11yId "stop"],
          buttonOn "play" (submitTx app (writeSignal playing True)) [A11yId "play"]
        ]
    mount root
