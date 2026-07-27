-- The split conformance scene, Haskell port — adaptive list-detail via
-- the config-list spelling: @window 0 [WTitle "split", WListDetail
-- True]@, @pushEntry 7 [ETitle "detail", EOnPopped ...]@ plus 'mountIn'
-- presents the detail.
--
-- The guest asks for the presentation ONCE and then does nothing
-- adaptive ever again. Everything after that is the platform
-- re-deciding as the size class changes: an app does not write two
-- layouts and pick one, and there is no prop for WHICH way it
-- presents. Nothing here is split-specific except that one prop.
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
          -- index read passes whether or not anything reached the
          -- screen, which is the gap that let a non-rendering split
          -- arm look green.
          labelBound s [A11yId "list"], -- label#0
          buttonOn "open detail"
            ( buildTx app $ do
                -- The popped handler rides the push, per-entry — the
                -- showAlert precedent, unchanged by the split.
                pushEntry
                  detailId
                  [ ETitle "detail",
                    -- Retention: the base root took this write while
                    -- the detail was up, on a regular window where it
                    -- was VISIBLE the whole time.
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
