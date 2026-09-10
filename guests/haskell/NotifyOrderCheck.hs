-- The process-level notification handler's DISPATCH ORDER
-- (docs/tasks-s9-plan.md R1), run rather than read. A tap on a reminder
-- after the app has exited relaunches the process, and THAT process never
-- called show, so the one-shot table is empty for the id that started it.
-- The ring loop's branch has no seam a test can reach — the ring is C
-- memory — so these drive KayaApp.notificationResult, which the branch
-- calls and tools/check-sugar-surface.py holds it to calling. Run
-- headless by tools/check-abort.py.

import Control.Monad (unless)
import Data.ByteString.Builder (toLazyByteString)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Word (Word32, Word64)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.Directory (removeFile)
import System.Exit (exitFailure)
import System.IO

import KayaApp
import qualified KayaWire as W

check :: Bool -> String -> IO ()
check ok what =
  unless ok $ do
    putStrLn ("notify-order: FAIL — " ++ what)
    exitFailure

-- The drop sentence is written to a real fd, so stderr is redirected to a
-- temp file and read back.
saidOnStderr :: IO () -> IO String
saidOnStderr body = do
  (path, handle) <- openTempFile "." "kaya-notify.txt"
  saved <- hDuplicate stderr
  hDuplicateTo handle stderr
  hClose handle
  body
  hFlush stderr
  hDuplicateTo saved stderr
  hClose saved
  said <- readFile' path
  removeFile path
  return said

main :: IO ()
main = do
  app <- newApp
  oneShot <- newIORef ([] :: [Word32])
  process <- newIORef ([] :: [(Word64, Word32)])
  onNotificationActivation app (\i o -> modifyIORef' process (++ [(i, o)]))
  buildTx app $
    showNotification 12 [NTitle "bound at the show"] $ \o ->
      modifyIORef' oneShot (++ [o])

  -- CASE 1: an id WITH a one-shot handler is answered by it, and the
  -- process-level handler is not consulted at all.
  notificationResult app 12 W.notificationOutcomeActivated
  readIORef oneShot >>= \seen ->
    check (seen == [W.notificationOutcomeActivated])
      ("the one-shot handler did not answer: " ++ show seen)
  readIORef process >>= \seen ->
    check (null seen)
      "the process-level handler answered an id that HAD a one-shot handler"

  -- CASE 2: an id this process never showed — the relaunch case.
  notificationResult app 77 W.notificationOutcomeActivated
  readIORef process >>= \seen ->
    check (seen == [(77, W.notificationOutcomeActivated)])
      "a result with no one-shot handler did not reach the process-level one"

  -- CASE 3: it does NOT retire.
  notificationResult app 78 W.notificationOutcomeRefused
  readIORef process >>= \seen ->
    check (length seen == 2 && seen !! 1 == (78, W.notificationOutcomeRefused))
      "the process-level handler retired after its first result"

  -- AND THE DROP IS ANNOUNCED, compared in full: a drop nobody announced
  -- is R5's defect class, and this sentence is the only signal a
  -- relaunched process's author gets that nothing listened.
  bare <- newApp
  said <- saidOnStderr (notificationResult bare 41 W.notificationOutcomeRefused)
  let want =
        "kaya: notification 41 outcome refused reached no handler — none was"
          ++ " bound at the show and no process-level handler is registered"
          ++ " (KayaApp.onNotificationActivation)"
  check (trim said == want)
    ("the drop was announced as " ++ show (trim said) ++ ", wanted " ++ show want)

  putStrLn
    ( "notify-order: OK — the one-shot wins, an unknown id reaches the "
        ++ "process handler, it does not retire, and an unclaimed result "
        ++ "announces its drop"
    )

  -- THE APP-LINK ROUTES (docs/app-links-plan.md §4). Four things no lane
  -- can see: the declaration's BYTES, the ids the counter mints, the
  -- dispatch by route id, and the two drops — a route that matched and
  -- reached no handler says so, route 0 says nothing because the CORE
  -- already announced that miss naming every declared pattern. NOTHING
  -- HERE READS A PATTERN: the core is the one parser and the one author
  -- of every declaration refusal, and it faults at apply.
  links <- newApp
  linkSeen <- newIORef ([] :: [(String, Map.Map String String)])
  link links "task/{key}" (\p -> modifyIORef' linkSeen (++ [("task", p)]))
  link links "{section}" (\p -> modifyIORef' linkSeen (++ [("section", p)]))

  -- CASE 1: the declaration is the generated record, parked, and the ids
  -- come from the binding's own counter starting at 1.
  parked <- readIORef (appPendingRoutes links)
  let want1 =
        [ W.txDeclareLinkRoute 1 (W.VStr "task/{key}"),
          W.txDeclareLinkRoute 2 (W.VStr "{section}")
        ]
  check (map toLazyByteString parked == map toLazyByteString want1)
    "link did not park the generated records, or minted the wrong ids"

  -- CASE 2: a link on a declared route reaches its handler with the
  -- captures, and the registration does NOT retire.
  linkOpened links 1 "dev.kaya.aurora.notes://task/t2" (Map.fromList [("key", "t2")])
  linkOpened links 1 "dev.kaya.aurora.notes://task/t1" (Map.fromList [("key", "t1")])
  linkOpened links 2 "dev.kaya.aurora.notes://today" (Map.fromList [("section", "today")])
  readIORef linkSeen >>= \seen ->
    check
      ( seen
          == [ ("task", Map.fromList [("key", "t2")]),
               ("task", Map.fromList [("key", "t1")]),
               ("section", Map.fromList [("section", "today")])
             ]
      )
      "a link did not reach its route's handler with the captures, or the registration retired"

  -- CASE 3 and CASE 4: the two drops.
  linkSaid <-
    saidOnStderr $ do
      linkOpened links 9 "dev.kaya.aurora.notes://task/t2" (Map.fromList [("key", "t2")])
      linkOpened links 0 "dev.kaya.aurora.notes://nope" Map.empty
  readIORef linkSeen >>= \seen ->
    check (length seen == 3) "a route this process never declared reached a handler"
  let linkWant =
        "kaya: link dev.kaya.aurora.notes://task/t2 matched route 9 and"
          ++ " reached no handler — none is registered for it (KayaApp.link)"
  check (trim linkSaid == linkWant)
    ("the link drop was announced as " ++ show (trim linkSaid) ++ ", wanted " ++ show linkWant)

  putStrLn
    ( "link-route: OK — the declaration parks the generated record, the "
        ++ "dispatch is by route id and does not retire, an unknown route "
        ++ "announces its drop, and route 0 is silent"
    )
  where
    trim = f . f
      where
        f = reverse . dropWhile (`elem` (" \t\r\n" :: String))
