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
    <nav aria-label="Operator pages" class="mb-6 flex flex-wrap gap-2 border-b border-edge pb-3 text-sm">
      {links.map(([key, label]) => (
        <a href={`/internal/${key}`} aria-current={section === key ? "page" : undefined}
          class={section === key ? "rounded bg-chrome px-3 py-1.5 text-ink" : "rounded px-3 py-1.5 text-muted hover:bg-chrome hover:text-ink"}>
          {label}
        </a>
      ))}
    </nav>
  );
}
