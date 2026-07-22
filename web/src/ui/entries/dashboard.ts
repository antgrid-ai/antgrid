/**
 * Post-checkout UX — single status banner (grisb-style), poll until webhook provisions.
 */
type DashboardData = {
  tier: string;
  purchaseSuccess: boolean;
  cancelNotice?: "immediate" | "pending" | "failed" | null;
  resumeNotice?: "success" | "failed" | null;
};

const FREE_TIER = "free";
const POLL_INTERVAL_MS = 2000;
const POLL_TIMEOUT_MS = 45_000;

function readData(): DashboardData | null {
  const el = document.getElementById("dashboard-data");
  if (!el?.textContent) return null;
  return JSON.parse(el.textContent) as DashboardData;
}

function stripQueryParam(name: string) {
  const params = new URLSearchParams(window.location.search);
  if (!params.has(name)) return;
  params.delete(name);
  const qs = params.toString();
  window.history.replaceState(null, "", `${window.location.pathname}${qs ? `?${qs}` : ""}`);
}

function setBannerMessage(msg: string, showSpinner: boolean) {
  const message = document.getElementById("purchase-status-message");
  const spinner = document.getElementById("purchase-status-spinner");
  if (message) message.textContent = msg;
  if (spinner) spinner.classList.toggle("hidden", !showSpinner);
}

function bindDismiss() {
  const btn = document.getElementById("purchase-status-dismiss");
  const banner = document.getElementById("purchase-status-banner");
  btn?.addEventListener("click", () => banner?.classList.add("hidden"));
}

async function pollUntilTier(targetTier: string): Promise<boolean> {
  const deadline = Date.now() + POLL_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const res = await fetch("/subscriptions/me");
    if (res.ok) {
      const body = (await res.json()) as { tier?: string };
      if (body.tier === targetTier) return true;
    }
    await new Promise((r) => window.setTimeout(r, POLL_INTERVAL_MS));
  }
  return false;
}

async function pollUntilNotFree(): Promise<boolean> {
  const deadline = Date.now() + POLL_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const res = await fetch("/subscriptions/me");
    if (res.ok) {
      const body = (await res.json()) as { tier?: string };
      if (body.tier && body.tier !== FREE_TIER) return true;
    }
    await new Promise((r) => window.setTimeout(r, POLL_INTERVAL_MS));
  }
  return false;
}

function bindModal(openId: string, modalId: string, dismissAttr: string) {
  const modal = document.getElementById(modalId);
  const openBtn = document.getElementById(openId);
  if (!modal || !openBtn) return;

  const dismiss = () => modal.classList.remove("modal-open");
  openBtn.addEventListener("click", () => modal.classList.add("modal-open"));
  modal.querySelectorAll(`[${dismissAttr}]`).forEach((el) => {
    el.addEventListener("click", dismiss);
  });
}

function initNoticeStrip(data: DashboardData) {
  if (data.cancelNotice === "pending") stripQueryParam("cancel");
  if (data.resumeNotice) stripQueryParam("resume");
}

function initCancelReload(data: DashboardData) {
  if (data.cancelNotice !== "immediate") return;

  if (data.tier === FREE_TIER) {
    stripQueryParam("cancel");
    window.location.reload();
    return;
  }

  void pollUntilTier(FREE_TIER).then((ready) => {
    if (ready) {
      stripQueryParam("cancel");
      window.location.reload();
    }
  });
}

function initPurchaseBanner(data: DashboardData) {
  if (!data.purchaseSuccess) return;

  stripQueryParam("purchase");
  bindDismiss();

  if (data.tier !== FREE_TIER) {
    setBannerMessage("Payment successful — your subscription is active.", false);
    window.setTimeout(() => {
      document.getElementById("purchase-status-banner")?.classList.add("hidden");
    }, 12_000);
    return;
  }

  setBannerMessage("Payment successful — activating your subscription…", true);

  void pollUntilNotFree().then((ready) => {
    if (ready) {
      setBannerMessage("Subscription updated.", false);
      window.setTimeout(() => window.location.reload(), 600);
      return;
    }
    setBannerMessage(
      "Payment received — your plan should appear shortly. Refresh if it does not update in a minute.",
      false
    );
  });
}

function init() {
  bindModal("cancel-subscription-btn", "cancel-subscription-modal", "data-cancel-dismiss");
  bindModal("resume-subscription-btn", "resume-subscription-modal", "data-resume-dismiss");

  const data = readData();
  if (!data) return;

  initNoticeStrip(data);
  initCancelReload(data);
  initPurchaseBanner(data);
}

init();
