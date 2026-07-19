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

  -- Abort mid-transaction after mutating: the boundary must restore
  -- the mirror and rethrow (rollback + propagate is the tx boundary's
  -- contract; surviving is the dispatch loop's). Here rollback is by
  -- purity — a throwing Build trips buildTx's evaluate barrier before
  -- the store-back and submit ever run.
  aborted <-
    try $ buildTx app $ do
      insert todos (VStr "c") (VStr "three")
      remove todos (VStr "a")
      error "handler bug"
  case (aborted :: Either SomeException ()) of
    Right () -> failWith "buildTx swallowed the error — the tx boundary must propagate"
    Left _ -> return ()
  expectKeys app todos ["a", "b"] "abort did not restore the mirror"

  -- The dispatch discipline: a throwing handler is logged and the
  -- loop continues — the next transaction works and sees the restored
  -- model.
  dispatch $ buildTx app $ do
    insert todos (VStr "d") (VStr "four")
    error "handler bug"
  expectKeys app todos ["a", "b"] "dispatch abort leaked into the mirror"
  buildTx app (insert todos (VStr "c") (VStr "three"))
  expectKeys app todos ["a", "b", "c"] "post-abort commit broken"

  -- Derived registrations roll back by the same purity (bDerived is
  -- stored back only on commit), but appDerived is internal to
  -- KayaApp, so there is nothing to observe here — not pinned.

  putStrLn "haskell abort check: OK"
