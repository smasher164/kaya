{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeApplications #-}

{- The dynamic-table spelling, TYPECHECKED. tools/check-sugar-surface.py
   compiles this with `ghc -fno-code` and also compiles doctored copies
   that must be REFUSED — the Rust doc-tests' shape, in the only form
   this binding has: the zone, the copy's key path and the row's record
   type are types, so the compiler is the wall (docs/tables-plan.md,
   dynamic tables).

   The census beside it reads the binding's text; only a compiler can say
   the surfaces fit together — that the bar reaches the template scope,
   that the handler's keys are the ones the re-declaration takes, and
   that a collection declared inside the template scope stays
   record-typed all the way to the mutation that fills ONE copy. -}

module NestedTable where

import Data.Proxy (Proxy (..))
import GHC.Generics (Generic)

import KayaApp
import KayaWire (Value (..))

data Position = Position {symbol :: String, shares :: String}
  deriving (Generic)

instance KayaRecord Position

-- One table per account: the inner For is the table, its bar is declared
-- in the parent template scope, and each stamped copy sorts alone.
nested :: App -> IO ()
nested app = do
  table <- buildTx app $ do
    accounts <- collection
    (accountList, (table, positions)) <- forEach accounts $ do
      -- DECLARED INSIDE THE TEMPLATE SCOPE, which the core requires of a
      -- nested collection, AND record-typed: the row's two cells are the
      -- record's two fields rather than the one string a scalar
      -- collection's element can be.
      positions <- collectionOf (Proxy :: Proxy Position)
      (t, _) <-
        forEach (recordHandle positions) $
          rowOf
            [ label (field @"symbol" @Position),
              label (field @"shares" @Position)
            ]
      columns t ["Symbol", "Shares"] sortNone
      _ <- columnOf [label element, pure t]
      return (t, positions)
    root <- row [pure accountList]
    mount root
    insert accounts (VStr "brokerage") (VStr "Brokerage")
    -- ONE COPY'S ROWS. `at` carries the record type across the key path,
    -- so the stamped instance is filled with records; a Collection here
    -- would take a bare Value and the row's fields would be unreachable.
    insertRecord (positions `at` VStr "brokerage") (VStr "aapl")
      (Position "AAPL" "10")
    return table
  -- The keys the click carried are the keys the re-declaration takes:
  -- one copy's arrows move and its siblings' do not.
  onSort app table $ \keys column ->
    submitTx app (columnsAt table keys ["Symbol", "Shares"] (sortAsc column))
