{-# LANGUAGE OverloadedStrings #-}

-- The font picker scene, Haskell port: guests/rust/fontpick.rs,
-- tools/scenes/fontpick.steps (docs/font-picker-plan.md §7).

import Control.Applicative ((<|>))
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Maybe (isJust, isNothing, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

mono :: [Text]
mono = ["Menlo", "DejaVu Sans Mono", "Cascadia Mono", "Consolas", "Courier New", "Droid Sans Mono", "monospace"]

docText :: Text
docText = "bold run, italic run, plain run"

wordsOf :: Int -> Bool -> Int -> Text
wordsOf w i wd = T.pack (show w) <> (if i then " italic " else " upright ") <> T.pack (show wd)

lightFamily :: [FontFace] -> Maybe (Int, Int, Int)
lightFamily faces = do
  let upright = [f.weight | f <- faces, not f.italic, f.width == 5]
      slanted = [f.weight | f <- faces, f.italic, f.width == 5]
  if length upright < 3 || 700 `notElem` upright then Nothing else Just ()
  light <- find (\w -> w < 400 && w `elem` slanted) upright
  (a, b) <- find (\(a, b) -> a >= 500 && b > a + 1) (zip upright (drop 1 upright))
  return (light, a, b)

uprightOnly :: [FontFace] -> Maybe Int
uprightOnly faces
  | null faces || any (.italic) faces = Nothing
  | otherwise = (.weight) <$> find (\f -> f.width == 5) faces

main :: IO ()
main = kayaMain $ \app -> do
  queueRef <- newIORef ([] :: [Text])
  lightRef <- newIORef Nothing
  plainRef <- newIORef Nothing
  monoRef <- newIORef Nothing
  askedRef <- newIORef Nothing
  widgetsRef <- newIORef Nothing

  let popNext = do
        queue <- readIORef queueRef
        case reverse queue of
          next : rest -> writeIORef queueRef (reverse rest) >> return (Just next)
          [] -> return Nothing

  onFontFamilies app $ \families -> do
    let m = find (`elem` families) mono
    writeIORef monoRef m
    writeIORef queueRef (reverse families ++ maybe [] pure m)
    next <- popNext
    mapM_ (submitTx app . listFontFaces) next

  onFontFaces app $ \family faces -> do
    m <- readIORef monoRef
    asked0 <- readIORef askedRef
    if Just family == m && isNothing asked0
      then do
        let face = find (\f -> f.weight == 700 && not f.italic && f.width == 5) faces
              <|> listToMaybe faces
        writeIORef askedRef ((\f -> FontChoice family f.weight f.italic f.width) <$> face)
      else return ()
    modifyIORef' lightRef (\l -> if isJust l then l else (,) family <$> lightFamily faces)
    modifyIORef' plainRef (\p -> if isJust p then p else (,) family <$> uprightOnly faces)
    light <- readIORef lightRef
    plain <- readIORef plainRef
    Just (ready, want, pick, _, exact, between, synth, doc, _) <- readIORef widgetsRef
    asked <- readIORef askedRef
    case (light, plain) of
      (Just (lf, (lw, a, b)), Just (pf, pw)) -> submitTx app $ do
        setFamily exact lf
        setFontWeight exact lw
        setFamily between lf
        setFontWeight between (a + (b - a) `div` 2)
        setFamily synth pf
        setFontWeight synth pw
        setFontItalic synth True
        setFamily doc lf
        setFontWeight doc lw
        setDocument app doc (italicRun (10, 16) . boldRun (0, 4) $ documentOf docText)
        let say i = writeSignal (want !! i)
        say 0 (wordsOf lw False 5)
        say 1 (wordsOf b False 5)
        say 2 (wordsOf pw True 5 <> " synthesized")
        say 3 (wordsOf 700 False 5)
        say 4 (wordsOf lw True 5)
        case asked of
          Just c -> do
            writeSignal pick (wordsOf c.weight c.italic c.width <> " " <> c.family)
            say 5 (wordsOf c.weight c.italic c.width)
          Nothing -> return ()
        writeSignal ready "faces: found"
      _ -> do
        next <- popNext
        submitTx app (maybe (writeSignal ready "faces: none suit") listFontFaces next)

  let onChosen choice = do
        Just (_, _, _, picked, _, _, _, _, chosen) <- readIORef widgetsRef
        asked <- readIORef askedRef
        submitTx app $ case choice of
          Nothing -> writeSignal picked "picked: cancelled"
          Just c -> do
            setFamily chosen c.family
            setFontWeight chosen c.weight
            setFontItalic chosen c.italic
            setFontWidth chosen c.width
            writeSignal picked $
              if Just c == asked
                then "picked: as asked"
                else "picked: " <> wordsOf c.weight c.italic c.width <> " " <> c.family

  widgets <- buildTx app $ do
    window primary [WTitle "fontpick"]
    ready <- signalText "faces: -"
    want <- mapM (const (signalText "-")) [1 .. 6 :: Int]
    pick <- signalText "-"
    picked <- signalText "picked: -"
    exact <- labelText "Exact" [A11yId "exact"]
    between <- labelText "Between" [A11yId "between"]
    synth <- labelText "Slanted" [A11yId "synth"]
    doc <- textarea [Rich True, A11yId "doc"]
    chosen <- labelText "Chosen" [A11yId "chosen"]
    root <-
      column $
        [ labelBound ready [A11yId "ready"],
          pure exact,
          pure between,
          pure synth,
          pure doc,
          pure chosen
        ]
          ++ zipWith
            (\s i -> labelBound s [A11yId i])
            want
            ["want_exact", "want_between", "want_synth", "want_bold", "want_italic", "want_pick"]
          ++ [ labelBound pick [A11yId "pick"],
               labelBound picked [A11yId "picked"],
               row
                 [ buttonOn "faces" (submitTx app listFontFamilies) [A11yId "faces"],
                   buttonOn
                     "pick"
                     ( do
                         asked <- readIORef askedRef
                         submitTx app (chooseFont True True asked onChosen)
                     )
                     [A11yId "pick_button"]
                 ]
             ]
    mount root
    return (ready, want, pick, picked, exact, between, synth, doc, chosen)
  writeIORef widgetsRef (Just widgets)
