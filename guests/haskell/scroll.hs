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
    root <-
      column
        []
        [ labelBound s, -- label#0
          scroll
            [Grow 1]
            ( column
                ( map mkRow [1 .. 29]
                    ++ [ buttonOn "bottom" $ -- button#0
                           buildTx app $
                             writeSignal s "bottom clicked"
                       ]
                )
            )
        ]
    mount root
    return s
  return ()
