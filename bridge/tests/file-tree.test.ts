import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { buildTree, readFile, loadIgnoreRules, countNodes } from "../src/file-tree";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

describe("file-tree", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "antgrid-tree-test-"));
  });

  afterEach(() => {
    rmSync(tempDir, { recursive: true, force: true });
  });

  describe("buildTree", () => {
    it("builds a tree from a directory", () => {
      writeFileSync(join(tempDir, "file1.txt"), "hello");
      mkdirSync(join(tempDir, "subdir"));
      writeFileSync(join(tempDir, "subdir", "file2.ts"), "world");

      const ig = loadIgnoreRules(tempDir, []);
      const tree = buildTree(tempDir, tempDir, ig);

      expect(tree).not.toBeNull();
      expect(tree!.type).toBe("directory");
      expect(tree!.children).toBeDefined();
      expect(tree!.children!.length).toBe(2);

      // Directories first, then files
      expect(tree!.children![0].name).toBe("subdir");
      expect(tree!.children![0].type).toBe("directory");
      expect(tree!.children![1].name).toBe("file1.txt");
      expect(tree!.children![1].type).toBe("file");
    });

    it("respects ignore rules", () => {
      writeFileSync(join(tempDir, "keep.ts"), "keep");
      mkdirSync(join(tempDir, "node_modules"));
      writeFileSync(join(tempDir, "node_modules", "pkg.js"), "pkg");

      const ig = loadIgnoreRules(tempDir, []);
      const tree = buildTree(tempDir, tempDir, ig);

      expect(tree!.children!.length).toBe(1);
      expect(tree!.children![0].name).toBe("keep.ts");
    });

    it("respects custom exclude patterns", () => {
      writeFileSync(join(tempDir, "keep.ts"), "keep");
      writeFileSync(join(tempDir, "ignore.log"), "log");

      const ig = loadIgnoreRules(tempDir, ["*.log"]);
      const tree = buildTree(tempDir, tempDir, ig);

      expect(tree!.children!.length).toBe(1);
      expect(tree!.children![0].name).toBe("keep.ts");
    });

    it("respects depth limit", () => {
      let dir = tempDir;
      for (let i = 0; i < 12; i++) {
        dir = join(dir, `level${i}`);
        mkdirSync(dir);
        writeFileSync(join(dir, "file.txt"), "deep");
      }

      const ig = loadIgnoreRules(tempDir, []);
      const tree = buildTree(tempDir, tempDir, ig);

      // Count depth — should stop at MAX_DEPTH (10)
      let node = tree;
      let depth = 0;
      while (node?.children?.length) {
        depth++;
        node = node.children.find((c) => c.type === "directory") ?? null;
      }
      expect(depth).toBeLessThanOrEqual(11);
    });

    it("includes file extensions", () => {
      writeFileSync(join(tempDir, "app.tsx"), "react");

      const ig = loadIgnoreRules(tempDir, []);
      const tree = buildTree(tempDir, tempDir, ig);

      expect(tree!.children![0].extension).toBe(".tsx");
    });
  });

  describe("nested .gitignore", () => {
    it("applies a directory's own .gitignore, anchored at that directory", () => {
      mkdirSync(join(tempDir, "a", "sub"), { recursive: true });
      mkdirSync(join(tempDir, "b"));
      writeFileSync(join(tempDir, "a", ".gitignore"), "*.log\n/local-only\n");
      writeFileSync(join(tempDir, "a", "x.log"), "");
      writeFileSync(join(tempDir, "a", "keep.ts"), "");
      writeFileSync(join(tempDir, "a", "sub", "y.log"), "");
      writeFileSync(join(tempDir, "a", "local-only"), "");
      writeFileSync(join(tempDir, "b", "x.log"), "");
      writeFileSync(join(tempDir, "b", "local-only"), "");

      const rules = loadIgnoreRules(tempDir, []);
      const tree = buildTree(tempDir, tempDir, rules)!;
      const paths = new Set<string>();
      const visit = (n: { path: string; children?: any[] }) => {
        paths.add(n.path);
        n.children?.forEach(visit);
      };
      visit(tree);

      expect(paths.has("a/keep.ts")).toBe(true);
      expect(paths.has("a/x.log")).toBe(false);
      expect(paths.has("a/sub/y.log")).toBe(false);
      // Anchored: `/local-only` means a/local-only, not b/local-only.
      expect(paths.has("a/local-only")).toBe(false);
      expect(paths.has("b/local-only")).toBe(true);
      expect(paths.has("b/x.log")).toBe(true);

      // The same rules answer the watcher's per-path question identically.
      expect(rules.ignores("a/sub/y.log")).toBe(true);
      expect(rules.ignores("b/x.log")).toBe(false);
    });

    it("still applies the root .gitignore and the defaults", () => {
      writeFileSync(join(tempDir, ".gitignore"), "dist\n");
      mkdirSync(join(tempDir, "dist"));
      writeFileSync(join(tempDir, "dist", "out.js"), "");
      mkdirSync(join(tempDir, "node_modules"));
      writeFileSync(join(tempDir, "src.ts"), "");

      const tree = buildTree(tempDir, tempDir, loadIgnoreRules(tempDir, []))!;
      expect(tree.children!.map((c) => c.name)).toEqual([".gitignore", "src.ts"]);
    });
  });

  describe("node budget", () => {
    it("stops the listing at the budget and marks the directory it cut", () => {
      for (const f of ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"]) {
        writeFileSync(join(tempDir, f), "");
      }

      // Root + three files.
      const tree = buildTree(tempDir, tempDir, loadIgnoreRules(tempDir, []), 4)!;
      expect(tree.truncated).toBe(true);
      expect(tree.children!.map((c) => c.name)).toEqual(["a.txt", "b.txt", "c.txt"]);
      expect(countNodes(tree)).toBe(4);
    });

    it("marks every directory left unfinished, and none that completed", () => {
      mkdirSync(join(tempDir, "first"));
      writeFileSync(join(tempDir, "first", "1.txt"), "");
      mkdirSync(join(tempDir, "second"));
      writeFileSync(join(tempDir, "second", "1.txt"), "");
      writeFileSync(join(tempDir, "second", "2.txt"), "");
      mkdirSync(join(tempDir, "third"));

      // Root, first, first/1.txt, second, second/1.txt — then the cut.
      const tree = buildTree(tempDir, tempDir, loadIgnoreRules(tempDir, []), 5)!;
      const byName = Object.fromEntries(tree.children!.map((c) => [c.name, c]));
      expect(byName.first.truncated).toBeUndefined();
      expect(byName.second.truncated).toBe(true);
      expect(byName.second.children!.map((c) => c.name)).toEqual(["1.txt"]);
      expect(byName.third).toBeUndefined();
      expect(tree.truncated).toBe(true);
    });

    it("a tree within budget carries no marker", () => {
      writeFileSync(join(tempDir, "a.txt"), "");
      const tree = buildTree(tempDir, tempDir, loadIgnoreRules(tempDir, []), 2)!;
      expect(tree.truncated).toBeUndefined();
      expect(JSON.stringify(tree)).not.toContain("truncated");
    });

    // The depth guard drops children without the parent ever learning why, so
    // the cap has to mark its own cut or it is the one truncation nothing
    // reports — on the wire or in the app.
    it("marks the directory the depth cap cut", () => {
      let dir = tempDir;
      for (let i = 0; i < 12; i++) {
        dir = join(dir, `level${i}`);
        mkdirSync(dir);
        writeFileSync(join(dir, "file.txt"), "deep");
      }

      let node = buildTree(tempDir, tempDir, loadIgnoreRules(tempDir, []))!;
      let deepest = node;
      while (true) {
        const next = node.children?.find((c) => c.type === "directory");
        if (!next) break;
        node = next;
        deepest = node;
      }

      expect(deepest.children).toEqual([]);
      expect(deepest.truncated).toBe(true);
    });

    it("does not mark a capped directory whose entries were all ignored", () => {
      let dir = tempDir;
      for (let i = 0; i < 10; i++) {
        dir = join(dir, `level${i}`);
        mkdirSync(dir);
      }
      mkdirSync(join(dir, "node_modules"));

      let node = buildTree(tempDir, tempDir, loadIgnoreRules(tempDir, []))!;
      for (let i = 0; i < 10; i++) {
        node = node.children!.find((c) => c.name === `level${i}`)!;
      }

      expect(node.children).toEqual([]);
      expect(node.truncated).toBeUndefined();
    });
  });

  describe("readFile", () => {
    it("reads a text file", () => {
      writeFileSync(join(tempDir, "hello.txt"), "Hello, world!");
      const result = readFile(tempDir, "hello.txt");
      expect(result.content).toBe("Hello, world!");
      expect(result.size).toBe(13);
      expect(result.error).toBeUndefined();
    });

    it("rejects path traversal", () => {
      const result = readFile(tempDir, "../../../etc/passwd");
      expect(result.content).toBeNull();
      expect(result.error).toBe("Path traversal denied");
    });

    it("returns error for non-existent file", () => {
      const result = readFile(tempDir, "nonexistent.txt");
      expect(result.content).toBeNull();
      expect(result.error).toBe("File not found");
    });

    it("detects binary files", () => {
      const binary = Buffer.alloc(100);
      binary[50] = 0; // null byte
      binary.write("not all text", 0);
      writeFileSync(join(tempDir, "binary.dat"), binary);

      const result = readFile(tempDir, "binary.dat");
      expect(result.content).toBeNull();
      expect(result.error).toBe("Binary file");
    });

    it("rejects files over the size limit", () => {
      // Create a file > 1MB
      const bigContent = "x".repeat(1_048_577);
      writeFileSync(join(tempDir, "big.txt"), bigContent);

      const result = readFile(tempDir, "big.txt");
      expect(result.content).toBeNull();
      expect(result.error).toContain("File too large");
    });
  });

  describe("readFile binary/base64", () => {
    it("reads a PNG as base64 with mimeType", () => {
      // 1x1 PNG
      const png = Buffer.from(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
        "base64",
      );
      writeFileSync(join(tempDir, "a.png"), png);
      const r = readFile(tempDir, "a.png");
      expect(r.error).toBeUndefined();
      expect(r.encoding).toBe("base64");
      expect(r.mimeType).toBe("image/png");
      expect(Buffer.from(r.content!, "base64").length).toBe(png.length);
    });

    it("text file stays utf8", () => {
      writeFileSync(join(tempDir, "a.txt"), "hello");
      const r = readFile(tempDir, "a.txt");
      expect(r.encoding).toBe("utf8");
      expect(r.content).toBe("hello");
    });

    it("non-allowlisted binary still rejected", () => {
      writeFileSync(join(tempDir, "a.bin"), Buffer.from([0, 1, 2, 0, 3]));
      const r = readFile(tempDir, "a.bin");
      expect(r.content).toBeNull();
      expect(r.error).toBe("Binary file");
    });

    it("oversized binary rejected", () => {
      writeFileSync(join(tempDir, "big.png"), Buffer.alloc(10_485_761, 1));
      const r = readFile(tempDir, "big.png");
      expect(r.content).toBeNull();
      expect(r.error).toContain("File too large");
    });

    it("mislabeled text (image extension, no binary bytes) returns utf8", () => {
      writeFileSync(join(tempDir, "notes.ico"), "just plain text, not an icon");
      const r = readFile(tempDir, "notes.ico");
      expect(r.encoding).toBe("utf8");
      expect(r.content).toBe("just plain text, not an icon");
      expect(r.mimeType).toBeUndefined();
    });
  });

  describe("countNodes", () => {
    it("counts all nodes in a tree", () => {
      writeFileSync(join(tempDir, "a.txt"), "a");
      writeFileSync(join(tempDir, "b.txt"), "b");
      mkdirSync(join(tempDir, "sub"));
      writeFileSync(join(tempDir, "sub", "c.txt"), "c");

      const ig = loadIgnoreRules(tempDir, []);
      const tree = buildTree(tempDir, tempDir, ig)!;
      // root + sub + a.txt + b.txt + c.txt = 5
      expect(countNodes(tree)).toBe(5);
    });
  });
});
