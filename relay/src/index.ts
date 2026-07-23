import { loadConfig } from "./config.js";
import { setLogLevel, logger } from "./logger.js";
import { startServer } from "./server.js";
import { FcmSender, GoogleTokenSource } from "./push/fcm.js";
import { ApnsSender, ApnsProviderToken, Http2ApnsTransport } from "./push/apns.js";

const config = loadConfig();
setLogLevel(config.logLevel);

// All three FCM fields must be set together to enable push:deliver forwarding;
// otherwise push:deliver replies "unconfigured" (see server.ts).
const fcmSender =
  config.fcmProjectId && config.fcmClientEmail && config.fcmPrivateKey
    ? new FcmSender({
        projectId: config.fcmProjectId,
        tokenSource: new GoogleTokenSource({
          clientEmail: config.fcmClientEmail,
          // Env stores the PEM with literal \n; restore real newlines.
          privateKeyPem: config.fcmPrivateKey.replace(/\\n/g, "\n"),
        }),
      })
    : undefined;

// All four APNs fields must be set together to enable direct-APNs push.
const apnsSender =
  config.apnsKeyId && config.apnsTeamId && config.apnsPrivateKey && config.apnsBundleId
    ? new ApnsSender({
        bundleId: config.apnsBundleId,
        providerToken: new ApnsProviderToken({
          keyId: config.apnsKeyId,
          teamId: config.apnsTeamId,
          // Env stores the .p8 PEM with literal \n; restore real newlines.
          privateKeyPem: config.apnsPrivateKey.replace(/\\n/g, "\n"),
        }),
        transport: new Http2ApnsTransport({ production: config.apnsProduction ?? false }),
      })
    : undefined;

const relay = startServer(config, { fcmSender, apnsSender });

logger.info("Antgrid Relay started", {
  port: config.port,
  version: "0.1.0",
  url: `ws://localhost:${config.port}/ws`,
  healthUrl: `http://localhost:${config.port}/health`,
});

function shutdown() {
  logger.info("Shutting down...");
  relay.stop();
  process.exit(0);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
