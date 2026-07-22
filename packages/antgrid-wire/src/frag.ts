export const MAX_FRAME_PAYLOAD = 1_500_000;
export const FRAG_THRESHOLD = 1_400_000;
export const FRAG_DATA_BUDGET = 1_400_000;
export const MAX_TRANSFER_BYTES = 33_554_432;
export const TRANSFER_TIMEOUT_MS = 10_000;
export const GLOBAL_REASSEMBLY_BUDGET = 67_108_864;
export const MAX_REREQUESTS = 1;
// Receive-side guard: a legitimate MAX_TRANSFER_BYTES transfer at FRAG_DATA_BUDGET
// per fragment needs ~24 fragments; this cap is ~40x headroom. Bounds the eager
// `n`-sized parts array a malformed/hostile envelope can ask a peer to allocate.
export const MAX_FRAGMENT_COUNT = 1024;

export interface FragHint {
  type: string;
  key: string;
}

export interface FragEnvelope {
  __frag: { id: string; i: number; n: number; hint?: FragHint };
  data: string;
}

export function isFragEnvelope(v: unknown): v is FragEnvelope {
  if (typeof v !== "object" || v === null) return false;
  const o = v as Record<string, unknown>;
  if (typeof o.data !== "string") return false;
  const f = o.__frag as Record<string, unknown> | undefined;
  if (typeof f !== "object" || f === null) return false;
  return (
    typeof f.id === "string" &&
    typeof f.i === "number" &&
    typeof f.n === "number"
  );
}

function jsonEscapedLen(ch: string): number {
  const code = ch.charCodeAt(0);
  if (ch === '"' || ch === "\\") return 2;
  if (code === 0x08 || code === 0x09 || code === 0x0a || code === 0x0c || code === 0x0d) {
    return 2;
  }
  if (code < 0x20) return 6;
  if (code >= 0xd800 && code <= 0xdfff && ch.length === 1) return 6;
  // `for..of` yields whole code points, so compute the UTF-8 length arithmetically
  // instead of allocating a Buffer per character on the multi-MB fragment path.
  const cp = ch.codePointAt(0)!;
  if (cp < 0x80) return 1;
  if (cp < 0x800) return 2;
  if (cp < 0x10000) return 3;
  return 4;
}

export function splitForJsonData(s: string, maxEscapedBytes: number): string[] {
  if (!Number.isFinite(maxEscapedBytes) || maxEscapedBytes <= 0) {
    throw new RangeError("maxEscapedBytes must be positive");
  }

  const out: string[] = [];
  let cur = "";
  let curBytes = 0;

  for (const ch of s) {
    const b = jsonEscapedLen(ch);
    if (curBytes + b > maxEscapedBytes && cur.length > 0) {
      out.push(cur);
      cur = "";
      curBytes = 0;
    }
    cur += ch;
    curBytes += b;
  }

  if (cur.length > 0 || out.length === 0) out.push(cur);
  return out;
}

// The `__frag` key is emitted first so the serialized frame always begins with
// `{"__frag"`. Receive-side reassemblers gate on that exact prefix as a cheap
// pre-parse filter (frag-reassembler.ts / frag.dart `accept`); keep the two in
// lockstep — reordering keys here silently breaks reassembly.
export function buildFragments(
  json: string,
  id: string,
  hint?: FragHint,
  budget: number = FRAG_DATA_BUDGET,
): string[] {
  const slices = splitForJsonData(json, budget);
  const n = slices.length;
  return slices.map((data, i) =>
    JSON.stringify({
      __frag: { id, i, n, ...(hint ? { hint } : {}) },
      data,
    } satisfies FragEnvelope),
  );
}
