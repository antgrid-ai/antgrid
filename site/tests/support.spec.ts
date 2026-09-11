import { expect, test } from "@playwright/test";

test("support chat is present without loading SalesIQ before user intent", async ({
  page,
}) => {
  await page.goto("/support");
  await expect(page.getByRole("button", { name: "Chat with support" })).toBeVisible();
  await expect(page.locator('script[src*="salesiq"]')).toHaveCount(0);
  await expect(page.locator("[data-salesiq-support]")).toHaveAttribute(
    "data-widget-url",
    "https://salesiq.zohopublic.com/widget?wc=siq1b947f921d212e33194fb74467bb4e1d9243576c0c0fc99198af56f9bc127661",
  );
});

test("a failed widget request can be retried without reloading the page", async ({
  page,
}) => {
  await page.goto("/support");
  const inlineScripts = await page.locator("script:not([src])").allTextContents();
  const controller = inlineScripts.find((script) =>
    script.includes("[data-salesiq-support]"),
  );
  expect(controller).toBeTruthy();

  let requests = 0;
  await page.route("https://salesiq.invalid/widget", async (route) => {
    requests += 1;
    await route.abort();
  });
  await page.setContent(`
    <aside data-salesiq-support data-widget-url="https://salesiq.invalid/widget">
      <button type="button" data-salesiq-open>Chat with support</button>
      <span data-salesiq-status></span>
    </aside>
    <script>${controller}</script>
  `);

  const button = page.getByRole("button", { name: "Chat with support" });
  await button.click();
  await expect(button).toBeEnabled();
  await button.click();
  await expect.poll(() => requests).toBe(2);
});

test("an app handoff identifies the visitor, opens chat, and scrubs the fragment", async ({
  page,
}) => {
  await page.goto("/support");
  const inlineScripts = await page.locator("script:not([src])").allTextContents();
  const controller = inlineScripts.find((script) =>
    script.includes("[data-salesiq-support]"),
  );
  expect(controller).toBeTruthy();

  await page.setContent(`
    <aside data-salesiq-support data-widget-url="https://salesiq.invalid/widget">
      <button type="button" data-salesiq-open>Chat with support</button>
      <span data-salesiq-status></span>
    </aside>
  `);
  await page.evaluate(() => {
    history.replaceState(
      null,
      "",
      "/support?chat=1&source=app#name=Jane%20Doe&email=jane%2Bapp%40example.com",
    );
    const calls: string[] = [];
    (window as any).__salesIqCalls = calls;
    (window as any).$zoho = {
      salesiq: {
        visitor: {
          name: (value: string) => calls.push(`name:${value}`),
          email: (value: string) => calls.push(`email:${value}`),
        },
        chatwindow: { visible: (value: string) => calls.push(`visible:${value}`) },
      },
    };
  });
  await page.addScriptTag({ content: controller });

  await expect.poll(() => page.evaluate(() => (window as any).__salesIqCalls)).toEqual([
    "name:Jane Doe",
    "email:jane+app@example.com",
    "visible:show",
  ]);
  await expect.poll(() => page.evaluate(() => window.location.hash)).toBe("");
  expect(new URL(page.url()).searchParams.get("chat")).toBe("1");
});
