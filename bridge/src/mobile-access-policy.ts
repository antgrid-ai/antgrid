import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export interface MobileAccessPolicyStore {
  listSameAccountDefaultProjects(): string[];
  isEnabled(projectId: string): boolean;
  enableProject(projectId: string): void;
  disableProject(projectId: string): boolean;
}

interface FileShape {
  version: 1;
  sameAccountDefaultProjects: string[];
}

export function loadMobileAccessPolicy(abDir: string): MobileAccessPolicyStore {
  const dir = join(abDir, "agents");
  const path = join(dir, "mobile-access-policy.json");

  let sameAccountDefaultProjects = readFile(path);

  function flush() {
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const data: FileShape = { version: 1, sameAccountDefaultProjects };
    writeFileSync(path, JSON.stringify(data, null, 2));
    if (process.platform !== "win32") chmodSync(path, 0o600);
  }

  return {
    listSameAccountDefaultProjects: () => sameAccountDefaultProjects.slice(),
    isEnabled: (projectId) => sameAccountDefaultProjects.includes(projectId),
    enableProject: (projectId) => {
      if (sameAccountDefaultProjects.includes(projectId)) return;
      sameAccountDefaultProjects = [...sameAccountDefaultProjects, projectId].sort();
      flush();
    },
    disableProject: (projectId) => {
      const next = sameAccountDefaultProjects.filter((p) => p !== projectId);
      if (next.length === sameAccountDefaultProjects.length) return false;
      sameAccountDefaultProjects = next;
      flush();
      return true;
    },
  };
}

function readFile(path: string): string[] {
  if (!existsSync(path)) return [];
  try {
    const raw = readFileSync(path, "utf8");
    const parsed = JSON.parse(raw) as FileShape;
    if (parsed.version !== 1 || !Array.isArray(parsed.sameAccountDefaultProjects)) return [];
    if (!parsed.sameAccountDefaultProjects.every((projectId) => typeof projectId === "string")) return [];
    return parsed.sameAccountDefaultProjects.slice().sort();
  } catch {
    return [];
  }
}
