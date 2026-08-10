import { Layout } from "./layout.js";
import { DownloadCard } from "./download-card.js";
import type { DeviceRow } from "../models/device.js";

export function DevicesPage(props: {
  user: { email?: string | null };
  devices: DeviceRow[];
}) {
  return (
    <Layout title="Devices" user={props.user}>
      <div class="mb-6">
        <h1 class="font-mono text-2xl font-semibold">Devices</h1>
        <p class="text-sm text-base-content/60 mt-1">
          Agents and apps signed into your account. A row is created when you
          sign in on a device and it provisions via{" "}
          <code class="px-1 bg-base-200 rounded">POST /account/devices</code>.
        </p>
      </div>
      <DevicesTable devices={props.devices} />
    </Layout>
  );
}

export function DevicesTable({ devices }: { devices: DeviceRow[] }) {
  if (devices.length === 0) {
    // There is no pairing ceremony — the bridge is a headless child of the
    // desktop app, so the empty state points at the install, not a CLI.
    return <DownloadCard />;
  }
  return (
    <div class="card bg-base-100 border border-base-300 overflow-x-auto">
      <table class="table">
        <thead>
          <tr class="text-xs uppercase tracking-wide text-base-content/60">
            <th>Name</th>
            <th>Kind</th>
            <th>Platform</th>
            <th>Last seen</th>
            <th></th>
          </tr>
        </thead>
        <tbody id="devices-tbody">
          {devices.map((d) => (
            <DeviceRowView device={d} />
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** Both agent (bridge) and app (phone) devices call `/account/devices/me/heartbeat`
 *  (routes/agents.ts), so `lastSeenAt` applies uniformly — "—" just means this
 *  device hasn't checked in yet. */
function lastSeenLabel(device: DeviceRow): string {
  if (!device.lastSeenAt) return "—";
  return new Date(device.lastSeenAt).toISOString().slice(0, 16).replace("T", " ");
}

export function DeviceRowView({ device }: { device: DeviceRow }) {
  return (
    <tr id={`device-${device.id}`} class="font-mono text-sm">
      <td>{device.displayName}</td>
      <td>
        <span class="badge badge-outline">{device.kind}</span>
      </td>
      <td>{device.platform}</td>
      <td class="text-base-content/60">{lastSeenLabel(device)}</td>
      <td class="text-right">
        <button
          class="btn btn-ghost btn-xs text-error"
          hx-delete={`/ui/devices/${device.id}`}
          hx-target={`#device-${device.id}`}
          hx-swap="outerHTML"
          hx-confirm={`Revoke "${device.displayName}"? The device will be signed out.`}
        >
          Revoke
        </button>
      </td>
    </tr>
  );
}
