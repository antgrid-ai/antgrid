import { Layout } from "./layout.js";
import { asset } from "./asset.js";
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
      {props.devices.length > 0 && <RevokeDeviceModal />}
      <script src={asset("devices")} defer />
    </Layout>
  );
}

/** One shared modal for every row — the row buttons carry the target in
 *  `data-revoke-*` and `entries/devices.ts` fills this in on open. Rendering a
 *  dialog per row would duplicate it once per device for no gain. */
function RevokeDeviceModal() {
  return (
    <div id="revoke-device-modal" class="modal" role="dialog" aria-modal="true">
      <div class="modal-box max-w-md">
        <h3 class="font-mono text-lg font-semibold">Revoke device?</h3>
        <p class="text-sm text-base-content/70 mt-2">
          <span id="revoke-device-name" class="font-mono">This device</span> will
          be signed out and loses access to every machine on your account. Signing
          in again on that device registers it anew.
        </p>
        {/* Two installs on the same machine share a display name (the row is
            keyed by deviceId, not by name), so the name alone cannot tell the
            user which one they are about to cut off. */}
        <p
          id="revoke-device-meta"
          class="font-mono text-xs text-base-content/50 mt-2"
        />
        <p
          id="revoke-device-error"
          class="alert alert-error font-mono text-xs mt-3 hidden"
          role="alert"
        />
        <div class="modal-action mt-4">
          <button type="button" class="btn btn-ghost font-mono" data-revoke-dismiss>
            Cancel
          </button>
          <button type="button" id="revoke-device-confirm" class="btn btn-error font-mono">
            Revoke
          </button>
        </div>
      </div>
      <button type="button" class="modal-backdrop" data-revoke-dismiss aria-label="Close" />
    </div>
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
          type="button"
          class="btn btn-ghost btn-xs text-error"
          data-revoke-url={`/ui/devices/${device.id}`}
          data-revoke-target={`#device-${device.id}`}
          data-revoke-name={device.displayName}
          data-revoke-meta={`${device.kind} · ${device.platform} · last seen ${lastSeenLabel(device)}`}
        >
          Revoke
        </button>
      </td>
    </tr>
  );
}
