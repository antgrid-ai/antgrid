import { test, expect, type Page } from "@playwright/test";

// Prices and the tier axis. KEEP IN LOCKSTEP with src/data/pricing.ts, which is itself
// pinned to the shipped catalog by web/tests/billing/site-pricing-lockstep.test.ts —
// this file only proves the page renders what that file says, so a number that is wrong
// in both is caught over there, not here. CTA wiring and the closed paid path are
// asserted in contracts.spec.ts — a wrong number here is a pricing bug, a wrong link
// there is a revenue bug, and they should not be able to mask each other.

test("pricing is sold on the seat axis", async ({ page }) => {
  await page.goto("/pricing");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(/priced per person/i);
});

test("plan cards carry the real prices, machine allowances and seat ceiling", async ({ page }) => {
  await page.goto("/pricing");

  // Locate each plan card by its heading span (font-mono text-ink inside the card).
  // Using .locator("..") to go up to the card root so price assertions stay within one card.
  const freeCard = page.locator("span.font-mono", { hasText: /^Free$/ }).locator("..").locator("..");
  const yearlyCard = page.locator("span.font-mono", { hasText: /^Pro$/ }).locator("..").locator("..");

  await expect(freeCard.locator("[data-price]", { hasText: "$0" })).toBeVisible();
  await expect(freeCard.getByText("1 worker machine")).toBeVisible();

  // Yearly card: $49 founding price (the headline figure) and $99 named as the
  // price at launch. The unit is part of the claim, so it is asserted beside the
  // number. $99 must never render as a struck-through former price — it has never
  // been charged, so a crossed-out "was" would be a reference price we invented.
  await expect(yearlyCard.locator("[data-price]", { hasText: "$49" })).toBeVisible();
  await expect(yearlyCard.locator("[data-list]", { hasText: "$99" })).toBeVisible();
  await expect(yearlyCard.getByText(/Founding price/)).toBeVisible();
  await expect(yearlyCard.locator("s, del, .line-through")).toHaveCount(0);
  await expect(yearlyCard.getByText("/ seat / year")).toBeVisible();
  await expect(yearlyCard.getByText("Up to 10 worker machines per person")).toBeVisible();
  await expect(yearlyCard.getByText(/Up to 25 seats/)).toBeVisible();
});

// Founding-price capture. The paid card's CTA is an interest form, not a checkout —
// contracts.spec.ts pins its target and the closed paid path; these cover what the
// reader actually experiences at the control.

const capture = (page: Page) =>
  page.locator("span.font-mono", { hasText: /^Pro$/ }).locator("..").locator("..").locator("form[data-waitlist]");

test("the capture asks for an address without naming a price", async ({ page }) => {
  await page.goto("/pricing");
  const form = capture(page);

  // The waitlist trades on "founding pricing", never on a figure or a struck anchor —
  // an address is not consent to a price.
  await expect(form).not.toContainText("$");
  await expect(form.locator("s, del, .line-through")).toHaveCount(0);

  // Accessibility floor: a real label (visually hidden is fine), an email field, and a
  // status line the reader's screen reader is told about.
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

  // One verb throughout: the button says Join, so the confirmation says joined.
  await expect(form.locator("[aria-live]")).toContainText(/joined the list/i);
  await expect(form.getByRole("button", { name: /^Joined$/ })).toBeVisible();
  expect(posted).toEqual([{ email: "founder@example.com", source: "pricing" }]);
});

test("the control says it is working while the address is in flight", async ({ page }) => {
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

  // Same verb in every state, so the reader never wonders whether a second thing
  // happened: Join -> Joining -> Joined.
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

  await expect(form.locator("[aria-live]")).toContainText(/does not look like an email address/i);
  // The error says what to do next and leaves the control usable, rather than
  // dead-ending the way the button it replaced did.
  await expect(form.locator("[aria-live]")).toContainText(/try again/i);
  await expect(form.getByRole("button", { name: /^Join the list$/ })).toBeEnabled();
  expect(requests).toBe(0);
});

test("a rejected address explains itself and leaves the reader able to retry", async ({ page }) => {
  // The API answers a rejection with a machine code, so the page owes the reader
  // its own sentence — echoing "BAD_REQUEST" back at them is not an explanation.
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

  const status = form.locator("[aria-live]");
  await expect(status).toContainText(/not accepted/i);
  await expect(status).toContainText(/try again/i);
  await expect(status).not.toContainText("BAD_REQUEST");
  await expect(form.getByRole("button", { name: /^Join the list$/ })).toBeEnabled();
  await expect(form.getByLabel(/email address/i)).toBeEditable();
});

test("the FAQ answers the seat and machine questions in place", async ({ page }) => {
  await page.goto("/pricing");
  await expect(page.getByRole("heading", { name: /what counts as a seat\?/i })).toBeVisible();
  await expect(page.getByRole("heading", { name: /what counts as a worker machine\?/i })).toBeVisible();

  // The FAQPage schema ships with the questions so the two cannot answer differently;
  // a malformed blob is invisible on the page and costs the rich result.
  const raw = await page.locator('script[type="application/ld+json"]').last().textContent();
  const schema = JSON.parse(raw ?? "");
  expect(schema["@type"]).toBe("FAQPage");
  expect(schema.mainEntity.length).toBeGreaterThan(0);
});
