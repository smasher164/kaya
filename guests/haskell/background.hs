-- The background conformance scene, Haskell port — work off the app
-- thread, posted back (docs/background-work-plan.md).
--
-- THE SCENE'S SHAPE IS DELIBERATE: a wrong implementation must DEADLOCK
-- rather than disagree. The worker parks until a CLICK releases it, and
-- only a live app thread can process a click.
--
-- The accumulators are the guest's own state, because signals are
-- write-only. IORefs without locking: everything that touches them runs
-- on the app thread, inside a posted transaction.

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
          -- Authored so the closing AX read can address it by identifier;
          -- an index read passes for an arm that ran and drew nothing.
          labelBound detail [A11yId "nested"], -- label#2
          buttonOn
            "start" -- button#0
            ( do
                _ <- forkIO $ do
                  -- Parks until the scene clicks release; on the app
                  -- thread that click could never be processed.
                  takeMVar released
                  -- Three posts, in order. The accumulator makes this a
                  -- test of ORDER and not of which one ran last.
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
          -- Proof the app thread is still serving input while the
          -- worker is parked and has posted nothing.
          buttonOn "ping" (buildTx app (writeSignal alive (VStr "alive"))) [], -- button#1
          -- tryPutMVar, NOT putMVar: putMVar BLOCKS when the MVar is
          -- already full, so a second release click would block the APP
          -- THREAD forever. The scene clicks once and would never show
          -- it (docs/deferred.md, the blocking-release entry).
          buttonOn "release" (() <$ tryPutMVar released ()) [], -- button#2
          -- A post from INSIDE a handler QUEUES for after; it never
          -- nests. The handler appends a, posts an action appending b,
          -- appends c — so it commits "ac" and the posted action then
          -- commits "acb". Nesting can only ever produce "abc".
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
