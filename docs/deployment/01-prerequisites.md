# Prerequisites

## Tooling

### Foundry

Foundry is the Solidity development and deployment framework used by this project.

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Verify installation
~/.config/.foundry/bin/forge --version
~/.config/.foundry/bin/cast --version

# On this machine, Foundry is at:
~/.config/.foundry/bin/forge
```

### Node.js / Bun

Required for the off-chain services and Ponder indexer.

```bash
# Install Bun (recommended) or Node.js 18+
curl -fsSL https://bun.sh/install | bash
bun --version

# Or Node.js via nvm
nvm install 18
node --version
```

### Python 3.11+

Required for the SNS (Semantic Novelty Service) FastAPI application.

```bash
python3 --version   # needs 3.11+
pip install --upgrade pip
```

### PM2

Process manager for running all services on the same machine.

```bash
# Install globally
npm install -g pm2
# Or if already installed at custom path on this machine:
~/.local/bin/pm2 --version
```

---

## Environment Variables

Create `.env` in the project root (never commit this file):

```bash
cp .env.example .env  # (create .env.example from the template below)
```

### Required for contract deployment

```env
# Private key for the deployer wallet (no 0x prefix)
PRIVATE_KEY=your_private_key_here

# BaseScan API key for contract verification
BASESCAN_API_KEY=your_basescan_key_here

# The admin address that will receive DEFAULT_ADMIN_ROLE on all contracts
ADMIN_ADDRESS=0x...

# The foundation multisig address (receives FOUNDATION_ROLE on Treasury)
FOUNDATION_ADDRESS=0x...

# Initial treasury wallet for PLOT allocation (receives 200M PLOT at deploy)
TREASURY_WALLET=0x...

# Chainlink PLOT/USD price feed address (Base Mainnet)
# Register at https://data.chain.link after PLOT token is deployed
CHAINLINK_PLOT_USD_FEED=0x...

# Voter pool address (receives 20% of slashed bonds)
VOTER_POOL_ADDRESS=0x...
```

### Required for off-chain services

```env
# RPC endpoint for event listening and tx submission
BASE_RPC_URL=https://mainnet.base.org

# Private key for the SNS oracle wallet (holds SNS_ORACLE_ROLE)
SNS_ORACLE_PRIVATE_KEY=0x...

# Deployed contract addresses (fill in after deployment)
CLAIM_REGISTRY_ADDRESS=0x...
NOVELTY_GATE_ADDRESS=0x...
EMISSION_CONTROLLER_ADDRESS=0x...

# Qdrant vector DB (production)
QDRANT_HOST=localhost
QDRANT_PORT=6333

# Arweave / Irys for permanent storage
IRYS_PRIVATE_KEY=0x...
IRYS_NETWORK=mainnet   # or 'devnet' for testing
```

### Base Sepolia testnet overrides

```env
BASE_RPC_URL=https://sepolia.base.org
BASESCAN_API_KEY=same_key_works_for_both
# Use a test private key with testnet ETH from the Base Sepolia faucet
```

---

## Accounts Needed

### 1. Deployer account
- Needs ETH on Base Sepolia / Mainnet for gas
- Receives no permanent roles post-deployment (handoff to multisig)
- Get testnet ETH: [Base Sepolia Faucet](https://faucet.quicknode.com/base/sepolia)

### 2. Admin multisig (Gnosis Safe recommended)
- Holds `DEFAULT_ADMIN_ROLE` on all contracts
- Used for role management and emergency actions
- Set up Safe at [safe.global](https://safe.global)

### 3. Foundation multisig (separate from admin)
- Holds `FOUNDATION_ROLE` on Treasury
- Used exclusively for treasury vetoes in the first 2 years
- Should require 3-of-5 or higher threshold

### 4. SNS oracle wallet (EOA or relayer)
- Holds `SNS_ORACLE_ROLE` on NoveltyGate
- Automatically submits novelty results from the off-chain SNS service
- Keep private key in a secrets manager (AWS Secrets Manager, HashiCorp Vault)

### 5. Keeper / Operator wallet (EOA)
- Holds `OPERATOR_ROLE` on EmissionController
- Called daily (snapshot) and periodically (mintEmission)
- Integrate with Chainlink Automation after launch

---

## Build and Test

Always verify all tests pass before deployment:

```bash
cd contracts

# Run full test suite
~/.config/.foundry/bin/forge test

# Run with verbose output (shows gas costs)
~/.config/.foundry/bin/forge test -vvv

# Expected: 138 tests pass, 0 fail
```

Check build compiles cleanly:

```bash
~/.config/.foundry/bin/forge build
```

---

## BaseScan API Key

Get a free API key at [basescan.org](https://basescan.org/register) to:
- Verify contract source code after deployment
- Query contract state from the explorer

The key is configured in `foundry.toml`:
```toml
[profile.default.etherscan]
base_sepolia = { key = "${BASESCAN_API_KEY}", url = "https://api-sepolia.basescan.org/api" }
base_mainnet = { key = "${BASESCAN_API_KEY}", url = "https://api.basescan.org/api" }
```
