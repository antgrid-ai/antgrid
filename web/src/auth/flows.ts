// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import type { Tx } from "../db/index.js";
import { Prisma } from "../generated/prisma/client.js";
import { authScope } from "./transaction.js";
import type { AuthOrigin } from "./contracts.js";

export async function createFlow(db: Tx, origin: AuthOrigin, ttl: number, journeyId?: string) {
  const journey = journeyId ? { id: journeyId } : await db.authJourney.create({ data: { origin } });
  const flow = await db.authFlow.create({ data: { journeyId: journey.id, expiresAt: new Date(Date.now() + ttl * 1000) } });
  if (authScope.getStore()) authScope.getStore()!.flowId = flow.id;
  await recordStage(db, flow.id, "request_accepted");
  return flow;
}

export async function recordStage(db: Tx, flowId: string | undefined, stage: string, failure?: string) {
  if (!flowId) return;
  await db.authFlowEvent.upsert({ where: { flowId_stage: { flowId, stage } },
    create: { flowId, stage, failure }, update: {} });
}

export async function linkFlowUser(db: Tx, userId: string, stage: string) {
  const flowId = authScope.getStore()?.flowId;
  if (!flowId) return;
  const flow = await db.authFlow.findUnique({ where: { id: flowId }, include: { journey: true } });
  if (!flow) return;
  const user = await db.user.findUniqueOrThrow({ where: { id: userId } });
  await db.authJourney.update({ where: { id: flow.journeyId }, data: { userId,
    category: flow.journey.category !== "unknown" ? flow.journey.category
      : stage === "user_created" ? "signup" : user.emailVerified ? "returning" : "activation" } });
  if (stage === "user_created" && !user.registrationOrigin) {
    await db.user.updateMany({ where: { id: userId, registrationOrigin: { equals: Prisma.DbNull } }, data: { registrationOrigin: flow.journey.origin! } });
  }
  if (stage === "ownership_verified" && !user.activationOrigin && flow.journey.category !== "returning") {
    await db.user.updateMany({ where: { id: userId, activationOrigin: { equals: Prisma.DbNull } }, data: { activationOrigin: flow.journey.origin! } });
  }
  await recordStage(db, flowId, stage);
}

export async function classifyJourney(db: Tx, userId: string, verified: boolean) {
  const flowId = authScope.getStore()?.flowId;
  if (!flowId) return;
  const flow = await db.authFlow.findUnique({ where: { id: flowId } });
  if (flow) await db.authJourney.updateMany({ where: { id: flow.journeyId, category: "unknown" },
    data: { userId, category: verified ? "returning" : "activation" } });
}
