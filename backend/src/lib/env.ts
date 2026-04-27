import dotenv from 'dotenv';
import { resolve } from 'node:path';

dotenv.config({ path: resolve(process.cwd(), '..', '.env') });

function required(key: string): string {
  const val = process.env[key];
  if (!val) throw new Error(`Missing required env var: ${key}`);
  return val;
}

export const env = {
  PORT: parseInt(process.env.PORT ?? '3000', 10),
  NODE_ENV: process.env.NODE_ENV ?? 'development',
  BASE_RPC_URL: required('BASE_RPC_URL'),
  CLAIM_REGISTRY_ADDRESS: required('CLAIM_REGISTRY_ADDRESS') as `0x${string}`,
  NOVELTY_GATE_ADDRESS: required('NOVELTY_GATE_ADDRESS') as `0x${string}`,
  BOND_CALCULATOR_ADDRESS: required('BOND_CALCULATOR_ADDRESS') as `0x${string}`,
  BOND_ESCROW_ADDRESS: required('BOND_ESCROW_ADDRESS') as `0x${string}`,
  USDC_ADDRESS: required('USDC_ADDRESS') as `0x${string}`,
  SNS_SERVICE_URL: process.env.SNS_SERVICE_URL ?? 'http://localhost:8000',
  PONDER_URL: process.env.PONDER_URL ?? 'http://localhost:42069',
  PRIVATE_KEY: process.env.PRIVATE_KEY,
} as const;
