{-# LANGUAGE OverloadedStrings #-}

-- The far end, Haskell port — guests/rust/farend.rs, tools/scenes/farend.steps,
-- docs/capture-plan.md §5: a surface showing the NV12 frames the app submits
-- from its own thread, and a voice output playing the samples it writes.

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar)
import qualified Data.ByteString as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Int (Int16)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)

import KayaApp

-- | What the far end sends: a flat colour at a size and a tone (0: silence).
data Sends = Sends {sRgb :: Int, sW :: Int, sH :: Int, sHz :: Double, sOn :: Bool}

-- | A flat colour as NV12, video-range BT.601.
nv12 :: Int -> Int -> Int -> (BS.ByteString, BS.ByteString)
nv12 w h rgb =
  let r = fromIntegral ((rgb `div` 65536) `mod` 256) :: Double
      g = fromIntegral ((rgb `div` 256) `mod` 256)
      b = fromIntegral (rgb `mod` 256)
      y = round (16 + 0.257 * r + 0.504 * g + 0.098 * b)
      u = round (128 - 0.148 * r - 0.291 * g + 0.439 * b)
      v = round (128 + 0.439 * r - 0.368 * g - 0.071 * b)
   in (BS.replicate (w * h) y, BS.pack (concat (replicate (w * h `div` 4) [u, v])))

-- | The peer's thread: a frame every 1/15 s and 10 ms of samples every 10 ms,
-- paced by the clock, until hung up.
runPeer :: MVar Sends -> Widget -> Voice -> MVar () -> IO ()
runPeer peer view call done = do
  start <- getMonotonicTimeNSec
  let loop sentFrames sentSamples shown phase = do
        now <- readMVar peer
        if not now.sOn
          then putMVar done ()
          else do
            t <- getMonotonicTimeNSec
            let elapsed = fromIntegral (t - start) / 1e9 :: Double
                key = (now.sRgb, now.sW, now.sH)
                planes = case shown of
                  Just (k, p) | k == key -> p
                  _ -> nv12 now.sW now.sH now.sRgb
                frameDue = fromIntegral sentFrames / 15 <= elapsed
            frames' <-
              if frameDue
                then do
                  let (y, uv) = planes
                  _ <- surfaceSubmit view (CaptureFrame now.sW now.sH y uv now.sW now.sW (fromIntegral t) 0)
                  return (sentFrames + 1)
                else return sentFrames
            let sampleDue = fromIntegral sentSamples / 48000 <= elapsed
                step = 2 * pi * now.sHz / 48000
                chunk = [if now.sHz > 0 then round (sin (phase + step * fromIntegral i) * 12000) else 0 | i <- [0 .. (479 :: Int)]] :: [Int16]
                phase' = if sampleDue then snd (properFraction ((phase + step * 480) / (2 * pi)) :: (Int, Double)) * 2 * pi else phase
            samples' <-
              if sampleDue
                then voiceWrite call chunk >> return (sentSamples + 480)
                else return sentSamples
            if frameDue || sampleDue then return () else threadDelay 5000
            loop frames' (samples' :: Word64) (Just (key, planes)) phase'
  loop (0 :: Word64) 0 Nothing 0

main :: IO ()
main = kayaMain $ \app -> do
  peer <- newMVar (Sends 0x1E5AC8 640 480 660 False)
  callRef <- newIORef Nothing
  routeRef <- newIORef Nothing
  viewRef <- newIORef Nothing
  let showRoute r = do
        mroute <- readIORef routeRef
        mapM_
          ( \route ->
              submitTx app $
                writeSignal route $ case r of
                  VoiceRouteFailed -> "voice failed"
                  VoiceRouteNone -> "voice none"
                  _ -> "voice playing"
          )
          mroute
      connect = do
        current <- readIORef callRef
        case current of
          Just _ -> return ()
          Nothing -> do
            call <- buildTx app voice
            onVoiceRoute app call (\r _ -> showRoute r)
            modifyMVar_ peer (\_ -> return (Sends 0x1E5AC8 640 480 660 True))
            done <- newEmptyMVar
            mview <- readIORef viewRef
            mapM_ (\view -> forkIO (runPeer peer view call done)) mview
            writeIORef callRef (Just (call, done))
      hangUp = do
        current <- readIORef callRef
        case current of
          Nothing -> return ()
          Just (call, done) -> do
            modifyMVar_ peer (\s -> return s {sOn = False})
            takeMVar done
            writeIORef callRef Nothing
            mroute <- readIORef routeRef
            submitTx app $ do
              releaseVoice call
              mapM_ (\route -> writeSignal route "voice none") mroute
  (route0, view0) <- buildTx app $ do
    window primary [WTitle "far end", WSize 520 640]
    route <- signalText "voice none"
    view <- surface [A11yLabel "Peer"] -- surface#0
    root <-
      column
        [ labelBound route, -- label#0
          row
            []
            [ buttonOn "Connect" connect, -- button#0
              buttonOn "Change" (modifyMVar_ peer (\s -> return s {sRgb = 0xC83C1E, sW = 1280, sH = 720, sHz = 440})),
              buttonOn "Quiet" (modifyMVar_ peer (\s -> return s {sHz = 0})),
              buttonOn "Hang up" hangUp -- button#3
            ],
          pure view
        ]
    mount root
    return (route, view)
  writeIORef routeRef (Just route0)
  writeIORef viewRef (Just view0)
