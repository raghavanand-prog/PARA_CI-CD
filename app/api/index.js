'use strict';

/**
 * Vercel serverless entry point.
 *
 * This is a thin adapter, not a reimplementation: it reuses the exact same
 * createApp() factory that app/src/server.js uses for local/ECS Fargate
 * execution, so the routes, middleware, and validation running on Vercel
 * are identical to the ones the security-gate pipeline scans and deploys
 * to AWS. Vercel's Node.js runtime accepts an Express app instance directly
 * as the request handler — no separate framework-specific code is needed.
 *
 * NOTE: this endpoint is a supplementary live demo of the API only. It is
 * NOT part of, and does not exercise, this project's actual CI/CD security
 * pipeline (CodePipeline/CodeBuild/security-gate.sh/ECS) — see
 * docs/deployment.md for the real, gated AWS deployment path.
 */
const createApp = require('../src/app');

module.exports = createApp();
