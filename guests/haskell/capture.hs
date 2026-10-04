{-# LANGUAGE OverloadedStrings #-}

-- The capture, Haskell port — guests/rust/capture.rs,
-- tools/scenes/capture.steps and capture_denied.steps, docs/capture-plan.md.

import Control.Concurrent.MVar (modifyMVar_, newMVar)
import Data.IORef (atomicModifyIORef', newIORef)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T

import KayaApp

camera1, camera2, microphone1, microphone2 :: Text
camera1 = "kaya-synthetic-camera-1"
camera2 = "kaya-synthetic-camera-2"
microphone1 = "kaya-synthetic-microphone-1"
microphone2 = "kaya-synthetic-microphone-2"

stateLine :: CaptureReading -> Text
stateLine r = case r.state of
  CaptureRunning -> "running " <> tshow r.width <> "x" <> tshow r.height <> "@" <> tshow r.frameRate
  CaptureFailed -> "failed " <> maybe "" captureFailureName r.failure
  CaptureInterrupted -> "interrupted " <> maybe "" captureInterruptionName r.interruption
  other -> captureStateName other

evidence :: Maybe (Int, Int) -> Maybe Int -> Text
evidence frames chunk =
  maybe "app frames none" (\(w, h) -> "app frames " <> tshow w <> "x" <> tshow h) frames
    <> ", "
    <> maybe "app chunks none" (\n -> "app chunks of " <> tshow n) chunk

deviceLine :: CaptureDevice -> Text
deviceLine d =
  captureKindName d.kind <> " " <> d.id
    <> (if d.kind == Camera then " " <> cameraFacingName d.facing else "")
    <> (if d.preferred then " preferred" else "")

main :: IO ()
main = kayaMain $ \app -> do
  (labels, call, missing) <- buildTx app $ do
    window primary [WTitle "capture", WSize 520 640]
    labels <- mapM signalText ["devices", "permissions", "idle", evidence Nothing Nothing, "idle"]
    call <- capture [CaptureCameraIs camera1, CaptureMicrophoneIs microphone1, CaptureSizeIs 600 400, CaptureFrameRateIs 30]
    missing <- capture [CaptureCameraIs "no-such-camera"]
    selfView <- videoCapture call [A11yLabel "Self view"] -- video#0
    root <-
      column
        ( map labelBound labels -- label#0..#4
            ++ [ row
                   [Wrap True]
                   [ buttonOn "Ask camera" (submitTx app (requestPermission Camera)), -- button#0
                     buttonOn "Start" (submitTx app (startCapture call)),
                     buttonOn "Switch" $
                       submitTx app $ do
                         captureCamera call (Just camera2)
                         captureMicrophone call (Just microphone2)
                         captureSize call 1280 720
                         captureFrameRate call 15,
                     buttonOn "Mute" (submitTx app (captureMuted call True)),
                     buttonOn "Camera off" (submitTx app (captureCamera call Nothing)),
                     buttonOn "Stop" (submitTx app (stopCapture call)),
                     buttonOn "Open missing" (submitTx app (startCapture missing)), -- button#6
                     buttonOn "Wide cover" $ -- button#7
                       submitTx app $ do
                         setAspect selfView 16 9
                         setFit selfView FitCover,
                     buttonOn "Wide contain" (submitTx app (setFit selfView FitContain)) -- button#8
                   ],
                 pure selfView
               ]
        )
    mount root
    watchCaptureDevices True
    return (labels, call, missing)
  let label i = labels !! i
  onCaptureDevices app $ \devices ->
    submitTx app (writeSignal (label 0) (T.intercalate "; " (map deviceLine devices)))
  onPermission app $ \_ _ -> do
    camera <- permission app Camera
    microphone <- permission app Microphone
    submitTx app $
      writeSignal (label 1) ("camera " <> permissionName camera <> ", microphone " <> permissionName microphone)
  onCaptureState app call $ \r -> submitTx app (writeSignal (label 2) (stateLine r))
  onCaptureState app missing $ \r -> submitTx app (writeSignal (label 4) (stateLine r))

  -- The app's own code on kaya's capture thread: it checks what it was
  -- handed and posts what it saw, as a call's encoder would read it.
  seen <- newMVar (Nothing, Nothing)
  let shown = label 3
  onCaptureFrame app call $ \f -> do
    let whole =
          BS.length f.y >= f.yStride * f.height
            && BS.length f.uv >= f.uvStride * ((f.height + 1) `div` 2)
            && f.yStride >= f.width
            && f.uvStride >= f.width
        size = if whole then Just (f.width, f.height) else Nothing
    modifyMVar_ seen $ \(frames, chunk) ->
      if frames /= size
        then do
          post app (submitTx app (writeSignal shown (evidence size chunk)))
          return (size, chunk)
        else return (frames, chunk)
  posted <- newIORef False
  onCaptureSamples app call $ \chunk _at -> do
    already <- atomicModifyIORef' posted (\p -> (True, p))
    if already
      then return ()
      else modifyMVar_ seen $ \(frames, _) -> do
        let n = Just (length chunk)
        post app (submitTx app (writeSignal shown (evidence frames n)))
        return (frames, n)
