// SPDX-License-Identifier: MPL-2.0

import { createHash } from "node:crypto";
import { ftsQuery } from "../../src/search";
import type { PublicGroup, PublicQuery } from "./dataset-types";

const FAMILIES: Record<string, string[]> = {
  languages: ["C", "C++", "C#", "F#", "F*", "Objective-C", "Visual C++", "Managed C++"],
  runtimes: [".NET", "NET", "ASP.NET", "asp-net", "Node.js", "nodejs"],
  packages: ["@acme/cache", "@acme/cache-core", "@other/cache", "acme-cache", "cache", "@acme/core"],
  errors: ["E_ACCESS_DENIED", "E_NOT_FOUND", "E_ACCESS_TIMEOUT", "ERR_ACCESS_DENIED", "E-ACCESS-DENIED", "ACCESS_DENIED"],
  versions: ["1.2.3", "1.3.2", "2.1.3", "2.3.1", "3.1.2", "3.2.1"],
  paths: ["src/memory/search.ts", "src/search/memory.ts", "memory/src/search.ts", "lib/memory/search.ts", "src/memory/store.ts", "src/memory/search.test.ts"],
  camelCase: ["maxRetryCount", "maxRetryDelay", "minRetryCount", "maxCount", "retryCount", "RetryCountMax"],
  snake_case: ["max_retry_count", "max_count_retry", "retry_max_count", "count_retry_max", "max_retry_delay", "min_retry_count"],
  protocols: ["HTTP2", "HTTP/2", "HTTP/3", "TLS1.3", "TLS/1.3", "TLS1.2"],
  names: ["Maya Patel", "Maya Chen", "Arjun Patel", "Arjun Chen", "Sofia Nguyen", "Sofia Chen"],
  unicode: ["José García", "Jose Garcia", "Zoë Martin", "Zoe Martin", "张伟", "王伟"],
  products: ["PostgreSQL", "SQLite", "TypeScript", "OpenTelemetry", "Riverpod", "Iroh"],
  uuids: Array.from({ length: 6 }, (_, i) => `550e8400-e29b-41d4-a716-44665544000${i}`),
};

export type TechnicalCase = {
  id: string; family: string; kind: "literal" | "phrase" | "casefold";
  term: string; query: string; controlQuery: string; generated: string; relevantIds: string[];
};

/** Adversarial lookup diagnostics, not a sample of production query frequency. */
export function technicalFixtures() {
  const terms = Object.entries(FAMILIES).flatMap(([family, values]) => values.map((term, i) => ({ family, term, id: `${family}-${i}` })));
  const control = (id: string) => `ref${createHash("sha256").update(id).digest("hex").slice(0, 20)}`;
  const cases: TechnicalCase[] = [];
  for (const entry of terms) for (const kind of ["literal", "phrase", "casefold"] as const) {
    const query = kind === "phrase" ? `"${entry.term}"` : kind === "casefold" ? entry.term.toUpperCase() : entry.term;
    const opaque = control(entry.id);
    cases.push({ id: `${entry.id}-${kind}`, family: entry.family, kind, term: entry.term, query,
      controlQuery: kind === "phrase" ? `"${opaque}"` : kind === "casefold" ? opaque.toUpperCase() : opaque,
      generated: ftsQuery(query), relevantIds: [entry.id] });
  }
  const probes = [
    { query: "retry", target: "maxRetryCount", id: "camelCase-0" },
    { query: "max retry count", target: "maxRetryCount", id: "camelCase-0" },
    { query: "max_retry_count", target: "maxRetryCount", id: "camelCase-0" },
    { query: "Open Telemetry", target: "OpenTelemetry", id: "products-3" },
    { query: "Postgres", target: "PostgreSQL", id: "products-0" },
  ];
  const groups = [false, true].map(opaque => ({
    id: opaque ? "technical-controls" : "technical-literals",
    documents: terms.map(({ id, term }) => {
      const name = opaque ? control(id) : term;
      const title = `${name} reference`;
      return { id, sourceIds: [id], title, content: `${title}\n\nDiagnostic finding for ${name}. Check the documented configuration before changing this component.` };
    }),
    queries: cases.map((item): PublicQuery => ({ id: item.id, text: opaque ? item.controlQuery : item.query,
      relevantIds: item.relevantIds, category: `${item.kind}/${item.family}` })),
  }));
  return { groups, cases, probes };
}

export function selectTechnicalQueries(group: PublicGroup, count: number) {
  const seed = "antgrid-cqadupstack-programmers-pilot-v1";
  const digest = (id: string) => createHash("sha256").update(`${seed}:${id}`).digest("hex");
  const selected = [...group.queries].sort((a, b) => digest(a.id).localeCompare(digest(b.id)) || a.id.localeCompare(b.id)).slice(0, count);
  return { group: { ...group, queries: selected }, selection: {
    method: "Lowest SHA-256(seed:query-id), selected before scoring; complete corpus retained", seed,
    availableQueries: group.queries.length, selectedQueries: selected.length, ids: selected.map(row => row.id),
    idsSha256: createHash("sha256").update(selected.map(row => row.id).join("\n")).digest("hex"),
  } };
}
