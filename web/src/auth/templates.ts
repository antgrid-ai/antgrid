// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

const escape = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
export function authEmail(p: { action: string; url: string; description: string; device?: string | null; createdAt: Date; expiresAt: Date }) {
  const device = p.device?.replace(/[\x00-\x1f\x7f]/g, "").slice(0, 160) ?? "Unknown device";
  const details = `Requested: ${p.createdAt.toISOString()}\nExpires: ${p.expiresAt.toISOString()}\nRequesting device (reported): ${device}`;
  return { subject: `${p.action} — Antgrid`,
    text: `Antgrid\n\n${p.description}\n\n${p.action}: ${p.url}\n\n${details}\n\nIf you did not start this request, ignore it.`,
    html: `<!doctype html><html lang="en"><body style="font-family:Arial,sans-serif;color:#18181b;background:#fff"><main style="max-width:560px;margin:auto;padding:24px"><h1>Antgrid</h1><h2>${escape(p.action)}</h2><p>${escape(p.description)}</p><p><a href="${escape(p.url)}">${escape(p.action)}</a></p><p style="overflow-wrap:anywhere">${escape(p.url)}</p><p>Requested: ${escape(p.createdAt.toISOString())}<br>Expires: ${escape(p.expiresAt.toISOString())}<br>Requesting device (reported): ${escape(device)}</p><p>If you did not start this request, ignore it.</p></main></body></html>` };
}
