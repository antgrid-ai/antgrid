/**
 * Revoke confirmation for the devices page.
 *
 * Replaces `hx-confirm`, which htmx implements with the browser's native
 * `window.confirm`. The row button carries no `hx-*` attributes at all — this
 * script issues the DELETE itself once the user confirms, then drops the row.
 *
 * Deliberately does NOT go through htmx: Vite bundles `htmx.org/dist/htmx.min.js`
 * as an ES module, so htmx initializes and processes `hx-*` attributes but never
 * assigns `window.htmx`. Reaching for that global made the Revoke button a
 * silent no-op. The endpoint returns an empty body, so the swap htmx would have
 * performed is just `row.remove()` — not worth a dependency on how the vendor
 * bundle happens to expose itself.
 */

type PendingRevoke = { url: string; target: string };

let pending: PendingRevoke | null = null;
let inFlight = false;

function byId(id: string): HTMLElement | null {
  return document.getElementById(id);
}

function setError(message: string) {
  const el = byId("revoke-device-error");
  if (!el) return;
  el.textContent = message;
  el.classList.toggle("hidden", message === "");
}

function close() {
  pending = null;
  setError("");
  byId("revoke-device-modal")?.classList.remove("modal-open");
}

function open(button: HTMLElement) {
  const url = button.dataset.revokeUrl;
  const target = button.dataset.revokeTarget;
  const el = byId("revoke-device-modal");
  if (!url || !target || !el) return;

  pending = { url, target };
  setError("");
  const name = byId("revoke-device-name");
  // textContent, never innerHTML — displayName is user-supplied.
  if (name) name.textContent = button.dataset.revokeName || "This device";
  // Distinguishes rows that share a display name; see RevokeDeviceModal.
  const meta = byId("revoke-device-meta");
  if (meta) meta.textContent = button.dataset.revokeMeta ?? "";
  el.classList.add("modal-open");
  byId("revoke-device-confirm")?.focus();
}

async function confirmRevoke() {
  const target = pending;
  // The row is removed on success, so a double-click must not fire a second
  // DELETE against an id that is already gone.
  if (!target || inFlight) return;
  inFlight = true;
  setError("");

  try {
    const res = await fetch(target.url, {
      method: "DELETE",
      credentials: "same-origin",
      headers: { "x-requested-with": "fetch" },
    });
    if (!res.ok) {
      // Never fail silently — a revoke that did nothing must say so, or the
      // device looks cut off while it is still live on the account.
      setError(
        res.status === 404
          ? "That device is already revoked. Reload the page."
          : `Could not revoke (HTTP ${res.status}). Try again.`,
      );
      return;
    }
    document.querySelector(target.target)?.remove();
    close();
  } catch {
    setError("Could not reach the server. Check your connection and try again.");
  } finally {
    inFlight = false;
  }
}

function init() {
  // Delegated: rows disappear as they are revoked, and the table is re-rendered
  // server-side on navigation — nothing here should hold a per-row listener.
  document.addEventListener("click", (ev) => {
    const el = ev.target as HTMLElement | null;
    const trigger = el?.closest<HTMLElement>("[data-revoke-url]");
    if (trigger) {
      ev.preventDefault();
      open(trigger);
      return;
    }
    if (el?.closest("[data-revoke-dismiss]")) {
      ev.preventDefault();
      close();
      return;
    }
    if (el?.closest("#revoke-device-confirm")) {
      ev.preventDefault();
      void confirmRevoke();
    }
  });

  document.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape" && pending) close();
  });
}

init();

export {};
