-- The grid conformance scene, Haskell port. See
-- guests/rust/grid.rs and tools/scenes/grid.steps.

import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  _ <- buildTx app $ do
    windowTitle "grid"
    root <-
      column
        []
        [ gridOf 2
            [ labelText "Name:", -- label#0
              labelText "Ada Lovelace", -- label#1
              labelText "Role:", -- label#2
              labelText "Engine programmer" -- label#3
            ],
          row
            [Grow 1]
            [ buttonOn "left" (return ()), -- button#0
              spacer,
              buttonOn "right" (return ()) -- button#1
            ]
        ]
    mount root
    return ()
  return ()
