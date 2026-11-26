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
