import { LIMITS, MemoryError, bytes, type MemoryRecord, type MemorySearchHit } from "./contracts";

export function ftsQuery(query: string): string {
  const terms: string[] = [];
  for (const part of query.matchAll(/"([^"]*)"|([^\s"]+)/gu)) {
    const tokens = ((part[1] ?? part[2]).match(/[\p{L}\p{N}\p{M}]+/gu) ?? []).filter(token => /[\p{L}\p{N}]/u.test(token));
    if (part[1] !== undefined) {
      if (tokens.length) terms.push(`"${tokens.join(" ")}"`);
    } else {
      terms.push(...tokens.map(token => `"${token}"`));
    }
  }
  if (!terms.length) throw new MemoryError("INVALID_ARGUMENT", "query must contain searchable Unicode letters or numbers");
  return terms.join(" OR ");
}

export function utf8Prefix(text: string, budget: number): string {
  let used = 0;
  let result = "";
  for (const char of text) {
    used += bytes(char);
    if (used > budget) break;
    result += char;
  }
  return result;
}

export function searchResponse(records: MemoryRecord[], limit: number): { results: MemorySearchHit[]; has_more: boolean } {
  const fits = (response: unknown): boolean => bytes(response) <= LIMITS.response
    && bytes({ isError: false, content: [{ type: "text", text: JSON.stringify(response) }] }) + 256 <= LIMITS.response;
  const candidates = records.slice(0, limit);
  const results: MemorySearchHit[] = [];
  for (const r of candidates) {
    const content = utf8Prefix(r.content, LIMITS.excerpt);
    const hit: MemorySearchHit = {
      id: r.id, memory_type: r.memory_type, scope: r.scope, content, excerpted: content !== r.content,
      source: r.source, lifecycle: r.lifecycle,
      ...(r.project_id === undefined ? {} : { project_id: r.project_id }),
      ...(r.task_id === undefined ? {} : { task_id: r.task_id }),
      ...(r.checkout_id === undefined ? {} : { checkout_id: r.checkout_id }),
      ...(r.applicability === undefined ? {} : { applicability: r.applicability }),
    };
    if (!fits({ results: [...results, hit], has_more: false })) break;
    results.push(hit);
  }
  const response = { results, has_more: records.length > results.length };
  for (let i = 0; i < results.length; i++) {
    const hit = results[i];
    const excerpt = hit.content;
    hit.content = candidates[i].content;
    hit.excerpted = false;
    if (!fits(response)) { hit.content = excerpt; hit.excerpted = excerpt !== candidates[i].content; }
  }
  return response;
}
