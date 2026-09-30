import { z } from "zod";

/** App → bridge, 2nd record on a TCP tunnel stream: dial
 *  `localhost:<port>` and pipe raw bytes both ways for the life of the stream.
 *  `connId` must equal the stream's open frame `connId`. `probe` asks only
 *  whether the port answers and whether it speaks TLS — the reply carries
 *  `tls` and the bridge FINs without piping anything. */
export const TunnelTcpOpen = z.object({
  type: z.literal("tunnel:tcp-open"),
  connId: z.string(),
  port: z.number().int().min(1).max(65_535),
  probe: z.boolean().optional(),
  checkoutId: z.string().default("main"),
});

/** Bridge → app, first record on a TCP tunnel stream once the upstream
 *  connection is up. Every byte after it is raw upstream output. `tls` is set
 *  only on a probe's reply. */
export const TunnelTcpReady = z.object({
  type: z.literal("tunnel:tcp-ready"),
  connId: z.string(),
  tls: z.boolean().optional(),
});

/** Bridge → app, first record instead of `tunnel:tcp-ready` when nothing
 *  answered on the port; FIN follows. Distinct from `stream:refused`, which
 *  means the tunnel itself was not allowed — this one means it was, and the
 *  dev server is not there. */
export const TunnelTcpError = z.object({
  type: z.literal("tunnel:tcp-error"),
  connId: z.string(),
  message: z.string(),
});

export type TunnelTcpOpen = z.infer<typeof TunnelTcpOpen>;
export type TunnelTcpReady = z.infer<typeof TunnelTcpReady>;
export type TunnelTcpError = z.infer<typeof TunnelTcpError>;
