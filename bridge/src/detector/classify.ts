const SERVICE_NAME = /^(dev|start|serve|watch)$/;
const SERVICE_NAME_SUFFIX = /(^|[:\-])(dev|watch|serve)$/;

const COMMAND_NAMES = new Set([
  "test", "build", "lint", "format", "typecheck", "check", "clean", "deploy",
]);

const SERVICE_CONTENT = [
  /\bnodemon\b/, /--watch\b/, /\s-w\b/, /--serve\b/, /--hot\b/,
  /\bnext\s+dev\b/, /\bvite\b/, /\bnuxt\s+dev\b/, /\bremix\s+dev\b/, /\bastro\s+dev\b/,
  /\b(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?(?:dev|start|serve|watch)\b/,
];

const COMMAND_CONTENT = [
  /\bjest\b/, /\bvitest\s+run\b/, /\bpytest\b/, /\btsc\s+--noEmit\b/, /\beslint\b/, /\bprettier\b/,
  /\b(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?(?:test|build|lint|format|typecheck|check|clean|deploy)\b/,
];

export function classifyNpmScript(name: string, script: string): "service" | "command" | "unknown" {
  if (SERVICE_NAME.test(name) || SERVICE_NAME_SUFFIX.test(name)) return "service";
  if (COMMAND_NAMES.has(name)) return "command";

  const parts = script.split(/&&|;/).map((s) => s.trim()).filter(Boolean);
  const last = parts[parts.length - 1] ?? script;

  for (const re of SERVICE_CONTENT) if (re.test(last)) return "service";
  for (const re of COMMAND_CONTENT) if (re.test(last)) return "command";

  return "unknown";
}
