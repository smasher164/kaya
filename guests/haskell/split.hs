-- The split scene, Haskell port — guests/rust/split.rs,
-- tools/scenes/split.steps.

import Data.Word (Word64)
import KayaApp
import KayaWire (Value (..))

detailId :: Word64
detailId = 7

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    window 0 [WTitle "split", WPanes 2]
    s <- signal (VStr "list pane")
    root <-
      column
        []
        [ -- Authored ids so the REAL-TREE read can address these: an
          -- index read passes whether or not anything reached the
          -- screen.
          labelBound s [A11yId "list"], -- label#0
          buttonOn "open detail"
            ( buildTx app $ do
                pushEntry
                  detailId
                  [ ETitle "detail",
                    EOnPopped (buildTx app (writeSignal s (VStr "popped detail")))
                  ]
                caption <- signal (VStr "detail pane")
                pane <- column [] [labelBound caption [A11yId "detail"]]
                mountIn detailId pane
            )
            []
        ]
    mount root
    return s
  return ()
