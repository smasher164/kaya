{-# LANGUAGE OverloadedStrings #-}

-- The references scene, Haskell port — guests/rust/references.rs,
-- tools/scenes/references.steps (docs/restoration-plan.md SR11, SR12): a
-- picked file's durable reference rides the session store across a
-- relaunch and redeems for its bytes; a foreign token and a deleted file
-- are refused by name.

import Control.Concurrent (forkIO)
import Control.Exception (SomeException, try)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removeFile)
import System.FilePath ((</>))
import System.IO (hClose, hGetContents', stderr)
import System.Posix.Process (getProcessID)
import KayaApp

-- The bytes a token redeems for, or the refusal's branch; the sentence
-- goes to stderr, where the leg log keeps it.
readBack :: T.Text -> IO T.Text
readBack tok = do
  r <- try (redeem tok)
  case r of
    Left (e :: ReferenceError) -> do
      TIO.hPutStrLn stderr ("references: " <> e.message)
      return e.refusal
    Right redeemed -> do
      o <- try (openPicked redeemed.file FileModeRead)
      case o of
        Left e -> return ("open failed: " <> tshow (e :: SomeException))
        Right (h, _) -> do
          body <- hGetContents' h
          hClose h
          return ("redeemed: " <> T.pack body)

main :: IO ()
main = kayaMain $ \app -> do
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let dir = tmp </> ("kaya-refs-" ++ show pid)
  createDirectoryIfMissing True dir
  writeFile (dir </> "picked.txt") "picked bytes"
  writeFile (dir </> "decoy.txt") "decoy"
  saved <- session.prefGetString "doc" ""

  let reader status tok = do
        _ <- forkIO $ do
          said <- readBack tok
          post app (buildTx app (writeSignal status said))
        return ()
  status <- buildTx app $ do
    window primary [WTitle "references"]
    status <- signalText (if T.null saved then "no reference" else "redeeming")
    let picked files = case files of
          [] -> buildTx app (writeSignal status "cancelled")
          (first : _) -> do
            r <- try (reference first)
            case r of
              Left (e :: ReferenceError) -> do
                TIO.hPutStrLn stderr ("references: " <> e.message)
                buildTx app (writeSignal status e.refusal)
              Right tok -> do
                session.prefSetString "doc" tok
                buildTx app (writeSignal status "minted")
        delete = do
          r <- try (redeem saved)
          case r of
            Left (_ :: ReferenceError) -> return ()
            Right redeemed -> do
              _ <- try (removeFile redeemed.file.localPath) :: IO (Either SomeException ())
              return ()
          reader status saved
    root <-
      column
        [ labelBound status [A11yId "status"],
          buttonOn "pick" (buildTx app (pickFile [("Text", "txt")] picked)) [A11yId "pick"],
          buttonOn "foreign" (reader status "kaya-ref1:beos:AAAA:00000000") [A11yId "foreign"],
          buttonOn "delete" delete [A11yId "delete"]
        ]
    mount root
    pure status
  if T.null saved then return () else reader status saved
