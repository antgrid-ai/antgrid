import { runDbSerializer } from "../../packages/antgrid-agents/src/agents/handoff/db-serialize";

// Entry for smoke-db-serialize-binary.ts. An unregistered serializer name makes
// the worker answer without opening any database, so a reply at all proves the
// worker was embedded and started.
try {
  await runDbSerializer({
    serializer: "smoke-unregistered",
    dbPath: "unused",
    outDir: "unused",
    signal: AbortSignal.timeout(15_000),
  });
  console.error("expected the worker to refuse an unregistered serializer");
  process.exit(1);
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  if (!message.includes("No serializer named smoke-unregistered")) {
    console.error(`worker did not answer: ${message}`);
    process.exit(1);
  }
  console.log("db serializer worker ok");
}
