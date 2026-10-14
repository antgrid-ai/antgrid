// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { createHmac, randomBytes } from "node:crypto";
import { z } from "zod";
import type { DB } from "../db/index.js";
import { createFlow } from "./flows.js";
import { pruneBrowserBindings } from "./browser-bindings.js";
import { safeReturnPath, requestOrigin } from "./contracts.js";
import { digest, matches } from "./native-plugin.js";

const PREFIX = "antgrid.request_flow.";

export async function createRequestFlow(db: DB, secret: string, email: string, method: string, headers: Headers | null,
  cookie: (name: string) => string | null | undefined, setCookie: (name: string, value: string, maxAge: number) => void) {
  const recipientHash = createHmac("sha256",secret).update("auth-journey:"+email).digest();
  const names = (headers?.get("cookie") ?? "").split(";").map((part) => part.trim().split("=")[0]).filter((name) => name.startsWith(PREFIX));
  let journeyId: string | undefined;
  let latest: { journeyId: string; recipientHash: Uint8Array | null; createdAt: Date } | undefined;
  for (const name of names) {
    const id = name.slice(PREFIX.length);
    const flow = z.uuid().safeParse(id).success ? await db.authFlow.findUnique({ where: { id }, include: { journey: true } }) : null;
    if (!flow || flow.expiresAt <= new Date()) { setCookie(name,"",0); continue; }
    const binding = cookie(name);
    if (binding && matches(flow.bindingHash,binding) && (!latest || flow.createdAt >= latest.createdAt)) {
      latest = { journeyId: flow.journeyId, recipientHash: flow.journey.recipientHash, createdAt: flow.createdAt };
    }
  }
  if (latest?.recipientHash && Buffer.from(latest.recipientHash).equals(recipientHash)) {
    const completed = await db.authFlowEvent.findFirst({ where: { stage: "first_client_use", flow: { journeyId: latest.journeyId } } });
    if (!completed) journeyId = latest.journeyId;
  }
  const flow = await createFlow(db,requestOrigin(headers,method),3600,journeyId);
  await db.authJourney.update({ where: { id: flow.journeyId }, data: { recipientHash } });
  const binding = randomBytes(32).toString("base64url");
  await db.authFlow.update({ where: { id: flow.id }, data: { bindingHash: digest(binding), returnPath: safeReturnPath(cookie("antgrid.return_path") ?? undefined) } });
  await pruneBrowserBindings(db,secret,headers,cookie,setCookie, { id: flow.id, kind: "request", expiresAt: flow.expiresAt, value: binding });
  setCookie(PREFIX+flow.id,binding,3600);
  return flow;
}
