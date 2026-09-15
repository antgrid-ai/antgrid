import { test, expect } from "@playwright/test";
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";

test("index leads with the featured article and lists remaining posts newest first", async ({ page }) => {
  await page.goto("/blog");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText("Blog");
  await expect(page.locator(".blog-lead h2")).toHaveText("A rendering check for engineering notes");
  await expect(page.locator(".blog-list h3")).toHaveText(["The latest synthetic note", "An earlier engineering check"]);
  const header = page.locator("header").first();
  if (await page.locator("#navToggle").isVisible()) await page.locator("#navToggle").click();
  await expect(header.getByRole("link", { name: "Blog", exact: true }).filter({ visible: true })).toHaveCount(1);
  await expect(page.locator("body > footer").getByRole("link", { name: "Changelog", exact: true })).toHaveAttribute("href", "/changelog");
});

test("article has complete metadata, verification and measured next action", async ({ page, request }) => {
  await page.goto("/blog/rendering-check");
  await expect(page.locator('link[rel="canonical"]')).toHaveAttribute("href", "https://antgrid.ai/blog/rendering-check");
  await expect(page.locator('meta[property="og:type"]')).toHaveAttribute("content", "article");
  await expect(page.locator('meta[property="article:author"]')).toHaveAttribute("content", "Test Author");
  await expect(page.locator('meta[property="article:published_time"]')).toHaveAttribute("content", "2026-09-12T00:00:00.000Z");
  await expect(page.locator('meta[property="article:modified_time"]')).toHaveAttribute("content", "2026-09-14T00:00:00.000Z");
  await expect(page.locator('meta[name="twitter:image:alt"]')).toHaveAttribute("content", /control plane/);
  const data = JSON.parse(await page.locator('script[type="application/ld+json"]').innerText());
  expect(data["@type"]).toBe("BlogPosting");
  expect(data.headline).toBe("A rendering check for engineering notes");
  expect(data.mainEntityOfPage).toBe("https://antgrid.ai/blog/rendering-check");
  expect(data.dateModified).toBe("2026-09-14T00:00:00.000Z");
  expect((await request.get(new URL(data.image).pathname)).ok()).toBe(true);
  await expect(page.locator('link[type="application/rss+xml"]')).toHaveAttribute("href", "https://antgrid.ai/blog/rss.xml");
  await expect(page.locator(".blog-verification")).toContainText("antgrid@abcdef1");
  await expect(page.locator('[data-umami-event="blog_cta"]')).toHaveAttribute("data-umami-event-slug", "rendering-check");
  await expect(page.locator('[data-umami-event="blog_cta"]')).toHaveAttribute("data-umami-event-destination", "security");
  await expect(page.locator(".blog-related h3")).toHaveText(["An earlier engineering check", "The latest synthetic note"]);
  await page.goto("/blog/earlier-engineering");
  await expect(page.locator('meta[name="twitter:image:alt"]')).toHaveAttribute("content", "Custom alternative description for the engineering fixture");
  await expect(page.locator(".blog-action")).toHaveAttribute("href", "https://github.com/antgrid-ai/antgrid");
});

test("article remains readable with accessible anchors, figures and scroll containers", async ({ page }, testInfo) => {
  await page.goto("/blog/rendering-check");
  await expect(page.locator("main h1")).toHaveCount(1);
  await expect(page.locator(".blog-prose")).toContainText("This synthetic article exercises the blog layout.");
  await expect(page.locator(".blog-prose img")).toHaveCount(1);
  expect(await page.locator(".blog-prose img").evaluateAll((images) => images.every((img) => (img as HTMLImageElement).alt.trim() && (img as HTMLImageElement).naturalWidth > 0))).toBe(true);
  await expect(page.locator("figcaption")).toBeVisible();
  await expect(page.locator(".footnotes")).toBeAttached();
  const anchors = page.locator(".heading-anchor");
  expect(await anchors.count()).toBeGreaterThan(2);
  const hrefs = await anchors.evaluateAll((nodes) => nodes.map((node) => node.getAttribute("href")));
  expect(new Set(hrefs).size).toBe(hrefs.length);
  for (const href of hrefs) await expect(page.locator(`[id="${href!.slice(1)}"]`)).toHaveCount(1);
  await anchors.first().focus();
  await expect(anchors.first()).toBeFocused();
  expect(await anchors.first().evaluate((node) => getComputedStyle(node).outlineStyle)).not.toBe("none");
  await anchors.first().press("Enter");
  expect(new URL(page.url()).hash).toBe(hrefs[0]);
  await expect(page.locator(".table-scroll")).toHaveAttribute("tabindex", "0");
  await expect(page.locator("pre")).toHaveAttribute("tabindex", "0");
  await page.evaluate(async () => { await document.fonts.ready; scrollTo(0, 0); });
  await page.screenshot({ path: `.test-output/article-${testInfo.project.name}.png`, fullPage: true });
  for (const size of ["100%", "200%"]) {
    await page.evaluate((fontSize) => { document.documentElement.style.fontSize = fontSize; }, size);
    const overflow = await page.evaluate(() => ({
      width: innerWidth, scroll: document.documentElement.scrollWidth,
      elements: [...document.querySelectorAll("body *")].filter((node) => node.getBoundingClientRect().right > innerWidth + 1 && !node.closest("pre, .table-scroll")).map((node) => `${node.tagName}.${node.className}`),
    }));
    expect(overflow.scroll, `${size}: ${JSON.stringify(overflow)}`).toBeLessThanOrEqual(overflow.width + 1);
  }
});

test("RSS and sitemap include only published routes and drafts have no output", async ({ request }) => {
  const feed = await request.get("/blog/rss.xml");
  expect(feed.headers()["content-type"]).toContain("xml");
  const xml = await feed.text();
  expect((xml.match(/<item>/g) ?? []).length).toBe(3);
  expect(xml).toContain("https://antgrid.ai/blog/rendering-check");
  expect(xml.indexOf("/blog/latest-note")).toBeLessThan(xml.indexOf("/blog/rendering-check"));
  const sitemap = await (await request.get("/sitemap-0.xml")).text();
  expect(sitemap).toContain("https://antgrid.ai/blog");
  expect(sitemap).toContain("/blog/rendering-check");
  expect((await request.get("/blog/unpublished-draft")).status()).toBe(404);
  const inspect = async (directory: string): Promise<void> => {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) await inspect(path);
      else if (/\.(html|xml)$/.test(entry.name)) expect(await readFile(path, "utf8"), path).not.toMatch(/DRAFT_(?:BODY_)?SENTINEL|unpublished-draft/);
    }
  };
  await inspect(".test-output/blog");
});
