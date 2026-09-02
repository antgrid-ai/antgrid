import { z } from "zod";

const Base64 = z.string().min(1).regex(/^[A-Za-z0-9+/=_-]+$/, "base64-ish");

const AuthFields = z.object({
  clientId: z.string().min(1),
  clientSecret: z.string().min(1),
  ed25519Pub: Base64,
  ed25519Priv: Base64,
  x25519Pub: Base64,
  x25519Priv: Base64,
  deviceUuid: z.string().regex(
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
    "UUID format",
  ),
});

const MachineBlock = z.object({
  relayUrl: z.string().min(1),
  licenseApiUrl: z.string().url(),
  auth: AuthFields,
});

const FirstProject = z.object({
  projectId: z.string().min(1),
  projectPath: z.string().min(1),
  mode: z.enum(["local", "remote"]),
});

export const BootstrapPayloadSchema = z
  .object({
    machine: MachineBlock.optional(),
    // Optional: an eager warm-up spawn (app launch) opens no project — the host
    // boots its control plane and waits for project:open RPCs. When present, the
    // host inlines it as the first core.
    firstProject: FirstProject.optional(),
    // Pid of the app process that spawned this host. The entrypoint starts an
    // owner-watchdog (owner-watchdog.ts) that self-exits the host when this pid
    // vanishes — the backstop for exits that skip the app's didRequestAppExit
    // teardown (force-kill, crash, window-close under `flutter run --machine`).
    // Optional: a host started outside the app (CLI/tests) has no owner.
    ownerPid: z.number().int().positive().optional(),
    // Build provenance of the spawning app, echoed verbatim into host.json so a
    // later app run can tell a host from its OWN install from one an update
    // replaced the app out from under. Opaque here — the host never interprets
    // it. Optional: a host started outside the app (CLI/tests) has no owner.
    ownerBuild: z.string().min(1).optional(),
    // The user's crash/telemetry consent, read by the app from its own settings
    // at the moment it spawned us — the SAME read that decides the app's own
    // Sentry init, so the two halves of one install can never disagree. Consent
    // is therefore fixed for the host's lifetime, exactly as it is for the app
    // process (`initCrashReporting` wraps `runApp` and is never re-run); a
    // toggle takes effect on the next spawn. Optional, and absence must resolve
    // to OFF: a host started outside the app has nobody to have consented.
    telemetryEnabled: z.boolean().optional(),
  })
  .refine((p) => p.firstProject === undefined || p.firstProject.mode !== "remote" || p.machine !== undefined, {
    message: "firstProject.mode 'remote' requires a machine block",
    path: ["machine"],
  });
export type BootstrapPayload = z.infer<typeof BootstrapPayloadSchema>;

export interface ReadBootstrapOptions {
  stdin?: NodeJS.ReadableStream;
  /** Max time to wait for stdin to close. Defaults to 10 seconds. */
  timeoutMs?: number;
  /** Sink for the human-launch notice (test seam). Defaults to stderr. */
  writeNotice?: (line: string) => void;
}

/**
 * Read exactly one JSON line from stdin, validate it as a BootstrapPayload, return it.
 * Held in memory by the caller; never written to disk.
 */
export async function readBootstrapPayload(
  opts: ReadBootstrapOptions = {},
): Promise<BootstrapPayload> {
  const stdin = opts.stdin ?? process.stdin;
  const timeoutMs = opts.timeoutMs ?? 10_000;

  // A human running the binary in a terminal gets a TTY on stdin; the desktop
  // app always spawns us with a pipe. Say what we're waiting for up front —
  // otherwise a direct launch sits silent for the whole timeout and looks hung.
  if ((stdin as NodeJS.ReadStream).isTTY) {
    const write = opts.writeNotice ?? ((line: string) => process.stderr.write(line + "\n"));
    write("antgrid-bridge is normally launched by the Antgrid desktop app, which supplies a bootstrap payload on stdin.");
    write(`Waiting up to ${Math.round(timeoutMs / 1000)}s for that payload, then exiting with an error. Press Ctrl+C to quit now; to use Antgrid, launch the desktop app.`);
  }

  const readAll = (async () => {
    const chunks: Buffer[] = [];
    for await (const c of stdin) {
      chunks.push(typeof c === "string" ? Buffer.from(c) : (c as Buffer));
    }
    return Buffer.concat(chunks).toString("utf8").trim();
  })();

  const raw = await Promise.race<string | null>([
    readAll,
    new Promise<null>((resolve) => setTimeout(() => resolve(null), timeoutMs)),
  ]);

  if (!raw) {
    throw new Error("bootstrap payload: no stdin data received within timeout");
  }

  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch (err) {
    throw new Error(`bootstrap payload: invalid JSON: ${(err as Error).message}`);
  }

  const parsed = BootstrapPayloadSchema.safeParse(json);
  if (!parsed.success) {
    const detail = parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ");
    throw new Error(`bootstrap payload: schema validation failed: ${detail}`);
  }
  return parsed.data;
}
