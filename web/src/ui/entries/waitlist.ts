/**
 * Founding-price waitlist capture on /pricing.
 *
 * Not htmx: the target is the public JSON endpoint the marketing site posts to
 * as well (POST /api/waitlist), so there is no fragment to swap and no redirect
 * to follow — the same reason entries/devices.ts issues its own request rather
 * than going through the vendored htmx bundle.
 */

const IDLE_NOTE = "Founding pricing at launch.";

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
    return "That address isn't a valid email. Correct it and submit again.";
  }
  if (status === 429) {
    return "Too many submissions from this network. Wait a minute, then submit again.";
  }
  return `The server rejected the request (HTTP ${status}). Submit again in a moment.`;
}

function setStatus(message: string, tone: Tone) {
  const el = document.getElementById("waitlist-status");
  if (!el) return;
  el.textContent = message;
  el.className = `${STATUS_BASE} ${STATUS_TONE[tone]}`;
}

let inFlight = false;

async function submit(form: HTMLFormElement) {
  const input = document.getElementById("waitlist-email");
  const button = document.getElementById("waitlist-submit");
  if (
    inFlight ||
    !(input instanceof HTMLInputElement) ||
    !(button instanceof HTMLButtonElement)
  ) {
    return;
  }

  inFlight = true;
  button.disabled = true;
  const idleLabel = button.textContent;
  button.textContent = "Joining…";
  setStatus(IDLE_NOTE, "idle");

  try {
    const res = await fetch(form.action, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        email: input.value,
        source: form.dataset.waitlistSource,
      }),
    });
    if (!res.ok) {
      setStatus(messageForStatus(res.status), "error");
      return;
    }
    // The endpoint answers identically for an address already on the list, so
    // there is nothing to tell apart here — and telling them apart is exactly
    // what it refuses to leak.
    form.hidden = true;
    setStatus(SUCCESS_NOTE, "ok");
  } catch {
    setStatus(
      "The request never reached the server. Check your connection and submit again.",
      "error",
    );
  } finally {
    inFlight = false;
    button.disabled = false;
    button.textContent = idleLabel;
  }
}

function init() {
  const form = document.getElementById("waitlist-form");
  if (!(form instanceof HTMLFormElement)) return;
  // The form's own `action`/`method` name the real target, but submission is
  // always intercepted: the endpoint reads a JSON body and would answer a
  // urlencoded post with the 400 this handler exists to avoid.
  form.addEventListener("submit", (ev) => {
    ev.preventDefault();
    void submit(form);
  });
}

init();

export {};
