import { Router, Request, Response } from 'express';
import { ethers } from 'ethers';
import { claimRegistry, noveltyGate, challengeWindow, bondCalculator, usdc, BOND_ESCROW_ADDRESS, signer } from '../lib/contracts.js';
import { env } from '../lib/env.js';

const router = Router();

// Matches ClaimRegistry.Domain enum order
const DOMAIN_NAMES = ['General', 'Science', 'Finance', 'Medical', 'Regulatory', 'NationalSecurity'];
const DOMAIN_MAP = Object.fromEntries(DOMAIN_NAMES.map((n, i) => [n, i]));

const STATUS_NAMES = ['Submitted', 'Pending', 'Disputed', 'Verified', 'Rejected', 'Superseded'];

const COMPLEXITY_BPS: Record<string, number> = {
  LOW: 10000, MEDIUM: 20000, HIGH: 30000, VERY_HIGH: 50000,
};

// POST /claims — full submission flow
router.post('/', async (req: Request, res: Response) => {
  const { claim_text, domain = 'General', complexity = 'MEDIUM', sources = [], submitter_address } = req.body as {
    claim_text?: string;
    domain?: string;
    complexity?: string;
    sources?: string[];
    submitter_address?: string;
  };

  if (!claim_text || claim_text.length < 10) {
    return res.status(400).json({ error: 'claim_text must be at least 10 characters' });
  }
  if (!submitter_address) {
    return res.status(400).json({ error: 'submitter_address is required' });
  }
  if (!signer) {
    return res.status(503).json({ error: 'Relay signer not configured. Set PRIVATE_KEY in .env.' });
  }

  const domainCode = DOMAIN_MAP[domain] ?? 0;
  const complexityBps = COMPLEXITY_BPS[complexity] ?? 5000;

  try {
    // 1. Hash the claim content (deterministic for duplicate detection)
    const payload = { text: claim_text, domain, sources, submitter: submitter_address, timestamp: Math.floor(Date.now() / 1000) };
    const contentHash = ethers.keccak256(ethers.toUtf8Bytes(JSON.stringify(payload))) as `0x${string}`;

    // 2. Exact-duplicate check (Layer 1)
    const existing = await (claimRegistry.contentHashToClaim(contentHash) as Promise<string>).catch(() => ethers.ZeroHash);
    if (existing && existing !== ethers.ZeroHash) {
      return res.status(409).json({ error: 'Exact duplicate claim already exists', claim_id: existing });
    }

    // 3. Get bond amount
    const bondRequired = await (bondCalculator.calculateBond(domainCode, complexityBps) as Promise<bigint>)
      .catch(() => BigInt('100000000')); // 100 USDC fallback

    // 4a. Ensure relay wallet has approved BondEscrow to spend at least bondRequired USDC
    const signerAddress = await signer!.getAddress();
    const allowance = await (usdc.allowance(signerAddress, BOND_ESCROW_ADDRESS) as Promise<bigint>);
    if (allowance < bondRequired) {
      const approveTx = await usdc.approve(BOND_ESCROW_ADDRESS, ethers.MaxUint256);
      await approveTx.wait();
    }

    // 4b. Submit claim on-chain; wait 2 confirmations so all RPC nodes see the state
    const tx = await claimRegistry.submitClaim(contentHash, domainCode, complexityBps, ethers.ZeroHash);
    const receipt = await tx.wait(2);
    const submittedEvent = receipt?.logs
      .map((log: { topics: string[]; data: string }) => { try { return claimRegistry.interface.parseLog(log); } catch { return null; } })
      .find((e: { name: string } | null) => e?.name === 'ClaimSubmitted');
    const claimId: string = (submittedEvent?.args?.claimId as string) ?? contentHash;

    // 5. NoveltyGate passthrough (always novel) + open challenge window
    // wait(2) on each tx so RPC nodes are consistent before the next call
    const noTx = await noveltyGate.submitNoveltyResult(claimId, 0, ethers.ZeroHash, ethers.ZeroHash);
    await noTx.wait(2);
    const owTx = await challengeWindow.openWindow(claimId);
    await owTx.wait();

    return res.status(201).json({
      claim_id: claimId,
      content_hash: contentHash,
      bond_required: bondRequired.toString(),
      tx_hash: receipt?.hash ?? null,
      novelty_result: null,
    });
  } catch (err) {
    const msg = (err as Error).message ?? 'Internal server error';
    console.error('[error] POST /claims:', msg);
    return res.status(500).json({ error: msg });
  }
});

// GET /claims — list via Ponder indexer
router.get('/', async (req: Request, res: Response) => {
  const { limit = '20', offset = '0', status, domain } = req.query as Record<string, string>;
  const where: string[] = [];
  if (status) where.push(`status: "${status}"`);
  if (domain != null) where.push(`selfDeclaredDomain: ${Number(domain)}`);
  const whereClause = where.length > 0 ? `, where: { ${where.join(', ')} }` : '';

  const query = `{
    claims(limit: ${Math.min(Number(limit), 100)}, offset: ${Number(offset)}${whereClause}) {
      items { id submitter bond status selfDeclaredDomain confidenceScore submittedAt noveltyPassed }
      totalCount
    }
  }`;

  try {
    const resp = await fetch(`${env.PONDER_URL}/graphql`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ query }),
    });
    const data = await resp.json() as { data?: { claims: unknown }; errors?: { message: string }[] };
    if (data.errors) throw new Error(data.errors[0].message);
    return res.json(data.data?.claims ?? { items: [], totalCount: 0 });
  } catch (err) {
    return res.status(502).json({ error: `Indexer unavailable: ${(err as Error).message}` });
  }
});

// GET /claims/:claimId — on-chain read
router.get('/:claimId', async (req: Request, res: Response) => {
  const { claimId } = req.params;
  try {
    const c = await claimRegistry.getClaim(claimId) as {
      claimId: string; contentHash: string; submitter: string; bond: bigint;
      status: number; selfDeclaredDomain: number; voterAssignedDomain: number;
      domainFinalized: boolean; confidenceScore: number; submittedAt: bigint;
      previousVersion: string; nextVersion: string; noveltyPassed: boolean;
    };
    if (!c.submitter || c.submitter === ethers.ZeroAddress) {
      return res.status(404).json({ error: 'Claim not found' });
    }
    return res.json({
      id: claimId,
      content_hash: c.contentHash,
      submitter: c.submitter,
      bond: c.bond.toString(),
      status: STATUS_NAMES[c.status] ?? 'Unknown',
      domain: DOMAIN_NAMES[c.selfDeclaredDomain] ?? 'Unknown',
      voter_domain: c.domainFinalized ? (DOMAIN_NAMES[c.voterAssignedDomain] ?? null) : null,
      domain_finalized: c.domainFinalized,
      confidence_score: c.confidenceScore.toString(),
      submitted_at: c.submittedAt.toString(),
      previous_version: c.previousVersion !== ethers.ZeroHash ? c.previousVersion : null,
      next_version: c.nextVersion !== ethers.ZeroHash ? c.nextVersion : null,
      novelty_passed: c.noveltyPassed,
    });
  } catch (err) {
    console.error('[error] GET /claims/:claimId:', (err as Error).message);
    return res.status(404).json({ error: 'Claim not found' });
  }
});

export default router;
