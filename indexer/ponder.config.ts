import { createConfig } from "@ponder/core";
import { http } from "viem";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

function loadAbi(name: string) {
  const p = resolve(process.cwd(), "..", "contracts", "out", `${name}.sol`, `${name}.json`);
  return JSON.parse(readFileSync(p, "utf8")).abi;
}

const startBlock = parseInt(process.env.DEPLOY_BLOCK ?? "40666128", 10);

export default createConfig({
  networks: {
    baseSepolia: {
      chainId: 84532,
      transport: http(process.env.BASE_RPC_URL ?? "https://sepolia.base.org"),
    },
  },
  contracts: {
    ClaimRegistry: {
      network: "baseSepolia",
      abi: loadAbi("ClaimRegistry"),
      address: (process.env.CLAIM_REGISTRY_ADDRESS ?? "0x4018c2cdc76d2282caabc40ab4fa16f3cca9f866") as `0x${string}`,
      startBlock,
    },
    ChallengeWindow: {
      network: "baseSepolia",
      abi: loadAbi("ChallengeWindow"),
      address: (process.env.CHALLENGE_WINDOW_ADDRESS ?? "0x596639e733dd9263ccfbce38f857688b40bb4c87") as `0x${string}`,
      startBlock,
    },
    OracleRouter: {
      network: "baseSepolia",
      abi: loadAbi("OracleRouter"),
      address: (process.env.ORACLE_ROUTER_ADDRESS ?? "0x4e9932c37e43cfcb973e00fc621973660a530e57") as `0x${string}`,
      startBlock,
    },
    InternalVote: {
      network: "baseSepolia",
      abi: loadAbi("InternalVote"),
      address: (process.env.INTERNAL_VOTE_ADDRESS ?? "0x2e62f06f3a1d7028cc5182790d235667fb45ca53") as `0x${string}`,
      startBlock,
    },
    EmissionController: {
      network: "baseSepolia",
      abi: loadAbi("EmissionController"),
      address: (process.env.EMISSION_CONTROLLER_ADDRESS ?? "0xe187aceaf04b9c791f58ba1de3a4342a92e7482b") as `0x${string}`,
      startBlock,
    },
  },
});
