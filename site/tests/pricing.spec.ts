import { test, expect, type Page } from "@playwright/test";

// The founding-price capture, which is the only thing on this page that DOES
// anything. The figures it sits beside are not asserted here: they come from
// src/data/pricing.ts, which is pinned to the shipped catalog by
// web/tests/billing/site-pricing-lockstep.test.ts — a number that is wrong is
// caught against the catalog, not against a copy of itself. CTA wiring and the
// closed paid path are in contracts.spec.ts.

const capture = (page: Page) =>
  page.locator("span.font-mono", { hasText: /^Pro$/ }).locator("..").locator("..").locator("form[data-waitlist]");

test("the capture is a usable email control before anything is typed", async ({ page }) => {
  await page.goto("/pricing");
  const form = capture(page);

  // The accessibility floor, all of it behaviour: a real label to find the field
  // by, the type that gets a keyboard an @ key, a live region for the reply, and
  // a control that is not already inert. It ships disabled for a scriptless
  // reader, so a still-disabled button here means the page's script never ran.
  const field = form.getByLabel(/email address/i);
  await expect(field).toHaveAttribute("type", "email");
  await expect(form.locator("[aria-live]")).toHaveCount(1);
  await expect(form.getByRole("button", { name: /^Join the list$/ })).toBeEnabled();
});

test("joining posts the address with the surface it came from", async ({ page }) => {
  const posted: unknown[] = [];
  await page.route("**/api/waitlist", async (route) => {
    posted.push(route.request().postDataJSON());
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "access-control-allow-origin": "*" },
      body: JSON.stringify({ ok: true }),
    });
  });

  await page.goto("/pricing");
  const form = capture(page);
  await form.getByLabel(/email address/i).fill("founder@example.com");
  await form.getByRole("button", { name: /^Join the list$/ }).click();

  // The payload is the contract with the web service — `source` is what tells
  // pricing leads apart from every other capture surface.
  await expect(form.getByRole("button", { name: /^Joined$/ })).toBeVisible();
  expect(posted).toEqual([{ email: "founder@example.com", source: "pricing" }]);
});

test("the control is inert while the address is in flight", async ({ page }) => {
  let release = () => {};
  const held = new Promise<void>((resolve) => (release = resolve));
  await page.route("**/api/waitlist", async (route) => {
    await held;
    await route.fulfill({
      status: 200,
      headers: { "content-type": "application/json", "access-control-allow-origin": "*" },
      body: JSON.stringify({ ok: true }),
    });
  });

  await page.goto("/pricing");
  const form = capture(page);
  await form.getByLabel(/email address/i).fill("founder@example.com");
  await form.getByRole("button", { name: /^Join the list$/ }).click();

  // Disabled mid-flight or an impatient second click posts the address twice.
  await expect(form.getByRole("button", { name: /^Joining/ })).toBeDisabled();
  release();
  await expect(form.getByRole("button", { name: /^Joined$/ })).toBeVisible();
});

test("a malformed address is refused at the field, before anything is sent", async ({ page }) => {
  let requests = 0;
  await page.route("**/api/waitlist", async (route) => {
    requests += 1;
    await route.fulfill({ status: 200, headers: { "access-control-allow-origin": "*" }, body: "{}" });
  });

  await page.goto("/pricing");
  const form = capture(page);
  await form.getByLabel(/email address/i).fill("founder@");
  await form.getByRole("button", { name: /^Join the list$/ }).click();

  expect(requests, "a malformed address reached the network").toBe(0);
  // And the reader is left able to fix it, rather than dead-ended the way the
  // button this replaced was.
  await expect(form.getByRole("button", { name: /^Join the list$/ })).toBeEnabled();
});

test("a rejected address leaves the reader able to retry", async ({ page }) => {
  // The API answers a rejection with a machine code. Leaking it verbatim is a
  // behaviour, not a wording preference: "BAD_REQUEST" tells the reader nothing
  // they can act on, so the page owes them its own sentence.
  await page.route("**/api/waitlist", async (route) => {
    await route.fulfill({
      status: 400,
      headers: { "content-type": "application/json", "access-control-allow-origin": "*" },
      body: JSON.stringify({ ok: false, error: "BAD_REQUEST" }),
    });
  });

  await page.goto("/pricing");
  const form = capture(page);
  await form.getByLabel(/email address/i).fill("founder@example.com");
  await form.getByRole("button", { name: /^Join the list$/ }).click();

  await expect(form.locator("[aria-live]")).not.toContainText("BAD_REQUEST");
  await expect(form.getByRole("button", { name: /^Join the list$/ })).toBeEnabled();
  await expect(form.getByLabel(/email address/i)).toBeEditable();
});

// Machine-read, so it is a contract rather than content: a malformed blob is
// invisible on the page and silently costs the FAQ rich result.
test("the FAQ ships structured data a crawler can parse", async ({ page }) => {
  await page.goto("/pricing");
  const raw = await page.locator('script[type="application/ld+json"]').last().textContent();
  const schema = JSON.parse(raw ?? "");
  expect(schema["@type"]).toBe("FAQPage");
  expect(schema.mainEntity.length).toBeGreaterThan(0);
});
