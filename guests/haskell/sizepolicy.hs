-- The sizepolicy scene, Haskell port — guests/rust/sizepolicy.rs,
-- tools/scenes/sizepolicy.steps.

import KayaApp

-- The declared box of the two CONSTANT-mode canvases: the one number `scale`
-- and `fixed` disagree about.
box :: Viewbox
box = Viewbox 300 120

-- A rectangle at l..r and t..b as FRACTIONS of the box.
panel :: Viewbox -> Double -> Double -> Double -> Double -> Paint -> [DrawOp]
panel (Viewbox w h) l t r b paint =
  [ moveTo (l * w) (t * h),
    lineTo (r * w) (t * h),
    lineTo (r * w) (b * h),
    lineTo (l * w) (b * h),
    close,
    fill paint Nonzero
  ]

-- The figure the three drawing canvases share. The centre probe point is
-- opaque, which is what `expect_ink` rests on.
figure :: Viewbox -> [DrawOp]
figure b = panel b 0.05 0 0.95 1 Ground ++ panel b 0.25 0 0.75 1 SeriesFill

-- The bar whose RIGHT EDGE is the frame number; the scene pins exact frames.
bar :: Viewbox -> Int -> [DrawOp]
bar b frame = panel b 0.25 0 (0.35 + 0.10 * fromIntegral frame) 1 Axis

-- Seconds back to the frame the harness drove, off the time the guest was
-- HANDED and never a clock of its own (§15.4).
frameOf :: Double -> Int
frameOf time = max 0 (round (time * 60))

main :: IO ()
main = kayaMain $ \app -> do
  (live, clock) <- buildTx app $ do
    window 0 [WTitle "sizepolicy", WSize 480 420]
    -- SCALE (the default)
    fit <- canvas box (figure box) [Grow 1, A11yId "fit", A11yLabel "Scaled panel"]
    -- FIXED
    mark <- canvas box (figure box) [Grow 1, A11yId "mark", A11yLabel "Fixed mark"]
    fixed mark
    -- REDRAW and TICK declare NO drawing here: the function is the drawing.
    live <- canvas box [] [Grow 1, A11yId "live", A11yLabel "Redrawn panel"]
    clock <- canvas box [] [Grow 1, A11yId "clock", A11yLabel "Animated bar"]
    root <- column [pure fit, pure mark, pure live, pure clock]
    mount root
    return (live, clock)
  onDraw app live figure
  onTick app clock (\size time -> bar size (frameOf time))
