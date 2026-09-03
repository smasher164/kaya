-- The progress scene, Haskell port — guests/rust/progress.rs,
-- tools/scenes/progress.steps.

import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    window 0 [WTitle "progress"]
    root <-
      column
        []
        [ progress 0.25, -- progress#0
          progressIndeterminate -- progress#1
        ]
    mount root
    return ()
  return ()
