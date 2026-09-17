{-# LANGUAGE OverloadedStrings #-}

-- The confirm scene, Haskell port — guests/rust/confirm.rs,
-- tools/scenes/confirm.steps.

import qualified Data.Text as T
import KayaApp

main :: IO ()
main = kayaMain $ \app -> do
  status <- buildTx app $ do
    window primary [WTitle "confirm"]
    s <- signal (T.pack "no decision")
    root <-
      column
        []
        [ labelBound s, -- label#0
          buttonOn "delete" $
            buildTx app $
              showAlert
                [ ATitle "delete item?",
                  AMessage "this cannot be undone",
                  AAction "Delete",
                  AAction "Archive",
                  ACancel "Keep"
                ]
                ( \choice ->
                    buildTx app $
                      writeSignal s $
                        T.pack ( if choice == alertChoiceCancel
                              then "kept"
                              else if choice == 1 then "archived" else "deleted"
                          )
                ),
          buttonOn "eject" $
            buildTx app $
              showAlert
                [ ATitle "eject disk?",
                  AMessage "it is still mounted",
                  AAction "Eject",
                  ACancel "Hold"
                ]
                ( \choice ->
                    buildTx app $
                      writeSignal s $
                        T.pack (if choice == alertChoiceCancel then "held" else "ejected")
                )
        ]
    mount root
    return s
  _ <- return status
  return ()
