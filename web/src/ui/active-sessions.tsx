import { runningSessionCount, type UserSession } from "../services/sessions.js";
import { fmtAge } from "./format.js";

// No tier branch: remote control is included on Free, so every tier sees its
// own running machines. What tier buys is how many workers may run at once,
// and that meter lives on the dashboard card.
export function ActiveSessionsCard(props: {
  sessions: UserSession[] | null;
  now: number;
}) {
  const { sessions, now } = props;

  return (
    <section class="mt-8">
      <div class="flex items-baseline gap-3 mb-3">
        <h2 class="text-lg font-semibold">Active sessions</h2>
        {/* No denominator: open streams are billed against nothing since the
            paid axis became the worker cap. This is liveness telemetry. */}
        {sessions ? (
          <span class="font-mono text-xs text-muted2">
            {runningSessionCount(sessions)} running
          </span>
        ) : null}
      </div>
      {sessions === null ? (
        <div class="card bg-panel border border-edge">
          <div class="card-body">
            <p class="text-sm text-muted">
              Couldn't reach the relay.
            </p>
          </div>
        </div>
      ) : sessions.length === 0 ? (
        <div class="card bg-panel border border-edge">
          <div class="card-body">
            <p class="text-sm text-muted">
              No agents running remotely.
            </p>
          </div>
        </div>
      ) : (
        <div class="card bg-panel border border-edge overflow-x-auto">
          <table class="table">
            <thead>
              <tr class="text-xs uppercase tracking-wide text-muted">
                <th>Device</th>
                <th>Sessions</th>
                <th>Connected</th>
              </tr>
            </thead>
            <tbody>
              {/* One row per machine, not per project: the relay multiplexes
                  projects as sealed streams and cannot name them. */}
              {sessions.map((s) => (
                <tr class="font-mono text-sm">
                  <td>{s.displayName}</td>
                  <td class={s.openStreamCount === 0 ? "text-muted" : ""}>
                    {s.openStreamCount === 0 ? "idle" : s.openStreamCount}
                  </td>
                  <td class="text-muted">{fmtAge(s.connectedAt, now)} ago</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
