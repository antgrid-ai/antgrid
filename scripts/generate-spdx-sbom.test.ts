import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const scriptPath = resolve(import.meta.dir, "generate-spdx-sbom.ts");

test("hashes tracked symlink targets without following directories or dangling links", () => {
  const folder = mkdtempSync(join(tmpdir(), "antgrid-sbom-"));
  function git(args: string[], input?: string): string {
    const result = spawnSync("git", args, { cwd: folder, encoding: "utf8", input });
    expect(result.status).toBe(0);
    return result.stdout.trim();
  }
  const sha1 = (data: string | Buffer) => createHash("sha1").update(data).digest("hex");

  try {
    git(["init"]);
    mkdirSync(join(folder, "LICENSES"));
    for (const name of ["Elastic-2.0", "Antgrid-Brand", "Third-Party-Trademark"]) {
      writeFileSync(join(folder, "LICENSES", `LicenseRef-${name}.txt`), "fixture licence\n");
    }
    mkdirSync(join(folder, ".claude", "skills"), { recursive: true });
    mkdirSync(join(folder, ".agents"));
    const payload = Buffer.from([0, 255, 13, 10, 42]);
    writeFileSync(join(folder, ".claude", "skills", "payload.bin"), payload);
    git(["add", "LICENSES", ".claude"]);

    // Windows checkouts can materialize links differently; Git's mode and blob
    // must determine their checksum regardless of the filesystem representation.
    if (process.platform === "win32") {
      mkdirSync(join(folder, ".agents", "skills"));
    } else {
      symlinkSync("../.claude/skills", join(folder, ".agents", "skills"));
      symlinkSync("missing-target", join(folder, "dangling-link"));
    }
    for (const [path, target] of [
      [".agents/skills", "../.claude/skills"],
      ["dangling-link", "missing-target"],
    ]) {
      const blob = git(["hash-object", "-w", "--stdin"], target);
      git(["update-index", "--add", "--cacheinfo", `120000,${blob},${path}`]);
    }

    const result = spawnSync(process.execPath, ["run", scriptPath, "sbom.json", "test", "fixture"], {
      cwd: folder,
      encoding: "utf8",
    });
    expect(result.stderr).toBe("");
    expect(result.status).toBe(0);
    const sbom = JSON.parse(readFileSync(join(folder, "sbom.json"), "utf8"));
    for (const [path, data] of [
      [".agents/skills", "../.claude/skills"],
      ["dangling-link", "missing-target"],
      [".claude/skills/payload.bin", payload],
    ] as const) {
      expect(sbom.files.find((file: { fileName: string }) => file.fileName === `./${path}`)?.checksums)
        .toEqual([{ algorithm: "SHA1", checksumValue: sha1(data) }]);
    }
    expect(sbom.files).toHaveLength(6);
    const rootPackage = sbom.packages.find((pkg: { SPDXID: string }) => pkg.SPDXID === "SPDXRef-Package-Root");
    expect(rootPackage.packageVerificationCode.packageVerificationCodeValue).toBe(sha1(
      sbom.files.map((file: { checksums: { checksumValue: string }[] }) => file.checksums[0]!.checksumValue)
        .sort().join(""),
    ));
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});
