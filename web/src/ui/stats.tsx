// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { Layout, type LayoutUser } from "./layout.js";
import type { LiveRelaySummary, UsageStats } from "../usage/stats.js";
import { Notice, RelayUnreachable } from "./notice.js";
import { OperatorNav } from "./operator-nav.js";

const n = (v: number) => v.toLocaleString("en-US");

function Kpi({ label, value, sub }: { label: string; value: number; sub?: string }) {
  return (
    <div class="rounded-box border border-edge bg-panel p-5">
      <div class="text-xs font-medium text-muted2">{label}</div>
      <div class="mt-3 font-mono text-3xl leading-none text-ink2 tabular-nums">{n(value)}</div>
      {sub && <div class="mt-3 text-sm text-muted">{sub}</div>}
    </div>
  );
}

function KpiRow({ children }: { children: unknown }) {
  return (
    <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
      {children}
    </div>
  );
}

function Section({ title, note, definition, children }: { title: string; note?: string; definition?: string; children: unknown }) {
  return (
    <section class="mt-10">
      <h2 class="mb-2 text-lg font-semibold">{title}</h2>
      {note && <p class="mb-4 text-sm leading-relaxed text-muted">{note}</p>}
      {definition && <details class="operator-definitions">
        <summary>How these counts work</summary>
        <p>{definition}</p>
      </details>}
      {children}
    </section>
  );
}

function Table({ head, rows, empty }: { head: string[]; rows: (string | number)[][]; empty: string }) {
  if (rows.length === 0) return <Notice text={empty} />;
  return (
    <div class="overflow-x-auto card bg-panel border border-edge">
      <table class="operator-table">
        <thead>
          <tr class="text-muted2">
            {head.map((h, index) => (
              <th class={`whitespace-nowrap ${rows.some((row) => typeof row[index] === "number") ? "text-right" : ""}`}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr>
              {row.map((cell) => (
                <td class={`whitespace-nowrap ${typeof cell === "number" ? "text-right font-mono tabular-nums" : /^\d{4}-\d{2}-\d{2}/.test(cell) ? "font-mono tabular-nums" : ""}`}>{typeof cell === "number" ? n(cell) : cell}</td>
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
    <Layout title="Usage" user={user} analytics={false} contentWidth="wide">
      <OperatorNav section="stats" />
      <div class="flex flex-wrap items-baseline justify-between gap-3 mb-2">
        <h1 class="text-2xl font-semibold">Usage</h1>
        <a href="/internal/connections" class="link text-sm text-muted2">
          Live connections
        </a>
      </div>
      <p class="text-sm text-muted">Current relay presence, registered devices and retained usage history.</p>

      <Section title="Relay now" note="Connected devices in the latest relay snapshot. Socket totals include individual connection slots.">
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

      <Section title="User accounts" note="Signup totals and registered device reach.">
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
        note="Daily active users and devices, plus peak and distinct relay presence. Days are UTC."
        definition="Active = heartbeated that UTC day or held by the relay at a 5-minute sample. Phones and machines heartbeat while running; desktop controllers never do, so they count only while the relay holds them. Apps are phones plus desktop controllers. Peak = most devices connected at one sample; Seen = distinct devices the relay held that day. History starts when the sampler was first deployed."
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
        note="Current unrevoked registrations, grouped by device class and platform."
        definition="Heartbeat columns never count desktop controllers, which do not heartbeat; use Daily activity for activity."
      >
        <Table
          head={["Class", "Platform", "Devices", "Users", "Heartbeat 7d", "Heartbeat 30d"]}
          rows={stats.devices.map((d) => [d.class, d.platform, d.devices, d.users, d.heartbeat7d, d.heartbeat30d])}
          empty="No devices registered."
        />
      </Section>

      <Section title="Subscriptions" note="Retained subscription records grouped by tier, status and promotional grant.">
        <Table
          head={["Tier", "Status", "Grant", "Count"]}
          rows={stats.subscriptions.map((s) => [s.tier, s.status, s.promotional ? "promo" : "paid", s.count])}
          empty="No subscriptions."
        />
      </Section>

      <Section
        title="App installs"
        note="Anonymous app install counts by platform."
        definition="Client-reported, unauthenticated, install-scoped. Telemetry is opt-out and off in demo mode."
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
