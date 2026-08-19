import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString as BS
main :: IO ()
main = do
  let s1 = T.pack "ab\x1F600\&cd"
      s2 = T.pack "ab\x1F468\&\x200d\&\x1F469\&\x200d\&\x1F467\&\x200d\&\x1F466\&cd"
      s3 = T.pack "abe\x301\&cd"
  putStrLn "LANG haskell"
  putStrLn ("natural_len_S1 " ++ show (T.length s1))
  putStrLn ("natural_len_S2 " ++ show (T.length s2))
  putStrLn ("natural_index_cd_S2 " ++ show (T.length (fst (T.breakOn (T.pack "cd") s2))))
  putStrLn ("bytes_len_S2 " ++ show (BS.length (TE.encodeUtf8 s2)))
  putStrLn ("string_len_S2 " ++ show (length (T.unpack s2)) ++ " (Haskell String = [Char] = scalars)")
  putStrLn ("split_grapheme_S3 " ++ show (T.unpack (T.take 3 s3)))
  putStrLn "stdlib_graphemes NONE (text-icu required)"
