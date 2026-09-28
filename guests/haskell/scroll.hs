{-# LANGUAGE OverloadedStrings #-}

-- The scroll scene, Haskell port — guests/rust/scroll.rs,
-- tools/scenes/scroll.steps.

import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    window primary [WTitle "scroll"]
    s <- signalText "at top"
    let mkRow i = do
          caption <- signalText ("row " <> tshow (i :: Int))
          labelBound caption
        mkCard i = do
          caption <- signalText ("card " <> tshow (i :: Int))
          labelBound caption
    root <-
      column
        []
        [ labelBound s, -- label#0
          scroll
            [Grow 1, A11yId "rows"]
            ( column
                ( map mkRow [1 .. 29]
                    ++ [ buttonOn "bottom" $ -- button#0
                           buildTx app $
                             writeSignal s "bottom clicked"
                       ]
                )
            ),
          -- A strip wider than the window, scrolled sideways
          -- (docs/hscroll-plan.md), addressed as scroll@strip.
          scroll
            [Along AxisHorizontal, A11yId "strip"]
            ( row
                []
                ( map mkCard [1 .. 19]
                    ++ [ buttonOn
                           "last card"
                           (buildTx app $ writeSignal s "last card clicked")
                           [A11yId "last"]
                       ]
                )
            )
        ]
    mount root
    return s
  return ()
