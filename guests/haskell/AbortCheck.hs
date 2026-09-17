{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The Haskell uniform-abort guard. Run headless by tools/check-abort.py.

import Control.Exception (SomeException, evaluate, try)
import Control.Monad (unless)
import Data.Bits (shiftR, (.&.))
import qualified Data.ByteString as BS
import Data.ByteString.Builder (toLazyByteString)
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import Data.List (isInfixOf)
import GHC.Generics (Generic)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Data.Text (Text)
import KayaApp
import KayaWire (Value (..))
import qualified KayaWire as W

-- A record with a DOCUMENT field (docs/rich-text-plan.md §19).
data CheckNote = CheckNote {cnTitle :: Text, cnBody :: Document}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

failWith :: String -> IO a
failWith msg = hPutStrLn stderr msg >> exitFailure

expectKeys :: App -> Collection -> [Text] -> String -> IO ()
expectKeys app todos want what = do
  got <- buildTx app (map fst <$> items todos)
  unless (got == map textKey want) $ failWith (what ++ ": " ++ show got)

main :: IO ()
main = do
  app <- newApp
  todos <- buildTx app $ do
    c <- collection
    insert c "a" "one"
    insert c "b" "two"
    return c

  -- Abort mid-transaction after mutating: rollback, then rethrow. Rollback
  -- is by PURITY — a throwing Build trips buildTx's evaluate barrier.
  aborted <-
    try $ buildTx app $ do
      insert todos "c" "three"
      remove todos "a"
      error "handler bug"
  case (aborted :: Either SomeException ()) of
    Right () -> failWith "buildTx swallowed the error — the tx boundary must propagate"
    Left _ -> return ()
  expectKeys app todos ["a", "b"] "abort did not restore the mirror"

  -- A throwing handler is logged and the loop continues.
  dispatch $ buildTx app $ do
    insert todos "d" "four"
    error "handler bug"
  expectKeys app todos ["a", "b"] "dispatch abort leaked into the mirror"
  buildTx app (insert todos "c" "three")
  expectKeys app todos ["a", "b", "c"] "post-abort commit broken"

  -- The menu surface: the constructors must reach the emitter, the ONE
  -- shortcut parser must reject aliases, and an abort must leave the app usable.
  file <- buildTx app $ do
    f <- menu "File" [] [item "Save" [IShortcut "PRIMARY+S"]]
    window primary [WMenus [pure f]]
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
  unless ((insertEdit 0 "x").source == Nothing) $
    failWith "an app-built edit carries a source — nothing on the wire carries one downward"
  unknown <- try (evaluate (editSourceName (editSourceOfWire 99)))
  case (unknown :: Either SomeException Text) of
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
      runsNow = (.runs) <$> document app editor
  act "formatText" (formatText editor "bold" (Flag True)) (0, 0, 0, 0)
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
    [ ("bold", bold editor, "bold", Flag True)
    , ("italic", italic editor, "italic", Flag True)
    , ("underline", underline editor, "underline", Flag True)
    , ("strike", strike editor, "strike", Flag True)
    , ("code", code editor, "code", Flag True)
    , ("link", link editor "https://kaya.dev", "link", Spelled "https://kaya.dev")
    ]
  runsNow >>= \runs ->
    check (null runs)
      ("a named act moved the fold (" ++ show runs
         ++ ") — a selection act is echoed back, and the fold moves when "
         ++ "it arrives")
  act "formatTextRange" (formatTextRange app editor (4, 7) "italic" (Flag True))
    (0, 1, 4, 7)
  runsNow >>= \runs ->
    check (runs == [Run (4, 7) "italic" (Flag True)])
      ("the fold after formatTextRange holds " ++ show runs
         ++ ", wanted 4..7 italic=true")
  -- A block covers the range's whole paragraphs, snapped against the
  -- FOLD's own text: "one\ntwo\nthree" puts (5, 6) inside 4..7.
  act "formatTextRange block" (formatTextRange app editor (5, 6) "block" (Spelled "heading1"))
    (0, 1, 4, 7)
  runsNow >>= \runs ->
    check (filter ((== "block") . (.name)) runs == [Run (4, 7) "block" (Spelled "heading1")])
      ("the fold after a ranged block act holds " ++ show runs
         ++ ", wanted 4..7 block=heading1")
  act "formatTextRange block body" (formatTextRange app editor (5, 6) "block" (Spelled "body"))
    (1, 1, 4, 7)
  act "unformatRange" (unformatRange app editor (4, 7) "italic") (1, 1, 4, 7)
  runsNow >>= \runs ->
    check (null runs)
      ("the fold after the two removals holds " ++ show runs
         ++ ", wanted nothing")

  -- THE DOCUMENT AS A ROW FIELD (docs/rich-text-plan.md §19). NOTHING
  -- ELSE READS THESE BYTES: the richrows scene asserts what the CORE
  -- renders, so a field encoding the core happens to tolerate would be
  -- green on five lanes; the reference list below is built from the wire
  -- rules by hand — u32 tag, u32 length, payload, padded to 8 — and not
  -- from this binding's own encoder.
  let le :: Int -> Int -> BS.ByteString
      le n width =
        BS.pack [fromIntegral ((n `shiftR` (8 * i)) .&. 0xff) | i <- [0 .. width - 1]]
      pad8 b = b <> BS.replicate ((8 - BS.length b `mod` 8) `mod` 8) 0
      handStr v = pad8 (le 4 4 <> le (length (BC.unpack (BC.pack v))) 4 <> BC.pack v)
      handI64 n = pad8 (le 2 4 <> le 8 4 <> le n 8)
      reference =
        BS.concat
          [ le 9 4, le 0 4, handStr "abc",
            handI64 0, handI64 1, handStr "bold", handStr "true",
            handI64 1, handI64 3, handStr "link", handStr "u"
          ]
      twoRuns = linkRun (1, 3) "u" (boldRun (0, 1) (documentOf "abc"))
  case toFieldValue twoRuns of
    VStr got
      | BC.pack got == reference -> return ()
      | otherwise ->
          let packed = BC.pack got
              n = min (BS.length packed) (BS.length reference)
              differs = [i | i <- [0 .. n - 1], BS.index packed i /= BS.index reference i]
           in failWith
                ( case differs of
                    (i : _) ->
                      "a Document field's bytes differ from the wire's own list at byte "
                        ++ show i ++ ": " ++ show (BS.index packed i) ++ ", wanted "
                        ++ show (BS.index reference i) ++ " (" ++ show (BS.length packed)
                        ++ " byte(s) packed, " ++ show (BS.length reference) ++ " wanted)"
                    [] ->
                      "a Document field packed " ++ show (BS.length packed)
                        ++ " byte(s) where the wire's own list is "
                        ++ show (BS.length reference)
                        ++ " — the text as a Str, then four values per run"
                )
    other ->
      failWith
        ( "a Document field's model value is " ++ show other
            ++ ", wanted the blob's bytes as a binary Str" )
  check (documentOfBlob reference == Document "abc" [Run (0, 1) "bold" (Flag True), Run (1, 3) "link" (Spelled "u")])
    ("the reference list read back as " ++ show (documentOfBlob reference))

  -- AND THE FOLD REACHES THE ROW: a stamped copy's edit folds into its
  -- row's field by the rule the LIVE mirror folds by, so the two
  -- documents are one document.
  let seed = boldRun (0, 6) (documentOf "Héllo world")
      oneEdit = Edit (0, 6) "Hey" [] Nothing
  rowApp <- newApp
  (rowNotes, rowNode) <- buildTx rowApp $ do
    notes <- collectionOf @CheckNote
    (_, node) <- forEach (recordHandle notes) (textareaRichBound (field @"cnBody" @CheckNote))
    insertRecord notes (textKey "a") (CheckNote "a" seed)
    return (notes, node)
  foldRowDocument rowApp rowNode [textKey "a"] (foldEdit oneEdit)
  liveEditor <- buildTx rowApp (textarea [Rich True])
  buildTx rowApp (setDocument rowApp liveEditor seed)
  absorbEdit rowApp liveEditor oneEdit
  mirrored <- document rowApp liveEditor
  items <- buildTx rowApp (recordItems rowNotes)
  case lookup (textKey "a") items of
    Nothing -> failWith "the row vanished before the fold could be read back"
    Just note ->
      check (cnBody note == mirrored)
        ( "the row's field folded to " ++ show (cnBody note)
            ++ " where the live mirror folded to " ++ show mirrored
            ++ " — one rule, two documents" )

  -- THE KEYED READ (docs/deferred.md, the idiom pass's keyed-read entry):
  -- 'getRecord' is 'recordItems' narrowed to one key, so it must agree
  -- with a 'lookup' over the same table on both a present key and an
  -- absent one — the single-row read `recordItems` \/ `lookup` forced a
  -- guest to spell out before this entry.
  gotA <- buildTx rowApp (getRecord rowNotes "a")
  case gotA of
    Just note -> check (cnTitle note == "a") ("getRecord \"a\" read title " ++ show (cnTitle note) ++ ", wanted \"a\"")
    Nothing -> failWith "getRecord found no row at a present key"
  gotMissing <- buildTx rowApp (getRecord rowNotes "no-such-key")
  case gotMissing of
    Nothing -> return ()
    Just _ -> failWith "getRecord found a row at an absent key"

  putStrLn "haskell abort check: OK"
