{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-specialize #-}

module Hydra.Contract.OffChain where

import Ledger
import Prelude hiding (init)

import Control.Arrow (second)
import Control.Monad (forever, void)
import Hydra.Contract.OnChain as OnChain (asDatum, asRedeemer)
import Ledger.Ada (lovelaceValueOf)
import Ledger.AddressMap (UtxoMap)
import Ledger.Constraints.OffChain (ScriptLookups (..))
import Ledger.Constraints.TxConstraints (
  TxConstraints,
  mustBeSignedBy,
  mustForgeCurrency,
  mustForgeValue,
  mustIncludeDatum,
  mustPayToOtherScript,
  mustPayToPubKey,
  mustPayToTheScript,
  mustSpendPubKeyOutput,
  mustSpendScriptOutput,
 )
import Ledger.Credential (Credential (..))
import Ledger.Typed.Scripts (ScriptInstance, ScriptType (..))
import Plutus.Contract (
  AsContractError,
  BlockchainActions,
  Contract,
  Endpoint,
  endpoint,
  select,
  submitTxConstraints,
  submitTxConstraintsWith,
  tell,
  utxoAt,
  type (.\/),
 )
import Plutus.Contract.Effects.AwaitTxConfirmed (awaitTxConfirmed)
import Plutus.Contract.Effects.UtxoAt (HasUtxoAt)

import qualified Data.Map.Strict as Map
import qualified Hydra.Contract.OnChain as OnChain
import qualified Ledger.Typed.Scripts as Scripts
import qualified Ledger.Value as Value

--
-- Head Parameters
--

data HeadParameters = HeadParameters
  { participants :: [PubKeyHash]
  , policy :: MonetaryPolicy
  , policyId :: MonetaryPolicyHash
  }

mkHeadParameters :: [PubKeyHash] -> MonetaryPolicy -> HeadParameters
mkHeadParameters participants policy =
  HeadParameters{participants, policy, policyId}
 where
  policyId = monetaryPolicyHash policy

--
-- Init
--

-- The initial transaction has `n` outputs, where each output is locked by a
-- validator 'νinitial' and the i-th output has k_i in its data field.
-- The validator 'νinitial' ensures the following:
--   - either the output is consumed by an abort transaction, or
--   - it is consumed by a commit transaction.
--
-- It also initialises the state-machine,
init ::
  (AsContractError e) =>
  HeadParameters ->
  Contract [OnChain.State] Schema e ()
init params@HeadParameters{participants, policy, policyId} = do
  endpoint @"init" @()
  void $ submitTxConstraintsWith lookups constraints
  tell [OnChain.Initial]
 where
  lookups =
    mempty
      { slMPS =
          Map.singleton policyId policy
      , slScriptInstance =
          Just (hydraScriptInstance params)
      }

  constraints =
    mconcat
      [ foldMap
          ( \vk ->
              let participationToken = OnChain.mkParticipationToken policyId vk
               in mconcat
                    [ mustPayToOtherScript
                        (Scripts.scriptHash $ initialScriptInstance params)
                        (asDatum @(DatumType OnChain.Initial) vk)
                        participationToken
                    , mustForgeValue
                        participationToken
                    ]
          )
          participants
      , mustPayToTheScript OnChain.Initial (lovelaceValueOf 0)
      ]

-- To lock outputs for a Hydra head, the i-th head member will attach a commit
-- transaction to the i-th output of the initial transaction.
--
-- Validator `νCommit` ensures that the commit transaction correctly records the
-- partial UTxO set Ui committed by the party.
commit ::
  (AsContractError e) =>
  HeadParameters ->
  Contract [OnChain.State] Schema e ()
commit params@HeadParameters{policy, policyId} = do
  (vk, toCommit) <- endpoint @"commit" @(PubKeyHash, (TxOutRef, TxOutTx))
  initial <-
    utxoAtWithDatum
      (Scripts.scriptAddress $ initialScriptInstance params)
      (asDatum @(DatumType OnChain.Initial) vk)
  void $
    submitTxConstraintsWith
      (lookups vk toCommit initial)
      (constraints vk toCommit initial)
 where
  lookups vk (ref, txOut) initial =
    mempty
      { slMPS =
          Map.singleton policyId policy
      , slScriptInstance =
          Just (hydraScriptInstance params)
      , slTxOutputs =
          initial <> Map.singleton ref txOut
      , slOtherScripts =
          Map.fromList
            [ (Scripts.scriptAddress script, Scripts.validatorScript script)
            | SomeScriptInstance script <-
                [ SomeScriptInstance $ initialScriptInstance params
                ]
            ]
      , slOwnPubkey =
          Just vk
      }

  constraints vk (ref, txOut) initial =
    let amount = txOutValue (txOutTxOut txOut) <> OnChain.mkParticipationToken policyId vk
     in mconcat
          [ mustBeSignedBy vk
          , -- NOTE: using a 'foldMap' here but that 'initial' utxo really has only one
            -- element!
            foldMap
              (`mustSpendScriptOutput` asRedeemer @(RedeemerType OnChain.Initial) ref)
              (Map.keys initial)
          , mustSpendPubKeyOutput ref
          , mustPayToOtherScript
              (Scripts.scriptHash $ commitScriptInstance params)
              (asDatum @(DatumType OnChain.Commit) (txOutTxOut txOut))
              amount
          ]

-- The SM transition from initial to open is achieved by posting the collectCom
-- transaction.
--
-- All head parameters remain part of the state.
--
-- In addition, information about the initial UTxO set, which is made up of the
-- individual UTxO sets Ui collected from the commit transactions, is stored in
-- the state.
--
-- It is also required that all n participation tokens be present in the output
-- of the collectCom transaction.
--
-- Finally, note that the transition requires a proof that the signer is one of
-- the head members.
collectCom ::
  (AsContractError e) =>
  HeadParameters ->
  Contract [OnChain.State] Schema e ()
collectCom params@HeadParameters{participants, policy, policyId} = do
  (headMember, storedOutputs) <- endpoint @"collectCom" @(PubKeyHash, [TxOut])
  commits <- utxoAt (Scripts.scriptAddress $ commitScriptInstance params)
  stateMachine <- utxoAt (Scripts.scriptAddress $ hydraScriptInstance params)
  tx <-
    submitTxConstraintsWith @OnChain.Hydra
      (lookups commits stateMachine headMember)
      (constraints commits stateMachine headMember storedOutputs)
  awaitTxConfirmed (txId tx)
  tell [OnChain.Open storedOutputs]
 where
  lookups commits stateMachine headMember =
    mempty
      { slMPS =
          Map.singleton policyId policy
      , slScriptInstance =
          Just (hydraScriptInstance params)
      , slOtherScripts =
          Map.fromList
            [ (Scripts.scriptAddress script, Scripts.validatorScript script)
            | SomeScriptInstance script <-
                [ SomeScriptInstance $ commitScriptInstance params
                , SomeScriptInstance $ hydraScriptInstance params
                ]
            ]
      , slTxOutputs =
          commits <> stateMachine
      , slOwnPubkey =
          Just headMember
      }

  constraints commits stateMachine headMember storedOutputs =
    let amount = foldMap (txOutValue . snd) $ flattenUtxo (commits <> stateMachine)
     in mconcat
          [ mustBeSignedBy headMember
          , foldMap
              (\ref -> mustSpendScriptOutput ref $ asRedeemer @(RedeemerType OnChain.Hydra) OnChain.CollectCom)
              (Map.keys stateMachine)
          , foldMap
              (\(_, ref) -> mustSpendScriptOutput ref $ asRedeemer @(RedeemerType OnChain.Commit) ())
              (zipOnParticipationToken policyId participants commits)
          , foldMap
              (mustIncludeDatum . asDatum @(DatumType OnChain.Commit))
              storedOutputs
          , mustPayToTheScript (OnChain.Open $ reverse storedOutputs) amount
          ]

abort ::
  (AsContractError e) =>
  HeadParameters ->
  Contract [OnChain.State] Schema e ()
abort params@HeadParameters{participants, policy, policyId} = do
  (headMember, toRefund) <- endpoint @"abort" @(PubKeyHash, [TxOut])
  initial <- utxoAt (Scripts.scriptAddress $ initialScriptInstance params)
  commits <- utxoAt (Scripts.scriptAddress $ commitScriptInstance params)
  stateMachine <- utxoAt (Scripts.scriptAddress $ hydraScriptInstance params)
  tx <-
    submitTxConstraintsWith @OnChain.Hydra
      (lookups initial commits stateMachine headMember)
      (constraints initial commits stateMachine toRefund headMember)
  awaitTxConfirmed (txId tx)
  tell [OnChain.Final]
 where
  lookups initial commits stateMachine headMember =
    mempty
      { slMPS =
          Map.singleton policyId policy
      , slScriptInstance =
          Just (hydraScriptInstance params)
      , slOtherScripts =
          Map.fromList
            [ (Scripts.scriptAddress script, Scripts.validatorScript script)
            | SomeScriptInstance script <-
                [ SomeScriptInstance $ initialScriptInstance params
                , SomeScriptInstance $ commitScriptInstance params
                , SomeScriptInstance $ hydraScriptInstance params
                ]
            ]
      , slTxOutputs =
          initial <> commits <> stateMachine
      , slOwnPubkey =
          Just headMember
      }

  constraints initial commits stateMachine toRefund headMember =
    mconcat
      [ mustBeSignedBy headMember
      , mustPayToTheScript OnChain.Final (lovelaceValueOf 0)
      , foldMap
          (\vk -> mustForgeCurrency policyId (OnChain.mkParticipationTokenName vk) (-1))
          participants
      , foldMap mustRefund toRefund
      , foldMap
          (\(_vk, ref) -> mustSpendScriptOutput ref $ asRedeemer @(RedeemerType OnChain.Initial) ref)
          (zipOnParticipationToken policyId participants initial)
      , foldMap
          (\(_vk, ref) -> mustSpendScriptOutput ref $ asRedeemer @(RedeemerType OnChain.Commit) ())
          (zipOnParticipationToken policyId participants commits)
      , foldMap
          (`mustSpendScriptOutput` asRedeemer @(RedeemerType OnChain.Hydra) OnChain.Abort)
          (Map.keys stateMachine)
      ]

-- | This endpoint allows for setting up a wallet for testing, that is, a wallet
-- that has several UTxO, so that one can be locked and the other used to pay
-- for fees.
setupForTesting ::
  (AsContractError e) =>
  HeadParameters ->
  Contract [OnChain.State] Schema e ()
setupForTesting params = do
  (vk, coins) <- endpoint @"setupForTesting" @(PubKeyHash, [Value])
  tx <- submitTxConstraints (hydraScriptInstance params) (constraints vk coins)
  awaitTxConfirmed (txId tx)
 where
  constraints vk =
    foldMap (mustPayToPubKey vk)

type Schema =
  BlockchainActions
    .\/ Endpoint "setupForTesting" (PubKeyHash, [Value])
    .\/ Endpoint "init" ()
    .\/ Endpoint "commit" (PubKeyHash, (TxOutRef, TxOutTx))
    .\/ Endpoint "collectCom" (PubKeyHash, [TxOut])
    .\/ Endpoint "abort" (PubKeyHash, [TxOut])

contract ::
  (AsContractError e) =>
  HeadParameters ->
  Contract [OnChain.State] Schema e ()
contract params = forever endpoints
 where
  endpoints =
    setupForTesting params
      `select` init params
      `select` commit params
      `select` collectCom params
      `select` abort params

--
-- Helpers
--

data SomeScriptInstance = forall a. SomeScriptInstance (ScriptInstance a)

hydraScriptInstance :: HeadParameters -> Scripts.ScriptInstance OnChain.Hydra
hydraScriptInstance =
  OnChain.hydraScriptInstance . toOnChainHeadParameters

initialScriptInstance :: HeadParameters -> Scripts.ScriptInstance OnChain.Initial
initialScriptInstance =
  OnChain.initialScriptInstance . toOnChainHeadParameters

commitScriptInstance :: HeadParameters -> Scripts.ScriptInstance OnChain.Commit
commitScriptInstance =
  OnChain.commitScriptInstance . toOnChainHeadParameters

toOnChainHeadParameters :: HeadParameters -> OnChain.HeadParameters
toOnChainHeadParameters HeadParameters{participants, policyId} =
  OnChain.HeadParameters participants policyId

flattenUtxo :: UtxoMap -> [(TxOutRef, TxOut)]
flattenUtxo =
  fmap (second txOutTxOut) . Map.assocs

mustRefund ::
  forall i o.
  TxOut ->
  TxConstraints i o
mustRefund txOut =
  case txOutAddress txOut of
    (Address (PubKeyCredential vk) _) ->
      mustPayToPubKey vk (txOutValue txOut)
    (Address ScriptCredential{} _) ->
      error "mustRefund: committing script output isn't allowed."

utxoAtWithDatum ::
  forall w s e.
  (AsContractError e, HasUtxoAt s) =>
  Address ->
  Datum ->
  Contract w s e UtxoMap
utxoAtWithDatum addr datum = do
  utxo <- utxoAt addr
  pure $ Map.filter matchDatum utxo
 where
  matchDatum txOut =
    txOutDatumHash (txOutTxOut txOut) == Just (datumHash datum)

-- When collecting commits, we need to associate each commit utxo to the
-- corresponding head member keys. There's no guarantee that head members will
-- commit in the order they are defined in the head parameters, so just
-- "zipping" doesn't do it.
--
-- Instead, we must associate each commited utxo to their key using the
-- participation token that they all carry.
zipOnParticipationToken ::
  MonetaryPolicyHash ->
  [PubKeyHash] ->
  UtxoMap ->
  [(PubKeyHash, TxOutRef)]
zipOnParticipationToken policyId vks utxo =
  go [] (flattenUtxo utxo) vks []
 where
  go acc [] _ _ = acc
  go acc _ [] _ = acc
  go acc (u : qu) (vk : qv) qv' =
    if u `hasParticipationToken` vk
      then go ((vk, fst u) : acc) qu (qv ++ qv') []
      else go acc (u : qu) qv (vk : qv')

  hasParticipationToken :: (TxOutRef, TxOut) -> PubKeyHash -> Bool
  hasParticipationToken (_, txOut) vk =
    let currency = Value.mpsSymbol policyId
        token = OnChain.mkParticipationTokenName vk
     in Value.valueOf (txOutValue txOut) currency token > 0
