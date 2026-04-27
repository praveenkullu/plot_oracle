import { onchainTable } from "@ponder/core";

export const claim = onchainTable("claim", (t) => ({
  id: t.hex().primaryKey(),
  contentHash: t.hex().notNull(),
  submitter: t.hex().notNull(),
  bond: t.bigint().notNull(),
  status: t.text().notNull(),
  selfDeclaredDomain: t.integer().notNull(),
  voterAssignedDomain: t.integer(),
  domainFinalized: t.boolean().notNull(),
  confidenceScore: t.integer(),
  submittedAt: t.bigint().notNull(),
  previousVersion: t.hex(),
  nextVersion: t.hex(),
  noveltyPassed: t.boolean(),
}));

export const challengeWindow = onchainTable("challenge_window", (t) => ({
  id: t.hex().primaryKey(),
  openedAt: t.bigint().notNull(),
  expiresAt: t.bigint().notNull(),
  challenger: t.hex(),
  challengerBond: t.bigint(),
  finalized: t.boolean().notNull(),
}));

export const voteRecord = onchainTable("vote_record", (t) => ({
  id: t.hex().primaryKey(),
  openedAt: t.bigint().notNull(),
  weightFor: t.bigint().notNull(),
  weightAgainst: t.bigint().notNull(),
  finalized: t.boolean().notNull(),
  verified: t.boolean(),
}));

export const emission = onchainTable("emission", (t) => ({
  id: t.text().primaryKey(),
  to: t.hex().notNull(),
  amount: t.bigint().notNull(),
  timestamp: t.bigint().notNull(),
}));
