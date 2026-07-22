-- The progress conformance scene, Haskell port. See
-- guests/rust/progress.rs and tools/scenes/progress.steps.

import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    windowTitle "progress"
    root <-
      column
        []
        [ progress 0.25, -- progress#0
          progressIndeterminate -- progress#1
        ]
    mount root
    return ()
  return ()
