import { env } from './env.js';

export interface SnsResult {
  claim_id: string;
  is_novel: boolean;
  similarity_score: number;
  similarity_bps: number;
  classification: string;
  nearest_claim_id: string | null;
  justification: {
    nearest_existing_claim: string | null;
    similarity_score: number;
    novel_elements: string[];
  };
}

export async function checkNovelty(
  claimId: string,
  claimText: string,
  domain: number,
  contentHash: string,
): Promise<SnsResult> {
  const resp = await fetch(`${env.SNS_SERVICE_URL}/novelty/check`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ claim_id: claimId, claim_text: claimText, domain, content_hash: contentHash }),
  });
  if (!resp.ok) throw new Error(`SNS error: ${resp.status} ${await resp.text()}`);
  return resp.json() as Promise<SnsResult>;
}

export async function storeEmbedding(
  claimId: string,
  claimText: string,
  domain: number,
  contentHash: string,
): Promise<void> {
  const resp = await fetch(`${env.SNS_SERVICE_URL}/novelty/embed`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ claim_id: claimId, claim_text: claimText, domain, content_hash: contentHash }),
  });
  if (!resp.ok) throw new Error(`SNS embed error: ${resp.status} ${await resp.text()}`);
}
