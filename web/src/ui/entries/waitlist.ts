/**
 * Founding-price waitlist capture on /pricing.
 *
 * Not htmx: the target is the public JSON endpoint the marketing site posts to
 * as well (POST /api/waitlist), so there is no fragment to swap and no redirect
 * to follow — the same reason entries/devices.ts issues its own request rather
 * than going through the vendored htmx bundle.
 */

const IDLE_LABEL = "Join the waitlist";
const BUSY_LABEL = "Joining…";
const DONE_LABEL = "Joined";

/** Confirms in the button's own words. "Submitted" would leave the reader
 *  guessing whether the thing they joined is the thing that answered. */
const SUCCESS_NOTE = "You're on the waitlist. Founding pricing at launch.";

const STATUS_BASE = "text-xs text-center mt-3 min-h-10";
const STATUS_TONE = {
  idle: "text-faint",
  ok: "text-ink2",
  error: "text-error",
} as const;

type Tone = keyof typeof STATUS_TONE;

/**
 * The endpoint answers a bare code, and a code is not an instruction — each
 * status has to say what the server did with the address and what the reader
 * does next. No apology: nothing here is broken, and "sorry" would be the only
 * word in the sentence that carries no information.
 */
function messageForStatus(status: number): string {
  if (status === 400) {
    return "That address wasn't accepted. Check it and submit again.";
  }
  if (status === 429) {
    return "Too many submissions from this network. Wait a minute, then submit again.";
  }
  // A 2xx that did not carry `ok` is not a rejection — something in front of the
  // endpoint answered instead of it, and quoting its status would explain nothing.
  if (status < 400) {
    return "The waitlist didn't answer. Submit again in a moment.";
  }
  return `The server rejected the request (HTTP ${status}). Submit again in a moment.`;
}

// The status line sits OUTSIDE the form, so it is reached through the card
// wrapper rather than the form — everything else is scoped to the form itself,
// which is what lets a second card on the page drive its own controls.
function bind(form: HTMLFormElement): void {
  const input = form.querySelector<HTMLInputElement>('input[type="email"]');
  const button = form.querySelector<HTMLButtonElement>("[data-waitlist-submit]");
  const status = form
    .closest("[data-waitlist-card]")
    ?.querySelector<HTMLElement>("[data-waitlist-status]");
  if (!input || !button || !status) return;

  const setStatus = (message: string, tone: Tone) => {
    status.textContent = message;
    status.className = `${STATUS_BASE} ${STATUS_TONE[tone]}`;
  };

  const toIdle = () => {
    button.disabled = false;
    button.textContent = IDLE_LABEL;
  };

  // Disabling the control a reader just activated blurs it and focus falls to
  // <body>, so their next Tab restarts at the top of the page. Reclaim it only if
  // that is in fact where it went — someone who tabbed on keeps their place. Not
  // folded into toIdle(), which also runs at bind time, when focus is legitimately
  // on <body> and stealing it would scroll the page to this card on load.
  const reclaimFocus = (el: HTMLElement) => {
    if (document.activeElement === document.body) el.focus();
  };

  // The markup ships it disabled so a page whose script never ran cannot fire a
  // native urlencoded POST at a JSON endpoint. Enabling it here is what says the
  // handler below is attached.
  toIdle();

  form.addEventListener("submit", (ev) => {
    ev.preventDefault();
    // `disabled` is the whole re-entry guard: it blocks the click and the
    // Enter-key implicit submit alike, and it survives the success path, which
    // is terminal.
    if (button.disabled) return;

    button.disabled = true;
    button.textContent = BUSY_LABEL;

    void (async () => {
      try {
        const res = await fetch(form.action, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            email: input.value.trim(),
            source: form.dataset.waitlist,
          }),
        });
        // `ok` is checked on the body as well as the status: a 200 from anything
        // that is not this endpoint (a maintenance page, an error interstitial)
        // must not be reported to the reader as a signup that was stored.
        const body = (await res.json().catch(() => null)) as { ok?: boolean } | null;

        if (res.ok && body?.ok) {
          // The endpoint answers identically for an address already on the list,
          // so there is nothing to tell apart here — and telling them apart is
          // exactly what it refuses to leak.
          input.readOnly = true;
          button.textContent = DONE_LABEL;
          setStatus(SUCCESS_NOTE, "ok");
          // The button stays disabled for good on this path, so the blur above is
          // permanent unless focus is placed somewhere. The input is the landing
          // spot rather than the status line: still focusable when read-only, it
          // sits before the message in tab order, and aria-describedby already
          // points at that message.
          reclaimFocus(input);
          return;
        }

        setStatus(messageForStatus(res.status), "error");
        toIdle();
        reclaimFocus(button);
      } catch {
        setStatus(
          "The request never reached the server. Check your connection and submit again.",
          "error",
        );
        toIdle();
        reclaimFocus(button);
      }
    })();
  });
}

for (const form of document.querySelectorAll<HTMLFormElement>("form[data-waitlist]")) {
  bind(form);
}

export {};
