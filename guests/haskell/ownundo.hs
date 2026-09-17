{-# LANGUAGE OverloadedStrings #-}

-- The app-owned undo scene, Haskell port — guests/rust/ownundo.rs,
-- tools/scenes/ownundo.steps (docs/rich-text-plan.md R6, §14).

import Data.IORef (newIORef, readIORef, writeIORef)

import Data.Text (Text)
import qualified Data.Text as T
import KayaApp

-- The label and the two live answers the route reads, in one transaction.
publishIn :: Signal -> Widget -> [Document] -> [Document] -> Build ()
publishIn status owned undos redos = do
  writeSignal
    status
    (T.pack ("undo " ++ show (length undos) ++ " redo " ++ show (length redos)))
  canUndo owned (not (null undos))
  canRedo owned (not (null redos))

main :: IO ()
main = kayaMain $ \app -> do
  -- THE APP'S OWN HISTORY: the document before each user edit, and the
  -- documents an undo took away. The binding's mirror is the document
  -- AFTER the edit it just delivered.
  undoRef <- newIORef ([] :: [Document])
  redoRef <- newIORef ([] :: [Document])
  currentRef <- newIORef (documentOf "")

  (owned, status) <- buildTx app $ do
    status <- signal (T.pack "undo 0 redo 0")

    -- Realized here because the menu handlers below need their handles.
    native <- textarea [Rich True, A11yId ("native" :: Text), A11yLabel ("Native" :: Text)]
    owned <-
      textarea [Rich True, OwnUndo True, A11yId ("owned" :: Text), A11yLabel ("Owned" :: Text)]

    let onUndo = do
          undos <- readIORef undoRef
          case undos of
            [] -> return ()
            (before : rest) -> do
              current <- readIORef currentRef
              redos <- readIORef redoRef
              let redos' = current : redos
              writeIORef undoRef rest
              writeIORef redoRef redos'
              writeIORef currentRef before
              submitTx app $ do
                setDocument app owned before
                publishIn status owned rest redos'
        onRedo = do
          redos <- readIORef redoRef
          case redos of
            [] -> return ()
            (after : rest) -> do
              current <- readIORef currentRef
              undos <- readIORef undoRef
              let undos' = current : undos
              writeIORef redoRef rest
              writeIORef undoRef undos'
              writeIORef currentRef after
              submitTx app $ do
                setDocument app owned after
                publishIn status owned undos' rest

    window
      primary
      [ WTitle "ownundo",
        WMenus
          [ menu
              "Edit"
              []
              [ item "Undo" [IRole roleUndo, IOnActivate onUndo],
                item "Redo" [IRole roleRedo, IOnActivate onRedo]
              ]
          ]
      ]

    root <-
      column
        []
        [ labelBound status [A11yId ("status" :: Text)], -- label#0
          pure native, -- textarea#0
          pure owned, -- textarea#1
          row
            []
            [ -- button#0
              buttonOn "focus native" (submitTx app (focusWidget native)),
              -- button#1
              buttonOn "focus owned" (submitTx app (focusWidget owned))
            ]
        ]
    mount root
    return (owned, status)

  onEdit app owned $ \_ -> do
    current <- readIORef currentRef
    doc <- document app owned
    undos <- readIORef undoRef
    let undos' = current : undos
    writeIORef undoRef undos'
    writeIORef redoRef []
    writeIORef currentRef doc
    submitTx app (publishIn status owned undos' [])
