// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { Hono } from "hono";

export const health = new Hono().get("/health", (c) =>
  c.json({ ok: true, service: "web" })
);
