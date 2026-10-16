{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The network images affordance scene, Haskell port —
-- guests/rust/netimage.rs, tools/scenes/netimage.steps. No HTTP: each
-- "download" is a job a worker thread holds until a click releases it.

import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (newChan, readChan, writeChan)
import Control.Monad (forM_, forever)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import GHC.Generics (Generic)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

data Track = Track {title :: Text, artUrl :: Text, art :: BS.ByteString, phase :: ImagePhase}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

data Job = Live (Maybe BS.ByteString) | RowJob Text Text BS.ByteString

rowsCount :: Int
rowsCount = 300

main :: IO ()
main = kayaMain $ \app -> do
  covers <- mapM (\name -> asset name >>= assetBytes) ["covers/cover-600.jpg", "covers/cover-320.jpg", "covers/cover-1000.jpg"]
  let cover i = covers !! (i `mod` 3)
  jobs <- newChan
  live <- newIORef (Just (Live (Just (cover 0))))
  pending <- newIORef []
  needed <- newIORef Set.empty
  ever <- newIORef Set.empty
  twice <- newIORef Nothing

  (artSig, phaseSig, band, released, again, tracks, artNode) <- buildTx app $ do
    window primary [WTitle "netimage", WSize 820 640]
    artSig <- signalImage BS.empty
    phaseSig <- signalPhase PhaseLoading
    band <- signalText "band: -"
    released <- signalText "released: none"
    again <- signalText "again: none"
    tracks <- collectionOf @Track
    (table, artNode) <- forEach (recordHandle tracks) $ do
      -- Realized ahead of its row so the central registration has a handle.
      n <-
        withTplAttrs
          [ TplFitAs FitCover,
            TplMaxWidth 40,
            TplMaxHeight 40,
            TplShapeAs ShapeRounded,
            TplPhaseField (field @"phase" @Track),
            TplA11yId "art"
          ]
          (image (field @"art" @Track))
      _ <- rowOf [pure n, label (field @"title" @Track)]
      return n
    columns table ["Art", "Title"] sortNone
    setA11yId table "tracks"
    setGrow table 1
    let send batch = writeChan jobs batch
        onRelease = do
          job <- readIORef live
          forM_ job $ \j -> writeIORef live Nothing >> send [j]
        onRefresh = do
          writeIORef live (Just (Live (Just (cover 1))))
          submitTx app (writeSignal phaseSig PhaseLoading)
        onJunk = submitTx app $ do
          writeSignal artSig (BC.pack "not an image")
          writeSignal phaseSig PhaseShown
        onFail = do
          writeIORef live (Just (Live Nothing))
          submitTx app $ do
            writeSignal artSig BS.empty
            writeSignal phaseSig PhaseLoading
        onRows = do
          writeIORef needed Set.empty
          batch <- readIORef pending
          writeIORef pending []
          send batch
        onDelete = submitTx app (remove (recordHandle tracks) "t299")
        onRetarget = do
          modifyIORef' pending (RowJob "t298" "u/298b" (cover 2) :)
          submitTx app (patch tracks "t298" [set (field @"artUrl" @Track) "u/298b"])
    root <-
      column
        [ column
            [ imageBound artSig [MaxWidth 96, MaxHeight 96, FitAs FitCover, PhaseBound phaseSig, A11yId "cover", A11yLabel "Cover"],
              row
                [ buttonOn "release" onRelease [A11yId "release"],
                  buttonOn "refresh" onRefresh [A11yId "refresh"]
                ],
              row
                [ buttonOn "junk" onJunk [A11yId "junk"],
                  buttonOn "fail" onFail [A11yId "fail"]
                ],
              row
                [ buttonOn "rows" onRows [A11yId "rows"],
                  buttonOn "delete" onDelete [A11yId "delete"],
                  buttonOn "retarget" onRetarget [A11yId "retarget"]
                ],
              labelBound band [A11yId "band"],
              labelBound released [A11yId "released"],
              labelBound again [A11yId "again"]
            ],
          pure table
        ]
    mount root
    forM_ [0 .. rowsCount - 1] $ \i ->
      insertRecord tracks (textKey (T.pack ('t' : pad3 i))) (Track ("Track " <> tshow i) ("u/" <> tshow i) BS.empty PhaseLoading)
    return (artSig, phaseSig, band, released, again, tracks, artNode)

  onNeeded app artNode $ \keys -> forM_ (take 1 keys) $ \first -> do
    let key = keyText first
        i = read (T.unpack (T.drop 1 key)) :: Int
    already <- Set.member key <$> readIORef needed
    if already
      then modifyIORef' twice (maybe (Just key) Just)
      else modifyIORef' needed (Set.insert key)
    modifyIORef' ever (Set.insert key)
    modifyIORef' pending (++ [RowJob key ("u/" <> tshow i) (cover i)])
    seen <- Set.size <$> readIORef ever
    seenTwice <- readIORef twice
    submitTx app $ do
      writeSignal band (if seen < rowsCount then "band: partial" else "band: " <> tshow seen)
      writeSignal again ("again: " <> fromMaybe "none" seenTwice)
  onReleased app artNode $ \keys -> forM_ (take 1 keys) $ \first -> do
    let key = keyText first
    modifyIORef' needed (Set.delete key)
    modifyIORef' pending (filter (\job -> case job of RowJob k _ _ -> k /= key; Live _ -> True))
    submitTx app (writeSignal released "released: some")

  _ <- forkIO $ forever $ do
    batch <- readChan jobs
    forM_ batch $ \job -> case job of
      Live (Just bytes) -> post app $ submitTx app $ do
        writeSignal artSig bytes
        writeSignal phaseSig PhaseShown
      Live Nothing -> post app (submitTx app (writeSignal phaseSig PhaseFailed))
      RowJob key url bytes ->
        post app $
          submitTx app $
            patchIf tracks (textKey key) (field @"artUrl" @Track) url [set (field @"art" @Track) bytes, set (field @"phase" @Track) PhaseShown]
  return ()

pad3 :: Int -> String
pad3 i = let s = show i in replicate (3 - length s) '0' ++ s
