{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE TypeApplications #-}

-- | Smart constructors for creating Hydra protocol transactions to be used in
-- the 'Hydra.Chain.Direct' way of talking to the main-chain.
--
-- This module also encapsulates the transaction format used when talking to the
-- cardano-node, which is currently different from the 'Hydra.Ledger.Cardano',
-- thus we have not yet "reached" 'isomorphism'.
module Hydra.Chain.Direct.Tx where

import Hydra.Cardano.Api
import Hydra.Prelude

import qualified Cardano.Api.UTxO as UTxO
import Cardano.Binary (decodeFull', serialize')
import Hydra.Chain (ContestationPeriod, HeadId (..), HeadParameters (..))
import qualified Hydra.Contract.Commit as Commit
import qualified Hydra.Contract.Head as Head
import qualified Hydra.Contract.HeadState as Head
import qualified Hydra.Contract.HeadTokens as HeadTokens
import qualified Hydra.Contract.Initial as Initial
import Hydra.Contract.MintAction (MintAction (Burn, Mint))
import Hydra.Crypto (MultiSignature, toPlutusSignatures)
import Hydra.Data.ContestationPeriod (addContestationPeriod, contestationPeriodFromDiffTime, contestationPeriodToDiffTime)
import qualified Hydra.Data.ContestationPeriod as OnChain
import qualified Hydra.Data.Party as OnChain
import Hydra.Ledger.Cardano (hashTxOuts, setValidityLowerBound, setValidityUpperBound)
import Hydra.Ledger.Cardano.Builder (
  addExtraRequiredSigners,
  addInputs,
  addOutputs,
  addVkInputs,
  burnTokens,
  emptyTxBody,
  mintTokens,
  unsafeBuildTransaction,
 )
import Hydra.Party (Party, partyFromChain, partyToChain)
import Hydra.Snapshot (Snapshot (..), SnapshotNumber)
import Plutus.V1.Ledger.Api (POSIXTime, fromBuiltin, fromData, toBuiltin)
import qualified Plutus.V1.Ledger.Api as Plutus

-- | Needed on-chain data to create Head transactions.
type UTxOWithScript = (TxIn, TxOut CtxUTxO, ScriptData)

-- | Representation of the Head output after a CollectCom transaction.
data OpenThreadOutput = OpenThreadOutput
  { openThreadUTxO :: UTxOWithScript
  , openContestationPeriod :: OnChain.ContestationPeriod
  , openParties :: [OnChain.Party]
  }
  deriving (Eq, Show)

data ClosedThreadOutput = ClosedThreadOutput
  { closedThreadUTxO :: UTxOWithScript
  , closedParties :: [OnChain.Party]
  , closedContestationDeadline :: Plutus.POSIXTime
  }
  deriving (Eq, Show)

headPolicyId :: TxIn -> PolicyId
headPolicyId =
  scriptPolicyId . PlutusScript . mkHeadTokenScript

mkHeadTokenScript :: TxIn -> PlutusScript
mkHeadTokenScript =
  fromPlutusScript @PlutusScriptV1 . HeadTokens.validatorScript . toPlutusTxOutRef

hydraHeadV1AssetName :: AssetName
hydraHeadV1AssetName = AssetName (fromBuiltin Head.hydraHeadV1)

-- FIXME: sould not be hardcoded
headValue :: Value
headValue = lovelaceToValue (Lovelace 2_000_000)

-- * Create Hydra Head transactions

-- | Create the init transaction from some 'HeadParameters' and a single TxIn
-- which will be used as unique parameter for minting NFTs.
initTx ::
  NetworkId ->
  -- | Participant's cardano public keys.
  [VerificationKey PaymentKey] ->
  HeadParameters ->
  TxIn ->
  Tx
initTx networkId cardanoKeys parameters seed =
  unsafeBuildTransaction $
    emptyTxBody
      & addVkInputs [seed]
      & addOutputs
        ( mkHeadOutputInitial networkId policyId parameters :
          map (mkInitialOutput networkId policyId) cardanoKeys
        )
      & mintTokens (mkHeadTokenScript seed) Mint ((hydraHeadV1AssetName, 1) : participationTokens)
 where
  policyId = headPolicyId seed
  participationTokens =
    [(assetNameFromVerificationKey vk, 1) | vk <- cardanoKeys]

mkHeadOutput :: NetworkId -> PolicyId -> TxOutDatum ctx -> TxOut ctx
mkHeadOutput networkId tokenPolicyId =
  TxOut
    (mkScriptAddress @PlutusScriptV1 networkId headScript)
    (headValue <> valueFromList [(AssetId tokenPolicyId hydraHeadV1AssetName, 1)])
 where
  headScript = fromPlutusScript Head.validatorScript

mkHeadOutputInitial :: NetworkId -> PolicyId -> HeadParameters -> TxOut CtxTx
mkHeadOutputInitial networkId tokenPolicyId HeadParameters{contestationPeriod, parties} =
  mkHeadOutput networkId tokenPolicyId headDatum
 where
  headDatum =
    mkTxOutDatum $
      Head.Initial
        (contestationPeriodFromDiffTime contestationPeriod)
        (map partyToChain parties)

mkInitialOutput :: NetworkId -> PolicyId -> VerificationKey PaymentKey -> TxOut CtxTx
mkInitialOutput networkId tokenPolicyId (verificationKeyHash -> pkh) =
  TxOut initialAddress initialValue initialDatum
 where
  initialValue =
    headValue <> valueFromList [(AssetId tokenPolicyId (AssetName $ serialiseToRawBytes pkh), 1)]
  initialAddress =
    mkScriptAddress @PlutusScriptV1 networkId initialScript
  initialScript =
    fromPlutusScript Initial.validatorScript
  initialDatum =
    mkTxOutDatum $ Initial.datum ()

-- | Craft a commit transaction which includes the "committed" utxo as a datum.
commitTx ::
  NetworkId ->
  -- | Party identifier and corresponding cardano key of the commiter.
  (Party, VerificationKey PaymentKey) ->
  -- | A single UTxO to commit to the Head
  -- We currently limit committing one UTxO to the head because of size limitations.
  Maybe (TxIn, TxOut CtxUTxO) ->
  InitObservation ->
  Maybe Tx
commitTx networkId (party, vk) utxo initObservation = do
  (initialInput, out, _) <- ownInitial headTokenScript vk initials
  pure $
    unsafeBuildTransaction $
      emptyTxBody
        & addInputs [(initialInput, initialWitness_)]
        & addVkInputs (maybeToList mCommittedInput)
        & addExtraRequiredSigners [verificationKeyHash vk]
        & addOutputs [commitOutput out]
 where
  InitObservation{initials, headTokenScript} = initObservation

  initialWitness_ =
    BuildTxWith $ ScriptWitness scriptWitnessCtx $ mkScriptWitness initialScript initialDatum initialRedeemer
  initialScript =
    fromPlutusScript @PlutusScriptV1 Initial.validatorScript
  initialDatum =
    mkScriptDatum $ Initial.datum ()
  initialRedeemer =
    toScriptData . Initial.redeemer $
      Initial.Commit (toPlutusTxOutRef <$> mCommittedInput)
  mCommittedInput =
    fst <$> utxo
  commitOutput out =
    TxOut commitAddress (commitValue out) commitDatum
  commitScript =
    fromPlutusScript Commit.validatorScript
  commitAddress =
    mkScriptAddress @PlutusScriptV1 networkId commitScript
  commitValue out =
    txOutValue out <> maybe mempty (txOutValue . snd) utxo
  commitDatum =
    mkTxOutDatum $ mkCommitDatum party Head.validatorHash utxo

mkCommitDatum :: Party -> Plutus.ValidatorHash -> Maybe (TxIn, TxOut CtxUTxO) -> Plutus.Datum
mkCommitDatum party headValidatorHash utxo =
  Commit.datum (partyToChain party, headValidatorHash, serializedUTxO)
 where
  serializedUTxO = case utxo of
    Nothing ->
      Nothing
    Just (_i, o) ->
      Just $ Commit.SerializedTxOut (toBuiltin $ serialize' $ toLedgerTxOut o)

-- | Create a transaction collecting all "committed" utxo and opening a Head,
-- i.e. driving the Head script state.
collectComTx ::
  NetworkId ->
  -- | Party who's authorizing this transaction
  VerificationKey PaymentKey ->
  InitObservation ->
  Tx
collectComTx networkId vk initObservation =
  unsafeBuildTransaction $
    emptyTxBody
      & addInputs ((headInput, headWitness) : (mkCommit <$> orderedCommits))
      & addOutputs [headOutput]
      & addExtraRequiredSigners [verificationKeyHash vk]
 where
  InitObservation
    { threadOutput = (headInput, initialHeadOutput, ScriptDatumForTxIn -> headDatumBefore)
    , commits
    , parties
    , contestationPeriod
    } = initObservation

  orderedCommits = sortOn (\(i, _, _) -> i) commits

  headWitness =
    BuildTxWith $ ScriptWitness scriptWitnessCtx $ mkScriptWitness headScript headDatumBefore headRedeemer
  headScript =
    fromPlutusScript @PlutusScriptV1 Head.validatorScript
  headRedeemer =
    toScriptData Head.CollectCom
  headOutput =
    TxOut
      (mkScriptAddress @PlutusScriptV1 networkId headScript)
      (txOutValue initialHeadOutput <> commitValue)
      headDatumAfter
  headDatumAfter =
    mkTxOutDatum Head.Open{Head.parties = onChainParties, utxoHash, contestationPeriod = onChainContestationPeriod}

  onChainParties = partyToChain <$> parties

  utxoHash =
    Head.hashPreSerializedCommits $ mapMaybe (\(_, _, d) -> extractSerialisedTxOut d) orderedCommits

  onChainContestationPeriod = contestationPeriodFromDiffTime contestationPeriod

  -- NOTE: We hash tx outs in an order that is recoverable on-chain.
  -- The simplest thing to do, is to make sure commit inputs are in the same
  -- order as their corresponding committed utxo.
  extractSerialisedTxOut d =
    case fromData $ toPlutusData d of
      Nothing -> error "SNAFU"
      Just ((_, _, Just o) :: Commit.DatumType) -> Just o
      _ -> Nothing

  mkCommit (commitInput, _commitOutput, commitDatum) =
    ( commitInput
    , mkCommitWitness commitDatum
    )
  mkCommitWitness (ScriptDatumForTxIn -> commitDatum) =
    BuildTxWith $ ScriptWitness scriptWitnessCtx $ mkScriptWitness commitScript commitDatum commitRedeemer
  commitValue =
    foldMap (\(_, out, _) -> txOutValue out) orderedCommits
  commitScript =
    fromPlutusScript @PlutusScriptV1 Commit.validatorScript
  commitRedeemer =
    toScriptData $ Commit.redeemer Commit.CollectCom

-- | Low-level data type of a snapshot to close the head with. This is different
-- to the 'ConfirmedSnasphot', which is provided to `CloseTx` as it also
-- contains relevant chain state like the 'openUtxoHash'.
data ClosingSnapshot
  = CloseWithInitialSnapshot {openUtxoHash :: ByteString}
  | CloseWithConfirmedSnapshot
      { snapshotNumber :: SnapshotNumber
      , closeUtxoHash :: ByteString
      , -- XXX: This is a bit of a wart and stems from the fact that our
        -- SignableRepresentation of 'Snapshot' is in fact the snapshotNumber
        -- and the closeUtxoHash as also included above
        signatures :: MultiSignature (Snapshot Tx)
      }

type PointInTime = (SlotNo, POSIXTime)

-- | Create a transaction closing a head with either the initial snapshot or
-- with a multi-signed confirmed snapshot.
closeTx ::
  -- | Party who's authorizing this transaction
  VerificationKey PaymentKey ->
  -- | The snapshot to close with, can be either initial or confirmed one.
  ClosingSnapshot ->
  -- | Current slot and posix time to be recorded as the closing time.
  PointInTime ->
  -- | Everything needed to spend the Head state-machine output.
  OpenThreadOutput ->
  Tx
closeTx vk closing (slotNo, posixTime) openThreadOutput =
  unsafeBuildTransaction $
    emptyTxBody
      & addInputs [(headInput, headWitness)]
      & addOutputs [headOutputAfter]
      & addExtraRequiredSigners [verificationKeyHash vk]
      & setValidityUpperBound slotNo
 where
  OpenThreadOutput
    { openThreadUTxO = (headInput, headOutputBefore, ScriptDatumForTxIn -> headDatumBefore)
    , openContestationPeriod
    , openParties
    } = openThreadOutput

  headWitness =
    BuildTxWith $ ScriptWitness scriptWitnessCtx $ mkScriptWitness headScript headDatumBefore headRedeemer

  headScript =
    fromPlutusScript @PlutusScriptV1 Head.validatorScript

  headRedeemer =
    toScriptData
      Head.Close
        { snapshotNumber
        , utxoHash
        , signature
        }

  headOutputAfter =
    modifyTxOutDatum (const headDatumAfter) headOutputBefore

  headDatumAfter =
    mkTxOutDatum
      Head.Closed
        { snapshotNumber
        , utxoHash
        , parties = openParties
        , contestationDeadline
        }

  snapshotNumber = toInteger $ case closing of
    CloseWithInitialSnapshot{} -> 0
    CloseWithConfirmedSnapshot{snapshotNumber = sn} -> sn

  utxoHash = toBuiltin $ case closing of
    CloseWithInitialSnapshot{openUtxoHash} -> openUtxoHash
    CloseWithConfirmedSnapshot{closeUtxoHash} -> closeUtxoHash

  signature = case closing of
    CloseWithInitialSnapshot{} -> mempty
    CloseWithConfirmedSnapshot{signatures = s} -> toPlutusSignatures s

  contestationDeadline = addContestationPeriod posixTime openContestationPeriod

-- XXX: This function is VERY similar to the 'closeTx' function (only notable
-- difference being the redeemer, which is in itself also the same structure as
-- the close's one. We could potentially refactor this to avoid repetition or do
-- something more principled at the protocol level itself and "merge" close and
-- contest as one operation.
contestTx ::
  -- | Party who's authorizing this transaction
  VerificationKey PaymentKey ->
  -- | Contested snapshot number (i.e. the one we contest to)
  Snapshot Tx ->
  -- | Multi-signature of the whole snapshot
  MultiSignature (Snapshot Tx) ->
  -- | Current slot and posix time to be recorded as the closing time.
  PointInTime ->
  -- | Everything needed to spend the Head state-machine output.
  ClosedThreadOutput ->
  Tx
contestTx vk Snapshot{number, utxo} sig (slotNo, _) ClosedThreadOutput{closedThreadUTxO = (headInput, headOutputBefore, ScriptDatumForTxIn -> headDatumBefore), closedParties, closedContestationDeadline} =
  unsafeBuildTransaction $
    emptyTxBody
      & addInputs [(headInput, headWitness)]
      & addOutputs [headOutputAfter]
      & addExtraRequiredSigners [verificationKeyHash vk]
      & setValidityUpperBound slotNo
 where
  headWitness =
    BuildTxWith $ ScriptWitness scriptWitnessCtx $ mkScriptWitness headScript headDatumBefore headRedeemer
  headScript =
    fromPlutusScript @PlutusScriptV1 Head.validatorScript
  headRedeemer =
    toScriptData
      Head.Contest
        { snapshotNumber = toInteger number
        , signature = toPlutusSignatures sig
        , utxoHash
        }
  headOutputAfter =
    modifyTxOutDatum (const headDatumAfter) headOutputBefore
  headDatumAfter =
    mkTxOutDatum
      Head.Closed
        { snapshotNumber = toInteger number
        , utxoHash
        , parties = closedParties
        , contestationDeadline = closedContestationDeadline
        }
  utxoHash = toBuiltin $ hashTxOuts $ toList utxo

fanoutTx ::
  -- | Snapshotted UTxO to fanout on layer 1
  UTxO ->
  -- | Everything needed to spend the Head state-machine output.
  UTxOWithScript ->
  -- | Point in time at which this transaction is posted, used to set
  -- lower bound.
  PointInTime ->
  -- | Minting Policy script, made from initial seed
  PlutusScript ->
  Tx
fanoutTx utxo (headInput, headOutput, ScriptDatumForTxIn -> headDatumBefore) (slotNo, _) headTokenScript =
  unsafeBuildTransaction $
    emptyTxBody
      & addInputs [(headInput, headWitness)]
      & addOutputs fanoutOutputs
      & burnTokens headTokenScript Burn headTokens
      & setValidityLowerBound slotNo
 where
  headWitness =
    BuildTxWith $ ScriptWitness scriptWitnessCtx $ mkScriptWitness headScript headDatumBefore headRedeemer

  headScript =
    fromPlutusScript @PlutusScriptV1 Head.validatorScript

  headRedeemer =
    toScriptData (Head.Fanout $ fromIntegral $ length utxo)

  headTokens =
    headTokensFromValue headTokenScript (txOutValue headOutput)

  fanoutOutputs =
    map toTxContext $ toList utxo

data AbortTxError = OverlappingInputs
  deriving (Show)

-- | Create transaction which aborts a head by spending the Head output and all
-- other "initial" outputs.
abortTx ::
  -- | Party who's authorizing this transaction
  VerificationKey PaymentKey ->
  InitObservation ->
  Either AbortTxError Tx
abortTx vk initObservation
  -- XXX: Can't we encode this as an invariant / make it impossible to represent
  -- in 'InitObservation'?
  | hasOverlappingInputs =
    Left OverlappingInputs
  | otherwise =
    Right $
      unsafeBuildTransaction $
        emptyTxBody
          & addInputs ((headInput, headWitness) : initialInputs <> commitInputs)
          & addOutputs commitOutputs
          & burnTokens headTokenScript Burn headTokens
          & addExtraRequiredSigners [verificationKeyHash vk]
 where
  hasOverlappingInputs =
    isJust . find (\(i, _, _) -> i == headInput) $ initialsToAbort <> commitsToAbort

  InitObservation
    { threadOutput = (headInput, headOutput, headScriptData)
    , headTokenScript
    , initials = initialsToAbort
    , commits = commitsToAbort
    } = initObservation

  headDatumBefore = ScriptDatumForTxIn headScriptData

  headWitness =
    BuildTxWith $ ScriptWitness scriptWitnessCtx $ mkScriptWitness headScript headDatumBefore headRedeemer
  headScript =
    fromPlutusScript @PlutusScriptV1 Head.validatorScript
  headRedeemer =
    toScriptData Head.Abort

  initialInputs = mkAbortInitial <$> initialsToAbort

  commitInputs = mkAbortCommit <$> commitsToAbort

  headTokens =
    headTokensFromValue headTokenScript $
      mconcat
        [ txOutValue headOutput
        , foldMap (\(_, o, _) -> txOutValue o) initialsToAbort
        , foldMap (\(_, o, _) -> txOutValue o) commitsToAbort
        ]

  -- NOTE: Abort datums contain the datum of the spent state-machine input, but
  -- also, the datum of the created output which is necessary for the
  -- state-machine on-chain validator to control the correctness of the
  -- transition.
  mkAbortInitial (initialInput, _, ScriptDatumForTxIn -> initialDatum) =
    (initialInput, mkAbortWitness initialDatum)
  mkAbortWitness initialDatum =
    BuildTxWith $ ScriptWitness scriptWitnessCtx $ mkScriptWitness initialScript initialDatum initialRedeemer
  initialScript =
    fromPlutusScript @PlutusScriptV1 Initial.validatorScript
  initialRedeemer =
    toScriptData $ Initial.redeemer Initial.Abort

  mkAbortCommit (commitInput, _, ScriptDatumForTxIn -> commitDatum) =
    (commitInput, mkCommitWitness commitDatum)
  mkCommitWitness commitDatum =
    BuildTxWith $ ScriptWitness scriptWitnessCtx $ mkScriptWitness commitScript commitDatum commitRedeemer
  commitScript =
    fromPlutusScript @PlutusScriptV1 Commit.validatorScript
  commitRedeemer =
    toScriptData (Commit.redeemer Commit.Abort)

  commitOutputs = mapMaybe (\(_, _, d) -> mkCommitOutput d) commitsToAbort

  mkCommitOutput :: ScriptData -> Maybe (TxOut CtxTx)
  mkCommitOutput x =
    case fromData @Commit.DatumType $ toPlutusData x of
      Just (_party, _validatorHash, serialisedTxOut) ->
        toTxContext <$> convertTxOut serialisedTxOut
      Nothing -> error "Invalid Commit datum"

-- * Observe Hydra Head transactions

-- XXX: Invariant: all TxIn of threadOutput, initials and commits are disjoint
data InitObservation = InitObservation
  { -- | The state machine UTxO produced by the Init transaction
    -- This output should always be present and 'threaded' across all
    -- transactions.
    -- NOTE(SN): The Head's identifier is somewhat encoded in the TxOut's address
    -- XXX(SN): Data and [OnChain.Party] are overlapping
    threadOutput :: UTxOWithScript
  , initials :: [UTxOWithScript]
  , commits :: [UTxOWithScript]
  , headId :: HeadId
  , headTokenScript :: PlutusScript -- TODO: compute from HeadId?
  , contestationPeriod :: ContestationPeriod
  , parties :: [Party]
  }
  deriving (Show, Eq)

-- XXX(SN): We should log decisions why a tx is not an initTx etc. instead of
-- only returning a Maybe, i.e. 'Either Reason (OnChainTx tx, OnChainHeadState)'
observeInitTx ::
  NetworkId ->
  Party ->
  Tx ->
  Maybe InitObservation
observeInitTx networkId party tx = do
  -- FIXME: This is affected by "same structure datum attacks", we should be
  -- using the Head script address instead.
  (ix, headOut, headData, Head.Initial cp ps) <- findFirst headOutput indexedOutputs
  parties <- mapM partyFromChain ps
  let contestationPeriod = contestationPeriodToDiffTime cp
  guard $ party `elem` parties
  (headTokenPolicyId, _headAssetName) <- findHeadAssetId headOut
  headTokenScript <- findScriptMinting tx headTokenPolicyId
  pure
    InitObservation
      { threadOutput =
          ( mkTxIn tx ix
          , toCtxUTxOTxOut headOut
          , fromLedgerData headData
          )
      , initials
      , commits = []
      , headId = mkHeadId headTokenPolicyId
      , headTokenScript
      , contestationPeriod
      , parties
      }
 where
  headOutput = \case
    (ix, out@(TxOut _ _ (TxOutDatum d))) ->
      (ix,out,toLedgerData d,) <$> fromData (toPlutusData d)
    _ -> Nothing

  indexedOutputs = zip [0 ..] (txOuts' tx)

  initialOutputs = filter (isInitial . snd) indexedOutputs

  initials =
    mapMaybe
      ( \(i, o) -> do
          dat <- getScriptData o
          pure (mkTxIn tx i, toCtxUTxOTxOut o, dat)
      )
      initialOutputs

  isInitial (TxOut addr _ _) = addr == initialAddress

  initialAddress = mkScriptAddress @PlutusScriptV1 networkId initialScript

  initialScript = fromPlutusScript Initial.validatorScript

data CommitObservation = CommitObservation
  { commitOutput :: UTxOWithScript
  , party :: Party
  , committed :: UTxO
  }

-- | Identify a commit tx by:
--
-- - Find which 'initial' tx input is being consumed.
-- - Find the redeemer corresponding to that 'initial', which contains the tx
--   input of the committed utxo.
-- - Find the outputs which pays to the commit validator.
-- - Using the datum of that output, deserialize the comitted output.
-- - Reconstruct the committed UTxO from both values (tx input and output).
observeCommitTx ::
  NetworkId ->
  InitObservation ->
  Tx ->
  Maybe CommitObservation
observeCommitTx networkId InitObservation{initials} tx = do
  initialTxIn <- findInitialTxIn
  mCommittedTxIn <- decodeInitialRedeemer initialTxIn

  (commitIn, commitOut) <- findTxOutByAddress commitAddress tx
  dat <- getScriptData commitOut
  (onChainParty, _, serializedTxOut) <- fromData @Commit.DatumType $ toPlutusData dat
  party <- partyFromChain onChainParty
  let mCommittedTxOut = convertTxOut serializedTxOut

  committed <-
    case (mCommittedTxIn, mCommittedTxOut) of
      (Nothing, Nothing) -> Just mempty
      (Just i, Just o) -> Just $ UTxO.singleton (i, o)
      (Nothing, Just{}) -> error "found commit with no redeemer out ref but with serialized output."
      (Just{}, Nothing) -> error "found commit with redeemer out ref but with no serialized output."

  pure
    CommitObservation
      { commitOutput = (commitIn, toUTxOContext commitOut, dat)
      , party
      , committed
      }
 where
  initialTxIns = map (\(i, _, _) -> i) initials

  findInitialTxIn =
    case filter (`elem` initialTxIns) (txIns' tx) of
      [input] -> Just input
      _ -> Nothing

  decodeInitialRedeemer =
    findRedeemerSpending tx >=> \case
      Initial.Abort ->
        Nothing
      Initial.Commit{committedRef} ->
        Just (fromPlutusTxOutRef <$> committedRef)

  commitAddress = mkScriptAddress @PlutusScriptV1 networkId commitScript

  commitScript = fromPlutusScript Commit.validatorScript

convertTxOut :: Maybe Commit.SerializedTxOut -> Maybe (TxOut CtxUTxO)
convertTxOut = \case
  Nothing -> Nothing
  Just (Commit.SerializedTxOut outBytes) ->
    -- XXX(SN): these errors might be more severe and we could throw an
    -- exception here?
    case fromLedgerTxOut <$> decodeFull' (fromBuiltin outBytes) of
      Right result -> Just result
      Left{} -> error "couldn't deserialize serialized output in commit's datum."

data CollectComObservation = CollectComObservation
  { threadOutput :: OpenThreadOutput
  , headId :: HeadId
  , utxoHash :: ByteString
  }
  deriving (Show, Eq)

-- | Identify a collectCom tx by lookup up the input spending the Head output
-- and decoding its redeemer.
observeCollectComTx ::
  -- | A UTxO set to lookup tx inputs
  UTxO ->
  Tx ->
  Maybe CollectComObservation
observeCollectComTx utxo tx = do
  (headInput, headOutput) <- findScriptOutput @PlutusScriptV1 utxo headScript
  redeemer <- findRedeemerSpending tx headInput
  oldHeadDatum <- lookupScriptData tx headOutput
  datum <- fromData $ toPlutusData oldHeadDatum
  headId <- findStateToken headOutput
  case (datum, redeemer) of
    (Head.Initial{parties, contestationPeriod}, Head.CollectCom) -> do
      (newHeadInput, newHeadOutput) <- findScriptOutput @PlutusScriptV1 (utxoFromTx tx) headScript
      newHeadDatum <- lookupScriptData tx newHeadOutput
      utxoHash <- decodeUtxoHash newHeadDatum
      pure
        CollectComObservation
          { threadOutput =
              OpenThreadOutput
                { openThreadUTxO =
                    ( newHeadInput
                    , newHeadOutput
                    , newHeadDatum
                    )
                , openParties = parties
                , openContestationPeriod = contestationPeriod
                }
          , headId
          , utxoHash
          }
    _ -> Nothing
 where
  headScript = fromPlutusScript Head.validatorScript
  decodeUtxoHash datum =
    case fromData $ toPlutusData datum of
      Just Head.Open{utxoHash} -> Just $ fromBuiltin utxoHash
      _ -> Nothing

data CloseObservation = CloseObservation
  { threadOutput :: ClosedThreadOutput
  , headId :: HeadId
  , snapshotNumber :: SnapshotNumber
  }
  deriving (Show, Eq)

-- | Identify a close tx by lookup up the input spending the Head output and
-- decoding its redeemer.
observeCloseTx ::
  -- | A UTxO set to lookup tx inputs
  UTxO ->
  Tx ->
  Maybe CloseObservation
observeCloseTx utxo tx = do
  (headInput, headOutput) <- findScriptOutput @PlutusScriptV1 utxo headScript
  redeemer <- findRedeemerSpending tx headInput
  oldHeadDatum <- lookupScriptData tx headOutput
  datum <- fromData $ toPlutusData oldHeadDatum
  headId <- findStateToken headOutput
  case (datum, redeemer) of
    (Head.Open{parties}, Head.Close{snapshotNumber = onChainSnapshotNumber}) -> do
      (newHeadInput, newHeadOutput) <- findScriptOutput @PlutusScriptV1 (utxoFromTx tx) headScript
      newHeadDatum <- lookupScriptData tx newHeadOutput
      closeContestationDeadline <- case fromData (toPlutusData newHeadDatum) of
        Just Head.Closed{contestationDeadline} -> pure contestationDeadline
        _ -> Nothing
      snapshotNumber <- integerToNatural onChainSnapshotNumber
      pure
        CloseObservation
          { threadOutput =
              ClosedThreadOutput
                { closedThreadUTxO =
                    ( newHeadInput
                    , newHeadOutput
                    , newHeadDatum
                    )
                , closedParties = parties
                , closedContestationDeadline = closeContestationDeadline
                }
          , headId
          , snapshotNumber
          }
    _ -> Nothing
 where
  headScript = fromPlutusScript Head.validatorScript

data ContestObservation = ContestObservation
  { contestedThreadOutput :: (TxIn, TxOut CtxUTxO, ScriptData)
  , headId :: HeadId
  , snapshotNumber :: SnapshotNumber
  }
  deriving (Show, Eq)

-- | Identify a close tx by lookup up the input spending the Head output and
-- decoding its redeemer.
observeContestTx ::
  -- | A UTxO set to lookup tx inputs
  UTxO ->
  Tx ->
  Maybe ContestObservation
observeContestTx utxo tx = do
  (headInput, headOutput) <- findScriptOutput @PlutusScriptV1 utxo headScript
  redeemer <- findRedeemerSpending tx headInput
  oldHeadDatum <- lookupScriptData tx headOutput
  datum <- fromData $ toPlutusData oldHeadDatum
  headId <- findStateToken headOutput
  case (datum, redeemer) of
    (Head.Closed{}, Head.Contest{snapshotNumber = onChainSnapshotNumber}) -> do
      (newHeadInput, newHeadOutput) <- findScriptOutput @PlutusScriptV1 (utxoFromTx tx) headScript
      newHeadDatum <- lookupScriptData tx newHeadOutput
      snapshotNumber <- integerToNatural onChainSnapshotNumber
      pure
        ContestObservation
          { contestedThreadOutput =
              ( newHeadInput
              , newHeadOutput
              , newHeadDatum
              )
          , headId
          , snapshotNumber
          }
    _ -> Nothing
 where
  headScript = fromPlutusScript Head.validatorScript

data FanoutObservation = FanoutObservation

-- | Identify a fanout tx by lookup up the input spending the Head output and
-- decoding its redeemer.
observeFanoutTx ::
  -- | A UTxO set to lookup tx inputs
  UTxO ->
  Tx ->
  Maybe FanoutObservation
observeFanoutTx utxo tx = do
  headInput <- fst <$> findScriptOutput @PlutusScriptV1 utxo headScript
  findRedeemerSpending tx headInput
    >>= \case
      Head.Fanout{} -> pure FanoutObservation
      _ -> Nothing
 where
  headScript = fromPlutusScript Head.validatorScript

data AbortObservation = AbortObservation

-- | Identify an abort tx by looking up the input spending the Head output and
-- decoding its redeemer.
-- FIXME: Add headId to AbortObservation to allow "upper layers" to
-- determine we are seeing an abort of "our head"
observeAbortTx ::
  -- | A UTxO set to lookup tx inputs
  UTxO ->
  Tx ->
  Maybe AbortObservation
observeAbortTx utxo tx = do
  headInput <- fst <$> findScriptOutput @PlutusScriptV1 utxo headScript
  findRedeemerSpending tx headInput >>= \case
    Head.Abort -> pure AbortObservation
    _ -> Nothing
 where
  headScript = fromPlutusScript Head.validatorScript

-- * Functions related to OnChainHeadState

-- | Look for the "initial" which corresponds to given cardano verification key.
ownInitial ::
  PlutusScript ->
  VerificationKey PaymentKey ->
  [UTxOWithScript] ->
  Maybe (TxIn, TxOut CtxUTxO, Hash PaymentKey)
ownInitial headTokenScript vkey =
  foldl' go Nothing
 where
  go (Just x) _ = Just x
  go Nothing (i, out, _) = do
    let vkh = verificationKeyHash vkey
    guard $ hasMatchingPT vkh (txOutValue out)
    pure (i, out, vkh)

  hasMatchingPT :: Hash PaymentKey -> Value -> Bool
  hasMatchingPT vkh val =
    case headTokensFromValue headTokenScript val of
      [(AssetName bs, 1)] -> bs == serialiseToRawBytes vkh
      _ -> False

mkHeadId :: PolicyId -> HeadId
mkHeadId =
  HeadId . serialiseToRawBytes

-- * Helpers

headTokensFromValue :: PlutusScript -> Value -> [(AssetName, Quantity)]
headTokensFromValue headTokenScript v =
  [ (assetName, q)
  | (AssetId pid assetName, q) <- valueToList v
  , pid == scriptPolicyId (PlutusScript headTokenScript)
  ]

assetNameFromVerificationKey :: VerificationKey PaymentKey -> AssetName
assetNameFromVerificationKey =
  AssetName . serialiseToRawBytes . verificationKeyHash

-- | Find first occurrence including a transformation.
findFirst :: Foldable t => (a -> Maybe b) -> t a -> Maybe b
findFirst fn = getFirst . foldMap (First . fn)

findHeadAssetId :: TxOut ctx -> Maybe (PolicyId, AssetName)
findHeadAssetId txOut =
  flip findFirst (valueToList $ txOutValue txOut) $ \case
    (AssetId pid aname, q)
      | aname == hydraHeadV1AssetName && q == 1 ->
        Just (pid, aname)
    _ ->
      Nothing

-- | Find (if it exists) the head identifier contained in given `TxOut`.
findStateToken :: TxOut ctx -> Maybe HeadId
findStateToken =
  fmap (mkHeadId . fst) . findHeadAssetId
