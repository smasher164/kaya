{-# LANGUAGE OverloadedStrings #-}

-- The split scene, Haskell port — guests/rust/split.rs,
-- tools/scenes/split.steps.

import Data.Word (Word64)
import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

detailId :: Word64
detailId = 7

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    window primary [WTitle "split", WPanes 2]
    s <- signal (T.pack "list pane")
    root <-
      column
        []
        [ -- Authored ids so the REAL-TREE read can address these: an
          -- index read passes whether or not anything reached the
          -- screen.
          labelBound s [A11yId ("list" :: Text)], -- label#0
          buttonOn "open detail"
            ( buildTx app $ do
                pushEntry
                  detailId
                  [ ETitle "detail",
                    EOnPopped (buildTx app (writeSignal s (T.pack "popped detail")))
                  ]
                caption <- signal (T.pack "detail pane")
                pane <- column [] [labelBound caption [A11yId ("detail" :: Text)]]
                mountIn detailId pane
            )
            []
        ]
    mount root
    return s
  return ()
