-- The adaptive scene, Haskell port — guests/rust/adaptive.rs,
-- tools/scenes/adaptive.steps.

import Data.IORef (newIORef, readIORef, writeIORef)

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  verticalRef <- newIORef False

  buildTx app $ do
    -- Above the breakpoint, so the resize half crosses it both ways.
    window 0 [WTitle "adaptive", WSize 900 600]
    alpha <- signal (VStr "alpha")
    longer <- signal (VStr "a longer label")
    steady <- signal (VStr "steady")

    -- row#0: the flip subject.
    dash <-
      row
        [A11yId "dash"]
        [ labelBound alpha, -- label#0
          labelBound longer -- label#1
        ]
    let onFlip = do
          vertical <- not <$> readIORef verticalRef
          writeIORef verticalRef vertical
          submitTx app $
            setAxis dash (if vertical then AxisVertical else AxisHorizontal)

    -- column#0: the control group, whose axis never moves.
    steadyCol <- column [A11yId "steady"] [labelBound steady] -- label#2
    flipButton <- buttonOn "flip" onFlip -- button#0
    one <- signal (VStr "one")
    two <- signal (VStr "a wider two")
    -- row#1: the breakpoint subject, which no handler touches.
    narrow <-
      row
        [A11yId "narrow", StackWhen Compact]
        [ labelBound one, -- label#3
          labelBound two -- label#4
        ]

    root <- column [pure dash, pure steadyCol, pure flipButton, pure narrow]
    mount root
