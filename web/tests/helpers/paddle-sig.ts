import { createHmac } from "node:crypto";

export function paddleSignature(rawBody: string, secret: string): string {
  const ts = Math.floor(Date.now() / 1000);
  const h1 = createHmac("sha256", secret).update(`${ts}:${rawBody}`).digest("hex");
  return `ts=${ts};h1=${h1}`;
}
