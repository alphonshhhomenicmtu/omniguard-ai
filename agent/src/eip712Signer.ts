/**
 * OmniGuard AI — EIP-712 Neural Advisement Signer (V2 Fail-Closed)
 *
 * Signs NeuralAdvisement typed data matching OmniMarketFeed.sol's exact domain separator
 * and struct typehash so live neural classifications are cryptographically verified on-chain
 * via ecrecover before triggering Reactive Omni subscriptions.
 *
 * V2 Security Fix (H1): No silent fallback to public Hardhat/Anvil keys. Live signing
 * fails closed when NEURAL_SIGNER_PRIVATE_KEY is missing. Local offline tests or explicitly
 * badged SIMULATED mode must pass `allowEphemeralSimulationKey: true` intentionally.
 */

import { type Address, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

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
  simulatedSigner: boolean;
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

let cachedSessionSimKey: Hex | null = null;

function getOrCreateSessionSimKey(): Hex {
  if (!cachedSessionSimKey) {
    cachedSessionSimKey = generatePrivateKey();
  }
  return cachedSessionSimKey;
}

export function hasConfiguredNeuralSignerKey(privateKeyHex?: string): boolean {
  return Boolean(privateKeyHex && /^0x[0-9a-fA-F]{64}$/.test(privateKeyHex.trim()));
}

export function getNeuralSignerAccount(
  privateKeyHex?: string,
  options: { allowEphemeralSimulationKey?: boolean } = {}
) {
  if (hasConfiguredNeuralSignerKey(privateKeyHex)) {
    return {
      account: privateKeyToAccount(privateKeyHex!.trim() as Hex),
      simulatedSigner: false,
    };
  }
  if (!options.allowEphemeralSimulationKey) {
    throw new Error(
      "NEURAL_SIGNER_PRIVATE_KEY is not configured. Refusing to sign live EIP-712 advisements with a fallback key (fail-closed)."
    );
  }
  return {
    account: privateKeyToAccount(getOrCreateSessionSimKey()),
    simulatedSigner: true,
  };
}

export async function signNeuralAdvisement(params: {
  chainId: number;
  verifyingContract: Address;
  advisement: NeuralAdvisementPayload;
  privateKeyHex?: string;
  allowEphemeralSimulationKey?: boolean;
}): Promise<SignedNeuralAdvisement> {
  const { account, simulatedSigner } = getNeuralSignerAccount(params.privateKeyHex, {
    allowEphemeralSimulationKey: params.allowEphemeralSimulationKey,
  });

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
    simulatedSigner,
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
