import { Layout } from "./layout.js";
import type { ConnectionSummary } from "../relay/push.js";
import { fmtAge } from "./format.js";

export function ConnectionsPage(props: {
  user: { email: string | null };
  connections: ConnectionSummary[] | null;
  now: number;
}) {
  const { user, connections, now } = props;
  return (
    <Layout title="Relay connections" user={user}>
      <div class="flex items-baseline gap-3 mb-4">
        <h1 class="text-xl font-semibold">Relay connections</h1>
        {connections && (
          <span class="font-mono text-xs text-muted2">
            {connections.length} live
          </span>
        )}
      </div>

      {connections === null ? (
        <div class="card bg-panel border border-error/40">
          <div class="card-body">
            <p class="text-sm text-error">
              Could not reach the relay. Check RELAY_INTERNAL_URL / secret.
            </p>
          </div>
        </div>
      ) : connections.length === 0 ? (
        <div class="card bg-panel border border-edge">
          <div class="card-body">
            <p class="text-sm text-muted">No live connections.</p>
          </div>
        </div>
      ) : (
        <div class="overflow-x-auto card bg-panel border border-edge">
          <table class="table table-sm font-mono text-xs">
            <thead>
              <tr class="text-muted2">
                <th>Device ID</th>
                <th>Type</th>
                <th>Streams</th>
                <th>Connected</th>
                <th>Last seen</th>
              </tr>
            </thead>
            <tbody>
              {connections.map((c) => (
                <tr>
                  <td class="break-all">{c.deviceId}</td>
                  <td>{c.deviceType}</td>
                  {/* Apps cannot hold streams at all (the relay answers an app's
                      stream-open with WRONG_DEVICE_TYPE), so a zero there is
                      "not applicable", not "dropped". */}
                  <td class={c.openStreamCount === 0 ? "text-faint" : "text-success"}>
                    {c.deviceType === "app" ? "—" : c.openStreamCount}
                  </td>
                  <td class="text-muted">{fmtAge(c.connectedAt, now)} ago</td>
                  <td class="text-muted">{fmtAge(c.lastSeen, now)} ago</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Layout>
  );
}
