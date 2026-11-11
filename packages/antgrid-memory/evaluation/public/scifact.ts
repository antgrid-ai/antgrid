// SPDX-License-Identifier: MPL-2.0

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { z } from "zod";
import { LIMITS, bytes } from "../../src/contracts";
import { utf8Prefix } from "../../src/search";
import type { PublicDocument, PublicGroup } from "./dataset-types";

const URL = "https://public.ukp.informatik.tu-darmstadt.de/thakur/BEIR/datasets/scifact.zip";
const MD5 = "5f7d1de60b170fc8027bb7898e2efca1";
const DocumentSchema = z.object({ _id: z.string(), title: z.string(), text: z.string() });
const QuerySchema = z.object({ _id: z.string(), text: z.string() });

export function parseSciFact(corpus: string, queries: string, qrels: string): PublicGroup {
  const documents: PublicDocument[] = corpus.trim().split(/\r?\n/).map(line => {
    const row = DocumentSchema.parse(JSON.parse(line));
    // Keeping the source title in every body holds available information constant
    // when the metadata columns are disabled for the body-only ablation.
    const content = `${row.title}\n\n${row.text}`;
    if (bytes(content) > LIMITS.content) throw new Error(`SciFact document ${row._id} exceeds body limit; explicit chunking required`);
    return { id: `scifact-${row._id}`, content, title: utf8Prefix(row.title, LIMITS.title), sourceIds: [row._id] };
  });
  const documentIds = new Set(documents.flatMap(row => row.sourceIds));
  const relevance = new Map<string, string[]>();
  const lines = qrels.trim().split(/\r?\n/);
  if (lines.shift() !== "query-id\tcorpus-id\tscore") throw new Error("Unexpected SciFact qrels header");
  for (const line of lines) {
    const [query, document, score] = line.split("\t");
    if (!query || !document || !Number.isFinite(Number(score))) throw new Error("Invalid qrels row");
    if (!documentIds.has(document)) throw new Error(`Missing judged document ${document}`);
    if (Number(score) > 0) relevance.set(query, [...(relevance.get(query) ?? []), document]);
  }
  const testQueries = queries.trim().split(/\r?\n/).map(line => QuerySchema.parse(JSON.parse(line)))
    .filter(row => relevance.has(row._id)).map(row => ({
      id: row._id, text: row.text, category: "scientific-claim", relevantIds: [...new Set(relevance.get(row._id)!)],
    }));
  if (testQueries.length !== relevance.size) throw new Error("Some test qrels have no query");
  return { id: "scifact-test", documents, queries: testQueries };
}

export async function prepareSciFact(directory: string) {
  mkdirSync(directory, { recursive: true });
  const zipPath = join(directory, "scifact.zip");
  if (!existsSync(zipPath)) {
    const response = await fetch(URL, { signal: AbortSignal.timeout(120_000) });
    if (!response.ok) throw new Error(`SciFact download HTTP ${response.status}`);
    writeFileSync(zipPath, new Uint8Array(await response.arrayBuffer()));
  }
  const archive = readFileSync(zipPath);
  if (createHash("md5").update(archive).digest("hex") !== MD5) throw new Error("SciFact archive does not match upstream checksum");
  // Read only fixed members, never extract caller-controlled archive paths.
  const extraction = Bun.spawnSync(["python", "-c", [
    "import pathlib,sys,zipfile",
    "root=pathlib.Path(sys.argv[2])",
    "with zipfile.ZipFile(sys.argv[1]) as z:",
    " for member,name in [('scifact/corpus.jsonl','corpus.jsonl'),('scifact/queries.jsonl','queries.jsonl'),('scifact/qrels/test.tsv','test.tsv')]:",
    "  info=z.getinfo(member)",
    "  assert info.file_size < 64*1024*1024, 'oversized archive member'",
    "  (root/name).write_bytes(z.read(member))",
  ].join("\n"), zipPath, directory], { stdout: "pipe", stderr: "pipe" });
  if (extraction.exitCode !== 0) throw new Error(`SciFact extraction failed: ${extraction.stderr.toString()}`);
  const paths = ["corpus.jsonl", "queries.jsonl", "test.tsv"];
  const values = paths.map(path => readFileSync(join(directory, path), "utf8"));
  const group = parseSciFact(values[0]!, values[1]!, values[2]!);
  return { groups: [group], manifest: {
    dataset: "BEIR SciFact", variant: "test", sourceUrl: URL, upstreamMd5: MD5,
    sha256: createHash("sha256").update(archive).digest("hex"), sourceBytes: archive.length,
    files: Object.fromEntries(paths.map((path, i) => [path, createHash("sha256").update(values[i]!).digest("hex")])),
    documents: group.documents.length, queries: group.queries.length,
    metadata: "Source title duplicated into optional title (UTF-8 capped); all variants retain original title and abstract in body; no description generation",
  } };
}
