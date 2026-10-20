import { lstat, realpath } from "node:fs/promises";
import { join, relative, sep } from "node:path";
import {
  ByteBudget,
  HandoffSnapshotError,
  SAFE_NATIVE_ID,
  copyWholeLines,
  refusesRealStoreUnderTest,
  type HandoffFile,
  type HandoffReference,
  type HandoffSnapshotFn,
} from "../handoff";
import { antigravityCliHome } from "./title";

const TRANSCRIPT_SEGMENTS = [".system_generated", "logs", "transcript_full.jsonl"];
const ARTIFACT_CAP = 1024 * 1024;

async function regularSize(path: string): Promise<number | undefined> {
  try {
    const info = await lstat(path);
    return info.isFile() ? info.size : undefined;
  } catch {
    return undefined;
  }
}

async function isDirectory(path: string): Promise<boolean> {
  try {
    return (await lstat(path)).isDirectory();
  } catch {
    return false;
  }
}

/** A hook-supplied path is only a hint: it counts when, after symlinks resolve,
 * it is exactly this conversation's full transcript inside the CLI's brain dir. */
async function acceptHint(hint: string, home: string, id: string): Promise<string | undefined> {
  try {
    const real = await realpath(hint);
    const rel = relative(await realpath(join(home, "brain")), real).split(sep);
    const expected = [id, ...TRANSCRIPT_SEGMENTS];
    return rel.length === expected.length && rel.every((part, i) => part === expected[i]) ? real : undefined;
  } catch {
    return undefined;
  }
}

export const snapshotAntigravityTranscript: HandoffSnapshotFn = async (opts) => {
  if (refusesRealStoreUnderTest(opts.antigravityHome)) return undefined;
  const id = opts.agentSessionId;
  if (!id || !SAFE_NATIVE_ID.test(id)) return undefined;
  const home = opts.antigravityHome ?? antigravityCliHome();
  const brainDir = join(home, "brain", id);

  let source = opts.transcriptPath ? await acceptHint(opts.transcriptPath, home, id) : undefined;
  // Never transcript.jsonl: it truncates long fields.
  source ??= join(brainDir, ...TRANSCRIPT_SEGMENTS);
  if ((await regularSize(source)) === undefined) return undefined;

  const budget = new ByteBudget(undefined, opts.signal);
  const transcript = await copyWholeLines(source, opts.outDir, "antigravity-transcript.jsonl", "transcript", budget);
  const files: HandoffFile[] = [transcript];
  const warnings: string[] = [];

  for (const [original, name] of [["plan.md", "antigravity-plan.md"], ["walkthrough.md", "antigravity-walkthrough.md"]] as const) {
    const path = join(brainDir, original);
    const size = await regularSize(path);
    if (size === undefined) continue;
    if (size > ARTIFACT_CAP) {
      warnings.push(`${original} is over 1 MB and was not copied.`);
      continue;
    }
    try {
      const copied = await copyWholeLines(path, opts.outDir, name, "sidecar", budget);
      files.push({ ...copied, originalName: original });
    } catch (error) {
      if (error instanceof HandoffSnapshotError && error.code === "TOO_LARGE") throw error;
      warnings.push(`Could not copy ${original}.`);
    }
  }

  const references: HandoffReference[] = [];
  const generated = join(brainDir, ".system_generated");
  if (await isDirectory(join(generated, "steps"))) {
    references.push({ path: join(generated, "steps"), note: "Full output of each tool step." });
  }
  if (await isDirectory(join(generated, "tasks"))) {
    references.push({ path: join(generated, "tasks"), note: "Logs of background commands." });
  }
  return {
    agent: "antigravity",
    agentSessionId: id,
    method: "copy",
    primary: transcript.name,
    files,
    references,
    redactions: [],
    warnings,
  };
};
