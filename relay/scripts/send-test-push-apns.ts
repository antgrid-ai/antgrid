#!/usr/bin/env bun
/**
 * APNs counterpart to send-test-push.ts, driving the relay's own ApnsSender
 * pieces by hand against the same five env vars the relay reads.
 *
 * With no device token it posts to a syntactically valid but non-existent one,
 * which turns it into a credential probe: APNs only reaches the point of
 * rejecting the *token* once it has accepted the provider JWT and the topic, so
 * `BadDeviceToken` proves the key id, team id, signing key and bundle id are all
 * correct. That is the only way to validate an APNs key without a real device.
 *
 * It talks to the transport directly rather than ApnsSender.send, which
 * collapses every failure to "error" and would hide the reason that makes this
 * diagnostic worth running.
 *
 *   bun run relay/scripts/send-test-push-apns.ts             # credential probe
 *   bun run relay/scripts/send-test-push-apns.ts <token> [k=v ...]
 */
import { ApnsProviderToken, Http2ApnsTransport } from "../src/push/apns";

const [argToken, ...pairs] = process.argv.slice(2);

const { APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_BUNDLE_ID, APNS_PRODUCTION } = process.env;
if (!APNS_KEY_ID || !APNS_TEAM_ID || !APNS_PRIVATE_KEY || !APNS_BUNDLE_ID) {
  console.error("APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY and APNS_BUNDLE_ID must all be set");
  process.exit(1);
}

const data: Record<string, string> = {};
for (const p of pairs) {
  const i = p.indexOf("=");
  if (i < 0) {
    console.error(`not a key=value pair: ${p}`);
    process.exit(1);
  }
  data[p.slice(0, i)] = p.slice(i + 1);
}

const probing = !argToken;
const deviceToken = argToken ?? "00".repeat(32);
const production = APNS_PRODUCTION === "true";

const providerToken = new ApnsProviderToken({
  keyId: APNS_KEY_ID,
  teamId: APNS_TEAM_ID,
  // Same unescaping the relay does at startup (loadConfig, relay/src/config.ts).
  privateKeyPem: APNS_PRIVATE_KEY.replace(/\\n/g, "\n"),
});

const res = await new Http2ApnsTransport({ production }).post(
  deviceToken,
  {
    authorization: `bearer ${await providerToken.get()}`,
    "apns-topic": APNS_BUNDLE_ID,
    "apns-push-type": "alert",
    "apns-priority": "10",
    "content-type": "application/json",
  },
  JSON.stringify({
    aps: { alert: { title: "Antgrid", body: "New activity" }, "mutable-content": 1, sound: "default" },
    ...data,
  })
);

console.log(`host: ${production ? "production" : "sandbox"}  key: ${APNS_KEY_ID}  topic: ${APNS_BUNDLE_ID}`);
console.log(`status: ${res.status}  body: ${res.body}`);

if (!probing) process.exit(res.status === 200 ? 0 : 1);

const reason = (() => {
  try {
    return JSON.parse(res.body)?.reason as string | undefined;
  } catch {
    return undefined;
  }
})();

// Only BadDeviceToken means the credentials cleared; every other reason names
// which one failed, so report it rather than a bare pass/fail.
if (reason === "BadDeviceToken") {
  console.log("PASS — provider token and topic accepted; credentials are valid");
  process.exit(0);
}
console.error(
  {
    InvalidProviderToken: "FAIL — key id/team id/signing key mismatch",
    ExpiredProviderToken: "FAIL — provider token expired; check host clock skew",
    TopicDisallowed: "FAIL — this key is not authorized for APNS_BUNDLE_ID",
    MissingTopic: "FAIL — APNS_BUNDLE_ID empty",
  }[reason ?? ""] ?? `FAIL — unexpected reason: ${reason ?? res.body}`
);
process.exit(1);
