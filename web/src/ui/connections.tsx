import { Layout } from "./layout.js";
import type { ConnectionSummary } from "../relay/push.js";
import { fmtAge } from "./format.js";

function stateClass(state: ConnectionSummary["state"]): string {
  switch (state) {
    case "PAIRED":
      return "text-success";
    case "AUTHENTICATED":
      return "text-info";
    case "CHALLENGED":
      return "text-warning";
    default:
      return "text-base-content/40";
  }
}

export function ConnectionsPage(props: {
  user: { email: string | null };
  connections: ConnectionSummary[] | null;
  now: number;
}) {
  const { user, connections, now } = props;
  return (
    <Layout title="Relay connections" user={user}>
      <div class="flex items-baseline gap-3 mb-4">
        <h1 class="font-mono text-xl font-semibold">Relay connections</h1>
        {connections && (
          <span class="font-mono text-xs text-base-content/50">
            {connections.length} live
          </span>
        )}
      </div>

      {connections === null ? (
        <div class="card bg-base-100 border border-error/40">
          <div class="card-body">
            <p class="font-mono text-sm text-error">
              Could not reach the relay. Check RELAY_INTERNAL_URL / secret.
            </p>
          </div>
        </div>
      ) : connections.length === 0 ? (
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body">
            <p class="font-mono text-sm text-base-content/60">No live connections.</p>
          </div>
        </div>
      ) : (
        <div class="overflow-x-auto card bg-base-100 border border-base-300">
          <table class="table table-sm font-mono text-xs">
            <thead>
              <tr class="text-base-content/50">
                <th>Device ID</th>
                <th>Type</th>
                <th>State</th>
                <th>Connected</th>
                <th>Last seen</th>
                <th>Paired with</th>
                <th>Parent agent</th>
              </tr>
            </thead>
            <tbody>
              {connections.map((c) => (
                <tr>
                  <td class="break-all">{c.deviceId}</td>
                  <td>{c.deviceType}</td>
                  <td class={stateClass(c.state)}>{c.state}</td>
                  <td class="text-base-content/60">{fmtAge(c.connectedAt, now)} ago</td>
                  <td class="text-base-content/60">{fmtAge(c.lastSeen, now)} ago</td>
                  <td class="break-all text-base-content/60">{c.pairedWith ?? "—"}</td>
                  <td class="break-all text-base-content/60">{c.parentAgentDeviceId ?? "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Layout>
  );
}
