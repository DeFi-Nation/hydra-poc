{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Unit tests for our "hand-rolled" transactions as they are used in the
-- "direct" chain component.
module Hydra.Chain.Direct.Fixture where

import Hydra.Prelude

import Cardano.Ledger.Alonzo.Language (Language (PlutusV1))
import Cardano.Ledger.Alonzo.PParams (PParams, PParams' (..))
import Cardano.Ledger.Alonzo.Scripts (ExUnits (..), Prices (..))
import Cardano.Ledger.BaseTypes (ProtVer (..), boundRational)
import Data.Bits (shift)
import Data.Default (def)
import qualified Data.Map as Map
import Data.Maybe (fromJust)
import Data.Ratio ((%))
import Hydra.Chain.Direct.Util (Era)
import Hydra.Ledger.Cardano (ProtocolParameters, ShelleyBasedEra (ShelleyBasedEraAlonzo), fromLedgerPParams)
import Plutus.V1.Ledger.Api (PubKeyHash (PubKeyHash), toBuiltin)
import Test.Cardano.Ledger.Alonzo.PlutusScripts (defaultCostModel)
import Test.Cardano.Ledger.Alonzo.Serialisation.Generators ()
import Test.QuickCheck.Instances ()

maxTxSize :: Int64
maxTxSize = 1 `shift` 14

protocolParams :: ProtocolParameters
protocolParams = fromLedgerPParams ShelleyBasedEraAlonzo pparams

pparams :: PParams Era
pparams =
  def
    { _costmdls = Map.singleton PlutusV1 $ fromJust defaultCostModel
    , _maxValSize = 1000000000
    , _maxTxExUnits = ExUnits 10000000000 10000000000
    , _maxBlockExUnits = ExUnits 10000000000 10000000000
    , _protocolVersion = ProtVer 5 0
    , _prices =
        Prices
          { prMem = fromJust $ boundRational $ 721 % 10000000
          , prSteps = fromJust $ boundRational $ 577 % 10000
          }
    }

instance Arbitrary PubKeyHash where
  arbitrary = PubKeyHash . toBuiltin <$> (arbitrary :: Gen ByteString)
