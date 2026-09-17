# syntax=docker/dockerfile:1

##########################
# Stage 1: build deps    #
##########################
# node:20-alpine's Node 20 LTS line has reached end-of-life (no further
# security patches) — moved to node:22-alpine, an actively supported Node
# LTS release, so the base image keeps receiving upstream OS/runtime patches.
FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts

##########################
# Stage 2: runtime image #
##########################
FROM node:22-alpine AS runtime

# Security-relevant OS updates and minimal footprint.
RUN apk update && apk upgrade --no-cache && apk add --no-cache dumb-init

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /app

# Run as a dedicated, unprivileged, non-root user.
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "require('http').get('http://127.0.0.1:3000/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/server.js"]
