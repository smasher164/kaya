-- The nav conformance scene, Haskell port — the serial navigation
-- grammar via the config-list spelling: @pushEntry 7 [ETitle
-- "detail"]@ plus 'mountIn' presents each screen, 'onEntryPopped'
-- hears the user's native pop, and 'onBackRequested' answers the
-- intercept_back veto with 'popEntry'. The covered root is RETAINED
-- (status keeps taking writes while covered); a programmatic
-- 'popEntry' does not echo entry_popped, so the settings round's
-- final status stays "back requested". See guests/rust/nav.rs and
-- tools/scenes/nav.steps.

import Data.Word (Word64)
import KayaApp
import KayaWire (Value (..))

detailId, settingsId :: Word64
detailId = 7
settingsId = 8

main :: IO ()
main = kayaMain $ \app -> do
  status <- buildTx app $ do
    windowTitle "nav"
    s <- signal (VStr "at root")
    root <-
      column
        []
        [ labelBound s, -- label#0
          buttonOn "open detail" $
            buildTx app $ do
              -- The popped handler rides the push (per-entry, the
              -- showAlert precedent): it can only ever mean the
              -- detail screen popped, and it retires with the one
              -- pop.
              pushEntry
                detailId
                [ ETitle "detail",
                  EOnPopped (buildTx app (writeSignal s (VStr "popped detail")))
                ]
              caption <- signal (VStr "detail pane")
              pane <- column [] [labelBound caption]
              mountIn detailId pane
              -- The covered root keeps taking writes — retention,
              -- observable after the pop.
              writeSignal s (VStr "pushed detail"),
          buttonOn "open settings" $
            buildTx app $ do
              -- The veto class: nothing has popped; agree and
              -- confirm. No entry_popped will fire — the write is
              -- the round's final status.
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

  -- The handlers ride each push above; nothing app-global remains.
  _ <- return status
  return ()
