// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { startEmailOutbox } from "./auth/email-outbox.js";
import { composeMail } from "./mail-stack.js";
import { buildApp } from "./app.js";
import { loadEnv } from "./env.js";
import { createDb } from "./db/index.js";
import { createAuth } from "./auth/better-auth.js";
import { startPeerPolicyOutbox } from "./relay/peer-policy-outbox.js";
import { startUsageSampler } from "./usage/sampler.js";

const env = loadEnv();
const db = createDb(env.PG_DATABASE_URL);
const { keys, providerSend, sendEmail, mailDomain } = composeMail(env, db);
startEmailOutbox(db, keys, providerSend, env.EMAIL_DELIVERY_PAUSED);
const auth = createAuth({ env, db, sendEmail, mailDomain });
const relay = { baseUrl: env.RELAY_INTERNAL_URL, secret: env.RELAY_INTERNAL_SECRET };
const app = buildApp({ db, auth, env, corsOrigins: env.CORS_ORIGINS, relay, sendEmail, mailDomain });
startPeerPolicyOutbox(db, env.PEER_POLICY_TARGETS);
startUsageSampler(db, relay);

Bun.serve({ port: env.PORT, fetch: app.fetch });
console.log(`web listening on :${env.PORT}`);
