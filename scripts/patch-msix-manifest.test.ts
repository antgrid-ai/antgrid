import { afterAll, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const scriptPath = resolve(import.meta.dir, "patch-msix-manifest.ps1");
const tempRoot = mkdtempSync(join(tmpdir(), "antgrid msix manifest test "));
const testOnWindows = process.platform === "win32" ? test : test.skip;
let packageSequence = 0;

type CommandResult = {
  status: number | null;
  stdout: string;
  stderr: string;
};

afterAll(() => {
  rmSync(tempRoot, { recursive: true, force: true });
});

// Mirrors what `dart run msix:build` emits: uap3/desktop already declared and
// ignorable, uap5 absent, exactly one <Application> carrying the branding the
// script inherits.
function manifestFixture(): string {
  return `<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" xmlns:uap3="http://schemas.microsoft.com/appx/manifest/uap/windows10/3" xmlns:desktop="http://schemas.microsoft.com/appx/manifest/desktop/windows10" xmlns:desktop4="http://schemas.microsoft.com/appx/manifest/desktop/windows10/4" IgnorableNamespaces="uap3 desktop">
  <Identity Name="RadhaAIProduct.antgrid" Publisher="CN=test" Version="1.0.0.0" ProcessorArchitecture="x64" />
  <Applications>
    <Application Id="antgrid" Executable="antgrid.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements BackgroundColor="transparent" Square150x150Logo="Images\\Square150x150Logo.png" Square44x44Logo="Images\\Square44x44Logo.png" DisplayName="antgrid" Description="antgrid" />
    </Application>
  </Applications>
</Package>
`;
}

/** A package folder holding the fixture manifest plus the named payload exes. */
function createPackage(executables: string[] = ["antgrid.exe", "antgrid-bridge.exe"]): string {
  packageSequence += 1;
  const folder = join(tempRoot, `package-${packageSequence}`);
  mkdirSync(folder, { recursive: true });
  writeFileSync(join(folder, "AppxManifest.xml"), manifestFixture());
  for (const name of executables) {
    writeFileSync(join(folder, name), "test executable");
  }
  return folder;
}

function runScript(folder: string, args: string[] = []): CommandResult {
  const result = spawnSync(
    "powershell.exe",
    [
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      scriptPath,
      "-ManifestPath",
      join(folder, "AppxManifest.xml"),
      ...args,
    ],
    { encoding: "utf8" },
  );

  return {
    status: result.status,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

function readManifest(folder: string): string {
  return readFileSync(join(folder, "AppxManifest.xml"), "utf8");
}

testOnWindows("declares the bridge as a launchable Application", () => {
  const folder = createPackage();
  const result = runScript(folder);

  expect(result.status).toBe(0);

  const manifest = readManifest(folder);
  expect(manifest).toContain('Id="bridge"');
  expect(manifest).toContain('Executable="antgrid-bridge.exe"');
  expect(manifest).toContain('EntryPoint="Windows.FullTrustApplication"');
  // The primary application must survive untouched.
  expect(manifest).toContain('Id="antgrid"');
});

testOnWindows("keeps the helper out of the app list and inherits branding", () => {
  const folder = createPackage();
  runScript(folder);

  const manifest = readManifest(folder);
  expect(manifest).toContain('AppListEntry="none"');
  // Hardcoding Images\* would break silently if msix renamed its generated
  // assets, so the logos must come from the primary application.
  expect(manifest).toContain('Square150x150Logo="Images\\Square150x150Logo.png"');
  expect(manifest).toContain('Square44x44Logo="Images\\Square44x44Logo.png"');
});

testOnWindows("marks the bridge multi-instance", () => {
  const folder = createPackage();
  runScript(folder);

  // Without this an activation while one bridge runs is handed to the existing
  // process, so concurrent hooks across terminals collapse into one.
  expect(readManifest(folder)).toContain('SupportsMultipleInstances="true"');
});

testOnWindows("adds a console-subsystem execution alias in the uap5 namespace", () => {
  const folder = createPackage();
  runScript(folder);

  const manifest = readManifest(folder);
  expect(manifest).toContain('Category="windows.appExecutionAlias"');
  expect(manifest).toContain('Alias="antgrid-bridge.exe"');
  // Subsystem is only defined on uap5:AppExecutionAlias — makeappx rejects the
  // uap3 spelling outright.
  expect(manifest).toContain("uap5:AppExecutionAlias");
  expect(manifest).toContain('Subsystem="console"');
  expect(manifest).toContain(
    'xmlns:uap5="http://schemas.microsoft.com/appx/manifest/uap/windows10/5"',
  );
  expect(manifest).toMatch(/IgnorableNamespaces="[^"]*\buap5\b/);
  expect(manifest).toMatch(/IgnorableNamespaces="[^"]*\bdesktop4\b/);
});

testOnWindows("is idempotent", () => {
  const folder = createPackage();
  runScript(folder);
  const afterFirst = readManifest(folder);

  const second = runScript(folder);
  expect(second.status).toBe(0);
  expect(second.stdout).toContain("Already declared");
  expect(readManifest(folder)).toBe(afterFirst);
});

testOnWindows("refuses to declare an executable missing from the package", () => {
  const folder = createPackage(["antgrid.exe"]);
  const result = runScript(folder);

  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("missing from the package folder");
  // A declared-but-absent executable would pass the build and fail at Store
  // ingestion instead, so nothing may be written.
  expect(readManifest(folder)).not.toContain('Id="bridge"');
});

testOnWindows("refuses to reuse an Application Id", () => {
  const folder = createPackage();
  const result = runScript(folder, ["-Id", "antgrid"]);

  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("already in use");
});

testOnWindows("accepts an alternate executable and Id", () => {
  const folder = createPackage(["antgrid.exe", "helper.exe"]);
  const result = runScript(folder, ["-Executable", "helper.exe", "-Id", "helper"]);

  expect(result.status).toBe(0);
  const manifest = readManifest(folder);
  expect(manifest).toContain('Id="helper"');
  expect(manifest).toContain('Alias="helper.exe"');
});
