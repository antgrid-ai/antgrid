import { buildApp } from "./app.js";
import { loadEnv } from "./env.js";
import { createDb } from "./db/index.js";
import { createAuth } from "./auth/better-auth.js";
import { createEmailSender } from "./auth/email.js";

const env = loadEnv();
const db = createDb(env.PG_DATABASE_URL);
const sendEmail = createEmailSender({ zeptoToken: env.ZEPTOMAIL_TOKEN, from: env.EMAIL_FROM });
const auth = createAuth({ env, db, sendEmail });
const relay = { baseUrl: env.RELAY_INTERNAL_URL, secret: env.RELAY_INTERNAL_SECRET };
const app = buildApp({ db, auth, env, corsOrigins: env.CORS_ORIGINS, relay, sendEmail });

Bun.serve({ port: env.PORT, fetch: app.fetch });
console.log(`web listening on :${env.PORT}`);
