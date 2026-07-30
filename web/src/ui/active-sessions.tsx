import { runningSessionCount, type UserSession } from "../services/sessions.js";
import { fmtAge } from "./format.js";
import { FREE_TIER } from "../billing/plans.js";

export function ActiveSessionsCard(props: {
  tier: string;
  sessions: UserSession[] | null;
  sessionLimit: number;
  now: number;
}) {
  const { tier, sessions, sessionLimit, now } = props;

  if (tier === FREE_TIER) {
    return (
      <section class="mt-8">
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body flex-row items-center justify-between gap-6 flex-wrap">
            <div class="flex-1 min-w-0">
              <h2 class="font-mono text-lg font-semibold">Active sessions</h2>
              <p class="text-sm text-base-content/70 mt-1 max-w-md">
                Run agents remotely — upgrade to Pro to monitor and control your
                machines from anywhere.
              </p>
            </div>
            <a class="btn btn-primary" href="/pricing">
              Upgrade to Pro
            </a>
          </div>
        </div>
      </section>
    );
  }

  return (
    <section class="mt-8">
      <div class="flex items-baseline gap-3 mb-3">
        <h2 class="font-mono text-lg font-semibold">Active sessions</h2>
        {sessions ? (
          <span class="font-mono text-xs text-base-content/50">
            {runningSessionCount(sessions)} / {sessionLimit} running
          </span>
        ) : null}
      </div>
      {sessions === null ? (
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body">
            <p class="font-mono text-sm text-base-content/60">
              Couldn't reach the relay.
            </p>
          </div>
        </div>
      ) : sessions.length === 0 ? (
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body">
            <p class="font-mono text-sm text-base-content/60">
              No agents running remotely.
            </p>
          </div>
        </div>
      ) : (
        <div class="card bg-base-100 border border-base-300 overflow-x-auto">
          <table class="table">
            <thead>
              <tr class="text-xs uppercase tracking-wide text-base-content/60">
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
                  <td class={s.openStreamCount === 0 ? "text-base-content/60" : ""}>
                    {s.openStreamCount === 0 ? "idle" : s.openStreamCount}
                  </td>
                  <td class="text-base-content/60">{fmtAge(s.connectedAt, now)} ago</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
