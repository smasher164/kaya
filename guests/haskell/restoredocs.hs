{-# LANGUAGE OverloadedStrings #-}

-- The restored shape, Haskell port — guests/rust/restoredocs.rs,
-- tools/scenes/restoredocs.steps (docs/restoration-plan.md SR9): each
-- document's title and text live in its own session scope, and act two
-- recreates the documents the last launch left, takes each scope back, and
-- selects the active one.

import Control.Monad (forM, forM_, when)
import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  windows <- restoredWindows
  (documents, active) <- case [w | w <- windows, w.id == 0] of
    (w : _) -> return (w.documents, w.activeDocument)
    [] -> do
      let first = [(10, "a"), (11, "b"), (12, "c")]
      forM_ first $ \(n, title) -> (documentSession n).prefSetString "title" title
      return (map fst first, 0)
  scopes <- forM documents $ \n -> do
    let scope = documentSession n
    title <- scope.prefGetString "title" "untitled"
    body <- scope.prefGetString "body" ""
    return (n, title, body)
  buildTx app $ do
    window primary [WTitle "restoredocs", WSize 640 420]
    forM_ scopes $ \(n, title, body) -> do
      let scope = documentSession n
      addDocument n [DTitle title, DRestore n]
      caption <- signalText (title <> " body")
      let recall = do
            now <- scope.prefGetString "title" "untitled"
            submitTx app (writeSignal caption (now <> " body"))
      field' <- entryOn (scope.prefSetString "body") [A11yId ("body-" <> title)]
      setText field' body
      root <-
        column
          [ labelBound caption [A11yId ("caption-" <> title)],
            pure field',
            buttonOn "recall" recall [A11yId ("recall-" <> title)]
          ]
      mountIn n root
    when (active /= 0) $ selectDocument active
