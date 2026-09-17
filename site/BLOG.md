# Publishing the Antgrid blog

Approved articles live in `src/content/blog/*.md`. Use lowercase hyphenated filenames; the filename becomes `/blog/<filename>`. Working editorial drafts belong in the private editorial repository. Nothing synchronises automatically.

```yaml
title: "An approved article title"
description: "A concise account of what the reader will learn."
publishedAt: 2026-09-14
topic: engineering
author: "Author name"
draft: false
featured: false
```

Every field above except `featured` is required. Topics are `proof`, `engineering`, `security` and `field-notes`. Optional fields:

- `updatedAt`: a date on or after publication.
- `coverImage` and `coverImageAlt`: an image path relative to the article (for example `./assets/my-post/cover.png`) and meaningful alternative text. Astro resolves the image and its dimensions through the collection schema.
- `ogImage` and `ogImageAlt`: a 1200 × 630 social card and its alternative description. Without these, the existing Antgrid control-plane card is used.
- `claimsVerifiedAt`: the 7–40 character Git commit hash against which product claims were checked. Recheck evidence before publishing; the visible note links to that commit.
- `action`: `{ label, href, category }`. Use an HTTPS URL or site-relative path. Categories: `github`, `download`, `security`, `article`, `pricing`. The default links to GitHub. Clicks use the existing Umami `blog_cta` event with `slug` and `destination` properties.

Place cover and body assets beside the articles in `src/content/blog/assets/`, not `public/`. Keep social cards in `public/og/` or `public/blog/` and refer to those as `/og/...` or `/blog/...`; their stable URLs and 1200 × 630 validation are unchanged. Missing image assets fail builds. Standard Markdown supports highlighted fenced code, tables, lists and footnotes. Start body headings at `##`; the layout supplies the sole `h1`. Headings receive permanent links and duplicate headings receive distinct IDs.

## Optimized article images

Both Markdown images and HTML figures use local relative paths and require meaningful alt text:

```md
![Terminal output showing a completed sample run](./assets/my-post/terminal.png)

<figure>
  <img src="./assets/my-post/terminal.png" alt="Terminal output showing a completed sample run" />
  <figcaption>The completed run, including its exit status.</figcaption>
</figure>
```

For raster sources, the build emits responsive WebP files under `dist/_astro/` with `srcset`, `sizes` and intrinsic dimensions. Width candidates are defined in `scripts/blog-image-options.mjs` and capped at the source image's width by Astro. Covers load eagerly with high priority; body images use lazy loading and asynchronous decoding. No runtime image service, browser JavaScript or external CDN is needed. SVG covers, Markdown images and HTML figures retain their original vector content and intrinsic dimensions without rasterization or resolution variants.

Root-relative `public/` URLs and remote URLs are not supported for body images in this pipeline. Import the asset into the article's source directory first. Do not specify a handcrafted `srcset` or force mismatched image dimensions.

`draft: false` means the copy is approved for the public website and Git history. Drafts are omitted from all public routes, feeds and related links, even during development. Dates do not schedule publication. Only one published post may be featured; otherwise the newest is the lead. Main navigation gains Blog at three published posts. The footer always links to it. Related articles favour the same topic, then newest posts.

## Local checks

Run commands from `site/`, which owns its dependencies and lockfile:

```sh
bun install --frozen-lockfile
bun run check
bun run test
bun run test:blog
```

`bun run dev` previews approved content from `src/content/blog`. `bun run build` produces the deployable static site in `dist/`.

The blog unit suite checks publishing policy and image-format selection. The ordinary site suite verifies production output and existing navigation. Azure runs both before deploying `dist/`.
