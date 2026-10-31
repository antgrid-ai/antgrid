// `antgrid agent-reach` and the shared plumbing for `antgrid orchestrator`: both
// talk to the RUNNING host over the loopback control plane (host.json's port +
// bearer), because the grants live on the account, not in a file this process
// could edit.
//
// Nothing here can raise a grant. A credential that lives on this machine must
// not be able to elevate this machine, so raising is done by the owner in the
// app; the CLI only reads and lowers.

import { readHostFile, hostFilePath } from "../host-discovery";
import { postControl } from "./watch-transport";
import type { ControlHost } from "./watch-transport";

export interface GrantsReply {
  grants: { orchestrator: boolean; busControl: boolean };
  reachEnabled: boolean;
  level: string;
}

export interface ReachCliOptions {
  /** ANTGRID_DIR override — a debug-build app runs under ~/.antgrid-dev. */
  dir?: string;
}

export const RAISE_IN_APP =
  "Raising this is done in the Antgrid app's settings for this machine, signed in as the account owner.";

/** Resolves the running host, or prints why there is none. */
export function resolveHost(cmd: string, dir?: string): ControlHost | null {
  if (dir) process.env.ANTGRID_DIR = dir;
  const path = hostFilePath();
  const host = readHostFile(path);
  if (!host) {
    console.error(`antgrid ${cmd}: no running host found (looked in ${path}).`);
    console.error("The host must be running: start the app or the bridge first. A debug-build");
    console.error("app runs under ~/.antgrid-dev — point at it with --dir or ANTGRID_DIR.");
    return null;
  }
  return host;
}

// postControl flattens a refused verb and an unreachable host into one string;
// only the latter deserves the "is it running" hint.
const CONNECTION_ERROR = /unable to connect|econnrefused|connection|fetch failed|socket|network/i;

export function failure(cmd: string, error: string): void {
  console.error(`antgrid ${cmd}: ${error}`);
  if (CONNECTION_ERROR.test(error)) console.error("The host must be running.");
}

export function parseGrants(reply: Record<string, unknown> | undefined): GrantsReply | null {
  const grants = reply?.grants as Record<string, unknown> | undefined;
  if (
    !grants ||
    typeof grants.orchestrator !== "boolean" ||
    typeof grants.busControl !== "boolean" ||
    typeof reply?.reachEnabled !== "boolean" ||
    typeof reply?.level !== "string"
  ) {
    return null;
  }
  return {
    grants: { orchestrator: grants.orchestrator, busControl: grants.busControl },
    reachEnabled: reply.reachEnabled,
    level: reply.level,
  };
}

export async function printStatus(cmd: string, host: ControlHost): Promise<number> {
  const { error, reply } = await postControl(host, { type: "bus-grants:get" }, cmd);
  if (error) {
    failure(cmd, error);
    return 1;
  }
  const status = parseGrants(reply);
  if (!status) {
    console.error(`antgrid ${cmd}: the host answered with an unexpected shape.`);
    return 1;
  }
  console.log(`effective reach: ${status.level}`);
  console.log(`orchestrator: ${status.grants.orchestrator ? "on" : "off"}`);
  console.log(`bus control: ${status.grants.busControl ? "on" : "off"}`);
  // The grants are the account's word now; the level is what this machine
  // enforces, which follows its directory and lags a change by one refresh.
  if ((status.reachEnabled && status.grants.busControl) !== (status.level === "control")) {
    console.log("(this machine applies the account's change at its next directory refresh)");
  }
  return 0;
}

export async function lowerGrants(
  cmd: string,
  host: ControlHost,
  body: { orchestrator?: false; busControl?: false },
): Promise<string | null> {
  const { error } = await postControl(host, { type: "bus-grants:lower", ...body }, cmd);
  return error;
}

export async function runAgentReachCli(action: string | undefined, opts: ReachCliOptions = {}): Promise<number> {
  const verb = action ?? "status";
  if (verb === "control") {
    console.error(`antgrid agent-reach: ${RAISE_IN_APP}`);
    return 1;
  }
  if (verb !== "off" && verb !== "messages" && verb !== "status") {
    console.error(`antgrid agent-reach: unknown action "${verb}"; use off, messages or status.`);
    return 1;
  }
  const host = resolveHost("agent-reach", opts.dir);
  if (!host) return 1;
  if (verb === "status") return printStatus("agent-reach", host);

  const enabled = verb === "messages";
  const set = await postControl(host, { type: "agent-reach:set", enabled }, "agent-reach");
  if (set.error) {
    failure("agent-reach", set.error);
    return 1;
  }
  const lowerError = await lowerGrants("agent-reach", host, { busControl: false });
  if (lowerError) {
    if (!enabled) {
      // Off is decided locally and wins over any account grant, so the machine
      // is already closed; the account flag just stays where it was.
      console.log("agent reach is off.");
      console.error(
        `antgrid agent-reach: could not lower bus control on the account (${lowerError}); local off already wins.`,
      );
      return 0;
    }
    failure("agent-reach", `reach is on, but lowering bus control failed: ${lowerError}`);
    return 1;
  }
  console.log(enabled ? "agent reach: messages only." : "agent reach is off.");
  return 0;
}
