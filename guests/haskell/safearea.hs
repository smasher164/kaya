{-# LANGUAGE OverloadedStrings #-}

-- The safearea scene, Haskell port — guests/rust/safearea.rs,
-- tools/scenes/safearea.steps (docs/safe-area-plan.md A3, A8).

import KayaApp

groundBox :: Viewbox
groundBox = Viewbox 300 200

ground :: Viewbox -> [DrawOp]
ground (Viewbox w h) =
  [ moveTo 0 0,
    lineTo w 0,
    lineTo w h,
    lineTo 0 h,
    close,
    fill PaintSeriesFill Nonzero
  ]

main :: IO ()
main = kayaMain $ \app -> do
  photo <- asset "images/photo.jpg"
  surface <- buildTx app $ do
    window primary [WTitle "safearea", WSize 420 640]
    caption <- signalText "inset 16"
    picture <- imageAsset photo [MaxHeight 160, A11yId "picture", A11yLabel "Photo"]
    bleed picture
    surface <- canvas groundBox [] [Grow 1, A11yId "ground", A11yLabel "Ground"]
    bleed surface
    root <-
      column
        []
        [ pure picture,
          labelBound caption [A11yId "caption"],
          buttonOn
            "No inset"
            ( submitTx app $ do
                window primary [WInset 0]
                writeSignal caption "inset 0"
            )
            [A11yId "inset"],
          buttonOn
            "Fullscreen"
            ( submitTx app $ do
                window primary [WFullscreen True]
                writeSignal caption "fullscreen"
            )
            [A11yId "full"],
          pure surface
        ]
    mount root
    return surface
  assetClose photo
  onDraw app surface ground
