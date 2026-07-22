import { existsSync, readFileSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { z } from "zod";
import { atomicWriteFile } from "./discovery";
import { resolveAbDir } from "./antgrid-dir";

export const HostFileSchema = z.object({
  version: z.literal(1),
  pid: z.number().int().positive(),
  controlPort: z.number().int().min(1).max(65535),
  token: z.string().min(1),
  startedAt: z.string(),
  agentVersion: z.string(),
});
export type HostFile = z.infer<typeof HostFileSchema>;

/** Machine-level host discovery file. ANTGRID_DIR-aware (unlike the per-project
 *  discovery files, which use homedir() directly — see plan decision 7). */
export function hostFilePath(): string {
  return join(resolveAbDir(), "host.json");
}

export function writeHostFile(path: string, data: HostFile): void {
  // Same protection rationale as the per-project discovery file: the token
  // grants control-plane access. 0o600 on POSIX; inherits ACL on Windows.
  atomicWriteFile(path, JSON.stringify(data, null, 2), { dirMode: 0o700, fileMode: 0o600 });
}

export function readHostFile(path: string): HostFile | null {
  if (!existsSync(path)) return null;
  try {
    const parsed = HostFileSchema.safeParse(JSON.parse(readFileSync(path, "utf8")));
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}

export function removeHostFile(path: string): void {
  try { unlinkSync(path); } catch { /* best-effort */ }
}
