import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

// The build already installs bridge dependencies; avoid a second script lockfile.
const requireBridge = createRequire(new URL("../bridge/package.json", import.meta.url));
const { z } = requireBridge("zod");
const { parse: parseYaml } = requireBridge("yaml");
const root = fileURLToPath(new URL("../", import.meta.url));
const hash = z.string().regex(/^[0-9a-f]{64}$/);
const pins = z.object({
  schemaVersion: z.literal(1),
  packages: z.record(z.string(), z.object({ version: z.string(), archiveSha256: hash })),
  rustFiles: z.object({ "Cargo.lock": hash, "Cargo.toml": hash }),
}).parse(JSON.parse(await readFile(join(root, "scripts/iroh-qualification/flutter-source-pins.json"), "utf8"))) as {
  packages: Record<string, { version: string; archiveSha256: string }>;
  rustFiles: Record<string, string>;
};
const configPath = join(root, "app/.dart_tool/package_config.json");
const config = z.object({ packages: z.array(z.object({ name: z.string(), rootUri: z.string() })) })
  .parse(JSON.parse(await readFile(configPath, "utf8"))) as { packages: { name: string; rootUri: string }[] };
async function yaml(path: string): Promise<Record<string, any>> {
  return z.record(z.string(), z.unknown()).parse(parseYaml(await readFile(path, "utf8")));
}
const lock = await yaml(join(root, "app/pubspec.lock"));
const appManifest = await yaml(join(root, "app/pubspec.yaml"));
const transportManifest = await yaml(join(root, "packages/antgrid_peer_transport/pubspec.yaml"));
const activeRoots = new Map<string, string>();
for (const [name, pin] of Object.entries(pins.packages)) {
  const matches = config.packages.filter((pkg) => pkg.name === name);
  assert.equal(matches.length, 1, `Expected exactly one resolved ${name}`);
  const packageUrl = new URL(matches[0].rootUri, pathToFileURL(configPath));
  assert.equal(packageUrl.protocol, "file:", `${name} must resolve to a local package`);
  const packageRoot = fileURLToPath(packageUrl);
  activeRoots.set(name, packageRoot);
  const manifest = await yaml(join(packageRoot, "pubspec.yaml"));
  assert.equal(manifest.name, name, `${name} resolved package identity changed`);
  assert.equal(manifest.version, pin.version, `${name} resolved package version changed`);
  const locked = lock.packages?.[name];
  assert.equal(locked?.version, pin.version, `${name} app lock version changed`);
  assert.equal(locked?.source, "hosted", `${name} app lock source changed`);
  assert.equal(locked?.description?.url, "https://pub.dev", `${name} package host changed`);
  assert.equal(locked?.description?.sha256, pin.archiveSha256, `${name} pub archive digest changed`);
}
assert.equal(appManifest.dependencies?.iroh_flutter, pins.packages.iroh_flutter.version, "App plugin pin changed");
for (const name of ["iroh_quic", "flutter_rust_bridge"]) {
  assert.equal(transportManifest.dependencies?.[name], pins.packages[name].version, `${name} transport pin changed`);
}
const rustRoot = join(activeRoots.get("iroh_flutter")!, "rust");
const generatedDart = await readFile(join(activeRoots.get("iroh_quic")!, "lib/src/rust/frb_generated.dart"), "utf8");
assert.equal(/String get codegenVersion => '([^']+)'/.exec(generatedDart)?.[1],
  pins.packages.flutter_rust_bridge.version, "Dart generated FRB/runtime mismatch");
const generatedRust = await readFile(join(rustRoot, "src/frb_generated.rs"), "utf8");
assert.equal(/FLUTTER_RUST_BRIDGE_CODEGEN_VERSION: &str = "([^"]+)"/.exec(generatedRust)?.[1],
  pins.packages.flutter_rust_bridge.version, "Rust generated FRB/runtime mismatch");
const verified: Record<string, string> = {};
for (const [file, expected] of Object.entries(pins.rustFiles)) {
  const actual = createHash("sha256").update(await readFile(join(rustRoot, file))).digest("hex");
  assert.equal(actual, expected, `Active iroh_flutter rust/${file} differs from published baseline; do not regenerate pins from build output`);
  verified[file] = actual;
}
console.log(JSON.stringify({ check: "iroh-packaging-source-pins", status: "pass",
  packages: Object.fromEntries(Object.entries(pins.packages).map(([name, pin]) => [name, pin.version])),
  rust: verified }));
