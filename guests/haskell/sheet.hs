{-# LANGUAGE OverloadedStrings #-}

-- The sheet scene, Haskell port — guests/rust/sheet.rs, tools/scenes/sheet.steps.

import Data.Word (Word64)
import KayaApp

taskId, detailsId :: Word64
taskId = 11
detailsId = 12

main :: IO ()
main = kayaMain $ \app -> do
  status <- buildTx app $ do
    window primary [WTitle "sheet"]
    s <- signalText "closed"
    draft <- signalText "draft: none"
    let openTask armed = buildTx app $ do
          presentSheet
            taskId
            ( [ ShTitle "new task",
                ShDetent DetentMedium,
                ShInterceptDismiss armed,
                ShOnDismissed (buildTx app (writeSignal s "dismissed"))
              ]
                -- Nothing has gone when the request fires; the app keeps
                -- the sheet up and says so.
                ++ [ ShOnDismissRequested (buildTx app (writeSignal s "dismiss requested"))
                   | armed
                   ]
            )
          caption <- signalText "what needs doing?"
          body <-
            column
              []
              [ labelBound caption, -- label#1
                entryOn (\text -> buildTx app (writeSignal draft ("draft: " <> text))), -- entry#0
                labelBound draft, -- label#2
                buttonOn "details" $
                  buildTx app $ do
                    presentSheetOver
                      taskId
                      detailsId
                      [ ShTitle "details",
                        ShOnDismissed (buildTx app (writeSignal s "details dismissed"))
                      ]
                    more <- signalText "more about it"
                    pane <- column [] [labelBound more]
                    mountIn detailsId pane
                    writeSignal s "details open",
                buttonOn "done" $
                  buildTx app $ do
                    -- Programmatic: no sheet_dismissed follows, so "done" stays.
                    dismissSheet taskId
                    writeSignal s "done"
              ]
          mountIn taskId body
          writeSignal s "open"
          writeSignal draft "draft: none"
    root <-
      column
        []
        [ labelBound s, -- label#0
          buttonOn "new task" (openTask False),
          buttonOn "new task, armed" (openTask True)
        ]
    mount root
    return s

  _ <- return status
  return ()
