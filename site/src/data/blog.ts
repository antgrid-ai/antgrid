import { getCollection } from "astro:content";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { imageMetadata } from "astro/assets/utils";
import { publishedPosts } from "./blog-policy";

export async function getPublishedPosts() {
  const posts = publishedPosts(await getCollection("blog"));
  for (const post of posts) {
    if (!post.rendered) throw new Error(`${post.id}: Markdown rendering failed. Fix the rendering error and run astro sync --force before rebuilding.`);
    for (const path of [post.data.coverImage, post.data.ogImage]) {
      if (!path) continue;
      if ((!path.startsWith("/blog/") && !path.startsWith("/og/")) || path.includes("..")) throw new Error(`${post.id}: blog images must live in public/blog or public/og`);
      const bytes = await readFile(resolve("public", `.${path}`)).catch(() => { throw new Error(`${post.id}: image does not exist: ${path}`); });
      if (path === post.data.ogImage) {
        const { width, height } = await imageMetadata(bytes, path);
        if (width !== 1200 || height !== 630) throw new Error(`${post.id}: social image must be 1200 × 630: ${path}`);
      }
    }
  }
  return posts;
}
