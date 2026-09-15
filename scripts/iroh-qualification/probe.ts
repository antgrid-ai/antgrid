export {};
const timeout = setTimeout(() => {
  console.error(JSON.stringify({ check: "deadline", status: "fail" }));
  process.exit(1);
}, 15_000);

try {
  // The published 1.1.0 manifest points one directory below its shipped loader.
  const iroh = require("@number0/iroh/index.js");
  const builder = iroh.Endpoint.builder();
  iroh.presetMinimal(builder);
  const endpoint = await builder.bind();
  try {
    console.log(JSON.stringify({
      check: "native-bind", status: "pass", platform: process.platform,
      arch: process.arch, endpointId: endpoint.id().toString(),
    }));
  } finally {
    await endpoint.close();
  }
  console.log(JSON.stringify({ check: "native-close", status: "pass" }));
} catch (error) {
  console.error(JSON.stringify({ check: "native-bind-close", status: "fail", message: String(error) }));
  process.exitCode = 1;
} finally {
  clearTimeout(timeout);
}
