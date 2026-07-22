import { Layout } from "./layout.js";
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
    return (
      <div class="card bg-base-100 border border-base-300 border-dashed">
        <div class="card-body items-center text-center py-10">
          <div class="font-mono text-sm text-base-content/60">No devices yet</div>
          <p class="text-xs text-base-content/50 max-w-sm">
            Sign in on the Antgrid app or run{" "}
            <code class="px-1 bg-base-200 rounded">antgrid pair</code> on your
            machine. The device row appears after sign-in provisioning completes.
          </p>
        </div>
      </div>
    );
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

/** `lastSeenAt` is written only by the agent heartbeat (routes/agents.ts), so an
 *  app row is null forever. Rendering both as "—" conflates "has never checked
 *  in" (actionable — the agent isn't reaching the account service) with "cannot
 *  ever check in" (by design). */
function lastSeenLabel(device: DeviceRow): string {
  if (device.kind === "app") return "n/a";
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
