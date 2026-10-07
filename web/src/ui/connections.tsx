// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { Layout, type LayoutUser } from "./layout.js";
import type { ConnectionSummary } from "../relay/push.js";
import { fmtAge } from "./format.js";
import { Notice, RelayUnreachable } from "./notice.js";
import { OperatorNav } from "./operator-nav.js";
import { baseSlotDeviceId } from "antgrid-wire";

function RelativeTime({ timestamp, now }: { timestamp: number; now: number }) {
  const iso = new Date(timestamp).toISOString();
  return <time datetime={iso} title={iso} class="whitespace-nowrap font-mono tabular-nums">{fmtAge(timestamp, now)} ago</time>;
}

function Count({ label, value }: { label: string; value: number }) {
  return <div class="rounded-box border border-edge bg-panel p-5">
    <div class="text-xs font-medium text-muted2">{label}</div>
    <div class="mt-3 font-mono text-3xl leading-none tabular-nums">{value.toLocaleString("en-US")}</div>
  </div>;
}

export function ConnectionsPage(props: {
  user: LayoutUser;
  connections: ConnectionSummary[] | null;
  now: number;
}) {
  const { user, connections, now } = props;
  const devices = new Map(connections?.map((connection) => [baseSlotDeviceId(connection.deviceId), connection.deviceType]));
  return (
    <Layout title="Relay connections" user={user} analytics={false} contentWidth="wide">
      <OperatorNav section="connections" />
      <div class="mb-2 flex flex-wrap items-baseline justify-between gap-3">
        <h1 class="text-2xl font-semibold">Relay connections</h1>
        <span class={`rounded-full border px-3 py-1 text-sm ${connections === null ? "border-error/40 text-error" : "border-edge text-muted2"}`}>
          {connections === null ? "Relay unavailable" : "Snapshot available"}
        </span>
      </div>
      <p class="mb-6 text-sm leading-relaxed text-muted">Current relay presence. Devices can hold multiple connection slots; each slot appears below.</p>

      {connections !== null && <div class="mb-8 grid grid-cols-2 gap-3 sm:grid-cols-4">
        <Count label="Live connection slots" value={connections.length} />
        <Count label="Unique devices" value={devices.size} />
        <Count label="Machines" value={[...devices.values()].filter((type) => type === "agent").length} />
        <Count label="App devices" value={[...devices.values()].filter((type) => type === "app").length} />
      </div>}

      {connections === null ? (
        <RelayUnreachable />
      ) : connections.length === 0 ? (
        <Notice text="No live connections." />
      ) : (
        <section>
          <h2 class="mb-2 text-lg font-semibold">Live connection slots</h2>
          <p class="mb-4 text-sm text-muted">Times are relative to this snapshot. Hover over a time for its precise UTC timestamp.</p>
          <div class="overflow-x-auto card bg-panel border border-edge">
          <table class="operator-table">
            <thead>
              <tr class="text-muted2">
                <th>Device / connection slot</th>
                <th>Device class</th>
                <th class="text-right">Connected</th>
                <th class="text-right">Last relay observation</th>
              </tr>
            </thead>
            <tbody>
              {connections.map((c) => (
                <tr>
                  <td class="break-all font-mono">{c.deviceId}</td>
                  <td class="whitespace-nowrap">{c.deviceType === "agent" ? "Machine" : "App device"}</td>
                  <td class="text-right text-muted"><RelativeTime timestamp={c.connectedAt} now={now} /></td>
                  <td class="text-right text-muted"><RelativeTime timestamp={c.lastSeen} now={now} /></td>
                </tr>
              ))}
            </tbody>
          </table>
          </div>
        </section>
      )}
    </Layout>
  );
}
