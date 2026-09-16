-- The Haskell uniform-abort guard. Run headless by tools/check-abort.py.

import Control.Exception (SomeException, evaluate, try)
import Control.Monad (unless)
import qualified Data.ByteString as BS
import Data.ByteString.Builder (toLazyByteString)
import qualified Data.ByteString.Lazy as BL
import Data.List (isInfixOf)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import KayaApp
import KayaWire (Value (..))
import qualified KayaWire as W

failWith :: String -> IO a
failWith msg = hPutStrLn stderr msg >> exitFailure

expectKeys :: App -> Collection -> [String] -> String -> IO ()
expectKeys app todos want what = do
  got <- buildTx app (map fst <$> items todos)
  unless (got == map VStr want) $ failWith (what ++ ": " ++ show got)

main :: IO ()
main = do
  app <- newApp
  todos <- buildTx app $ do
    c <- collection
    insert c (VStr "a") (VStr "one")
    insert c (VStr "b") (VStr "two")
    return c

  -- Abort mid-transaction after mutating: rollback, then rethrow. Rollback
  -- is by PURITY — a throwing Build trips buildTx's evaluate barrier.
  aborted <-
    try $ buildTx app $ do
      insert todos (VStr "c") (VStr "three")
      remove todos (VStr "a")
      error "handler bug"
  case (aborted :: Either SomeException ()) of
    Right () -> failWith "buildTx swallowed the error — the tx boundary must propagate"
    Left _ -> return ()
  expectKeys app todos ["a", "b"] "abort did not restore the mirror"

  -- A throwing handler is logged and the loop continues.
  dispatch $ buildTx app $ do
    insert todos (VStr "d") (VStr "four")
    error "handler bug"
  expectKeys app todos ["a", "b"] "dispatch abort leaked into the mirror"
  buildTx app (insert todos (VStr "c") (VStr "three"))
  expectKeys app todos ["a", "b", "c"] "post-abort commit broken"

  -- The menu surface: the constructors must reach the emitter, the ONE
  -- shortcut parser must reject aliases, and an abort must leave the app usable.
  file <- buildTx app $ do
    f <- menu "File" [] [item "Save" [IShortcut "PRIMARY+S"]]
    window 0 [WMenus [pure f]]
    return f

  badShortcut <-
    try $ buildTx app $ menuAppend file [item "Bad" [IShortcut "ctrl+s"]]
  case (badShortcut :: Either SomeException ()) of
    Right () -> failWith "an alias shortcut must die in the binding's one parser"
    Left _ -> return ()

  menuAborted <-
    try $ buildTx app $ do
      menuAppend file [item "Doomed" []]
      error "handler bug"
  case (menuAborted :: Either SomeException ()) of
    Right () -> failWith "menu abort: buildTx must propagate"
    Left _ -> return ()
  buildTx app (menuAppend file [item "Publish" [IPrimary True]])

  -- THE EDIT SOURCE (the review page's ruling 3, 2026-09-14): the wire's
  -- number is the name the core's own table gives it, an app-built edit
  -- carries none, and a number this build does not know is refused by
  -- value. Nothing else runs the mapping — the scene reaches it only
  -- through a real keystroke.
  mapM_
    ( \(wire, want) -> do
        let got = editSourceName (editSourceOfWire wire)
        unless (got == want) $
          failWith
            ( "edit source " ++ show wire ++ " reads as " ++ show got
                ++ ", wanted " ++ show want
            )
    )
    [ (W.editSourceUser, "user"),
      (W.editSourceImeCommit, "ime_commit"),
      (W.editSourcePaste, "paste"),
      (W.editSourceNativeUndo, "native_undo"),
      (W.editSourceDrop, "drop")
    ]
  unless (editSource (insertEdit 0 "x") == Nothing) $
    failWith "an app-built edit carries a source — nothing on the wire carries one downward"
  unknown <- try (evaluate (editSourceName (editSourceOfWire 99)))
  case (unknown :: Either SomeException String) of
    Right s ->
      failWith ("edit source 99 read as " ++ show s ++ " instead of being refused")
    Left e ->
      unless ("99" `isInfixOf` show e) $
        failWith ("the unknown edit source was refused without naming it: " ++ show e)

  -- THE RANGED FORMAT ACT (docs/rich-text-plan.md §17). Nothing else
  -- reads these bytes: the richtext scene drives the SELECTION act, whose
  -- record differs only in these two words, and a ranged act is echoed by
  -- nothing, so a sugar that sent ranged 0 would format whatever the user
  -- had selected with every lane green.
  let check ok what = unless ok (failWith what)
  editor <- buildTx app (textarea [Rich True])
  buildTx app (setDocument app editor (documentOf "one\ntwo\nthree"))
  let staged what body = do
        bytes <- BL.toStrict . toLazyByteString . snd <$> stageTx app body
        let byteAt at = fromIntegral (BS.index bytes at) :: Int
            word n at = sum [byteAt (at + k) * (256 ^ k) | k <- [0 .. n - 1]]
        check (BS.length bytes >= 40)
          (what ++ " staged " ++ show (BS.length bytes)
             ++ " bytes, too few for one format_text record")
        check (word 2 4 == fromIntegral W.txKindFormatText)
          (what ++ " staged record kind " ++ show (word 2 4) ++ ", wanted "
             ++ show W.txKindFormatText)
        return (word 4 16, word 4 20, word 8 24, word 8 32)
      act what body want = do
        got <- staged what body
        check (got == want)
          (what ++ " staged (removed, ranged, start, stop) " ++ show got
             ++ ", wanted " ++ show want)
      runsNow = docRuns <$> document app editor
  act "formatText" (formatText editor "bold" "true") (0, 0, 0, 0)
  act "unformat" (unformat editor "bold") (1, 0, 0, 0)
  act "setBlock" (setBlock editor Heading1) (0, 0, 0, 0)
  runsNow >>= \runs ->
    check (null runs)
      ("a SELECTION act moved the fold (" ++ show runs
         ++ ") — the widget echoes that one back, and the fold moves when "
         ++ "it arrives")
  -- THE NAMED ACTS (docs/rich-text-plan.md §18): each is 'formatText'
  -- with its own name, so each stages the bytes the general act stages —
  -- compared here because the scenes drive 'formatText' itself, and an
  -- act that sent another name, or a ranged record, would pass every lane.
  let stagedBytes body = BL.toStrict . toLazyByteString . snd <$> stageTx app body
  mapM_
    (\(what, body, name, value) -> do
      got <- stagedBytes body
      want <- stagedBytes (formatText editor name value)
      check (got == want)
        (what ++ " staged " ++ show got ++ ", wanted " ++ show want
           ++ " — the bytes formatText " ++ show name ++ " " ++ show value
           ++ " stages"))
    [ ("bold", bold editor, "bold", "true")
    , ("italic", italic editor, "italic", "true")
    , ("underline", underline editor, "underline", "true")
    , ("strike", strike editor, "strike", "true")
    , ("code", code editor, "code", "true")
    , ("link", link editor "https://kaya.dev", "link", "https://kaya.dev")
    ]
  runsNow >>= \runs ->
    check (null runs)
      ("a named act moved the fold (" ++ show runs
         ++ ") — a selection act is echoed back, and the fold moves when "
         ++ "it arrives")
  act "formatTextRange" (formatTextRange app editor (4, 7) "italic" "true")
    (0, 1, 4, 7)
  runsNow >>= \runs ->
    check (runs == [Run 4 7 "italic" "true"])
      ("the fold after formatTextRange holds " ++ show runs
         ++ ", wanted 4..7 italic=true")
  -- A block covers the range's whole paragraphs, snapped against the
  -- FOLD's own text: "one\ntwo\nthree" puts (5, 6) inside 4..7.
  act "formatTextRange block" (formatTextRange app editor (5, 6) "block" "heading1")
    (0, 1, 4, 7)
  runsNow >>= \runs ->
    check (filter ((== "block") . runName) runs == [Run 4 7 "block" "heading1"])
      ("the fold after a ranged block act holds " ++ show runs
         ++ ", wanted 4..7 block=heading1")
  act "formatTextRange block body" (formatTextRange app editor (5, 6) "block" "body")
    (1, 1, 4, 7)
  act "unformatRange" (unformatRange app editor (4, 7) "italic") (1, 1, 4, 7)
  runsNow >>= \runs ->
    check (null runs)
      ("the fold after the two removals holds " ++ show runs
         ++ ", wanted nothing")

  putStrLn "haskell abort check: OK"
