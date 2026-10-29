{-# LANGUAGE OverloadedStrings #-}

-- The document-tabs scene, Haskell port — guests/rust/doctabs.rs,
-- tools/scenes/doctabs.steps (docs/doctabs-plan.md §5): three documents, one
-- armed against a close, a shared region beside them, the "+", and a
-- programmatic select that echoes nothing.

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Word (Word64)
import KayaApp

docA, docB, docC, notes :: Word64
docA = 10
docB = 11
docC = 12
notes = 30

names :: [(Word64, T.Text)]
names = [(docA, "a"), (docB, "b"), (docC, "c")]

main :: IO ()
main = kayaMain $ \app -> do
  untitled <- newIORef (0 :: Word64)
  regions <- newIORef (0 :: Word64)
  buildTx app $ do
    status <- signalText "ready"

    -- THE ONE BUILDER every window's shared region comes from, the first
    -- window's and a torn-out one's alike (docs/doctabs-plan.md §1.2).
    let region w n = do
          addRegionIn w n RegionLeading
          root <-
            column
              []
              [ labelBound status [A11yId "status"],
                entryOn (const (return ())) [A11yId "note"],
                buttonOn "to a" (submitTx app (selectDocument docA)) [A11yId "first"]
              ]
          mountIn n root

    let newDocument = do
          modifyIORef' untitled (+ 1)
          k <- readIORef untitled
          let name = "untitled " <> T.pack (show k)
              n = 100 + k
          submitTx app $ do
            addDocument n [DTitle name]
            selectDocument n
            caption <- signalText (name <> " body")
            root <- column [] [labelBound caption]
            mountIn n root
            writeSignal status ("new " <> name)
        detached w documents = do
          modifyIORef' regions (+ 1)
          k <- readIORef regions
          let moved = T.unwords [fromMaybe "untitled" (lookup d names) | d <- documents]
          submitTx app $ do
            region w (300 + k)
            writeSignal status ("detached " <> moved)

    window
      primary
      [ WTitle "doctabs",
        WSize 640 420,
        WNewDocument True,
        WOnNewDocument newDocument,
        WOnDocumentsCloseRequested
          (\documents -> submitTx app (writeSignal status ("asked about " <> T.pack (show (length documents))))),
        WOnDocumentsDetached detached
      ]

    let askClose =
          submitTx app $
            showAlert
              [ ATitle "unsaved changes",
                AMessage "b has unsaved changes",
                AAction "Discard",
                ACancel "Keep Editing"
              ]
              ( \choice ->
                  submitTx app $
                    if choice == AlertCancel
                      then writeSignal status "kept b"
                      else do
                        closeDocument docB
                        writeSignal status "discarded b"
              )

    mapM_
      ( \(n, name) -> do
          let armed = n == docB
              say text = submitTx app (writeSignal status text)
          addDocument
            n
            ( [ DTitle name,
                DTooltip ("/documents/" <> name),
                DOnSelected (say ("selected " <> name)),
                DOnClosed (say ("closed " <> name)),
                DOnMoved (\_ at -> say ("moved " <> name <> " to " <> T.pack (show at)))
              ]
                <> (if armed then [DInterceptClose True, DOnCloseRequested askClose] else [])
            )
          caption <- signalText (name <> " body")
          let mark = submitTx app $ do
                updateDocument docB [DDirty True]
                writeSignal status "marked b"
          root <-
            column
              []
              ( [ labelBound caption [A11yId ("body-" <> name)],
                  entryOn (const (return ())) [A11yId ("field-" <> name)]
                ]
                  <> [buttonOn "mark b" mark [A11yId "mark"] | armed]
              )
          mountIn n root
      )
      names
    region primary notes
