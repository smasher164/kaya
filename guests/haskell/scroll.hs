-- The scroll scene, Haskell port — guests/rust/scroll.rs,
-- tools/scenes/scroll.steps.

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    window 0 [WTitle "scroll"]
    s <- signal (VStr "at top")
    let mkRow i = do
          caption <- signal (VStr ("row " <> show (i :: Int)))
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
                             writeSignal s (VStr "bottom clicked")
                       ]
                )
            )
        ]
    mount root
    return s
  return ()
