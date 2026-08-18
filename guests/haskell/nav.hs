-- The nav conformance scene, Haskell port — the serial navigation
-- grammar. The covered root is RETAINED (status keeps taking writes
-- while covered), and a programmatic 'popEntry' does NOT echo
-- entry_popped, so the settings round's final status stays "back
-- requested". See guests/rust/nav.rs and tools/scenes/nav.steps.

import Data.Word (Word64)
import KayaApp
import KayaWire (Value (..))

detailId, settingsId :: Word64
detailId = 7
settingsId = 8

main :: IO ()
main = kayaMain $ \app -> do
  status <- buildTx app $ do
    window 0 [WTitle "nav"]
    s <- signal (VStr "at root")
    root <-
      column
        []
        [ labelBound s, -- label#0
          buttonOn "open detail" $
            buildTx app $ do
              -- The popped handler rides the push, so it can only ever
              -- mean this screen, and it retires with the one pop.
              pushEntry
                detailId
                [ ETitle "detail",
                  EOnPopped (buildTx app (writeSignal s (VStr "popped detail")))
                ]
              caption <- signal (VStr "detail pane")
              pane <- column [] [labelBound caption]
              mountIn detailId pane
              -- The covered root keeps taking writes; the pop reveals it.
              writeSignal s (VStr "pushed detail"),
          buttonOn "open settings" $
            buildTx app $ do
              -- The veto class: nothing has popped, so the app agrees
              -- itself. No entry_popped fires for that programmatic pop.
              pushEntry
                settingsId
                [ ETitle "settings",
                  EInterceptBack True,
                  EOnBack
                    ( buildTx app $ do
                        writeSignal s (VStr "back requested")
                        popEntry
                    )
                ]
              caption <- signal (VStr "settings pane")
              pane <- column [] [labelBound caption]
              mountIn settingsId pane
              writeSignal s (VStr "pushed settings")
        ]
    mount root
    return s

  _ <- return status
  return ()
