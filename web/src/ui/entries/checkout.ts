/**
 * Checkout client — billing modal on subscription page, then Paddle/Razorpay overlay.
 * Matches grisb-training: close wizard modal before opening payment SDK.
 *
 * This script never creates a transaction. The seat form does that server-side,
 * and the session it hands back is embedded in the page beside the total that
 * same call quoted — so the overlay opens the very transaction whose number the
 * buyer just read. A fetch here that created a second one would be a second
 * price.
 */
import { initializePaddle, type Paddle } from "@paddle/paddle-js";

type CheckoutPlan = {
  id: string;
  label: string;
  recurring: boolean;
  trial: boolean;
  workerLimit: number;
  displayPrice: number;
  chargePrice: number;
  discountLabel?: string;
};

type WizardData = {
  email: string;
  plan: CheckoutPlan;
  detectedCountry: string | null;
  gateway: "paddle" | "razorpay";
  readiness: Record<string, Record<string, boolean>>;
  seats: number;
  maxSeats: number;
  orderSeats: number | null;
};

type PaddleSession = {
  provider: "paddle";
  transactionId: string;
  clientToken: string;
  environment: "sandbox" | "production";
  customerAuthToken?: string;
};

type RazorpaySession = {
  provider: "razorpay";
  keyId: string;
  subscriptionId: string;
  shortUrl?: string;
  callbackUrl?: string;
  planId?: string;
};

type CheckoutSession = PaddleSession | RazorpaySession;

declare global {
  interface Window {
    Razorpay?: new (options: Record<string, unknown>) => {
      open(): void;
      on(event: string, cb: (response: Record<string, unknown>) => void): void;
    };
  }
}

const RAZORPAY_CHECKOUT_SDK = "https://checkout.razorpay.com/v1/checkout.js";

const RAZORPAY_CARD_ONLY_CONFIG = {
  display: {
    blocks: {
      cards_only: {
        name: "Pay via Card",
        instruments: [{ method: "card" }],
      },
    },
    sequence: ["block.cards_only"],
    preferences: { show_default_blocks: false },
  },
};

let paddleInstance: Paddle | undefined;
let razorpayScriptLoaded = false;

function loadScript(src: string): Promise<void> {
  return new Promise((resolve, reject) => {
    if (document.querySelector(`script[src="${src}"]`)) {
      resolve();
      return;
    }
    const s = document.createElement("script");
    s.src = src;
    s.onload = () => resolve();
    s.onerror = () => reject(new Error(`failed to load ${src}`));
    document.head.appendChild(s);
  });
}

async function loadRazorpayCheckoutSdk(): Promise<void> {
  if (razorpayScriptLoaded && window.Razorpay) return;
  await loadScript(RAZORPAY_CHECKOUT_SDK);
  razorpayScriptLoaded = true;
}

function readJson<T>(id: string): T | null {
  const el = document.getElementById(id);
  if (!el?.textContent) return null;
  try {
    return JSON.parse(el.textContent) as T;
  } catch {
    return null;
  }
}

function initCheckout(data: WizardData, session: CheckoutSession | null) {
  const plan = data.plan;
  let gateway = session?.provider ?? data.gateway;

  const params = new URLSearchParams(window.location.search);
  if (params.get("payment") === "success") {
    window.location.replace("/dashboard?purchase=success");
    return;
  }

  const btnPay = document.getElementById("btn-pay") as HTMLButtonElement;
  const btnReview = document.getElementById("btn-review") as HTMLButtonElement;
  const seatsInput = document.getElementById("seats-input") as HTMLInputElement;
  const seatForm = document.getElementById("seat-form") as HTMLFormElement;
  const seatCountry = document.getElementById("seat-country") as HTMLInputElement;
  const countrySelect = document.getElementById("billing-country") as HTMLSelectElement;
  const gatewayLabel = document.getElementById("gateway-label")!;
  const summaryDue = document.getElementById("summary-due")!;
  const footerDue = document.getElementById("footer-due")!;
  const totalNote = document.getElementById("summary-total-note")!;

  function gatewayReady(gw: string, planId: string): boolean {
    const byPlan = data.readiness[gw];
    return byPlan !== undefined && byPlan[planId] === true;
  }

  /** Mirrors the server's `anyCheckoutReady`. Recomputed here rather than read
   *  off the button's initial `disabled`, which also covers "no order yet" and
   *  would make the first quote look like a misconfigured deployment. */
  const checkoutAvailable = Object.values(data.readiness).some((byPlan) =>
    Object.values(byPlan).some((ready) => ready)
  );

  function setGatewayLabel(provider: "paddle" | "razorpay") {
    gateway = provider;
    gatewayLabel.textContent = provider === "razorpay" ? "Razorpay" : "Paddle";
  }

  function clampSeats(value: number): number {
    if (!Number.isFinite(value)) return 1;
    return Math.min(Math.max(Math.trunc(value), 1), data.maxSeats);
  }

  /** A total belongs to the seat count it was quoted for. The moment the two
   *  disagree the number on screen is about a transaction the buyer no longer
   *  wants, so it goes away together with the button that would pay it. */
  function syncSeatSelection() {
    const seats = clampSeats(Number.parseInt(seatsInput.value, 10));
    seatsInput.value = String(seats);
    const quoted = session !== null && data.orderSeats === seats;
    btnPay.disabled = !quoted || !checkoutAvailable;
    btnReview.textContent = quoted ? "Update total" : "Review order";
    if (!quoted) {
      summaryDue.textContent = "—";
      footerDue.textContent = "—";
      totalNote.textContent = "Your total is quoted when you review the order.";
    }
  }

  countrySelect.addEventListener("change", () => {
    const code = countrySelect.value;
    seatCountry.value = code;
    if (!code) return;
    fetch("/billing/confirm-country", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ country: code }),
    })
      .then((res) => res.json())
      .then((body: { provider?: string }) => {
        if (body.provider === "paddle" || body.provider === "razorpay") {
          setGatewayLabel(body.provider);
        }
      })
      .catch(() => {});
  });

  if (data.detectedCountry && countrySelect.value !== data.detectedCountry) {
    countrySelect.value = data.detectedCountry;
    gateway = data.gateway;
  }
  seatCountry.value = countrySelect.value;

  document.getElementById("seats-dec")!.addEventListener("click", () => {
    seatsInput.value = String(clampSeats(Number.parseInt(seatsInput.value, 10) - 1));
    syncSeatSelection();
  });
  document.getElementById("seats-inc")!.addEventListener("click", () => {
    seatsInput.value = String(clampSeats(Number.parseInt(seatsInput.value, 10) + 1));
    syncSeatSelection();
  });
  seatsInput.addEventListener("change", syncSeatSelection);

  seatForm.addEventListener("submit", () => {
    if (!countrySelect.value) return;
    btnReview.classList.add("loading");
  });

  function setCheckoutStatus(msg: string, showSpinner: boolean) {
    const content = document.getElementById("checkout-status-content")!;
    const text = document.getElementById("checkout-status-text")!;
    const spinner = document.getElementById("checkout-spinner")!;
    content.classList.remove("hidden");
    text.textContent = msg;
    spinner.classList.toggle("hidden", !showSpinner);
  }

  function hideCheckoutStatus() {
    document.getElementById("checkout-status-content")!.classList.add("hidden");
  }

  function setPayButtonLoading(loading: boolean) {
    btnPay.classList.toggle("loading", loading);
    if (loading) {
      btnPay.disabled = true;
      return;
    }
    syncSeatSelection();
  }

  function redirectSuccess() {
    window.location.href = "/dashboard?purchase=success";
  }

  /** Close billing wizard so subscription page shows behind Razorpay/Paddle (grisb pattern). */
  function hideCheckoutModal() {
    const modal = document.getElementById("checkout-modal");
    if (!modal) return;
    modal.classList.remove("modal-open");
    modal.classList.add("hidden");
  }

  function showCheckoutModal() {
    const modal = document.getElementById("checkout-modal");
    if (!modal) return;
    modal.classList.remove("hidden");
    modal.classList.add("modal-open");
  }

  function onPaymentDismissed(msg = "Checkout closed.") {
    document.body.classList.remove("checkout-payment-active");
    setPayButtonLoading(false);
    showCheckoutModal();
    setCheckoutStatus(msg, false);
    document.getElementById("checkout-retry")!.classList.remove("hidden");
  }

  /** Razorpay injects backdrop after open(); patch it for transparent blur on dark theme. */
  function patchRazorpayBackdrop() {
    const apply = () => {
      for (const el of document.querySelectorAll<HTMLElement>(".razorpay-backdrop")) {
        el.style.background = "rgb(9 9 11 / 55%)";
        el.style.backdropFilter = "blur(8px)";
        el.style.setProperty("-webkit-backdrop-filter", "blur(8px)");
      }
    };
    apply();
    const obs = new MutationObserver(apply);
    obs.observe(document.body, { childList: true, subtree: true });
    window.setTimeout(() => obs.disconnect(), 10_000);
  }

  function beginPaymentOverlay() {
    document.body.classList.add("checkout-payment-active");
    hideCheckoutModal();
    patchRazorpayBackdrop();
  }

  async function openRazorpaySession(rzpSession: RazorpaySession) {
    await loadRazorpayCheckoutSdk();
    if (!window.Razorpay) throw new Error("Razorpay checkout SDK failed to load");

    beginPaymentOverlay();

    const options: Record<string, unknown> = {
      key: rzpSession.keyId,
      name: "antgrid",
      description: rzpSession.planId || plan.id,
      prefill: { email: data.email },
      theme: { color: "#D2542A" },
      config: RAZORPAY_CARD_ONLY_CONFIG,
      redirect: false,
      ...(rzpSession.callbackUrl ? { callback_url: rzpSession.callbackUrl } : {}),
      modal: {
        ondismiss: () => onPaymentDismissed(),
      },
      // Subscriptions provision from the webhook, so the client only redirects.
      handler: () => redirectSuccess(),
      subscription_id: rzpSession.subscriptionId,
    };

    const rzp = new window.Razorpay(options);
    rzp.on("payment.failed", (response) => {
      const err = response.error as { description?: string } | undefined;
      onPaymentDismissed(err?.description || "Payment failed.");
    });
    rzp.open();
  }

  async function openPaddleSession(paddleSession: PaddleSession) {
    if (!paddleInstance) {
      paddleInstance = await initializePaddle({
        token: paddleSession.clientToken,
        environment: paddleSession.environment,
        checkout: {
          settings: { displayMode: "overlay", theme: "dark", locale: "en", variant: "one-page" },
        },
        eventCallback: (event) => {
          if (event.name === "checkout.completed") redirectSuccess();
          if (event.name === "checkout.closed" && event.data?.status !== "completed") {
            onPaymentDismissed();
          }
        },
      });
    }
    if (!paddleInstance) throw new Error("Paddle checkout SDK failed to initialize");

    beginPaymentOverlay();

    // customerAuthToken and customer.email are mutually exclusive in Paddle.js.
    if (paddleSession.customerAuthToken) {
      paddleInstance.Checkout.open({
        transactionId: paddleSession.transactionId,
        customerAuthToken: paddleSession.customerAuthToken,
      });
    } else {
      const openOpts: { transactionId: string; customer?: { email: string } } = {
        transactionId: paddleSession.transactionId,
      };
      if (data.email) openOpts.customer = { email: data.email };
      paddleInstance.Checkout.open(openOpts);
    }
  }

  async function openCheckout() {
    if (!session) return;
    setPayButtonLoading(true);
    hideCheckoutStatus();
    document.getElementById("checkout-retry")!.classList.add("hidden");
    try {
      setGatewayLabel(session.provider);
      setPayButtonLoading(false);
      if (session.provider === "razorpay") await openRazorpaySession(session);
      else await openPaddleSession(session);
    } catch (e) {
      setPayButtonLoading(false);
      showCheckoutModal();
      const msg = e instanceof Error ? e.message : String(e);
      setCheckoutStatus(`Unexpected error: ${msg}`, false);
      document.getElementById("checkout-retry")!.classList.remove("hidden");
    }
  }

  btnPay.addEventListener("click", () => {
    if (!countrySelect.value) {
      countrySelect.focus();
      countrySelect.classList.add("select-error");
      return;
    }
    countrySelect.classList.remove("select-error");
    if (!gatewayReady(gateway, plan.id)) {
      setCheckoutStatus(
        gateway === "razorpay"
          ? "Razorpay is not configured for this plan."
          : "Paddle is not configured for this plan.",
        false
      );
      return;
    }
    document.getElementById("checkout-retry")!.classList.add("hidden");
    void openCheckout();
  });

  document.getElementById("checkout-retry")!.addEventListener("click", () => {
    hideCheckoutStatus();
    btnPay.click();
  });

  syncSeatSelection();
}

const wizard = readJson<WizardData>("checkout-wizard-data");
if (wizard) {
  initCheckout(wizard, readJson<CheckoutSession>("checkout-session-data"));
}
