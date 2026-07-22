FROM oven/bun:1.3-alpine

WORKDIR /app

# Root workspace manifests + lockfile
COPY package.json bun.lock bunfig.toml ./

# All workspace manifests must be present for bun to resolve the workspace graph
COPY packages/antgrid-wire/package.json ./packages/antgrid-wire/
COPY bridge/package.json ./bridge/
COPY bridge/plugin/package.json ./bridge/plugin/
COPY relay/package.json ./relay/
COPY evals/package.json ./evals/
COPY web/package.json ./web/

# Prisma schema needs to be present before install so the postinstall hook
# (bunx --bun prisma generate) can read it.
COPY web/prisma ./web/prisma

# Install the web workspace. Cannot use --production because the
# postinstall hook runs `bunx --bun prisma generate`; without prisma in
# node_modules, bunx fetches latest from npm (currently 7.x), which is
# incompatible with the Prisma 6 schema. Including devDeps keeps the
# workspace's pinned prisma@^6 in node_modules.
RUN bun install --frozen-lockfile --filter antgrid-web

# Source
COPY web/src ./web/src
COPY web/tsconfig.json ./web/
COPY web/vite.config.ts ./web/

# Static assets served by app.ts.
# public/build is excluded by .dockerignore (**/build)
COPY web/public ./web/public

# Build static assets (Vite -> web/public/build/ + manifest.json) that asset.ts
# reads at runtime. public/build is gitignored build output, so it MUST be built
# here — there is nothing to COPY.
RUN bun run --filter antgrid-web build:assets

WORKDIR /app/web
EXPOSE 8787
CMD ["bun", "run", "src/index.ts"]
