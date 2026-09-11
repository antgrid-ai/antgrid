import type { Child } from "hono/jsx";

let widgetUrl = "";

export function setSalesIqWidgetUrl(value: string | undefined): void {
  if (!value) {
    widgetUrl = "";
    return;
  }
  try {
    const parsed = new URL(value);
    widgetUrl = parsed.protocol === "https:" ? parsed.toString() : "";
  } catch {
    widgetUrl = "";
  }
}

export function salesIqSupportControl(user: {
  id: string;
  email?: string | null;
}): Child {
  if (!widgetUrl) {
    return (
      <a
        href="https://antgrid.ai/support?chat=1&source=account"
        class="flex items-center gap-2.5 rounded-field px-2.5 py-2 text-sm text-ink2 hover:bg-chrome hover:text-ink"
      >
        <SupportIcon />
        Support
      </a>
    );
  }
  return (
    <button
      type="button"
      data-salesiq-open
      data-salesiq-widget-url={widgetUrl}
      data-salesiq-user-id={user.id ?? ""}
      data-salesiq-user-email={user.email ?? ""}
      class="flex w-full items-center gap-2.5 rounded-field px-2.5 py-2 text-sm text-ink2 hover:bg-chrome hover:text-ink"
    >
      <SupportIcon />
      Support
    </button>
  );
}

function SupportIcon() {
  return (
    <svg class="h-4 w-4 shrink-0 text-muted2" viewBox="0 0 16 16" fill="none" aria-hidden="true">
      <path d="M3 7.5a5 5 0 0110 0v3.25A1.25 1.25 0 0111.75 12H10v-4h3M3 8h3v4H4.25A1.25 1.25 0 013 10.75V7.5zM10 13.5H7.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
  );
}

export const SALESIQ_CONTROLLER_SCRIPT = `
(() => {
  let loading;
  document.addEventListener("click", (event) => {
    const button = event.target.closest("[data-salesiq-open]");
    if (!button) return;
    const show = () => window.$zoho?.salesiq?.chatwindow?.visible("show");
    if (window.$zoho?.salesiq?.chatwindow) return show();
    if (loading) return;
    button.disabled = true;
    window.$zoho = window.$zoho || {};
    window.$zoho.salesiq = window.$zoho.salesiq || { widgetcode: "siqwidget", values: {}, ready: function () {} };
    window.$zoho.salesiq.ready = function () {
      window.$zoho.salesiq.tracking?.off();
      window.$zoho.salesiq.floatbutton?.visible("hide");
      if (button.dataset.salesiqUserId) window.$zoho.salesiq.visitor?.id(button.dataset.salesiqUserId);
      if (button.dataset.salesiqUserEmail) window.$zoho.salesiq.visitor?.email(button.dataset.salesiqUserEmail);
      button.disabled = false;
      show();
    };
    const script = document.createElement("script");
    script.id = "zsiqscript";
    script.src = button.dataset.salesiqWidgetUrl;
    script.defer = true;
    loading = new Promise((resolve, reject) => {
      script.onload = resolve;
      script.onerror = reject;
      document.head.appendChild(script);
    }).catch(() => {
      script.remove();
      loading = undefined;
      button.disabled = false;
    });
  });
  document.addEventListener("submit", (event) => {
    if (event.target.matches("[data-salesiq-logout]")) window.$zoho?.salesiq?.reset?.();
  });
})();`;
