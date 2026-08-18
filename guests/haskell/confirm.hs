-- The confirm conformance scene, Haskell port — the modal-alert
-- grammar. The three rounds take the three answer paths (action 0,
-- action 1, alertChoiceCancel, which covers every platform-native
-- dismissal). See guests/rust/confirm.rs and tools/scenes/confirm.steps.

import KayaApp
import KayaWire (Value (..), alertChoiceCancel)

main :: IO ()
main = kayaMain $ \app -> do
  status <- buildTx app $ do
    window 0 [WTitle "confirm"]
    s <- signal (VStr "no decision")
    root <-
      column
        []
        [ labelBound s, -- label#0
          -- The result handler rides the request and retires with its
          -- one answer; ids are binding-allocated.
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
                        VStr
                          ( if choice == alertChoiceCancel
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
                        VStr (if choice == alertChoiceCancel then "held" else "ejected")
                )
        ]
    mount root
    return s
  -- `status` keeps the signal alive for the scene's lifetime.
  _ <- return status
  return ()
