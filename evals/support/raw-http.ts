import { createHash, randomBytes } from "node:crypto";
import type { TunnelTcpStreamClient } from "../helpers/relay-client";

// Speaks HTTP/1.1 and RFC 6455 by hand over a `tunnel-tcp` stream, because the
// tunnel carries opaque bytes and these rows must prove that the bytes a real
// browser would send reach the dev server untouched.

export interface RawHttpResponse {
  status: number;
  /** Lower-cased names; a repeated header keeps every value in order. */
  headers: Map<string, string[]>;
  body: Buffer;
}

const HEADER_END = Buffer.from("\r\n\r\n");

export function buildRequest(opts: {
  method: string;
  path: string;
  port: number;
  headers?: Record<string, string>;
  body?: Uint8Array;
}): Buffer {
  const headers: Record<string, string> = {
    host: `localhost:${opts.port}`,
    connection: "close",
    ...opts.headers,
  };
  if (opts.body) headers["content-length"] = String(opts.body.length);
  const head = [`${opts.method} ${opts.path} HTTP/1.1`, ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`), "", ""].join("\r\n");
  return Buffer.concat([Buffer.from(head, "latin1"), Buffer.from(opts.body ?? [])]);
}

/** Parses the status line and headers, or null until the head is complete. */
export function parseHead(bytes: Buffer): { status: number; headers: Map<string, string[]>; bodyStart: number } | null {
  const end = bytes.indexOf(HEADER_END);
  if (end === -1) return null;
  const [statusLine, ...lines] = bytes.subarray(0, end).toString("latin1").split("\r\n");
  const status = Number(statusLine!.split(" ")[1]);
  const headers = new Map<string, string[]>();
  for (const line of lines) {
    const colon = line.indexOf(":");
    const name = line.slice(0, colon).toLowerCase();
    headers.set(name, [...(headers.get(name) ?? []), line.slice(colon + 1).trim()]);
  }
  return { status, headers, bodyStart: end + HEADER_END.length };
}

/** Sends one `Connection: close` request and reads to the bridge's FIN. The
 *  body is returned exactly as the origin framed it — a chunked body stays
 *  chunked — so a caller can assert nothing rewrote it. */
export async function fetchOverTunnel(
  client: TunnelTcpStreamClient,
  request: Buffer,
  timeoutMs = 30_000,
): Promise<RawHttpResponse> {
  await client.ready(timeoutMs);
  await client.send(request);
  const ended = await Promise.race([client.ended, Bun.sleep(timeoutMs).then(() => "timeout" as const)]);
  if (ended !== "fin") throw new Error(`tunnel-tcp response ended "${ended}" instead of "fin"`);
  const bytes = client.received();
  const head = parseHead(bytes);
  if (!head) throw new Error("tunnel-tcp response ended before a complete HTTP head");
  return { status: head.status, headers: head.headers, body: bytes.subarray(head.bodyStart) };
}

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

export interface WsHandshake {
  key: string;
  request: Buffer;
  expectedAccept: string;
}

export function buildWsHandshake(port: number, path: string, headers: Record<string, string> = {}): WsHandshake {
  const key = randomBytes(16).toString("base64");
  const request = buildRequest({
    method: "GET",
    path,
    port,
    headers: {
      connection: "Upgrade",
      upgrade: "websocket",
      "sec-websocket-version": "13",
      "sec-websocket-key": key,
      ...headers,
    },
  });
  return { key, request, expectedAccept: createHash("sha1").update(key + WS_GUID).digest("base64") };
}

/** One client-to-server frame; masked, as RFC 6455 requires of a client. */
export function encodeWsFrame(opcode: number, payload: Uint8Array): Buffer {
  const mask = randomBytes(4);
  const len = payload.length;
  const head =
    len < 126
      ? Buffer.from([0x80 | opcode, 0x80 | len])
      : len < 65_536
        ? Buffer.from([0x80 | opcode, 0x80 | 126, len >> 8, len & 0xff])
        : (() => {
            const h = Buffer.alloc(10);
            h[0] = 0x80 | opcode;
            h[1] = 0x80 | 127;
            h.writeBigUInt64BE(BigInt(len), 2);
            return h;
          })();
  const masked = Buffer.alloc(len);
  for (let i = 0; i < len; i++) masked[i] = payload[i]! ^ mask[i % 4]!;
  return Buffer.concat([head, mask, masked]);
}

export interface WsFrame {
  opcode: number;
  payload: Buffer;
}

/** Splits complete server-to-client (unmasked) frames off `bytes`. */
export function decodeWsFrames(bytes: Buffer): WsFrame[] {
  const frames: WsFrame[] = [];
  let offset = 0;
  while (offset + 2 <= bytes.length) {
    const opcode = bytes[offset]! & 0x0f;
    let len = bytes[offset + 1]! & 0x7f;
    let cursor = offset + 2;
    if (len === 126) {
      if (cursor + 2 > bytes.length) break;
      len = bytes.readUInt16BE(cursor);
      cursor += 2;
    } else if (len === 127) {
      if (cursor + 8 > bytes.length) break;
      len = Number(bytes.readBigUInt64BE(cursor));
      cursor += 8;
    }
    if (cursor + len > bytes.length) break;
    frames.push({ opcode, payload: bytes.subarray(cursor, cursor + len) });
    offset = cursor + len;
  }
  return frames;
}
