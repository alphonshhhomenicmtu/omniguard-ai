import dotenv from "dotenv";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  type Abi,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = path.resolve(__dirname, "..");
dotenv.config({ path: path.join(REPO_ROOT, ".env") });

export const DEPLOYMENTS_DIR = path.join(REPO_ROOT, "deployments");
export const DEPLOYMENTS_FILE = path.join(DEPLOYMENTS_DIR, "testnet.json");

export const reactiveLasnaChain = defineChain({
  id: 5318007,
  name: "Reactive Lasna",
  nativeCurrency: { name: "Lasna REACT", symbol: "lREACT", decimals: 18 },
  rpcUrls: { default: { http: [process.env.REACTIVE_RPC_URL || "https://lasna-rpc.rnk.dev/"] } },
  blockExplorers: { default: { name: "Reactscan", url: "https://lasna.reactscan.net" } },
});

export const baseSepoliaChain = defineChain({
  id: 84532,
  name: "Base Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [process.env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org"] } },
  blockExplorers: { default: { name: "BaseScan", url: "https://sepolia.basescan.org" } },
});

export const unichainSepoliaChain = defineChain({
  id: 1301,
  name: "Unichain Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [process.env.UNICHAIN_SEPOLIA_RPC_URL || "https://sepolia.unichain.org"] } },
  blockExplorers: { default: { name: "Uniscan", url: "https://sepolia.uniscan.xyz" } },
});

export const VERIFIED_OMNI_ADDRESSES = {
  REACTIVE_SYSTEM: "0x8888888888888888888888888888888888888888" as Address,
  BASE_SEPOLIA_CALLBACK_PROXY: "0x476F44b11F5C942c58f4c8E3d0300E5710743585" as Address,
  UNICHAIN_SEPOLIA_CALLBACK_PROXY: "0x775c9B990ADe401060B78D0e98684eEf8d2466C1" as Address,
  BASE_SEPOLIA_FAUCET: "0x2afaFD298b23b62760711756088F75B7409f5967" as Address,
};

export interface TestnetDeploymentRecord {
  updatedAt: string;
  deployer: Address;
  neuralSigner: Address;
  baseMarketFeed?: Address;
  baseMarketFeedTx?: Hex;
  unichainMarketFeed?: Address;
  unichainMarketFeedTx?: Hex;
  reactiveGuard?: Address;
  reactiveGuardTx?: Hex;
  baseGuardVault?: Address;
  baseGuardVaultTx?: Hex;
  unichainGuardVault?: Address;
  unichainGuardVaultTx?: Hex;
  ruleIds?: Record<string, number>;
}

export function requireDeployerKey(): Hex {
  const key = process.env.DEPLOYER_PRIVATE_KEY?.trim();
  if (!key || !/^0x[0-9a-fA-F]{64}$/.test(key)) {
    throw new Error(
      "Missing valid DEPLOYER_PRIVATE_KEY in .env (expected 0x-prefixed 64-hex private key). Copy .env.example to .env and fund a testnet wallet on Base Sepolia, Unichain Sepolia, and Reactive Lasna."
    );
  }
  return key as Hex;
}

export function getNeuralSignerKey(): Hex {
  const key = process.env.NEURAL_SIGNER_PRIVATE_KEY?.trim();
  if (key && /^0x[0-9a-fA-F]{64}$/.test(key)) {
    return key as Hex;
  }
  return requireDeployerKey();
}

export function loadFoundryArtifact(contractFile: string, contractName: string): { abi: Abi; bytecode: Hex } {
  const artifactPath = path.join(REPO_ROOT, "contracts", "out", contractFile, `${contractName}.json`);
  if (!fs.existsSync(artifactPath)) {
    throw new Error(
      `Foundry artifact not found at ${artifactPath}. Run 'cd contracts && forge build' first.`
    );
  }
  const json = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
  return {
    abi: json.abi as Abi,
    bytecode: json.bytecode.object as Hex,
  };
}

export function readDeployments(): Partial<TestnetDeploymentRecord> {
  if (!fs.existsSync(DEPLOYMENTS_FILE)) return {};
  return JSON.parse(fs.readFileSync(DEPLOYMENTS_FILE, "utf8"));
}

export function saveDeployments(patch: Partial<TestnetDeploymentRecord>) {
  fs.mkdirSync(DEPLOYMENTS_DIR, { recursive: true });
  const current = readDeployments();
  const next = { ...current, ...patch, updatedAt: new Date().toISOString() };
  fs.writeFileSync(DEPLOYMENTS_FILE, JSON.stringify(next, null, 2) + "\n", "utf8");
  return next;
}

export function createClients(chain: typeof baseSepoliaChain | typeof unichainSepoliaChain | typeof reactiveLasnaChain) {
  const account = privateKeyToAccount(requireDeployerKey());
  const publicClient = createPublicClient({ chain, transport: http() });
  const walletClient = createWalletClient({ account, chain, transport: http() });
  return { account, publicClient, walletClient };
}
