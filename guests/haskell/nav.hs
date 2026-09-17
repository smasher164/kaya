{-# LANGUAGE OverloadedStrings #-}

-- The nav scene, Haskell port — guests/rust/nav.rs, tools/scenes/nav.steps.

import Data.Word (Word64)
import qualified Data.Text as T
import KayaApp

detailId, settingsId :: Word64
detailId = 7
settingsId = 8

main :: IO ()
main = kayaMain $ \app -> do
  status <- buildTx app $ do
    window primary [WTitle "nav"]
    s <- signal (T.pack "at root")
    root <-
      column
        []
        [ labelBound s, -- label#0
          buttonOn "open detail" $
            buildTx app $ do
              pushEntry
                detailId
                [ ETitle "detail",
                  EOnPopped (buildTx app (writeSignal s (T.pack "popped detail")))
                ]
              caption <- signal (T.pack "detail pane")
              pane <- column [] [labelBound caption]
              mountIn detailId pane
              writeSignal s (T.pack "pushed detail"),
          buttonOn "open settings" $
            buildTx app $ do
              -- Nothing has popped, so no entry_popped follows this pop.
              pushEntry
                settingsId
                [ ETitle "settings",
                  EInterceptBack True,
                  EOnBack
                    ( buildTx app $ do
                        writeSignal s (T.pack "back requested")
                        popEntry
                    )
                ]
              caption <- signal (T.pack "settings pane")
              pane <- column [] [labelBound caption]
              mountIn settingsId pane
              writeSignal s (T.pack "pushed settings")
        ]
    mount root
    return s

  _ <- return status
  return ()
