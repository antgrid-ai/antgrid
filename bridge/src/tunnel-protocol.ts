import { z } from "zod";

export const TunnelHttpRequest = z.object({
  type: z.literal("tunnel:http-request"),
  requestId: z.string(),
  port: z.number().int().positive(),
  scheme: z.enum(["http", "https"]).optional(),
  method: z.string(),
  path: z.string(),
  headers: z.record(z.string(), z.string()).optional(),
  body: z.string().optional(),
});

export const TunnelHttpResponse = z.object({
  type: z.literal("tunnel:http-response"),
  requestId: z.string(),
  status: z.number().int(),
  headers: z.record(z.string(), z.string()),
  setCookies: z.array(z.string()).optional(),
  body: z.string(),
  bodyEncoding: z.enum(["utf8", "base64"]),
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
