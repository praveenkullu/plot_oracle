import { ponder } from "@/generated";
import * as schema from "../ponder.schema";

const STATUS_NAMES = ["Submitted", "Pending", "Disputed", "Verified", "Rejected", "Superseded"];

// ── ClaimRegistry ─────────────────────────────────────────────────────────────

ponder.on("ClaimRegistry:ClaimSubmitted", async ({ event, context }) => {
  await context.db.insert(schema.claim).values({
    id: event.args.claimId,
    contentHash: event.args.contentHash,
    submitter: event.args.submitter,
    bond: event.args.bond,
    status: "Submitted",
    selfDeclaredDomain: event.args.selfDeclaredDomain,
    domainFinalized: false,
    submittedAt: event.block.timestamp,
  });
});

ponder.on("ClaimRegistry:StatusChanged", async ({ event, context }) => {
  await context.db
    .update(schema.claim, { id: event.args.claimId })
    .set({ status: STATUS_NAMES[event.args.newStatus] ?? "Unknown" });
});

ponder.on("ClaimRegistry:NoveltyResult", async ({ event, context }) => {
  await context.db
    .update(schema.claim, { id: event.args.claimId })
    .set({ noveltyPassed: event.args.passed });
});

ponder.on("ClaimRegistry:ConfidenceScoreSet", async ({ event, context }) => {
  await context.db
    .update(schema.claim, { id: event.args.claimId })
    .set({ confidenceScore: event.args.score });
});

ponder.on("ClaimRegistry:DomainFinalized", async ({ event, context }) => {
  await context.db
    .update(schema.claim, { id: event.args.claimId })
    .set({ voterAssignedDomain: event.args.voterAssignedDomain, domainFinalized: true });
});

ponder.on("ClaimRegistry:ClaimSuperseded", async ({ event, context }) => {
  await context.db
    .update(schema.claim, { id: event.args.oldClaimId })
    .set({ nextVersion: event.args.newClaimId });
  await context.db
    .update(schema.claim, { id: event.args.newClaimId })
    .set({ previousVersion: event.args.oldClaimId });
});

// ── ChallengeWindow ───────────────────────────────────────────────────────────

ponder.on("ChallengeWindow:WindowOpened", async ({ event, context }) => {
  await context.db.insert(schema.challengeWindow).values({
    id: event.args.claimId,
    openedAt: event.block.timestamp,
    expiresAt: event.args.expiresAt,
    finalized: false,
  });
});

ponder.on("ChallengeWindow:ChallengeOpened", async ({ event, context }) => {
  await context.db
    .update(schema.challengeWindow, { id: event.args.claimId })
    .set({ challenger: event.args.challenger, challengerBond: event.args.bond });
});

ponder.on("ChallengeWindow:WindowExpired", async ({ event, context }) => {
  await context.db
    .update(schema.challengeWindow, { id: event.args.claimId })
    .set({ finalized: true });
});

// ── OracleRouter ─────────────────────────────────────────────────────────────

ponder.on("OracleRouter:DisputeResolved", async ({ event, context }) => {
  await context.db
    .update(schema.claim, { id: event.args.claimId })
    .set({
      status: event.args.verified ? "Verified" : "Rejected",
      confidenceScore: event.args.score,
    });
});

// ── InternalVote ─────────────────────────────────────────────────────────────

ponder.on("InternalVote:VoteOpened", async ({ event, context }) => {
  await context.db.insert(schema.voteRecord).values({
    id: event.args.claimId,
    openedAt: event.block.timestamp,
    weightFor: 0n,
    weightAgainst: 0n,
    finalized: false,
  });
});

ponder.on("InternalVote:VoteCast", async ({ event, context }) => {
  const existing = await context.db.find(schema.voteRecord, { id: event.args.claimId });
  if (!existing) return;

  if (event.args.support) {
    await context.db
      .update(schema.voteRecord, { id: event.args.claimId })
      .set({ weightFor: existing.weightFor + event.args.weight });
  } else {
    await context.db
      .update(schema.voteRecord, { id: event.args.claimId })
      .set({ weightAgainst: existing.weightAgainst + event.args.weight });
  }
});

ponder.on("InternalVote:VoteFinalized", async ({ event, context }) => {
  await context.db
    .update(schema.voteRecord, { id: event.args.claimId })
    .set({
      weightFor: event.args.weightFor,
      weightAgainst: event.args.weightAgainst,
      finalized: true,
      verified: event.args.verified,
    });
});

// ── EmissionController ────────────────────────────────────────────────────────

ponder.on("EmissionController:EmissionMinted", async ({ event, context }) => {
  await context.db.insert(schema.emission).values({
    id: `${event.transaction.hash}-${event.log.logIndex}`,
    to: event.args.to,
    amount: event.args.amount,
    timestamp: event.block.timestamp,
  });
});
