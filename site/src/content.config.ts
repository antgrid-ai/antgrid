import { defineCollection } from "astro:content";
import { glob } from "astro/loaders";
import { createBlogSchema } from "./data/blog-policy";

export const collections = {
  blog: defineCollection({
    loader: glob({
      base: "./src/content/blog",
      pattern: "*.md",
      generateId: ({ entry }) => {
        const slug = entry.replace(/\.md$/, "");
        if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug)) throw new Error(`Blog filename must be a lowercase hyphenated slug: ${entry}`);
        return slug;
      },
    }),
    schema: ({ image }) => createBlogSchema(image()),
  }),
};
