import { lstat, open, readFile, readdir } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  ByteBudget,
  HandoffSnapshotError,
  copyWholeLines,
  refusesRealStoreUnderTest,
  writeText,
  type HandoffFile,
  type HandoffReference,
  type HandoffSnapshotFn,
} from "../handoff";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const FIRST_LINE_BYTES = 256 * 1024;
// Checkpoints and pasted files are context, not the conversation, so they must
// not be able to crowd out the transcript itself.
const SIDECAR_TOTAL_CAP = 16 * 1024 * 1024;

interface SidecarSource {
  name: string;
  path: string;
  size: number;
}

async function startsWithSession(path: string, id: string): Promise<boolean> {
  try {
    const handle = await open(path, "r");
    try {
      const buffer = Buffer.alloc(FIRST_LINE_BYTES);
      const { bytesRead } = await handle.read(buffer, 0, FIRST_LINE_BYTES, 0);
      const line = buffer.subarray(0, bytesRead).toString("utf8").split("\n", 1)[0] ?? "";
      const record = JSON.parse(line) as { type?: unknown; data?: { sessionId?: unknown } };
      return record.type === "session.start" && record.data?.sessionId === id;
    } finally {
      await handle.close();
    }
  } catch {
    return false;
  }
}

async function regularEntries(dir: string): Promise<SidecarSource[]> {
  let names: string[];
  try {
    names = (await readdir(dir)).sort();
  } catch {
    return [];
  }
  const out: SidecarSource[] = [];
  for (const name of names) {
    const path = join(dir, name);
    try {
      const info = await lstat(path);
      if (info.isFile()) out.push({ name, path, size: info.size });
    } catch {
      // Vanished mid-listing.
    }
  }
  return out;
}

const pad = (n: number) => String(n).padStart(2, "0");

export const snapshotCopilotTranscript: HandoffSnapshotFn = async (opts) => {
  if (refusesRealStoreUnderTest(opts.copilotHome)) return undefined;
  const id = opts.agentSessionId;
  if (!id || !UUID.test(id)) return undefined;
  const home = opts.copilotHome ?? process.env.COPILOT_HOME ?? join(homedir(), ".copilot");
  const sessionDir = join(home, "session-state", id);
  const events = join(sessionDir, "events.jsonl");
  if (!(await startsWithSession(events, id))) return undefined;

  const budget = new ByteBudget(undefined, opts.signal);
  // Cut at the last newline: /rewind can shrink the log and the CLI appends while we read.
  const transcript = await copyWholeLines(events, opts.outDir, "copilot-events.jsonl", "transcript", budget);
  const files: HandoffFile[] = [transcript];
  const references: HandoffReference[] = [];
  const warnings: string[] = [];

  let sidecarBytes = 0;
  const copySidecar = async (source: SidecarSource, name: string): Promise<void> => {
    if (sidecarBytes + source.size > SIDECAR_TOTAL_CAP) {
      references.push({ path: source.path, note: "Left in place: sidecar size cap reached." });
      return;
    }
    try {
      const text = await readFile(source.path, "utf8");
      // Pasted content is text; a NUL means a binary blob that utf8 would mangle.
      if (text.includes("\u0000")) {
        references.push({ path: source.path, note: "Left in place: not a text file." });
        return;
      }
      const written = await writeText(opts.outDir, name, text, "sidecar", budget);
      sidecarBytes += written.bytes;
      files.push({ ...written, originalName: source.name, sourcePath: source.path });
    } catch (error) {
      if (error instanceof HandoffSnapshotError && error.code === "TOO_LARGE") throw error;
      warnings.push(`Could not copy ${source.name}.`);
    }
  };

  const workspace = (await regularEntries(sessionDir)).find((e) => e.name === "workspace.yaml");
  if (workspace) await copySidecar(workspace, "copilot-workspace.yaml");
  const checkpoints = (await regularEntries(join(sessionDir, "checkpoints"))).filter((e) => e.name.endsWith(".md"));
  for (const [i, entry] of checkpoints.entries()) await copySidecar(entry, `copilot-checkpoint-${pad(i + 1)}.md`);
  for (const [i, entry] of (await regularEntries(join(sessionDir, "files"))).entries()) {
    await copySidecar(entry, `copilot-file-${pad(i + 1)}`);
  }

  return {
    agent: "github-copilot",
    agentSessionId: id,
    method: "copy",
    primary: transcript.name,
    files,
    references,
    redactions: [],
    warnings,
  };
};
