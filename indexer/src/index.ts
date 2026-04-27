import { ponder } from "@/generated";
import { eq } from "drizzle-orm";
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
    .update(schema.claim)
    .set({ status: STATUS_NAMES[event.args.newStatus] ?? "Unknown" })
    .where(eq(schema.claim.id, event.args.claimId));
});

ponder.on("ClaimRegistry:NoveltyResult", async ({ event, context }) => {
  await context.db
    .update(schema.claim)
    .set({ noveltyPassed: event.args.passed })
    .where(eq(schema.claim.id, event.args.claimId));
});

ponder.on("ClaimRegistry:ConfidenceScoreSet", async ({ event, context }) => {
  await context.db
    .update(schema.claim)
    .set({ confidenceScore: event.args.score })
    .where(eq(schema.claim.id, event.args.claimId));
});

ponder.on("ClaimRegistry:DomainFinalized", async ({ event, context }) => {
  await context.db
    .update(schema.claim)
    .set({ voterAssignedDomain: event.args.voterAssignedDomain, domainFinalized: true })
    .where(eq(schema.claim.id, event.args.claimId));
});

ponder.on("ClaimRegistry:ClaimSuperseded", async ({ event, context }) => {
  await context.db
    .update(schema.claim)
    .set({ nextVersion: event.args.newClaimId })
    .where(eq(schema.claim.id, event.args.oldClaimId));
  // New claim row is created by the ClaimSubmitted event; just set its previousVersion
  await context.db
    .update(schema.claim)
    .set({ previousVersion: event.args.oldClaimId })
    .where(eq(schema.claim.id, event.args.newClaimId));
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
    .update(schema.challengeWindow)
    .set({ challenger: event.args.challenger, challengerBond: event.args.bond })
    .where(eq(schema.challengeWindow.id, event.args.claimId));
});

ponder.on("ChallengeWindow:WindowExpired", async ({ event, context }) => {
  await context.db
    .update(schema.challengeWindow)
    .set({ finalized: true })
    .where(eq(schema.challengeWindow.id, event.args.claimId));
});

// ── OracleRouter ─────────────────────────────────────────────────────────────

ponder.on("OracleRouter:DisputeResolved", async ({ event, context }) => {
  await context.db
    .update(schema.claim)
    .set({
      status: event.args.verified ? "Verified" : "Rejected",
      confidenceScore: event.args.score,
    })
    .where(eq(schema.claim.id, event.args.claimId));
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
  const [existing] = await context.db
    .select()
    .from(schema.voteRecord)
    .where(eq(schema.voteRecord.id, event.args.claimId));
  if (!existing) return;

  if (event.args.support) {
    await context.db
      .update(schema.voteRecord)
      .set({ weightFor: existing.weightFor + event.args.weight })
      .where(eq(schema.voteRecord.id, event.args.claimId));
  } else {
    await context.db
      .update(schema.voteRecord)
      .set({ weightAgainst: existing.weightAgainst + event.args.weight })
      .where(eq(schema.voteRecord.id, event.args.claimId));
  }
});

ponder.on("InternalVote:VoteFinalized", async ({ event, context }) => {
  await context.db
    .update(schema.voteRecord)
    .set({
      weightFor: event.args.weightFor,
      weightAgainst: event.args.weightAgainst,
      finalized: true,
      verified: event.args.verified,
    })
    .where(eq(schema.voteRecord.id, event.args.claimId));
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
