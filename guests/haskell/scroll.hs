-- The scroll conformance scene, Haskell port — the viewport grows so
-- the enclosing track constrains it (an unconstrained viewport hugs
-- its content and nothing overflows); the bottom button, reachable
-- only by scrolling, proves the scrolled-to content is live. See
-- guests/rust/scroll.rs and tools/scenes/scroll.steps.

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    windowTitle "scroll"
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
