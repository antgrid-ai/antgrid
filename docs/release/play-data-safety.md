# Google Play Data Safety Form — Telemetry Declarations

This document records the canonical Google Play Data Safety form answers for analytics and crash reporting introduced in the app-telemetry feature. Future Play Store submissions must remain consistent with these declarations.

---

## App Activity

### App interactions

| Attribute | Answer |
|---|---|
| **Data collected** | Yes — user engagement events (app launches, terminal input, file navigation, settings changes) |
| **Sharing** | Not shared with third parties |
| **User awareness & control** | Disclosed in app settings; gated behind single opt-out toggle (`telemetryEnabled`, default on) |
| **Purpose** | Analytics — usage patterns, feature adoption, retention |
| **Encryption in transit** | Yes — all payloads sent over HTTPS |
| **Ephemeral** | No — retained first-party for retention analysis |

---

## App info & Performance

### Crash logs and diagnostics

| Attribute | Answer |
|---|---|
| **Data collected** | Yes — app crashes and unhandled exceptions (Sentry/sentry_flutter) |
| **Redaction** | User content (file paths, project names, code snippets) stripped via `scrubCrashEvent()` before transmission |
| **Sharing** | Not shared; routed to self-hosted error tracking (errex, or GlitchTip DSN if deployed) |
| **User awareness & control** | Disclosed in app settings; gated behind opt-out toggle |
| **Purpose** | App functionality / Analytics — diagnosing failures, prioritizing fixes |
| **Encryption in transit** | Yes — HTTPS to error tracker |
| **Ephemeral** | No — retained self-hosted for crash investigation |

---

## Device or other IDs

### Anonymous install ID

| Attribute | Answer |
|---|---|
| **Data collected** | Yes — random UUID v4 per app install (not account id, device uuid, or advertising id) |
| **Purpose** | Analytics — cohort retention and session deduplication |
| **Sharing** | Not shared |
| **Encryption in transit** | Yes — included in HTTPS events payloads |
| **Resettable** | Not transmitted when telemetry is off (persists locally in secure storage; effectively reset on app-data clear or reinstall) |

---

## Financial information

| Attribute | Answer |
|---|---|
| **In-app purchases** | No — subscriptions handled off-app (web checkout via Paddle/Razorpay) |
| **Payment methods** | Not collected in-app |

Revisit if/when Google Play Billing is integrated.

---

## Summary

All telemetry is governed by a single app-level opt-out (`telemetryEnabled`), default enabled. Analytics events (Plausible + first-party backend) stop immediately when the toggle is turned off. Crash reporting (Sentry) is initialized at app startup, so disabling it takes effect on the next app launch. The install ID is not transmitted when telemetry is off; it persists locally in secure storage and is effectively reset only on app-data clear or reinstall. All transport is over HTTPS; crash payloads are scrubbed to remove user content; and analytics events sent to Plausible contain no identifier (the install UUID is sent only to our own first-party backend). These three properties—anonymous data, encrypted transport, and user control—satisfy Google Play's "optional" data category requirements.

