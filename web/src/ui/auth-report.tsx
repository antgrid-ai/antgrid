// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { Layout, type LayoutUser } from "./layout.js";
import { OperatorNav } from "./operator-nav.js";
import type { AuthReportFilter, loadAuthReport } from "../models/auth-report.js";
import { OriginSchema } from "../auth/contracts.js";

function funnel(row: Awaited<ReturnType<typeof loadAuthReport>>["rows"][number]) {
  const origin = OriginSchema.parse(JSON.parse(row.origin));
  const stages = [`Accepted ${row.accepted}`];
  const mail = [`Queued ${row.queued}`, `Mail accepted ${row.mailAccepted}`, `Approval ${row.approved}`];
  if (origin.method === "magic_link") {
    stages.push(...mail);
    if (row.category === "signup") stages.push(`Created ${row.created}`);
  } else if (origin.method === "password" && row.category === "signup") {
    stages.push(`Created ${row.created}`, ...mail);
  } else if (["reset", "verification"].includes(origin.method)) {
    stages.push(...mail);
  } else if (row.category === "signup") {
    stages.push(`Created ${row.created}`);
  }
  stages.push(`Verified ${row.verified}`, `Session ${row.sessions}`, `Client use ${row.completed}`);
  return stages.join(" -> ");
}

export function AuthReportPage({ user, filter, data }: { user: LayoutUser; filter: AuthReportFilter; data: Awaited<ReturnType<typeof loadAuthReport>> }) {
  return <Layout title="Authentication funnels" user={user} analytics={false} contentWidth="wide"><OperatorNav section="auth" />
    <h1 class="text-2xl font-semibold">Authentication funnels</h1>
    <p class="text-sm text-muted">Server-confirmed requests. Completion means first authenticated client use within 24 hours. Screen views and email previews are excluded.</p>
    <p class="mt-4">Verified users: {data.verifiedUsers} · Pending registrations: {data.pendingUsers} · Stale unverified: {data.staleUsers} · Unknown registration origin: {data.unknownUsers}</p>
    <div class="my-4 text-sm"><h2>Email execution {data.sendingPaused ? "(paused: configuration requires attention)" : ""}</h2>{data.queue.map((queue) => <p>{queue.state}: {queue._count}; oldest {queue._min.createdAt?.toISOString()}; earliest expiry {queue._min.expiresAt?.toISOString()}</p>)}
      {data.recipientOutcomes.map((event) => <p>{event.kind}: {event._count}</p>)}</div>
    <form method="get" class="my-6 flex flex-wrap gap-3">{Object.entries(filter).map(([name, value]) => <label class="text-sm">{name}<input class="input input-bordered block" name={name} value={value} type={name === "from" || name === "to" ? "date" : "text"} /></label>)}<button class="btn" type="submit">Filter</button></form>
    <div class="overflow-x-auto"><table class="operator-table"><thead><tr>{["Origin", "Journey", "Stage order", "Accepted", "Created", "Mail queued", "Mail accepted", "Approval", "Verified", "Session", "Complete / conversion", "Pending", "Stalled", "Later recovered", "Bounced", "Failed", "Mean completion"].map((label) => <th>{label}</th>)}</tr></thead>
      <tbody>{data.rows.map((row) => <tr><td>{row.origin}</td><td>{row.category}</td><td class="text-xs">{funnel(row)}</td><td>{row.accepted}</td><td>{row.created}</td><td>{row.queued}</td><td>{row.mailAccepted}</td><td>{row.approved}</td><td>{row.verified}</td><td>{row.sessions}</td><td>{row.completed} / {Math.round(row.completed / row.accepted * 100)}%</td><td>{row.pending}</td><td>{row.stalled}</td><td>{row.recovered}</td><td>{row.bounced}</td><td>{row.failures} {Object.entries(row.failureCategories).map(([kind,count]) => `${kind}: ${count}`).join(", ")}</td><td>{row.seconds == null ? "—" : `${Math.round(row.seconds)}s`}</td></tr>)}</tbody></table></div>
  </Layout>;
}
