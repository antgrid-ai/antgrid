// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

type OperatorSection = "users" | "accounts" | "stats" | "connections";

export function OperatorNav({ section }: { section: OperatorSection }) {
  const links = [
    ["users", "Users"],
    ["accounts", "Accounts"],
    ["stats", "Stats"],
    ["connections", "Connections"],
  ] as const;
  return (
    <nav aria-label="Operator pages" class="mb-8 flex flex-wrap items-center gap-2 border-b border-edge pb-4 text-sm">
      <span class="mr-3 text-xs font-semibold uppercase tracking-wide text-muted">Operator</span>
      {links.map(([key, label]) => (
        <a href={`/internal/${key}`} aria-current={section === key ? "page" : undefined}
          class={section === key ? "rounded-box bg-chrome px-4 py-2 font-semibold text-ink" : "rounded-box px-4 py-2 text-muted hover:bg-chrome hover:text-ink"}>
          {label}
        </a>
      ))}
    </nav>
  );
}
