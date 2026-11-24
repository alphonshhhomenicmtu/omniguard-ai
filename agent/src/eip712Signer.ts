/**
 * OmniGuard AI — EIP-712 Neural Advisement Signer
 *
 * Signs NeuralAdvisement typed data matching OmniMarketFeed.sol's exact domain separator
 * and struct typehash so live neural classifications are cryptographically verified on-chain
 * via ecrecover before triggering Reactive Omni subscriptions.
 */

import { type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

export interface NeuralAdvisementPayload {
  marketId: Hex;
  regime: 0 | 1 | 2 | 3;
  riskScoreBps: number;
  recommendedHedgeBps: number;
  issuedAt: bigint;
  validUntil: bigint;
  nonce: bigint;
}

export interface SignedNeuralAdvisement {
  signer: Address;
  chainId: number;
  verifyingContract: Address;
  advisement: {
    marketId: Hex;
    regime: number;
    riskScoreBps: number;
    recommendedHedgeBps: number;
    issuedAt: string;
    validUntil: string;
    nonce: string;
  };
  signature: Hex;
}

// Deterministic non-production ephemeral key used ONLY when NEURAL_SIGNER_PRIVATE_KEY is unset in local simulation mode.
const EPHEMERAL_SIMULATION_KEY: Hex =
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";

export function getNeuralSignerAccount(privateKeyHex?: string) {
  const key =
    privateKeyHex && /^0x[0-9a-fA-F]{64}$/.test(privateKeyHex.trim())
      ? (privateKeyHex.trim() as Hex)
      : EPHEMERAL_SIMULATION_KEY;
  return privateKeyToAccount(key);
}

export async function signNeuralAdvisement(params: {
  chainId: number;
  verifyingContract: Address;
  advisement: NeuralAdvisementPayload;
  privateKeyHex?: string;
}): Promise<SignedNeuralAdvisement> {
  const account = getNeuralSignerAccount(params.privateKeyHex);

  const signature = await account.signTypedData({
    domain: {
      name: "OmniGuardMarketFeed",
      version: "1",
      chainId: params.chainId,
      verifyingContract: params.verifyingContract,
    },
    types: {
      NeuralAdvisement: [
        { name: "marketId", type: "bytes32" },
        { name: "regime", type: "uint8" },
        { name: "riskScoreBps", type: "uint16" },
        { name: "recommendedHedgeBps", type: "uint16" },
        { name: "issuedAt", type: "uint64" },
        { name: "validUntil", type: "uint64" },
        { name: "nonce", type: "uint256" },
      ],
    },
    primaryType: "NeuralAdvisement",
    message: {
      marketId: params.advisement.marketId,
      regime: params.advisement.regime,
      riskScoreBps: params.advisement.riskScoreBps,
      recommendedHedgeBps: params.advisement.recommendedHedgeBps,
      issuedAt: params.advisement.issuedAt,
      validUntil: params.advisement.validUntil,
      nonce: params.advisement.nonce,
    },
  });

  return {
    signer: account.address,
    chainId: params.chainId,
    verifyingContract: params.verifyingContract,
    advisement: {
      marketId: params.advisement.marketId,
      regime: params.advisement.regime,
      riskScoreBps: params.advisement.riskScoreBps,
      recommendedHedgeBps: params.advisement.recommendedHedgeBps,
      issuedAt: params.advisement.issuedAt.toString(),
      validUntil: params.advisement.validUntil.toString(),
      nonce: params.advisement.nonce.toString(),
    },
    signature,
  };
}
