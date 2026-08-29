{- The adaptive conformance scene, Haskell port — see
   guests/rust/adaptive.rs for the full rationale. row@dash flips by a
   HANDLER (D2's user-driven toggle); row@narrow carries the declared
   breakpoint (D3): 'StackBelow' 520 stacks it vertically while the
   window is narrower than 520 logical points and reverts crossing back.
   The byte-frozen contract is tools/scenes/adaptive.steps. -}

import Data.IORef (newIORef, readIORef, writeIORef)

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  verticalRef <- newIORef False

  buildTx app $ do
    -- Explicit size: the desktop start must sit ABOVE the breakpoint's
    -- threshold so the scene's resize half crosses it both ways.
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

    -- column#0: the control group — its axis answers the creation kind's
    -- own and never moves.
    steadyCol <- column [A11yId "steady"] [labelBound steady] -- label#2
    flipButton <- buttonOn "flip" onFlip -- button#0
    one <- signal (VStr "one")
    two <- signal (VStr "a wider two")
    -- row#1: the BREAKPOINT subject (D3) — declared data, core-evaluated.
    -- The handler never touches it.
    narrow <-
      row
        [A11yId "narrow", StackBelow 520]
        [ labelBound one, -- label#3
          labelBound two -- label#4
        ]

    root <- column [pure dash, pure steadyCol, pure flipButton, pure narrow]
    mount root
