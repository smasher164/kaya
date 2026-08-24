{- The dynamic-table spelling, TYPECHECKED. tools/check-sugar-surface.sh
   compiles this with `ghc -fno-code` and also compiles two doctored
   copies that must be REFUSED — the Rust doc-tests' shape, in the only
   form this binding has: the zone and the copy's key path are types, so
   the compiler is the wall (docs/tables-plan.md, dynamic tables).

   The census beside it reads the binding's text; only a compiler can say
   the three surfaces fit together — that the bar reaches the template
   scope, that the handler's keys are the ones the re-declaration takes. -}

module NestedTable where

import KayaApp
import KayaWire (Value (..))

-- One table per account: the inner For is the table, its bar is declared
-- in the parent template scope, and each stamped copy sorts alone.
nested :: App -> IO ()
nested app = do
  table <- buildTx app $ do
    accounts <- collection
    (accountList, table) <- forEach accounts $ do
      positions <- collection
      -- TWO CELLS OVER A SCALAR nested collection: `collectionOf` is
      -- Build-only and `at` yields no RecordCollection, so a nested
      -- table's rows cannot carry record FIELDS in this binding yet.
      (t, _) <- forEach positions $ rowOf [label element, label element]
      columnsNode t ["Symbol", "Shares"] sortNone
      _ <- columnOf [label element, pure t]
      return t
    root <- row [pure accountList]
    mount root
    insert accounts (VStr "brokerage") (VStr "Brokerage")
    return table
  -- The keys the click carried are the keys the re-declaration takes:
  -- one copy's arrows move and its siblings' do not.
  onSortNode app table $ \keys column ->
    submitTx app (columnsAt table keys ["Symbol", "Shares"] (sortAsc column))
