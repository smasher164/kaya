{-# LANGUAGE OverloadedStrings #-}

-- The code surface scene, Haskell port: guests/rust/codesurface.rs,
-- tools/scenes/codesurface.steps (docs/code-surface-plan.md). A textarea that
-- numbers its lines, the platform's monospaced face, a family picked from the
-- platform's list, a family the platform lacks, a label at twice the size.

import qualified Data.ByteString as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Text.Printf (printf)
import KayaApp

-- Forty lines; the third wraps at every lane's width.
codeDocument :: Text
codeDocument =
  T.intercalate "\n" $
    [ "// codesurface: a small source file for the gutter",
      "fn main() {",
      "    let note = \"this line is long on purpose, so that the textarea wraps it onto a second row "
        <> "and the gutter has a continuation to leave unnumbered, the way every editor does\";"
    ]
      ++ [T.pack (printf "    let value_%02d = %d * 2;" i i) | i <- [4 .. 39 :: Int]]
      ++ ["}"]

main :: IO ()
main = kayaMain $ \app -> do
  pickedRef <- newIORef Nothing
  listedRef <- newIORef Nothing
  let end = BS.length (TE.encodeUtf8 codeDocument)

  onFontFamilies app $ \families -> do
    picked <- readIORef pickedRef
    listed <- readIORef listedRef
    let ordered = and (zipWith (<) families (drop 1 families))
        word
          | null families = "families: none"
          | ordered = "families: listed, unique, in order"
          | otherwise = "families: out of order"
    submitTx app $ do
      mapM_ (\s -> writeSignal s word) listed
      case (families, picked) of
        (first : _, Just w) -> setFamily w first
        _ -> return ()

  (picked, families) <- buildTx app $ do
    window primary [WTitle "codesurface"]
    families <- signalText "families: -"
    code <- textarea [A11yId "code", LineNumbers True, Monospaced True]
    setText code codeDocument
    plain <- textarea [A11yId "plain"]
    setText plain "plain text\nin the app's face"
    monoEntry <- entry [Monospaced True, A11yId "mono_entry"]
    setText monoEntry "let y = 2;"
    picked <- labelText "picked" [A11yId "picked"]
    root <-
      column
        [ pure code,
          pure plain,
          labelText "let x = 1;" [Monospaced True, A11yId "mono"],
          pure monoEntry,
          labelText "missing" [Family "Kaya No Such Family", Monospaced True, A11yId "missing"],
          labelText "Big" [TextScale 2, A11yId "big"],
          labelText "Plain" [A11yId "plain_label"],
          labelBound families [A11yId "families"],
          pure picked,
          row
            [ buttonOn
                "end"
                (submitTx app (focusWidget code >> selectRange code (end, end) >> revealRange code (end, end)))
                [A11yId "end"],
              buttonOn "fonts" (submitTx app listFontFamilies) [A11yId "fonts"]
            ]
        ]
    mount root
    return (picked, families)
  writeIORef pickedRef (Just picked)
  writeIORef listedRef (Just families)
