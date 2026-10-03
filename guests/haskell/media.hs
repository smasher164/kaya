{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE NoFieldSelectors #-}

-- The media suite, Haskell port — guests/rust/media.rs,
-- tools/scenes/media_*.steps, docs/media-plan.md §7a, §7b.

import Control.Monad (forM_, when)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (sort, sortOn)
import Data.Maybe (fromMaybe)
import GHC.Generics (Generic)
import System.Environment (lookupEnv)
import Text.Printf (printf)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp hiding (Clip (..))

data Item = Item Text MediaSource Text Text

local :: Text -> Text -> Text -> Item
local n = Item n (mediaAsset ("media/" <> n))

served :: Text -> Text -> Text -> Text -> Item
served base n = Item n (mediaUrl (base <> "/" <> n))

h264, hevc, av1 :: Text
h264 = "avc1.64000b, mp4a.40.2"
hevc = "hvc1.1.6.L60.90, mp4a.40.2"
av1 = "av01.0.00M.08, mp4a.40.2"

formats :: [Item]
formats =
  [ local "h264_aac.mp4" "video/mp4" h264,
    local "hevc_aac.mp4" "video/mp4" hevc,
    local "hevc_aac.mov" "video/quicktime" hevc,
    local "vp9_opus.webm" "video/webm" "vp09.00.10.08, opus",
    local "vp9_aac.mp4" "video/mp4" "vp09.00.10.08, mp4a.40.2",
    local "av1_aac.mp4" "video/mp4" av1,
    local "av1_opus.webm" "video/webm" "av01.0.00M.08, opus",
    local "tone.mp3" "audio/mpeg" "",
    local "tone.m4a" "audio/mp4" "mp4a.40.2",
    local "tone.ogg" "audio/ogg" "opus",
    local "tone_opus.webm" "audio/webm" "opus",
    local "tone.flac" "audio/flac" "",
    local "tone.wav" "audio/wav" ""
  ]

mediaUrlOf :: String -> IO Text
mediaUrlOf why = maybe (error why) T.pack <$> lookupEnv "KAYA_MEDIA_URL"

-- | The local server's items, and the three failures: a 404, a local
-- file that is not there, and a port nothing listens on.
delivery :: IO [Item]
delivery = do
  base <-
    mediaUrlOf
      "kaya: the media_delivery scene reads KAYA_MEDIA_URL, the local server the lane \
      \starts (tools/lib/media_server.py); a hand run goes through tools/run-leg.py"
  let (host, port) = T.breakOnEnd ":" base
      refused = if T.null host || T.null port then base else host <> "9"
  return
    [ served base "h264_aac.mp4" "video/mp4" h264,
      served base "hls_fmp4.m3u8" "application/vnd.apple.mpegurl" "",
      served base "hls_mpegts.m3u8" "application/vnd.apple.mpegurl" "",
      served base "dash.mpd" "application/dash+xml" "",
      served base "nope.mp4" "video/mp4" h264,
      local "missing.mp4" "video/mp4" h264,
      Item "refused.mp4" (mediaUrl (refused <> "/h264_aac.mp4")) "video/mp4" h264
    ]

yesNo :: Bool -> Text
yesNo b = if b then "yes" else "no"

formatsApp :: App -> String -> IO ()
formatsApp app scene = do
  let session = scene == "media_session"
  items <- if scene == "media_delivery" then delivery else pure formats
  atRef <- newIORef (0 :: Int)
  canRef <- newIORef False
  furthestRef <- newIORef (0 :: Int)
  nextsRef <- newIORef (0 :: Int)
  (summary, name, p) <- buildTx app $ do
    window primary [WTitle "media"]
    summary <- signalText "idle"
    name <- signalText (if session then "next 0" else "none")
    p <- player [PlayerMutedIs True, PlayerLoopIs session]
    let next = do
          i <- readIORef atRef
          case drop i items of
            Item n src mime codecs : _ -> do
              writeIORef atRef (i + 1)
              canPlay mime codecs >>= writeIORef canRef
              writeIORef furthestRef 0
              submitTx app $ do
                playerSource p src
                writeSignal name n
                writeSignal summary "loading"
            [] -> return ()
        toggle = do
          r <- playerReading app p
          submitTx app $ do
            when (r.state == PlayerIdle) $ playerSource p (mediaAsset "media/h264_aac.mp4")
            play p
    root <-
      column
        [ labelBound summary, -- label#0
          labelBound name, -- label#1
          videoShowing p [A11yId "clip", A11yLabel "Clip"], -- video#0
          buttonOn (if session then "play" else "next") (if session then toggle else next) -- button#0
        ]
    mount root
    when session $
      declareSession
        [SessionPlayer p, SessionTitle "kaya media", SessionArtist "kaya", SessionHandles [ActionNext]]
    return (summary, name, p)

  onPlayerState app p $ \s ->
    if session
      then when (s == PlayerPlaying || s == PlayerPaused) $ submitTx app (writeSignal summary (playerStateName s))
      else case s of
        PlayerReady -> submitTx app (play p)
        PlayerEnded -> do
          r <- playerReading app p
          furthest <- readIORef furthestRef
          can <- readIORef canRef
          let played =
                if furthest >= 1000 then "played past 1s" else "played to " <> T.pack (show furthest) <> "ms"
              secs = printf "%.1f" (fromIntegral r.durationMs / 1000 :: Double) :: String
          submitTx app $
            writeSignal summary $
              "ready " <> T.pack secs <> "s " <> tshow r.width <> "x" <> tshow r.height <> ", "
                <> played <> ", ended, can_play " <> yesNo can
        _ -> return ()
  onFailed app p $ \why _ -> do
    can <- readIORef canRef
    submitTx app $ writeSignal summary ("failed " <> mediaFailureName why <> ", can_play " <> yesNo can)
  onPosition app p $ \ms -> modifyIORef' furthestRef (max ms)
  onSession app $ \action -> case action of
    SessionNext -> do
      modifyIORef' nextsRef (+ 1)
      n <- readIORef nextsRef
      submitTx app $ writeSignal name ("next " <> tshow n)
    _ -> return ()

-- | One track list as a line: @audio en, fr [2]@, the selection counting
-- from 1, @-@ for none; @audio none@ for an empty list.
trackLine :: Text -> [Text] -> Maybe Int -> Text
trackLine what [] _ = what <> " none"
trackLine what tags selected =
  what <> " " <> T.intercalate ", " tags <> " [" <> maybe "-" (\i -> tshow (i + 1)) selected <> "]"

-- | media_tracks (docs/media-plan.md §3, §7a): each item's audio and
-- caption listing, a second audio track selected, the last caption track
-- selected, and the cue read at 0.5 s and 1.5 s with the player paused
-- there. The sidecar items are the suite's floor file with captions.vtt (the
-- first over h264_frames.mp4): an asset, then fetched from the local server,
-- then a 404 there.
tracksApp :: App -> IO ()
tracksApp app = do
  base <-
    mediaUrlOf
      "kaya: the media scenes that stream read KAYA_MEDIA_URL, the local server the lane \
      \starts (tools/lib/media_server.py); a hand run goes through tools/run-leg.py"
  let floorAs label = Item label (mediaAsset "media/h264_aac.mp4") "video/mp4" h264
      items =
        [ (local "h264_2audio.mp4" "video/mp4" h264, Nothing),
          (local "vp9_2audio.webm" "video/webm" "vp09.00.10.08, opus", Nothing),
          (served base "hls_fmp4.m3u8" "application/vnd.apple.mpegurl" "", Nothing),
          (served base "hls_mpegts.m3u8" "application/vnd.apple.mpegurl" "", Nothing),
          (local "h264_tx3g.mp4" "video/mp4" h264, Nothing),
          (Item "h264_frames.mp4 + captions.vtt" (mediaAsset "media/h264_frames.mp4") "video/mp4" h264, Just (mediaAsset "media/captions.vtt")),
          (floorAs "h264_aac.mp4 + http captions.vtt", Just (mediaUrl (base <> "/captions.vtt"))),
          (floorAs "h264_aac.mp4 + http nope.vtt", Just (mediaUrl (base <> "/nope.vtt")))
        ]
  atRef <- newIORef (0 :: Int)
  canRef <- newIORef False
  (summary, audio, captions, cue, p) <- buildTx app $ do
    window primary [WTitle "media tracks"]
    summary <- signalText "idle"
    name <- signalText "none"
    audio <- signalText "audio none"
    captions <- signalText "captions none"
    cue <- signalText ""
    p <- player [PlayerMutedIs True]
    let next = do
          i <- readIORef atRef
          case drop i items of
            (Item n src mime codecs, sidecar) : _ -> do
              writeIORef atRef (i + 1)
              canPlay mime codecs >>= writeIORef canRef
              submitTx app $ do
                maybe (clearCaptions p) (\s -> playerCaptions p s "en") sidecar
                playerSource p src
                writeSignal name n
                writeSignal summary "loading"
                writeSignal cue ""
            [] -> return ()
        pickCaptions = do
          t <- playerTracks app p
          let listed = length t.captions
          submitTx app $
            if listed == 0 then writeSignal cue "captions none" else selectCaptions p (Just (listed - 1))
        at ms = submitTx app $ do
          pause p
          seek p ms
    root <-
      column
        [ labelBound summary, -- label#0
          labelBound name, -- label#1
          labelBound audio, -- label#2
          labelBound captions, -- label#3
          labelBound cue, -- label#4
          videoShowing p [A11yId "clip", A11yLabel "Clip"], -- video#0
          buttonOn "next" next, -- button#0
          buttonOn "audio 2" (submitTx app (selectAudio p 1)), -- button#1
          buttonOn "captions" pickCaptions, -- button#2
          buttonOn "at 0.5s" (at 500), -- button#3
          buttonOn "at 1.5s" (at 1500), -- button#4
          buttonOn "captions off" (submitTx app (selectCaptions p Nothing)), -- button#5
          buttonOn "play" (submitTx app (seek p 0 >> play p)) -- button#6
        ]
    mount root
    return (summary, audio, captions, cue, p)

  onPlayerState app p $ \s -> when (s == PlayerReady) $ do
    can <- readIORef canRef
    submitTx app $ writeSignal summary ("ready, can_play " <> yesNo can)
  onFailed app p $ \why _ -> do
    can <- readIORef canRef
    let line = "failed " <> mediaFailureName why <> ", can_play " <> yesNo can
    submitTx app $ do
      writeSignal summary line
      writeSignal audio line
  onTracks app p $ \t -> submitTx app $ do
    writeSignal audio (trackLine "audio" t.audio t.audioSelected)
    writeSignal captions (trackLine "captions" t.captions t.captionSelected)
  onCue app p $ \text -> submitTx app (writeSignal cue text)

data Clip = Clip {name :: Text, player :: Player}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

feedRows :: Int
feedRows = 10

-- | media_feed (docs/media-plan.md §7b): a scroll of rows, each a video
-- view showing its row's own player, paused on its first frame; the first
-- and last rows' visibility in label#0 and label#1.
feedApp :: App -> IO ()
feedApp app = do
  (first, lastRow, videoNode) <- buildTx app $ do
    window primary [WTitle "media feed", WSize 420 480]
    first <- signalText "r0 out"
    lastRow <- signalText ("r" <> tshow (feedRows - 1) <> " out")
    clips <- collectionOf @Clip
    (rows, videoNode) <- forEach (recordHandle clips) $ do
      -- Realized ahead of its row so the central registration has a handle.
      v <- video (field @"player" @Clip)
      _ <- columnOf [label (field @"name" @Clip), pure v]
      return v
    root <-
      column
        [ labelBound first, -- label#0
          labelBound lastRow, -- label#1
          scroll [Grow 1] (column [pure rows])
        ]
    mount root
    forM_ [0 .. feedRows - 1] $ \i -> do
      p <- player [PlayerMutedIs True, PlayerSourceIs (mediaAsset "media/h264_aac.mp4")]
      insertRecord clips (intKey (fromIntegral i)) (Clip ("r" <> tshow i) p)
    return (first, lastRow, videoNode)

  onVisibility app videoNode $ \keys shown -> do
    let row = case keys of
          k : _ -> maybe (-1) fromIntegral (keyInt k)
          [] -> -1 :: Int
        word
          | shown >= 0.999 = "whole"
          | shown > 0 = "in"
          | otherwise = "out"
    submitTx app $ do
      when (row == 0) $ writeSignal first ("r0 " <> word)
      when (row == feedRows - 1) $ writeSignal lastRow ("r" <> tshow row <> " " <> word)

-- | The answered times as the labels spell them: each time asked, then
-- the time of the picture the platform returned, in ms.
frameLine :: Text -> [Frame] -> ReadOutcome -> Text
frameLine what frames outcome =
  T.unwords ([what] ++ [tshow f.requestedMs <> "@" <> tshow f.actualMs | f <- sortOn (.index) frames] ++ [readOutcomeName outcome])

-- | h264_frames.mp4's grey bands: frame 12 (0x505050) and frame 37
-- (0xA0A0A0) at 25 fps, its one keyframe at 0 (tools/gen-media.py).
bands :: [Int]
bands = [480, 1480]

-- | media_reader (docs/media-plan.md §8 rulings 3 and 4): a reader with no
-- player draws a filmstrip of h264_frames.mp4's exact and keyframe
-- pictures and a waveform of tone.wav's peaks beside two loaded images; a
-- read the server never finishes is cancelled and another is closed under
-- its reader; a file that is not media and a missing file fail.
readerApp :: App -> IO ()
readerApp app = do
  base <-
    mediaUrlOf
      "kaya: the media scenes that stream read KAYA_MEDIA_URL, the local server the lane \
      \starts (tools/lib/media_server.py); a hand run goes through tools/run-leg.py"
  exact <- newIORef []
  keyframe <- newIORef []
  failures <- newIORef []
  missing <- newIORef []
  cancels <- newIORef []
  trickling <- newIORef Nothing
  let stripBox = Viewbox 320 45
      waveBox = Viewbox 200 60
  (labels, strip, wave, clip, exactRead, peaksRead, ends, logo, photo) <- buildTx app $ do
    window primary [WTitle "media reader", WSize 560 560]
    labels <- mapM signalText ["exact", "keyframe", "peaks", "failures", "no track", "cancel"]
    let line i lines what outcome = do
          modifyIORef' lines (sort . ((what <> " " <> readOutcomeName outcome) :))
          joined <- T.intercalate "; " <$> readIORef lines
          submitTx app (writeSignal (labels !! i) joined)
        start = do
          (trickle, r, closing, closingRead) <- buildTx app $ do
            trickle <- openReader (mediaUrl (base <> "/trickle/h264_frames.mp4"))
            r <- readFrames trickle [0] (80, 45) Exact
            closing <- openReader (mediaUrl (base <> "/trickle/h264_aac.mp4"))
            closingRead <- readFrames closing [0] (80, 45) Exact
            writeSignal (labels !! 5) "reading"
            return (trickle, r, closing, closingRead)
          onReadDone app r (line 5 cancels "trickle")
          onReadDone app closingRead (line 5 cancels "closed")
          writeIORef trickling (Just (trickle, r, closing))
        cancel = do
          t <- readIORef trickling
          writeIORef trickling Nothing
          forM_ t $ \(trickle, r, closing) -> submitTx app $ do
            cancelRead trickle r
            closeReader closing
    strip <- canvas stripBox [] [A11yId "strip", A11yLabel "Filmstrip"]
    wave <- canvas waveBox [] [A11yId "wave", A11yLabel "Waveform"]
    root <-
      column
        ( map labelBound (take 5 labels) -- label#0..#4
            ++ [ pure strip,
                 pure wave,
                 buttonOn "start" start, -- button#0
                 buttonOn "cancel" cancel, -- button#1
                 labelBound (labels !! 5) -- label#5
               ]
        )
    mount root
    clip <- openReader (mediaAsset "media/h264_frames.mp4")
    exactRead <- readFrames clip bands (80, 45) Exact
    tone <- openReader (mediaAsset "media/tone.wav")
    peaksRead <- readPeaks tone 4800
    failed <-
      mapM
        ( \(what, source) -> do
            r <- openReader (mediaAsset source)
            read' <- readFrames r [0] (80, 45) Exact
            return (read', line 3 failures what)
        )
        [("OFL.txt", "fonts/OFL.txt"), ("missing.mp4", "media/missing.mp4")]
    silent <- openReader (mediaAsset "media/h264_noaudio.mp4")
    silentRead <- readPeaks silent 4800
    song <- openReader (mediaAsset "media/tone.mp3")
    songRead <- readFrames song [0] (80, 45) Exact
    logo <- loadImage (mediaAsset "images/a11y-logo.png")
    photo <- loadImage (mediaAsset "images/photo.jpg")
    let ends =
          failed
            ++ [ (silentRead, line 4 missing "noaudio peaks"),
                 (songRead, line 4 missing "mp3 frames")
               ]
    return (labels, strip, wave, clip, exactRead, peaksRead, ends, logo, photo)
  forM_ ends $ \(r, h) -> onReadDone app r h
  onFrame app exactRead (\f -> modifyIORef' exact (f :))
  onReadDone app exactRead $ \outcome -> do
    frames <- readIORef exact
    keyframeRead <- buildTx app $ do
      writeSignal (labels !! 0) (frameLine "exact" frames outcome)
      readFrames clip bands (80, 45) Keyframe
    onFrame app keyframeRead (\f -> modifyIORef' keyframe (f :))
    onReadDone app keyframeRead $ \outcome' -> do
      ex <- sortOn (.index) <$> readIORef exact
      kf <- sortOn (.index) <$> readIORef keyframe
      submitTx app $ do
        writeSignal (labels !! 1) (frameLine "keyframe" kf outcome')
        draw strip stripBox [drawImage f.picture (80 * fromIntegral i) 0 80 45 | (i, f) <- zip [0 :: Int ..] (ex ++ kf)]
  onPeaks app peaksRead $ \p -> do
    let pairs = [peaksPair p i 0 | i <- [0 .. p.pairCount - 1]]
        lows = if null pairs then 0 else minimum (map fst pairs)
        highs = if null pairs then 0 else maximum (map snd pairs)
        y v = 30 - fromIntegral v * 25 / 8192
        bar i (lo, hi) =
          let x = 8 + 7 * fromIntegral i
           in [moveTo x (y hi), lineTo (x + 5) (y hi), lineTo (x + 5) (y lo), lineTo x (y lo), close, fill PaintSeries Nonzero]
    submitTx app $ do
      writeSignal (labels !! 2) $
        "peaks " <> tshow p.sampleRate <> " Hz, " <> tshow p.channels <> " ch, " <> tshow p.pairCount
          <> " pairs of " <> tshow p.samplesPerPair <> ", " <> tshow lows <> ".." <> tshow highs
      draw wave waveBox $
        concat (zipWith bar [0 :: Int ..] pairs)
          ++ [drawImage logo 150 4 20 20, drawImage photo 150 30 40 30]
  onReadDone app peaksRead $ \outcome -> case outcome of
    ReadCompleted -> return ()
    _ -> submitTx app (writeSignal (labels !! 2) ("peaks " <> readOutcomeName outcome))

main :: IO ()
main = kayaMain $ \app -> do
  scene <- fromMaybe "" <$> lookupEnv "KAYA_SELFTEST"
  case scene of
    "media_tracks" -> tracksApp app
    "media_feed" -> feedApp app
    "media_reader" -> readerApp app
    _ -> formatsApp app scene
