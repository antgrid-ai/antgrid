# antgrid site

Standalone static marketing site (home + /pricing). Isolated from the Bun
workspaces — own deps, own build, own deploy. Not a workspace member.

## Develop
    cd site && bun install && bun run dev      # http://localhost:4321

## Build & test
    bun run build      # static output → dist/
    bun run check      # astro type/template check
    bun run test       # Playwright (desktop + mobile)
    bun run build:og   # regenerate the OG image (preview server must be up)

## Config
- CTAs point at the web app via PUBLIC_APP_URL (default https://app.antgrid.ai):
  Start free / Sign in → /login, checkout → /checkout?planId=<id>.
- Prices/caps live in src/data/pricing.ts — keep in lockstep with
  web/src/billing/plans.ts and web/src/models/plan.ts.

## Deploy
Azure Static Web Apps via .github/workflows/azure-static-web-apps.yml (builds with
Bun, uploads the prebuilt dist/). Custom domain antgrid.ai with free SSL; routing,
headers and the 404 come from public/staticwebapp.config.json. The web app stays on
Caddy at app.antgrid.ai.
