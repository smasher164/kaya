{-# LANGUAGE OverloadedStrings #-}

-- The background scene, Haskell port — guests/rust/background.rs,
-- tools/scenes/background.steps.

import Control.Concurrent (forkIO, newEmptyMVar, takeMVar, tryPutMVar)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  released <- newEmptyMVar
  postedRef <- newIORef ""
  nestedRef <- newIORef ""

  _ <- buildTx app $ do
    window primary [WTitle "background"]
    status <- signal (T.pack "idle")
    alive <- signal (T.pack "-")
    detail <- signal (T.pack "-")

    root <-
      column
        []
        [ labelBound status [A11yId ("status" :: Text)], -- label#0
          labelBound alive [A11yId ("alive" :: Text)], -- label#1
          labelBound detail [A11yId ("nested" :: Text)], -- label#2
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
                        buildTx app (writeSignal status (T.pack seen))
                    )
                    ["1", "2", "3"]
                buildTx app (writeSignal status (T.pack "working"))
            )
            [],
          buttonOn "ping" (buildTx app (writeSignal alive (T.pack "alive"))) [], -- button#1
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
                  buildTx app (writeSignal detail (T.pack seen))
                modifyIORef' nestedRef (++ "c")
                seen <- readIORef nestedRef
                buildTx app (writeSignal detail (T.pack seen))
            )
            []
        ]
    mount root
    return ()
  return ()
