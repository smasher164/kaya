{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The network images scene over HTTP, Haskell port —
-- guests/rust/netimage_http.rs, tools/scenes/netimage_http.steps: the row
-- image helper fetching from the lane's media server with the app's own
-- client, http-client-tls.

import Control.Exception (try)
import Control.Monad (forM_)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.IORef (atomicModifyIORef', newIORef)
import GHC.Generics (Generic)
import Network.HTTP.Client (HttpException, Manager, httpLbs, parseRequest, responseBody, responseStatus)
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode, statusIsSuccessful)
import System.Environment (lookupEnv)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

data Track = Track {title :: Text, artUrl :: Text, art :: BS.ByteString, phase :: ImagePhase}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

covers :: [Text]
covers = ["covers/cover-600.jpg", "covers/cover-320.jpg", "covers/cover-1000.jpg"]

fetch :: Manager -> Text -> IO (Either Text BS.ByteString)
fetch manager url = do
  got <- try (parseRequest (T.unpack url) >>= \request -> httpLbs request manager)
  pure $ case got of
    Left e -> Left (tshow (e :: HttpException))
    Right response
      | statusIsSuccessful (responseStatus response) -> Right (BL.toStrict (responseBody response))
      | otherwise -> Left (url <> ": status code " <> tshow (statusCode (responseStatus response)))

main :: IO ()
main = do
  base <-
    lookupEnv "KAYA_MEDIA_URL"
      >>= maybe
        (fail "kaya: the netimage_http scene reads KAYA_MEDIA_URL, the local server the lane starts (tools/lib/media_server.py)")
        (pure . T.pack)
  manager <- newTlsManager
  failures <- newIORef (0 :: Int)
  kayaMain $ \app -> do
    (tracks, artNode, errors) <- buildTx app $ do
      window primary [WTitle "netimage_http", WSize 640 560]
      errors <- signalText "errors: 0"
      tracks <- collectionOf @Track
      (table, artNode) <- forEach (recordHandle tracks) $ do
        n <-
          withTplAttrs
            [ TplFitAs FitCover,
              TplMaxWidth 20,
              TplMaxHeight 20,
              TplPhaseField (field @"phase" @Track),
              TplA11yId "art"
            ]
            (image (field @"art" @Track))
        _ <- rowOf [pure n, label (field @"title" @Track)]
        return n
      columns table ["Art", "Title"] sortNone
      setGrow table 1
      root <- row [labelBound errors [A11yId "errors"], pure table]
      mount root
      let loading name path = Track name (base <> "/" <> path) BS.empty PhaseLoading
      forM_
        [ ("missing", "status/404/"),
          ("broken", "status/500/"),
          ("junk", "covers/README.md"),
          ("slow", "trickle/covers/cover-600.jpg")
        ]
        $ \(key, path) -> insertRecord tracks (textKey key) (loading key path)
      forM_ (zip [0 :: Int ..] (take 12 (cycle covers))) $ \(i, path) ->
        insertRecord tracks (textKey ("a" <> (if i < 10 then "0" else "") <> tshow i)) (loading ("Track " <> tshow i) path)
      return (tracks, artNode, errors)
    images <-
      rowImages app tracks (field @"artUrl" @Track) (field @"art" @Track) (field @"phase" @Track) (fetch manager)
    onRowImageError images $ \_ _ -> do
      n <- atomicModifyIORef' failures (\n -> (n + 1, n + 1))
      pure (writeSignal errors ("errors: " <> tshow n))
    attachRowImages app artNode images
