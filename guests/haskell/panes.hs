{-# LANGUAGE OverloadedStrings #-}

-- The panes scene, Haskell port — guests/rust/panes.rs,
-- tools/scenes/panes.steps.

import Data.Word (Word64)
import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

contentId, detailId :: Word64
contentId = 7
detailId = 8

main :: IO ()
main = kayaMain $ \app -> do
  buildTx app $ do
    window primary [WTitle "panes", WPanes 3]
    caption <- signal (T.pack "root pane")
    root <-
      column
        []
        [ -- Authored ids so the REAL-TREE read can address these: an
          -- index read passes whether or not anything reached the
          -- screen.
          labelBound caption [A11yId ("root" :: Text)], -- label#0
          buttonOn
            "open content"
            ( buildTx app $ do
                pushEntry contentId [ETitle "content"]
                inner <- signal (T.pack "content pane")
                pane <-
                  column
                    []
                    [ labelBound inner [A11yId ("content" :: Text)], -- label#1
                      buttonOn
                        "open detail"
                        ( buildTx app $ do
                            pushEntry detailId [ETitle "detail"]
                            leaf <- signal (T.pack "detail pane")
                            deep <- column [] [labelBound leaf [A11yId ("detail" :: Text)]] -- label#last
                            mountIn detailId deep
                        )
                        [] -- button#1
                    ]
                mountIn contentId pane
            )
            [] -- button#0
        ]
    mount root
