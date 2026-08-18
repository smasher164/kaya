-- The split conformance scene, Haskell port — adaptive list-detail. The
-- guest asks for the presentation ONCE and does nothing adaptive ever
-- again; there is no prop for WHICH way it presents.
--
-- TWO scripts drive this ONE app: split resizes and names the
-- presentation on each side, listdetail asserts the bare invariant at
-- whatever width its host gives. See guests/rust/split.rs,
-- tools/scenes/split.steps and tools/scenes/listdetail.steps.

import Data.Word (Word64)
import KayaApp
import KayaWire (Value (..))

detailId :: Word64
detailId = 7

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    -- The one adaptive declaration in the whole guest.
    window 0 [WTitle "split", WListDetail True]
    s <- signal (VStr "list pane")
    root <-
      column
        []
        [ -- Authored ids so the REAL-TREE read can address these: an
          -- index read passes whether or not anything reached the screen,
          -- which once let a non-rendering split arm look green.
          labelBound s [A11yId "list"], -- label#0
          buttonOn "open detail"
            ( buildTx app $ do
                pushEntry
                  detailId
                  [ ETitle "detail",
                    -- Retention: the base root takes this write while
                    -- the detail is up.
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
