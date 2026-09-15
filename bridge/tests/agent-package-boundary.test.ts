import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, join, resolve, relative } from "node:path";
import ts from "typescript";
import { AGENTS } from "antgrid-agents/builtins";

const repo = resolve(import.meta.dir, "../..");
const packageRoot = join(repo, "packages/antgrid-agents");
const exports = new Set(Object.keys(JSON.parse(readFileSync(join(packageRoot, "package.json"), "utf8")).exports));

test("agent package and bridge respect the public dependency boundary", () => {
  const errors: string[] = [];
  const identities = new Set(Object.entries(AGENTS).flatMap(([id, spec]) => [id, spec.hookName].filter((v): v is string => !!v)));
  for (const [root, adapter] of [[join(repo, "bridge/src"), false], [join(repo, "bridge/integrations"), false], [join(packageRoot, "src"), true]] as const) {
    for (const file of new Bun.Glob("**/*.ts").scanSync(root)) {
      const path = join(root, file);
      const source = ts.createSourceFile(path, readFileSync(path, "utf8"), ts.ScriptTarget.Latest, true);
      const visit = (node: ts.Node): void => {
        if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) && node.moduleSpecifier && ts.isStringLiteral(node.moduleSpecifier)) {
          const spec = node.moduleSpecifier.text;
          if (adapter && (spec.includes("bridge/") || (spec.startsWith(".") && relative(packageRoot, resolve(dirname(path), spec)).startsWith("..")))) errors.push(`${file}: reverse dependency ${spec}`);
          if (!adapter && spec.startsWith("antgrid-agents/") && !exports.has("./" + spec.slice("antgrid-agents/".length))) errors.push(`${file}: private export ${spec}`);
          if (!adapter && spec.startsWith(".") && resolve(dirname(path), spec).startsWith(packageRoot)) errors.push(`${file}: relative package import ${spec}`);
        }
        // Type-only property keys (such as a terminal's cursor colour) do not dispatch providers.
        if (!adapter && ts.isStringLiteral(node) && !ts.isLiteralTypeNode(node.parent) && identities.has(node.text)) errors.push(`${file}: provider identity literal ${node.text}`);
        ts.forEachChild(node, visit);
      };
      visit(source);
    }
  }
  expect(errors).toEqual([]);
});
