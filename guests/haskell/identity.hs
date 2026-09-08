-- The identity scene, Haskell port — guests/rust/identity.rs,
-- tools/scenes/identity.steps.

import Control.Monad (when)
import Data.IORef (newIORef, readIORef, writeIORef)

import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  draftRef <- newIORef ""
  caps <- capabilities
  buildTx app $ do
    -- BEFORE THE FIRST MOUNT, per the declared-once wall. NO ARGUMENTS:
    -- the name, the mark and the id are the manifest's
    -- (docs/tasks-s3-plan.md N4).
    appIdentity
    -- ONE PROMOTED COMMAND, and not about commands: Windows mints its custom
    -- caption from the first promotion, taking the system icon with it.
    window
      0
      [ WTitle "identity",
        WSize 480 360,
        WMenus [menu "File" [] [item "Save" [ISymbol SymbolDone, IPrimary True]]]
      ]

    heading <- signal (VStr "identity")
    status <- signal (VStr "ready")

    root <-
      column
        []
        [ labelBound heading, -- label#0
          labelBound status, -- label#1
          entryOn (writeIORef draftRef), -- entry#0
          buttonOn -- button#0
            "Go"
            ( do
                draft <- readIORef draftRef
                submitTx app (writeSignal status (VStr ("clicked " ++ draft)))
            )
        ]
    mount root

    -- No title at all rather than an empty one: an empty string is a title an
    -- app WROTE.
    when (auxWindows caps) $ do
      createWindow 1 [WSize 360 240]
      caption <- signal (VStr "no title of its own")
      aux <- column [] [labelBound caption] -- label#2
      mountIn 1 aux
