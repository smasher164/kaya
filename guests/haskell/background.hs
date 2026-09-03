-- The background scene, Haskell port — guests/rust/background.rs,
-- tools/scenes/background.steps.

import Control.Concurrent (forkIO, newEmptyMVar, takeMVar, tryPutMVar)
import Data.IORef (modifyIORef', newIORef, readIORef)
import KayaApp
import KayaWire (Value (..))

main :: IO ()
main = kayaMain $ \app -> do
  released <- newEmptyMVar
  postedRef <- newIORef ""
  nestedRef <- newIORef ""

  _ <- buildTx app $ do
    window 0 [WTitle "background"]
    status <- signal (VStr "idle")
    alive <- signal (VStr "-")
    detail <- signal (VStr "-")

    root <-
      column
        []
        [ labelBound status [A11yId "status"], -- label#0
          labelBound alive [A11yId "alive"], -- label#1
          labelBound detail [A11yId "nested"], -- label#2
          buttonOn
            "start" -- button#0
            ( do
                _ <- forkIO $ do
                  -- Parks until the scene clicks release.
                  takeMVar released
                  mapM_
                    ( \step -> post app $ do
                        modifyIORef' postedRef (++ step)
                        seen <- readIORef postedRef
                        buildTx app (writeSignal status (VStr seen))
                    )
                    ["1", "2", "3"]
                buildTx app (writeSignal status (VStr "working"))
            )
            [],
          buttonOn "ping" (buildTx app (writeSignal alive (VStr "alive"))) [], -- button#1
          -- tryPutMVar, NOT putMVar: putMVar BLOCKS on a full MVar, so a
          -- second release click would wedge the APP THREAD (docs/deferred.md,
          -- the blocking-release entry).
          buttonOn "release" (() <$ tryPutMVar released ()) [], -- button#2
          buttonOn
            "nest" -- button#3
            ( do
                modifyIORef' nestedRef (++ "a")
                post app $ do
                  modifyIORef' nestedRef (++ "b")
                  seen <- readIORef nestedRef
                  buildTx app (writeSignal detail (VStr seen))
                modifyIORef' nestedRef (++ "c")
                seen <- readIORef nestedRef
                buildTx app (writeSignal detail (VStr seen))
            )
            []
        ]
    mount root
    return ()
  return ()
