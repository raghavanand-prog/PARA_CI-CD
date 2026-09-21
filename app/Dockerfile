# syntax=docker/dockerfile:1

##########################
# Stage 1: build deps    #
##########################
# node:20-alpine's Node 20 LTS line has reached end-of-life (no further
# security patches) — moved to node:22-alpine, an actively supported Node
# LTS release. Only used to produce node_modules for COPY below; this
# stage's own OS packages are never shipped.
FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts

##########################
# Stage 2: runtime image #
##########################
# Distroless for the shipped image: verified locally (via a real `trivy
# image` scan, vulnerability DB pulled through mirror.gcr.io) that this
# has by far the smallest OS-package attack surface of the options tried:
#   node:20-alpine (apk upgrade only):        critical=1 high=19
#   node:22-alpine (bumped + apk upgrade):    critical=1 high=10
#   node:22-slim   (apt-get upgrade):         critical=5 high=62  <- worse:
#     a full Debian base has a much larger package count than either
#     alpine or distroless, so total CVE surface went UP despite patching.
#   distroless/nodejs22-debian12:nonroot:     critical=1 high=5   <- best
# The `:nonroot` tag already runs as an unprivileged user (uid 65532), so
# there is no separate addgroup/adduser step needed here.
FROM gcr.io/distroless/nodejs22-debian12:nonroot AS runtime

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src

EXPOSE 3000

# Distroless has no shell, so HEALTHCHECK must use exec form (JSON array)
# rather than shell form — `CMD node -e "..."` would otherwise try to run
# through /bin/sh, which doesn't exist in this image.
#
# The binary must be the ABSOLUTE path (/nodejs/bin/node), not the bare
# "node": exec-form CMD/HEALTHCHECK resolves argv[0] via $PATH rather than
# through the image's own ENTRYPOINT, and this image's PATH (verified via
# `docker inspect .Config.Env`) is just the standard system dirs
# (/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin) — it does
# NOT include /nodejs/bin, even though ENTRYPOINT itself
# (["/nodejs/bin/node"], also confirmed via `docker inspect`) uses that
# exact path. A bare "node" here fails with "executable file not found in
# $PATH" on every invocation; this is what silently broke the ECS
# container health check in production (confirmed: the app itself was
# healthy and answering the ALB's own checks the whole time — the
# internal health check process never even reached the app).
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/nodejs/bin/node", "-e", "require('http').get('http://127.0.0.1:3000/health', (r) => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"]

# No dumb-init: distroless has no shell to run it from, and an
# Alpine-built (musl-linked) dumb-init binary can't run on this
# glibc-based Debian image anyway. src/server.js already installs its own
# SIGTERM/SIGINT handlers for graceful shutdown, and this process never
# spawns children, so PID-1 zombie-reaping isn't a concern here.
CMD ["src/server.js"]
