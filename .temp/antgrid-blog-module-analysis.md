# Antgrid blog module: implementation analysis

Prepared 2026-09-15 from `.antgrid/uploads/ad92b11e-antgrid-blog-implementation-brief.md` and the current public repository. This is analysis, not approved article copy or an implementation change.

## Outcome

The brief is suitable as the implementation specification. The blog belongs in the standalone Astro site under `site/`, not in the Hono licensing/account application under `web/`. The current site already has a shared shell, design tokens, canonical metadata, sitemap, analytics, changelog and responsive Playwright coverage. The main new work is the content model, article rendering, draft-safe route/feed generation and article-specific metadata.

No blog files or posts existed when inspected. `site/` is outside the root Bun workspace and owns its own `package.json` and `bun.lock`; dependency installation and test commands must run from `site/`.

## Current integration points

| Concern | Existing source | Implication |
| --- | --- | --- |
| Astro build and sitemap | `site/astro.config.mjs` | Static article routes should enter the sitemap automatically when generated. Draft routes must never be generated for production. |
| Shared shell | `site/src/layouts/Base.astro` | Build a dedicated post layout on top of Base, preserving fonts, nav, footer and analytics. |
| SEO | `site/src/components/Seo.astro` | It already provides canonical, Open Graph and Twitter metadata, but hard-codes `og:type=website` and assumes a 1200×630 image. Extend it for articles. |
| Navigation | `site/src/components/Nav.astro` | The desktop bar and phone drawer share one item list. Add Blog to that list only once the three-worthy-post launch condition is met. |
| Footer | `site/src/components/Footer.astro` | Changelog is already linked; add Blog for early route discovery without conflating the two. |
| Visual system | `site/src/styles/global.css` and `site/src/pages/changelog.astro` | Existing dark tokens, type scale, focus ring and divider-led changelog provide a strong basis. There is no Markdown prose styling yet. |
| Links and analytics | `site/src/config.ts` and Base | Centralise the Blog path and article-end destinations; the self-hosted Umami tag already provides page views. |
| Deployment gate | `.github/workflows/azure-static-web-apps.yml` | CI installs site dependencies, runs Astro check/build, then Playwright desktop/mobile tests. |

## Proposed module shape

```text
site/src/content.config.ts
site/src/content/blog/*.md
site/src/data/blog.ts
site/src/layouts/BlogPost.astro
site/src/pages/blog/index.astro
site/src/pages/blog/[slug].astro
site/src/pages/blog/rss.xml.ts
site/src/styles/global.css
site/public/blog/                 # only assets needing stable unprocessed URLs
site/tests/blog.spec.ts
```

Use Astro content collections and Markdown by default. Add `@astrojs/rss` to `site/package.json` only when implementing the feed. Do not introduce MDX or a CMS for version one.

A shared blog helper should load entries, filter drafts, sort newest first, reject multiple published featured entries, select the visual lead, calculate reading time and choose related entries. The index, article route, RSS, sitemap route generation and nav threshold must use consistent published-entry semantics. Whether this resides in one `data/blog.ts` module or smaller helpers is an implementation choice; the invariant is one published-post policy.

## Frontmatter and publishing policy

Follow the brief's required fields: `title`, `description`, `publishedAt`, `topic`, `author` and `draft`. Constrain `topic` to `proof`, `engineering`, `security` and `field-notes`; validate `updatedAt >= publishedAt`; require meaningful alt text with a cover; derive slugs from filenames. `claimsVerifiedAt` records the source commit used to check applicable product claims, not a permanent guarantee of their validity.

The multiple-featured rule is collection-wide and cannot be validated by one entry's schema. Throw a build error naming the conflicting articles. When none is featured, show the newest published article as the visual lead without changing its metadata.

The brief requests a representative draft fixture and production draft exclusion. Make the preview rule explicit during implementation: production routes, RSS, related posts and sitemap exclude drafts; a development-only route may render drafts for editorial QA. Do not make drafts appear on the normal index by default.

Potential optional refinements, if useful when first posts are prepared: a constrained article-end CTA key rather than inferring a destination from topic, and optional explicit related slugs with a deterministic fallback. These are suggestions, not requirements in the brief.

## Rendering and metadata gaps

Add a scoped long-form prose treatment for headings and deep-link anchors, paragraphs, code and horizontal `pre` scrolling, lists, blockquotes, tables, figures/captions, footnotes, links and images. Wide tables should scroll independently; making the whole article scroll horizontally would fail phone readability. Preserve the site's universal `:focus-visible` rule and use its tokens rather than an unrelated light card-grid system.

Extend `Seo.astro` or a narrowly scoped article companion to emit `og:type=article`, publication and optional modification metadata, author, absolute canonical and image URLs, Twitter image alternative text, RSS autodiscovery and valid `BlogPosting` JSON-LD. Use the current OG-card visual language or a deliberate per-post/static Antgrid image. Verify every social image named by metadata actually resolves from the build.

The site already has `@astrojs/sitemap`; generated published article routes should be included without a new sitemap system. The blog index needs its own canonical and description. RSS must contain only published entries and absolute Antgrid URLs.

For article-end click measurement, use stable Umami-compatible event attributes or a small event handler with the article slug and destination category. Page views are already tracked site-wide; a blog-specific analytics stack is unnecessary.

## Verification plan

Create a representative fixture containing a long code line, wide table, figure, blockquote, footnote and links. Test the difficult article surface before polishing the index. Add tests for published-only newest-first index, static article routes, draft absence in HTML/RSS/sitemap, featured invariant, no-feature fallback, canonical/OG/JSON-LD correctness, RSS URL/content type, article-end event attributes, anchor targets, image alternatives, and no page-level overflow at phone width. Run the existing site checks and desktop/mobile Playwright suite.

The initial three articles still need approved final copy, current repository evidence for product claims, social images and contextual CTA choices. Do not treat the brief's `antgrid@994e7e7` source pin as publication approval; re-verify mechanisms against the current source before publishing.

## Key implementation risks

1. Drafts leaking through one surface while being filtered from another.
2. A collection-wide featured invariant silently drifting across routes.
3. Article SEO changing the existing website metadata contract or pointing to a missing image.
4. Markdown code/tables overflowing the phone viewport.
5. A primary nav Blog item appearing before the agreed three-post launch threshold.

The pre-existing unrelated root `bun.lock` worktree modification was not changed during this analysis.
