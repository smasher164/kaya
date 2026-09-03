-- The panes scene, Haskell port — guests/rust/panes.rs,
-- tools/scenes/panes.steps.

import Data.Word (Word64)
import KayaApp
import KayaWire (Value (..))

contentId, detailId :: Word64
contentId = 7
detailId = 8

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    window 0 [WTitle "panes", WPanes 3]
    caption <- signal (VStr "root pane")
    root <-
      column
        []
        [ -- Authored ids so the REAL-TREE read can address these: an
          -- index read passes whether or not anything reached the
          -- screen.
          labelBound caption [A11yId "root"], -- label#0
          buttonOn
            "open content"
            ( buildTx app $ do
                pushEntry contentId [ETitle "content"]
                inner <- signal (VStr "content pane")
                pane <-
                  column
                    []
                    [ labelBound inner [A11yId "content"], -- label#1
                      buttonOn
                        "open detail"
                        ( buildTx app $ do
                            pushEntry detailId [ETitle "detail"]
                            leaf <- signal (VStr "detail pane")
                            deep <- column [] [labelBound leaf [A11yId "detail"]] -- label#last
                            mountIn detailId deep
                        )
                        [] -- button#1
                    ]
                mountIn contentId pane
            )
            [] -- button#0
        ]
    mount root
