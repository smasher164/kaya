{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

-- A COMPILE_FAIL PROBE for F1's KayaValue class (docs/deferred.md, the
-- idiom pass's keyed-value entry): a type with no 'KayaValue' instance
-- passed where the class demands one must be refused AT COMPILE TIME, on
-- every guest-facing call shape the class reaches — a wire-tag leak this
-- narrow would otherwise surface as a runtime crash from inside
-- 'KayaApp.toWire', not a type error a guest sees before running anything.
--
-- NOT a cabal target (kaya-guests.cabal never names this file): each
-- numbered CASE is compiled ALONE, selecting it with -DCASE=<n>, and each
-- must FAIL with "No instance for (KayaValue Unsupported)" naming this
-- file's own 'Unsupported' type — never a stray syntax or scope error,
-- which would be a probe passing for the wrong reason (the project's own
-- "watch the negative test fail" rule). Run by hand (the mechanical
-- pattern tools/check-*.py's own compile_fail-style probes use elsewhere
-- in the project; wiring this into that machinery is the coordinator's,
-- since tools/ is not this pass's to touch):
--
--   for n in 1 2 3 4; do
--     nix develop -c ghc -fno-code -fdefer-type-errors -XCPP \
--       -DCASE=$n -ibindings/haskell -iguests/haskell \
--       guests/haskell/checks/KayaValueNegative.hs
--   done
--
-- (drop -fdefer-type-errors to make the refusal a hard compile failure;
-- it is used here only so a single run can print every case's error
-- instead of stopping at the first).
module KayaValueNegative where

import Data.Text (Text)
import KayaApp

-- No 'KayaValue' instance — deliberately: this is the type under test.
data Unsupported = Unsupported

#if CASE == 1
-- CASE 1: signal's argument.
bad :: Build Signal
bad = signal Unsupported
#elif CASE == 2
-- CASE 2: writeSignal's argument.
bad :: Signal -> Build ()
bad sig = writeSignal sig Unsupported
#elif CASE == 3
-- CASE 3: a bare collection's key (insert).
bad :: Collection -> Build ()
bad c = insert c Unsupported ("v" :: Text)
#elif CASE == 4
-- CASE 4: a bare collection's value (insert) — the OTHER KayaValue slot,
-- so a wrong VALUE type is refused as loudly as a wrong KEY type.
bad :: Collection -> Build ()
bad c = insert c ("k" :: Text) Unsupported
#else
#error "KayaValueNegative: pass -DCASE=1, 2, 3 or 4"
#endif
