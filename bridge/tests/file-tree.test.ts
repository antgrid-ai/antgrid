import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import {
  buildTree,
  readFile,
  loadIgnoreRules,
  countNodes,
  externalSafeImageMime,
  listDirectory,
  listDirectoryBatch,
  allocateBudgets,
  MAX_BATCH_NODES,
} from "../src/file-tree";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, symlinkSync } from "node:fs";
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

  describe("listDirectory", () => {
    it("returns only immediate entries — a grandchild is absent", () => {
      mkdirSync(join(tempDir, "a", "sub"), { recursive: true });
      writeFileSync(join(tempDir, "a", "sub", "deep.txt"), "");
      writeFileSync(join(tempDir, "a", "shallow.txt"), "");

      const listing = listDirectory("a", tempDir, loadIgnoreRules(tempDir, []));
      expect(listing.children.map((c) => c.name)).toEqual(["sub", "shallow.txt"]);
      // Depth-1: the "sub" entry names the directory but does not walk into it.
      expect(listing.children.find((c) => c.name === "sub")!.children).toBeUndefined();
    });

    it("omits symlink entries entirely from a listing", () => {
      writeFileSync(join(tempDir, "real.txt"), "");
      const linkTarget = mkdtempSync(join(tmpdir(), "antgrid-tree-link-target-"));
      symlinkSync(linkTarget, join(tempDir, "linked"), process.platform === "win32" ? "junction" : "dir");

      const listing = listDirectory("", tempDir, loadIgnoreRules(tempDir, []));
      expect(listing.children.map((c) => c.name)).toEqual(["real.txt"]);

      rmSync(linkTarget, { recursive: true, force: true });
    });

    it("rejects a relPath containing .. segments outright", () => {
      const listing = listDirectory("../outside", tempDir, loadIgnoreRules(tempDir, []));
      expect(listing.missing).toBe(true);
      expect(listing.children).toEqual([]);
    });

    it("rejects an absolute relPath outright", () => {
      const listing = listDirectory("/etc", tempDir, loadIgnoreRules(tempDir, []));
      expect(listing.missing).toBe(true);
    });

    it.skipIf(process.platform !== "win32")(
      "rejects an escaping path even when the root is spelled with a different drive-letter case",
      () => {
        const upperRoot = tempDir.charAt(0).toUpperCase() + tempDir.slice(1);
        const listing = listDirectory("../outside", upperRoot, loadIgnoreRules(tempDir, []));
        expect(listing.missing).toBe(true);
      },
    );

    it.skipIf(process.platform !== "win32")(
      "does not mistake a path inside the checkout for outside because of drive-letter case",
      () => {
        writeFileSync(join(tempDir, "a.txt"), "");
        const lowerRoot = tempDir.charAt(0).toLowerCase() + tempDir.slice(1);
        const listing = listDirectory("", lowerRoot, loadIgnoreRules(tempDir, []));
        expect(listing.missing).toBeUndefined();
        expect(listing.children.map((c) => c.name)).toEqual(["a.txt"]);
      },
    );

    it("answers missing for a directory that does not exist", () => {
      const listing = listDirectory("does-not-exist", tempDir, loadIgnoreRules(tempDir, []));
      expect(listing.missing).toBe(true);
      expect(listing.children).toEqual([]);
    });

    it("answers an empty children array, with no missing flag, for a genuinely empty directory", () => {
      mkdirSync(join(tempDir, "empty"));
      const listing = listDirectory("empty", tempDir, loadIgnoreRules(tempDir, []));
      expect(listing.children).toEqual([]);
      expect(listing.missing).toBeUndefined();
    });

    it("matches buildTree's sort order for the same directory", () => {
      mkdirSync(join(tempDir, "zeta"));
      mkdirSync(join(tempDir, "Alpha"));
      writeFileSync(join(tempDir, "beta.txt"), "");
      writeFileSync(join(tempDir, "Aardvark.txt"), "");

      const rules = loadIgnoreRules(tempDir, []);
      const tree = buildTree(tempDir, tempDir, rules)!;
      const listing = listDirectory("", tempDir, rules);

      expect(listing.children.map((c) => c.name)).toEqual(tree.children!.map((c) => c.name));
    });

    it("includeIgnored true vs false differ exactly by the gitignored set, never by .git or .antgrid", () => {
      writeFileSync(join(tempDir, ".gitignore"), "build\n");
      mkdirSync(join(tempDir, "build"));
      writeFileSync(join(tempDir, "build", "out.js"), "");
      writeFileSync(join(tempDir, "src.ts"), "");
      mkdirSync(join(tempDir, ".git"));
      writeFileSync(join(tempDir, ".git", "HEAD"), "");
      mkdirSync(join(tempDir, ".antgrid"));
      writeFileSync(join(tempDir, ".antgrid", "state.json"), "");

      const respecting = loadIgnoreRules(tempDir, [], { gitignore: true });
      const showAll = loadIgnoreRules(tempDir, [], { gitignore: false });

      const withGit = listDirectory("", tempDir, respecting).children.map((c) => c.name).sort();
      const withoutGit = listDirectory("", tempDir, showAll).children.map((c) => c.name).sort();

      // The only difference between the two variants is the gitignored "build".
      expect(withoutGit).toEqual([...withGit, "build"].sort());
      expect(withGit).not.toContain("build");

      // DEFAULT_IGNORES applies under both flags, which is wider than the
      // spec's floor — node_modules and friends stay hidden even in the
      // show-everything variant. See IgnoreRulesOptions.gitignore.
      for (const listing of [withGit, withoutGit]) {
        expect(listing).not.toContain(".git");
        expect(listing).not.toContain(".antgrid");
      }
    });

    it("keeps hiding DEFAULT_IGNORES entries under the show-everything variant", () => {
      mkdirSync(join(tempDir, "node_modules"));
      writeFileSync(join(tempDir, "node_modules", "pkg.js"), "");
      writeFileSync(join(tempDir, "src.ts"), "");

      const showAll = loadIgnoreRules(tempDir, [], { gitignore: false });
      const names = listDirectory("", tempDir, showAll).children.map((c) => c.name);
      expect(names).toEqual(["src.ts"]);
    });

    it("refuses a path whose ANCESTOR is a symlink out of the checkout", () => {
      const outside = mkdtempSync(join(tmpdir(), "antgrid-tree-outside-"));
      mkdirSync(join(outside, "secrets"));
      writeFileSync(join(outside, "secrets", "creds.txt"), "shh");
      symlinkSync(outside, join(tempDir, "link"), process.platform === "win32" ? "junction" : "dir");

      // The final component is a real directory and the path is lexically
      // inside the root — only resolving the link catches it.
      const listing = listDirectory("link/secrets", tempDir, loadIgnoreRules(tempDir, []));
      expect(listing.missing).toBe(true);
      expect(listing.children).toEqual([]);

      rmSync(outside, { recursive: true, force: true });
    });

    it("does not report truncated when the entries past the cap were all ignored", () => {
      writeFileSync(join(tempDir, ".gitignore"), "*.log\n");
      mkdirSync(join(tempDir, "d"));
      writeFileSync(join(tempDir, "d", "a.txt"), "");
      writeFileSync(join(tempDir, "d", "b.log"), "");
      writeFileSync(join(tempDir, "d", "c.log"), "");

      // Budget 1, and the only surviving entry fits in it: everything after it
      // was going to be dropped anyway, so the app must not draw a
      // "there is more here" affordance over a complete listing.
      const listing = listDirectory("d", tempDir, loadIgnoreRules(tempDir, []), 1);
      expect(listing.children.map((c) => c.name)).toEqual(["a.txt"]);
      expect(listing.truncated).toBeUndefined();
    });

    it("gitignore: false skips nested .gitignore files too, not just the root one", () => {
      mkdirSync(join(tempDir, "a"));
      writeFileSync(join(tempDir, "a", ".gitignore"), "*.log\n");
      writeFileSync(join(tempDir, "a", "x.log"), "");
      writeFileSync(join(tempDir, "a", "keep.ts"), "");

      const showAll = loadIgnoreRules(tempDir, [], { gitignore: false });
      const listing = listDirectory("a", tempDir, showAll);
      expect(listing.children.map((c) => c.name).sort()).toEqual([".gitignore", "keep.ts", "x.log"]);
    });
  });

  describe("allocateBudgets / listDirectoryBatch", () => {
    it("gives every path at least one slot when paths outnumber the total budget", () => {
      const budgets = allocateBudgets(20_000, MAX_BATCH_NODES);
      expect(budgets).toHaveLength(20_000);
      expect(budgets.every((b) => b >= 1)).toBe(true);
    });

    it("gives a single path the whole budget", () => {
      expect(allocateBudgets(1, MAX_BATCH_NODES)).toEqual([MAX_BATCH_NODES]);
    });

    it("collapses a repeated path instead of listing it once per occurrence", () => {
      mkdirSync(join(tempDir, "hot"));
      writeFileSync(join(tempDir, "hot", "a.txt"), "");

      const results = listDirectoryBatch(
        new Array(64).fill("hot"),
        tempDir,
        loadIgnoreRules(tempDir, []),
      );
      expect(results).toHaveLength(1);
      expect(results[0].children.map((c) => c.name)).toEqual(["a.txt"]);
    });

    it("allocates fair-share across a 64-path batch and redistributes surplus in request order", () => {
      const dirs: string[] = [];
      for (let i = 0; i < 64; i++) {
        const name = `dir${i}`;
        mkdirSync(join(tempDir, name));
        dirs.push(name);
      }
      // dir0 needs far more than its fair share of a 64-unit budget (1 each);
      // dir1 needs exactly its share; the other 62 need none of it.
      for (let i = 0; i < 100; i++) {
        writeFileSync(join(tempDir, "dir0", `f${i}.txt`), "");
      }
      writeFileSync(join(tempDir, "dir1", "only.txt"), "");

      const rules = loadIgnoreRules(tempDir, []);
      const results = listDirectoryBatch(dirs, tempDir, rules, 64);

      expect(results).toHaveLength(64);

      // dir1 fit inside its own fair share and is never marked truncated.
      expect(results[1].truncated).toBeUndefined();
      expect(results[1].children.map((c) => c.name)).toEqual(["only.txt"]);

      // The 62 empty directories hand their whole share back as surplus.
      for (let i = 2; i < 64; i++) {
        expect(results[i].children).toEqual([]);
        expect(results[i].truncated).toBeUndefined();
      }

      // dir0 receives every unit of surplus the other 63 listings did not
      // need (63 units, on top of its own 1), but 100 real files still
      // exceeds the 64 total the batch was given, so it stays truncated.
      expect(results[0].truncated).toBe(true);
      expect(results[0].children.length).toBe(63);

      const total = results.reduce((sum, r) => sum + r.children.length, 0);
      expect(total).toBeLessThanOrEqual(64);
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

    it("reads a JFIF as base64 with the jpeg mimeType", () => {
      // Reuses the 1x1 PNG bytes — only the extension→mime mapping is under test.
      const bytes = Buffer.from(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
        "base64",
      );
      writeFileSync(join(tempDir, "a.jfif"), bytes);
      const r = readFile(tempDir, "a.jfif");
      expect(r.error).toBeUndefined();
      expect(r.encoding).toBe("base64");
      expect(r.mimeType).toBe("image/jpeg");
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

  describe("readFile — external image exception", () => {
    // The Files-tab-outside-the-checkout link an image-generation tool's own
    // output directory produces: `readFile`'s traversal guard normally
    // refuses anything outside `projectRoot` outright, but a recognized
    // image extension is a narrow, deliberate exception — see
    // EXTERNAL_SAFE_IMAGE_MIME in file-tree.ts.
    let externalDir: string;

    beforeEach(() => {
      externalDir = mkdtempSync(join(tmpdir(), "antgrid-external-test-"));
    });

    afterEach(() => {
      rmSync(externalDir, { recursive: true, force: true });
    });

    it("serves a recognized image from outside the checkout root", () => {
      const png = Buffer.from(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
        "base64",
      );
      const outsidePath = join(externalDir, "generated.png");
      writeFileSync(outsidePath, png);

      const r = readFile(tempDir, outsidePath);
      expect(r.error).toBeUndefined();
      expect(r.encoding).toBe("base64");
      expect(r.mimeType).toBe("image/png");
    });

    it("still denies a non-image path outside the checkout root", () => {
      const outsidePath = join(externalDir, "notes.txt");
      writeFileSync(outsidePath, "hello");

      const r = readFile(tempDir, outsidePath);
      expect(r.content).toBeNull();
      expect(r.error).toBe("Path traversal denied");
    });

    it("still denies a PDF outside the checkout root (excluded on purpose)", () => {
      const outsidePath = join(externalDir, "generated.pdf");
      writeFileSync(outsidePath, "not a real pdf — the extension is what's under test");

      const r = readFile(tempDir, outsidePath);
      expect(r.content).toBeNull();
      expect(r.error).toBe("Path traversal denied");
    });
  });

  describe("externalSafeImageMime", () => {
    it("recognizes common raster image extensions", () => {
      expect(externalSafeImageMime("a.png")).toBe("image/png");
      expect(externalSafeImageMime("a.JPG")).toBe("image/jpeg");
      expect(externalSafeImageMime("a.webp")).toBe("image/webp");
    });

    it("excludes svg, pdf, and ico even though other surfaces can render them", () => {
      // .svg can embed a script, .pdf is a heavier parser, .ico has no real
      // "generated output" use case here — none is worth the exposure for a
      // path this app never chose to trust with a checkout.
      expect(externalSafeImageMime("a.svg")).toBeUndefined();
      expect(externalSafeImageMime("a.pdf")).toBeUndefined();
      expect(externalSafeImageMime("a.ico")).toBeUndefined();
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
