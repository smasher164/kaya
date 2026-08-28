{- The canvas SIZE-POLICY scene from Haskell (docs/canvas-plan.md
   §3.2.1): what a canvas does when layout gives it a track that is not
   its viewbox. See guests/rust/sizepolicy.rs; the byte-frozen contract
   is tools/scenes/sizepolicy.steps.

   ALL FOUR CANVASES GROW, which is the only reason the scene can see
   anything: an ungrown canvas is its natural size, so its track IS its
   viewbox and every policy agrees.

   EVERY FIGURE IS DRAWN IN FRACTIONS OF THE BOX IT IS HANDED, which is
   what lets one frozen expectation serve four different tracks. -}

import KayaApp

-- The declared box of the two CONSTANT-mode canvases. A `scale` canvas
-- keeps drawing in it at any size and a `fixed` one refuses to leave it,
-- so it is the one number the two of them disagree about.
box :: Viewbox
box = Viewbox 300 120

-- An axis-aligned rectangle at l..r and t..b as FRACTIONS of the box,
-- filled with one paint role.
panel :: Viewbox -> Double -> Double -> Double -> Double -> Paint -> [DrawOp]
panel (Viewbox w h) l t r b paint =
  [ moveTo (l * w) (t * h),
    lineTo (r * w) (t * h),
    lineTo (r * w) (b * h),
    lineTo (l * w) (b * h),
    close,
    fill paint Nonzero
  ]

-- The figure the three drawing canvases share: a ground panel inset a
-- twentieth of the WIDTH with a translucent series panel over its middle
-- half. The centre probe point is opaque, which is what `expect_ink`
-- rests on.
figure :: Viewbox -> [DrawOp]
figure b = panel b 0.05 0 0.95 1 Ground ++ panel b 0.25 0 0.75 1 SeriesFill

-- The animating canvas's bar, whose RIGHT EDGE is the frame number: 35
-- hundredths plus ten per frame, so the scene's two expectations pin
-- exactly which frames were driven.
bar :: Viewbox -> Int -> [DrawOp]
bar b frame = panel b 0.25 0 (0.35 + 0.10 * fromIntegral frame) 1 Axis

-- Seconds back to the frame the harness drove. The guest reads the time
-- it was HANDED and never a clock of its own (§15.4).
frameOf :: Double -> Int
frameOf time = max 0 (round (time * 60))

main :: IO ()
main = kayaMain $ \app -> do
  (live, clock) <- buildTx app $ do
    window 0 [WTitle "sizepolicy", WSize 480 420]
    -- SCALE, the default: nothing is declared, and the core
    -- re-rasterizes this same display list at whatever track the column
    -- hands over, fitted uniformly and centred.
    fit <- canvas box (figure box) [Grow 1, A11yId "fit", A11yLabel "Scaled panel"]
    -- FIXED: the one true property. This one draws at the box whatever
    -- the column does with it, and the backend blits it 1:1.
    mark <- canvas box (figure box) [Grow 1, A11yId "mark", A11yLabel "Fixed mark"]
    fixed mark
    -- REDRAW and TICK declare NO drawing here: the registered function
    -- is the drawing, and the viewbox it is written in is the size the
    -- core hands over.
    live <- canvas box [] [Grow 1, A11yId "live", A11yLabel "Redrawn panel"]
    clock <- canvas box [] [Grow 1, A11yId "clock", A11yLabel "Animated bar"]
    root <- column [pure fit, pure mark, pure live, pure clock]
    mount root
    return (live, clock)
  onDraw app live figure
  onTick app clock (\size time -> bar size (frameOf time))
