import type { PlanId, ProviderId } from "./plans.js";

export type NormalizedEventType = "activated" | "renewed" | "canceled" | "past_due" | "expired";

export interface NormalizedEvent {
  provider: ProviderId;
  providerEventId: string;
  type: NormalizedEventType;
  accountId: string;
  planId: PlanId;
  customerId: string;
  providerSubscriptionId?: string;
  providerTransactionId?: string;
  currentPeriodEnd?: Date;
}

export interface PaymentProvider {
  readonly id: ProviderId;
  verifyWebhook(rawBody: string, signature: string | undefined): Promise<NormalizedEvent | null>;
}
