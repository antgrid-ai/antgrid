// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { createHash } from "node:crypto";
import { EmailKeyring, createOutboxSender, startEmailOutbox } from "./auth/email-outbox.js";
import { buildApp } from "./app.js";
import { loadEnv } from "./env.js";
import { createDb } from "./db/index.js";
import { createAuth } from "./auth/better-auth.js";
import { createEmailSender } from "./auth/email.js";
import { startPeerPolicyOutbox } from "./relay/peer-policy-outbox.js";
import { startUsageSampler } from "./usage/sampler.js";

const env = loadEnv();
const db = createDb(env.PG_DATABASE_URL);
const providerSend = createEmailSender({ zeptoToken: env.ZEPTOMAIL_TOKEN, from: env.EMAIL_FROM, replyTo: env.EMAIL_REPLY_TO });
const keys = new EmailKeyring(env.EMAIL_OUTBOX_ACTIVE_KEY ?? "dev", env.EMAIL_OUTBOX_KEYS ? JSON.parse(env.EMAIL_OUTBOX_KEYS) :
  { dev: createHash("sha256").update("development-email-only:" + env.BETTER_AUTH_SECRET).digest("base64") });
const sendEmail = createOutboxSender(db, keys);
startEmailOutbox(db, keys, providerSend, env.EMAIL_DELIVERY_PAUSED);
const auth = createAuth({ env, db, sendEmail });
const relay = { baseUrl: env.RELAY_INTERNAL_URL, secret: env.RELAY_INTERNAL_SECRET };
const app = buildApp({ db, auth, env, corsOrigins: env.CORS_ORIGINS, relay, sendEmail });
startPeerPolicyOutbox(db, env.PEER_POLICY_TARGETS);
startUsageSampler(db, relay);

Bun.serve({ port: env.PORT, fetch: app.fetch });
console.log(`web listening on :${env.PORT}`);
