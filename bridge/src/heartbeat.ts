import { SessionBusGrantsSchema, type SessionBusGrants, type SessionBusGrantsPatch } from "antgrid-wire";

export interface SendHeartbeatArgs {
  licenseApiUrl: string;
  getToken: () => string;
  deviceUuid: string;
  mobileAccessEnabled: boolean;
  relayUrl?: string | null;
  machineName?: string | null;
  fetchFn?: typeof fetch;
}

export async function sendHeartbeat(args: SendHeartbeatArgs): Promise<boolean> {
  const f = args.fetchFn ?? fetch;
  try {
    const res = await f(`${args.licenseApiUrl}/account/devices/me/heartbeat`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${args.getToken()}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        deviceUuid: args.deviceUuid,
        mobileAccessEnabled: args.mobileAccessEnabled,
        relayUrl: args.relayUrl ?? null,
        machineName: args.machineName ?? null,
      }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

export interface RegisterBusKeyArgs {
  licenseApiUrl: string;
  getToken: () => string | Promise<string>;
  busPublicKey: string;
  fetchFn?: typeof fetch;
}

/** Publishes this machine's bus public key so other machines on the account can
 *  find it in the directory. Separate from the heartbeat: the key changes only
 *  on re-provisioning, so it is sent on mismatch, not on a cadence. */
export async function registerBusKey(args: RegisterBusKeyArgs): Promise<boolean> {
  const f = args.fetchFn ?? fetch;
  try {
    const res = await f(`${args.licenseApiUrl}/account/devices/me/bus-key`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${await args.getToken()}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ busPublicKey: args.busPublicKey }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

export interface SessionBusGrantsArgs {
  licenseApiUrl: string;
  getToken: () => string | Promise<string>;
  fetchFn?: typeof fetch;
}

export type SessionBusGrantsResult =
  | { ok: true; grants: SessionBusGrants }
  | { ok: false; status: number | null };

async function sessionBusGrantsCall(
  args: SessionBusGrantsArgs,
  init: { method: "GET" } | { method: "POST"; body: string },
): Promise<SessionBusGrantsResult> {
  const f = args.fetchFn ?? fetch;
  try {
    const res = await f(`${args.licenseApiUrl}/account/devices/me/session-bus`, {
      ...init,
      headers: {
        authorization: `Bearer ${await args.getToken()}`,
        ...(init.method === "POST" ? { "content-type": "application/json" } : {}),
      },
    });
    if (!res.ok) return { ok: false, status: res.status };
    const parsed = SessionBusGrantsSchema.safeParse(await res.json());
    return parsed.success ? { ok: true, grants: parsed.data } : { ok: false, status: res.status };
  } catch {
    return { ok: false, status: null };
  }
}

/** This machine's own orchestrator and bus-control grants, as web holds them. */
export function getSessionBusGrants(args: SessionBusGrantsArgs): Promise<SessionBusGrantsResult> {
  return sessionBusGrantsCall(args, { method: "GET" });
}

/** Lowers grants. Only `false` is expressible: raising needs the owner's
 *  account session, which web enforces too, so a credential that lives on this
 *  machine cannot elevate it. */
export function lowerSessionBusGrants(
  args: SessionBusGrantsArgs & { patch: { [K in keyof SessionBusGrantsPatch]?: false } },
): Promise<SessionBusGrantsResult> {
  return sessionBusGrantsCall(args, { method: "POST", body: JSON.stringify(args.patch) });
}
