import { z } from "astro/zod";
import type { ImageMetadata } from "astro";

export const topics = { proof: "Proof", engineering: "Engineering", security: "Security", "field-notes": "Field notes" } as const;
const text = z.string().trim().min(1);
const localImage = text.regex(/^\/(?!\/)[^?#]+\.(png|jpe?g|webp|avif|svg)$/i, "Use a site-relative image path");
export const coverImagePath = text.regex(/^\.\.?\/[^?#]+\.(png|jpe?g|webp|avif|svg)$/i, "Use an image path relative to the article, outside public/");
const date = z.union([z.date(), z.iso.date(), z.iso.datetime({ offset: true })]).pipe(z.coerce.date());
export const createBlogSchema = <T extends z.ZodType>(cover: T) => z.object({
  title: text,
  description: text,
  publishedAt: date,
  updatedAt: date.optional(),
  topic: z.enum(["proof", "engineering", "security", "field-notes"]),
  author: text,
  draft: z.boolean(),
  featured: z.boolean().default(false),
  coverImage: cover.optional(),
  coverImageAlt: text.optional(),
  ogImage: localImage.optional(),
  ogImageAlt: text.optional(),
  claimsVerifiedAt: text.regex(/^[a-f0-9]{7,40}$/i, "Use the verified Git commit hash").optional(),
  action: z.object({
    label: text,
    href: text.refine((value) => /^\/(?!\/)/.test(value) || /^https:\/\//.test(value), "Use a site-relative path or HTTPS URL"),
    category: z.enum(["github", "download", "security", "article", "pricing"]),
  }).optional(),
}).superRefine((post, ctx) => {
  if (post.updatedAt && post.updatedAt < post.publishedAt) ctx.addIssue({ code: "custom", path: ["updatedAt"], message: "updatedAt cannot precede publishedAt" });
  for (const [image, alt] of [["coverImage", "coverImageAlt"], ["ogImage", "ogImageAlt"]] as const) {
    if (post[image] && !post[alt]) ctx.addIssue({ code: "custom", path: [alt], message: `${image} requires meaningful alternative text` });
  }
});

export const blogSchema = createBlogSchema(coverImagePath);
export type BlogData = Omit<z.infer<typeof blogSchema>, "coverImage"> & { coverImage?: string | ImageMetadata };
export type BlogPost = { id: string; data: BlogData; body?: string };
export function publishedPosts<T extends BlogPost>(entries: T[]): T[] {
  const posts = entries.filter((post) => !post.data.draft).sort((a, b) => b.data.publishedAt.getTime() - a.data.publishedAt.getTime() || a.id.localeCompare(b.id, "en"));
  const featured = posts.filter((post) => post.data.featured);
  if (featured.length > 1) throw new Error(`Only one published blog post may be featured: ${featured.map((post) => post.id).join(", ")}`);
  return posts;
}
export const leadPost = <T extends BlogPost>(posts: T[]) => posts.find((post) => post.data.featured) ?? posts[0];
export const showBlogNav = (posts: BlogPost[]) => posts.length >= 3;
export const readingMinutes = (body = "") => Math.max(1, Math.ceil((body.match(/\S+/g)?.length ?? 0) / 200));
export const postPath = (post: BlogPost) => `/blog/${post.id}`;
export const formatDate = (date: Date) => new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" }).format(date);
export function relatedPosts<T extends BlogPost>(post: BlogPost, posts: T[]): T[] {
  const remaining = posts.filter((other) => other.id !== post.id);
  return [...remaining.filter((other) => other.data.topic === post.data.topic), ...remaining.filter((other) => other.data.topic !== post.data.topic)].slice(0, 2);
}
