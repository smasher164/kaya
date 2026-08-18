{- The uniform-abort guard: a handler abort rolls the model mirror
   back, ships nothing, and the app continues — the same observable
   semantics as every other binding (the negative test each language
   carries). Runs headless: the library loads (KAYA_LIB) but the core
   loop is never entered; records queue and the process exits. -}

import Control.Exception (SomeException, try)
import Control.Monad (unless)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import KayaApp
import KayaWire (Value (..))

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

  -- Abort mid-transaction after mutating: the boundary must restore the
  -- mirror and rethrow. Rollback is by PURITY here — a throwing Build
  -- trips buildTx's evaluate barrier before the store-back and submit
  -- ever run.
  aborted <-
    try $ buildTx app $ do
      insert todos (VStr "c") (VStr "three")
      remove todos (VStr "a")
      error "handler bug"
  case (aborted :: Either SomeException ()) of
    Right () -> failWith "buildTx swallowed the error — the tx boundary must propagate"
    Left _ -> return ()
  expectKeys app todos ["a", "b"] "abort did not restore the mirror"

  -- The dispatch discipline: a throwing handler is logged and the loop
  -- continues, and the next transaction sees the restored model.
  dispatch $ buildTx app $ do
    insert todos (VStr "d") (VStr "four")
    error "handler bug"
  expectKeys app todos ["a", "b"] "dispatch abort leaked into the mirror"
  buildTx app (insert todos (VStr "c") (VStr "three"))
  expectKeys app todos ["a", "b", "c"] "post-abort commit broken"

  -- NOT PINNED: derived registrations roll back by the same purity, but
  -- appDerived is internal to KayaApp so there is nothing to observe.

  -- The menu surface. The record stream is internal to the Build monad,
  -- so what the three clauses below pin is that the constructors run
  -- through the emitter, that the binding's ONE shortcut parser rejects
  -- aliases, and that an aborted append propagates and leaves the app
  -- usable.
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

  putStrLn "haskell abort check: OK"
