-- The Haskell uniform-abort guard. Run headless by tools/check-abort.py.

import Control.Exception (SomeException, evaluate, try)
import Control.Monad (unless)
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

  putStrLn "haskell abort check: OK"
