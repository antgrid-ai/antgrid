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

# Install only the relay workspace. The relay has no postinstall/codegen step
# (unlike web's prisma generate), so --frozen-lockfile is sufficient.
RUN bun install --frozen-lockfile --filter antgrid-relay

# Source
COPY relay/src ./relay/src
COPY relay/tsconfig.json ./relay/

# Shared workspace dep imported by relay/src at runtime (antgrid-wire -> ./src/index.ts).
COPY packages/antgrid-wire/src ./packages/antgrid-wire/src

WORKDIR /app/relay
EXPOSE 8080
CMD ["bun", "run", "src/index.ts"]
