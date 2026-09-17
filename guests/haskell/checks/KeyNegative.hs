{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- A COMPILE_FAIL PROBE for the 'Key' wall: a collection key is ONE type
-- a literal already is (a string literal through IsString, an integer
-- literal through Num), so anything else in a key slot must be refused
-- AT COMPILE TIME naming 'Key'. Without this the slot's old shape — a
-- class-polymorphic 'KayaValue k' — is a thing a later edit could put
-- back, and every guest would quietly need an ascription again
-- (KayaValueNegative.hs beside this one is the same idea one class over).
--
-- NOT a cabal target: each numbered CASE is compiled ALONE with
-- -DCASE=<n> and each must FAIL naming 'Key' and this file's own
-- 'Unsupported' type — never a stray syntax or scope error:
--
--   for n in 1 2 3 4; do
--     nix develop -c ghc -fno-code -XGHC2021 -DCASE=$n \
--       -ibindings/haskell -iguests/haskell \
--       guests/haskell/checks/KeyNegative.hs
--   done
module KeyNegative where

import Data.Text (Text)
import GHC.Generics (Generic)
import KayaApp

-- Not a key, and not convertible to one: this is the type under test.
data Unsupported = Unsupported

data Note = Note {title :: Text}
  deriving stock (Generic)
  deriving anyclass (KayaRecord)

#if CASE == 0
-- CASE 0: the positive control — the same slots given a Key compile.
good :: RecordCollection Note -> Text -> Build ()
good c t = remove (recordHandle c) (textKey t)
#elif CASE == 1
-- CASE 1: a bare collection's key.
bad :: Collection -> Build ()
bad c = insert c Unsupported "v"
#elif CASE == 2
-- CASE 2: a record collection's key.
bad :: RecordCollection Note -> Build ()
bad c = insertRecord c Unsupported (Note "n")
#elif CASE == 3
-- CASE 3: the instance selector.
bad :: Collection -> Collection
bad c = c `at` Unsupported
#elif CASE == 4
-- CASE 4: A TEXT IS NOT A KEY EITHER, which is the half a literal hides:
-- a computed Text goes through 'textKey', so a slot that started taking
-- bare Texts again is caught here.
bad :: RecordCollection Note -> Text -> Build ()
bad c t = remove (recordHandle c) t
#else
#error "KeyNegative: pass -DCASE=0 (the control), 1, 2, 3 or 4"
#endif
