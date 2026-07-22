const ANSI_RE = /\x1b\[[0-9;?]*[ -/]*[@-~]/g;
const URL_RE = /(https?):\/\/([a-zA-Z0-9\.\-_]+)(?::(\d+))?(\/[^\s\x1b]*)?/g;

export interface UrlHit {
  scheme: "http" | "https";
  host: string;
  port: number;
  path: string;
}

export function extractUrls(chunk: string): UrlHit[] {
  const clean = chunk.replace(ANSI_RE, "");
  const hits: UrlHit[] = [];
  for (const m of clean.matchAll(URL_RE)) {
    const scheme = m[1] as "http" | "https";
    const host = m[2];
    const port = m[3] ? Number(m[3]) : (scheme === "https" ? 443 : 80);
    const path = m[4] ?? "/";
    hits.push({ scheme, host, port, path });
  }
  return hits;
}

export function canonicalize(hit: UrlHit): UrlHit {
  if (hit.host === "127.0.0.1" || hit.host === "0.0.0.0") {
    return { ...hit, host: "localhost" };
  }
  return hit;
}

export function toUrlString(hit: UrlHit): string {
  const defaultPort = hit.scheme === "https" ? 443 : 80;
  const portPart = hit.port === defaultPort ? "" : `:${hit.port}`;
  return `${hit.scheme}://${hit.host}${portPart}${hit.path}`;
}
