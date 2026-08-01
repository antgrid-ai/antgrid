import { z } from "zod";

/** `gzip-base64` = base64 of the gzipped body. Compressing before base64 is the
 *  only compression this tunnel can have: what crosses the relay is AES-GCM
 *  ciphertext, so WebSocket permessage-deflate would have nothing to squeeze. */
export const TUNNEL_GZIP_ENCODING = "gzip-base64";

export const TunnelHttpRequest = z.object({
  type: z.literal("tunnel:http-request"),
  requestId: z.string(),
  port: z.number().int().positive(),
  scheme: z.enum(["http", "https"]).optional(),
  method: z.string(),
  path: z.string(),
  headers: z.record(z.string(), z.string()).optional(),
  body: z.string().optional(),
  /** Body encodings the caller can decode BEYOND the mandatory utf8/base64.
   *  Absent means neither — an older app renders an unknown bodyEncoding as
   *  text, so the bridge must never compress unasked. New app + old bridge is
   *  safe for the mirror-image reason: `z.object` strips unknown keys, so this
   *  field just vanishes and the response comes back uncompressed. */
  acceptEncodings: z.array(z.string()).optional(),
});

export const TunnelHttpResponse = z.object({
  type: z.literal("tunnel:http-response"),
  requestId: z.string(),
  status: z.number().int(),
  headers: z.record(z.string(), z.string()),
  setCookies: z.array(z.string()).optional(),
  body: z.string(),
  bodyEncoding: z.enum(["utf8", "base64", TUNNEL_GZIP_ENCODING]),
});

export type TunnelHttpRequest = z.infer<typeof TunnelHttpRequest>;
export type TunnelHttpResponse = z.infer<typeof TunnelHttpResponse>;

const TunnelMessageSchema = z.discriminatedUnion("type", [
  TunnelHttpRequest,
  TunnelHttpResponse,
]);

export type TunnelMessage = z.infer<typeof TunnelMessageSchema>;

export function isTunnelMessage(raw: string): boolean {
  try {
    const json = JSON.parse(raw);
    return typeof json?.type === "string" && json.type.startsWith("tunnel:");
  } catch {
    return false;
  }
}

export function parseTunnelMessage(raw: string | object): TunnelMessage | null {
  try {
    const json = typeof raw === "string" ? JSON.parse(raw) : raw;
    const result = TunnelMessageSchema.safeParse(json);
    return result.success ? result.data : null;
  } catch {
    return null;
  }
}
