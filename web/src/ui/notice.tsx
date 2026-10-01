// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

/** A one-line card standing in for content that is empty or failed to load. */
export function Notice({ text, tone = "muted" }: { text: string; tone?: "muted" | "error" }) {
  return (
    <div class={`card bg-panel border ${tone === "error" ? "border-error/40" : "border-edge"}`}>
      <div class="card-body">
        <p class={`text-sm ${tone === "error" ? "text-error" : "text-muted"}`}>{text}</p>
      </div>
    </div>
  );
}

export function RelayUnreachable() {
  return <Notice tone="error" text="Could not reach the relay. Check RELAY_INTERNAL_URL / secret." />;
}
