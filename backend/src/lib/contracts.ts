import { ethers } from 'ethers';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { env } from './env.js';

const CONTRACTS_OUT = resolve(process.cwd(), '..', 'contracts', 'out');

function loadAbi(name: string): readonly object[] {
  const p = resolve(CONTRACTS_OUT, `${name}.sol`, `${name}.json`);
  return (JSON.parse(readFileSync(p, 'utf8')) as { abi: readonly object[] }).abi;
}

export const provider = new ethers.JsonRpcProvider(env.BASE_RPC_URL);

export const signer = env.PRIVATE_KEY
  ? new ethers.Wallet(env.PRIVATE_KEY, provider)
  : null;

export const claimRegistry = new ethers.Contract(
  env.CLAIM_REGISTRY_ADDRESS,
  loadAbi('ClaimRegistry'),
  signer ?? provider,
);

export const noveltyGate = new ethers.Contract(
  env.NOVELTY_GATE_ADDRESS,
  loadAbi('NoveltyGate'),
  signer ?? provider,
);

export const bondCalculator = new ethers.Contract(
  env.BOND_CALCULATOR_ADDRESS,
  loadAbi('BondCalculator'),
  provider,
);

const ERC20_ABI = [
  'function allowance(address owner, address spender) view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
  'function balanceOf(address account) view returns (uint256)',
];

export const usdc = new ethers.Contract(env.USDC_ADDRESS, ERC20_ABI, signer ?? provider);

export const BOND_ESCROW_ADDRESS = env.BOND_ESCROW_ADDRESS;
