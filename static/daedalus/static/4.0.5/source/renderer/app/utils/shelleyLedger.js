// @flow
import {
  utils,
  TxOutputDestinationType,
  AddressType,
} from '@cardano-foundation/ledgerjs-hw-app-cardano';
import { encode } from 'borc';
import blakejs from 'blakejs';
import _ from 'lodash';
import {
  derivationPathToLedgerPath,
  CERTIFICATE_TYPE,
} from './hardwareWalletUtils';
import { deriveXpubChannel } from '../ipc/getHardwareWalletChannel';
import { AddressStyles } from '../domains/WalletAddress';

// Types
import type {
  CoinSelectionInput,
  CoinSelectionOutput,
  CoinSelectionCertificate,
  CoinSelectionWithdrawal,
  CoinSelectionAssetsType,
} from '../api/transactions/types';
import type {
  BIP32Path,
  Certificate,
} from '../../../common/types/hardware-wallets.types';
import type { AddressStyle } from '../api/addresses/types';

export type ShelleyTxInputType = {
  coins: number,
  address: string,
  txid: string,
  outputNo: number,
  encodeCBOR: Function,
};

export type ShelleyTxOutputType = {
  address: string,
  coins: number | [number, Map<Buffer, Map<Buffer, number>>],
  isChange: boolean,
  spendingPath: ?BIP32Path,
  stakingPath: ?BIP32Path,
  encodeCBOR: Function,
};

export type ShelleyFeeType = {
  fee: number,
  encodeCBOR: Function,
};

export type ShelleyTtlType = {
  ttl: number,
  encodeCBOR: Function,
};

export type ShelleyTxWitnessType = {
  publicKey: string,
  signature: Buffer,
  encodeCBOR: Function,
};

export type ShelleyTxAuxType = {
  getId: Function,
  inputs: Array<ShelleyTxInputType>,
  outputs: Array<ShelleyTxOutputType>,
  fee: ShelleyFeeType,
  ttl: ShelleyTtlType,
  certs: Array<?Certificate>,
  withdrawals: ?ShelleyTxWithdrawalsType,
  encodeCBOR: Function,
};

export type ShelleyTxWithdrawalsType = {
  withdrawals: Array<CoinSelectionWithdrawal>,
  encodeCBOR: Function,
};

// Constants
export const HARDENED_THRESHOLD = 0x80000000;
export const derivationScheme = {
  type: 'v2',
  ed25519Mode: 2,
  keyfileVersion: '2.0.0',
};

// Constructors
export const ShelleyTxWitnessShelley = (
  publicKey: string,
  signature: Buffer
) => {
  function encodeCBOR(encoder: any) {
    return encoder.pushAny([publicKey, signature]);
  }
  return {
    publicKey,
    signature,
    encodeCBOR,
  };
};

export const ShelleyTxInputFromUtxo = (utxoInput: CoinSelectionInput) => {
  const { address, amount, id, index } = utxoInput;
  const coins = amount.quantity;
  const outputNo = index;
  const txHash = Buffer.from(id, 'hex');

  function encodeCBOR(encoder: any) {
    return encoder.pushAny([txHash, outputNo]);
  }

  return {
    txid: id,
    coins,
    address,
    outputNo,
    encodeCBOR,
  };
};

export const groupTokensByPolicyId = (assets: CoinSelectionAssetsType) => {
  const compareStringsCanonically = (string1: string, string2: string) =>
    string1.length - string2.length || string1.localeCompare(string2);

  const groupedAssets = {};
  _(assets)
    .orderBy(['policyId', 'assetName'], ['asc', 'asc'])
    .groupBy(({ policyId }) => policyId)
    .mapValues((tokens) =>
      tokens.map(({ assetName, quantity, policyId }) => ({
        assetName,
        quantity,
        policyId,
      }))
    )
    .map((tokens, policyId) => ({
      policyId,
      assets: tokens.sort((token1, token2) =>
        compareStringsCanonically(token1.assetName, token2.assetName)
      ),
    }))
    .sort((token1, token2) =>
      compareStringsCanonically(token1.policyId, token2.policyId)
    )
    .value()
    .map((sortedAssetsGroup) => {
      groupedAssets[sortedAssetsGroup.policyId] = sortedAssetsGroup.assets;
      return groupedAssets;
    });
  return groupedAssets;
};

export const ShelleyTxOutputAssets = (assets: CoinSelectionAssetsType) => {
  const policyIdMap = new Map<Buffer, Map<Buffer, number>>();

  const tokenObject = groupTokensByPolicyId(assets);

  Object.entries(tokenObject).forEach(([policyId, tokens]) => {
    const assetMap = new Map<Buffer, number>();
    _.map(tokens, (token) => {
      assetMap.set(Buffer.from(token.assetName, 'hex'), token.quantity);
    });
    policyIdMap.set(Buffer.from(policyId, 'hex'), assetMap);
  });
  return policyIdMap;
};

export const prepareTokenBundle = (assets: CoinSelectionAssetsType) => {
  const tokenObject = groupTokensByPolicyId(assets);
  const tokenObjectEntries = Object.entries(tokenObject);

  const tokenBundle = _.map(tokenObjectEntries, ([policyId, tokens]) => {
    const tokensList = tokens.map(({ assetName, quantity }) => ({
      assetNameHex: assetName,
      amount: quantity.toString(),
    }));
    return {
      policyIdHex: policyId,
      tokens: tokensList,
    };
  });
  return tokenBundle;
};

export const ShelleyTxOutput = (
  output: CoinSelectionOutput,
  addressStyle: AddressStyle
) => {
  const { address, amount, derivationPath, assets } = output;
  const adaCoinQuantity = amount.quantity;
  const coins =
    assets && assets.length > 0
      ? [adaCoinQuantity, ShelleyTxOutputAssets(assets)]
      : adaCoinQuantity;

  function encodeCBOR(encoder: any) {
    const addressBuff =
      addressStyle === AddressStyles.ADDRESS_SHELLEY
        ? utils.bech32_decodeAddress(address)
        : utils.base58_decode(address);
    return encoder.pushAny([addressBuff, coins]);
  }

  const isChange = derivationPath !== null;
  return {
    address,
    coins,
    isChange,
    spendingPath: isChange ? derivationPathToLedgerPath(derivationPath) : null,
    stakingPath: isChange ? [2147485500, 2147485463, 2147483648, 2, 0] : null,
    encodeCBOR,
  };
};

export const ShelleyTxCert = (cert: {
  type: string,
  accountAddress: string,
  pool: ?string,
}) => {
  const { type, accountAddress, pool } = cert;
  let hash;
  let poolHash;
  if (pool) {
    poolHash = utils.buf_to_hex(utils.bech32_decodeAddress(pool));
    hash = Buffer.from(poolHash, 'hex');
  }

  function encodeCBOR(encoder: any) {
    const accountAddressHash = utils
      .bech32_decodeAddress(accountAddress)
      .slice(1);
    const account = [0, accountAddressHash];
    const encodedCertsTypes = {
      [0]: [type, account],
      [1]: [type, account],
      [2]: [type, account, hash],
    };
    return encoder.pushAny(encodedCertsTypes[type]);
  }
  return {
    address: accountAddress,
    type,
    accountAddress,
    poolHash: poolHash || null,
    encodeCBOR,
  };
};

export const ShelleyTxWithdrawal = (
  withdrawals: Array<CoinSelectionWithdrawal>
) => {
  function encodeCBOR(encoder: any) {
    const withdrawalMap = new Map();
    _.map(withdrawals, (withdrawal) => {
      const rewardAccount = utils.bech32_decodeAddress(withdrawal.stakeAddress);
      const coin = withdrawal.amount.quantity;
      withdrawalMap.set(rewardAccount, coin);
    });
    return encoder.pushAny(withdrawalMap);
  }
  return {
    withdrawals,
    encodeCBOR,
  };
};

export const prepareLedgerCertificate = (cert: CoinSelectionCertificate) => {
  return {
    type: CERTIFICATE_TYPE[cert.certificateType],
    params: {
      path: derivationPathToLedgerPath(cert.rewardAccountPath),
      poolKeyHashHex: cert.pool
        ? utils.buf_to_hex(utils.bech32_decodeAddress(cert.pool))
        : null,
    },
  };
};

export const prepareLedgerWithdrawal = (
  withdrawal: CoinSelectionWithdrawal
) => {
  return {
    path: derivationPathToLedgerPath(withdrawal.derivationPath),
    amount: withdrawal.amount.quantity.toString(),
  };
};

export const ShelleyFee = (fee: number) => {
  function encodeCBOR(encoder: any) {
    return encoder.pushAny(fee);
  }
  return {
    fee,
    encodeCBOR,
  };
};

export const ShelleyTtl = (ttl: number) => {
  function encodeCBOR(encoder: any) {
    return encoder.pushAny(ttl);
  }
  return {
    ttl,
    encodeCBOR,
  };
};

export const ShelleyTxAux = (
  inputs: Array<ShelleyTxInputType>,
  outputs: Array<ShelleyTxOutputType>,
  fee: ShelleyFeeType,
  ttl: ShelleyTtlType,
  certs: Array<?Certificate>,
  withdrawals: ?ShelleyTxWithdrawalsType
) => {
  const blake2b = (data) => blakejs.blake2b(data, null, 32);
  function getId() {
    return blake2b(
      encode(ShelleyTxAux(inputs, outputs, fee, ttl, certs, withdrawals))
      // 32
    ).toString('hex');
  }

  function encodeCBOR(encoder: any) {
    const txMap = new Map();
    txMap.set(0, inputs);
    txMap.set(1, outputs);
    txMap.set(2, fee);
    txMap.set(3, ttl);
    if (certs && certs.length) txMap.set(4, certs);
    if (withdrawals) txMap.set(5, withdrawals);
    return encoder.pushAny(txMap);
  }

  return {
    getId,
    inputs,
    outputs,
    fee,
    ttl,
    certs,
    withdrawals,
    encodeCBOR,
  };
};

export const ShelleySignedTransactionStructured = (
  txAux: ShelleyTxAuxType,
  witnesses: Map<number, ShelleyTxWitnessType>,
  meta: ?any // @TODO - TBD once meta introduced
) => {
  function getId() {
    return txAux.getId();
  }

  function encodeCBOR(encoder: any) {
    return encoder.pushAny([txAux, witnesses, meta]);
  }

  return {
    getId,
    witnesses,
    txAux,
    encodeCBOR,
  };
};

export const CachedDeriveXpubFactory = (deriveXpubHardenedFn: Function) => {
  const derivedXpubs = {};
  let xpubMemo;

  const deriveXpub = async (
    absDerivationPath: Array<number>,
    xpubHex: ?string
  ) => {
    if (xpubHex) xpubMemo = xpubHex;
    const memoKey = JSON.stringify(absDerivationPath);
    let derivedXpubsMemo = await derivedXpubs[memoKey];

    if (!derivedXpubsMemo) {
      const deriveHardened =
        absDerivationPath.length === 0 ||
        indexIsHardened(absDerivationPath.slice(-1)[0]);
      derivedXpubsMemo = deriveHardened
        ? await deriveXpubHardenedFn(xpubMemo)
        : await deriveXpubNonhardenedFn(absDerivationPath);
    }
    /*
     * the derivedXpubs map stores promises instead of direct results
     * to deal with concurrent requests to derive the same xpub
     */
    return derivedXpubsMemo;
  };

  const deriveXpubNonhardenedFn = async (derivationPath) => {
    const lastIndex = derivationPath.slice(-1)[0];
    const parentXpub = await deriveXpub(derivationPath.slice(0, -1), null);
    try {
      const parentXpubHex = utils.buf_to_hex(parentXpub);
      const derivedXpub = await deriveXpubChannel.request({
        parentXpubHex,
        lastIndex,
        derivationScheme: derivationScheme.ed25519Mode,
      });
      // $FlowFixMe
      return utils.hex_to_buf(derivedXpub);
    } catch (e) {
      throw e;
    }
  };

  return deriveXpub;
};

// Helpers
export const indexIsHardened = (index: number) => {
  return index >= HARDENED_THRESHOLD;
};

export const prepareLedgerInput = (input: CoinSelectionInput) => {
  return {
    txHashHex: input.id,
    outputIndex: input.index,
    path: derivationPathToLedgerPath(input.derivationPath),
  };
};

export const prepareLedgerOutput = (
  output: CoinSelectionOutput,
  addressStyle: AddressStyle
) => {
  const isChange = output.derivationPath !== null;

  let tokenBundle = [];
  if (output.assets) {
    tokenBundle = prepareTokenBundle(output.assets);
  }

  if (isChange) {
    return {
      destination: {
        type: TxOutputDestinationType.DEVICE_OWNED,
        params: {
          type: AddressType.BASE,
          params: {
            spendingPath: derivationPathToLedgerPath(output.derivationPath),
            stakingPath: utils.str_to_path("1852'/1815'/0'/2/0"),
          },
        },
      },
      amount: output.amount.quantity.toString(),
      tokenBundle,
    };
  }
  return {
    destination: {
      type: TxOutputDestinationType.THIRD_PARTY,
      params: {
        addressHex:
          addressStyle === AddressStyles.ADDRESS_SHELLEY
            ? utils.buf_to_hex(utils.bech32_decodeAddress(output.address))
            : utils.buf_to_hex(utils.base58_decode(output.address)),
      },
    },
    amount: output.amount.quantity.toString(),
    tokenBundle,
  };
};

export const prepareTxAux = ({
  txInputs,
  txOutputs,
  fee,
  ttl,
  certificates,
  withdrawals,
}: {
  txInputs: Array<ShelleyTxInputType>,
  txOutputs: Array<ShelleyTxOutputType>,
  fee: number,
  ttl: number,
  certificates: Array<?Certificate>,
  withdrawals: ?ShelleyTxWithdrawalsType,
}) => {
  const txFee = ShelleyFee(fee);
  const txTtl = ShelleyTtl(ttl);
  const txCerts = certificates;
  const txWithdrawals = withdrawals;
  return ShelleyTxAux(
    txInputs,
    txOutputs,
    txFee,
    txTtl,
    txCerts,
    txWithdrawals
  );
};

export const prepareBody = (
  unsignedTx: ShelleyTxAuxType,
  txWitnesses: any // @TODO - figure out fallback if is Map<number, ShelleyTxWitnessType> presented as empty array
) => {
  const signedTransactionStructure = ShelleySignedTransactionStructured(
    unsignedTx,
    txWitnesses,
    null
  );
  return encode(signedTransactionStructure).toString('hex');
};
