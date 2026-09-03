-- The nav scene, Haskell port — guests/rust/nav.rs, tools/scenes/nav.steps.

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
              pushEntry
                detailId
                [ ETitle "detail",
                  EOnPopped (buildTx app (writeSignal s (VStr "popped detail")))
                ]
              caption <- signal (VStr "detail pane")
              pane <- column [] [labelBound caption]
              mountIn detailId pane
              writeSignal s (VStr "pushed detail"),
          buttonOn "open settings" $
            buildTx app $ do
              -- Nothing has popped, so no entry_popped follows this pop.
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
