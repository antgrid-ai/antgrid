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
