import { mkdtempSync, writeFileSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

const FIXTURES_DIR = resolve(import.meta.dir, "../fixtures");

export interface TestProject {
  dir: string;
  configPath: string;
  cleanup(): void;
}

/**
 * Create a temp project directory with test files, and a antgrid.yaml config
 * pointing to it.
 */
export function createTestProject(fixtureName: string, replacements?: Record<string, string>): TestProject {
  // Create temp project directory with sample files
  const dir = mkdtempSync(join(tmpdir(), "antgrid-eval-"));
  mkdirSync(join(dir, "src"), { recursive: true });
  writeFileSync(join(dir, "README.md"), "# Eval Test Project\nThis is a test file.\n");
  writeFileSync(join(dir, "src", "index.ts"), 'console.log("hello");\n');
  writeFileSync(join(dir, "src", "utils.ts"), 'export const add = (a: number, b: number) => a + b;\n');

  // Read fixture yaml and apply any replacements
  const fixturePath = join(FIXTURES_DIR, `${fixtureName}.yaml`);
  let yaml = readFileSync(fixturePath, "utf8");

  if (replacements) {
    for (const [key, value] of Object.entries(replacements)) {
      yaml = yaml.replace(key, value);
    }
  }

  // Write resolved config to temp dir
  const configPath = join(dir, "antgrid.yaml");
  writeFileSync(configPath, yaml);

  return {
    dir,
    configPath,
    cleanup() {
      rmSync(dir, { recursive: true, force: true });
    },
  };
}
