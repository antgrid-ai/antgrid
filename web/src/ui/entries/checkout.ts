/**
 * Checkout client — billing modal on subscription page, then Paddle/Razorpay overlay.
 * Matches grisb-training: close wizard modal before opening payment SDK.
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
  isSubscription: boolean;
  subscriptionId?: string;
  shortUrl?: string;
  callbackUrl?: string;
  orderId?: string;
  amount?: number;
  currency?: string;
  planId?: string;
};

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

function initCheckout(data: WizardData) {
  const plan = data.plan;
  let gateway = data.gateway;

  const params = new URLSearchParams(window.location.search);
  if (params.get("payment") === "success") {
    window.location.replace("/dashboard?purchase=success");
    return;
  }

  const btnPay = document.getElementById("btn-pay")!;
  const countrySelect = document.getElementById("billing-country") as HTMLSelectElement;
  const gatewayLabel = document.getElementById("gateway-label")!;
  const payDisabledInitially = btnPay.hasAttribute("disabled");

  function gatewayReady(gw: string, planId: string) {
    const byPlan = data.readiness[gw];
    return byPlan && byPlan[planId] === true;
  }

  function setGatewayLabel(provider: "paddle" | "razorpay") {
    gateway = provider;
    gatewayLabel.textContent = provider === "razorpay" ? "Razorpay" : "Paddle";
  }

  countrySelect.addEventListener("change", () => {
    const code = countrySelect.value;
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
      btnPay.setAttribute("disabled", "");
      return;
    }
    if (payDisabledInitially) btnPay.setAttribute("disabled", "");
    else btnPay.removeAttribute("disabled");
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

  if (params.get("payment") === "failed") {
    onPaymentDismissed("Payment failed or was cancelled. Try again.");
  }

  async function verifyRazorpayOrderPayment(args: {
    orderId: string;
    paymentId: string;
    signature: string;
  }) {
    const res = await fetch("/billing/verify-payment", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        provider: "razorpay",
        orderId: args.orderId,
        paymentId: args.paymentId,
        signature: args.signature,
      }),
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      throw new Error((err as { error?: string }).error || `verify failed (${res.status})`);
    }
  }


  async function openRazorpaySession(session: RazorpaySession) {
    await loadRazorpayCheckoutSdk();
    if (!window.Razorpay) throw new Error("Razorpay checkout SDK failed to load");

    beginPaymentOverlay();

    const options: Record<string, unknown> = {
      key: session.keyId,
      name: "antgrid",
      description: session.planId || plan.id,
      prefill: { email: data.email },
      theme: { color: "#818CF8" },
      config: RAZORPAY_CARD_ONLY_CONFIG,
      redirect: false,
      ...(session.callbackUrl ? { callback_url: session.callbackUrl } : {}),
      modal: {
        ondismiss: () => onPaymentDismissed(),
      },
      handler: async (response: Record<string, string>) => {
        try {
          if (session.isSubscription) {
            redirectSuccess();
            return;
          }
          const orderId = response.razorpay_order_id;
          const paymentId = response.razorpay_payment_id;
          const signature = response.razorpay_signature;
          if (!orderId || !paymentId || !signature) {
            throw new Error("Incomplete payment response");
          }
          setCheckoutStatus("Confirming payment…", true);
          showCheckoutModal();
          await verifyRazorpayOrderPayment({ orderId, paymentId, signature });
          redirectSuccess();
        } catch (e) {
          showCheckoutModal();
          const msg = e instanceof Error ? e.message : String(e);
          setCheckoutStatus(`Payment verification failed: ${msg}`, false);
          document.getElementById("checkout-retry")!.classList.remove("hidden");
        }
      },
    };

    if (session.isSubscription) {
      options.subscription_id = session.subscriptionId;
    } else {
      options.order_id = session.orderId;
      options.amount = session.amount;
      options.currency = session.currency || "USD";
    }

    const rzp = new window.Razorpay(options);
    rzp.on("payment.failed", (response) => {
      const err = response.error as { description?: string } | undefined;
      onPaymentDismissed(err?.description || "Payment failed.");
    });
    rzp.open();
  }

  async function openPaddleSession(session: PaddleSession) {
    if (!paddleInstance) {
      paddleInstance = await initializePaddle({
        token: session.clientToken,
        environment: session.environment,
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
    if (session.customerAuthToken) {
      paddleInstance.Checkout.open({
        transactionId: session.transactionId,
        customerAuthToken: session.customerAuthToken,
      });
    } else {
      const openOpts: { transactionId: string; customer?: { email: string } } = {
        transactionId: session.transactionId,
      };
      if (data.email) openOpts.customer = { email: data.email };
      paddleInstance.Checkout.open(openOpts);
    }
  }

  async function openCheckout() {
    setPayButtonLoading(true);
    hideCheckoutStatus();
    document.getElementById("checkout-retry")!.classList.add("hidden");
    try {
      const res = await fetch("/billing/checkout-session", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ planId: plan.id, country: countrySelect.value }),
      });
      if (!res.ok) {
        const err = await res.json().catch(() => ({}));
        setPayButtonLoading(false);
        setCheckoutStatus(
          `Could not start payment: ${(err as { error?: string }).error || res.status}`,
          false
        );
        document.getElementById("checkout-retry")!.classList.remove("hidden");
        return;
      }
      const session = (await res.json()) as PaddleSession | RazorpaySession;
      gateway = session.provider;
      gatewayLabel.textContent = session.provider === "razorpay" ? "Razorpay" : "Paddle";
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
}

const dataEl = document.getElementById("checkout-wizard-data");
if (dataEl?.textContent) {
  initCheckout(JSON.parse(dataEl.textContent) as WizardData);
}
