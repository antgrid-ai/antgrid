// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { Layout, type LayoutUser } from "./layout.js";
import type { LiveRelaySummary, UsageStats } from "../usage/stats.js";
import { Notice, RelayUnreachable } from "./notice.js";

const n = (v: number) => v.toLocaleString("en-US");

function Kpi({ label, value, sub }: { label: string; value: number; sub?: string }) {
  return (
    <div>
      <div class="text-[0.6875rem] font-medium uppercase tracking-[0.12em] text-muted2">{label}</div>
      <div class="mt-1 font-mono text-xl leading-none text-ink2">{n(value)}</div>
      {sub && <div class="mt-1 text-xs text-muted">{sub}</div>}
    </div>
  );
}

function KpiRow({ children }: { children: unknown }) {
  return (
    <div class="grid grid-cols-2 gap-x-8 gap-y-6 rounded-box border border-edge bg-page/40 p-5 sm:grid-cols-4">
      {children}
    </div>
  );
}

function Section({ title, note, children }: { title: string; note?: string; children: unknown }) {
  return (
    <section class="mt-8">
      <h2 class="text-sm font-semibold mb-1">{title}</h2>
      {note && <p class="text-xs text-muted mb-3">{note}</p>}
      {children}
    </section>
  );
}

function Table({ head, rows, empty }: { head: string[]; rows: (string | number)[][]; empty: string }) {
  if (rows.length === 0) return <Notice text={empty} />;
  return (
    <div class="overflow-x-auto card bg-panel border border-edge">
      <table class="table table-sm font-mono text-xs">
        <thead>
          <tr class="text-muted2">
            {head.map((h) => (
              <th class="whitespace-nowrap px-2">{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr>
              {row.map((cell) => (
                <td class="whitespace-nowrap px-2">{typeof cell === "number" ? n(cell) : cell}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function StatsPage(props: { user: LayoutUser; stats: UsageStats; live: LiveRelaySummary | null }) {
  const { user, stats, live } = props;
  return (
    <Layout title="Usage" user={user}>
      <div class="flex items-baseline gap-3 mb-4">
        <h1 class="text-xl font-semibold">Usage</h1>
        <a href="/internal/connections" class="link text-xs text-muted2">
          Live connections
        </a>
      </div>

      <Section title="Relay now">
        {live === null ? (
          <RelayUnreachable />
        ) : (
          <KpiRow>
            <Kpi label="Machines" value={live.machines} />
            <Kpi label="Phones" value={live.phones} />
            <Kpi label="Desktop controllers" value={live.controllers} />
            <Kpi
              label="Sockets"
              value={live.sockets}
              sub={live.unknown ? `${n(live.unknown)} unregistered or revoked devices` : undefined}
            />
          </KpiRow>
        )}
      </Section>

      <Section title="Accounts">
        <KpiRow>
          <Kpi label="Users" value={stats.users.total} sub={`${n(stats.waitlist)} on waitlist`} />
          <Kpi label="New · 24h" value={stats.users.new1d} />
          <Kpi label="New · 7d" value={stats.users.new7d} />
          <Kpi label="New · 30d" value={stats.users.new30d} />
          <Kpi label="With a phone" value={stats.reach.phone} />
          <Kpi label="With a machine" value={stats.reach.machine} />
          <Kpi label="Machine + phone" value={stats.reach.machineAndPhone} />
          <Kpi label="With a desktop controller" value={stats.reach.controller} />
        </KpiRow>
      </Section>

      <Section
        title="Daily activity"
        note="UTC days. Active = heartbeated that UTC day or held by the relay at a 5-minute sample. Phones and machines heartbeat while running; desktop controllers never do, so they count only while the relay holds them. Apps are phones plus desktop controllers. Peak = most devices connected at one sample; Seen = distinct devices the relay held that day. History starts when the sampler was first deployed."
      >
        <Table
          head={["Day", "Users", "Phones", "Machines", "Controllers", "Peak", "Peak apps", "Peak machines", "Seen apps", "Seen machines"]}
          rows={stats.history.map((h) => [
            h.day,
            h.activeUsers,
            h.activeMobileApps,
            h.activeAgents,
            h.activeDesktopApps,
            h.relayPeakTotal,
            h.relayPeakApps,
            h.relayPeakAgents,
            h.relaySeenApps,
            h.relaySeenAgents,
          ])}
          empty="No samples yet."
        />
      </Section>

      <Section
        title="Registered devices"
        note="Unrevoked rows. Heartbeat columns never count desktop controllers, which do not heartbeat; use Daily activity for activity."
      >
        <Table
          head={["Class", "Platform", "Devices", "Users", "Heartbeat 7d", "Heartbeat 30d"]}
          rows={stats.devices.map((d) => [d.class, d.platform, d.devices, d.users, d.heartbeat7d, d.heartbeat30d])}
          empty="No devices registered."
        />
      </Section>

      <Section title="Subscriptions">
        <Table
          head={["Tier", "Status", "Grant", "Count"]}
          rows={stats.subscriptions.map((s) => [s.tier, s.status, s.promotional ? "promo" : "paid", s.count])}
          empty="No subscriptions."
        />
      </Section>

      <Section
        title="App installs"
        note="Client-reported, unauthenticated, install-scoped. Telemetry is opt-out and off in demo mode."
      >
        <Table
          head={["Platform", "24h", "7d", "30d"]}
          rows={stats.installs.map((i) => [i.platform, i.d1, i.d7, i.d30])}
          empty="No analytics events in the last 30 days."
        />
      </Section>

      <Section title="App events · 7d">
        <Table
          head={["Event", "Events", "Installs"]}
          rows={stats.events7d.map((e) => [e.name, e.events, e.installs])}
          empty="No analytics events in the last 7 days."
        />
      </Section>

      <Section title="Signups by week">
        <Table
          head={["Week of", "Signups"]}
          rows={stats.signupsByWeek.map((w) => [w.week, w.count])}
          empty="No signups in the last 12 weeks."
        />
      </Section>
    </Layout>
  );
}
