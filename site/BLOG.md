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
- `coverImage` and `coverImageAlt`: a site-relative image path and meaningful alternative text.
- `ogImage` and `ogImageAlt`: a 1200 × 630 social card and its alternative description. Without these, the existing Antgrid control-plane card is used.
- `claimsVerifiedAt`: the 7–40 character Git commit hash against which product claims were checked. Recheck evidence before publishing; the visible note links to that commit.
- `action`: `{ label, href, category }`. Use an HTTPS URL or site-relative path. Categories: `github`, `download`, `security`, `article`, `pricing`. The default links to GitHub. Clicks use the existing Umami `blog_cta` event with `slug` and `destination` properties.

Place cover/social assets in `public/blog/` (or reuse `public/og/`) and refer to them as `/blog/...`. Missing assets fail published builds. Use descriptive alt text for body images and explicit width/height when known. Standard Markdown supports highlighted fenced code, tables, lists and footnotes. For captions, use semantic HTML `<figure>`, `<img>` and `<figcaption>`. Start body headings at `##`; the layout supplies the sole `h1`. Headings receive permanent links and duplicate headings receive distinct IDs.

`draft: false` means the copy is approved for the public website and Git history. Drafts are omitted from all public routes, feeds and related links, even during development. Dates do not schedule publication. Only one published post may be featured; otherwise the newest is the lead. Main navigation gains Blog at three published posts. The footer always links to it. Related articles favour the same topic, then newest posts.

## Local checks

Run commands from `site/`, which owns its dependencies and lockfile:

```sh
bun install --frozen-lockfile
bun run check
bun run test
bun run test:blog
```

`bun run dev` previews approved content. `bun run dev:blog` previews synthetic examples at `http://localhost:4322/blog`; it is for layout QA, not private editorial drafts. Test content lives under `tests/fixtures/blog`. The explicit fixture configuration selects it and writes to `.test-output/blog` and `.test-cache/blog`; the normal build uses `src/content/blog` and deployable `dist/`. Do not set `ANTGRID_BLOG_FIXTURES` manually or use the fixture configuration for deployments.

The separate blog suite checks publishing policy, metadata, RSS/sitemap exclusion and responsive article rendering on phone, tablet and desktop. The ordinary site suite verifies production output and existing navigation. Azure runs both before deploying the normal `dist/` artifact.
