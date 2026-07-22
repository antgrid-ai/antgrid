#!/usr/bin/env bun
/**
 * Sends a data-only FCM push to one device token — the relay's own FcmSender,
 * driven by hand. The Firebase console cannot send data-only messages, so this
 * is the only way to exercise the background/terminated delivery path.
 *
 * Reads the same three env vars the relay does; see
 * docs/runbooks/fcm-relay-setup.md.
 *
 *   bun run relay/scripts/send-test-push.ts <device-token> [key=value ...]
 */
import { FcmSender, GoogleTokenSource } from "../src/push/fcm";

const [pushToken, ...pairs] = process.argv.slice(2);
if (!pushToken) {
  console.error("usage: send-test-push.ts <device-token> [key=value ...]");
  process.exit(1);
}

const { FCM_PROJECT_ID, FCM_CLIENT_EMAIL, FCM_PRIVATE_KEY } = process.env;
if (!FCM_PROJECT_ID || !FCM_CLIENT_EMAIL || !FCM_PRIVATE_KEY) {
  console.error("FCM_PROJECT_ID, FCM_CLIENT_EMAIL and FCM_PRIVATE_KEY must all be set");
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
if (Object.keys(data).length === 0) data.hello = "world";

const sender = new FcmSender({
  projectId: FCM_PROJECT_ID,
  tokenSource: new GoogleTokenSource({
    clientEmail: FCM_CLIENT_EMAIL,
    // Same unescaping the relay does at startup (loadFcmConfig, relay/src/config.ts).
    privateKeyPem: FCM_PRIVATE_KEY.replace(/\\n/g, "\n"),
  }),
});
console.log(await sender.send(pushToken, data));
