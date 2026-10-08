// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

/**
 * How long FCM/APNs may hold an undelivered push. Long enough that a phone off
 * overnight or through a flight still hears what its agents asked; short enough
 * that a device offline for days does not come back to a backlog of agent state
 * that has long since moved on. Keep in lockstep with the app's kPushMaxAge, which drops anything
 * older that still slips through.
 */
export const PUSH_TTL_SECONDS = 12 * 60 * 60;

export interface PushSendOptions {
  /** Opaque thread key from push:deliver. APNs only: FcmSender ignores it (see there). */
  collapseKey?: string;
}

export interface PushSender {
  send(pushToken: string, data: Record<string, string>, opts?: PushSendOptions): Promise<"ok" | "unregistered" | "error">;
}
