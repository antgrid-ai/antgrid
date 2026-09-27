import { describe, expect, test } from "bun:test";
import { getBlogImageOptions } from "../../scripts/blog-image-options.mjs";
import { blogSchema, leadPost, publishedPosts, readingMinutes, relatedPosts, type BlogPost } from "../../src/data/blog-policy";

const valid = { title: "Test", description: "Description", publishedAt: "2026-09-14", author: "Test Author", topic: "proof", draft: false };
const post = (id: string, overrides = {}): BlogPost => ({ id, data: blogSchema.parse({ ...valid, ...overrides }) });

describe("blog publishing contract", () => {
  test("preserves SVG vectors and optimizes raster formats", () => {
    for (const format of ["svg", "SVG"]) expect(getBlogImageOptions(format)).toEqual({ format: "svg" });
    for (const format of ["png", "jpg", "jpeg", "webp", "avif"]) {
      expect(getBlogImageOptions(format)).toMatchObject({
        format: "webp", quality: 80, widths: [480, 768, 1088, 1600, 2176],
      });
    }
  });
  test("requires explicit editorial fields and rejects invalid metadata", () => {
    for (const key of Object.keys(valid)) {
      const missing = { ...valid } as Record<string, unknown>;
      delete missing[key];
      expect(blogSchema.safeParse(missing).success).toBe(false);
    }
    for (const fields of [
      { title: " " }, { topic: "news" }, { publishedAt: "not-a-date" }, { publishedAt: null }, { publishedAt: "2026-02-30" },
      { updatedAt: "2026-09-13" }, { coverImage: "/blog/image.png" },
      { ogImage: "/og/custom.png" }, { claimsVerifiedAt: "not a commit" },
      { action: { label: "Bad", href: "javascript:alert(1)", category: "github" } },
    ]) expect(blogSchema.safeParse({ ...valid, ...fields }).success).toBe(false);
    expect(blogSchema.safeParse({ ...valid, updatedAt: "2026-09-14", coverImage: "./assets/cover.png", coverImageAlt: "A useful diagram" }).success).toBe(true);
    expect(blogSchema.safeParse({ ...valid, coverImage: "/blog/cover.png", coverImageAlt: "A useful diagram" }).success).toBe(false);
  });

  test("drafts are removed before featured validation and date ties are stable", () => {
    const posts = publishedPosts([post("z"), post("draft", { draft: true, featured: true }), post("a", { featured: true }), post("old", { publishedAt: "2026-09-01" })]);
    expect(posts.map((p) => p.id)).toEqual(["a", "z", "old"]);
    expect(leadPost(posts)?.id).toBe("a");
  });

  test("conflicting featured posts fail with their names", () => {
    expect(() => publishedPosts([post("one", { featured: true }), post("two", { featured: true })])).toThrow("one, two");
  });

  test("an empty collection has no lead, and a lone post leads without being featured", () => {
    expect(leadPost([])).toBeUndefined();
    const one = publishedPosts([post("one")]);
    expect(leadPost(one)?.id).toBe("one");
    expect(one[0].data.featured).toBe(false);
  });

  test("related posts favour topic before recency, without the current post", () => {
    const current = post("current");
    const posts = publishedPosts([current, post("new", { topic: "security" }), post("same", { publishedAt: "2026-09-01" })]);
    expect(relatedPosts(current, posts).map((p) => p.id)).toEqual(["same", "new"]);
    expect(relatedPosts(current, [current])).toEqual([]);
  });

  test("reading time has a one-minute minimum and rounds up", () => {
    expect(readingMinutes()).toBe(1);
    expect(readingMinutes("word ".repeat(200))).toBe(1);
    expect(readingMinutes("word ".repeat(201))).toBe(2);
  });
});
