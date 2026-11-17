// SPDX-License-Identifier: MPL-2.0

import { createHash, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { z } from "zod";
import { LIMITS, bytes } from "../../src/contracts";
import { utf8Prefix } from "../../src/search";
import type { PublicDocument, PublicGroup } from "./dataset-types";
import { utf8Parts } from "./longmemeval";

export const TECHNICAL_SOURCE_URL = "https://huggingface.co/datasets/BeIR/cqadupstack";
export const TECHNICAL_REVISION = "e84b7220ce5a4e6c49aeb568983b0ec5a7584c2c";
const QRELS_REVISION = "13595a9f221256a9a21e91c8b0fed3563382b6a7";
const READER_VERSION = "1.4.3";
const SOURCE_FILES = {
  corpus: { name: "corpus.parquet", size: 20111039, sha256: "b8eefa212252fe5af6ee72ba530df053740ff30c2c0bea77089f8a9271e94f75", url: `${TECHNICAL_SOURCE_URL}/resolve/${TECHNICAL_REVISION}/programmers/corpus/corpus-00000-of-00001.parquet` },
  queries: { name: "queries.parquet", size: 41633, sha256: "106ba4777034ccec608a623ac93b5cfad63d89effc64d0528759ea94e276345d", url: `${TECHNICAL_SOURCE_URL}/resolve/${TECHNICAL_REVISION}/programmers/queries/queries-00000-of-00001.parquet` },
  qrels: { name: "test.tsv", size: 27053, sha256: "ed69afa873c64d34298792d694c82c4293e4b7e3c6ea3edc7a73662d4b0cba76", url: `https://huggingface.co/datasets/BeIR/cqadupstack-qrels/resolve/${QRELS_REVISION}/programmers/test.tsv` },
} as const;
const NORMALIZED_FILES = {
  "corpus.jsonl": { name: "corpus.jsonl", size: 35249481, sha256: "cb91fd1bfae2220559bbcede0bcb4994b785881ed55346507a497ee30ae0ff33" },
  "queries.jsonl": { name: "queries.jsonl", size: 71745, sha256: "49ad45f0ac82863a84f3ede8deb9c90ff419ffc3c7fc364a3efd16efde07c589" },
} as const;
const DocumentSchema = z.object({ _id: z.string().min(1), title: z.string(), text: z.string() });
const QuerySchema = z.object({ _id: z.string().min(1), text: z.string().min(1) });
export type UnsupportedTechnicalQuery = { id: string; bytes: number; reason: string };
const checksum = (value: string | Uint8Array) => createHash("sha256").update(value).digest("hex");

export function parseTechnicalDataset(corpus: string, queries: string, qrels: string): { group: PublicGroup; unsupportedQueries: UnsupportedTechnicalQuery[] } {
  const originals = new Set<string>();
  const documents: PublicDocument[] = corpus.trim().split(/\r?\n/).flatMap(line => {
    const row = DocumentSchema.parse(JSON.parse(line));
    if (originals.has(row._id)) throw new Error(`Duplicate technical document ${row._id}`);
    originals.add(row._id);
    const content = `${row.title}\n\n${row.text}`;
    // Partition the same source text in every variant; metadata must not rescue information omitted from the body-only corpus.
    return utf8Parts(content, LIMITS.content).map((part, index) => ({
      id: `cqadupstack-programmers-${row._id}-c${String(index).padStart(3, "0")}`,
      content: part, title: utf8Prefix(row.title, LIMITS.title), sourceIds: [row._id],
    }));
  });
  const relevance = new Map<string, Set<string>>();
  const lines = qrels.trim().split(/\r?\n/);
  if (lines.shift() !== "query-id\tcorpus-id\tscore") throw new Error("Unexpected technical qrels header");
  for (const line of lines) {
    const fields = line.split("\t");
    const [query, document, score] = fields;
    if (fields.length !== 3 || !query || !document || !/^\d+$/.test(score ?? "")) throw new Error("Invalid technical qrels row");
    if (!originals.has(document)) throw new Error(`Missing technical relevance document ${document}`);
    if (Number(score) > 0) { const found = relevance.get(query) ?? new Set<string>(); found.add(document); relevance.set(query, found); }
  }
  const seen = new Set<string>();
  const unsupportedQueries: UnsupportedTechnicalQuery[] = [];
  const testQueries = queries.trim().split(/\r?\n/).map(line => QuerySchema.parse(JSON.parse(line))).filter(row => relevance.has(row._id)).map(row => {
    if (seen.has(row._id)) throw new Error(`Duplicate technical query ${row._id}`);
    seen.add(row._id);
    const size = bytes(row.text);
    if (size > LIMITS.query) unsupportedQueries.push({ id: row._id, bytes: size, reason: `Query exceeds ${LIMITS.query}-byte service limit; retained unchanged` });
    if (!/[\p{L}\p{N}]/u.test(row.text)) unsupportedQueries.push({ id: row._id, bytes: size, reason: "Query has no searchable Unicode letters or numbers; retained unchanged" });
    return { id: row._id, text: row.text, category: "programming-duplicate-question", relevantIds: [...relevance.get(row._id)!] };
  });
  if (testQueries.length !== relevance.size) throw new Error("Some technical test qrels have no query");
  return { group: { id: "cqadupstack-programmers-test", documents, queries: testQueries }, unsupportedQueries };
}

export function verifyTechnicalSource(value: Uint8Array, expected: { name: string; size: number; sha256: string }): void {
  if (value.byteLength !== expected.size || checksum(value) !== expected.sha256) throw new Error(`Technical source checksum mismatch: ${expected.name}`);
}

async function sourceFile(directory: string, file: typeof SOURCE_FILES[keyof typeof SOURCE_FILES]): Promise<void> {
  const target = join(directory, file.name);
  if (existsSync(target)) { verifyTechnicalSource(readFileSync(target), file); return; }
  const temporary = `${target}.${randomUUID()}.partial`;
  try {
    // curl enforces transfer timeouts across HF redirects; Bun fetch can remain pending past its abort deadline on Windows.
    const download = Bun.spawn([process.platform === "win32" ? "curl.exe" : "curl", "--fail", "--silent", "--show-error", "--location",
      "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "10", "--max-time", "120",
      "--max-filesize", String(file.size), "--output", temporary, file.url], { stdout: "pipe", stderr: "pipe", timeout: 125_000 });
    const [exitCode, error] = await Promise.all([download.exited, new Response(download.stderr).text()]);
    if (exitCode !== 0) throw new Error(`Technical source download failed: ${file.name} (${exitCode}): ${error}`);
    verifyTechnicalSource(readFileSync(temporary), file);
    renameSync(temporary, target);
  } finally { rmSync(temporary, { force: true }); }
}

function normalizeParquet(directory: string, readerDirectory: string): void {
  const temporary = randomUUID();
  const paths = [join(directory, `corpus.${temporary}.partial`), join(directory, `queries.${temporary}.partial`)];
  try {
    const extraction = Bun.spawnSync(["python", "-I", "-S", "-c", [
      "import json,pathlib,sys",
      "sys.path.insert(0,sys.argv[1])",
      "try: import duckdb",
      "except ImportError: raise SystemExit('Install the evaluation reader first: python -m pip install --no-deps --target '+sys.argv[1]+' duckdb==1.4.3')",
      `assert duckdb.__version__=='${READER_VERSION}', 'Unexpected evaluation reader version'`,
      "db=duckdb.connect(':memory:',config={'autoinstall_known_extensions':'false','autoload_known_extensions':'false'})",
      "for source,target,columns in [(sys.argv[2],sys.argv[4],['_id','title','text']),(sys.argv[3],sys.argv[5],['_id','text'])]:",
      " rows=db.execute('SELECT '+','.join(columns)+' FROM read_parquet(?) ORDER BY _id',[source])",
      " with pathlib.Path(target).open('w',encoding='utf-8',newline='\\n') as output:",
      "  while batch:=rows.fetchmany(1024):",
      "   for row in batch: output.write(json.dumps(dict(zip(columns,row)),ensure_ascii=False,separators=(',',':'))+'\\n')",
      "db.close()",
    ].join("\n"), readerDirectory, join(directory, "corpus.parquet"), join(directory, "queries.parquet"), ...paths], { stdout: "pipe", stderr: "pipe", timeout: 60_000 });
    if (extraction.exitCode !== 0) throw new Error(`Technical Parquet conversion failed: ${extraction.stderr.toString()}`);
    verifyTechnicalSource(readFileSync(paths[0]!), NORMALIZED_FILES["corpus.jsonl"]);
    verifyTechnicalSource(readFileSync(paths[1]!), NORMALIZED_FILES["queries.jsonl"]);
    // Rebuild from verified source bytes each time so edited or stale normalized caches never enter the evaluation.
    renameSync(paths[0]!, join(directory, "corpus.jsonl"));
    renameSync(paths[1]!, join(directory, "queries.jsonl"));
  } finally { for (const path of paths) rmSync(path, { force: true }); }
}

export async function prepareTechnicalDataset(directory: string, readerDirectory = resolve(import.meta.dir, "../../../../.tmp/memory-public-evaluation/python")) {
  mkdirSync(directory, { recursive: true });
  await Promise.all(Object.values(SOURCE_FILES).map(file => sourceFile(directory, file)));
  normalizeParquet(directory, readerDirectory);
  const names = ["corpus.jsonl", "queries.jsonl", "test.tsv"];
  const values = names.map(name => readFileSync(join(directory, name), "utf8"));
  const parsed = parseTechnicalDataset(values[0]!, values[1]!, values[2]!);
  const sourceIds = new Set(parsed.group.documents.flatMap(document => document.sourceIds));
  const sourceDocuments = sourceIds.size;
  if (sourceDocuments !== 32176 || parsed.group.queries.length !== 876) throw new Error("Technical source count changed");
  const queryCorpusOverlap = parsed.group.queries.filter(query => sourceIds.has(query.id)).length;
  const selfRelevantQueries = parsed.group.queries.filter(query => query.relevantIds.includes(query.id)).length;
  if (queryCorpusOverlap || selfRelevantQueries) throw new Error("Technical source contains self-matches; implement exclusion before ranking and limiting before evaluation");
  const manifest = {
    dataset: "BEIR CQADupStack programmers", variant: "test", sourceUrl: TECHNICAL_SOURCE_URL,
    revision: TECHNICAL_REVISION, qrelsRevision: QRELS_REVISION,
    sourceMethod: "Checksum-verified official Parquet files; deterministic _id-order JSONL includes only original ID, title and text",
    reader: { name: "duckdb", version: READER_VERSION, installation: "Isolated evaluation directory; no global environment changes" },
    sourceFiles: SOURCE_FILES,
    files: Object.fromEntries(names.map((name, index) => [name, { sha256: checksum(values[index]!), bytes: bytes(values[index]!) }])),
    sourceDocuments, documents: parsed.group.documents.length, queries: parsed.group.queries.length,
    unsupportedQueries: parsed.unsupportedQueries,
    queryCorpusOverlap, selfRelevantQueries,
    chunking: { maxBytes: LIMITS.content, version: "original-title-body-utf8-v1" },
    metadata: "Original title and body are partitioned without truncation in every variant; optional source title is UTF-8 capped at 256 bytes; no query-derived or generated metadata",
  };
  writeFileSync(join(directory, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
  return { groups: [parsed.group], manifest };
}

if (import.meta.main) {
  const { manifest } = await prepareTechnicalDataset(resolve(import.meta.dir, "../../../../.tmp/memory-public-evaluation/datasets/cqadupstack-programmers"));
  console.log(JSON.stringify(manifest, null, 2));
}
