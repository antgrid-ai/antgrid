import { Layout, PageHead } from "./layout.js";
import { asset } from "./asset.js";
import { DownloadCard } from "./download-card.js";
import type { DeviceRow } from "../models/device.js";

export function DevicesPage(props: {
  user: { email?: string | null };
  devices: DeviceRow[];
}) {
  return (
    <Layout title="Devices" user={props.user} section="devices">
      {/* Named for what the reader controls. The endpoint that creates the row
          was the old subtitle, and nobody signing in on a phone is looking for
          it — what they need to know is that a device lands here by itself and
          that revoking is how it leaves. */}
      <PageHead title="Devices">
        Every machine and phone signed in to your account. Each one appears
        here on its own the first time it connects; revoke a device to cut it
        off.
      </PageHead>
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
        <h3 class="text-lg font-semibold">Revoke device?</h3>
        <p class="text-sm text-muted mt-2">
          <span id="revoke-device-name" class="font-mono">This device</span> will
          be signed out and loses access to every machine on your account. Signing
          in again on that device registers it anew.
        </p>
        {/* Two installs on the same machine share a display name (the row is
            keyed by deviceId, not by name), so the name alone cannot tell the
            user which one they are about to cut off. */}
        <p
          id="revoke-device-meta"
          class="font-mono text-xs text-muted2 mt-2"
        />
        <p
          id="revoke-device-error"
          class="alert alert-error text-xs mt-3 hidden"
          role="alert"
        />
        <div class="modal-action mt-4">
          <button type="button" class="btn btn-ghost" data-revoke-dismiss>
            Cancel
          </button>
          <button type="button" id="revoke-device-confirm" class="btn btn-error">
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
    <div class="card bg-panel border border-edge overflow-x-auto">
      <table class="table">
        <thead>
          <tr class="text-xs uppercase tracking-wide text-muted">
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
        {/* The one distinction in this table that costs money: an `agent` row is
            a machine counted against the plan's worker limit, an `app` row is
            not. Tinted accordingly rather than left as one uniform outline. */}
        <span
          class={
            device.kind === "agent"
              ? "badge badge-sm border-signal/50 bg-signaldeep/40 text-signal2"
              : "badge badge-sm border-edge text-muted"
          }
        >
          {device.kind}
        </span>
      </td>
      <td>{device.platform}</td>
      <td class="text-muted">{lastSeenLabel(device)}</td>
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
