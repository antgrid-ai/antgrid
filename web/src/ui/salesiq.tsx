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

export function salesIqSupportLauncher(user?: {
  id: string;
  email?: string | null;
}): Child {
  if (!widgetUrl) {
    return (
      <aside class="support-launcher" aria-label="Support">
        <a
          href="https://antgrid.ai/support?chat=1&source=account"
          class="support-launcher-button"
          aria-label="Chat with support"
          title="Chat with support"
        >
          <SupportIcon />
        </a>
      </aside>
    );
  }
  return (
    <aside class="support-launcher" aria-label="Support">
      <span class="support-launcher-status" data-salesiq-status role="status" aria-live="polite"></span>
      <button
        type="button"
        data-salesiq-open
        data-salesiq-widget-url={widgetUrl}
        data-salesiq-user-id={user?.id ?? ""}
        data-salesiq-user-email={user?.email ?? ""}
        class="support-launcher-button"
        aria-label="Chat with support"
        aria-expanded="false"
        title="Chat with support"
      >
        <SupportIcon />
        <CloseIcon />
      </button>
    </aside>
  );
}

function SupportIcon() {
  return (
    <svg class="support-launcher-icon support-launcher-icon-chat" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path d="M5.75 4.75h12.5a2.5 2.5 0 0 1 2.5 2.5v7.5a2.5 2.5 0 0 1-2.5 2.5h-6.1L7.5 20.5v-3.25H5.75a2.5 2.5 0 0 1-2.5-2.5v-7.5a2.5 2.5 0 0 1 2.5-2.5Z" />
      <path d="m7.5 9 2 2-2 2M12 13h4.5" />
    </svg>
  );
}

function CloseIcon() {
  return (
    <svg class="support-launcher-icon support-launcher-icon-close" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path d="m6.75 6.75 10.5 10.5M17.25 6.75 6.75 17.25" />
    </svg>
  );
}

export const SALESIQ_CONTROLLER_SCRIPT = `
(() => {
  let loading;
  // Zoho owns the open/closed state — it can close the window from inside the
  // iframe — so read it off the widget rather than tracking a local boolean.
  const chatIsOpen = () => !!document.querySelector("#zsiq_chat_wrap.chat-iframe-open");
  document.addEventListener("click", (event) => {
    const button = event.target.closest("[data-salesiq-open]");
    if (!button) return;
    const status = button.parentElement?.querySelector("[data-salesiq-status]");
    if (window.$zoho?.salesiq?.chatwindow) {
      const open = !chatIsOpen();
      window.$zoho.salesiq.chatwindow.visible(open ? "show" : "hide");
      button.setAttribute("aria-expanded", String(open));
      return;
    }
    if (loading) return;
    button.disabled = true;
    if (status) status.textContent = "Opening support chat…";
    window.$zoho = window.$zoho || {};
    window.$zoho.salesiq = window.$zoho.salesiq || { widgetcode: "siqwidget", values: {}, ready: function () {} };
    window.$zoho.salesiq.ready = function () {
      window.$zoho.salesiq.tracking?.off();
      window.$zoho.salesiq.floatbutton?.visible("hide");
      if (button.dataset.salesiqUserId) window.$zoho.salesiq.visitor?.id(button.dataset.salesiqUserId);
      if (button.dataset.salesiqUserEmail) window.$zoho.salesiq.visitor?.email(button.dataset.salesiqUserEmail);
      button.disabled = false;
      if (status) status.textContent = "";
      window.$zoho.salesiq.chatwindow?.visible("show");
      button.setAttribute("aria-expanded", "true");
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
      if (status) status.textContent = "Chat could not load. Open the support page to contact us.";
    });
  });
  document.addEventListener("submit", (event) => {
    if (event.target.matches("[data-salesiq-logout]")) window.$zoho?.salesiq?.reset?.();
  });
})();`;
