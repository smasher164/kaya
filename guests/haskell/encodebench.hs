{- The encode benchmark: pins "derives target the encoder, not a value
   tree" (DESIGN.md, milestone 3) as a suite leg. Encodes N
   collection_insert records through the generated wire encoder and
   requires a floor rate with ~10x headroom — only a structural
   regression (per-record reflection, tree building) can trip it. -}

import qualified Data.ByteString.Lazy as BL
import Data.ByteString.Builder (toLazyByteString)
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import KayaWire

main :: IO ()
main = do
  let n = 200000 :: Int
      floorRate = 100000 :: Int -- records/second

  start <- getCurrentTime
  let encoded =
        sum
          [ BL.length
              (toLazyByteString
                 (txCollectionInsert 1 []
                    (VStr ("k" ++ show (i `mod` 1024)))
                    0
                    [VStr "send report", VBool False]))
          | i <- [0 .. n - 1]
          ]
  encoded `seq` return ()
  end <- getCurrentTime
  let elapsed = realToFrac (diffUTCTime end start) :: Double
      rate = floor (fromIntegral n / elapsed) :: Int
  if rate >= floorRate
    then putStrLn ("ENCODE_BENCH: OK (haskell: " ++ show rate ++ " rec/s)")
    else do
      hPutStrLn stderr
        ("ENCODE_BENCH: FAIL (haskell: " ++ show rate ++ " rec/s, floor "
           ++ show floorRate ++ ")")
      exitFailure
