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
