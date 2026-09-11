---
layout: ../layouts/Legal.astro
title: Privacy Policy — antgrid
description: How Radha AI Products collects, uses, and protects your information when you use Antgrid. End-to-end encrypted; the relay never sees your code.
path: /privacy
---

# Privacy Policy

**Last updated:** September 11, 2026

This Privacy Notice for **BHARATH MOHAN** (doing business as **Radha AI Products**) ("we," "us," or "our") describes how and why we might access, collect, store, use, and/or share ("process") your personal information when you use **Antgrid** and our related services ("Services"), including when you:

- Visit our website at [https://antgrid.ai](https://antgrid.ai), use the app at [https://app.antgrid.ai](https://app.antgrid.ai), or any website or application of ours that links to this Privacy Notice
- Install and run the Antgrid bridge, desktop app, or mobile app
- Engage with us in other related ways, including any sales, marketing, or support

Radha AI Products is the legal entity behind Antgrid. **Questions or concerns?** If you do not agree with our policies and practices, please do not use our Services. If you have questions, contact us at [contact@radhaai.com](mailto:contact@radhaai.com).

## Summary of Key Points

- **End-to-end encrypted.** Communication between your coding agents and your devices is end-to-end encrypted (X25519 key exchange + AES-256-GCM). Our relay server forwards encrypted data it **cannot decrypt** — it never sees your source code, terminal output, prompts, or files in readable form. The relay does authenticate and route by your device identity (see Section 3).
- **What we process.** Account details (name, email), device identifiers and public keys used for pairing, session information including IP address and browser/device type, and billing status. Payment card data is handled by our payment processors and app stores — not by us.
- **Privacy-respecting analytics, crash reporting & support.** Anonymous, cookieless usage analytics — self-hosted Umami on our websites and in the app, plus our own first-party backend for the app — and crash/error reports via our self-hosted error tracker. No third-party analytics, advertising, or tracking SDKs, and no third party ever receives your data to use for its own purposes — the only third-party SDK in the app (Sentry) is used purely as transport to our own self-hosted error tracking, and the infrastructure providers listed in Section 7 only carry it on our behalf. No personal information is included; the app's telemetry can be turned off anytime in app settings, and the website's analytics identifies no one to begin with. Zoho SalesIQ is used only when you explicitly open support chat; tracking is disabled, and the widget is not loaded before that action.
- **AI providers.** Antgrid does not send your code or prompts to AI providers. Your local coding agents (e.g., Claude Code, Codex) do that directly, under your own accounts and API keys.
- **We do not sell your personal information**, and we do not process sensitive personal information.
- **Your rights.** You may review, change, or delete your information. See Sections 10 and 11.

## 1. What Information Do We Collect?

### Personal information you disclose to us

- **Account information** — name and email address (provided directly or via a third-party sign-in provider).
- **Billing status** — your plan, subscription state, trial status, and transaction identifiers returned by our payment processors or app stores. **We do not collect or store full payment card numbers; these are handled entirely by our payment processors and the app stores.**
- **Waitlist email address** — if you join the founding-pricing waitlist from our website or pricing page, we store the email address you submit and the page you submitted it from, so we can tell you when pricing opens. This does not create an account, and the submitting IP address is used only for rate limiting and is never stored on the record.
- **Support conversations** — if you choose to open support chat, we process the messages and attachments you submit. When you are signed in, your name or account identifier and email address are supplied so we can recognize you and retain conversation history across devices. The app passes name and email to the support page in a URL fragment, which is removed after the page reads it and is not sent to our web host.

### Information collected automatically

When you use the Services, we collect limited technical information necessary to operate and secure them:

- **Device and pairing data** — a device identifier (device UUID), device public keys (a persistent **Ed25519** identity key and a per-connection **X25519** session key) used to establish encrypted sessions, the device/machine name (derived from your system hostname or set by you), and your subscription tier. While a device is connected, our relay holds these in memory to authenticate and route your traffic.
- **Session and connection data** — your **IP address** and **browser/device user-agent**. We use these to operate the Services, authenticate sessions, prevent abuse, and enforce rate limits. How long this is retained, and where it is stored, is described in Sections 5 and 7.
- **Sign-in security data** — when you use cross-device (email link) sign-in, we briefly record the requesting IP address and user-agent and include them in the approval email so you can confirm the request is yours.
- **Website analytics** — when you visit [https://antgrid.ai](https://antgrid.ai) or your account pages at [https://app.antgrid.ai](https://app.antgrid.ai), our self-hosted Umami instance records the page address (including any campaign parameters in the link you followed), the referring site, the page title, your browser, operating system, device type, screen size, language, and an approximate location (country, and region or city where available). No cookies are set and nothing is stored on your device. Visits are grouped using an anonymous hash derived from your IP address and browser; the IP address itself is not kept in the analytics record, the hash is scoped to the individual site you are on — our website and your account pages are counted separately and cannot be joined — and you are never tracked across other websites.
- **App usage analytics** — when telemetry is enabled (opt-out; toggled in app settings), we collect anonymous usage events: an install-scoped random UUID (generated on first run and stored in secure device storage — this is **not** your account id, device UUID, or any persistent personal identifier), the event name, your platform, and app version. The install id is sent only to our own first-party backend (for retention analysis); our self-hosted Umami instance receives no install id or identifier of any kind — only the event name, your platform, and a small set of non-identifying properties describing the event itself (for example which sign-in method was used), grouped by the same cookieless, anonymous hash and approximate location described under **Website analytics** above. No personal information, no content, and no relay traffic is included. The install id is never shared with any third party, and it persists locally in secure storage; when telemetry is off it is simply not transmitted.
- **Crash and error diagnostics** — when telemetry is enabled, the app reports crashes and errors to our self-hosted error tracker using the Sentry SDK as transport only (no data is sent to Sentry's own servers or any third party). Before transmission, file paths are truncated and any potential user content is stripped. These reports contain stack traces, app version, platform, and device type — not your source code, files, or personal information.

### Information we do **not** access

Because of our end-to-end encryption, we do **not** have access to, and do **not** store in readable form: your source code, files, repository contents, terminal output, command history, prompts to or responses from AI agents, any images or attachments you send to your agent, or the content of any message, approval, or preview tunneled through the relay. The relay processes only opaque ciphertext, and we do not persist images or attachments on our servers.

## 2. How Do We Process Your Information?

- **Provide and operate the Services** — create and authenticate your account, pair your devices, route encrypted traffic, and deliver the features you use.
- **Determine correct pricing** — we use your IP address to detect your country so we can show the correct price and apply taxes (see Section 6).
- **Process payments and manage subscriptions** — via our payment processors and app stores (Section 6).
- **Maintain security** — prevent fraud and abuse, enforce rate limits, and protect the integrity of the relay and your account.
- **Communicate with you** — send service, security, billing, and support messages.
- **Comply with law** — meet legal, tax, and accounting obligations.

## 3. End-to-End Encryption and the Relay

All agent-to-app traffic is end-to-end encrypted after a handshake using X25519 key exchange and AES-256-GCM authenticated encryption. Encryption keys are generated on your devices, are per-connection, and are never persisted by us. As a result, **we cannot read the contents of the data you transmit through the Services.**

For full transparency about what the relay *can* see: the relay authenticates devices using their public keys and routes messages by device identity, so it processes device identifiers and the public keys exchanged during the handshake. When a recipient device is not connected, the relay does not hold the message: the frame is refused and dropped. Nothing is queued, buffered, or written to disk. The relay returns the same response whether the recipient is offline or the sender is not permitted to reach it, so it never discloses which of your devices are online. The relay does **not** store your IP address in a database or link it to your account; IP addresses on the relay are held only in memory for the duration of a connection (for rate limiting) and may appear in short-lived operational logs.

## 4. Analytics, Crash Reporting, and Tracking

**We do not use any third-party analytics, advertising, or behavioral-tracking technologies, and no third party ever receives your analytics or crash data to use for its own purposes.** The analytics and error-tracking services are our own, running on infrastructure we control; the providers listed in Section 7 carry that traffic on our behalf and nothing more. We do not use tracking cookies. Our website and app use only the functional cookies and storage necessary to keep you signed in and to operate the Services. Zoho SalesIQ's website tracking is disabled. Its support widget connects only after you choose Chat with support and may then use functional storage needed to maintain the conversation.

Our website and the Antgrid app both collect anonymous, first-party usage analytics, and the app additionally reports crashes and errors when telemetry is enabled:

- **Website analytics** are cookieless and anonymous. We use our own self-hosted [Umami](https://umami.is) instance, on our website and on your account pages, to count page visits and see which links bring readers here. It sets no cookies, stores no identifier on your device, and cannot follow you to any other website — Section 1 lists the exact fields. Nothing on the site depends on it, so blocking the script costs you nothing.
- **App usage analytics** are cookieless and anonymous. We use the same self-hosted [Umami](https://umami.is) instance and our own first-party backend to record which features are used, on what platform, and with which app version. Umami receives only the event name, the platform, and a small set of non-identifying properties describing the event itself — no install id or identifier of any kind. A random install-scoped UUID (not your account or device id) is sent only to our own first-party backend for retention analysis. You can opt out at any time in the app's settings (Settings → Privacy → Usage Analytics).
- **Crash and error reports** are sent via the Sentry SDK configured to point exclusively at our own self-hosted error tracker — no data is forwarded to Sentry's cloud or any other third party. Reports contain stack traces, platform, app version, and device type. User content and file paths are stripped before transmission.

The app's telemetry is **on by default** but entirely optional. If you opt out, analytics events stop immediately. Crash reporting is disabled at the next app launch (it is initialized at startup, so a restart is needed for that change to take effect). Your choice is stored locally on your device. Website analytics has no such toggle, because there is nothing about you for it to switch off — it sets no cookie, stores nothing on your device, and identifies no one.

## 5. Where Your Information Is Stored

- **Account and session data** (name, email, and your session's IP address and user-agent) is stored in our application database, associated with your account, for security and account management.
- **Cross-device sign-in records** (including the requesting IP and user-agent) are stored only briefly and expire automatically (within approximately 10 minutes).
- **Relay traffic** is processed in transit only and is end-to-end encrypted; the relay does not maintain a database of your activity.

## 6. Artificial Intelligence and Third-Party Coding Agents

Antgrid is a command centre for AI coding agents (such as Claude Code, Codex, and similar tools) that you install and run on your own machine. **Antgrid does not itself send your code, prompts, or data to AI providers.** Those agents connect to their respective AI providers (e.g., Anthropic, OpenAI, Google) directly, using your own accounts, credentials, and API keys, and are governed by those providers' terms and privacy policies. You are responsible for your use of those agents and for complying with the applicable AI provider terms.

## 7. With Whom Do We Share Your Information? (Subprocessors)

We share information only with service providers that help us operate the Services, and only as needed. Our key subprocessors are:

| Provider | Purpose | What they receive |
|---|---|---|
| **Razorpay** | Payment processing (web) | Payment and billing details |
| **Paddle** | Payment processing (web, merchant of record) | Payment and billing details |
| **Apple** | In-app purchases (iOS) | Purchase/subscription data |
| **Google** | In-app purchases (Android) | Purchase/subscription data |
| **ipinfo.io** | Geolocation for correct pricing and tax | Your IP address (to return a country code) |
| **ZeptoMail (Zoho)** | Transactional and sign-in emails | Your email address and message content |
| **Zoho SalesIQ** | User-initiated customer support chat | Name or account identifier and email when signed in, technical connection data, and the support messages or attachments you submit |
| **Cloudflare** | CDN and security filtering in front of our analytics endpoint | Connection data for requests it proxies (IP address, user-agent) |
| **Microsoft Azure** | Hosting and infrastructure (website, app backend, and relay) | Technical/connection data as needed to operate |

Each provider operates under its own privacy policy. We may also disclose information **for legal reasons** (to comply with applicable law or enforceable governmental request, and to protect our rights, safety, and property) and **in a business transfer** (merger, financing, acquisition, or sale of assets). We do **not** sell your personal information.

## 8. How Long Do We Keep Your Information?

We keep personal information only for as long as necessary for the purposes set out in this Notice, unless a longer period is required or permitted by law (such as tax or accounting requirements):

- **Account information** — for as long as your account is active, and then as required for legal/financial obligations.
- **Session IP address and user-agent** — for the lifetime of the session; expired and deleted sessions are removed.
- **Cross-device sign-in records** — automatically expire within approximately 10 minutes.
- **Operational logs** (which may contain IP addresses) — retained for up to 30 days, then deleted.
- **Waitlist email address** — until founding pricing opens and we have contacted you, or until you ask us to remove it, whichever comes first.
- **Support conversations** — while needed to resolve and follow up on your request, and then according to our support retention settings or until you ask us to delete them where applicable.

When we no longer have a legitimate need to process your information, we delete or anonymize it, or securely isolate it where deletion is not immediately possible (for example, in backups).

## 9. How Do We Keep Your Information Safe?

We implement appropriate technical and organizational measures to protect personal information, including end-to-end encryption of agent traffic and authenticated device pairing. However, no method of transmission or storage is 100% secure, and we cannot guarantee absolute security.

## 10. What Are Your Privacy Rights?

Depending on your location, you may have the right to access, correct, update, or delete your personal information, to withdraw consent, and to opt out of marketing communications. To exercise these rights, contact us at [contact@radhaai.com](mailto:contact@radhaai.com).

### Account and data deletion

You can request deletion of your account and associated personal data at any time by emailing [contact@radhaai.com](mailto:contact@radhaai.com) with the subject "Account Deletion Request" from your registered email address. Upon verification, we will delete or anonymize your account data, except where retention is required by law (for example, tax and transaction records). We will action verified deletion requests within 30 days.

To be removed from the founding-pricing waitlist, email us from the address you submitted with the subject "Waitlist Removal" — no account is needed, and we delete the record on verification.

If you purchased through the Apple App Store or Google Play, manage or cancel any active subscription through your store account before requesting deletion, as those subscriptions are managed by the store (see our [Cancellation & Refund Policy](/refunds)).

## 11. India (DPDP Act, 2023) — Grievance Redressal

If you are in India, you have rights under the Digital Personal Data Protection Act, 2023, including the right to access, correct, and erase your personal data and to grievance redressal. To exercise these rights or raise a grievance, contact our Grievance Officer:

**Grievance Officer:** Bharath Mohan (Proprietor, Radha AI Products)
**Email:** [contact@radhaai.com](mailto:contact@radhaai.com)

We will acknowledge your grievance within 48 hours and aim to resolve it within 30 days.

## 12. Do We Collect Information From Minors?

We do not knowingly collect data from or market to children under 18 years of age. By using the Services, you represent that you are at least 18, or the parent or guardian of a minor who uses the Services with your consent. If you believe we have collected information from a child under 18, contact us at [contact@radhaai.com](mailto:contact@radhaai.com) and we will take reasonable steps to delete it.

## 13. Controls for Do-Not-Track Features

No uniform standard for recognizing Do-Not-Track ("DNT") signals has been finalized, so we do not currently respond to them. Because we do not use behavioral tracking, this has no effect on how we handle your information.

## 14. Jurisdiction-Specific Rights

If you are located in a jurisdiction with specific data-protection requirements (for example, the European Union or the United Kingdom), you may have additional rights, including the rights of access, erasure, and data portability. To the extent those laws apply, we honor the higher standard. This Privacy Notice is governed by the laws of India, and disputes are subject to the exclusive jurisdiction of the courts of India.

## 15. Do We Make Updates to This Notice?

Yes. We may update this Privacy Notice from time to time. The updated version will be indicated by a revised "Last updated" date. If we make material changes, we will notify you by posting a prominent notice or by direct communication where required.

## 16. How Can You Contact Us About This Notice?

If you have questions or comments about this notice, email us at [contact@radhaai.com](mailto:contact@radhaai.com) or write to us at:

**Radha AI Products**
14A Chokka Nadar Shandu, Thiruthangal
Tamil Nadu - 626130, India
GSTIN: 33BCQPB1528R1ZA
[contact@radhaai.com](mailto:contact@radhaai.com)
