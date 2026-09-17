# syntax=docker/dockerfile:1

##########################
# Stage 1: build deps    #
##########################
# node:20-alpine's Node 20 LTS line has reached end-of-life (no further
# security patches) — moved to node:22-slim, an actively supported Node
# LTS release on Debian, matching the runtime stage below.
FROM node:22-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts

##########################
# Stage 2: runtime image #
##########################
# Distroless was evaluated for this stage (minimal attack surface, no
# shell/package manager) but its currently published nodejs22-debian12
# base still ships a slightly-behind-patch-level libssl3 with known,
# already-fixed CVEs upstream in Debian — and distroless has no package
# manager to apply that fix in place, so those findings would sit there
# until the distroless project's own next rebuild, outside this project's
# control. node:22-slim keeps a real Debian + apt underneath specifically
# so `apt-get upgrade` can pull the actual patched packages (openssl,
# libssl3, etc.) directly at build time — the same OS the CVE database
# tracks fixes for. That patchability, verified against a live scan, is
# worth the larger surface versus a smaller image with unpatchable CVEs.
FROM node:22-slim AS runtime

# Security-relevant OS updates and minimal footprint: apt-get upgrade
# pulls the latest patched Debian packages (including libssl3) available
# at build time; --no-install-recommends and the apt list cleanup keep
# the image from accumulating anything beyond what's actually needed.
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends dumb-init \
    && rm -rf /var/lib/apt/lists/*

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /app

# Run as a dedicated, unprivileged, non-root user.
RUN groupadd -r appgroup && useradd -r -g appgroup appuser

COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "require('http').get('http://127.0.0.1:3000/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/server.js"]
