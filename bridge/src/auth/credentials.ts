import type { Readable } from "node:stream";
import { z } from "zod";

const Base64 = z.string().min(1).regex(/^[A-Za-z0-9+/=_-]+$/, "base64-ish");

const AuthFields = z.object({
  userId: z.string().min(1).optional(),
  endpointSecret: z.string().regex(/^[A-Za-z0-9+/]{43}=$/).optional(),
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
    // The spawner holds our stdin open for its life, so EOF means it is gone
    // (`watchOwnerStdin`, owner-watchdog.ts). Absence must mean "do not watch":
    // the CLI, evals and tests close stdin right after this line.
    ownerHoldsStdin: z.boolean().optional(),
  })
  .refine((p) => p.firstProject === undefined || p.firstProject.mode !== "remote" || p.machine !== undefined, {
    message: "firstProject.mode 'remote' requires a machine block",
    path: ["machine"],
  });
export type BootstrapPayload = z.infer<typeof BootstrapPayloadSchema>;

export interface ReadBootstrapOptions {
  stdin?: Readable;
  /** Max time to wait for the payload line. Defaults to 10 seconds. */
  timeoutMs?: number;
  /** Sink for the human-launch notice (test seam). Defaults to stderr. */
  writeNotice?: (line: string) => void;
}

/**
 * Read exactly one JSON line from stdin, validate it as a BootstrapPayload, return it.
 * Held in memory by the caller; never written to disk.
 *
 * Resolves at the first newline OR at EOF, whichever comes first, because an
 * `ownerHoldsStdin` spawner never closes the pipe. Listens for `data` rather
 * than using `for await`, whose early exit would destroy the stream that
 * `watchOwnerStdin` goes on to watch.
 */
export async function readBootstrapPayload(
  opts: ReadBootstrapOptions = {},
): Promise<BootstrapPayload> {
  const stdin: Readable = opts.stdin ?? process.stdin;
  const timeoutMs = opts.timeoutMs ?? 10_000;

  // A human running the binary in a terminal gets a TTY on stdin; the desktop
  // app always spawns us with a pipe. Say what we're waiting for up front —
  // otherwise a direct launch sits silent for the whole timeout and looks hung.
  if ((stdin as NodeJS.ReadStream).isTTY) {
    const write = opts.writeNotice ?? ((line: string) => process.stderr.write(line + "\n"));
    write("antgrid-bridge is normally launched by the Antgrid desktop app, which supplies a bootstrap payload on stdin.");
    write(`Waiting up to ${Math.round(timeoutMs / 1000)}s for that payload, then exiting with an error. Press Ctrl+C to quit now; to use Antgrid, launch the desktop app.`);
  }

  // stdin outlives this read: the owner may hold it open, or a TTY may stay
  // attached. With no listener left, a later read error (EIO on a detached
  // TTY) would surface as an uncaught exception and shut a live host down.
  stdin.on("error", () => {});

  const raw = await new Promise<string | null>((resolve) => {
    const chunks: Buffer[] = [];
    // Detaching everything is also what lets the chunks — secrets included —
    // be collected once the payload is parsed.
    const settle = (line: string | null) => {
      clearTimeout(timer);
      stdin.off("data", onData);
      stdin.off("end", onEnd);
      stdin.off("error", onEnd);
      resolve(line);
    };
    const onData = (c: string | Buffer) => {
      const buf = typeof c === "string" ? Buffer.from(c) : c;
      const nl = buf.indexOf(0x0a);
      if (nl < 0) {
        chunks.push(buf);
        return;
      }
      chunks.push(buf.subarray(0, nl));
      settle(Buffer.concat(chunks).toString("utf8").trim());
    };
    const onEnd = () => settle(Buffer.concat(chunks).toString("utf8").trim());
    const timer = setTimeout(() => settle(null), timeoutMs);
    stdin.on("data", onData);
    stdin.once("end", onEnd);
    stdin.once("error", onEnd);
  });

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
