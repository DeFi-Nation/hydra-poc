{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Chain component implementation which uses directly the Node-to-Client
-- protocols to submit "hand-rolled" transactions including Plutus validators and
-- observing the chain using it as well.
module Hydra.Chain.Direct (
  NetworkMagic (NetworkMagic),
  withIOManager,
  module Hydra.Chain.Direct,
) where

import Hydra.Prelude

import Cardano.Ledger.Alonzo.Language (Language (PlutusV1))
import Cardano.Ledger.Alonzo.Rules.Utxo (UtxoPredicateFailure (UtxosFailure))
import Cardano.Ledger.Alonzo.Rules.Utxos (TagMismatchDescription (FailedUnexpectedly), UtxosPredicateFailure (ValidationTagMismatch))
import Cardano.Ledger.Alonzo.Rules.Utxow (AlonzoPredFail (WrappedShelleyEraFailure))
import Cardano.Ledger.Alonzo.Tx (ValidatedTx)
import Cardano.Ledger.Alonzo.TxInfo (FailureDescription (PlutusFailure), debugPlutus)
import Cardano.Ledger.Alonzo.TxSeq (txSeqTxns)
import Cardano.Ledger.Crypto (StandardCrypto)
import Cardano.Ledger.Shelley.API (ApplyTxError (ApplyTxError), TxId)
import qualified Cardano.Ledger.Shelley.API as Ledger
import Cardano.Ledger.Shelley.Rules.Ledger (LedgerPredicateFailure (UtxowFailure))
import Cardano.Ledger.Shelley.Rules.Utxow (UtxowPredicateFailure (UtxoFailure))
import Control.Exception (IOException)
import Control.Monad (foldM)
import Control.Monad.Class.MonadSTM (
  newEmptyTMVar,
  newTQueueIO,
  newTVarIO,
  putTMVar,
  readTQueue,
  retry,
  takeTMVar,
  writeTQueue,
  writeTVar,
 )
import Control.Monad.Class.MonadTimer (timeout)
import Control.Tracer (nullTracer)
import Data.Aeson (Value (String), object, (.=))
import Data.List ((\\))
import Data.Sequence.Strict (StrictSeq)
import Hydra.Cardano.Api (
  ChainPoint,
  NetworkId,
  PaymentKey,
  SigningKey,
  Tx,
  VerificationKey,
  fromLedgerTx,
  fromLedgerTxIn,
  fromLedgerUTxO,
  toConsensusPointHF,
  toLedgerTx,
  toLedgerUTxO,
 )
import Hydra.Chain (
  Chain (..),
  ChainCallback,
  ChainComponent,
  ChainState (ChainState),
  OnChainTx (..),
  PostChainTx (..),
  PostTxError (..),
 )
import Hydra.Chain.Direct.State (
  SomeOnChainHeadState (..),
  TokHeadState (..),
  abort,
  close,
  collect,
  commit,
  fanout,
  getKnownUTxO,
  idleOnChainHeadState,
  initialize,
  observeSomeTx,
  reifyState,
 )
import Hydra.Chain.Direct.Util (
  Block,
  Era,
  SomePoint (..),
  defaultCodecs,
  nullConnectTracers,
  versions,
 )
import Hydra.Chain.Direct.Wallet (
  ErrCoverFee (..),
  TinyWallet (..),
  TinyWalletLog,
  getFuelUTxO,
  getTxId,
  withTinyWallet,
 )
import Hydra.Logging (Tracer, traceWith)
import Hydra.Party (Party)
import Ouroboros.Consensus.Cardano.Block (GenTx (..), HardForkApplyTxErr (ApplyTxErrAlonzo), HardForkBlock (BlockAlonzo))
import Ouroboros.Consensus.Ledger.SupportsMempool (ApplyTxErr)
import Ouroboros.Consensus.Network.NodeToClient (Codecs' (..))
import Ouroboros.Consensus.Shelley.Ledger (ShelleyBlock (..))
import Ouroboros.Consensus.Shelley.Ledger.Mempool (mkShelleyTx)
import Ouroboros.Network.Block (Point (..), Tip (..), getTipPoint)
import Ouroboros.Network.Magic (NetworkMagic (..))
import Ouroboros.Network.Mux (
  MuxMode (..),
  MuxPeer (MuxPeer),
  OuroborosApplication (..),
  RunMiniProtocol (..),
 )
import Ouroboros.Network.NodeToClient (
  IOManager,
  LocalAddress,
  NodeToClientProtocols (..),
  NodeToClientVersion,
  connectTo,
  localSnocket,
  localStateQueryPeerNull,
  nodeToClientProtocols,
  withIOManager,
 )
import Ouroboros.Network.Protocol.ChainSync.Client (
  ChainSyncClient (..),
  ClientStIdle (..),
  ClientStIntersect (..),
  ClientStNext (..),
  chainSyncClientPeer,
 )
import Ouroboros.Network.Protocol.LocalTxSubmission.Client (
  LocalTxClientStIdle (..),
  LocalTxSubmissionClient (..),
  SubmitResult (..),
  localTxSubmissionClientPeer,
 )
import Test.Cardano.Ledger.Alonzo.Serialisation.Generators ()

withDirectChain ::
  -- | Tracer for logging
  Tracer IO DirectChainLog ->
  -- | Network identifer to which we expect to connect.
  NetworkId ->
  -- | A cross-platform abstraction for managing I/O operations on local sockets
  IOManager ->
  -- | Path to a domain socket used to connect to the server.
  FilePath ->
  -- | Key pair for the wallet.
  (VerificationKey PaymentKey, SigningKey PaymentKey) ->
  -- | Hydra party of our hydra node.
  Party ->
  -- | Cardano keys of all Head participants (including our key pair).
  [VerificationKey PaymentKey] ->
  -- | Point at which to start following the chain.
  Maybe ChainPoint ->
  ChainComponent Tx IO a
withDirectChain tracer networkId iocp socketPath keyPair party cardanoKeys point callback action = do
  queue <- newTQueueIO
  withTinyWallet (contramap Wallet tracer) networkId keyPair iocp socketPath $ \wallet -> do
    headState <-
      newTVarIO $
        SomeOnChainHeadState $
          idleOnChainHeadState
            networkId
            (cardanoKeys \\ [verificationKey wallet])
            (verificationKey wallet)
            party
    res <-
      race
        ( do
            -- FIXME: There's currently a race-condition with the actual client
            -- which will only see transactions after it has established
            -- connection with the server's tip. So any transaction submitted
            -- before that tip will be missed.
            --
            -- The way we handle rollbacks is also wrong because it'll
            -- fast-forward to the tip, and not allow recovering intermediate
            -- history.
            threadDelay 2
            action $
              Chain
                { postTx = \tx -> do
                    -- NOTE: trace would include full ChainState!
                    traceWith tracer $ ToPost tx
                    -- XXX(SN): 'finalizeTx' retries until a payment utxo is
                    -- found. See haddock for details
                    response <-
                      timeoutThrowAfter (NoPaymentInput @Tx) 10 $
                        -- FIXME (MB): 'cardanoKeys' should really not be here. They
                        -- are only required for the init transaction and ought to
                        -- come from the _client_ and be part of the init request
                        -- altogether. This goes in the direction of 'dynamic
                        -- heads' where participants aren't known upfront but
                        -- provided via the API. Ultimately, an init request from
                        -- a client would contain all the details needed to
                        -- establish connection to the other peers and to
                        -- bootstrap the init transaction.
                        -- For now, we bear with it and keep the static keys in
                        -- context.
                        fromPostChainTx cardanoKeys wallet headState tx
                          >>= finalizeTx wallet headState . toLedgerTx
                          >>= \vtx -> do
                            response <- newEmptyTMVar
                            writeTQueue queue (vtx, response)
                            return response
                    atomically (takeTMVar response) >>= \case
                      Nothing -> pure ()
                      Just err -> throwIO err
                }
        )
        ( handle onIOException $
            connectTo
              (localSnocket iocp)
              nullConnectTracers
              (versions networkId (client tracer (toConsensusPointHF <$> point) queue headState callback))
              socketPath
        )
    case res of
      Left a -> pure a
      Right () -> error "'connectTo' cannot terminate but did?"
 where
  timeoutThrowAfter ex s stm = do
    timeout s (atomically stm) >>= \case
      Nothing -> throwIO ex
      Just a -> pure a

  onIOException :: IOException -> IO ()
  onIOException ioException =
    throwIO $
      ConnectException
        { ioException
        , socketPath
        , networkId
        }

data ConnectException = ConnectException
  { ioException :: IOException
  , socketPath :: FilePath
  , networkId :: NetworkId
  }
  deriving (Show)

instance Exception ConnectException

data IntersectionNotFoundException = IntersectionNotFound
  { requestedPoint :: Point Block
  }
  deriving (Show)

instance Exception IntersectionNotFoundException

client ::
  (MonadST m, MonadTimer m, MonadThrow m) =>
  Tracer m DirectChainLog ->
  Maybe (Point Block) ->
  TQueue m (ValidatedTx Era, TMVar m (Maybe (PostTxError Tx))) ->
  TVar m SomeOnChainHeadState ->
  ChainCallback Tx m ->
  NodeToClientVersion ->
  OuroborosApplication 'InitiatorMode LocalAddress LByteString m () Void
client tracer point queue headState callback nodeToClientV =
  nodeToClientProtocols
    ( const $
        pure $
          NodeToClientProtocols
            { localChainSyncProtocol =
                InitiatorProtocolOnly $
                  let peer = chainSyncClient tracer callback headState point
                   in MuxPeer nullTracer cChainSyncCodec (chainSyncClientPeer peer)
            , localTxSubmissionProtocol =
                InitiatorProtocolOnly $
                  let peer = txSubmissionClient tracer queue
                   in MuxPeer nullTracer cTxSubmissionCodec (localTxSubmissionClientPeer peer)
            , localStateQueryProtocol =
                InitiatorProtocolOnly $
                  let peer = localStateQueryPeerNull
                   in MuxPeer nullTracer cStateQueryCodec peer
            }
    )
    nodeToClientV
 where
  Codecs
    { cChainSyncCodec
    , cTxSubmissionCodec
    , cStateQueryCodec
    } = defaultCodecs nodeToClientV

chainSyncClient ::
  forall m.
  (MonadSTM m, MonadThrow m) =>
  Tracer m DirectChainLog ->
  ChainCallback Tx m ->
  TVar m SomeOnChainHeadState ->
  Maybe (Point Block) ->
  ChainSyncClient Block (Point Block) (Tip Block) m ()
chainSyncClient tracer callback headState = \case
  Nothing ->
    ChainSyncClient (pure initStIdle)
  Just startingPoint ->
    ChainSyncClient $
      pure $ do
        SendMsgFindIntersect
          [startingPoint]
          ( clientStIntersect
              (\_ -> throwIO (IntersectionNotFound startingPoint))
          )
 where
  -- NOTE:
  -- We fast-forward the chain client to the current node's tip on start, and
  -- from there, follow the chain block by block as they arrive. This is why the
  -- chain client here has no state (and needs no persistence of previously seen
  -- headers). It fits with the narrative of heads being online all-the-time;
  -- history prior to when the client is created is thus not needed.
  --
  -- To acquire the chain tip, we leverage the fact that in any responses, the
  -- server will send its current tip, which can then find an intersection with.
  -- Hence the first `SendMsgRequestNext` which sole purpose is to get the
  -- server's tip. Note that the findIntersect can fail after that if the server
  -- switches to a different chain fork in between the two calls, in which case
  -- we'll start over the last step with the new tip.
  initStIdle :: ClientStIdle Block (Point Block) (Tip Block) m ()
  initStIdle = SendMsgRequestNext initStNext (pure initStNext)
   where
    initStNext :: ClientStNext Block (Point Block) (Tip Block) m ()
    initStNext =
      ClientStNext
        { recvMsgRollForward = \_ (getTipPoint -> tip) ->
            ChainSyncClient $
              pure $
                SendMsgFindIntersect [tip] (clientStIntersect initStIntersect)
        , recvMsgRollBackward = \_ (getTipPoint -> tip) ->
            ChainSyncClient $
              pure $
                SendMsgFindIntersect [tip] (clientStIntersect initStIntersect)
        }

    initStIntersect :: Point Block -> m (ClientStIdle Block (Point Block) (Tip Block) m ())
    initStIntersect tip =
      pure $ SendMsgFindIntersect [tip] (clientStIntersect initStIntersect)

  clientStIntersect ::
    (Point Block -> m (ClientStIdle Block (Point Block) (Tip Block) m ())) ->
    ClientStIntersect Block (Point Block) (Tip Block) m ()
  clientStIntersect onIntersectionNotFound =
    ClientStIntersect
      { recvMsgIntersectFound = \_ _ ->
          ChainSyncClient (pure clientStIdle)
      , recvMsgIntersectNotFound = \(getTipPoint -> tip) ->
          ChainSyncClient $ onIntersectionNotFound tip
      }

  clientStIdle :: ClientStIdle Block (Point Block) (Tip Block) m ()
  clientStIdle = SendMsgRequestNext clientStNext (pure clientStNext)

  -- FIXME: rolling forward with a transaction does not necessarily mean that we
  -- can't roll backward. Or said differently, the block / transactions yielded
  -- by the server are not necessarily settled. Settlement only happens after a
  -- while and we will have to carefully consider how we want to handle
  -- rollbacks. What happen if an 'init' transaction is rolled back?
  --
  -- At the moment, we trigger the callback directly, though we may want to
  -- perhaps only yield transactions through the callback once they have
  -- 'settled' and keep a short buffer of pending transactions in the network
  -- layer directly? To be discussed.
  clientStNext :: ClientStNext Block (Point Block) (Tip Block) m ()
  clientStNext =
    ClientStNext
      { recvMsgRollForward = \blk _tip -> do
          ChainSyncClient $ do
            let receivedTxs = toList $ getAlonzoTxs blk
            forM_ receivedTxs $ \tx ->
              -- TODO: logging on call-site of callback or make callback monadic
              callback $ \chainState -> do
                -- TODO: extract chain-specific st from chainState
                let st = undefined chainState
                case observeSomeTx (fromLedgerTx tx) st of
                  Just (onChainTx, _st') -> do
                    -- TODO: Hydra.Direct.State would store st' now in onChainTx as chainState.
                    Just onChainTx
                  Nothing ->
                    Nothing
            pure clientStIdle
      , recvMsgRollBackward = \point _tip ->
          ChainSyncClient $ do
            traceWith tracer $ RolledBackward $ SomePoint point
            pure clientStIdle
      }

txSubmissionClient ::
  forall m.
  (MonadSTM m) =>
  Tracer m DirectChainLog ->
  TQueue m (ValidatedTx Era, TMVar m (Maybe (PostTxError Tx))) ->
  LocalTxSubmissionClient (GenTx Block) (ApplyTxErr Block) m ()
txSubmissionClient tracer queue =
  LocalTxSubmissionClient clientStIdle
 where
  clientStIdle :: m (LocalTxClientStIdle (GenTx Block) (ApplyTxErr Block) m ())
  clientStIdle = do
    (tx, response) <- atomically $ readTQueue queue
    traceWith tracer (PostingTx (getTxId tx, tx))
    pure $
      SendMsgSubmitTx
        (GenTxAlonzo . mkShelleyTx $ tx)
        ( \case
            SubmitSuccess -> do
              traceWith tracer (PostedTx (getTxId tx))
              atomically (putTMVar response Nothing)
              clientStIdle
            SubmitFail reason -> do
              atomically (putTMVar response (Just $ onFail reason))
              clientStIdle
        )

  -- XXX(SN): patch-work error pretty printing on single plutus script failures
  onFail err =
    case err of
      ApplyTxErrAlonzo (ApplyTxError [failure]) ->
        fromMaybe failedToPostTx (unwrapPlutus failure)
      _ ->
        failedToPostTx
   where
    failedToPostTx = FailedToPostTx{failureReason = show err}

  unwrapPlutus :: LedgerPredicateFailure Era -> Maybe (PostTxError Tx)
  unwrapPlutus = \case
    UtxowFailure (WrappedShelleyEraFailure (UtxoFailure (UtxosFailure (ValidationTagMismatch _ (FailedUnexpectedly [PlutusFailure plutusFailure debug]))))) ->
      Just $ PlutusValidationFailed{plutusFailure, plutusDebugInfo = show (debugPlutus PlutusV1 (decodeUtf8 debug))}
    _ ->
      Nothing

-- | Balance and sign the given partial transaction.
--
-- XXX(SN): This function does 'retry' when no payment UTXO was found and thus
-- might block. This is necessary in some situations when the wallet has not yet
-- "seen" the change output although the direct chain client observed a
-- transaction already. This is a smell and we should try to avoid having this
-- race condition in the first place.
finalizeTx ::
  (MonadSTM m, MonadThrow (STM m)) =>
  TinyWallet m ->
  TVar m SomeOnChainHeadState ->
  ValidatedTx Era ->
  STM m (ValidatedTx Era)
finalizeTx TinyWallet{sign, getUTxO, coverFee} headState partialTx = do
  headUTxO <- (\(SomeOnChainHeadState st) -> getKnownUTxO st) <$> readTVar headState
  walletUTxO <- fromLedgerUTxO . Ledger.UTxO <$> getUTxO
  coverFee (Ledger.unUTxO $ toLedgerUTxO headUTxO) partialTx >>= \case
    Left ErrNoPaymentUTxOFound ->
      retry
    Left ErrUnknownInput{input} -> do
      throwIO
        ( CannotSpendInput
            { input = show input
            , walletUTxO
            , headUTxO
            } ::
            PostTxError Tx
        )
    Left e ->
      throwIO
        ( CannotCoverFees
            { walletUTxO
            , headUTxO
            , reason = show e
            , tx = fromLedgerTx partialTx
            } ::
            PostTxError Tx
        )
    Right validatedTx -> do
      pure $ sign validatedTx

fromPostChainTx ::
  (MonadSTM m, MonadThrow (STM m)) =>
  [VerificationKey PaymentKey] ->
  TinyWallet m ->
  TVar m SomeOnChainHeadState ->
  PostChainTx Tx ->
  STM m Tx
fromPostChainTx cardanoKeys wallet someHeadState tx = do
  -- TODO: use this existential as 'ChainState tx'
  SomeOnChainHeadState st <- readTVar someHeadState
  case (tx, reifyState st) of
    (InitTx params, TkIdle) -> do
      getFuelUTxO wallet >>= \case
        Just (fromLedgerTxIn -> seedInput, _) -> do
          pure $ initialize params cardanoKeys seedInput st
        Nothing ->
          throwIO (NoSeedInput @Tx)
    (AbortTx{}, TkInitialized) -> do
      pure (abort st)
    -- NOTE / TODO: 'CommitTx' also contains a 'Party' which seems redundant
    -- here. The 'Party' is already part of the state and it is the only party
    -- which can commit from this Hydra node.
    (CommitTx{committed}, TkInitialized) -> do
      either throwIO pure (commit committed st)
    -- TODO: We do not rely on the utxo from the collect com tx here because the
    -- chain head-state is already tracking UTXO entries locked by commit scripts,
    -- and thus, can re-construct the committed UTXO for the collectComTx from
    -- the commits' datums.
    --
    -- Perhaps we do want however to perform some kind of sanity check to ensure
    -- that both states are consistent.
    (CollectComTx{}, TkInitialized) -> do
      pure (collect st)
    (CloseTx{confirmedSnapshot}, TkOpen) ->
      pure (close confirmedSnapshot st)
    (FanoutTx{utxo}, TkClosed) ->
      pure (fanout utxo st)
    (_, _) ->
      throwIO $ InvalidStateToPost tx

--
-- Helpers
--

-- | This extract __Alonzo__ transactions from a block. If the block wasn't
-- produced in the Alonzo era, it returns a empty sequence.
getAlonzoTxs :: Block -> StrictSeq (ValidatedTx Era)
getAlonzoTxs = \case
  BlockAlonzo (ShelleyBlock (Ledger.Block _ txsSeq) _) ->
    txSeqTxns txsSeq
  _ ->
    mempty

--
-- Tracing
--

-- TODO add  ToJSON, FromJSON instances
data DirectChainLog
  = ToPost {toPost :: PostChainTx Tx}
  | PostingTx {postedTx :: (TxId StandardCrypto, ValidatedTx Era)}
  | PostedTx {postedTxId :: TxId StandardCrypto}
  | ReceivedTxs {onChainTxs :: [OnChainTx Tx], receivedTxs :: [(TxId StandardCrypto, ValidatedTx Era)]}
  | RolledBackward {point :: SomePoint}
  | Wallet TinyWalletLog
  deriving (Eq, Show, Generic)

instance Arbitrary DirectChainLog where
  arbitrary = genericArbitrary

instance ToJSON DirectChainLog where
  toJSON = \case
    ToPost{toPost} ->
      object
        [ "tag" .= String "ToPost"
        , "toPost" .= toPost
        ]
    PostingTx{postedTx} ->
      object
        [ "tag" .= String "PostingTx"
        , "postedTx" .= postedTx
        ]
    PostedTx{postedTxId} ->
      object
        [ "tag" .= String "PostedTx"
        , "postedTxId" .= postedTxId
        ]
    ReceivedTxs{onChainTxs, receivedTxs} ->
      object
        [ "tag" .= String "ReceivedTxs"
        , "onChainTxs" .= onChainTxs
        , "receivedTxs" .= receivedTxs
        ]
    RolledBackward{point} ->
      object
        [ "tag" .= String "RolledBackward"
        , "point" .= show @Text point
        ]
    Wallet log ->
      object
        [ "tag" .= String "Wallet"
        , "contents" .= log
        ]
