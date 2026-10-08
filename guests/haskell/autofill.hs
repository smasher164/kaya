{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}

-- The content type scene, Haskell port — guests/rust/autofill.rs,
-- tools/scenes/autofill.steps (docs/autofill-plan.md §5): a sign-in form,
-- a sign-up form, a code field and a phone field, each saying what it
-- holds; a button that turns the sign-in name into an email address and
-- back; and a stamped code field.

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import GHC.Generics (Generic)
import KayaApp

data Account = Account {name :: Text}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

main :: IO ()
main = kayaMain $ \app -> do
  email <- newIORef False
  buildTx app $ do
    accounts <- collectionOf @Account
    mode <- signalText "sign in with a username"

    user <- entry [Placeholder "Username", ContentType ContentTypeUsername, A11yId "user"]
    (rows, _) <- forEach (recordHandle accounts) $ do
      pin <- withTplAttrs [TplContentType ContentTypeOneTimeCode, TplA11yId "pin"] secureField
      _ <- rowOf [label (field @"name" @Account), pure pin]
      return ()

    root <-
      column
        []
        [ pure user,
          secureField [Placeholder "Password", ContentType ContentTypePassword, A11yId "password"],
          labelBound mode [A11yId "mode"],
          buttonOn
            "Use email"
            ( do
                modifyIORef' email not
                now <- readIORef email
                submitTx app $
                  if now
                    then do
                      setContentType user ContentTypeEmail
                      writeSignal mode "sign in with an email address"
                    else do
                      setContentType user ContentTypeUsername
                      writeSignal mode "sign in with a username"
            )
            [A11yId "switch"],
          entry [Placeholder "Email", ContentType ContentTypeEmail, A11yId "email"],
          secureField [Placeholder "New password", ContentType ContentTypeNewPassword, A11yId "new"],
          entry [Placeholder "Code", ContentType ContentTypeOneTimeCode, A11yId "code"],
          entry [Placeholder "Phone", ContentType ContentTypePhone, A11yId "phone"],
          entry [Placeholder "Note", A11yId "note"],
          pure rows
        ]
    mount root
    insertRecord accounts (textKey "a") (Account "a")
