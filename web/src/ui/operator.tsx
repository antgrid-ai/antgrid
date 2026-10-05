// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import type { Child } from "hono/jsx";
import { baseSlotDeviceId } from "antgrid-wire";
import { Layout, type LayoutUser } from "./layout.js";
import { OperatorNav } from "./operator-nav.js";
import { Notice } from "./notice.js";
import { CellMeter } from "./cell-meter.js";
import type { ConnectionSummary } from "../relay/push.js";
import { isMobilePlatform } from "../models/device.js";
import type {
  UsersQuery, AccountsQuery, OperatorUserRow, OperatorAccountRow,
  OperatorUserDetail, OperatorAccountDetail, OperatorSubscription, OperatorDevice,
} from "../models/operator.js";

const ACTIVITY_NOTE = "Last observed activity is the latest retained device heartbeat or sign-in session update. Session observations can lag by a day or longer. Unknown means no retained observation. All timestamps are UTC.";
const HISTORY_NOTE = "Only retained records are shown. Repeated joins and billing updates can overwrite earlier states.";

function Timestamp({ value }: { value: Date | string | null | undefined }) {
  const iso = typeof value === "string" ? value : value?.toISOString();
  return iso ? <time datetime={iso} class="font-mono text-xs whitespace-nowrap">{iso}</time> : <span class="text-muted">Unknown</span>;
}

function Section({ title, note, children }: { title: string; note?: string; children: Child }) {
  return <section class="mt-8"><h2 class="mb-2 text-sm font-semibold">{title}</h2>
    {note && <p class="mb-3 text-xs leading-relaxed text-muted">{note}</p>}{children}</section>;
}

function Table({ headers, rows, empty }: { headers: string[]; rows: Child[][]; empty: string }) {
  if (!rows.length) return <Notice text={empty} />;
  return <div class="overflow-x-auto card bg-panel border border-edge"><table class="table table-sm text-xs">
    <thead><tr class="text-muted2">{headers.map((header) => <th class="whitespace-nowrap">{header}</th>)}</tr></thead>
    <tbody>{rows.map((row) => <tr>{row.map((cell) => <td class="align-top">{cell}</td>)}</tr>)}</tbody>
  </table></div>;
}

function UserLink({ user }: { user: { id: string; name: string; email: string } }) {
  return <a href={`/internal/users/${encodeURIComponent(user.id)}`} class="link"><span class="block font-medium">{user.name || user.email}</span><span class="font-mono text-xs text-muted">{user.email}</span></a>;
}

function AccountLink({ id }: { id: string | null | undefined }) {
  return id ? <a href={`/internal/accounts/${encodeURIComponent(id)}`} class="link font-mono text-xs break-all">{id}</a> : <span class="text-muted">None</span>;
}

function Plan({ subscription }: { subscription: OperatorSubscription | null }) {
  return subscription ? <div><span class="font-medium">{subscription.plan.label}</span><span class="block text-muted">{subscription.tier} · {subscription.status}</span></div> : <span class="text-muted">No active subscription</span>;
}

function Source({ subscription }: { subscription: OperatorSubscription | null }) {
  if (!subscription) return <span class="text-muted">None</span>;
  const trial = subscription.plan.trial || subscription.tier === "trial" || subscription.trialStartedAt !== null || subscription.trialEndsAt !== null;
  return <span>{subscription.provider ?? "No provider"}{subscription.promotional ? " · Promotional" : ""}{trial ? " · Trial" : ""}</span>;
}

function Credentials({ credentials }: { credentials: OperatorUserRow["credentials"] }) {
  const providers = [...new Set(credentials.filter((c) => c.providerId !== "credential").map((c) => c.providerId))];
  const password = credentials.some((c) => c.providerId === "credential");
  return <div class="space-y-1"><div>OAuth: {providers.length ? providers.join(", ") : "None linked"}</div>
    <div>Password: {password ? "Credential linked" : "None linked"}</div><div class="text-muted">Email link available</div></div>;
}

function Deleted({ deletedAt }: { deletedAt: Date | null }) {
  return deletedAt ? <span class="text-amber">Retained deleted record · <Timestamp value={deletedAt} /></span> : <span>Not deleted</span>;
}

function pageHref(path: string, query: UsersQuery | AccountsQuery, page: number) {
  const params = new URLSearchParams({ page: String(page) });
  if (query.search) params.set("search", query.search);
  if (query.includeDeleted) params.set("includeDeleted", "true");
  if ("sort" in query) params.set("sort", query.sort);
  if ("teamsOnly" in query && query.teamsOnly) params.set("teamsOnly", "true");
  if ("paidOnly" in query && query.paidOnly) params.set("paidOnly", "true");
  return `${path}?${params}`;
}

function Pagination({ path, query, total }: { path: string; query: UsersQuery | AccountsQuery; total: number }) {
  return <nav aria-label="Pagination" class="mt-4 flex items-center justify-between gap-4 text-xs">
    <span class="text-muted">Page {query.page} · {total.toLocaleString("en-US")} records · 50 per page</span>
    <div class="flex gap-4">{query.page > 1 && <a class="link" href={pageHref(path, query, query.page - 1)}>Previous</a>}
      {query.page * 50 < total && <a class="link" href={pageHref(path, query, query.page + 1)}>Next</a>}</div>
  </nav>;
}

function Filters({ query, accounts = false }: { query: UsersQuery | AccountsQuery; accounts?: boolean }) {
  return <form action={accounts ? "/internal/accounts" : "/internal/users"} method="get" class="mb-4 flex flex-wrap items-end gap-4">
    <label class="flex flex-col gap-1 text-xs text-muted">Search name or email
      <input class="input input-sm input-bordered bg-panel text-ink" type="search" name="search" value={query.search} placeholder="Name or email" />
    </label>
    {"sort" in query && <label class="flex flex-col gap-1 text-xs text-muted">Sort
      <select class="select select-sm select-bordered bg-panel text-ink" name="sort"><option value="newest" selected={query.sort === "newest"}>Newest signup</option><option value="activity" selected={query.sort === "activity"}>Latest observed activity</option></select>
    </label>}
    <label class="flex items-center gap-2 text-xs"><input class="checkbox checkbox-sm" type="checkbox" name="includeDeleted" value="true" checked={query.includeDeleted} />Include deleted</label>
    {"teamsOnly" in query && <label class="flex items-center gap-2 text-xs"><input class="checkbox checkbox-sm" type="checkbox" name="teamsOnly" value="true" checked={query.teamsOnly} />Teams only</label>}
    {"paidOnly" in query && <label class="flex items-center gap-2 text-xs"><input class="checkbox checkbox-sm" type="checkbox" name="paidOnly" value="true" checked={query.paidOnly} />Paid only</label>}
    <button class="btn btn-sm" type="submit">Apply filters</button>
  </form>;
}

export function OperatorUsersPage({ user, data, query }: {
  user: LayoutUser; data: { rows: OperatorUserRow[]; total: number }; query: UsersQuery;
}) {
  return <Layout title="Operator users" user={user} analytics={false}><OperatorNav section="users" />
    <h1 class="mb-4 text-xl font-semibold">Users</h1><Filters query={query} />
    <p class="mb-4 text-xs text-muted">{ACTIVITY_NOTE} Active sign-in sessions are unexpired Better-Auth sessions. Active devices are unrevoked registrations.</p>
    <Table headers={["Identity", "Signup", "Sign-in methods", "Effective plan / billing account", "Machines", "Phones", "Desktop controllers", "Active sign-in sessions", "Last observed activity", "Flags"]}
      rows={data.rows.map((row) => [<UserLink user={row} />, <Timestamp value={row.createdAt} />, <Credentials credentials={row.credentials} />,
        <div><Plan subscription={row.subscription} /><div class="mt-1"><AccountLink id={row.billingAccountId} /></div></div>, row.machines, row.phones, row.desktopControllers, row.activeSessions,
        <Timestamp value={row.lastObservedActivityIso} />, <div>{row.emailVerified ? "Email verified" : "Email unverified"}<br /><Deleted deletedAt={row.deletedAt} /></div>])}
      empty="No users match these filters on this page." />
    <Pagination path="/internal/users" query={query} total={data.total} />
  </Layout>;
}

export function OperatorAccountsPage({ user, data, query }: {
  user: LayoutUser; data: { rows: OperatorAccountRow[]; total: number }; query: AccountsQuery;
}) {
  return <Layout title="Operator accounts" user={user} analytics={false}><OperatorNav section="accounts" />
    <h1 class="mb-4 text-xl font-semibold">Accounts</h1><Filters query={query} accounts />
    <p class="mb-4 text-xs leading-relaxed text-muted">Newest creation first. Teams have more than one purchased seat on their effective active subscription. Paid excludes free, trial, promotional and dev grants; provider must be Paddle, Razorpay or manual. Device totals are informational; worker and app-device limits apply per user. Activity totals include only users currently billing against each account.</p>
    <p class="mb-4 text-xs text-muted">{ACTIVITY_NOTE}</p>
    <Table headers={["Account / owner", "Plan / status", "Source", "Occupied / purchased seats", "Outstanding invites", "Active machines", "Worker limit per user", "Active sign-in sessions", "Last observed activity", "Country", "Billing provider", "Created", "Deletion"]}
      rows={data.rows.map((row) => [<div><AccountLink id={row.id} /><UserLink user={row.owner} /></div>, <Plan subscription={row.subscription} />, <Source subscription={row.subscription} />,
        `${row.occupiedSeats} / ${row.subscription?.seats ?? "Unknown"}`, row.pendingInvites, row.machines, row.subscription?.workerLimit ?? "No active subscription", row.activeSessions,
        <Timestamp value={row.lastObservedActivityIso} />, row.country ?? "Unknown", row.billingProvider ?? "None", <Timestamp value={row.createdAt} />, <Deleted deletedAt={row.deletedAt} />])}
      empty="No accounts match these filters on this page." />
    <Pagination path="/internal/accounts" query={query} total={data.total} />
  </Layout>;
}

function Usage({ data }: { data: OperatorUserRow }) {
  return data.subscription ? <div class="grid gap-6 sm:grid-cols-2"><CellMeter label="Active machines · per user" used={data.machines} limit={data.subscription.workerLimit} unit="machines" />
    <CellMeter label="Active app devices · per user" used={data.phones + data.desktopControllers} limit={data.subscription.appDeviceLimit} unit="app devices" /></div> : <Notice text="No active subscription. No entitlement limits are available." />;
}

function DeviceTable({ devices, connections }: { devices: OperatorDevice[]; connections?: ConnectionSummary[] | null }) {
  return <Table headers={["Device", "Class", "Platform", "Registered", "Last heartbeat", "Revoked", "Phone access · machine setting", ...(connections !== undefined ? ["Relay"] : [])]}
    rows={devices.map((device) => [<div class="min-w-32"><div>{device.displayName}</div><div class="font-mono text-muted break-all">{device.deviceId}</div>{device.machineName && <div>{device.machineName}</div>}</div>,
      device.kind === "agent" ? "Machine" : isMobilePlatform(device.platform) ? "Phone" : "Desktop controller", device.platform,
      <Timestamp value={device.activatedAt} />, <Timestamp value={device.lastSeenAt} />, device.revokedAt ? <Timestamp value={device.revokedAt} /> : "Active",
      device.kind === "agent" ? device.mobileAccessEnabled ? "Enabled" : "Disabled" : "—",
      ...(connections !== undefined ? [connections === null ? "Unavailable" : connections.some((c) => baseSlotDeviceId(c.deviceId) === device.deviceId && c.deviceType === device.kind) ? "Connected to relay" : "No relay connections"] : [])])} empty="No retained devices." />;
}

function connectedDevices(connections: ConnectionSummary[]) {
  const devices = new Map<string, ConnectionSummary>();
  for (const connection of connections) {
    const deviceId = baseSlotDeviceId(connection.deviceId);
    const key = `${connection.deviceType}:${deviceId}`;
    const previous = devices.get(key);
    devices.set(key, { ...connection, deviceId,
      connectedAt: Math.min(previous?.connectedAt ?? connection.connectedAt, connection.connectedAt),
      lastSeen: Math.max(previous?.lastSeen ?? connection.lastSeen, connection.lastSeen),
    });
  }
  return [...devices.values()];
}

export function OperatorUserPage({ user, data, connections, now = new Date() }: {
  user: LayoutUser; data: OperatorUserDetail; connections: ConnectionSummary[] | null; now?: Date;
}) {
  const slots = connections === null ? null : connectedDevices(connections);
  return <Layout title={`User · ${data.email}`} user={user} analytics={false}><OperatorNav section="users" />
    <a class="link text-xs" href="/internal/users">All users</a><h1 class="mt-2 text-xl font-semibold">{data.name || data.email}</h1>
    <p class="font-mono text-sm text-muted">{data.email}</p>
    <Section title="Identity"><Table headers={["User ID", "Signup", "Verification", "Deletion"]} rows={[[data.id, <Timestamp value={data.createdAt} />, data.emailVerified ? "Email verified" : "Email unverified", <Deleted deletedAt={data.deletedAt} />]]} empty="" /></Section>
    <Section title="Accounts"><Table headers={["Relationship", "Account", "Owner"]}
      rows={[["Owned personal account", <AccountLink id={data.ownedAccount?.id} />, data.ownedAccount ? <UserLink user={data.ownedAccount.user} /> : "None"], ["Current billing account", <AccountLink id={data.billingAccount?.id} />, data.billingAccount ? <UserLink user={data.billingAccount.user} /> : "None"]]} empty="" /></Section>
    <Section title="Entitlement limits" note="Limits are the effective subscription snapshot and apply per user. Seats are account-wide."><Plan subscription={data.subscription} />
      {data.subscription && <p class="mt-2 text-xs"><Source subscription={data.subscription} /> · Purchased account seats: {data.subscription.seats}</p>}<div class="mt-4"><Usage data={data} /></div></Section>
    <Section title="Retained memberships" note={HISTORY_NOTE}><Table headers={["Account", "Owner", "Role", "Status", "Joined", "Ended"]}
      rows={data.memberships.map((m) => [<AccountLink id={m.accountId} />, <UserLink user={m.account.user} />, m.role, m.status, <Timestamp value={m.joinedAt} />, m.endedAt ? <Timestamp value={m.endedAt} /> : "—"])} empty="No retained memberships." /></Section>
    <Section title="Retained devices" note="Revoked rows are included. Phone access is a setting on each machine, not a phone permission."><DeviceTable devices={data.devices} connections={connections} /></Section>
    <Section title="Sign-in sessions and observed activity" note={ACTIVITY_NOTE}><p class="mb-3 text-sm">Active sign-in sessions: <span class="font-mono">{data.activeSessions}</span> · Last observed activity: <Timestamp value={data.lastObservedActivityIso} /></p>
      <Table headers={["Session ID", "Created", "Last session update", "Expires", "Status"]} rows={data.sessions.map((s) => [s.id, <Timestamp value={s.createdAt} />, <Timestamp value={s.updatedAt} />, <Timestamp value={s.expiresAt} />, s.expiresAt.getTime() > now.getTime() ? "Active" : "Expired"])} empty="No retained sign-in sessions." /></Section>
    <Section title="Relay connections"><p class="mb-3 text-sm">{slots === null ? "Unavailable" : slots.length ? "Connected to relay" : "No relay connections"}</p>
      {slots && slots.length > 0 && <><p class="mb-3 text-xs text-muted">{slots.length} unique connected devices · {slots.filter((c) => c.deviceType === "agent").length} machines · {slots.filter((c) => c.deviceType === "app").length} app devices. Duplicate connection slots count once.</p><Table headers={["Device ID", "Type", "Connected", "Last relay observation"]} rows={slots.map((c) => [c.deviceId, c.deviceType, <Timestamp value={new Date(c.connectedAt)} />, <Timestamp value={new Date(c.lastSeen)} />])} empty="No relay connections" /></>}
    </Section>
    <Section title="Linked sign-in credentials" note="Provider rows describe linked credentials. Email-link sign-in is available independently of linked OAuth or password credentials."><Credentials credentials={data.credentials} />
      <div class="mt-3"><Table headers={["Credential ID", "Method", "Linked", "Updated"]} rows={data.credentials.map((c) => [c.id, c.providerId === "credential" ? "Password" : `OAuth · ${c.providerId}`, <Timestamp value={c.createdAt} />, <Timestamp value={c.updatedAt} />])} empty="No linked OAuth or password credentials. Email-link sign-in remains available." /></div></Section>
    <Section title="Pending unexpired invitations matching email"><InviteTable invites={data.invites} now={now} /></Section>
    <Section title="Waitlist">{data.waitlist ? <Table headers={["Email", "Source", "Joined"]} rows={[[data.waitlist.email, data.waitlist.source, <Timestamp value={data.waitlist.createdAt} />]]} empty="" /> : <Notice text="No waitlist entry." />}</Section>
  </Layout>;
}

function InviteTable({ invites, now }: { invites: OperatorAccountDetail["invites"]; now: Date }) {
  return <Table headers={["Account", "Email", "Role", "Status", "Delivery / bounce", "Created", "Expires", "Resolved"]}
    rows={invites.map((i) => [<AccountLink id={i.accountId} />, i.email, i.role, i.status === "pending" && i.expiresAt <= now ? "Expired (retained pending record)" : i.status,
      i.deliveryStatus ?? "No bounce reported", <Timestamp value={i.createdAt} />, <Timestamp value={i.expiresAt} />, i.resolvedAt ? <Timestamp value={i.resolvedAt} /> : "—"])} empty="No retained invitations." />;
}

function Members({ members, former = false }: { members: OperatorAccountDetail["members"]; former?: boolean }) {
  if (!members.length) return <Notice text={former ? "No retained former members." : "No users currently billing against this account."} />;
  return <div class="space-y-4">{members.map((member) => <div class="rounded-box border border-edge bg-panel p-4">
    <div class="flex flex-wrap items-start justify-between gap-3"><UserLink user={member.user} /><span class="text-xs text-muted">{member.role} · {member.status}</span></div>
    <p class="mt-2 text-xs text-muted">{member.retainedMembership ? <>Joined <Timestamp value={member.joinedAt} />{member.endedAt && <> · Ended <Timestamp value={member.endedAt} /></>}</> : "No retained membership; bills through account ownership"} · Current billing account: <AccountLink id={member.user.billingAccountId} /></p>
    <p class="mt-2 text-xs">Active sign-in sessions: {member.user.activeSessions} · Last observed activity: <Timestamp value={member.user.lastObservedActivityIso} /> · <Deleted deletedAt={member.user.deletedAt} /></p>
    <div class="my-4"><Usage data={member.user} /></div><DeviceTable devices={member.user.devices} />
  </div>)}</div>;
}

export function OperatorAccountPage({ user, data, now = new Date() }: { user: LayoutUser; data: OperatorAccountDetail; now?: Date }) {
  const current = data.members.filter((m) => m.currentBilling);
  const former = data.members.filter((m) => m.retainedMembership && (!m.currentBilling || m.status !== "active"));
  return <Layout title={`Account · ${data.id}`} user={user} analytics={false}><OperatorNav section="accounts" />
    <a class="link text-xs" href="/internal/accounts">All accounts</a><h1 class="mt-2 text-xl font-semibold">Account</h1><p class="font-mono text-xs break-all text-muted">{data.id}</p>
    <Section title="Account and owner"><Table headers={["Owner", "Created", "Country", "Country source", "Billing provider", "Deletion"]} rows={[[<UserLink user={data.owner} />, <Timestamp value={data.createdAt} />, data.country ?? "Unknown", data.countrySource ?? "Unknown", data.billingProvider ?? "None", <Deleted deletedAt={data.deletedAt} />]]} empty="" /></Section>
    <Section title="Current subscription and seat usage" note="Seats are account-wide. Occupied seats and outstanding unexpired invitations are shown separately. Worker and app-device limits apply to each user; account device totals are informational.">
      <Plan subscription={data.subscription} /><p class="mt-2 text-xs"><Source subscription={data.subscription} /></p>
      <div class="mt-4 grid gap-6 sm:grid-cols-3">{data.subscription ? <CellMeter label="Occupied seats" used={data.occupiedSeats} limit={data.subscription.seats} unit="seats" /> : <p class="text-sm">Occupied seats: {data.occupiedSeats} · Purchased seats: Unknown</p>}
        <div><div class="text-xs text-muted">Outstanding unexpired invitations</div><div class="mt-1 font-mono text-2xl">{data.pendingInvites}</div></div>
        <div><div class="text-xs text-muted">Active machines · informational total</div><div class="mt-1 font-mono text-2xl">{data.machines}</div></div></div>
      <p class="mt-4 text-xs">Phones: {data.phones} · Desktop controllers: {data.desktopControllers} · Active sign-in sessions: {data.activeSessions} · Last observed activity: <Timestamp value={data.lastObservedActivityIso} /></p>
    </Section>
    <Section title="Current billing members" note={`Only these users contribute to the account's device, session and activity totals. ${ACTIVITY_NOTE}`}><Members members={current} /></Section>
    <Section title="Retained former members" note={`Devices and activity below are current observations of these users, not activity attributable to their former membership. Only users also listed under current billing members contribute to current account totals. ${HISTORY_NOTE}`}><Members members={former} former /></Section>
    <Section title="Retained invitations" note="Expired pending invitations are displayed as expired without changing the stored record. A missing bounce report is not delivery confirmation."><InviteTable invites={data.invites} now={now} /></Section>
    <Section title="Retained subscriptions" note={HISTORY_NOTE}><Table headers={["Subscription / plan", "Status", "Source", "Seats", "Workers per user", "App devices per user", "Created", "Updated", "Period end", "Trial start / end", "Cancelled"]}
      rows={data.subscriptions.map((s) => [<div class="font-mono break-all">{s.id}<div class="font-sans">{s.plan.label} · {s.tier}{data.subscription?.id === s.id ? " · Effective" : ""}</div></div>, s.status, <Source subscription={s} />, s.seats, s.workerLimit, s.appDeviceLimit,
        <Timestamp value={s.createdAt} />, <Timestamp value={s.updatedAt} />, <Timestamp value={s.currentPeriodEnd} />, <div><Timestamp value={s.trialStartedAt} /><br /><Timestamp value={s.trialEndsAt} /></div>, <Timestamp value={s.cancelledAt} />])} empty="No retained subscriptions." /></Section>
    <Section title="Billing customer IDs"><Table headers={["Provider", "Customer ID"]} rows={data.billingCustomers.map((customer) => [customer.provider, <span class="font-mono break-all">{customer.providerCustomerId}</span>])} empty="No billing customer records." /></Section>
  </Layout>;
}
