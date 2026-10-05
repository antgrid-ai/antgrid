// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { AsyncLocalStorage } from "node:async_hooks";
import type { DB, Tx } from "../db/index.js";

type Scope = { tx: Tx; flowId?: string; enqueueFailed?: boolean; retryAfter?: number; charged: Set<string> };
export const authScope = new AsyncLocalStorage<Scope>();

// The adapter, hooks and outbox must see the same transaction, including calls
// made through auth.api from server-rendered forms.
export function scopedAuthDb(db: DB): DB {
  return new Proxy(db, {
    get(target, key) {
      const active = authScope.getStore()?.tx ?? target;
      if (key === "$transaction" && active !== target) {
        return (fn: (tx: Tx) => unknown) => fn(active);
      }
      const value = Reflect.get(active, key);
      return typeof value === "function" ? value.bind(active) : value;
    },
  });
}

export async function authTransaction<T>(db: DB, fn: () => Promise<T>): Promise<T> {
  if (authScope.getStore()) return fn();
  return db.$transaction((tx) => authScope.run({ tx, charged: new Set() }, fn),
    { maxWait: 10000, timeout: 30000 });
}

export async function lockAuthAccount(db: Tx, email: string) {
  await db.$executeRaw`SELECT pg_advisory_xact_lock(hashtextextended(${email.toLowerCase()}, 713))`;
}
