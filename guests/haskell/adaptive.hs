{-# LANGUAGE OverloadedStrings #-}

-- The adaptive scene, Haskell port — guests/rust/adaptive.rs,
-- tools/scenes/adaptive.steps.

import Data.IORef (newIORef, readIORef, writeIORef)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  verticalRef <- newIORef False

  buildTx app $ do
    -- Above the breakpoint, so the resize half crosses it both ways.
    window primary [WTitle "adaptive", WSize 900 600]
    alpha <- signal (T.pack "alpha")
    longer <- signal (T.pack "a longer label")
    steady <- signal (T.pack "steady")

    -- row#0: the flip subject.
    dash <-
      row
        [A11yId ("dash" :: Text)]
        [ labelBound alpha, -- label#0
          labelBound longer -- label#1
        ]
    let onFlip = do
          vertical <- not <$> readIORef verticalRef
          writeIORef verticalRef vertical
          submitTx app $
            setAxis dash (if vertical then AxisVertical else AxisHorizontal)

    -- column#0: the control group, whose axis never moves.
    steadyCol <- column [A11yId ("steady" :: Text)] [labelBound steady] -- label#2
    flipButton <- buttonOn "flip" onFlip -- button#0
    one <- signal (T.pack "one")
    two <- signal (T.pack "a wider two")
    -- row#1: the breakpoint subject, which no handler touches.
    narrow <-
      row
        [A11yId ("narrow" :: Text), StackWhen Compact]
        [ labelBound one, -- label#3
          labelBound two -- label#4
        ]

    -- grid@sheet: three columns regular, one compact (D6.2).
    cells <- mapM signal (["c1", "c2", "c3", "c4", "c5", "c6"] :: [Text])
    sheet <- grid 3 (map labelBound cells) -- label#5..#10
    setA11yId sheet "sheet"
    columnsWhen sheet Compact 1

    -- grid@fit: no count, a 240-point floor, the WIDTH decides
    -- (docs/layout-knobs-plan.md §3). Buttons, so the label ordinals
    -- above stay put.
    fit <- grid 3 [button "f1", button "f2", button "f3"] -- button#1..#3
    setColumnsAuto fit 240
    setA11yId fit "fit"

    root <- column [pure dash, pure steadyCol, pure flipButton, pure narrow, pure sheet, pure fit]
    mount root
