# Pinned, not floating 1.3: direct-APNs push needs Bun >= 1.3.14. Earlier 1.3.x
# negotiates no h2 against the APNs endpoint (ERR_HTTP2_ERROR "h2 is not
# supported"), and ApnsSender.send reports only "error", so a regression here is
# invisible at runtime.
FROM oven/bun:1.3.14-alpine

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
