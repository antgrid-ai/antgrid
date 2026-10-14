// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { z } from "zod";

export const OriginSchema = z.object({
  surface: z.enum(["flutter", "web", "unknown"]),
  platform: z.enum(["android", "ios", "macos", "windows", "linux", "unknown"]),
  method: z.string().max(32),
  version: z.string().max(64).nullable(),
  quality: z.enum(["reported", "inferred", "unknown"]),
});
export type AuthOrigin = z.infer<typeof OriginSchema>;
export function requestOrigin(headers: Headers | null, method: string): AuthOrigin {
  const ua = headers?.get("user-agent") ?? "";
  const platform = /android/i.test(ua) ? "android" : /iphone|ipad/i.test(ua) ? "ios"
    : /windows/i.test(ua) ? "windows" : /mac/i.test(ua) ? "macos"
    : /linux/i.test(ua) ? "linux" : "unknown";
  const reported = OriginSchema.safeParse({
    surface: "flutter", platform: headers?.get("x-antgrid-platform"), method,
    version: headers?.get("x-antgrid-version") ?? null, quality: "reported",
  });
  if (reported.success && headers?.get("x-antgrid-surface") === "flutter") return reported.data;
  return { surface: ua ? "web" : "unknown", platform, method, version: null,
    quality: ua ? "inferred" : "unknown" };
}

export const FlowResultSchema = z.object({
  id: z.uuid(), journeyId: z.uuid(),
  status: z.enum(["pending", "ready", "expired", "consumed", "unbound"]),
  serverTime: z.iso.datetime(), expiresAt: z.iso.datetime(), retryAt: z.iso.datetime(),
  delivery: z.enum(["accepted", "queued", "sending", "provider_accepted", "failed", "expired", "bounced"]).nullable(),
});

export function safeReturnPath(raw: string | undefined): string {
  if (!raw || raw.length > 2048 || /[\\\x00-\x20#]/.test(raw)) return "/dashboard";
  let decoded = raw;
  try { for (let i = 0; i < 3; i++) decoded = decodeURIComponent(decoded); }
  catch { return "/dashboard"; }
  if (!/^\/(?![/\\])/.test(decoded) || /[\\\x00-\x20#]/.test(decoded)) return "/dashboard";
  const url = new URL(raw, "https://antgrid.invalid");
  if (url.origin !== "https://antgrid.invalid" ||
      /^\/(?:login|signup|oauth|api\/auth|ui|forgot-password|reset-password)(?:\/|$)/i.test(new URL(decoded, url.origin).pathname)) return "/dashboard";
  const permitted = new Set(["plan", "invite", "tab", "notice"]);
  if (url.pathname === "/invite" && z.uuid().safeParse(url.searchParams.get("id")).success && /^[A-Za-z0-9_-]{32,128}$/.test(url.searchParams.get("t") ?? "")) { permitted.add("id"); permitted.add("t"); }
  for (const key of [...url.searchParams.keys()]) if (!permitted.has(key)) url.searchParams.delete(key);
  return url.pathname + url.search;
}
